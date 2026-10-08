import Foundation
import HoloCore
#if canImport(Glibc)
import Glibc
#endif

/// A validated side effect on Linux. The macOS-only parts of the shared
/// action model (security bookmarks, the Shortcuts app) map to their nearest
/// desktop equivalents: an app is a desktop entry id, a file is a path.
public enum LinuxActionCommand: Equatable {
    case playSound(String)
    case copyText(String)
    case speakText(String)
    case openURL(URL)
    case launchApplication(String)
    case openItem(String)
    case runShellCommand(String)
    case takeScreenshot(interactive: Bool)
    case unsupported(String)
}

public enum LinuxActionPlanner {
    public static func command(for action: ZoneActionConfiguration) -> LinuxActionCommand? {
        switch action.kind {
        case .openApplication:
            let target = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? nil : .launchApplication(target)
        case .openItem:
            let target = action.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return target.isEmpty ? nil : .openItem(target)
        case .runShortcut:
            return .unsupported("macOS Shortcuts are not available on Linux. Assign a shell command instead.")
        default:
            break
        }
        guard let shared = LocalActionPlanner.command(for: action) else { return nil }
        switch shared {
        case .playSound(let name): return .playSound(name)
        case .copyText(let text): return .copyText(text)
        case .speakText(let text): return .speakText(text)
        case .openURL(let url): return .openURL(url)
        case .runShellCommand(let command): return .runShellCommand(command)
        case .takeScreenshot(let interactive): return .takeScreenshot(interactive: interactive)
        case .runShortcut, .openApplication, .openItem:
            return nil
        }
    }

    /// Short human description used by `holo actions`.
    public static func summary(for action: ZoneActionConfiguration) -> String {
        switch action.kind {
        case .none: return "Visual only"
        case .sound: return "Play sound \(action.soundName)"
        case .copyText: return "Copy text \(quoted(action.text))"
        case .speakText: return "Speak text \(quoted(action.text))"
        case .openURL: return "Open website \(action.text)"
        case .runShortcut: return "Run Shortcut \(quoted(action.text)) (macOS only)"
        case .openApplication: return "Open app \(action.text.isEmpty ? "(not set)" : action.text)"
        case .openItem: return "Open \(action.text.isEmpty ? "(not set)" : action.text)"
        case .runShellCommand: return "Run \(quoted(action.text))"
        case .screenshotClipboard: return "Screenshot to clipboard"
        case .screenshotSelection: return "Capture selection to clipboard"
        }
    }

    private static func quoted(_ text: String) -> String {
        let flattened = text.replacingOccurrences(of: "\n", with: " ")
        let clipped = flattened.count > 60 ? String(flattened.prefix(57)) + "…" : flattened
        return "\"\(clipped)\""
    }
}

public enum LinuxActionError: Error, LocalizedError, Equatable {
    case missingTool(String)
    case notFound(String)
    case unsupported(String)
    case launchFailed(String)
    case exited(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .missingTool(let hint): return hint
        case .notFound(let item): return "\(item) does not exist."
        case .unsupported(let reason): return reason
        case .launchFailed(let detail): return detail
        case .exited(let name, let status): return "\(name) exited with status \(status)."
        }
    }
}

/// The desktop session the service runs in, used to pick helper tools.
public struct DesktopSession: Equatable, Sendable {
    public var isWayland: Bool
    public var isX11: Bool
    public var desktop: String

    public init(environment: [String: String] = ProcessInfo.processInfo.environment) {
        isWayland = !(environment["WAYLAND_DISPLAY"] ?? "").isEmpty
        isX11 = !(environment["DISPLAY"] ?? "").isEmpty
        desktop = (environment["XDG_CURRENT_DESKTOP"] ?? "").lowercased()
    }

    public var isGNOME: Bool { desktop.contains("gnome") }
    public var isKDE: Bool { desktop.contains("kde") }
}

/// Builds argv vectors for each command. Separated from execution so the
/// choices can be unit tested.
public struct LinuxActionResolver {
    public var session: DesktopSession
    public var isAvailable: (String) -> Bool
    public var fileExists: (String) -> Bool
    public var soundDirectories: [String]
    public var applicationDirectories: [String]
    public var home: String

    public init(
        session: DesktopSession = DesktopSession(),
        isAvailable: @escaping (String) -> Bool = { ToolLocator.isAvailable($0) },
        fileExists: @escaping (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.session = session
        self.isAvailable = isAvailable
        self.fileExists = fileExists
        let home = environment["HOME"] ?? NSHomeDirectory()
        self.home = home
        let dataHome = environment["XDG_DATA_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.local/share"
        let dataDirs = (environment["XDG_DATA_DIRS"].flatMap { $0.isEmpty ? nil : $0 } ?? "/usr/local/share:/usr/share")
            .split(separator: ":").map(String.init)
        let roots = [dataHome] + dataDirs
        self.soundDirectories = roots.map { $0 + "/sounds/freedesktop/stereo" }
        self.applicationDirectories = roots.map { $0 + "/applications" }
    }

    /// One process to start: argv plus optional data for its stdin.
    public struct Invocation: Equatable, Sendable {
        public var arguments: [String]
        public var input: String?
        public var name: String

        public init(_ arguments: [String], input: String? = nil, name: String) {
            self.arguments = arguments
            self.input = input
            self.name = name
        }
    }

    /// Sound names from the macOS defaults map to freedesktop theme sounds.
    static let soundAliases = [
        "tink": "message", "glass": "complete", "ping": "bell", "pop": "message",
        "purr": "message-new-instant", "hero": "complete", "submarine": "bell",
        "funk": "dialog-warning", "basso": "dialog-error", "blow": "bell",
        "bottle": "message", "frog": "message", "morse": "message", "sosumi": "dialog-warning"
    ]

    public func resolveSoundFile(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded = expandHome(trimmed)
        if expanded.contains("/") { return fileExists(expanded) ? expanded : nil }
        var candidates = [trimmed]
        if let alias = Self.soundAliases[trimmed.lowercased()] { candidates.append(alias) }
        for candidate in candidates {
            for directory in soundDirectories {
                for ext in ["oga", "ogg", "wav"] {
                    let path = "\(directory)/\(candidate).\(ext)"
                    if fileExists(path) { return path }
                }
            }
        }
        return nil
    }

    public func expandHome(_ path: String) -> String {
        if path == "~" { return home }
        if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
        return path
    }

    public func desktopEntryPath(_ id: String) -> String? {
        if id.hasSuffix(".desktop"), id.contains("/") { return fileExists(id) ? id : nil }
        let file = id.hasSuffix(".desktop") ? id : id + ".desktop"
        for directory in applicationDirectories {
            let path = directory + "/" + file
            if fileExists(path) { return path }
        }
        return nil
    }

    public func invocations(for command: LinuxActionCommand) throws -> [Invocation] {
        switch command {
        case .unsupported(let reason):
            throw LinuxActionError.unsupported(reason)

        case .playSound(let name):
            if let file = resolveSoundFile(name) {
                for player in ["pw-play", "paplay"] where isAvailable(player) {
                    return [Invocation([player, file], name: "Sound")]
                }
                if isAvailable("canberra-gtk-play") {
                    return [Invocation(["canberra-gtk-play", "-f", file], name: "Sound")]
                }
                if file.hasSuffix(".wav"), isAvailable("aplay") {
                    return [Invocation(["aplay", "-q", file], name: "Sound")]
                }
                throw LinuxActionError.missingTool("No sound player found. Install pipewire-bin (pw-play) or pulseaudio-utils (paplay).")
            }
            if isAvailable("canberra-gtk-play") {
                return [Invocation(["canberra-gtk-play", "-i", name], name: "Sound")]
            }
            throw LinuxActionError.notFound("Sound \"\(name)\"")

        case .copyText(let text):
            if session.isWayland, isAvailable("wl-copy") {
                return [Invocation(["wl-copy"], input: text, name: "Copy text")]
            }
            if session.isX11 {
                if isAvailable("xclip") { return [Invocation(["xclip", "-selection", "clipboard"], input: text, name: "Copy text")] }
                if isAvailable("xsel") { return [Invocation(["xsel", "--clipboard", "--input"], input: text, name: "Copy text")] }
            }
            if !session.isWayland && !session.isX11 {
                throw LinuxActionError.missingTool("No graphical session is visible to Holo (WAYLAND_DISPLAY and DISPLAY are unset).")
            }
            throw LinuxActionError.missingTool(session.isWayland
                ? "Copying needs wl-clipboard: sudo apt install wl-clipboard"
                : "Copying needs xclip: sudo apt install xclip")

        case .speakText(let text):
            if isAvailable("spd-say") {
                // spd-say treats a leading dash as an option.
                let safe = text.hasPrefix("-") ? " " + text : text
                return [Invocation(["spd-say", "--", safe], name: "Speak text")]
            }
            for engine in ["espeak-ng", "espeak"] where isAvailable(engine) {
                return [Invocation([engine, "--stdin"], input: text, name: "Speak text")]
            }
            throw LinuxActionError.missingTool("Speaking needs speech-dispatcher (spd-say) or espeak-ng: sudo apt install espeak-ng")

        case .openURL(let url):
            return [try opener(for: url.absoluteString, name: "Open website")]

        case .openItem(let item):
            let path = expandHome(item)
            guard fileExists(path) else { throw LinuxActionError.notFound(path) }
            return [try opener(for: path, name: "Open file")]

        case .launchApplication(let target):
            let expanded = expandHome(target)
            if let entry = desktopEntryPath(expanded) {
                let id = URL(fileURLWithPath: entry).deletingPathExtension().lastPathComponent
                if isAvailable("gtk-launch") { return [Invocation(["gtk-launch", id], name: "Open app")] }
                if isAvailable("gio") { return [Invocation(["gio", "launch", entry], name: "Open app")] }
                if isAvailable("dex") { return [Invocation(["dex", entry], name: "Open app")] }
                throw LinuxActionError.missingTool("Launching desktop apps needs gtk-launch or gio (libglib2.0-bin).")
            }
            if expanded.contains("/") {
                guard FileManager.default.isExecutableFile(atPath: expanded) else { throw LinuxActionError.notFound(expanded) }
                return [Invocation([expanded], name: "Open app")]
            }
            if isAvailable(expanded) { return [Invocation([expanded], name: "Open app")] }
            throw LinuxActionError.notFound("Application \"\(target)\" (no desktop entry or executable with that name)")

        case .runShellCommand(let command):
            if isAvailable("bash") { return [Invocation(["bash", "-lc", command], name: "Shell command")] }
            return [Invocation(["/bin/sh", "-c", command], name: "Shell command")]

        case .takeScreenshot(let interactive):
            return [try screenshotInvocation(interactive: interactive)]
        }
    }

    private func opener(for target: String, name: String) throws -> Invocation {
        if isAvailable("xdg-open") { return Invocation(["xdg-open", target], name: name) }
        if isAvailable("gio") { return Invocation(["gio", "open", target], name: name) }
        throw LinuxActionError.missingTool("Opening needs xdg-open (xdg-utils) or gio (libglib2.0-bin).")
    }

    private func screenshotInvocation(interactive: Bool) throws -> Invocation {
        let name = interactive ? "Selection capture" : "Screenshot"
        if session.isGNOME || (!session.isKDE && isAvailable("gnome-screenshot") && !isAvailable("grim")) {
            if isAvailable("gnome-screenshot") {
                return Invocation(["gnome-screenshot", "-c"] + (interactive ? ["-a"] : []), name: name)
            }
            if isAvailable("holo-screenshot-portal") {
                return Invocation(["holo-screenshot-portal"] + (interactive ? ["--interactive"] : []), name: name)
            }
        }
        if session.isKDE, isAvailable("spectacle") {
            return Invocation(["spectacle", "-b", "-n", "-c"] + (interactive ? ["-r"] : ["-f"]), name: name)
        }
        if session.isWayland, isAvailable("grim"), isAvailable("wl-copy") {
            if interactive {
                guard isAvailable("slurp") else {
                    throw LinuxActionError.missingTool("Selection capture needs slurp: sudo apt install slurp")
                }
                return Invocation(["/bin/sh", "-c", "grim -g \"$(slurp)\" - | wl-copy --type image/png"], name: name)
            }
            return Invocation(["/bin/sh", "-c", "grim - | wl-copy --type image/png"], name: name)
        }
        if session.isX11, isAvailable("maim"), isAvailable("xclip") {
            return Invocation(["/bin/sh", "-c", "maim \(interactive ? "-s " : "")| xclip -selection clipboard -t image/png"], name: name)
        }
        if isAvailable("holo-screenshot-portal") {
            return Invocation(["holo-screenshot-portal"] + (interactive ? ["--interactive"] : []), name: name)
        }
        throw LinuxActionError.missingTool(session.isGNOME
            ? "Screenshots on GNOME need gnome-screenshot (sudo apt install gnome-screenshot) or python3-gi for the portal helper."
            : "No screenshot tool found (gnome-screenshot, spectacle, grim + wl-clipboard, or maim + xclip).")
    }
}

/// Starts action processes without waiting for them. Failures that happen
/// after launch are reported through `onAsyncError`.
public final class LinuxActionDispatcher {
    public var resolver: LinuxActionResolver
    public var onAsyncError: ((String) -> Void)?
    private let lock = NSLock()
    private var running: [UUID: Process] = [:]
    private var speech: Process?

    public init(resolver: LinuxActionResolver = LinuxActionResolver()) {
        self.resolver = resolver
    }

    public func perform(_ action: ZoneActionConfiguration) throws {
        guard let command = LinuxActionPlanner.command(for: action) else { return }
        let invocations = try resolver.invocations(for: command)
        for invocation in invocations {
            if case .speakText = command { stopSpeech() }
            let process = try launch(invocation)
            if case .speakText = command {
                lock.lock()
                speech = process
                lock.unlock()
            }
        }
    }

    private func stopSpeech() {
        lock.lock()
        let previous = speech
        speech = nil
        lock.unlock()
        if let previous, previous.isRunning { previous.terminate() }
    }

    @discardableResult
    private func launch(_ invocation: LinuxActionResolver.Invocation) throws -> Process {
        guard let executable = ToolLocator.find(invocation.arguments[0]) else {
            throw LinuxActionError.missingTool("\(invocation.arguments[0]) is not installed.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = Array(invocation.arguments.dropFirst())
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let inputPipe: Pipe?
        if invocation.input != nil {
            let pipe = Pipe()
            process.standardInput = pipe
            inputPipe = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
            inputPipe = nil
        }
        let identifier = UUID()
        let name = invocation.name
        process.terminationHandler = { [weak self] process in
            guard let self else { return }
            self.lock.lock()
            self.running.removeValue(forKey: identifier)
            self.lock.unlock()
            let status = process.terminationStatus
            if process.terminationReason == .exit, status != 0 {
                self.onAsyncError?(LinuxActionError.exited(name, status).localizedDescription)
            }
        }
        lock.lock()
        running[identifier] = process
        lock.unlock()
        do {
            try process.run()
        } catch {
            lock.lock()
            running.removeValue(forKey: identifier)
            lock.unlock()
            throw LinuxActionError.launchFailed("\(name) could not start: \(error.localizedDescription)")
        }
        if let inputPipe, let text = invocation.input {
            let handle = inputPipe.fileHandleForWriting
            handle.write(Data(text.utf8))
            try? handle.close()
        }
        return process
    }
}

/// Desktop notifications through org.freedesktop.Notifications via gdbus,
/// which ships with every GNOME installation.
public final class DesktopNotifier {
    private let runner: CommandRunning
    private let queue = DispatchQueue(label: "holo.notifier")
    private var lastID: UInt32 = 0

    public init(runner: CommandRunning = ProcessCommandRunner()) {
        self.runner = runner
    }

    public static var isAvailable: Bool {
        ToolLocator.isAvailable("gdbus") || ToolLocator.isAvailable("notify-send")
    }

    /// Posts asynchronously. Transient notifications replace the previous one
    /// so a burst of taps does not pile up in the notification list.
    public func notify(summary: String, body: String, transient: Bool = true, urgent: Bool = false) {
        queue.async { [self] in
            if ToolLocator.isAvailable("gdbus") {
                let hints = "{'transient': <\(transient)>, 'urgency': <byte \(urgent ? 2 : 1)>, 'desktop-entry': <'holo'>}"
                let replaces = transient ? lastID : 0
                let result = runner.run("gdbus", [
                    "call", "--session",
                    "--dest", "org.freedesktop.Notifications",
                    "--object-path", "/org/freedesktop/Notifications",
                    "--method", "org.freedesktop.Notifications.Notify",
                    "Holo", "\(replaces)", "input-tablet", summary, body, "[]", hints,
                    transient ? "1500" : "-1"
                ], timeout: 3)
                if let output = result?.output, result?.status == 0, let id = Self.parseNotificationID(output) {
                    if transient { lastID = id }
                    return
                }
            }
            if ToolLocator.isAvailable("notify-send") {
                var arguments = ["--app-name=Holo", "--icon=input-tablet"]
                if transient { arguments += ["--transient", "--expire-time=1500"] }
                if urgent { arguments.append("--urgency=critical") }
                _ = runner.run("notify-send", arguments + [summary, body], timeout: 3)
            }
        }
    }

    /// Parses gdbus's "(uint32 42,)" reply.
    public static func parseNotificationID(_ output: String) -> UInt32? {
        let digits = output.split(whereSeparator: { !$0.isNumber })
        return digits.last.flatMap { UInt32($0) }
    }
}

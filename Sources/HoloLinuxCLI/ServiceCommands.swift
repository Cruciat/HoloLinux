import Foundation
import HoloCore
import HoloLinux
#if canImport(Glibc)
import Glibc
#endif

enum ServiceCommands {
    static let runHelp = """
    Usage: holo run [--allow-external-input] [--allow-external-output]

    Listens with the active profile and runs the assigned actions until
    stopped. This is what the systemd user service runs:

      systemctl --user enable --now holo     start now and at every login
      journalctl --user -u holo -f           follow its log

    The listener releases the microphone while `holo calibrate`, `evaluate`,
    `compare`, or `monitor` is running, or after `holo pause`.
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        guard let options = try parse(
            arguments,
            flags: ["allow-external-input", "allow-external-output"],
            help: runHelp
        ) else { return 0 }
        let paths = HoloPaths.standard()
        let control = try serviceControl(paths)
        var serviceOptions = LiveService.Options()
        serviceOptions.allowExternalInput = options.has("allow-external-input")
        serviceOptions.allowExternalOutput = options.has("allow-external-output")
        let underSystemd = ProcessInfo.processInfo.environment["INVOCATION_ID"] != nil
        let timestamps = terminal.isOutputTTY && !underSystemd
        let service = LiveService(
            paths: paths,
            options: serviceOptions,
            control: control,
            log: { message in
                terminal.line(timestamps ? terminal.dim(clock()) + "  " + message : message)
            }
        )
        return service.run()
    }

    static func pause(_ arguments: [String]) throws -> Int32 {
        guard try parse(arguments, help: "Usage: holo pause\n\nPauses the background service and releases the microphone until `holo resume`.") != nil else { return 0 }
        let control = try serviceControl()
        try control.setPausedByUser(true)
        terminal.line("Paused. The service releases the microphone within a second. Resume with `holo resume`.")
        return 0
    }

    static func resume(_ arguments: [String]) throws -> Int32 {
        guard try parse(arguments, help: "Usage: holo resume\n\nResumes the background service after `holo pause`.") != nil else { return 0 }
        let control = try serviceControl()
        try control.setPausedByUser(false)
        terminal.line(control.runningServicePID() == nil
            ? "Resumed. Note: the service is not running — start it with `systemctl --user start holo`."
            : "Resumed.")
        return 0
    }

    static func status(_ arguments: [String]) throws -> Int32 {
        guard try parse(arguments, help: "Usage: holo status") != nil else { return 0 }
        let paths = HoloPaths.standard()
        let control = try serviceControl(paths)
        let library = try? ProfileLibrary(paths: paths)
        if let pid = control.runningServicePID() {
            var state = terminal.green("running") + " (pid \(pid))"
            if let guided = control.activeGuidedSession() {
                state += ", paused for a guided session (\(guided))"
            } else if control.isPausedByUser {
                state += ", " + terminal.yellow("paused") + " (`holo resume` to continue)"
            }
            terminal.line("Service: \(state)")
        } else {
            terminal.line("Service: " + terminal.yellow("not running") + " — `systemctl --user enable --now holo` to start it")
            if control.isPausedByUser { terminal.line("         (also paused; `holo resume` clears it)") }
        }
        if let profile = library?.activeProfile {
            terminal.line("Profile: \"\(profile.name)\" • \(profile.sensingStrategy.displayName)")
        } else {
            terminal.line("Profile: none — run `holo calibrate`")
        }
        terminal.line(terminal.dim("Log:     journalctl --user -u holo -f"))
        return control.runningServicePID() == nil ? 3 : 0
    }
}

enum CheckCommand {
    static let help = """
    Usage: holo check [--device DEV] [--strategy S]

    Reports the microphone route Holo would use, whether it is the laptop's
    built-in microphone, which helper tools for actions are installed, your
    profiles, and the background service. Exits non-zero when the
    microphone route would be refused.
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        guard let options = try parse(arguments, values: ["device", "strategy"], help: help) else { return 0 }
        let library = try openLibrary()
        let control = try serviceControl(library.paths)
        let active = library.activeProfile
        let strategy = try options.value("strategy").map(StrategyArgument.parse) ?? active?.sensingStrategy ?? .passive
        let saved = options.value("device") == nil ? active.map(library.captureSettings(for:)) : nil
        let choice = chooseCapture(
            device: options.value("device"),
            channels: nil,
            strategy: strategy,
            saved: saved,
            library: library,
            allowExternalInput: false,
            allowExternalOutput: false
        )

        terminal.line(terminal.bold("Audio"))
        describeRoute(choice, strategy: strategy)
        if let issue = choice.check.issueDescription {
            terminal.line(terminal.red("✗ ") + issue)
        } else {
            terminal.line(terminal.green("✓ ") + "Holo can use this microphone" + (strategy == .passive ? "." : " and speaker."))
        }

        terminal.line()
        terminal.line(terminal.bold("Desktop"))
        let session = DesktopSession()
        let kind = session.isWayland ? "Wayland" : session.isX11 ? "X11" : "none detected"
        terminal.line("Session:   \(kind)\(session.desktop.isEmpty ? "" : " (\(session.desktop))")")
        let tools: [(String, [String], String)] = [
            ("Notifications", ["gdbus", "notify-send"], "libglib2.0-bin"),
            ("Open URL/file", ["xdg-open", "gio"], "xdg-utils"),
            ("Open app", ["gtk-launch", "gio"], "libglib2.0-bin"),
            ("Copy text", session.isWayland ? ["wl-copy"] : ["xclip", "xsel"], session.isWayland ? "wl-clipboard" : "xclip"),
            ("Speak text", ["spd-say", "espeak-ng"], "espeak-ng"),
            ("Play sound", ["pw-play", "paplay", "canberra-gtk-play"], "pipewire-bin"),
            ("Screenshot", session.isGNOME ? ["gnome-screenshot", "holo-screenshot-portal"] : ["gnome-screenshot", "spectacle", "grim", "maim"], session.isGNOME ? "gnome-screenshot" : "grim"),
            ("Mic routing", ["wpctl"], "wireplumber")
        ]
        for (name, candidates, package) in tools {
            if let found = candidates.first(where: { ToolLocator.isAvailable($0) }) {
                terminal.line("  " + terminal.green("✓ ") + name.padding(toLength: 15, withPad: " ", startingAt: 0) + terminal.dim(found))
            } else {
                terminal.line("  " + terminal.yellow("– ") + name.padding(toLength: 15, withPad: " ", startingAt: 0) + terminal.dim("missing (sudo apt install \(package))"))
            }
        }

        terminal.line()
        terminal.line(terminal.bold("Profiles"))
        ProfilesCommand.list(library)

        terminal.line()
        terminal.line(terminal.bold("Service"))
        if let pid = control.runningServicePID() {
            let paused = control.activeGuidedSession() != nil || control.isPausedByUser
            terminal.line("  running (pid \(pid))" + (paused ? ", paused" : ""))
        } else {
            terminal.line("  not running — `systemctl --user enable --now holo`")
        }
        return choice.check.isUsable ? 0 : 2
    }
}

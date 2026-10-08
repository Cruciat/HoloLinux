import Foundation
import HoloCore
import HoloLinux
#if canImport(Glibc)
import Glibc
#endif

enum HoloVersion {
    static let string = "0.1.0 (Linux)"
}

struct CLIError: Error {
    var message: String
    var status: Int32

    init(_ message: String, status: Int32 = 1) {
        self.message = message
        self.status = status
    }
}

let terminal = Terminal.shared

func parse(_ arguments: [String], values: Set<String> = [], flags: Set<String> = [], help: String) throws -> ParsedArguments? {
    if arguments.contains("--help") || arguments.contains("-h") {
        terminal.line(help)
        return nil
    }
    do {
        return try ParsedArguments(arguments, valueOptions: values, flagOptions: flags)
    } catch let error as ArgumentError {
        throw CLIError(error.message + "\n\n" + help, status: 64)
    }
}

func openLibrary(_ paths: HoloPaths = HoloPaths.standard()) throws -> ProfileLibrary {
    do {
        return try ProfileLibrary(paths: paths)
    } catch {
        throw CLIError("Could not open Holo's data in \(paths.dataRoot.path): \(error.localizedDescription)")
    }
}

func serviceControl(_ paths: HoloPaths = HoloPaths.standard()) throws -> ServiceControl {
    do {
        return try ServiceControl(directory: paths.runtimeDirectory)
    } catch {
        throw CLIError("Could not use the runtime directory \(paths.runtimeDirectory.path): \(error.localizedDescription)")
    }
}

func profile(named query: String?, in library: ProfileLibrary) throws -> HoloProfile {
    if let query {
        guard let match = library.find(query) else {
            throw CLIError("No profile matches \"\(query)\". Run `holo profiles` to list them.")
        }
        return match
    }
    guard let active = library.activeProfile else {
        throw CLIError("No desk profile yet. Run `holo calibrate` first.")
    }
    return active
}

func percent(_ value: Double) -> String {
    "\(Int((value * 100).rounded()))%"
}

func zoneHint(_ zone: DeskZone) -> String {
    let side = zone.isLeft ? "left" : "right"
    let edge = zone.verticalIndex == 0 ? "display (rear) edge" : "keyboard (front) edge"
    return "tap the desk to the \(side) of the laptop, near the \(edge)"
}

func progressBar(_ count: Int, of total: Int, width: Int = 10) -> String {
    let filled = total == 0 ? 0 : min(width, Int((Double(count) / Double(total) * Double(width)).rounded()))
    return String(repeating: "█", count: filled) + String(repeating: "·", count: width - filled)
}

func clock() -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from: Date())
}

// MARK: Capture setup

struct CaptureChoice {
    var settings: CaptureSettings
    var check: RouteCheck
}

/// Picks the capture settings for a session and validates the route.
func chooseCapture(
    device: String?,
    channels: Int?,
    strategy: SensingStrategy,
    saved: CaptureSettings?,
    library: ProfileLibrary,
    allowExternalInput: Bool,
    allowExternalOutput: Bool,
    inspector: RouteInspector = RouteInspector()
) -> CaptureChoice {
    let chosenDevice = device ?? saved?.device ?? library.config.defaultDevice
    // A profile calibrated on an explicitly allowed external device keeps that permission.
    let allowInput = allowExternalInput || (saved?.allowsExternalInput ?? false)
    let allowOutput = allowExternalOutput || (saved?.allowsExternalOutput ?? false)
    var settings = CaptureSettings(
        device: chosenDevice,
        channels: channels ?? saved?.channels ?? 1,
        allowsExternalInput: allowInput,
        allowsExternalOutput: allowOutput
    )
    let check = inspector.check(
        settings: settings,
        strategy: strategy,
        allowExternalInput: allowInput,
        allowExternalOutput: allowOutput
    )
    if channels == nil, saved == nil {
        if let detected = check.route.input?.channels {
            settings.channels = min(max(detected, 1), CaptureSettings.maximumChannels)
        } else if AlsaCardInspector.cardReference(fromDevice: chosenDevice) != nil {
            settings.channels = 2
        }
    }
    return CaptureChoice(settings: settings, check: check)
}

func describeRoute(_ choice: CaptureChoice, strategy: SensingStrategy) {
    if let input = choice.check.route.input {
        let channels = input.channels.map { ", \($0) channel\($0 == 1 ? "" : "s") available" } ?? ""
        let builtIn = input.isBuiltIn == true ? terminal.green(input.builtInDescription)
            : input.isBuiltIn == false ? terminal.red(input.builtInDescription) : terminal.yellow(input.builtInDescription)
        terminal.line("Microphone: \(input.name) — \(builtIn)\(channels)")
        terminal.line(terminal.dim("            \(input.identifier) (\(input.reason))"))
    } else {
        terminal.line("Microphone: \(choice.settings.device)")
    }
    if strategy != .passive, let output = choice.check.route.output {
        let builtIn = output.isBuiltIn == true ? terminal.green(output.builtInDescription)
            : output.isBuiltIn == false ? terminal.red(output.builtInDescription) : terminal.yellow(output.builtInDescription)
        terminal.line("Speakers:   \(output.name) — \(builtIn)")
    }
    terminal.line(terminal.dim("Capture:    device \"\(choice.settings.device)\", \(choice.settings.channels) channel\(choice.settings.channels == 1 ? "" : "s"), \(Int(choice.settings.sampleRate)) Hz"))
    for warning in choice.check.warnings {
        terminal.warning(warning)
    }
}

func requireUsableRoute(_ choice: CaptureChoice) throws {
    if let message = choice.check.issueDescription {
        throw CLIError(message, status: 2)
    }
}

// MARK: Guided session plumbing

/// Shared machinery for interactive sessions: the event loop, raw keys,
/// Ctrl-C handling, the capture engine, and pausing the background service.
final class GuidedRunner {
    let loop = EventLoop()
    let control: ServiceControl
    private(set) var settings: CaptureSettings
    private(set) var engine: CaptureEngine
    private(set) var cancelled = false

    var onObservation: ((TapObservation) -> Void)?
    var onLevel: ((Double, Double) -> Void)?
    var onKey: ((UInt8) -> Void)?
    var onTick: ((Double) -> Void)?
    var onCaptureFailure: ((String) -> Void)?

    init(name: String, settings: CaptureSettings, control: ServiceControl, reportsLevel: Bool = false) throws {
        self.control = control
        self.settings = settings
        self.engine = CaptureEngine(settings: settings)
        engine.reportsLevel = reportsLevel
        guard control.beginGuidedSession(name: name) else {
            let other = control.activeGuidedSession() ?? "another session"
            throw CLIError("Another Holo session is already using the microphone (\(other)). Finish it first.")
        }
        if let pid = control.runningServicePID() {
            terminal.line(terminal.dim("The background service (pid \(pid)) pauses and releases the microphone until this session ends."))
            // Give the service a moment to let go of an exclusive device.
            usleep(800_000)
        }
    }

    deinit {
        engine.stop()
        control.releaseGuidedSession()
    }

    func start(strategy: SensingStrategy) throws {
        do {
            try startEngine(strategy: strategy)
        } catch let error as AlsaError where settings.channels > 1 {
            // Some raw devices only offer mono capture.
            if case .configure = error {
                settings.channels = 1
                let reportsLevel = engine.reportsLevel
                engine = CaptureEngine(settings: settings)
                engine.reportsLevel = reportsLevel
                try startEngine(strategy: strategy)
                terminal.warning("The device does not offer two channels; capturing mono.")
            } else {
                throw error
            }
        }
    }

    private func startEngine(strategy: SensingStrategy) throws {
        try engine.start(strategy: strategy) { [weak self] event in
            self?.loop.post { self?.deliver(event) }
        }
    }

    func stopCapture() {
        engine.stop()
    }

    private func deliver(_ event: CaptureEngine.Event) {
        switch event {
        case .observation(let observation, let generation):
            guard engine.isCurrent(generation) else { return }
            onObservation?(observation)
        case .level(let level, let floor, let generation):
            guard engine.isCurrent(generation) else { return }
            onLevel?(level, floor)
        case .failed(let message, let generation):
            guard engine.isCurrent(generation) else { return }
            engine.stop()
            if let onCaptureFailure {
                onCaptureFailure(message)
            } else {
                terminal.error("Capture stopped: \(message)")
                finish()
            }
        }
    }

    /// Runs the loop until `finish()` or Ctrl-C.
    func run() {
        terminal.enableRawInput()
        loop.watchesStandardInput = true
        loop.handleSignals([SIGINT, SIGTERM, SIGHUP])
        loop.onSignal = { [weak self] _ in
            self?.cancelled = true
            self?.loop.stop()
        }
        loop.onKey = { [weak self] key in self?.onKey?(key) }
        loop.onStandardInputClosed = { }
        loop.onTick = { [weak self] in self?.onTick?(HoloClock.now()) }
        loop.run()
        engine.stop()
        terminal.restoreInput()
    }

    func finish() {
        loop.stop()
    }

    func cancel() {
        cancelled = true
        loop.stop()
    }
}

extension UInt8 {
    var character: Character { Character(UnicodeScalar(self)) }
    var isEnter: Bool { self == 10 || self == 13 }
}

import Foundation
import HoloCore
import HoloLinux

enum ActionsCommand {
    static var help: String {
        """
        Usage:
          holo actions [--profile NAME]                 list the four zone actions
          holo actions set ZONE KIND [VALUE...]         assign an action
          holo actions clear ZONE                       back to visual only
          holo actions test ZONE                        run a zone's action now

        Zones: \(ZoneArgument.help)

        Kinds:
        \(ActionArgument.kinds.map { "  " + $0.usage }.joined(separator: "\n"))

        Examples:
          holo actions set lr url https://calendar.google.com
          holo actions set lf app org.gnome.Nautilus
          holo actions set rr shell 'playerctl play-pause'
          holo actions set rf open ~/Documents/notes.md
          holo actions set lr sound complete

        Shell commands run automatically on every accepted tap, so make them safe
        to repeat. The running service picks up changes within a second.
        """
    }

    static func run(_ arguments: [String]) throws -> Int32 {
        // Everything after `set ZONE KIND` is the action's value, verbatim, so
        // shell commands may contain their own --options.
        var head = arguments
        var value: [String] = []
        if let setIndex = arguments.firstIndex(of: "set"), arguments.count > setIndex + 3 {
            head = Array(arguments[...(setIndex + 2)])
            value = Array(arguments[(setIndex + 3)...])
            if value.first == "--" { value.removeFirst() }
        }
        guard let options = try parse(head, values: ["profile"], help: help) else { return 0 }
        var library = try openLibrary()
        let selected = try profile(named: options.value("profile"), in: library)
        let words = options.positionals + value
        guard let verb = words.first else {
            list(selected)
            return 0
        }
        switch verb {
        case "list":
            list(selected)
            return 0
        case "set":
            guard words.count >= 3 else { throw CLIError("Usage: holo actions set ZONE KIND [VALUE...]", status: 64) }
            let zone = try argument { try ZoneArgument.parse(words[1]) }
            let action = try argument { try ActionArgument.parse(kind: words[2], value: Array(words.dropFirst(3))) }
            try save(action, for: zone, in: selected, library: &library)
            terminal.line("\(zone.displayName): \(LinuxActionPlanner.summary(for: action))")
            warnIfUnavailable(action)
            return 0
        case "clear":
            guard words.count == 2 else { throw CLIError("Usage: holo actions clear ZONE", status: 64) }
            let zone = try argument { try ZoneArgument.parse(words[1]) }
            try save(ZoneActionConfiguration(kind: .none), for: zone, in: selected, library: &library)
            terminal.line("\(zone.displayName): Visual only")
            return 0
        case "test":
            guard words.count == 2 else { throw CLIError("Usage: holo actions test ZONE", status: 64) }
            let zone = try argument { try ZoneArgument.parse(words[1]) }
            let action = selected.action(for: zone)
            terminal.line("Testing \(zone.displayName): \(LinuxActionPlanner.summary(for: action))")
            let dispatcher = LinuxActionDispatcher()
            var asyncError: String?
            let finished = DispatchSemaphore(value: 0)
            dispatcher.onAsyncError = { message in
                asyncError = message
                finished.signal()
            }
            do {
                try dispatcher.perform(action)
            } catch {
                throw CLIError("The action failed: \(error.localizedDescription)")
            }
            // Report quick failures (missing file, bad command) before exiting.
            _ = finished.wait(timeout: .now() + 1.5)
            if let asyncError { throw CLIError("The action failed: \(asyncError)") }
            if action.kind == .none { terminal.line("Visual only: no side effect.") }
            return 0
        default:
            throw CLIError("Unknown actions command \"\(verb)\".\n\n" + help, status: 64)
        }
    }

    private static func argument<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let error as ArgumentError { throw CLIError(error.message, status: 64) }
    }

    static func list(_ profile: HoloProfile) {
        terminal.line(terminal.bold("Actions") + " • \"\(profile.name)\"")
        for zone in DeskZone.allCases {
            let action = profile.action(for: zone)
            terminal.line("  \(zone.shortName)  \(zone.displayName.padding(toLength: 12, withPad: " ", startingAt: 0)) \(LinuxActionPlanner.summary(for: action))")
        }
    }

    private static func save(_ action: ZoneActionConfiguration, for zone: DeskZone, in profile: HoloProfile, library: inout ProfileLibrary) throws {
        var updated = profile
        guard let index = updated.zones.firstIndex(where: { $0.zone == zone }) else {
            throw CLIError("The profile has no \(zone.displayName) zone.")
        }
        updated.zones[index].action = action
        do {
            try library.save(updated, capture: nil, makeActive: false)
        } catch {
            throw CLIError("Could not save the profile: \(error.localizedDescription)")
        }
    }

    static func warnIfUnavailable(_ action: ZoneActionConfiguration) {
        guard let command = LinuxActionPlanner.command(for: action) else { return }
        do {
            _ = try LinuxActionResolver().invocations(for: command)
        } catch {
            terminal.warning("This action cannot run on this system yet: \(error.localizedDescription)")
        }
    }
}

enum ProfilesCommand {
    static let help = """
    Usage:
      holo profiles                     list profiles (* marks the active one)
      holo profiles use NAME|ID         make a profile active
      holo profiles show [NAME|ID]      details, capture settings, actions, latest accuracy
      holo profiles rename NAME|ID NEW  rename a profile
      holo profiles delete NAME|ID --yes
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        guard let options = try parse(arguments, flags: ["yes"], help: help) else { return 0 }
        var library = try openLibrary()
        let words = options.positionals
        switch words.first ?? "list" {
        case "list":
            list(library)
        case "use":
            guard words.count == 2 else { throw CLIError("Usage: holo profiles use NAME|ID", status: 64) }
            let selected = try profile(named: words[1], in: library)
            try library.activate(selected)
            terminal.line("Active profile: \"\(selected.name)\". The service switches within a second.")
        case "show":
            let selected = try profile(named: words.count > 1 ? words[1] : nil, in: library)
            show(selected, library: library)
        case "rename":
            guard words.count >= 3 else { throw CLIError("Usage: holo profiles rename NAME|ID NEW-NAME", status: 64) }
            var selected = try profile(named: words[1], in: library)
            selected.name = words.dropFirst(2).joined(separator: " ")
            try library.save(selected, capture: nil, makeActive: false)
            terminal.line("Renamed to \"\(selected.name)\".")
        case "delete":
            guard words.count == 2 else { throw CLIError("Usage: holo profiles delete NAME|ID --yes", status: 64) }
            let selected = try profile(named: words[1], in: library)
            guard options.has("yes") else {
                throw CLIError("This deletes \"\(selected.name)\" and its calibration. Add --yes to confirm.", status: 64)
            }
            try library.delete(selected)
            terminal.line("Deleted \"\(selected.name)\".")
        default:
            throw CLIError("Unknown profiles command \"\(words[0])\".\n\n" + help, status: 64)
        }
        return 0
    }

    static func list(_ library: ProfileLibrary) {
        guard !library.profiles.isEmpty else {
            terminal.line("No desk profiles yet. Run `holo calibrate`.")
            return
        }
        let reports = (try? library.paths.evaluationStore().loadAll()) ?? []
        let active = library.activeProfile?.id
        for profile in library.profiles {
            let marker = profile.id == active ? terminal.green("*") : " "
            let agreement = profile.calibration.leaveOneOutAccuracy.map { "agreement \(percent($0))" } ?? ""
            let accuracy = EvaluationHistory.latest(for: profile.id, in: reports).map { "tested \(percent($0.overallAccuracy))" } ?? "not tested"
            terminal.line("\(marker) \(profile.id.uuidString.prefix(8))  \(profile.name.padding(toLength: 20, withPad: " ", startingAt: 0)) \(profile.sensingStrategy.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(agreement)  \(accuracy)")
        }
    }

    static func show(_ profile: HoloProfile, library: ProfileLibrary) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        terminal.line(terminal.bold(profile.name) + "  \(profile.id.uuidString)")
        terminal.line("Surface:      \(profile.surfaceDescription)")
        terminal.line("Position:     \(profile.laptopPositionNote)")
        terminal.line("Sensing:      \(profile.sensingStrategy.displayName)")
        terminal.line("Calibrated:   \(formatter.string(from: profile.calibration.capturedAt)) • \(profile.calibration.sampleCount) taps, \(profile.classifier.negativeExamples.count) rejection examples")
        if let agreement = profile.calibration.leaveOneOutAccuracy {
            terminal.line("Agreement:    \(percent(agreement))")
        }
        let capture = library.captureSettings(for: profile)
        terminal.line("Capture:      device \"\(capture.device)\", \(capture.channels) channel\(capture.channels == 1 ? "" : "s"), \(Int(capture.sampleRate)) Hz")
        let reports = (try? library.paths.evaluationStore().loadAll()) ?? []
        if let report = EvaluationHistory.latest(for: profile.id, in: reports) {
            terminal.line("Last test:    \(percent(report.overallAccuracy)) accuracy, " + String(format: "%.0f ms median", report.medianResponseLatencyMilliseconds) + " (\(formatter.string(from: report.completedAt)))")
        } else {
            terminal.line("Last test:    none — run `holo evaluate`")
        }
        terminal.line()
        ActionsCommand.list(profile)
    }
}

enum ConfigCommand {
    static let help = """
    Usage:
      holo config                          show settings
      holo config notifications on|off     desktop notification for each accepted tap and for problems
      holo config device DEV               capture device for new calibrations (default: "default")
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        guard let options = try parse(arguments, help: help) else { return 0 }
        var library = try openLibrary()
        let words = options.positionals
        guard let key = words.first else {
            terminal.line("notifications  \(library.config.notifications ? "on" : "off")")
            terminal.line("device         \(library.config.defaultDevice)")
            terminal.line(terminal.dim("config file    \(library.paths.configFile.path)"))
            terminal.line(terminal.dim("data           \(library.paths.dataRoot.path)"))
            return 0
        }
        guard words.count == 2 else { throw CLIError(help, status: 64) }
        switch key {
        case "notifications":
            switch words[1].lowercased() {
            case "on", "true", "yes": library.config.notifications = true
            case "off", "false", "no": library.config.notifications = false
            default: throw CLIError("Use on or off.", status: 64)
            }
        case "device":
            library.config.defaultDevice = words[1]
        default:
            throw CLIError("Unknown setting \"\(key)\".\n\n" + help, status: 64)
        }
        try library.saveConfig()
        terminal.line("\(key) = \(words[1])")
        return 0
    }
}

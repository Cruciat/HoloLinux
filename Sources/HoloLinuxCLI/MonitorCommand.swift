import Foundation
import HoloCore
import HoloLinux

enum MonitorCommand {
    static let help = """
    Usage: holo monitor [options]

    Shows the live input level and every detected tap with its signal quality
    and, when a profile exists, the zone it would trigger. No actions run, and
    the background service pauses while the monitor is open.

    Options:
      --profile NAME         classify with another profile
      --strategy S           passive, active, or hybrid (default: the profile's)
      --device DEV           ALSA capture device (default: the profile's, else "default")
      --channels N           1 or 2 (default: the profile's, else detected)
      --seconds N            exit after N seconds
      --save-wav             keep each detected 90 ms window as a WAV file (raw audio!)
      --allow-external-input
      --allow-external-output

    Keys: q quit
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        guard let options = try parse(
            arguments,
            values: ["profile", "strategy", "device", "channels", "seconds"],
            flags: ["save-wav", "allow-external-input", "allow-external-output"],
            help: help
        ) else { return 0 }
        let library = try openLibrary()
        let control = try serviceControl(library.paths)
        let profile = options.value("profile") != nil
            ? try profile(named: options.value("profile"), in: library)
            : library.activeProfile
        let strategy = try options.value("strategy").map(StrategyArgument.parse) ?? profile?.sensingStrategy ?? .passive
        let seconds = try options.integer("seconds", range: 1...86_400)
        let saved = (options.value("device") == nil && options.value("channels") == nil) ? profile.map(library.captureSettings(for:)) : nil

        let choice = chooseCapture(
            device: options.value("device"),
            channels: try options.integer("channels", range: 1...2),
            strategy: strategy,
            saved: saved,
            library: library,
            allowExternalInput: options.has("allow-external-input"),
            allowExternalOutput: options.has("allow-external-output")
        )
        terminal.line(terminal.bold("Holo monitor") + " • \(strategy.displayName)" + (profile.map { " • classifying with \"\($0.name)\"" } ?? " • no profile yet"))
        describeRoute(choice, strategy: strategy)
        try requireUsableRoute(choice)

        let debugDirectory = library.paths.debugCapturesDirectory
        if options.has("save-wav") {
            try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
            terminal.line(terminal.red("Raw audio of each detected event is saved to \(debugDirectory.path)."))
        }

        let runner = try GuidedRunner(name: "monitor", settings: choice.settings, control: control, reportsLevel: true)
        let started = HoloClock.now()
        var taps = 0
        var lastLevel = (-90.0, -90.0)
        let classifier = profile.flatMap { $0.sensingStrategy == strategy ? $0.classifier : nil }
        if profile != nil, classifier == nil {
            terminal.warning("The profile uses \(profile!.sensingStrategy.rawValue) sensing, so taps are not classified with --strategy \(strategy.rawValue).")
        }

        var lastLevelLine = 0.0
        runner.onLevel = { level, floor in
            lastLevel = (level, floor)
            // Without a terminal, print the meter at most once per second.
            if !terminal.isOutputTTY {
                let now = HoloClock.now()
                guard now - lastLevelLine >= 1 else { return }
                lastLevelLine = now
            }
            terminal.status(terminal.meter(dbfs: level, floorDBFS: floor) + String(format: " %5.1f dBFS  floor %5.1f  taps %d", level, floor, taps) + terminal.dim("  (q to quit)"))
        }
        runner.onObservation = { observation in
            taps += 1
            let quality = observation.feature.quality
            var line = "\(clock())  tap  " + qualityLabel(quality.summary)
                + String(format: "  SNR %4.1f dB  peak %5.1f dBFS", quality.signalToNoiseDB, TapPipeline.dbfs(quality.peakAmplitude))
            if let classifier {
                let decision = classifier.predict(observation.feature)
                if let zone = decision.zone, decision.wasAccepted {
                    line += "  → " + terminal.cyan(zone.displayName) + " \(percent(decision.confidence))"
                } else {
                    line += "  → " + terminal.yellow("rejected: \(decision.rejectionReason?.displayName ?? "low confidence")")
                }
            }
            let latency = observation.responseLatencyMilliseconds()
            if latency >= 0 { line += terminal.dim(String(format: "  %.0f ms", latency)) }
            terminal.line(line)
            if options.has("save-wav") {
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
                let url = debugDirectory.appendingPathComponent("\(formatter.string(from: Date()))-monitor.wav")
                do {
                    try WaveFileWriter.write(channels: observation.rawChannels, sampleRate: choice.settings.sampleRate, to: url)
                } catch {
                    terminal.warning("Could not save \(url.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if terminal.isOutputTTY {
                terminal.status(terminal.meter(dbfs: lastLevel.0, floorDBFS: lastLevel.1) + String(format: " %5.1f dBFS  taps %d", lastLevel.0, taps))
            }
        }
        runner.onTick = { now in
            if let seconds, now - started >= Double(seconds) { runner.finish() }
        }
        runner.onKey = { key in
            if key.character == "q" || key == 27 { runner.finish() }
        }

        try runner.start(strategy: strategy)
        terminal.line(terminal.dim("Learning the room's background noise for a moment, then tap the desk."))
        runner.run()
        terminal.line("\(taps) tap\(taps == 1 ? "" : "s") detected.")
        return 0
    }

    static func qualityLabel(_ summary: String) -> String {
        let padded = summary.padding(toLength: 9, withPad: " ", startingAt: 0)
        switch summary {
        case "Excellent", "Good": return terminal.green(padded)
        case "Fair": return padded
        default: return terminal.yellow(padded)
        }
    }
}

enum CompareCommand {
    static let help = """
    Usage: holo compare [options]

    Collects three taps per zone with each sensing strategy (36 taps) and
    measures which one separates the zones best on this desk. The result
    becomes the suggested strategy for the next `holo calibrate`. Active and
    hybrid sensing play a quiet 15.5–21 kHz chirp through the laptop speakers.

    Options:
      --device DEV, --channels N, --allow-external-input, --allow-external-output

    Keys: Enter arm the next set · q quit
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        guard let options = try parse(
            arguments,
            values: ["device", "channels"],
            flags: ["allow-external-input", "allow-external-output"],
            help: help
        ) else { return 0 }
        let library = try openLibrary()
        let control = try serviceControl(library.paths)
        let profileID = library.activeProfile?.id
        let choice = chooseCapture(
            device: options.value("device"),
            channels: try options.integer("channels", range: 1...2),
            strategy: .hybrid,
            saved: nil,
            library: library,
            allowExternalInput: options.has("allow-external-input"),
            allowExternalOutput: options.has("allow-external-output")
        )
        terminal.line(terminal.bold("Holo sensing comparison"))
        describeRoute(choice, strategy: .hybrid)
        try requireUsableRoute(choice)

        let runner = try GuidedRunner(name: "compare", settings: choice.settings, control: control)
        let controller = ComparisonController(profileID: profileID)
        var result: ApproachComparison?

        func prompt() {
            guard case .waitingForArm(let strategy, let zone) = controller.phase else { return }
            terminal.status("\(strategy.displayName) • put your hand at " + terminal.cyan(zone.displayName) + ", then press " + terminal.bold("Enter"))
        }

        func render(_ updates: [ComparisonController.Update]) {
            for update in updates {
                switch update {
                case .preparing(let strategy, let zone, _):
                    terminal.status("Get ready — \(strategy.displayName) • \(zone.displayName)…")
                case .armed(let strategy, let zone, let next, let total):
                    terminal.status("\(strategy.displayName) • " + terminal.cyan(zone.displayName) + " armed • tap \(next) of \(total)")
                case .accepted(let strategy, let zone, let count, let total):
                    terminal.status("\(strategy.displayName) • \(zone.displayName) \(progressBar(count, of: total, width: total)) \(count)/\(total)")
                case .retry(let issue):
                    terminal.status(terminal.yellow(issue.guidance))
                case .setComplete:
                    terminal.line(terminal.green("Set saved."))
                    prompt()
                case .strategyChanged(let strategy):
                    do {
                        runner.stopCapture()
                        try runner.start(strategy: strategy)
                        terminal.line("Switched to \(strategy.displayName)." + (strategy == .passive ? "" : " The speaker probe is playing."))
                        prompt()
                    } catch {
                        terminal.error(error.localizedDescription)
                        runner.cancel()
                    }
                case .finished(let comparison):
                    result = comparison
                    runner.finish()
                case .failed(let message):
                    terminal.error(message)
                    runner.cancel()
                }
            }
        }

        runner.onObservation = { render(controller.handle($0, now: HoloClock.now())) }
        runner.onTick = { render(controller.tick(now: $0)) }
        runner.onKey = { key in
            if key.character == "q" || key == 27 {
                runner.cancel()
            } else if key.isEnter, case .waitingForArm = controller.phase {
                render(controller.arm(now: HoloClock.now()))
            }
        }
        try runner.start(strategy: .passive)
        prompt()
        runner.run()

        guard let result, !runner.cancelled else {
            terminal.line("Comparison cancelled.")
            return 1
        }
        terminal.line()
        terminal.line("Strategy                   agreement   rejected   median DSP")
        for score in result.scores {
            let mark = score.strategy == result.selectedStrategy ? terminal.green(" ← suggested") : ""
            terminal.line(score.strategy.displayName.padding(toLength: 27, withPad: " ", startingAt: 0)
                + percent(score.crossValidationAccuracy).padding(toLength: 12, withPad: " ", startingAt: 0)
                + percent(score.rejectionRate).padding(toLength: 11, withPad: " ", startingAt: 0)
                + String(format: "%.1f ms", score.medianProcessingLatencyMilliseconds) + mark)
        }
        do {
            try library.paths.comparisonStore().save(result)
            terminal.line("The next `holo calibrate` will use \(result.selectedStrategy.displayName) unless you pass --strategy.")
        } catch {
            terminal.warning("The comparison could not be saved: \(error.localizedDescription)")
        }
        return 0
    }
}

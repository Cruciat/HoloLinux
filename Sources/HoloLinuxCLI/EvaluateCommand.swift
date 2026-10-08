import Foundation
import HoloCore
import HoloLinux

enum EvaluateCommand {
    static let help = """
    Usage: holo evaluate [options]

    Guided held-out accuracy test for the active profile: fifteen new taps per
    zone, 60 in total. Press Enter to arm each zone. Every tap detected while a
    zone is armed counts, including rejected ones. The report (JSON and CSV) is
    saved next to the profiles.

    Targets from the original project: at least 80% overall accuracy and a
    median response under 200 ms.

    Options:
      --profile NAME         evaluate another profile
      --taps N               taps per zone (default: 15; only 15 counts as a full acceptance session)
      --allow-external-input
      --allow-external-output

    Keys: Enter arm the zone · q quit without saving
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        guard let options = try parse(
            arguments,
            values: ["profile", "taps"],
            flags: ["allow-external-input", "allow-external-output"],
            help: help
        ) else { return 0 }
        let library = try openLibrary()
        let control = try serviceControl(library.paths)
        let profile = try profile(named: options.value("profile"), in: library)
        let taps = try options.integer("taps", range: 3...30) ?? EvaluationAcceptance.tapsPerZone

        let choice = chooseCapture(
            device: nil,
            channels: nil,
            strategy: profile.sensingStrategy,
            saved: library.captureSettings(for: profile),
            library: library,
            allowExternalInput: options.has("allow-external-input"),
            allowExternalOutput: options.has("allow-external-output")
        )
        terminal.line(terminal.bold("Holo accuracy test") + " • \"\(profile.name)\" • \(profile.sensingStrategy.displayName)")
        describeRoute(choice, strategy: profile.sensingStrategy)
        try requireUsableRoute(choice)

        let runner = try GuidedRunner(name: "evaluate", settings: choice.settings, control: control)
        let controller = EvaluationController(profile: profile, targetPerZone: taps)
        var report: EvaluationReport?

        func showZone(_ zone: DeskZone) {
            terminal.line()
            for line in terminal.deskMap(highlight: zone) { terminal.line(line) }
            terminal.line()
            terminal.status("Put your hand at " + terminal.cyan(zone.displayName) + " (\(zoneHint(zone))), then press " + terminal.bold("Enter") + ".")
        }

        func render(_ updates: [EvaluationController.Update]) {
            for update in updates {
                switch update {
                case .preparing(let zone, _):
                    terminal.status("Get ready — \(zone.displayName) arms in one second…")
                case .armed(let zone, let next, let total):
                    terminal.status(terminal.cyan(zone.displayName) + " armed • tap \(next) of \(total)")
                case .recorded(let record, let count, let total):
                    let verdict: String
                    if record.isCorrect {
                        verdict = terminal.green("✓ \(record.expectedZone.shortName)") + terminal.dim(" \(percent(record.confidence))")
                    } else if let predicted = record.predictedZone {
                        verdict = terminal.red("✗ heard \(predicted.displayName)")
                    } else {
                        verdict = terminal.red("✗ rejected (\(record.rejectionReason?.displayName ?? "low confidence"))")
                    }
                    let latency = record.responseLatencyMilliseconds >= 0 ? String(format: "%.0f ms", record.responseLatencyMilliseconds) : "n/a"
                    terminal.line("  \(record.expectedZone.shortName) \(count)/\(total)  \(verdict)  \(terminal.dim(latency))")
                case .zoneComplete(let zone, let next):
                    terminal.line(terminal.green("\(zone.displayName) complete."))
                    showZone(next)
                case .finished(let finished):
                    report = finished
                    runner.finish()
                }
            }
        }

        runner.onObservation = { observation in
            let now = HoloClock.now()
            render(controller.handle(observation, now: now, responseTime: HoloClock.now()))
        }
        runner.onTick = { now in render(controller.tick(now: now)) }
        runner.onKey = { key in
            if key.character == "q" || key == 27 {
                runner.cancel()
            } else if key.isEnter, case .waitingForArm = controller.phase {
                render(controller.arm(now: HoloClock.now()))
            }
        }
        runner.onCaptureFailure = { message in
            terminal.error("Capture stopped: \(message)")
            runner.cancel()
        }

        terminal.line()
        terminal.line("Tap naturally, one tap at a time. Rejected taps count as wrong — that is the point of the test.")
        try runner.start(strategy: profile.sensingStrategy)
        showZone(DeskZone.allCases[0])
        runner.run()

        guard let report, !runner.cancelled else {
            terminal.line("Accuracy test cancelled. Nothing was saved.")
            return 1
        }
        terminal.line()
        var savedURL: URL?
        do {
            savedURL = try library.paths.evaluationStore().save(report)
        } catch {
            terminal.warning("The report could not be saved: \(error.localizedDescription)")
        }
        ReportPrinter.print(report, savedAt: savedURL)
        return report.meetsAccuracyAndLatencyTargets ? 0 : 3
    }
}

enum ReportCommand {
    static let help = """
    Usage: holo report [--profile NAME] [--json]

    Shows the newest saved accuracy report for the active (or named) profile.
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        guard let options = try parse(arguments, values: ["profile"], flags: ["json"], help: help) else { return 0 }
        let library = try openLibrary()
        let profile = try profile(named: options.value("profile"), in: library)
        let reports = try library.paths.evaluationStore().loadAll()
        guard let report = EvaluationHistory.latest(for: profile.id, in: reports) else {
            terminal.line("No accuracy report for \"\(profile.name)\" yet. Run `holo evaluate`.")
            return 1
        }
        if options.has("json") {
            print(String(decoding: try report.jsonData(), as: UTF8.self))
            return 0
        }
        ReportPrinter.print(report, savedAt: nil)
        return 0
    }
}

enum ReportPrinter {
    static func print(_ report: EvaluationReport, savedAt url: URL?) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        terminal.line(terminal.bold("Accuracy report") + " • \"\(report.profileName)\" • \(report.strategy.displayName) • \(formatter.string(from: report.completedAt))")
        let correct = report.records.filter(\.isCorrect).count
        let accuracyMark = report.meetsAccuracyTarget ? terminal.green("✓") : terminal.red("✗")
        terminal.line("Overall accuracy: \(percent(report.overallAccuracy)) (\(correct)/\(report.records.count))   target ≥ \(percent(EvaluationAcceptance.minimumAccuracy)) \(accuracyMark)")
        if report.hasCompleteResponseLatency {
            let latencyMark = report.meetsLatencyTarget ? terminal.green("✓") : terminal.red("✗")
            terminal.line(String(format: "Median response:  %.0f ms", report.medianResponseLatencyMilliseconds) + "        target < \(Int(EvaluationAcceptance.maximumMedianResponseMilliseconds)) ms \(latencyMark)")
        } else {
            terminal.line("Median response:  unavailable (some timestamps were invalid)")
        }
        terminal.line()
        terminal.line("Per zone:  " + report.perZoneAccuracy.map { "\($0.zone.shortName) \(percent($0.accuracy)) (\($0.correct)/\($0.total))" }.joined(separator: "   "))
        terminal.line()
        terminal.line("Confusion matrix (rows: where you tapped, columns: what Holo heard)")
        terminal.line("        " + DeskZone.allCases.map { $0.shortName.padding(toLength: 5, withPad: " ", startingAt: 0) }.joined() + "rejected")
        let matrix = report.confusionMatrix
        let rejected = report.rejectedPerZone
        for (row, zone) in DeskZone.allCases.enumerated() {
            let cells = matrix[row].enumerated().map { column, value -> String in
                let text = String(value).padding(toLength: 5, withPad: " ", startingAt: 0)
                return column == row ? terminal.bold(text) : (value > 0 ? terminal.yellow(text) : terminal.dim(text))
            }.joined()
            terminal.line("  \(zone.shortName)    " + cells + String(rejected[row]))
        }
        terminal.line()
        if report.meetsAccuracyAndLatencyTargets {
            terminal.line(terminal.green("PASSED") + " — this setup meets the prototype's accuracy and latency targets.")
        } else if !report.isBalancedAcceptanceSession {
            terminal.line(terminal.yellow("Not a full acceptance session") + " (needs \(EvaluationAcceptance.tapsPerZone) taps per zone).")
        } else {
            terminal.line(terminal.red("NOT PASSED") + " — recalibrate (`holo calibrate --recalibrate`), add rejection examples, or try `holo compare`.")
        }
        if let url {
            terminal.line(terminal.dim("Saved: \(url.path) and .csv"))
        }
    }
}

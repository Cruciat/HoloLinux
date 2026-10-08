import Foundation
import HoloCore
import HoloLinux

enum CalibrateCommand {
    static let help = """
    Usage: holo calibrate [options]

    Guided calibration: ten natural taps in each of the four zones around the
    laptop, then an agreement review before saving. Keep the laptop exactly
    where it will stay; moving it invalidates the profile.

    Options:
      --name NAME            profile name (default: "My Desk", or the recalibrated profile's name)
      --surface TEXT         desk surface description (default: "Rigid desk")
      --position TEXT        laptop position note
      --recalibrate [NAME]   replace an existing profile (default: the active one), keeping its actions
      --strategy S           passive (default), active, or hybrid
      --device DEV           ALSA capture device (default: "default", the session's input)
      --channels N           capture 1 or 2 channels (default: detected)
      --taps N               taps per zone (default: 10)
      --allow-external-input    accept a USB/Bluetooth microphone
      --allow-external-output   accept non-built-in speakers for active/hybrid sensing

    Keys while capturing: u undo last tap · r redo this zone · p pause/resume · q quit
    """

    static func run(_ arguments: [String]) throws -> Int32 {
        // --recalibrate takes an optional profile name, so extract it before strict parsing.
        var remaining = arguments
        var recalibrate = false
        var recalibrateName: String?
        if let index = remaining.firstIndex(where: { $0 == "--recalibrate" || $0.hasPrefix("--recalibrate=") }) {
            recalibrate = true
            let argument = remaining.remove(at: index)
            if argument.hasPrefix("--recalibrate=") {
                recalibrateName = String(argument.dropFirst("--recalibrate=".count))
            } else if index < remaining.count, !remaining[index].hasPrefix("--") {
                recalibrateName = remaining.remove(at: index)
            }
        }
        guard let options = try parse(
            remaining,
            values: ["name", "surface", "position", "strategy", "device", "channels", "taps"],
            flags: ["allow-external-input", "allow-external-output"],
            help: help
        ) else { return 0 }

        var library = try openLibrary()
        let paths = library.paths
        let control = try serviceControl(paths)

        let existing: HoloProfile? = recalibrate ? try profile(named: recalibrateName, in: library) : nil
        if !options.positionals.isEmpty {
            throw CLIError("Unexpected argument \"\(options.positionals[0])\".\n\n" + help, status: 64)
        }

        let comparison = (try? paths.comparisonStore().load()) ?? nil
        let suggested = comparison.flatMap { $0.applies(to: existing?.id ?? library.activeProfile?.id) ? $0.selectedStrategy : nil }
        let strategy = try options.value("strategy").map(StrategyArgument.parse) ?? existing?.sensingStrategy ?? suggested ?? .passive
        let taps = try options.integer("taps", range: 3...30) ?? CalibrationGuidance.targetTapsPerZone
        let channels = try options.integer("channels", range: 1...2)

        let draft = CalibrationDraft(
            name: options.value("name") ?? existing?.name ?? "My Desk",
            surfaceDescription: options.value("surface") ?? existing?.surfaceDescription ?? "Rigid desk",
            laptopPositionNote: options.value("position") ?? existing?.laptopPositionNote ?? "Laptop centered; position unchanged",
            strategy: strategy
        )

        // Recalibration keeps the previous capture path unless told otherwise.
        let savedCapture = (options.value("device") == nil && channels == nil) ? existing.map(library.captureSettings(for:)) : nil
        let choice = chooseCapture(
            device: options.value("device"),
            channels: channels,
            strategy: strategy,
            saved: savedCapture,
            library: library,
            allowExternalInput: options.has("allow-external-input"),
            allowExternalOutput: options.has("allow-external-output")
        )

        terminal.line(terminal.bold("Holo calibration") + " • \"\(draft.name)\" • \(strategy.displayName)")
        if let existing {
            terminal.line(terminal.dim("Recalibrating \(existing.name) (\(existing.id.uuidString.prefix(8))); its actions are kept."))
        }
        if suggested != nil, options.value("strategy") == nil, existing == nil {
            terminal.line(terminal.dim("Using the strategy suggested by your last `holo compare`."))
        }
        describeRoute(choice, strategy: strategy)
        try requireUsableRoute(choice)

        let runner = try GuidedRunner(name: "calibrate", settings: choice.settings, control: control)
        let controller = CalibrationController(draft: draft, targetPerZone: taps)
        let ui = CalibrationUI(controller: controller, runner: runner)

        terminal.line()
        terminal.line("Make natural taps with a short pause between them, spread around the highlighted")
        terminal.line("area. Weak, noisy, or clipped taps are not counted. Keys: " + terminal.bold("u") + " undo · " + terminal.bold("r") + " redo zone · " + terminal.bold("p") + " pause · " + terminal.bold("q") + " quit")

        try runner.start(strategy: strategy)
        ui.begin(now: HoloClock.now())
        runner.run()

        guard ui.saveRequested, !runner.cancelled else {
            terminal.line("Calibration discarded. Nothing was saved.")
            return 1
        }

        let profile = try controller.makeProfile(replacing: existing)
        do {
            try library.save(profile, capture: runner.settings, makeActive: true)
        } catch {
            throw CLIError("The profile could not be saved: \(error.localizedDescription)")
        }
        terminal.line()
        terminal.line(terminal.green("Saved") + " \"\(profile.name)\" (\(profile.id.uuidString.prefix(8))) with \(profile.calibration.sampleCount) taps" +
            (controller.session.negativeSamples.isEmpty ? "" : " and \(controller.session.negativeSamples.count) rejection examples") +
            ". It is now the active profile.")
        if let agreement = profile.calibration.leaveOneOutAccuracy {
            terminal.line("Calibration agreement: \(percent(agreement)) (a diagnostic only — run `holo evaluate` for real accuracy).")
        }
        terminal.line()
        terminal.line("Next:")
        terminal.line("  holo evaluate                         measure accuracy with 60 new taps")
        terminal.line("  holo actions set lr url https://example.com")
        terminal.line("  systemctl --user enable --now holo    start listening in the background")
        return 0
    }
}

/// Renders calibration progress and handles keys.
final class CalibrationUI {
    enum Screen {
        case capturing
        case paused
        case review
        case negatives
    }

    let controller: CalibrationController
    let runner: GuidedRunner
    private(set) var saveRequested = false
    private var screen: Screen = .capturing
    private var lastAccepted: String?

    init(controller: CalibrationController, runner: GuidedRunner) {
        self.controller = controller
        self.runner = runner
        runner.onObservation = { [weak self] observation in
            guard let self else { return }
            self.render(self.controller.handle(observation, now: HoloClock.now()))
        }
        runner.onTick = { [weak self] now in
            guard let self else { return }
            self.render(self.controller.tick(now: now))
        }
        runner.onKey = { [weak self] key in self?.key(key) }
        runner.onCaptureFailure = { [weak self] message in
            guard let self else { return }
            terminal.error("Capture stopped: \(message)")
            self.controller.disarm()
            self.screen = .paused
            terminal.line("Press " + terminal.bold("p") + " to try again or " + terminal.bold("q") + " to quit.")
        }
    }

    func begin(now: Double) {
        showMap(highlight: controller.currentZone)
        terminal.status(terminal.dim("Learning the room's background noise — stay quiet for a second…"))
        render(controller.start(now: now))
    }

    private func labels() -> [DeskZone: String] {
        var labels: [DeskZone: String] = [:]
        for zone in DeskZone.allCases {
            let count = controller.session.count(for: zone)
            let target = controller.session.targetPerZone
            labels[zone] = count >= target ? "✓" : count > 0 ? "\(count)/\(target)" : nil
        }
        return labels
    }

    private func showMap(highlight: DeskZone?) {
        terminal.line()
        for line in terminal.deskMap(highlight: highlight, labels: labels()) { terminal.line(line) }
        terminal.line()
    }

    private func render(_ updates: [CalibrationController.Update]) {
        for update in updates {
            switch update {
            case .preparing(let zone, let seconds):
                terminal.status(terminal.cyan("▶ \(zone.displayName)") + ": \(zoneHint(zone)). Listening in \(Int(seconds.rounded())) s…")
            case .armed(let zone, let next, let total):
                terminal.status(statusLine(zone: zone, count: next - 1, total: total, note: "listening — tap now"))
            case .accepted(let zone, let count, let total, let quality):
                lastAccepted = quality
                terminal.status(statusLine(zone: zone, count: count, total: total, note: "last tap: \(quality)"))
            case .retry(let issue):
                terminal.status(terminal.yellow(issue.guidance))
            case .zoneComplete(let zone, let next):
                terminal.line(terminal.green("✓ \(zone.displayName) done.") + " Next: \(next.displayName) — move your hand; listening starts automatically.")
                showMap(highlight: next)
            case .allZonesCaptured(let result):
                terminal.line(terminal.green("✓ All four zones captured."))
                showMap(highlight: nil)
                showReview(result)
            case .reviewUnavailable(let message):
                terminal.line(terminal.yellow("Calibration review unavailable: \(message)"))
                showReview(nil)
            case .negativeCaptured(let label, let count):
                terminal.status("\(label) examples: \(count) captured — keep going, then press Enter")
            case .removedSample(let what):
                terminal.line("Removed the last \(what).")
                if screen == .capturing { showMap(highlight: controller.currentZone) }
            case .zoneCleared(let zone):
                terminal.line("Cleared \(zone.displayName). Tap it again.")
                screen = .capturing
                showMap(highlight: zone)
            case .negativesCleared(let label):
                terminal.line("Cleared \(label) examples.")
            }
        }
    }

    private func statusLine(zone: DeskZone, count: Int, total: Int, note: String) -> String {
        "\(terminal.cyan(zone.displayName.padding(toLength: 12, withPad: " ", startingAt: 0))) \(progressBar(count, of: total)) \(count)/\(total)  \(terminal.dim(note))"
    }

    private func showReview(_ result: CrossValidationResult?) {
        screen = .review
        if let result {
            let agreement = percent(result.accuracy)
            let colored = result.accuracy >= CalibrationGuidance.minimumCleanAgreement ? terminal.green(agreement) : terminal.yellow(agreement)
            terminal.line("Calibration agreement (each tap classified by the others): \(colored)")
            let perZone = result.perZoneAccuracy.map { "\($0.zone.shortName) \(percent($0.accuracy))" }.joined(separator: "   ")
            terminal.line("  " + perZone)
            if controller.needsAttention, let weakest = controller.weakestZone {
                terminal.line(terminal.yellow("The taps in \(weakest.displayName) were the least consistent. Redoing that zone usually helps."))
            }
        }
        reviewMenu()
    }

    private func reviewMenu() {
        let weakest = controller.weakestZone.map { terminal.bold("r") + " redo weakest zone (\($0.shortName)) · " } ?? ""
        terminal.line()
        terminal.line(terminal.bold("s") + " save · " + weakest + terminal.bold("1-4") + " redo LR/LF/RR/RF · " +
            terminal.bold("n") + " add rejection examples · " + terminal.bold("q") + " quit without saving")
    }

    private func negativesMenu() {
        terminal.line()
        terminal.line("Rejection examples teach Holo which sounds are not taps. Choose one, make that sound")
        terminal.line("for a few seconds (talking is the most useful), then press Enter.")
        for (index, label) in CalibrationController.negativeLabels.enumerated() {
            let count = controller.session.negativeCount(for: label)
            terminal.line("  \(terminal.bold(String(index + 1))) \(label)" + (count > 0 ? terminal.dim(" (\(count))") : ""))
        }
        terminal.line(terminal.bold("Enter") + " stop · " + terminal.bold("c") + " clear the selected sound · " + terminal.bold("b") + " back")
    }

    private func key(_ key: UInt8) {
        let character = key.character
        if character == "q" || key == 27 {
            runner.cancel()
            return
        }
        switch screen {
        case .capturing:
            switch character {
            case "u": render(controller.undo(now: HoloClock.now()))
            case "r": render(controller.redoZone(now: HoloClock.now()))
            case "p":
                controller.disarm()
                runner.stopCapture()
                screen = .paused
                terminal.line("Paused; the microphone is released. Press " + terminal.bold("p") + " to continue.")
            default: break
            }
        case .paused:
            guard character == "p" else { return }
            do {
                try runner.start(strategy: controller.strategy)
                screen = controller.session.zonesComplete ? .review : .capturing
                if screen == .review {
                    reviewMenu()
                } else {
                    showMap(highlight: controller.currentZone)
                    render(controller.arm(now: HoloClock.now()))
                }
            } catch {
                terminal.error(error.localizedDescription)
            }
        case .review:
            switch character {
            case "s":
                saveRequested = true
                runner.finish()
            case "r":
                if let zone = controller.weakestZone {
                    render(controller.redoZone(zone, now: HoloClock.now()))
                }
            case "1", "2", "3", "4":
                if let index = Int(String(character)) {
                    render(controller.redoZone(DeskZone.allCases[index - 1], now: HoloClock.now()))
                }
            case "n":
                screen = .negatives
                negativesMenu()
            case "u":
                render(controller.undo(now: HoloClock.now()))
                screen = .capturing
            default: break
            }
        case .negatives:
            if let index = Int(String(character)), (1...CalibrationController.negativeLabels.count).contains(index) {
                let label = CalibrationController.negativeLabels[index - 1]
                controller.startNegatives(label: label, now: HoloClock.now())
                terminal.status("Recording \(label.lowercased()) sounds — start now, press Enter when done")
            } else if key.isEnter {
                if case .collectingNegatives(let label) = controller.phase {
                    controller.stopNegatives()
                    terminal.line("\(label): \(controller.session.negativeCount(for: label)) examples.")
                    negativesMenu()
                }
            } else if character == "c" {
                if case .collectingNegatives(let label) = controller.phase {
                    render(controller.clearNegatives(label: label))
                }
            } else if character == "b" {
                controller.stopNegatives()
                screen = .review
                reviewMenu()
            }
        }
    }
}

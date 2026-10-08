import HoloCore
@testable import HoloLinux
import XCTest

final class TapPipelineTests: XCTestCase {
    func testDetectsEachTapWithItsOnsetTime() {
        var desk = SyntheticDesk(seed: 1)
        let stream = desk.stream(seconds: 4, taps: [(1.2, .leftTop), (2.0, .rightBottom), (3.1, .leftBottom)])
        let found = observations(from: stream, startTime: 500)
        XCTAssertEqual(found.count, 3)
        let expected = [501.2, 502.0, 503.1]
        for (observation, time) in zip(found, expected) {
            XCTAssertEqual(observation.eventTime, time, accuracy: 0.003)
            XCTAssertEqual(observation.rawChannels.count, 2)
            XCTAssertEqual(observation.feature.strategy, .passive)
        }
    }

    func testSustainedSoundAndQuietRoomProduceNoTaps() {
        var desk = SyntheticDesk(seed: 2)
        var stream = desk.noise(frames: 48_000 * 3)
        // A 1.5 s voiced sound at 150 Hz.
        for index in 48_000..<(48_000 + 72_000) {
            let time = Double(index) / 48_000
            let value = Float(0.05 * sin(2 * Double.pi * 150 * time) * (0.6 + 0.4 * sin(2 * Double.pi * 4 * time)))
            stream[0][index] += value
            stream[1][index] += value
        }
        XCTAssertTrue(observations(from: stream).isEmpty)
    }

    func testLevelReports() {
        let pipeline = TapPipeline(sampleRate: 48_000, channelCount: 1, strategy: .passive)
        var levels: [Double] = []
        pipeline.onLevel = { level, _ in levels.append(level) }
        let tone = (0..<48_000).map { Float(0.1 * sin(Double($0) * 0.05)) }
        for start in stride(from: 0, to: tone.count, by: 480) {
            pipeline.process(channels: [Array(tone[start..<(start + 480)])], bufferStartTime: 0)
        }
        XCTAssertEqual(levels.count, 10)
        XCTAssertEqual(levels.last ?? 0, 20 * log10(0.1 / sqrt(2)), accuracy: 0.5)
    }

    func testDeinterleavesAllFormats() {
        let floats: [Float] = [0.5, -0.5, 0.25, -0.25]
        let floatBytes = floats.withUnsafeBytes { Array($0) }
        XCTAssertEqual(AlsaCaptureSource.deinterleave(floatBytes, frames: 2, channels: 2, format: .float32), [[0.5, 0.25], [-0.5, -0.25]])
        let ints: [Int16] = [16_384, -16_384]
        let intBytes = ints.withUnsafeBytes { Array($0) }
        XCTAssertEqual(AlsaCaptureSource.deinterleave(intBytes, frames: 2, channels: 1, format: .int16), [[0.5, -0.5]])
        let wide: [Int32] = [Int32.min, 1_073_741_824]
        let wideBytes = wide.withUnsafeBytes { Array($0) }
        XCTAssertEqual(AlsaCaptureSource.deinterleave(wideBytes, frames: 1, channels: 2, format: .int32), [[-1], [0.5]])
    }
}

final class CalibrationControllerTests: XCTestCase {
    private func run(_ controller: CalibrationController, zone: DeskZone, taps: [TapObservation], clock: inout Double) -> [CalibrationController.Update] {
        var updates: [CalibrationController.Update] = []
        for tap in taps {
            clock += 0.5
            updates += controller.tick(now: clock)
            updates += controller.handle(tap, now: clock)
        }
        return updates
    }

    func testFullFlowArmsZonesInOrderAndBuildsAProfile() throws {
        let samples = zoneObservations(count: 4)
        let controller = CalibrationController(draft: CalibrationDraft(name: "Test desk"), targetPerZone: 4)
        var clock = 100.0
        XCTAssertEqual(controller.start(now: clock), [.preparing(.leftTop, inSeconds: 1)])

        // Taps before the zone arms are ignored.
        XCTAssertEqual(controller.handle(samples[.leftTop]![0], now: clock + 0.6), [])
        clock += 1.0
        XCTAssertEqual(controller.tick(now: clock), [.armed(.leftTop, nextTap: 1, of: 4)])

        var updates: [CalibrationController.Update] = []
        for zone in DeskZone.allCases {
            if zone != .leftTop {
                clock += GuidedTiming.zoneTransitionDelay
                XCTAssertEqual(controller.tick(now: clock), [.armed(zone, nextTap: 1, of: 4)])
            }
            updates += run(controller, zone: zone, taps: samples[zone]!, clock: &clock)
            XCTAssertEqual(controller.session.count(for: zone), 4)
        }
        XCTAssertTrue(updates.contains(.zoneComplete(.leftTop, next: .leftBottom)))
        XCTAssertTrue(updates.contains(.zoneComplete(.rightTop, next: .rightBottom)))
        guard case .allZonesCaptured(let result)? = updates.last else {
            return XCTFail("Expected a review, got \(String(describing: updates.last))")
        }
        XCTAssertEqual(result?.accuracy ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(controller.phase, .zonesComplete)
        XCTAssertNil(controller.weakestZone)

        let profile = try controller.makeProfile(replacing: nil)
        XCTAssertEqual(profile.name, "Test desk")
        XCTAssertEqual(profile.calibration.samplesPerZone, [4, 4, 4, 4])
        XCTAssertEqual(profile.zones.map(\.action.kind), [.none, .none, .none, .none])
        for zone in DeskZone.allCases {
            let decision = profile.classifier.predict(zoneObservations(count: 1, seed: 99)[zone]![0].feature)
            XCTAssertEqual(decision.zone, zone)
        }
    }

    func testRateLimitQualityGateUndoAndRedo() {
        let samples = zoneObservations(count: 3)
        let controller = CalibrationController(draft: CalibrationDraft(), targetPerZone: 3)
        var clock = 0.0
        _ = controller.start(now: clock)
        clock = 1.0
        _ = controller.tick(now: clock)

        // One tap, one sample: a second event within 0.4 s is ignored.
        XCTAssertEqual(controller.handle(samples[.leftTop]![0], now: clock).count, 1)
        XCTAssertEqual(controller.handle(samples[.leftTop]![1], now: clock + 0.2), [])

        // A clipped tap asks for a retry and is not stored.
        var clipped = samples[.leftTop]![1]
        clipped.feature.quality.clippingFraction = 0.5
        XCTAssertEqual(controller.handle(clipped, now: clock + 0.5), [.retry(.clipped)])
        XCTAssertEqual(controller.session.count(for: .leftTop), 1)

        // Undo removes the sample and re-arms after the settle delay.
        let undo = controller.undo(now: clock + 1)
        XCTAssertEqual(undo.first, .removedSample("Left Rear tap"))
        XCTAssertEqual(controller.session.count(for: .leftTop), 0)
        XCTAssertEqual(controller.tick(now: clock + 2.1), [.armed(.leftTop, nextTap: 1, of: 3)])

        // Redo clears the zone.
        _ = controller.handle(samples[.leftTop]![2], now: clock + 2.2)
        XCTAssertEqual(controller.redoZone(now: clock + 3).first, .zoneCleared(.leftTop))
        XCTAssertEqual(controller.session.count(for: .leftTop), 0)
    }

    func testStrategyMismatchIsIgnored() {
        let controller = CalibrationController(draft: CalibrationDraft(strategy: .hybrid), targetPerZone: 2)
        _ = controller.start(now: 0)
        _ = controller.tick(now: 1)
        let passive = zoneObservations(count: 1)[.leftTop]![0]
        XCTAssertEqual(controller.handle(passive, now: 2), [])
    }

    func testNegativeExamplesSkipTheQualityGateAndArePersisted() throws {
        let samples = zoneObservations(count: 3)
        let controller = CalibrationController(draft: CalibrationDraft(), targetPerZone: 3)
        var clock = 0.0
        _ = controller.start(now: clock)
        for zone in DeskZone.allCases {
            clock += 2.5
            _ = controller.tick(now: clock)
            for tap in samples[zone]! {
                clock += 0.5
                _ = controller.handle(tap, now: clock)
            }
        }
        XCTAssertTrue(controller.session.zonesComplete)
        controller.startNegatives(label: "Talking", now: clock)
        var weak = samples[.leftTop]![0]
        weak.feature.quality.peakAmplitude = 0.0001
        XCTAssertEqual(controller.handle(weak, now: clock + 0.5), [], "Waits 0.8 s before collecting")
        XCTAssertEqual(controller.handle(weak, now: clock + 1), [.negativeCaptured("Talking", count: 1)])
        XCTAssertEqual(controller.handle(weak, now: clock + 1.1), [.negativeCaptured("Talking", count: 2)])
        _ = controller.undo(now: clock + 1.2)
        XCTAssertEqual(controller.session.negativeCount(for: "Talking"), 1)
        controller.stopNegatives()
        let profile = try controller.makeProfile(replacing: nil)
        XCTAssertEqual(profile.classifier.negativeExamples.count, 1)
    }

    func testRecalibrationKeepsIdentityAndActions() throws {
        let samples = zoneObservations(count: 3)
        func calibrated(_ existing: HoloProfile?) throws -> HoloProfile {
            let controller = CalibrationController(draft: CalibrationDraft(name: "Desk"), targetPerZone: 3)
            var clock = 0.0
            _ = controller.start(now: clock)
            for zone in DeskZone.allCases {
                clock += 2.5
                _ = controller.tick(now: clock)
                for tap in samples[zone]! {
                    clock += 0.5
                    _ = controller.handle(tap, now: clock)
                }
            }
            return try controller.makeProfile(replacing: existing)
        }
        var first = try calibrated(nil)
        first.zones[2].action = ZoneActionConfiguration(kind: .runShellCommand, text: "true")
        let second = try calibrated(first)
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertEqual(second.zones[2].action.kind, .runShellCommand)
    }
}

final class EvaluationControllerTests: XCTestCase {
    func testRecordsEveryArmedTapAndProducesAReport() throws {
        let training = zoneObservations(count: 4)
        let classifier = try TrainedTapClassifier.train(positiveExamples: DeskZone.allCases.flatMap { zone in
            training[zone]!.map { LabeledTap(zone: zone, feature: $0.feature) }
        })
        let profile = HoloProfile(
            name: "Desk",
            surfaceDescription: "",
            laptopPositionNote: "",
            classifier: classifier,
            calibration: CalibrationSummary(sampleCount: 16, samplesPerZone: [4, 4, 4, 4], leaveOneOutAccuracy: 1)
        )
        let held = zoneObservations(count: 3, seed: 42)
        let controller = EvaluationController(profile: profile, targetPerZone: 3)
        var clock = 0.0
        XCTAssertEqual(controller.phase, .waitingForArm(.leftTop))

        // Unarmed taps are not counted.
        XCTAssertEqual(controller.handle(held[.leftTop]![0], now: clock), [])

        var final: EvaluationReport?
        for (zoneIndex, zone) in DeskZone.allCases.enumerated() {
            XCTAssertEqual(controller.phase, .waitingForArm(zone))
            XCTAssertEqual(controller.arm(now: clock), [.preparing(zone, inSeconds: 1)])
            clock += 1
            XCTAssertEqual(controller.tick(now: clock), [.armed(zone, nextTap: 1, of: 3)])
            // Tap the wrong zone once in the last zone to check the matrix.
            for index in 0..<3 {
                clock += 0.5
                let source = (zoneIndex == 3 && index == 0) ? held[.leftTop]![1] : held[zone]![index]
                var observation = source
                observation.eventTime = clock - 0.1
                let updates = controller.handle(observation, now: clock)
                if case .finished(let report)? = updates.last { final = report }
            }
        }
        let report = try XCTUnwrap(final)
        XCTAssertEqual(controller.phase, .finished)
        XCTAssertEqual(report.records.count, 12)
        XCTAssertEqual(report.confusionMatrix[3][0], 1)
        XCTAssertEqual(report.overallAccuracy, 11.0 / 12.0, accuracy: 0.001)
        XCTAssertEqual(report.medianResponseLatencyMilliseconds, 100, accuracy: 0.5)
        XCTAssertEqual(report.profileID, profile.id)
        XCTAssertFalse(report.isBalancedAcceptanceSession, "Only 15 taps per zone count as an acceptance session")
    }
}

final class ComparisonControllerTests: XCTestCase {
    func testWalksAllStrategiesAndMeasures() {
        let controller = ComparisonController(profileID: nil, targetPerZone: 3)
        var clock = 0.0
        var finished: ApproachComparison?
        var strategyChanges: [SensingStrategy] = []
        for strategy in SensingStrategy.allCases {
            var desk = SyntheticDesk(seed: UInt64(strategy.rawValue.count) * 31)
            for zone in DeskZone.allCases {
                _ = controller.arm(now: clock)
                clock += 1
                _ = controller.tick(now: clock)
                let stream = desk.stream(seconds: 3.0, taps: [(1.0, zone), (1.6, zone), (2.2, zone)])
                let found = observations(from: stream, strategy: strategy)
                XCTAssertEqual(found.count, 3, "\(strategy) \(zone)")
                for observation in found {
                    clock += 0.5
                    let updates = controller.handle(observation, now: clock)
                    for update in updates {
                        if case .finished(let comparison) = update { finished = comparison }
                        if case .strategyChanged(let next) = update { strategyChanges.append(next) }
                    }
                }
            }
        }
        XCTAssertEqual(strategyChanges, [.active, .hybrid])
        XCTAssertEqual(finished?.scores.count, 3)
        XCTAssertEqual(controller.phase, .finished)
    }
}

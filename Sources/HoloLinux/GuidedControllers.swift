import Foundation
import HoloCore

/// Timing rules shared with the macOS AppModel.
public enum GuidedTiming {
    /// Pause between "get ready" and listening for a zone.
    public static let armDelay = 1.0
    /// Pause after a zone completes before the next zone arms automatically.
    public static let zoneTransitionDelay = 2.0
    /// Ignore further events this long after an accepted tap (one tap, one sample).
    public static let afterTap = 0.40
    public static let afterStart = 0.50
    public static let afterUndo = 0.35
    public static let beforeNegatives = 0.80
}

// MARK: - Calibration

/// The guided calibration flow: ten clean taps per zone, automatic arming,
/// quality retries, undo, zone redo, rejection examples, and consistency review.
public final class CalibrationController {
    public enum Phase: Equatable {
        case idle
        case settling(DeskZone, armAt: Double)
        case armed(DeskZone)
        case zonesComplete
        case collectingNegatives(String)
    }

    public enum Update: Equatable {
        case preparing(DeskZone, inSeconds: Double)
        case armed(DeskZone, nextTap: Int, of: Int)
        case accepted(DeskZone, count: Int, of: Int, quality: String)
        case retry(GuidedCaptureQualityIssue)
        case zoneComplete(DeskZone, next: DeskZone)
        case allZonesCaptured(CrossValidationResult?)
        case reviewUnavailable(String)
        case negativeCaptured(String, count: Int)
        case removedSample(String)
        case zoneCleared(DeskZone)
        case negativesCleared(String)
    }

    public static let negativeLabels = ["Talking", "Typing", "Laptop touch", "Room noise"]

    public private(set) var session: CalibrationSession
    public private(set) var phase: Phase = .idle
    public private(set) var validation: CrossValidationResult?
    public private(set) var lastIssue: GuidedCaptureQualityIssue?
    private var acceptAfter = -Double.infinity

    public init(draft: CalibrationDraft, targetPerZone: Int = CalibrationGuidance.targetTapsPerZone) {
        session = CalibrationSession(draft: draft, targetPerZone: targetPerZone)
    }

    public var strategy: SensingStrategy { session.draft.strategy }
    public var currentZone: DeskZone? { session.currentZone }

    public func start(now: Double) -> [Update] {
        acceptAfter = now + GuidedTiming.afterStart
        return arm(now: now, delay: GuidedTiming.armDelay)
    }

    /// Re-arms the current zone (after a pause or a capture restart).
    public func arm(now: Double, delay: Double = GuidedTiming.armDelay) -> [Update] {
        lastIssue = nil
        guard let zone = session.currentZone else {
            phase = .zonesComplete
            return []
        }
        phase = .settling(zone, armAt: now + delay)
        session.isArmed = false
        session.isSettling = true
        return [.preparing(zone, inSeconds: delay)]
    }

    /// Stops accepting taps until `arm` is called again.
    public func disarm() {
        session.isArmed = false
        session.isSettling = false
        session.negativeLabel = nil
        phase = session.zonesComplete ? .zonesComplete : .idle
    }

    public func tick(now: Double) -> [Update] {
        guard case .settling(let zone, let armAt) = phase, now >= armAt else { return [] }
        guard session.currentZone == zone else { return arm(now: now) }
        phase = .armed(zone)
        session.isSettling = false
        session.isArmed = true
        acceptAfter = max(acceptAfter, now)
        return [.armed(zone, nextTap: session.count(for: zone) + 1, of: session.targetPerZone)]
    }

    public func handle(_ observation: TapObservation, now: Double) -> [Update] {
        guard now >= acceptAfter else { return [] }
        guard observation.feature.strategy == session.draft.strategy else { return [] }

        switch phase {
        case .armed(let zone):
            if let issue = GuidedCaptureQuality.issue(for: observation.feature.quality) {
                lastIssue = issue
                return [.retry(issue)]
            }
            lastIssue = nil
            session.positiveSamples.append(LabeledTap(zone: zone, feature: observation.feature))
            acceptAfter = now + GuidedTiming.afterTap
            let count = session.count(for: zone)
            var updates: [Update] = [.accepted(zone, count: count, of: session.targetPerZone, quality: observation.feature.quality.summary)]
            if let next = session.currentZone {
                if next != zone {
                    updates.append(.zoneComplete(zone, next: next))
                    updates += arm(now: now, delay: GuidedTiming.zoneTransitionDelay)
                }
            } else {
                session.isArmed = false
                session.isSettling = false
                phase = .zonesComplete
                updates.append(review())
            }
            return updates

        case .collectingNegatives(let label):
            // Rejection examples intentionally skip the clean-tap quality gate.
            session.negativeSamples.append(LabeledTap(zone: nil, negativeLabel: label, feature: observation.feature))
            return [.negativeCaptured(label, count: session.negativeCount(for: label))]

        default:
            return []
        }
    }

    private func review() -> Update {
        do {
            let result = try ClassifierEvaluator.leaveOneOut(session.positiveSamples)
            validation = result
            return .allZonesCaptured(result)
        } catch {
            validation = nil
            return .reviewUnavailable(error.localizedDescription)
        }
    }

    public func undo(now: Double) -> [Update] {
        var removed: String?
        if case .collectingNegatives(let label) = phase {
            if let index = session.negativeSamples.lastIndex(where: { $0.negativeLabel == label }) {
                session.negativeSamples.remove(at: index)
                removed = "\(label) example"
            }
            acceptAfter = now + GuidedTiming.afterUndo
            return removed.map { [.removedSample($0)] } ?? []
        }
        if let last = session.positiveSamples.popLast(), let zone = last.zone {
            removed = "\(zone.displayName) tap"
        }
        validation = nil
        acceptAfter = now + GuidedTiming.afterUndo
        guard let removed else { return [] }
        return [.removedSample(removed)] + arm(now: now)
    }

    /// Clears one zone (default: the current or most recent zone) and arms it again.
    public func redoZone(_ requested: DeskZone? = nil, now: Double) -> [Update] {
        let zone: DeskZone?
        if let requested {
            zone = requested
        } else if let current = session.currentZone {
            zone = session.count(for: current) > 0
                ? current
                : DeskZone.allCases.last { $0.rawValue < current.rawValue && session.count(for: $0) > 0 }
        } else {
            zone = DeskZone.allCases.last
        }
        guard let zone else { return [] }
        session.positiveSamples.removeAll { $0.zone == zone }
        session.negativeLabel = nil
        validation = nil
        acceptAfter = now + GuidedTiming.afterStart
        return [.zoneCleared(zone)] + arm(now: now)
    }

    public func startNegatives(label: String, now: Double) {
        guard session.zonesComplete else { return }
        session.negativeLabel = label
        session.isArmed = true
        session.isSettling = false
        phase = .collectingNegatives(label)
        acceptAfter = now + GuidedTiming.beforeNegatives
    }

    public func stopNegatives() {
        session.negativeLabel = nil
        session.isArmed = false
        phase = session.zonesComplete ? .zonesComplete : .idle
    }

    public func clearNegatives(label: String) -> [Update] {
        session.negativeSamples.removeAll { $0.negativeLabel == label }
        return [.negativesCleared(label)]
    }

    /// The zone whose held-out taps agreed least with the others.
    /// The zone whose held-out taps agreed least with the others, or nil when
    /// every zone agreed perfectly.
    public var weakestZone: DeskZone? {
        guard let validation,
              let weakest = validation.perZoneAccuracy.min(by: { $0.accuracy < $1.accuracy }),
              weakest.accuracy < 1 else { return nil }
        return weakest.zone
    }

    public var needsAttention: Bool {
        guard let validation else { return false }
        return validation.accuracy < CalibrationGuidance.minimumCleanAgreement
    }

    /// Trains the classifier and builds the profile, keeping the previous
    /// profile's identity and actions when recalibrating.
    public func makeProfile(replacing existing: HoloProfile?) throws -> HoloProfile {
        let classifier = try TrainedTapClassifier.train(
            positiveExamples: session.positiveSamples,
            negativeExamples: session.negativeSamples
        )
        let crossValidation = try validation ?? ClassifierEvaluator.leaveOneOut(session.positiveSamples)
        let summary = CalibrationSummary(
            sampleCount: session.positiveSamples.count,
            samplesPerZone: DeskZone.allCases.map { session.count(for: $0) },
            leaveOneOutAccuracy: crossValidation.accuracy
        )
        var profile = HoloProfile(
            id: existing?.id ?? UUID(),
            name: session.draft.name,
            surfaceDescription: session.draft.surfaceDescription,
            laptopPositionNote: session.draft.laptopPositionNote,
            classifier: classifier,
            calibration: summary,
            zones: existing?.zones ?? DeskZone.allCases.map { ZoneConfiguration(zone: $0) }
        )
        if let existing { profile.createdAt = existing.createdAt }
        return profile
    }
}

// MARK: - Evaluation

/// The guided held-out accuracy test: fifteen armed taps per zone. Every
/// detected event while armed is recorded, including classifier rejections.
public final class EvaluationController {
    public enum Phase: Equatable {
        case waitingForArm(DeskZone)
        case settling(DeskZone, armAt: Double)
        case armed(DeskZone)
        case finished
    }

    public enum Update: Equatable {
        case preparing(DeskZone, inSeconds: Double)
        case armed(DeskZone, nextTap: Int, of: Int)
        case recorded(EvaluationRecord, count: Int, of: Int)
        case zoneComplete(DeskZone, next: DeskZone)
        case finished(EvaluationReport)
    }

    public let profile: HoloProfile
    public private(set) var session: EvaluationSession
    public private(set) var phase: Phase
    private var acceptAfter = -Double.infinity

    public init(profile: HoloProfile, targetPerZone: Int = EvaluationAcceptance.tapsPerZone, startedAt: Date = Date()) {
        self.profile = profile
        session = EvaluationSession(startedAt: startedAt, targetPerZone: targetPerZone)
        phase = .waitingForArm(DeskZone.allCases[0])
    }

    public var currentZone: DeskZone? { session.currentZone }

    private func count(for zone: DeskZone) -> Int {
        session.records.filter { $0.expectedZone == zone }.count
    }

    /// Explicitly arms the current zone, as the macOS accuracy test requires.
    public func arm(now: Double) -> [Update] {
        guard let zone = session.currentZone else { return [] }
        switch phase {
        case .waitingForArm, .armed, .settling:
            phase = .settling(zone, armAt: now + GuidedTiming.armDelay)
            session.isArmed = false
            session.isSettling = true
            return [.preparing(zone, inSeconds: GuidedTiming.armDelay)]
        case .finished:
            return []
        }
    }

    public func disarm() {
        guard let zone = session.currentZone else { return }
        session.isArmed = false
        session.isSettling = false
        phase = .waitingForArm(zone)
    }

    public func tick(now: Double) -> [Update] {
        guard case .settling(let zone, let armAt) = phase, now >= armAt else { return [] }
        phase = .armed(zone)
        session.isSettling = false
        session.isArmed = true
        acceptAfter = now
        return [.armed(zone, nextTap: count(for: zone) + 1, of: session.targetPerZone)]
    }

    /// `responseTime` is when the decision is available (defaults to `now`).
    public func handle(_ observation: TapObservation, now: Double, responseTime: Double? = nil) -> [Update] {
        guard case .armed(let zone) = phase, now >= acceptAfter else { return [] }
        var decision = profile.classifier.predict(observation.feature)
        decision.processingLatencyMilliseconds = observation.processingLatencyMilliseconds
        let record = EvaluationRecord(
            expectedZone: zone,
            decision: decision,
            responseLatencyMilliseconds: observation.responseLatencyMilliseconds(now: responseTime ?? now),
            capturedAt: observation.feature.capturedAt,
            feature: observation.feature
        )
        session.records.append(record)
        acceptAfter = now + GuidedTiming.afterTap
        let zoneCount = count(for: zone)
        var updates: [Update] = [.recorded(record, count: zoneCount, of: session.targetPerZone)]
        if let next = session.currentZone {
            if next != zone {
                session.isArmed = false
                session.isSettling = false
                phase = .waitingForArm(next)
                updates.append(.zoneComplete(zone, next: next))
            }
        } else {
            phase = .finished
            session.isArmed = false
            updates.append(.finished(report()))
        }
        return updates
    }

    public func report(completedAt: Date = Date()) -> EvaluationReport {
        EvaluationReport(
            profileID: profile.id,
            profileName: profile.name,
            strategy: profile.sensingStrategy,
            startedAt: session.startedAt,
            completedAt: completedAt,
            records: session.records,
            notes: "Guided held-out session on Linux; \(session.targetPerZone) taps per zone."
        )
    }
}

// MARK: - Sensing comparison

/// Collects three taps per zone for each sensing strategy and measures which
/// one separates the zones best on this desk.
public final class ComparisonController {
    public enum Phase: Equatable {
        case waitingForArm(SensingStrategy, DeskZone)
        case settling(SensingStrategy, DeskZone, armAt: Double)
        case armed(SensingStrategy, DeskZone)
        case finished
    }

    public enum Update: Equatable {
        case preparing(SensingStrategy, DeskZone, inSeconds: Double)
        case armed(SensingStrategy, DeskZone, nextTap: Int, of: Int)
        case accepted(SensingStrategy, DeskZone, count: Int, of: Int)
        case retry(GuidedCaptureQualityIssue)
        case setComplete(next: SensingStrategy, DeskZone)
        case strategyChanged(SensingStrategy)
        case finished(ApproachComparison)
        case failed(String)
    }

    public private(set) var session: BenchmarkSession
    public private(set) var phase: Phase
    public let profileID: UUID?
    private var acceptAfter = -Double.infinity

    public init(profileID: UUID?, targetPerZone: Int = 3) {
        self.profileID = profileID
        session = BenchmarkSession(targetPerZone: targetPerZone)
        phase = .waitingForArm(.passive, DeskZone.allCases[0])
    }

    public var currentStrategy: SensingStrategy? { session.currentStrategy }

    public func arm(now: Double) -> [Update] {
        guard let strategy = session.currentStrategy, let zone = session.currentZone else { return [] }
        phase = .settling(strategy, zone, armAt: now + GuidedTiming.armDelay)
        session.isArmed = false
        session.isSettling = true
        return [.preparing(strategy, zone, inSeconds: GuidedTiming.armDelay)]
    }

    public func disarm() {
        guard let strategy = session.currentStrategy, let zone = session.currentZone else { return }
        session.isArmed = false
        session.isSettling = false
        phase = .waitingForArm(strategy, zone)
    }

    public func tick(now: Double) -> [Update] {
        guard case .settling(let strategy, let zone, let armAt) = phase, now >= armAt else { return [] }
        phase = .armed(strategy, zone)
        session.isArmed = true
        session.isSettling = false
        acceptAfter = now
        return [.armed(strategy, zone, nextTap: session.count(strategy: strategy, zone: zone) + 1, of: session.targetPerZone)]
    }

    public func handle(_ observation: TapObservation, now: Double) -> [Update] {
        guard case .armed(let strategy, let zone) = phase,
              now >= acceptAfter,
              observation.feature.strategy == strategy else { return [] }
        if let issue = GuidedCaptureQuality.issue(for: observation.feature.quality) {
            return [.retry(issue)]
        }
        session.samples.append(BenchmarkSample(
            labeledTap: LabeledTap(zone: zone, feature: observation.feature),
            processingLatencyMilliseconds: observation.processingLatencyMilliseconds
        ))
        acceptAfter = now + GuidedTiming.afterTap
        var updates: [Update] = [.accepted(strategy, zone, count: session.count(strategy: strategy, zone: zone), of: session.targetPerZone)]
        guard let nextStrategy = session.currentStrategy, let nextZone = session.currentZone else {
            phase = .finished
            session.isArmed = false
            do {
                updates.append(.finished(try ApproachComparison.measure(session.samples, profileID: profileID)))
            } catch {
                updates.append(.failed(error.localizedDescription))
            }
            return updates
        }
        if nextStrategy != strategy || nextZone != zone {
            session.isArmed = false
            session.isSettling = false
            phase = .waitingForArm(nextStrategy, nextZone)
            updates.append(.setComplete(next: nextStrategy, nextZone))
            if nextStrategy != strategy { updates.append(.strategyChanged(nextStrategy)) }
        }
        return updates
    }
}

import Foundation
import HoloCore
#if canImport(Glibc)
import Glibc
#endif

/// The background listener (`holo run`): the Linux equivalent of the macOS
/// Desk view. It classifies taps with the active profile and runs the
/// assigned actions, releases the microphone while a guided session or a
/// user pause is active, reloads profiles when they change, and keeps
/// retrying when the microphone or route is unavailable.
public final class LiveService {
    public struct Options {
        public var allowExternalInput = false
        public var allowExternalOutput = false
        public var routeCheckInterval = 5.0
        public var retryInterval = 3.0
        public var supervisionInterval = 0.5

        public init() {}
    }

    public enum State: Equatable {
        case starting
        case waitingForProfile
        case paused(String)
        case blocked(String)
        case failed(String)
        case listening(String)
    }

    public private(set) var state: State = .starting {
        didSet {
            guard state != oldValue else { return }
            describe(state)
        }
    }

    private let paths: HoloPaths
    private let options: Options
    private let loop: EventLoop
    private let control: ServiceControl
    private let routeInspector: RouteInspector
    private let dispatcher: LinuxActionDispatcher
    private let notifier: DesktopNotifier?
    private let makeEngine: (CaptureSettings) -> CaptureEngine
    private let log: (String) -> Void

    private var library: ProfileLibrary?
    private var profile: HoloProfile?
    private var capture: CaptureSettings?
    private var engine: CaptureEngine?
    private var fingerprint = ""
    private var lastLoadError: String?
    private var nextSupervision = 0.0
    private var nextRouteCheck = 0.0
    private var retryAt = 0.0

    public private(set) var acceptedCount = 0
    public private(set) var rejectedCount = 0
    /// Called after every classified tap (used by tests).
    public var onDecision: ((ClassificationDecision) -> Void)?

    public init(
        paths: HoloPaths,
        options: Options = Options(),
        loop: EventLoop = EventLoop(),
        control: ServiceControl,
        routeInspector: RouteInspector = RouteInspector(),
        dispatcher: LinuxActionDispatcher = LinuxActionDispatcher(),
        notifier: DesktopNotifier? = DesktopNotifier(),
        makeEngine: @escaping (CaptureSettings) -> CaptureEngine = { CaptureEngine(settings: $0) },
        log: @escaping (String) -> Void
    ) {
        self.paths = paths
        self.options = options
        self.loop = loop
        self.control = control
        self.routeInspector = routeInspector
        self.dispatcher = dispatcher
        self.notifier = notifier
        self.makeEngine = makeEngine
        self.log = log
    }

    /// Runs until SIGINT/SIGTERM. Returns a process exit status.
    public func run() -> Int32 {
        guard control.acquireDaemonLock() else {
            log("Another Holo service is already running (pid \(control.runningServicePID().map(String.init) ?? "?")).")
            return 1
        }
        defer { control.releaseDaemonLock() }
        dispatcher.onAsyncError = { [weak self] message in
            self?.loop.post { self?.reportActionFailure(message) }
        }
        loop.handleSignals([SIGINT, SIGTERM, SIGHUP])
        loop.onSignal = { [weak self] signalNumber in
            guard let self else { return }
            if signalNumber == SIGHUP {
                self.log("Reloading profiles and settings.")
                self.fingerprint = ""
                self.nextSupervision = 0
            } else {
                self.loop.stop()
            }
        }
        loop.tickInterval = 0.25
        loop.onTick = { [weak self] in self?.supervise(now: HoloClock.now()) }
        log("Holo service started (data: \(paths.dataRoot.path)).")
        supervise(now: HoloClock.now())
        loop.run()
        stopCapture()
        log("Holo service stopped.")
        return 0
    }

    // MARK: Supervision

    public func supervise(now: Double) {
        guard now >= nextSupervision else { return }
        nextSupervision = now + options.supervisionInterval

        reloadIfChanged()

        if let guided = control.activeGuidedSession() {
            pause(because: "a guided session is running (\(guided.split(separator: " ").dropFirst().joined(separator: " ")))")
            return
        }
        if control.isPausedByUser {
            pause(because: "paused with `holo pause`")
            return
        }
        guard let profile, let capture else {
            stopCapture()
            state = .waitingForProfile
            return
        }

        if let engine, engine.isRunning {
            if now >= nextRouteCheck {
                nextRouteCheck = now + options.routeCheckInterval
                let check = routeCheck(capture: capture, strategy: profile.sensingStrategy)
                if let message = check.issueDescription {
                    stopCapture()
                    block(message, now: now)
                }
            }
            return
        }

        guard now >= retryAt else { return }
        let check = routeCheck(capture: capture, strategy: profile.sensingStrategy)
        if let message = check.issueDescription {
            block(message, now: now)
            return
        }
        for warning in check.warnings where state == .starting || state == .waitingForProfile || isPaused {
            log("warning: \(warning)")
        }
        startCapture(profile: profile, capture: capture, now: now)
    }

    private var isPaused: Bool {
        if case .paused = state { return true }
        return false
    }

    private func pause(because reason: String) {
        stopCapture()
        state = .paused(reason)
        retryAt = 0
    }

    private func block(_ message: String, now: Double) {
        retryAt = now + options.routeCheckInterval
        if state != .blocked(message) {
            state = .blocked(message)
            notifyProblem(message)
        }
    }

    private func routeCheck(capture: CaptureSettings, strategy: SensingStrategy) -> RouteCheck {
        routeInspector.check(
            settings: capture,
            strategy: strategy,
            allowExternalInput: options.allowExternalInput || capture.allowsExternalInput,
            allowExternalOutput: options.allowExternalOutput || capture.allowsExternalOutput
        )
    }

    private func reloadIfChanged() {
        do {
            if library == nil { library = try ProfileLibrary(paths: paths) }
            guard var library else { return }
            let current = library.fingerprint()
            guard current != fingerprint else { return }
            fingerprint = current
            try library.reload()
            self.library = library
            lastLoadError = nil
            let previousProfile = profile
            let previousCapture = capture
            profile = library.activeProfile
            capture = profile.map(library.captureSettings(for:))
            if let profile {
                let changedSignal = previousProfile?.id != profile.id
                    || previousProfile?.classifier != profile.classifier
                    || previousCapture != capture
                if changedSignal {
                    if previousProfile != nil { log("Profile changed; restarting capture.") }
                    stopCapture()
                    retryAt = 0
                } else if previousProfile != profile {
                    log("Actions updated for \"\(profile.name)\".")
                }
            }
        } catch {
            // Report each distinct problem once; it is retried when files change.
            let message = error.localizedDescription
            if message != lastLoadError {
                lastLoadError = message
                log("Could not load profiles: \(message)")
                notifyProblem("Could not load profiles: \(message)")
            }
        }
    }

    // MARK: Capture

    private func startCapture(profile: HoloProfile, capture: CaptureSettings, now: Double) {
        let engine = makeEngine(capture)
        do {
            try engine.start(strategy: profile.sensingStrategy) { [weak self] event in
                self?.loop.post { self?.handle(event) }
            }
            self.engine = engine
            nextRouteCheck = now + options.routeCheckInterval
            let wasProblem: Bool
            switch state {
            case .blocked, .failed: wasProblem = true
            default: wasProblem = false
            }
            state = .listening(listeningDescription(profile: profile, engine: engine))
            if wasProblem, library?.config.notifications == true {
                notifier?.notify(summary: "Holo is listening again", body: profile.name, transient: true)
            }
        } catch {
            retryAt = now + options.retryInterval
            let message = error.localizedDescription
            if state != .failed(message) {
                state = .failed(message)
                notifyProblem(message)
            }
        }
    }

    private func stopCapture() {
        engine?.stop()
        engine = nil
    }

    private func listeningDescription(profile: HoloProfile, engine: CaptureEngine) -> String {
        let status = engine.status
        let channels = status.map { "\($0.channels) ch \($0.sampleFormat) @ \(Int($0.sampleRate)) Hz" } ?? ""
        return "\"\(profile.name)\" • \(profile.sensingStrategy.displayName) • \(engine.settings.device) \(channels)"
    }

    private func handle(_ event: CaptureEngine.Event) {
        switch event {
        case .observation(let observation, let generation):
            guard let engine, engine.isCurrent(generation), let profile else { return }
            classify(observation, profile: profile)
        case .level:
            break
        case .failed(let message, let generation):
            guard let engine, engine.isCurrent(generation) else { return }
            stopCapture()
            let now = HoloClock.now()
            retryAt = now + options.retryInterval
            state = .failed(message)
            notifyProblem(message)
        }
    }

    private func classify(_ observation: TapObservation, profile: HoloProfile) {
        var decision = profile.classifier.predict(observation.feature)
        decision.processingLatencyMilliseconds = observation.processingLatencyMilliseconds
        let latency = observation.responseLatencyMilliseconds()
        onDecision?(decision)
        guard let zone = decision.zone,
              LocalActionDispatchPolicy.allowsAutomaticDispatch(for: decision, isDeskActive: true) else {
            rejectedCount += 1
            log("Rejected • \(decision.rejectionReason?.displayName ?? "low confidence") • \(observation.feature.quality.summary) signal")
            return
        }
        acceptedCount += 1
        let action = profile.action(for: zone)
        let summary = LinuxActionPlanner.summary(for: action)
        log(String(format: "%@ • %d%% • %.0f ms • %@", zone.displayName, Int((decision.confidence * 100).rounded()), latency, summary))
        do {
            try dispatcher.perform(action)
        } catch {
            reportActionFailure("\(zone.displayName): \(error.localizedDescription)")
            return
        }
        if library?.config.notifications == true {
            notifier?.notify(summary: "Holo · \(zone.displayName)", body: summary, transient: true)
        }
    }

    private func reportActionFailure(_ message: String) {
        log("Action failed • \(message)")
        if library?.config.notifications == true {
            notifier?.notify(summary: "Holo action failed", body: message, transient: false)
        }
    }

    private func notifyProblem(_ message: String) {
        guard library?.config.notifications == true else { return }
        notifier?.notify(summary: "Holo stopped listening", body: message, transient: false)
    }

    private func describe(_ state: State) {
        switch state {
        case .starting: break
        case .waitingForProfile: log("No calibrated desk profile yet. Run `holo calibrate`; the service will pick it up automatically.")
        case .paused(let reason): log("Paused: \(reason). Microphone released.")
        case .blocked(let message): log("Not listening: \(message)")
        case .failed(let message): log("Capture failed: \(message) Retrying.")
        case .listening(let detail): log("Listening • \(detail)")
        }
    }
}

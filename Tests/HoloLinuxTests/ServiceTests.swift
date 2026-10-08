import HoloCore
@testable import HoloLinux
import XCTest
#if canImport(Glibc)
import Glibc
#endif

final class StorageTests: XCTestCase {
    private func makeProfile(_ name: String) throws -> HoloProfile {
        let samples = zoneObservations(count: 3)
        let classifier = try TrainedTapClassifier.train(positiveExamples: DeskZone.allCases.flatMap { zone in
            samples[zone]!.map { LabeledTap(zone: zone, feature: $0.feature) }
        })
        return HoloProfile(
            name: name,
            surfaceDescription: "Oak",
            laptopPositionNote: "Center",
            classifier: classifier,
            calibration: CalibrationSummary(sampleCount: 12, samplesPerZone: [3, 3, 3, 3], leaveOneOutAccuracy: 1)
        )
    }

    func testStandardPathsFollowXDG() {
        let paths = HoloPaths.standard(environment: [
            "HOME": "/home/elia",
            "XDG_RUNTIME_DIR": "/run/user/1000"
        ])
        XCTAssertEqual(paths.dataRoot.path, "/home/elia/.local/share/Holo")
        XCTAssertEqual(paths.configFile.path, "/home/elia/.config/holo/config.json")
        XCTAssertEqual(paths.runtimeDirectory.path, "/run/user/1000/holo")
        XCTAssertEqual(paths.profilesDirectory.path, "/home/elia/.local/share/Holo/Profiles")
        let overridden = HoloPaths.standard(environment: ["HOME": "/h", "XDG_DATA_HOME": "/d", "HOLO_CONFIG_DIR": "/c"])
        XCTAssertEqual(overridden.dataRoot.path, "/d/Holo")
        XCTAssertEqual(overridden.configDirectory.path, "/c")
    }

    func testLibrarySavesActivatesFindsAndDeletes() throws {
        let paths = testPaths()
        var library = try ProfileLibrary(paths: paths)
        XCTAssertNil(library.activeProfile)
        let kitchen = try makeProfile("Kitchen")
        let office = try makeProfile("Office")
        try library.save(kitchen, capture: CaptureSettings(device: "plughw:0,6", channels: 2), makeActive: true)
        try library.save(office, capture: CaptureSettings(), makeActive: false)

        let reloaded = try ProfileLibrary(paths: paths)
        XCTAssertEqual(reloaded.profiles.count, 2)
        XCTAssertEqual(reloaded.activeProfile?.id, kitchen.id)
        XCTAssertEqual(reloaded.captureSettings(for: kitchen), CaptureSettings(device: "plughw:0,6", channels: 2))
        XCTAssertEqual(reloaded.find("office")?.id, office.id)
        XCTAssertEqual(reloaded.find(String(office.id.uuidString.prefix(6)))?.id, office.id)
        XCTAssertNil(reloaded.find("garage"))

        let before = library.fingerprint()
        Thread.sleep(forTimeInterval: 0.02)
        try library.activate(office)
        XCTAssertNotEqual(library.fingerprint(), before)
        try library.delete(office)
        XCTAssertNil(library.config.activeProfileID)
        XCTAssertEqual(library.activeProfile?.id, kitchen.id)
    }

    func testConfigToleratesMissingKeys() throws {
        let config = try JSONDecoder().decode(LinuxConfig.self, from: Data("{\"notifications\": false}".utf8))
        XCTAssertFalse(config.notifications)
        XCTAssertEqual(config.defaultDevice, "default")
        XCTAssertTrue(config.captureByProfile.isEmpty)
    }

    func testCaptureSettingsDecodeOlderFilesAndKeepPermissions() throws {
        let old = try JSONDecoder().decode(CaptureSettings.self, from: Data("{\"device\": \"plughw:0,6\", \"channels\": 2, \"sampleRate\": 48000}".utf8))
        XCTAssertEqual(old, CaptureSettings(device: "plughw:0,6", channels: 2))
        let allowed = CaptureSettings(allowsExternalInput: true)
        let roundTrip = try JSONDecoder().decode(CaptureSettings.self, from: JSONEncoder().encode(allowed))
        XCTAssertTrue(roundTrip.allowsExternalInput)
        XCTAssertFalse(roundTrip.allowsExternalOutput)
    }

    func testCaptureSettingsClampChannels() {
        XCTAssertEqual(CaptureSettings(channels: 4).channels, 2)
        XCTAssertEqual(CaptureSettings(channels: 0).channels, 1)
    }
}

final class ServiceControlTests: XCTestCase {
    func testGuidedSessionsAreExclusiveAndVisible() throws {
        let directory = temporaryDirectory()
        let first = try ServiceControl(directory: directory)
        let second = try ServiceControl(directory: directory)
        XCTAssertNil(second.activeGuidedSession())
        XCTAssertTrue(first.beginGuidedSession(name: "calibrate"))
        XCTAssertFalse(second.beginGuidedSession(name: "monitor"))
        XCTAssertEqual(second.activeGuidedSession(), "\(getpid()) calibrate")
        first.releaseGuidedSession()
        XCTAssertNil(second.activeGuidedSession())
        XCTAssertTrue(second.beginGuidedSession(name: "monitor"))
    }

    func testDaemonLockAndPauseFlag() throws {
        let directory = temporaryDirectory()
        let service = try ServiceControl(directory: directory)
        let other = try ServiceControl(directory: directory)
        XCTAssertNil(other.runningServicePID())
        XCTAssertTrue(service.acquireDaemonLock())
        XCTAssertFalse(other.acquireDaemonLock())
        XCTAssertEqual(other.runningServicePID(), getpid())
        service.releaseDaemonLock()
        XCTAssertNil(other.runningServicePID())

        XCTAssertFalse(service.isPausedByUser)
        try other.setPausedByUser(true)
        XCTAssertTrue(service.isPausedByUser)
        try other.setPausedByUser(false)
        XCTAssertFalse(service.isPausedByUser)
    }
}

/// Plays a prepared multichannel stream in real time, then idles until stopped.
final class ScriptedSource: AudioInputSource {
    let channels: [[Float]]
    private var thread: Thread?
    private let lock = NSLock()
    private var stopped = false
    private var done: DispatchSemaphore?

    init(channels: [[Float]]) {
        self.channels = channels
    }

    func start(onBuffer: @escaping ([[Float]], Double) -> Void, onFailure: @escaping (String) -> Void) throws -> CaptureStatus {
        let done = DispatchSemaphore(value: 0)
        self.done = done
        let channels = self.channels
        let thread = Thread { [weak self] in
            let start = HoloClock.now()
            var offset = 0
            let total = channels[0].count
            while offset < total {
                guard let self, !self.isStopped else { break }
                let end = min(offset + 480, total)
                let due = start + Double(end) / 48_000
                let wait = due - HoloClock.now()
                if wait > 0 { Thread.sleep(forTimeInterval: wait) }
                onBuffer(channels.map { Array($0[offset..<end]) }, start + Double(offset) / 48_000)
                offset = end
            }
            while let self, !self.isStopped { Thread.sleep(forTimeInterval: 0.01) }
            done.signal()
        }
        self.thread = thread
        thread.start()
        return CaptureStatus(device: "scripted", channels: channels.count, sampleRate: 48_000, periodFrames: 480, sampleFormat: "float32")
    }

    private var isStopped: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopped
    }

    func stop() {
        lock.lock()
        stopped = true
        lock.unlock()
        done?.wait()
        done = nil
    }
}

final class LiveServiceTests: XCTestCase {
    func testClassifiesTapsRunsActionsAndPausesForGuidedSessions() throws {
        let paths = testPaths()
        var library = try ProfileLibrary(paths: paths)
        let samples = zoneObservations(count: 4)
        let classifier = try TrainedTapClassifier.train(positiveExamples: DeskZone.allCases.flatMap { zone in
            samples[zone]!.map { LabeledTap(zone: zone, feature: $0.feature) }
        })
        var profile = HoloProfile(
            name: "Desk",
            surfaceDescription: "",
            laptopPositionNote: "",
            classifier: classifier,
            calibration: CalibrationSummary(sampleCount: 16, samplesPerZone: [4, 4, 4, 4], leaveOneOutAccuracy: 1)
        )
        let marker = paths.dataRoot.appendingPathComponent("taps.log").path
        profile.zones[0].action = ZoneActionConfiguration(kind: .runShellCommand, text: "echo LR >> '\(marker)'")
        profile.zones[3].action = ZoneActionConfiguration(kind: .runShellCommand, text: "echo RF >> '\(marker)'")
        library.config.notifications = false
        try library.save(profile, capture: CaptureSettings(device: "default", channels: 2), makeActive: true)

        var desk = SyntheticDesk(seed: 11)
        let stream = desk.stream(seconds: 4, taps: [(1.2, .leftTop), (2.0, .rightBottom), (2.8, .leftBottom)])
        let runner = MockRunner(responses: [
            "wpctl inspect @DEFAULT_AUDIO_SOURCE@": CommandResult(status: 0, output: Fixtures.internalNode),
            "wpctl inspect 45": CommandResult(status: 0, output: Fixtures.internalDevice)
        ])
        let control = try ServiceControl(directory: paths.runtimeDirectory)
        let loop = EventLoop()
        var log: [String] = []
        let logLock = NSLock()
        var options = LiveService.Options()
        options.supervisionInterval = 0.1
        let service = LiveService(
            paths: paths,
            options: options,
            loop: loop,
            control: control,
            routeInspector: RouteInspector(runner: runner),
            notifier: nil,
            makeEngine: { settings in CaptureEngine(settings: settings) { _ in ScriptedSource(channels: stream) } },
            log: { message in
                logLock.lock()
                log.append(message)
                logLock.unlock()
            }
        )
        let finished = expectation(description: "service stopped")
        let thread = Thread {
            XCTAssertEqual(service.run(), 0)
            finished.fulfill()
        }
        thread.start()
        Thread.sleep(forTimeInterval: 4.6)

        // A guided session in another "process" pauses the service.
        let guided = try ServiceControl(directory: paths.runtimeDirectory)
        XCTAssertTrue(guided.beginGuidedSession(name: "monitor"))
        Thread.sleep(forTimeInterval: 0.5)
        guided.releaseGuidedSession()
        Thread.sleep(forTimeInterval: 0.5)
        loop.post { loop.stop() }
        wait(for: [finished], timeout: 5)

        logLock.lock()
        let lines = log
        logLock.unlock()
        XCTAssertTrue(lines.contains { $0.hasPrefix("Listening • \"Desk\"") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Left Rear •") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Right Front •") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.hasPrefix("Left Front •") }, lines.joined(separator: "\n"))
        XCTAssertTrue(lines.contains { $0.contains("Paused: a guided session is running (monitor)") }, lines.joined(separator: "\n"))
        XCTAssertEqual(service.acceptedCount, 3)

        // Give the shell actions a moment to finish writing.
        Thread.sleep(forTimeInterval: 0.5)
        let written = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
        XCTAssertEqual(written.split(separator: "\n").sorted(), ["LR", "RF"])
    }

    func testWaitsForAProfileAndRefusesExternalMicrophones() throws {
        let paths = testPaths()
        let control = try ServiceControl(directory: paths.runtimeDirectory)
        let runner = MockRunner(responses: [
            "wpctl inspect @DEFAULT_AUDIO_SOURCE@": CommandResult(status: 0, output: Fixtures.usbNode)
        ])
        var log: [String] = []
        let service = LiveService(
            paths: paths,
            control: control,
            routeInspector: RouteInspector(runner: runner),
            notifier: nil,
            makeEngine: { settings in CaptureEngine(settings: settings) { _ in ScriptedSource(channels: [[0], [0]]) } },
            log: { log.append($0) }
        )
        service.supervise(now: 1)
        XCTAssertEqual(service.state, .waitingForProfile)

        var library = try ProfileLibrary(paths: paths)
        let samples = zoneObservations(count: 3)
        let classifier = try TrainedTapClassifier.train(positiveExamples: DeskZone.allCases.flatMap { zone in
            samples[zone]!.map { LabeledTap(zone: zone, feature: $0.feature) }
        })
        try library.save(HoloProfile(
            name: "Desk", surfaceDescription: "", laptopPositionNote: "",
            classifier: classifier,
            calibration: CalibrationSummary(sampleCount: 12, samplesPerZone: [3, 3, 3, 3], leaveOneOutAccuracy: 1)
        ), capture: CaptureSettings(), makeActive: true)
        service.supervise(now: 2)
        guard case .blocked(let message) = service.state else {
            return XCTFail("Expected the USB microphone to be refused, got \(service.state)")
        }
        XCTAssertTrue(message.contains("built-in microphone"))

        // A profile calibrated with --allow-external-input keeps that permission.
        try library.save(library.activeProfile!, capture: CaptureSettings(allowsExternalInput: true), makeActive: true)
        Thread.sleep(forTimeInterval: 0.05)
        service.supervise(now: 10)
        guard case .listening = service.state else {
            return XCTFail("Expected the allowed USB microphone to be used, got \(service.state)")
        }

        try control.setPausedByUser(true)
        service.supervise(now: 11)
        XCTAssertEqual(service.state, .paused("paused with `holo pause`"))
    }
}

import Foundation
import HoloCore
#if canImport(Glibc)
import Glibc
#endif

/// Where the Linux port keeps its files. Profiles and reports use the same
/// layout as the macOS app under the XDG data directory.
public struct HoloPaths: Equatable {
    public var dataRoot: URL
    public var configDirectory: URL
    public var runtimeDirectory: URL

    public init(dataRoot: URL, configDirectory: URL, runtimeDirectory: URL) {
        self.dataRoot = dataRoot
        self.configDirectory = configDirectory
        self.runtimeDirectory = runtimeDirectory
    }

    /// Honors HOLO_DATA_DIR / HOLO_CONFIG_DIR / HOLO_RUNTIME_DIR overrides, then XDG variables.
    public static func standard(environment: [String: String] = ProcessInfo.processInfo.environment) -> HoloPaths {
        let home = environment["HOME"] ?? NSHomeDirectory()
        func directory(_ override: String, _ xdg: String, _ fallback: String, _ leaf: String) -> URL {
            if let value = environment[override], !value.isEmpty {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
            let base = environment[xdg].flatMap { $0.isEmpty ? nil : $0 } ?? (home + "/" + fallback)
            return URL(fileURLWithPath: base, isDirectory: true).appendingPathComponent(leaf, isDirectory: true)
        }
        let runtime: URL
        if let value = environment["HOLO_RUNTIME_DIR"], !value.isEmpty {
            runtime = URL(fileURLWithPath: value, isDirectory: true)
        } else if let xdg = environment["XDG_RUNTIME_DIR"], !xdg.isEmpty {
            runtime = URL(fileURLWithPath: xdg, isDirectory: true).appendingPathComponent("holo", isDirectory: true)
        } else {
            runtime = URL(fileURLWithPath: "/tmp/holo-\(getuid())", isDirectory: true)
        }
        return HoloPaths(
            dataRoot: directory("HOLO_DATA_DIR", "XDG_DATA_HOME", ".local/share", "Holo"),
            configDirectory: directory("HOLO_CONFIG_DIR", "XDG_CONFIG_HOME", ".config", "holo"),
            runtimeDirectory: runtime
        )
    }

    public var profilesDirectory: URL { dataRoot.appendingPathComponent("Profiles", isDirectory: true) }
    public var evaluationsDirectory: URL { dataRoot.appendingPathComponent("Evaluations", isDirectory: true) }
    public var debugCapturesDirectory: URL { dataRoot.appendingPathComponent("DebugCaptures", isDirectory: true) }
    public var comparisonFile: URL { dataRoot.appendingPathComponent("approach-comparison.json") }
    public var configFile: URL { configDirectory.appendingPathComponent("config.json") }

    public func profileStore() throws -> ProfileStore {
        try ProfileStore(directory: profilesDirectory)
    }

    public func evaluationStore() throws -> EvaluationStore {
        try EvaluationStore(directory: evaluationsDirectory)
    }

    public func comparisonStore() throws -> ApproachComparisonStore {
        try FileManager.default.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        return try ApproachComparisonStore(fileURL: comparisonFile)
    }
}

/// Settings that the macOS app keeps in its UI state.
public struct LinuxConfig: Codable, Equatable, Sendable {
    public var activeProfileID: UUID?
    /// Show a desktop notification for each accepted tap (the Linux stand-in
    /// for the macOS desk map highlight) and for service problems.
    public var notifications: Bool
    /// Capture device used for new calibrations.
    public var defaultDevice: String
    /// The capture path each profile was calibrated with, keyed by profile id.
    public var captureByProfile: [String: CaptureSettings]

    public init(
        activeProfileID: UUID? = nil,
        notifications: Bool = true,
        defaultDevice: String = CaptureSettings.defaultDevice,
        captureByProfile: [String: CaptureSettings] = [:]
    ) {
        self.activeProfileID = activeProfileID
        self.notifications = notifications
        self.defaultDevice = defaultDevice
        self.captureByProfile = captureByProfile
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeProfileID = try container.decodeIfPresent(UUID.self, forKey: .activeProfileID)
        notifications = try container.decodeIfPresent(Bool.self, forKey: .notifications) ?? true
        defaultDevice = try container.decodeIfPresent(String.self, forKey: .defaultDevice) ?? CaptureSettings.defaultDevice
        captureByProfile = try container.decodeIfPresent([String: CaptureSettings].self, forKey: .captureByProfile) ?? [:]
    }

    public func captureSettings(for profileID: UUID) -> CaptureSettings? {
        captureByProfile[profileID.uuidString]
    }

    public mutating func setCaptureSettings(_ settings: CaptureSettings, for profileID: UUID) {
        captureByProfile[profileID.uuidString] = settings
    }
}

public struct ConfigStore {
    public let fileURL: URL

    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    public func load() throws -> LinuxConfig {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return LinuxConfig() }
        return try JSONDecoder().decode(LinuxConfig.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ config: LinuxConfig) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: fileURL, options: .atomic)
    }

    public func modificationDate() -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: fileURL.path))?[.modificationDate] as? Date
    }
}

/// Profiles plus the Linux-only settings around them.
public struct ProfileLibrary {
    public let paths: HoloPaths
    public let store: ProfileStore
    public let configStore: ConfigStore
    public private(set) var profiles: [HoloProfile]
    public var config: LinuxConfig

    public init(paths: HoloPaths) throws {
        self.paths = paths
        self.store = try paths.profileStore()
        self.configStore = ConfigStore(fileURL: paths.configFile)
        self.profiles = try store.loadAll()
        self.config = try configStore.load()
    }

    /// The configured profile, or the most recently updated one.
    public var activeProfile: HoloProfile? {
        if let id = config.activeProfileID, let match = profiles.first(where: { $0.id == id }) {
            return match
        }
        return profiles.first
    }

    public func captureSettings(for profile: HoloProfile) -> CaptureSettings {
        config.captureSettings(for: profile.id) ?? CaptureSettings(device: config.defaultDevice, channels: 1)
    }

    /// Finds a profile by exact name, id, or unique id prefix.
    public func find(_ query: String) -> HoloProfile? {
        let lowered = query.lowercased()
        if let byName = profiles.filter({ $0.name.lowercased() == lowered }).first { return byName }
        let matches = profiles.filter { $0.id.uuidString.lowercased().hasPrefix(lowered) }
        return matches.count == 1 ? matches[0] : nil
    }

    public mutating func save(_ profile: HoloProfile, capture: CaptureSettings?, makeActive: Bool) throws {
        try store.save(profile)
        profiles = try store.loadAll()
        if let capture { config.setCaptureSettings(capture, for: profile.id) }
        if makeActive { config.activeProfileID = profile.id }
        try configStore.save(config)
    }

    public mutating func delete(_ profile: HoloProfile) throws {
        try store.delete(profile)
        profiles = try store.loadAll()
        config.captureByProfile.removeValue(forKey: profile.id.uuidString)
        if config.activeProfileID == profile.id { config.activeProfileID = nil }
        try configStore.save(config)
    }

    public mutating func activate(_ profile: HoloProfile) throws {
        config.activeProfileID = profile.id
        try configStore.save(config)
    }

    public mutating func saveConfig() throws {
        try configStore.save(config)
    }

    public mutating func reload() throws {
        profiles = try store.loadAll()
        config = try configStore.load()
    }

    /// Newest modification time across profiles and config, for change detection.
    public func fingerprint() -> String {
        let fileManager = FileManager.default
        var parts: [String] = []
        if let files = try? fileManager.contentsOfDirectory(atPath: paths.profilesDirectory.path) {
            for file in files.sorted() where file.hasSuffix(".json") {
                let path = paths.profilesDirectory.appendingPathComponent(file).path
                let date = (try? fileManager.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                parts.append("\(file):\(date?.timeIntervalSince1970 ?? 0)")
            }
        }
        parts.append("config:\(configStore.modificationDate()?.timeIntervalSince1970 ?? 0)")
        return parts.joined(separator: "|")
    }
}

/// Coordinates the background service with guided sessions. A guided session
/// (calibrate, evaluate, compare, monitor) holds an exclusive lock; while it
/// is held the service releases the microphone and runs no actions, matching
/// the macOS rule that only the live Desk view dispatches actions.
public final class ServiceControl {
    public let directory: URL

    private var guidedDescriptor: Int32 = -1
    private var daemonDescriptor: Int32 = -1

    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        chmod(directory.path, 0o700)
    }

    deinit {
        releaseGuidedSession()
        releaseDaemonLock()
    }

    private var guidedLockPath: String { directory.appendingPathComponent("guided.lock").path }
    private var daemonLockPath: String { directory.appendingPathComponent("daemon.lock").path }
    private var pausedPath: String { directory.appendingPathComponent("paused").path }

    // MARK: Guided sessions

    /// Returns false when another guided session already holds the lock.
    public func beginGuidedSession(name: String) -> Bool {
        guard guidedDescriptor < 0 else { return true }
        let descriptor = open(guidedLockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return true }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        _ = ftruncate(descriptor, 0)
        let record = "\(getpid()) \(name)\n"
        _ = record.withCString { write(descriptor, $0, strlen($0)) }
        guidedDescriptor = descriptor
        return true
    }

    public func releaseGuidedSession() {
        guard guidedDescriptor >= 0 else { return }
        _ = ftruncate(guidedDescriptor, 0)
        flock(guidedDescriptor, LOCK_UN)
        close(guidedDescriptor)
        guidedDescriptor = -1
    }

    /// The name of the guided session currently running in another process.
    public func activeGuidedSession() -> String? {
        holderDescription(path: guidedLockPath)
    }

    // MARK: Service

    /// Returns false when another service instance is already running.
    public func acquireDaemonLock() -> Bool {
        guard daemonDescriptor < 0 else { return true }
        let descriptor = open(daemonLockPath, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return true }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            return false
        }
        _ = ftruncate(descriptor, 0)
        let record = "\(getpid()) service\n"
        _ = record.withCString { write(descriptor, $0, strlen($0)) }
        daemonDescriptor = descriptor
        return true
    }

    public func releaseDaemonLock() {
        guard daemonDescriptor >= 0 else { return }
        _ = ftruncate(daemonDescriptor, 0)
        flock(daemonDescriptor, LOCK_UN)
        close(daemonDescriptor)
        daemonDescriptor = -1
    }

    /// PID of the running service, if any.
    public func runningServicePID() -> Int32? {
        guard let description = holderDescription(path: daemonLockPath) else { return nil }
        return description.split(separator: " ").first.flatMap { Int32($0) }
    }

    // MARK: Pause flag

    public var isPausedByUser: Bool {
        FileManager.default.fileExists(atPath: pausedPath)
    }

    public func setPausedByUser(_ paused: Bool) throws {
        if paused {
            try Data("paused\n".utf8).write(to: URL(fileURLWithPath: pausedPath))
        } else if FileManager.default.fileExists(atPath: pausedPath) {
            try FileManager.default.removeItem(atPath: pausedPath)
        }
    }

    /// Reads the lock file's record if another process holds the lock.
    private func holderDescription(path: String) -> String? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        if flock(descriptor, LOCK_SH | LOCK_NB) == 0 {
            flock(descriptor, LOCK_UN)
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: 128)
        let count = read(descriptor, &buffer, buffer.count)
        let text = count > 0 ? String(decoding: buffer.prefix(count), as: UTF8.self) : ""
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}

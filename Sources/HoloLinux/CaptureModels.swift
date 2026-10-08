import Foundation
import HoloCore

/// Monotonic time in seconds. Matches the clock used for audio buffer
/// timestamps, so tap-to-response latency is measured on one clock.
public enum HoloClock {
    public static func now() -> Double {
        ProcessInfo.processInfo.systemUptime
    }
}

/// One accepted detector window after feature extraction, ready for the
/// classifier or a guided session.
public struct TapObservation: Sendable {
    public var feature: TapFeatureVector
    public var spectrum: [SpectrumBand]
    public var rawChannels: [[Float]]
    public var onsetOffset: Int
    /// Monotonic time at which the tap's onset reached the microphone.
    public var eventTime: Double
    public var processingLatencyMilliseconds: Double

    public init(
        feature: TapFeatureVector,
        spectrum: [SpectrumBand] = [],
        rawChannels: [[Float]] = [],
        onsetOffset: Int = 0,
        eventTime: Double,
        processingLatencyMilliseconds: Double = 0
    ) {
        self.feature = feature
        self.spectrum = spectrum
        self.rawChannels = rawChannels
        self.onsetOffset = onsetOffset
        self.eventTime = eventTime
        self.processingLatencyMilliseconds = processingLatencyMilliseconds
    }

    /// Milliseconds from the tap's onset to `now`, or `AudioTimeline.invalidElapsedMilliseconds`.
    public func responseLatencyMilliseconds(now: Double = HoloClock.now()) -> Double {
        AudioTimeline.elapsedMilliseconds(since: eventTime, now: now)
    }
}

/// How Holo opens the microphone. Saved per desk profile so the live service
/// uses exactly the signal path that was calibrated.
public struct CaptureSettings: Codable, Equatable, Sendable {
    public static let defaultDevice = "default"
    public static let defaultSampleRate = 48_000.0
    public static let maximumChannels = 2

    /// ALSA PCM name: "default" (PipeWire/PulseAudio default source), or a
    /// device such as "plughw:0,6".
    public var device: String
    public var channels: Int
    public var sampleRate: Double
    /// Set when the profile was calibrated with --allow-external-input, so
    /// the service accepts the same non-built-in microphone.
    public var allowsExternalInput: Bool
    /// Set when calibrated with --allow-external-output (active/hybrid sensing).
    public var allowsExternalOutput: Bool

    public init(
        device: String = CaptureSettings.defaultDevice,
        channels: Int = 1,
        sampleRate: Double = CaptureSettings.defaultSampleRate,
        allowsExternalInput: Bool = false,
        allowsExternalOutput: Bool = false
    ) {
        self.device = device
        self.channels = min(max(channels, 1), Self.maximumChannels)
        self.sampleRate = sampleRate
        self.allowsExternalInput = allowsExternalInput
        self.allowsExternalOutput = allowsExternalOutput
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            device: try container.decodeIfPresent(String.self, forKey: .device) ?? Self.defaultDevice,
            channels: try container.decodeIfPresent(Int.self, forKey: .channels) ?? 1,
            sampleRate: try container.decodeIfPresent(Double.self, forKey: .sampleRate) ?? Self.defaultSampleRate,
            allowsExternalInput: try container.decodeIfPresent(Bool.self, forKey: .allowsExternalInput) ?? false,
            allowsExternalOutput: try container.decodeIfPresent(Bool.self, forKey: .allowsExternalOutput) ?? false
        )
    }
}

public struct CaptureStatus: Equatable, Sendable {
    public var device: String
    public var channels: Int
    public var sampleRate: Double
    public var periodFrames: Int
    public var sampleFormat: String

    public init(device: String, channels: Int, sampleRate: Double, periodFrames: Int, sampleFormat: String) {
        self.device = device
        self.channels = channels
        self.sampleRate = sampleRate
        self.periodFrames = periodFrames
        self.sampleFormat = sampleFormat
    }
}

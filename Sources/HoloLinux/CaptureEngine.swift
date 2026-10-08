import Foundation
import HoloCore

/// Detector and feature extractor for one capture stream. Runs on the capture
/// thread, exactly like the macOS analysis queue.
public final class TapPipeline {
    public let sampleRate: Double
    public let strategy: SensingStrategy
    private let detector: StreamingTapDetector
    private let extractor: TapFeatureExtractor
    private var levelSum = 0.0
    private var levelFrames = 0
    private let levelInterval: Int

    public var onObservation: ((TapObservation) -> Void)?
    /// Reports input RMS (dBFS) and the detector's adaptive noise floor (dBFS) about ten times per second.
    public var onLevel: ((Double, Double) -> Void)?

    public init(sampleRate: Double, channelCount: Int, strategy: SensingStrategy) {
        self.sampleRate = sampleRate
        self.strategy = strategy
        self.detector = StreamingTapDetector(sampleRate: sampleRate, channelCount: channelCount)
        self.extractor = TapFeatureExtractor(sampleRate: sampleRate, strategy: strategy)
        self.levelInterval = max(Int(sampleRate / 10), 1)
    }

    public func process(channels: [[Float]], bufferStartTime: Double) {
        guard let frameCount = channels.map(\.count).min(), frameCount > 0 else { return }
        let bufferStartSampleIndex = detector.totalSamples
        let events = detector.process(channels: channels)

        if onLevel != nil {
            let scale = 1.0 / Double(channels.count)
            for index in 0..<frameCount {
                var sample = 0.0
                for channel in channels { sample += Double(channel[index]) * scale }
                levelSum += sample * sample
            }
            levelFrames += frameCount
            if levelFrames >= levelInterval {
                let rms = sqrt(levelSum / Double(levelFrames))
                onLevel?(Self.dbfs(rms), Self.dbfs(detector.noiseFloorRMS))
                levelSum = 0
                levelFrames = 0
            }
        }

        for event in events {
            let processingStart = HoloClock.now()
            let analysis = extractor.analyze(from: event)
            let processingEnd = HoloClock.now()
            let eventTime = AudioTimeline.eventHostTimeSeconds(
                bufferStartHostTimeSeconds: bufferStartTime,
                bufferStartSampleIndex: bufferStartSampleIndex,
                eventSampleIndex: event.streamSampleIndex,
                sampleRate: sampleRate
            )
            onObservation?(TapObservation(
                feature: analysis.feature,
                spectrum: analysis.spectrum,
                rawChannels: event.channels,
                onsetOffset: event.onsetOffset,
                eventTime: eventTime,
                processingLatencyMilliseconds: (processingEnd - processingStart) * 1_000
            ))
        }
    }

    public static func dbfs(_ rms: Double) -> Double {
        20 * log10(max(rms, 1e-9))
    }
}

/// Owns the microphone, the optional speaker probe, and the analysis pipeline.
/// Events are delivered from the capture thread; callers hop to their own loop.
public final class CaptureEngine {
    public enum Event {
        case observation(TapObservation, generation: UInt64)
        case level(dbfs: Double, noiseFloorDBFS: Double, generation: UInt64)
        case failed(String, generation: UInt64)
    }

    public typealias SourceFactory = (CaptureSettings) -> AudioInputSource

    public let settings: CaptureSettings
    public private(set) var strategy: SensingStrategy?
    public private(set) var status: CaptureStatus?
    public private(set) var generation: UInt64 = 0
    public var reportsLevel = false
    public var probeDevice = "default"

    private let makeSource: SourceFactory
    private var source: AudioInputSource?
    private var probe: AlsaProbePlayer?

    public init(settings: CaptureSettings, sourceFactory: SourceFactory? = nil) {
        self.settings = settings
        self.makeSource = sourceFactory ?? { AlsaCaptureSource(settings: $0) }
    }

    public var isRunning: Bool { source != nil }

    public func start(strategy: SensingStrategy, deliver: @escaping (Event) -> Void) throws {
        stop()
        generation &+= 1
        let generation = self.generation
        let pipeline = TapPipeline(
            sampleRate: settings.sampleRate,
            channelCount: settings.channels,
            strategy: strategy
        )
        pipeline.onObservation = { deliver(.observation($0, generation: generation)) }
        if reportsLevel {
            pipeline.onLevel = { deliver(.level(dbfs: $0, noiseFloorDBFS: $1, generation: generation)) }
        }
        let source = makeSource(settings)
        let status = try source.start(
            onBuffer: { channels, start in pipeline.process(channels: channels, bufferStartTime: start) },
            onFailure: { deliver(.failed($0, generation: generation)) }
        )
        if strategy != .passive {
            let probe = AlsaProbePlayer(device: probeDevice, sampleRate: settings.sampleRate)
            do {
                try probe.start(onFailure: { deliver(.failed("Speaker probe stopped: \($0)", generation: generation)) })
            } catch {
                source.stop()
                throw error
            }
            self.probe = probe
        }
        self.source = source
        self.status = status
        self.strategy = strategy
    }

    public func stop() {
        probe?.stop()
        probe = nil
        source?.stop()
        source = nil
        status = nil
        strategy = nil
        generation &+= 1
    }

    /// True when an event belongs to the capture that is currently running.
    public func isCurrent(_ generation: UInt64) -> Bool {
        isRunning && generation == self.generation
    }
}

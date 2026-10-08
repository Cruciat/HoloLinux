import CAlsa
import Foundation
import HoloCore
#if canImport(Glibc)
import Glibc
#endif

public enum AlsaError: Error, LocalizedError, Equatable {
    case open(device: String, code: Int32)
    case configure(device: String, code: Int32)
    case io(device: String, code: Int32)

    public var errorDescription: String? {
        switch self {
        case .open(let device, let code):
            return "Could not open audio device \"\(device)\": \(AlsaError.describe(code)). \(AlsaError.hint(for: code, device: device))"
        case .configure(let device, let code):
            return "Audio device \"\(device)\" rejected 48 kHz capture: \(AlsaError.describe(code)). Try \"plughw:\" instead of \"hw:\", or the \"default\" device."
        case .io(let device, let code):
            return "Audio device \"\(device)\" stopped: \(AlsaError.describe(code))."
        }
    }

    static func describe(_ code: Int32) -> String {
        guard let message = snd_strerror(code) else { return "error \(code)" }
        return String(cString: message)
    }

    static func hint(for code: Int32, device: String) -> String {
        if code == -EBUSY {
            return "Another program holds the device exclusively; use \"default\" so PipeWire can share it."
        }
        if code == -ENOENT || code == -ENODEV {
            return "Check the device name with `arecord -L`, or use \"default\"."
        }
        return ""
    }
}

/// Sample formats tried in order. Float is preferred; integer formats let
/// Holo open raw "hw:" devices that do not offer float samples.
enum AlsaSampleFormat: CaseIterable {
    case float32
    case int32
    case int16

    var alsaFormat: snd_pcm_format_t {
        switch self {
        case .float32: return SND_PCM_FORMAT_FLOAT_LE
        case .int32: return SND_PCM_FORMAT_S32_LE
        case .int16: return SND_PCM_FORMAT_S16_LE
        }
    }

    var bytesPerSample: Int {
        switch self {
        case .float32, .int32: return 4
        case .int16: return 2
        }
    }

    var name: String {
        switch self {
        case .float32: return "float32"
        case .int32: return "s32"
        case .int16: return "s16"
        }
    }
}

/// A configured ALSA PCM handle.
final class AlsaPCM {
    let handle: OpaquePointer
    let device: String
    let channels: Int
    let sampleRate: Double
    let format: AlsaSampleFormat
    let periodFrames: Int
    let bufferFrames: Int

    init(
        device: String,
        stream: snd_pcm_stream_t,
        channels: Int,
        sampleRate: Double,
        latencyMicroseconds: UInt32,
        formats: [AlsaSampleFormat] = AlsaSampleFormat.allCases
    ) throws {
        var lastError: Int32 = -EINVAL
        for format in formats {
            var pcm: OpaquePointer?
            let opened = snd_pcm_open(&pcm, device, stream, 0)
            guard opened >= 0, let pcm else {
                throw AlsaError.open(device: device, code: opened)
            }
            let configured = snd_pcm_set_params(
                pcm,
                format.alsaFormat,
                SND_PCM_ACCESS_RW_INTERLEAVED,
                UInt32(channels),
                UInt32(sampleRate),
                1,
                latencyMicroseconds
            )
            if configured >= 0 {
                var buffer: snd_pcm_uframes_t = 0
                var period: snd_pcm_uframes_t = 0
                if snd_pcm_get_params(pcm, &buffer, &period) < 0 || period == 0 {
                    period = 512
                    buffer = 2_048
                }
                self.handle = pcm
                self.device = device
                self.channels = channels
                self.sampleRate = sampleRate
                self.format = format
                self.periodFrames = min(max(Int(period), 64), 4_096)
                self.bufferFrames = Int(buffer)
                return
            }
            lastError = configured
            snd_pcm_close(pcm)
        }
        throw AlsaError.configure(device: device, code: lastError)
    }

    deinit {
        snd_pcm_close(handle)
    }
}

/// Reads microphone audio on a dedicated thread.
public protocol AudioInputSource: AnyObject {
    /// Opens the device and starts delivering buffers. `onBuffer` receives
    /// deinterleaved channels and the monotonic time of the first frame.
    func start(
        onBuffer: @escaping ([[Float]], Double) -> Void,
        onFailure: @escaping (String) -> Void
    ) throws -> CaptureStatus
    func stop()
}

public final class AlsaCaptureSource: AudioInputSource {
    public let settings: CaptureSettings
    private let lock = NSLock()
    private var stopRequested = false
    private var thread: Thread?
    private var finished: DispatchSemaphore?

    public init(settings: CaptureSettings) {
        self.settings = settings
    }

    public func start(
        onBuffer: @escaping ([[Float]], Double) -> Void,
        onFailure: @escaping (String) -> Void
    ) throws -> CaptureStatus {
        stop()
        // Open synchronously so configuration errors surface to the caller.
        let pcm = try AlsaPCM(
            device: settings.device,
            stream: SND_PCM_STREAM_CAPTURE,
            channels: settings.channels,
            sampleRate: settings.sampleRate,
            latencyMicroseconds: 40_000
        )
        lock.lock()
        stopRequested = false
        lock.unlock()
        let done = DispatchSemaphore(value: 0)
        finished = done
        let thread = Thread { [weak self] in
            self?.readLoop(pcm: pcm, onBuffer: onBuffer, onFailure: onFailure)
            done.signal()
        }
        thread.name = "holo-capture"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
        return CaptureStatus(
            device: settings.device,
            channels: pcm.channels,
            sampleRate: pcm.sampleRate,
            periodFrames: pcm.periodFrames,
            sampleFormat: pcm.format.name
        )
    }

    public func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        if let finished {
            finished.wait()
        }
        finished = nil
        thread = nil
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func readLoop(
        pcm: AlsaPCM,
        onBuffer: ([[Float]], Double) -> Void,
        onFailure: (String) -> Void
    ) {
        let frames = pcm.periodFrames
        let channels = pcm.channels
        var raw = [UInt8](repeating: 0, count: frames * channels * pcm.format.bytesPerSample)
        _ = snd_pcm_start(pcm.handle)
        var consecutiveErrors = 0

        while !shouldStop {
            let ready = snd_pcm_wait(pcm.handle, 200)
            if ready == 0 { continue }
            if ready < 0 {
                if !recover(pcm, code: ready, consecutiveErrors: &consecutiveErrors, onFailure: onFailure) { return }
                continue
            }
            let count = raw.withUnsafeMutableBytes { buffer -> Int in
                Int(snd_pcm_readi(pcm.handle, buffer.baseAddress, snd_pcm_uframes_t(frames)))
            }
            let now = HoloClock.now()
            if count == -Int(EAGAIN) { continue }
            if count < 0 {
                if !recover(pcm, code: Int32(count), consecutiveErrors: &consecutiveErrors, onFailure: onFailure) { return }
                continue
            }
            consecutiveErrors = 0
            guard count > 0 else { continue }
            var delay: snd_pcm_sframes_t = 0
            if snd_pcm_delay(pcm.handle, &delay) < 0 || delay < 0 { delay = 0 }
            let firstFrameTime = now - Double(Int(delay) + count) / pcm.sampleRate
            onBuffer(Self.deinterleave(raw, frames: count, channels: channels, format: pcm.format), firstFrameTime)
        }
    }

    private func recover(
        _ pcm: AlsaPCM,
        code: Int32,
        consecutiveErrors: inout Int,
        onFailure: (String) -> Void
    ) -> Bool {
        consecutiveErrors += 1
        let recovered = snd_pcm_recover(pcm.handle, code, 1)
        if recovered < 0 || consecutiveErrors > 20 || code == -ENODEV {
            onFailure(AlsaError.io(device: pcm.device, code: recovered < 0 ? recovered : code).localizedDescription)
            return false
        }
        _ = snd_pcm_start(pcm.handle)
        return true
    }

    static func deinterleave(_ raw: [UInt8], frames: Int, channels: Int, format: AlsaSampleFormat) -> [[Float]] {
        var output = Array(repeating: [Float](repeating: 0, count: frames), count: channels)
        raw.withUnsafeBytes { bytes in
            switch format {
            case .float32:
                let samples = bytes.bindMemory(to: Float.self)
                for channel in 0..<channels {
                    for frame in 0..<frames { output[channel][frame] = samples[frame * channels + channel] }
                }
            case .int32:
                let samples = bytes.bindMemory(to: Int32.self)
                for channel in 0..<channels {
                    for frame in 0..<frames {
                        output[channel][frame] = Float(Int32(littleEndian: samples[frame * channels + channel])) / 2_147_483_648
                    }
                }
            case .int16:
                let samples = bytes.bindMemory(to: Int16.self)
                for channel in 0..<channels {
                    for frame in 0..<frames {
                        output[channel][frame] = Float(Int16(littleEndian: samples[frame * channels + channel])) / 32_768
                    }
                }
            }
        }
        return output
    }
}

/// Plays the active-sensing chirp in a loop, like the macOS probe player.
public final class AlsaProbePlayer {
    public static let period = 0.120
    public static let volume: Float = 0.55

    private let device: String
    private let sampleRate: Double
    private let lock = NSLock()
    private var stopRequested = false
    private var finished: DispatchSemaphore?

    public init(device: String = "default", sampleRate: Double) {
        self.device = device
        self.sampleRate = sampleRate
    }

    public func start(onFailure: @escaping (String) -> Void) throws {
        stop()
        let pcm = try AlsaPCM(
            device: device,
            stream: SND_PCM_STREAM_PLAYBACK,
            channels: 1,
            sampleRate: sampleRate,
            latencyMicroseconds: 60_000,
            formats: [.float32]
        )
        let periodFrames = max(Int(sampleRate * Self.period), 1)
        var loop = [Float](repeating: 0, count: periodFrames)
        let chirp = ActiveProbe.chirp(sampleRate: sampleRate)
        for index in 0..<min(chirp.count, periodFrames) {
            loop[index] = chirp[index] * Self.volume
        }
        lock.lock()
        stopRequested = false
        lock.unlock()
        let pattern = loop
        let done = DispatchSemaphore(value: 0)
        finished = done
        let thread = Thread { [weak self] in
            self?.writeLoop(pcm: pcm, loop: pattern, onFailure: onFailure)
            done.signal()
        }
        thread.name = "holo-probe"
        thread.start()
    }

    public func stop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
        finished?.wait()
        finished = nil
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    private func writeLoop(pcm: AlsaPCM, loop: [Float], onFailure: (String) -> Void) {
        let chunk = max(pcm.periodFrames, 64)
        var position = 0
        var errors = 0
        while !shouldStop {
            var block = [Float](repeating: 0, count: chunk)
            for index in 0..<chunk {
                block[index] = loop[(position + index) % loop.count]
            }
            let written = block.withUnsafeBytes { buffer -> Int in
                Int(snd_pcm_writei(pcm.handle, buffer.baseAddress, snd_pcm_uframes_t(chunk)))
            }
            if written < 0 {
                errors += 1
                if snd_pcm_recover(pcm.handle, Int32(written), 1) < 0 || errors > 20 {
                    onFailure(AlsaError.io(device: pcm.device, code: Int32(written)).localizedDescription)
                    return
                }
                continue
            }
            errors = 0
            position = (position + written) % loop.count
        }
        _ = snd_pcm_drop(pcm.handle)
    }
}

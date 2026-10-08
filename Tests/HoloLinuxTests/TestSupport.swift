import Foundation
import HoloCore
@testable import HoloLinux

/// Generates stereo desk audio with zone-specific taps, similar to the core
/// pipeline fixtures but with the left/right balance a laptop array would see.
struct SyntheticDesk {
    let sampleRate = 48_000.0
    private var state: UInt64

    init(seed: UInt64 = 0x484F4C4F) {
        state = seed
    }

    mutating func unit() -> Double {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return Double(value >> 11) / Double(1 << 53)
    }

    mutating func noise(frames: Int, level: Double = 0.0006) -> [[Float]] {
        (0..<2).map { _ in (0..<frames).map { _ in Float((unit() - 0.5) * 2 * level) } }
    }

    /// A tap of the given zone, 160 ms long, starting at sample 0.
    mutating func tap(_ zone: DeskZone, gain: Double = 1) -> [[Float]] {
        let frequency = [330.0, 520, 820, 1_180][zone.rawValue] * (1 + (unit() - 0.5) * 0.01)
        let second = zone.isLeft ? 2.1 : 2.7
        let decay = zone.verticalIndex == 0 ? 46.0 : 51.0
        let (leftGain, rightGain) = zone.isLeft ? (1.0, 0.65) : (0.65, 1.0)
        let delay = zone.isLeft ? 0 : 6
        let jitteredGain = gain * (1 + (unit() - 0.5) * 0.1)
        let count = Int(sampleRate * 0.16)
        var mono = [Double](repeating: 0, count: count)
        for index in 0..<count {
            let time = Double(index) / sampleRate
            let impact = 0.40 * exp(-time * 2_500) * cos(2 * Double.pi * 1_800 * time)
            let body = sin(2 * Double.pi * frequency * time) + 0.24 * sin(2 * Double.pi * frequency * second * time)
            mono[index] = jitteredGain * (impact + 0.12 * exp(-time * decay) * body)
        }
        let left = mono.map { Float($0 * leftGain) }
        let right = (0..<count).map { index in index >= delay ? Float(mono[index - delay] * rightGain) : 0 }
        return [left, right]
    }

    /// Room noise with taps mixed in at the given sample offsets.
    mutating func stream(seconds: Double, taps: [(at: Double, zone: DeskZone)]) -> [[Float]] {
        let frames = Int(sampleRate * seconds)
        var channels = noise(frames: frames)
        for item in taps {
            let start = Int(item.at * sampleRate)
            let signal = tap(item.zone)
            for channel in 0..<2 {
                for index in signal[channel].indices where start + index < frames {
                    channels[channel][start + index] += signal[channel][index]
                }
            }
        }
        return channels
    }
}

/// Runs a stream through the real detector and extractor and returns the observations.
func observations(
    from channels: [[Float]],
    strategy: SensingStrategy = .passive,
    bufferFrames: Int = 512,
    startTime: Double = 1_000
) -> [TapObservation] {
    let pipeline = TapPipeline(sampleRate: 48_000, channelCount: channels.count, strategy: strategy)
    var result: [TapObservation] = []
    pipeline.onObservation = { result.append($0) }
    var offset = 0
    let total = channels[0].count
    while offset < total {
        let end = min(offset + bufferFrames, total)
        let slice = channels.map { Array($0[offset..<end]) }
        pipeline.process(channels: slice, bufferStartTime: startTime + Double(offset) / 48_000)
        offset = end
    }
    return result
}

/// Observations for `count` taps of each zone, in zone order.
func zoneObservations(count: Int, seed: UInt64 = 7) -> [DeskZone: [TapObservation]] {
    var desk = SyntheticDesk(seed: seed)
    var result: [DeskZone: [TapObservation]] = [:]
    for zone in DeskZone.allCases {
        let taps = (0..<count).map { index in (at: 1.0 + Double(index) * 0.5, zone: zone) }
        let stream = desk.stream(seconds: 1.5 + Double(count) * 0.5, taps: taps)
        result[zone] = observations(from: stream)
    }
    return result
}

struct MockRunner: CommandRunning {
    var responses: [String: CommandResult]

    func run(_ executable: String, _ arguments: [String], timeout: Double) -> CommandResult? {
        responses[([executable] + arguments).joined(separator: " ")]
    }
}

func temporaryDirectory(_ name: String = UUID().uuidString) -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("holo-tests-\(name)", isDirectory: true)
    try? FileManager.default.removeItem(at: url)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

func testPaths() -> HoloPaths {
    let root = temporaryDirectory()
    return HoloPaths(
        dataRoot: root.appendingPathComponent("data"),
        configDirectory: root.appendingPathComponent("config"),
        runtimeDirectory: root.appendingPathComponent("run")
    )
}

enum Fixtures {
    /// `wpctl inspect` of a Raptor Lake SOF digital microphone node (representative).
    static let internalNode = """
    id 52, type PipeWire:Interface:Node
        alsa.card = "0"
        alsa.card_name = "sof-hda-dsp"
        alsa.device = "6"
        alsa.id = "DMIC Raw"
        api.alsa.path = "hw:0,6"
        api.alsa.pcm.card = "0"
        audio.channels = "2"
        audio.position = "FL,FR"
        device.api = "alsa"
        device.class = "sound"
      * device.id = "45"
        device.profile.description = "Digital Microphone"
      * factory.id = "19"
      * media.class = "Audio/Source"
      * node.description = "Raptor Lake-P/U/H cAVS Digital Microphone"
      * node.name = "alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source"
        node.nick = "Digital Microphone"
        object.path = "alsa:acp:sofhdadsp:6:capture"
      * object.serial = "53"
    """

    static let internalDevice = """
    id 45, type PipeWire:Interface:Device
        api.alsa.card = "0"
        device.api = "alsa"
        device.bus = "pci"
        device.bus-path = "pci-0000:00:1f.3-platform-skl_hda_dsp_generic"
      * device.description = "Raptor Lake-P/U/H cAVS"
        device.form-factor = "internal"
      * device.name = "alsa_card.pci-0000_00_1f.3-platform-skl_hda_dsp_generic"
      * media.class = "Audio/Device"
    """

    static let usbNode = """
    id 70, type PipeWire:Interface:Node
        audio.channels = "2"
      * device.id = "68"
      * media.class = "Audio/Source"
      * node.description = "Yeti Stereo Microphone Analog Stereo"
      * node.name = "alsa_input.usb-Blue_Microphones_Yeti_Stereo_Microphone_REV8-00.analog-stereo"
    """

    static let usbDevice = """
    id 68, type PipeWire:Interface:Device
        device.api = "alsa"
        device.bus = "usb"
        device.form-factor = "microphone"
    """

    static let bluetoothNode = """
    id 81, type PipeWire:Interface:Node
        audio.channels = "1"
        device.api = "bluez5"
      * media.class = "Audio/Source"
      * node.description = "WH-1000XM4"
      * node.name = "bluez_input.88_C9_E8_00_00_00.0"
    """

    static let filterNode = """
    id 90, type PipeWire:Interface:Node
        audio.channels = "1"
      * media.class = "Audio/Source"
      * node.description = "Noise Canceling source"
      * node.name = "rnnoise_source"
        node.virtual = "true"
    """

    static let internalSink = """
    id 51, type PipeWire:Interface:Node
        audio.channels = "2"
        device.api = "alsa"
      * media.class = "Audio/Sink"
      * node.description = "Raptor Lake-P/U/H cAVS Speaker"
      * node.name = "alsa_output.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Speaker__sink"
    """

    static let bluetoothSink = """
    id 82, type PipeWire:Interface:Node
        device.api = "bluez5"
      * media.class = "Audio/Sink"
      * node.description = "WH-1000XM4"
      * node.name = "bluez_output.88_C9_E8_00_00_00.1"
    """
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import HoloCore

setbuf(stdout, nil)

struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        return value ^ (value >> 31)
    }

    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }
}

private func syntheticEvent(zone: DeskZone, sampleRate: Double, variation: Double, generator: inout SeededGenerator) -> DetectedTap {
    let count = Int(sampleRate * 0.090)
    let onset = Int(sampleRate * 0.012)
    let baseFrequency = 260.0 + Double(zone.rawValue) * 145.0
    let secondaryFrequency = 1_600.0 + Double(zone.column) * 820.0
    var samples = Array(repeating: Float.zero, count: count)
    for index in samples.indices {
        let noise = (generator.unit() - 0.5) * 0.0008
        guard index >= onset else {
            samples[index] = Float(noise)
            continue
        }
        let time = Double(index - onset) / sampleRate
        let envelope = exp(-time * (50 + Double(zone.row) * 7))
        let tap = sin(2 * .pi * baseFrequency * (1 + variation) * time)
            + 0.42 * sin(2 * .pi * secondaryFrequency * time)
        samples[index] = Float(noise + 0.12 * envelope * tap)
    }
    return DetectedTap(
        channels: [samples],
        onsetOffset: onset,
        streamSampleIndex: 0,
        noiseFloorRMS: 0.0005
    )
}

private func residentMegabytes() -> Double {
#if canImport(Darwin)
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(
        MemoryLayout<mach_task_basic_info_data_t>.size / MemoryLayout<natural_t>.size
    )
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), rebound, &count)
        }
    }
    guard result == KERN_SUCCESS else { return 0 }
    return Double(info.resident_size) / (1_024 * 1_024)
#else
    guard let statm = try? String(contentsOfFile: "/proc/self/statm", encoding: .utf8) else { return 0 }
    let fields = statm.split(separator: " ")
    guard fields.count > 1, let pages = Double(fields[1]) else { return 0 }
    return pages * Double(sysconf(Int32(_SC_PAGESIZE))) / (1_024 * 1_024)
#endif
}

let arguments = CommandLine.arguments
let duration: TimeInterval = {
    guard let index = arguments.firstIndex(of: "--duration"), index + 1 < arguments.count else { return 1_800 }
    return Double(arguments[index + 1]) ?? 1_800
}()
let fast = arguments.contains("--fast")
let sampleRate = 48_000.0
var generator = SeededGenerator(state: 0x484F4C4F)
let extractor = TapFeatureExtractor(sampleRate: sampleRate, strategy: .passive)
var calibration: [LabeledTap] = []

for zone in DeskZone.allCases {
    for sample in 0..<8 {
        let variation = (Double(sample) - 3.5) * 0.002
        calibration.append(LabeledTap(
            zone: zone,
            feature: extractor.extract(from: syntheticEvent(zone: zone, sampleRate: sampleRate, variation: variation, generator: &generator))
        ))
    }
}

let classifier: TrainedTapClassifier
do {
    classifier = try TrainedTapClassifier.train(positiveExamples: calibration)
} catch {
    fputs("soak setup failed: \(error)\n", stderr)
    exit(2)
}

let started = Date()
let initialMemory = residentMegabytes()
var iteration = 0
var positiveCorrect = 0
var positiveRejected = 0
var positiveWrong = 0
var rejectionChallengesPassed = 0
var rejectionChallengesFalseAccepted = 0
var failures = 0
var nextProgress = 60.0

repeat {
    let zone = DeskZone.allCases[iteration % DeskZone.allCases.count]
    let variation = (generator.unit() - 0.5) * 0.012
    let event = syntheticEvent(zone: zone, sampleRate: sampleRate, variation: variation, generator: &generator)
    var feature = extractor.extract(from: event)
    let expectsRejection = iteration % 10 == 9
    if expectsRejection {
        switch (iteration / 10) % 5 {
        case 0:
            feature.quality.peakAmplitude = 0.001
        case 1:
            feature.quality.signalToNoiseDB = 2
        case 2:
            feature.quality.clippingFraction = 0.40
        case 3:
            feature.names[0] = "incompatible_feature"
        default:
            feature.values = feature.values.map { $0 + 100 }
        }
    }
    let decision = classifier.predict(feature)

    if expectsRejection {
        if decision.zone == nil {
            rejectionChallengesPassed += 1
        } else {
            rejectionChallengesFalseAccepted += 1
            failures += 1
        }
    } else if decision.zone == zone {
        positiveCorrect += 1
    } else if decision.zone == nil {
        positiveRejected += 1
        failures += 1
    } else {
        positiveWrong += 1
        failures += 1
    }
    if !decision.confidence.isFinite || feature.values.contains(where: { !$0.isFinite }) { failures += 1 }
    iteration += 1

    let elapsed = Date().timeIntervalSince(started)
    if elapsed >= nextProgress {
        print(String(format: "soak %.0fs • \(iteration) events • %.1f MB RSS", elapsed, residentMegabytes()))
        nextProgress += 60
    }
    if !fast { Thread.sleep(forTimeInterval: 0.10) }
    if fast && iteration >= max(Int(duration * 500), 5_000) { break }
} while Date().timeIntervalSince(started) < duration

let elapsed = Date().timeIntervalSince(started)
let finalMemory = residentMegabytes()
let growth = finalMemory - initialMemory
let summary = String(
    format: "Holo soak complete: %.1fs, \(iteration) events; positives \(positiveCorrect) correct, \(positiveRejected) rejected, \(positiveWrong) wrong; rejection challenges \(rejectionChallengesPassed) rejected, \(rejectionChallengesFalseAccepted) false accepted; RSS %.1f→%.1f MB (Δ %.1f MB)",
    elapsed, initialMemory, finalMemory, growth
)
print(summary)

if failures > 0 || growth > 96 || iteration == 0 {
    exit(1)
}

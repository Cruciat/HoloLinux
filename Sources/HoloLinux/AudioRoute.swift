import Foundation
import HoloCore

/// One end of the audio route as seen on Linux.
public struct LinuxAudioEndpoint: Equatable, Sendable {
    public var name: String
    public var identifier: String
    /// `nil` when Holo cannot tell whether the device is part of the laptop.
    public var isBuiltIn: Bool?
    public var channels: Int?
    public var reason: String

    public init(name: String, identifier: String, isBuiltIn: Bool?, channels: Int?, reason: String) {
        self.name = name
        self.identifier = identifier
        self.isBuiltIn = isBuiltIn
        self.channels = channels
        self.reason = reason
    }

    public var builtInDescription: String {
        switch isBuiltIn {
        case .some(true): return "built-in"
        case .some(false): return "external"
        case .none: return "unknown"
        }
    }
}

public struct LinuxAudioRoute: Equatable, Sendable {
    public var input: LinuxAudioEndpoint?
    public var output: LinuxAudioEndpoint?
    public var notes: [String]
    /// True when the default device could not be looked up at all (as opposed
    /// to PipeWire reporting that there is no default device).
    public var inputLookupFailed: Bool
    public var outputLookupFailed: Bool

    public init(
        input: LinuxAudioEndpoint?,
        output: LinuxAudioEndpoint?,
        notes: [String] = [],
        inputLookupFailed: Bool = false,
        outputLookupFailed: Bool = false
    ) {
        self.input = input
        self.output = output
        self.notes = notes
        self.inputLookupFailed = inputLookupFailed
        self.outputLookupFailed = outputLookupFailed
    }

    /// The route in the shared macOS policy model. An endpoint whose transport
    /// cannot be determined is passed as built-in and reported as a warning
    /// instead, so systems without PipeWire are not locked out.
    public var coreRoute: AudioRouteInfo {
        AudioRouteInfo(
            input: input.map { AudioEndpointInfo(name: $0.name, isBuiltIn: $0.isBuiltIn ?? true) },
            output: output.map { AudioEndpointInfo(name: $0.name, isBuiltIn: $0.isBuiltIn ?? true) }
        )
    }
}

public struct RouteCheck: Equatable, Sendable {
    public var route: LinuxAudioRoute
    public var issue: AudioHardwarePolicyIssue?
    public var warnings: [String]

    public var isUsable: Bool { issue == nil }

    public var issueDescription: String? {
        guard let issue else { return nil }
        switch issue {
        case .inputUnavailable:
            return "No default microphone is available. Select the laptop's internal microphone in Settings › Sound › Input."
        case .builtInInputRequired(let selected):
            return "Holo requires the laptop's built-in microphone, but the current input is \(selected). Select the internal microphone in Settings › Sound › Input, or pass --allow-external-input to override."
        case .outputUnavailable:
            return "Active and Hybrid sensing need the laptop speakers, but no default output is available."
        case .builtInOutputRequired(let selected):
            return "Active and Hybrid sensing require the laptop's built-in speakers, but the current output is \(selected). Select them in Settings › Sound › Output, use Passive sensing, or pass --allow-external-output."
        }
    }
}

/// Parses `wpctl inspect` output and classifies PipeWire nodes.
public enum PipeWireInspector {
    public static func parseProperties(_ text: String) -> [String: String] {
        var properties: [String: String] = [:]
        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("*") { line = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
            guard let separator = line.range(of: " = ") else { continue }
            let key = String(line[..<separator.lowerBound]).trimmingCharacters(in: .whitespaces)
            var value = String(line[separator.upperBound...]).trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            guard !key.isEmpty, !key.contains(" ") else { continue }
            properties[key] = value
        }
        return properties
    }

    public static func channelCount(_ properties: [String: String]) -> Int? {
        if let channels = properties["audio.channels"].flatMap(Int.init), channels > 0 {
            return channels
        }
        guard let position = properties["audio.position"] else { return nil }
        let names = position
            .trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
            .split(whereSeparator: { $0 == "," || $0 == " " })
        return names.isEmpty ? nil : names.count
    }

    /// Mirrors the macOS transport check: laptop audio sits on the PCI or
    /// platform bus; USB and Bluetooth devices are external. Virtual and
    /// filtered sources cannot be classified.
    public static func classify(node: [String: String], device: [String: String] = [:]) -> (isBuiltIn: Bool?, reason: String) {
        let merged = device.merging(node) { _, nodeValue in nodeValue }
        let nodeName = (node["node.name"] ?? "").lowercased()
        let api = (merged["device.api"] ?? "").lowercased()
        let bus = (merged["device.bus"] ?? "").lowercased()
        let formFactor = (merged["device.form-factor"] ?? "").lowercased()
        let busPath = (merged["device.bus-path"] ?? "").lowercased()

        if api == "bluez5" || bus == "bluetooth" || nodeName.hasPrefix("bluez_") {
            return (false, "Bluetooth device")
        }
        if bus == "usb" || busPath.contains("usb-") || nodeName.contains(".usb-") || nodeName.hasPrefix("alsa_input.usb") || nodeName.hasPrefix("alsa_output.usb") {
            return (false, "USB device")
        }
        if formFactor == "internal" {
            return (true, "device form factor is internal")
        }
        if ["headset", "headphone", "hands-free", "handset", "webcam", "microphone", "speaker"].contains(formFactor) {
            return (false, "device form factor is \(formFactor)")
        }
        if merged["node.virtual"] == "true" {
            return (nil, "virtual or filtered source (for example a noise-suppression filter)")
        }
        if ["pci", "platform", "isa"].contains(bus) {
            return (true, "device is on the \(bus) bus")
        }
        let builtInPrefixes = ["alsa_input.pci-", "alsa_output.pci-", "alsa_input.platform-", "alsa_output.platform-"]
        if builtInPrefixes.contains(where: { nodeName.hasPrefix($0) }) {
            return (true, "ALSA device on the PCI/platform bus")
        }
        return (nil, "transport not reported")
    }

    public static func endpoint(nodeText: String, deviceText: String?) -> LinuxAudioEndpoint? {
        let node = parseProperties(nodeText)
        guard let nodeName = node["node.name"] else { return nil }
        let device = deviceText.map(parseProperties) ?? [:]
        let classification = classify(node: node, device: device)
        let name = node["node.description"] ?? node["node.nick"] ?? nodeName
        return LinuxAudioEndpoint(
            name: name,
            identifier: nodeName,
            isBuiltIn: classification.isBuiltIn,
            channels: channelCount(node),
            reason: classification.reason
        )
    }
}

/// Inspects ALSA cards directly for devices such as "plughw:0,6".
public enum AlsaCardInspector {
    /// Returns the card index or id named by an ALSA device string, or nil
    /// when the device is not a direct hardware device.
    public static func cardReference(fromDevice device: String) -> String? {
        let lowered = device.lowercased()
        let prefixes = ["plughw:", "hw:", "sysdefault:", "dsnoop:", "front:"]
        guard let prefix = prefixes.first(where: { lowered.hasPrefix($0) }) else { return nil }
        let arguments = String(device.dropFirst(prefix.count))
        for part in arguments.split(separator: ",") {
            let piece = part.trimmingCharacters(in: .whitespaces)
            if piece.uppercased().hasPrefix("CARD=") {
                return String(piece.dropFirst(5))
            }
            if !piece.contains("=") {
                return piece
            }
        }
        return nil
    }

    public static func endpoint(forDevice device: String, procRoot: String = "/proc/asound") -> LinuxAudioEndpoint? {
        guard let reference = cardReference(fromDevice: device) else { return nil }
        let fileManager = FileManager.default
        var cardDirectory: String?
        if Int(reference) != nil {
            cardDirectory = procRoot + "/card" + reference
        } else {
            // Card ids are symlinks to their cardN directory.
            cardDirectory = procRoot + "/" + reference
        }
        guard let directory = cardDirectory, fileManager.fileExists(atPath: directory) else {
            return LinuxAudioEndpoint(name: device, identifier: device, isBuiltIn: nil, channels: nil, reason: "ALSA card \(reference) not found")
        }
        let id = (try? String(contentsOfFile: directory + "/id", encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? reference
        let isUSB = fileManager.fileExists(atPath: directory + "/usbid")
        return LinuxAudioEndpoint(
            name: "ALSA card \(id) (\(device))",
            identifier: device,
            isBuiltIn: !isUSB,
            channels: nil,
            reason: isUSB ? "USB audio card" : "non-USB ALSA card"
        )
    }
}

public struct RouteInspector: Sendable {
    public var runner: CommandRunning
    public var procRoot: String

    public init(runner: CommandRunning = ProcessCommandRunner(), procRoot: String = "/proc/asound") {
        self.runner = runner
        self.procRoot = procRoot
    }

    public static func usesSessionDefault(_ device: String) -> Bool {
        let lowered = device.lowercased()
        return ["default", "pipewire", "pulse"].contains(lowered)
            || lowered.hasPrefix("pipewire:")
            || lowered.hasPrefix("pulse:")
    }

    public func route(for settings: CaptureSettings, includeOutput: Bool) -> LinuxAudioRoute {
        var route = LinuxAudioRoute(input: nil, output: nil)
        if let card = AlsaCardInspector.endpoint(forDevice: settings.device, procRoot: procRoot) {
            route.input = card
        } else if Self.usesSessionDefault(settings.device) {
            let lookup = sessionEndpoint("@DEFAULT_AUDIO_SOURCE@")
            route.input = lookup.endpoint
            if let note = lookup.note {
                route.notes.append(note)
                route.inputLookupFailed = true
            }
        } else {
            route.input = LinuxAudioEndpoint(
                name: settings.device,
                identifier: settings.device,
                isBuiltIn: nil,
                channels: nil,
                reason: "custom ALSA device"
            )
        }
        if includeOutput {
            let lookup = sessionEndpoint("@DEFAULT_AUDIO_SINK@")
            route.output = lookup.endpoint
            if let note = lookup.note {
                route.notes.append(note)
                route.outputLookupFailed = true
            }
        }
        return route
    }

    public func check(
        settings: CaptureSettings,
        strategy: SensingStrategy,
        allowExternalInput: Bool = false,
        allowExternalOutput: Bool = false
    ) -> RouteCheck {
        let route = route(for: settings, includeOutput: strategy != .passive)
        return Self.evaluate(
            route: route,
            device: settings.device,
            strategy: strategy,
            allowExternalInput: allowExternalInput,
            allowExternalOutput: allowExternalOutput
        )
    }

    /// Applies the shared hardware policy to an inspected route.
    public static func evaluate(
        route: LinuxAudioRoute,
        device: String,
        strategy: SensingStrategy,
        allowExternalInput: Bool = false,
        allowExternalOutput: Bool = false
    ) -> RouteCheck {
        var warnings = route.notes
        if let input = route.input, input.isBuiltIn == nil {
            warnings.append("Could not confirm that \(input.name) is the laptop's internal microphone (\(input.reason)).")
        }
        if strategy != .passive, let output = route.output, output.isBuiltIn == nil {
            warnings.append("Could not confirm that \(output.name) is the laptop's built-in speaker (\(output.reason)).")
        }
        var adjusted = route.coreRoute
        // When PipeWire cannot be queried the default device is unknown rather
        // than missing; opening the capture reports whether it exists.
        if route.input == nil, route.inputLookupFailed {
            adjusted.input = AudioEndpointInfo(name: device, isBuiltIn: true)
        }
        if strategy != .passive, route.output == nil, route.outputLookupFailed {
            adjusted.output = AudioEndpointInfo(name: "default output", isBuiltIn: true)
        }
        if allowExternalInput, let input = adjusted.input, !input.isBuiltIn {
            warnings.append("Using external input \(input.name) because --allow-external-input was given.")
            adjusted.input?.isBuiltIn = true
        }
        if allowExternalOutput, let output = adjusted.output, !output.isBuiltIn {
            warnings.append("Using external output \(output.name) because --allow-external-output was given.")
            adjusted.output?.isBuiltIn = true
        }
        let issue = AudioHardwarePolicy.issue(for: adjusted, strategy: strategy)
        return RouteCheck(route: route, issue: issue, warnings: warnings)
    }

    private func sessionEndpoint(_ target: String) -> (endpoint: LinuxAudioEndpoint?, note: String?) {
        guard let result = runner.run("wpctl", ["inspect", target], timeout: 3) else {
            return (nil, "wpctl was not found, so the default \(target.contains("SOURCE") ? "microphone" : "output") could not be inspected.")
        }
        guard result.status == 0 else {
            if (result.output + result.errorOutput).contains("not found") {
                // wpctl answers "Object ... not found" when there is no default node.
                return (nil, nil)
            }
            let detail = result.errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            return (nil, "PipeWire could not be queried (\(detail.isEmpty ? "wpctl exited with \(result.status)" : detail)).")
        }
        let node = PipeWireInspector.parseProperties(result.output)
        var deviceText: String?
        if let deviceID = node["device.id"],
           let device = runner.run("wpctl", ["inspect", deviceID], timeout: 3),
           device.status == 0 {
            deviceText = device.output
        }
        return (PipeWireInspector.endpoint(nodeText: result.output, deviceText: deviceText), nil)
    }
}

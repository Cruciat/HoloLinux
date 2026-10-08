import HoloCore
@testable import HoloLinux
import XCTest

final class PipeWireInspectorTests: XCTestCase {
    func testParsesStarredAndQuotedProperties() {
        let properties = PipeWireInspector.parseProperties(Fixtures.internalNode)
        XCTAssertEqual(properties["node.name"], "alsa_input.pci-0000_00_1f.3-platform-skl_hda_dsp_generic.HiFi__Mic1__source")
        XCTAssertEqual(properties["device.id"], "45")
        XCTAssertEqual(properties["audio.channels"], "2")
        XCTAssertNil(properties["id 52, type PipeWire:Interface:Node"])
    }

    func testInternalMicrophoneIsBuiltIn() {
        let endpoint = PipeWireInspector.endpoint(nodeText: Fixtures.internalNode, deviceText: Fixtures.internalDevice)
        XCTAssertEqual(endpoint?.isBuiltIn, true)
        XCTAssertEqual(endpoint?.channels, 2)
        XCTAssertEqual(endpoint?.name, "Raptor Lake-P/U/H cAVS Digital Microphone")
    }

    func testInternalNodeWithoutDevicePropertiesFallsBackToNodeName() {
        let endpoint = PipeWireInspector.endpoint(nodeText: Fixtures.internalNode, deviceText: nil)
        XCTAssertEqual(endpoint?.isBuiltIn, true)
    }

    func testUSBAndBluetoothAreExternal() {
        XCTAssertEqual(PipeWireInspector.endpoint(nodeText: Fixtures.usbNode, deviceText: Fixtures.usbDevice)?.isBuiltIn, false)
        XCTAssertEqual(PipeWireInspector.endpoint(nodeText: Fixtures.usbNode, deviceText: nil)?.isBuiltIn, false)
        XCTAssertEqual(PipeWireInspector.endpoint(nodeText: Fixtures.bluetoothNode, deviceText: nil)?.isBuiltIn, false)
        XCTAssertEqual(PipeWireInspector.endpoint(nodeText: Fixtures.bluetoothSink, deviceText: nil)?.isBuiltIn, false)
    }

    func testVirtualFilterIsUnknown() {
        let endpoint = PipeWireInspector.endpoint(nodeText: Fixtures.filterNode, deviceText: nil)
        XCTAssertNil(endpoint?.isBuiltIn)
        XCTAssertEqual(endpoint?.channels, 1)
    }

    func testChannelCountFromPosition() {
        XCTAssertEqual(PipeWireInspector.channelCount(["audio.position": "[FL,FR]"]), 2)
        XCTAssertEqual(PipeWireInspector.channelCount(["audio.position": "MONO"]), 1)
        XCTAssertNil(PipeWireInspector.channelCount([:]))
    }
}

final class AlsaCardInspectorTests: XCTestCase {
    func testCardReferences() {
        XCTAssertEqual(AlsaCardInspector.cardReference(fromDevice: "hw:0,6"), "0")
        XCTAssertEqual(AlsaCardInspector.cardReference(fromDevice: "plughw:1"), "1")
        XCTAssertEqual(AlsaCardInspector.cardReference(fromDevice: "hw:CARD=sofhdadsp,DEV=6"), "sofhdadsp")
        XCTAssertEqual(AlsaCardInspector.cardReference(fromDevice: "plughw:DEV=0,CARD=Yeti"), "Yeti")
        XCTAssertNil(AlsaCardInspector.cardReference(fromDevice: "default"))
        XCTAssertNil(AlsaCardInspector.cardReference(fromDevice: "pipewire"))
    }

    func testUSBCardsAreExternal() throws {
        let root = temporaryDirectory()
        let card0 = root.appendingPathComponent("card0")
        let card1 = root.appendingPathComponent("card1")
        try FileManager.default.createDirectory(at: card0, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: card1, withIntermediateDirectories: true)
        try "sofhdadsp\n".write(to: card0.appendingPathComponent("id"), atomically: true, encoding: .utf8)
        try "Yeti\n".write(to: card1.appendingPathComponent("id"), atomically: true, encoding: .utf8)
        try "046d:0a38\n".write(to: card1.appendingPathComponent("usbid"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("Yeti").path, withDestinationPath: "card1")

        XCTAssertEqual(AlsaCardInspector.endpoint(forDevice: "plughw:0,6", procRoot: root.path)?.isBuiltIn, true)
        XCTAssertEqual(AlsaCardInspector.endpoint(forDevice: "hw:1,0", procRoot: root.path)?.isBuiltIn, false)
        XCTAssertEqual(AlsaCardInspector.endpoint(forDevice: "hw:CARD=Yeti,DEV=0", procRoot: root.path)?.isBuiltIn, false)
        XCTAssertNil(AlsaCardInspector.endpoint(forDevice: "hw:7,0", procRoot: root.path)?.isBuiltIn)
    }
}

final class RoutePolicyTests: XCTestCase {
    private func inspector(source: String?, sink: String? = nil, sourceDevice: String? = nil) -> RouteInspector {
        var responses: [String: CommandResult] = [:]
        responses["wpctl inspect @DEFAULT_AUDIO_SOURCE@"] = source.map { CommandResult(status: 0, output: $0) }
            ?? CommandResult(status: 3, output: "", errorOutput: "Object '@DEFAULT_AUDIO_SOURCE@' not found\n")
        if let sink { responses["wpctl inspect @DEFAULT_AUDIO_SINK@"] = CommandResult(status: 0, output: sink) }
        if let sourceDevice { responses["wpctl inspect 45"] = CommandResult(status: 0, output: sourceDevice) }
        return RouteInspector(runner: MockRunner(responses: responses))
    }

    func testInternalMicrophonePassesPassive() {
        let check = inspector(source: Fixtures.internalNode, sourceDevice: Fixtures.internalDevice)
            .check(settings: CaptureSettings(), strategy: .passive)
        XCTAssertNil(check.issue)
        XCTAssertTrue(check.warnings.isEmpty)
    }

    func testUSBMicrophoneIsRefusedUnlessAllowed() {
        let refused = inspector(source: Fixtures.usbNode).check(settings: CaptureSettings(), strategy: .passive)
        XCTAssertEqual(refused.issue, .builtInInputRequired(selected: "Yeti Stereo Microphone Analog Stereo"))
        XCTAssertNotNil(refused.issueDescription)

        let allowed = inspector(source: Fixtures.usbNode).check(settings: CaptureSettings(), strategy: .passive, allowExternalInput: true)
        XCTAssertNil(allowed.issue)
        XCTAssertFalse(allowed.warnings.isEmpty)
    }

    func testMissingDefaultSourceIsUnavailable() {
        let check = inspector(source: nil).check(settings: CaptureSettings(), strategy: .passive)
        XCTAssertEqual(check.issue, .inputUnavailable)
    }

    func testUnreachablePipeWireIsAWarningNotARefusal() {
        let runner = MockRunner(responses: [
            "wpctl inspect @DEFAULT_AUDIO_SOURCE@": CommandResult(status: 2, output: "", errorOutput: "Could not connect to PipeWire\n")
        ])
        let check = RouteInspector(runner: runner).check(settings: CaptureSettings(), strategy: .passive)
        XCTAssertNil(check.issue)
        XCTAssertTrue(check.warnings.contains { $0.contains("Could not connect to PipeWire") })
    }

    func testMissingWpctlIsAWarningNotARefusal() {
        let check = RouteInspector(runner: MockRunner(responses: [:])).check(settings: CaptureSettings(), strategy: .passive)
        XCTAssertNil(check.issue)
        XCTAssertTrue(check.warnings.contains { $0.contains("wpctl") })
    }

    func testFilteredSourceWarns() {
        let check = inspector(source: Fixtures.filterNode).check(settings: CaptureSettings(), strategy: .passive)
        XCTAssertNil(check.issue)
        XCTAssertTrue(check.warnings.contains { $0.contains("virtual or filtered") })
    }

    func testActiveSensingRequiresBuiltInSpeakers() {
        let good = inspector(source: Fixtures.internalNode, sink: Fixtures.internalSink, sourceDevice: Fixtures.internalDevice)
            .check(settings: CaptureSettings(), strategy: .active)
        XCTAssertNil(good.issue)

        let bad = inspector(source: Fixtures.internalNode, sink: Fixtures.bluetoothSink, sourceDevice: Fixtures.internalDevice)
            .check(settings: CaptureSettings(), strategy: .hybrid)
        XCTAssertEqual(bad.issue, .builtInOutputRequired(selected: "WH-1000XM4"))

        let passive = inspector(source: Fixtures.internalNode, sink: Fixtures.bluetoothSink, sourceDevice: Fixtures.internalDevice)
            .check(settings: CaptureSettings(), strategy: .passive)
        XCTAssertNil(passive.issue, "Passive sensing never checks the output")
    }

    func testCustomDeviceIsUnknownButAllowed() {
        let check = RouteInspector(runner: MockRunner(responses: [:]))
            .check(settings: CaptureSettings(device: "my_dsnoop"), strategy: .passive)
        XCTAssertNil(check.issue)
        XCTAssertEqual(check.route.input?.isBuiltIn, nil)
    }
}

final class ArgumentParsingTests: XCTestCase {
    func testOptionsFlagsAndPositionals() throws {
        let parsed = try ParsedArguments(
            ["set", "--profile", "Desk", "lr", "--verbose", "--taps=12", "--", "--literal"],
            valueOptions: ["profile", "taps"],
            flagOptions: ["verbose"]
        )
        XCTAssertEqual(parsed.positionals, ["set", "lr", "--literal"])
        XCTAssertEqual(parsed.value("profile"), "Desk")
        XCTAssertEqual(try parsed.integer("taps", range: 3...30), 12)
        XCTAssertTrue(parsed.has("verbose"))
    }

    func testUnknownOptionAndMissingValue() {
        XCTAssertThrowsError(try ParsedArguments(["--nope"]))
        XCTAssertThrowsError(try ParsedArguments(["--profile"], valueOptions: ["profile"]))
        XCTAssertThrowsError(try ParsedArguments(["--verbose=1"], flagOptions: ["verbose"]))
        let parsed = try? ParsedArguments(["--taps", "99"], valueOptions: ["taps"])
        XCTAssertThrowsError(try parsed?.integer("taps", range: 3...30))
    }

    func testZones() throws {
        XCTAssertEqual(try ZoneArgument.parse("lr"), .leftTop)
        XCTAssertEqual(try ZoneArgument.parse("Left Front"), .leftBottom)
        XCTAssertEqual(try ZoneArgument.parse("right_rear"), .rightTop)
        XCTAssertEqual(try ZoneArgument.parse("4"), .rightBottom)
        XCTAssertThrowsError(try ZoneArgument.parse("middle"))
    }

    func testActions() throws {
        XCTAssertEqual(try ActionArgument.parse(kind: "visual", value: []).kind, .none)
        XCTAssertEqual(try ActionArgument.parse(kind: "sound", value: []).soundName, "message")
        let shell = try ActionArgument.parse(kind: "shell", value: ["ls", "-la", "~"])
        XCTAssertEqual(shell.kind, .runShellCommand)
        XCTAssertEqual(shell.text, "ls -la ~")
        XCTAssertEqual(try ActionArgument.parse(kind: "url", value: ["example.com"]).text, "example.com")
        XCTAssertThrowsError(try ActionArgument.parse(kind: "url", value: ["ftp://example.com"]))
        XCTAssertThrowsError(try ActionArgument.parse(kind: "copy", value: [" "]))
        XCTAssertEqual(try ActionArgument.parse(kind: "screenshot-area", value: []).kind, .screenshotSelection)
        XCTAssertThrowsError(try ActionArgument.parse(kind: "teleport", value: []))
    }
}

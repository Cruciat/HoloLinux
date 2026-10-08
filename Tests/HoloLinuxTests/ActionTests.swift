import HoloCore
@testable import HoloLinux
import XCTest

final class LinuxActionPlannerTests: XCTestCase {
    func testMacOnlyKindsMapToLinuxEquivalents() {
        XCTAssertEqual(
            LinuxActionPlanner.command(for: ZoneActionConfiguration(kind: .openApplication, text: "firefox")),
            .launchApplication("firefox")
        )
        XCTAssertEqual(
            LinuxActionPlanner.command(for: ZoneActionConfiguration(kind: .openItem, text: "~/notes.md")),
            .openItem("~/notes.md")
        )
        if case .unsupported = LinuxActionPlanner.command(for: ZoneActionConfiguration(kind: .runShortcut, text: "Focus")) {
        } else {
            XCTFail("Shortcuts are macOS-only")
        }
        XCTAssertNil(LinuxActionPlanner.command(for: ZoneActionConfiguration(kind: .openApplication)))
        XCTAssertNil(LinuxActionPlanner.command(for: ZoneActionConfiguration(kind: .none)))
    }

    func testSharedKindsUseTheCorePlanner() {
        XCTAssertEqual(
            LinuxActionPlanner.command(for: ZoneActionConfiguration(kind: .openURL, text: "example.com")),
            .openURL(URL(string: "https://example.com")!)
        )
        XCTAssertNil(LinuxActionPlanner.command(for: ZoneActionConfiguration(kind: .openURL, text: "file:///etc/passwd")))
        XCTAssertEqual(
            LinuxActionPlanner.command(for: ZoneActionConfiguration(kind: .runShellCommand, text: " echo hi ")),
            .runShellCommand("echo hi")
        )
        XCTAssertEqual(LinuxActionPlanner.command(for: ZoneActionConfiguration(kind: .screenshotSelection)), .takeScreenshot(interactive: true))
    }
}

final class LinuxActionResolverTests: XCTestCase {
    private func resolver(
        tools: Set<String>,
        files: Set<String> = [],
        environment: [String: String] = ["WAYLAND_DISPLAY": "wayland-0", "XDG_CURRENT_DESKTOP": "GNOME", "HOME": "/home/elia"]
    ) -> LinuxActionResolver {
        LinuxActionResolver(
            session: DesktopSession(environment: environment),
            isAvailable: { tools.contains($0) },
            fileExists: { files.contains($0) },
            environment: environment
        )
    }

    func testCopyUsesWlCopyOnWaylandWithStdin() throws {
        let invocations = try resolver(tools: ["wl-copy", "xclip"]).invocations(for: .copyText("-n secret"))
        XCTAssertEqual(invocations, [.init(["wl-copy"], input: "-n secret", name: "Copy text")])
    }

    func testCopyOnX11AndMissingTools() throws {
        let x11 = resolver(tools: ["xclip"], environment: ["DISPLAY": ":0", "HOME": "/h"])
        XCTAssertEqual(try x11.invocations(for: .copyText("a")).first?.arguments, ["xclip", "-selection", "clipboard"])
        XCTAssertThrowsError(try resolver(tools: []).invocations(for: .copyText("a"))) { error in
            XCTAssertTrue(error.localizedDescription.contains("wl-clipboard"))
        }
        XCTAssertThrowsError(try resolver(tools: ["wl-copy"], environment: ["HOME": "/h"]).invocations(for: .copyText("a")))
    }

    func testSoundResolvesFreedesktopNamesAndMacAliases() throws {
        let file = "/usr/share/sounds/freedesktop/stereo/message.oga"
        let sounds = resolver(tools: ["pw-play"], files: [file])
        XCTAssertEqual(try sounds.invocations(for: .playSound("message")).first?.arguments, ["pw-play", file])
        XCTAssertEqual(try sounds.invocations(for: .playSound("Tink")).first?.arguments, ["pw-play", file])
        XCTAssertThrowsError(try sounds.invocations(for: .playSound("nope")))
        let canberra = resolver(tools: ["canberra-gtk-play"])
        XCTAssertEqual(try canberra.invocations(for: .playSound("bell")).first?.arguments, ["canberra-gtk-play", "-i", "bell"])
    }

    func testSpeechAvoidsOptionInjection() throws {
        let spd = try resolver(tools: ["spd-say"]).invocations(for: .speakText("-h"))
        XCTAssertEqual(spd.first?.arguments, ["spd-say", "--", " -h"])
        let espeak = try resolver(tools: ["espeak-ng"]).invocations(for: .speakText("ciao"))
        XCTAssertEqual(espeak.first, .init(["espeak-ng", "--stdin"], input: "ciao", name: "Speak text"))
    }

    func testOpeningURLsFilesAndApps() throws {
        let tools = resolver(
            tools: ["xdg-open", "gtk-launch"],
            files: ["/home/elia/notes.md", "/usr/share/applications/org.gnome.Nautilus.desktop"]
        )
        XCTAssertEqual(try tools.invocations(for: .openURL(URL(string: "https://example.com")!)).first?.arguments, ["xdg-open", "https://example.com"])
        XCTAssertEqual(try tools.invocations(for: .openItem("~/notes.md")).first?.arguments, ["xdg-open", "/home/elia/notes.md"])
        XCTAssertThrowsError(try tools.invocations(for: .openItem("~/missing.md")))
        XCTAssertEqual(try tools.invocations(for: .launchApplication("org.gnome.Nautilus")).first?.arguments, ["gtk-launch", "org.gnome.Nautilus"])
        XCTAssertThrowsError(try tools.invocations(for: .launchApplication("not-installed")))

        let gio = resolver(tools: ["gio"], files: ["/usr/share/applications/firefox.desktop"])
        XCTAssertEqual(try gio.invocations(for: .launchApplication("firefox")).first?.arguments, ["gio", "launch", "/usr/share/applications/firefox.desktop"])
    }

    func testShellUsesBashLoginShell() throws {
        XCTAssertEqual(try resolver(tools: ["bash"]).invocations(for: .runShellCommand("echo hi")).first?.arguments, ["bash", "-lc", "echo hi"])
        XCTAssertEqual(try resolver(tools: []).invocations(for: .runShellCommand("echo hi")).first?.arguments, ["/bin/sh", "-c", "echo hi"])
    }

    func testScreenshotToolsPerDesktop() throws {
        let gnome = resolver(tools: ["gnome-screenshot", "grim", "wl-copy"])
        XCTAssertEqual(try gnome.invocations(for: .takeScreenshot(interactive: true)).first?.arguments, ["gnome-screenshot", "-c", "-a"])
        let portal = resolver(tools: ["holo-screenshot-portal"])
        XCTAssertEqual(try portal.invocations(for: .takeScreenshot(interactive: false)).first?.arguments, ["holo-screenshot-portal"])
        let sway = resolver(tools: ["grim", "slurp", "wl-copy"], environment: ["WAYLAND_DISPLAY": "w", "XDG_CURRENT_DESKTOP": "sway", "HOME": "/h"])
        XCTAssertEqual(try sway.invocations(for: .takeScreenshot(interactive: false)).first?.arguments.first, "/bin/sh")
        let kde = resolver(tools: ["spectacle"], environment: ["WAYLAND_DISPLAY": "w", "XDG_CURRENT_DESKTOP": "KDE", "HOME": "/h"])
        XCTAssertEqual(try kde.invocations(for: .takeScreenshot(interactive: false)).first?.arguments, ["spectacle", "-b", "-n", "-c", "-f"])
        XCTAssertThrowsError(try resolver(tools: []).invocations(for: .takeScreenshot(interactive: false)))
    }

    func testUnsupportedThrows() {
        XCTAssertThrowsError(try resolver(tools: []).invocations(for: .unsupported("nope")))
    }
}

final class DispatcherTests: XCTestCase {
    func testShellCommandRunsAndReportsFailures() throws {
        let directory = temporaryDirectory()
        let marker = directory.appendingPathComponent("marker").path
        let dispatcher = LinuxActionDispatcher()
        try dispatcher.perform(ZoneActionConfiguration(kind: .runShellCommand, text: "printf done > '\(marker)'"))
        let failed = expectation(description: "failure reported")
        dispatcher.onAsyncError = { message in
            XCTAssertTrue(message.contains("status 3"))
            failed.fulfill()
        }
        try dispatcher.perform(ZoneActionConfiguration(kind: .runShellCommand, text: "exit 3"))
        wait(for: [failed], timeout: 5)
        // The two commands run concurrently; wait for the first one's output.
        let deadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: marker), Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(try String(contentsOfFile: marker, encoding: .utf8), "done")
    }

    func testVisualOnlyDoesNothing() throws {
        try LinuxActionDispatcher().perform(ZoneActionConfiguration(kind: .none))
    }

    func testNotificationIDParsing() {
        XCTAssertEqual(DesktopNotifier.parseNotificationID("(uint32 42,)\n"), 42)
        XCTAssertNil(DesktopNotifier.parseNotificationID(""))
    }
}

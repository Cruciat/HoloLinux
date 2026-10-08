import Foundation
import HoloCore
#if canImport(Glibc)
import Glibc
#endif

/// Minimal terminal output: colors when attached to a TTY, an in-place status
/// line, and raw single-key input for guided sessions.
public final class Terminal {
    public static let shared = Terminal()

    public let isOutputTTY: Bool
    public let isInputTTY: Bool
    public let usesColor: Bool
    private var savedAttributes: termios?
    private var statusVisible = false

    public init(
        isOutputTTY: Bool = isatty(STDOUT_FILENO) == 1,
        isInputTTY: Bool = isatty(STDIN_FILENO) == 1,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.isOutputTTY = isOutputTTY
        self.isInputTTY = isInputTTY
        self.usesColor = isOutputTTY && environment["NO_COLOR"] == nil && environment["TERM"] != "dumb"
    }

    // MARK: Styling

    public func style(_ text: String, _ codes: String) -> String {
        usesColor ? "\u{1B}[\(codes)m\(text)\u{1B}[0m" : text
    }

    public func bold(_ text: String) -> String { style(text, "1") }
    public func dim(_ text: String) -> String { style(text, "2") }
    public func green(_ text: String) -> String { style(text, "32") }
    public func red(_ text: String) -> String { style(text, "31") }
    public func yellow(_ text: String) -> String { style(text, "33") }
    public func cyan(_ text: String) -> String { style(text, "36") }
    public func highlight(_ text: String) -> String { style(text, "1;7") }

    // MARK: Output

    /// Prints a full line, clearing any in-place status first.
    public func line(_ text: String = "") {
        clearStatus()
        write(text + "\n")
    }

    public func error(_ text: String) {
        clearStatus()
        fputs(red("error: ") + text + "\n", stderr)
        fflush(stderr)
    }

    public func warning(_ text: String) {
        clearStatus()
        write(yellow("warning: ") + text + "\n")
    }

    /// Rewrites the current status line in place (TTY) or prints it (pipe).
    public func status(_ text: String) {
        if isOutputTTY {
            write("\r\u{1B}[2K" + text)
            statusVisible = true
        } else {
            write(text + "\n")
        }
    }

    public func clearStatus() {
        guard statusVisible else { return }
        write("\r\u{1B}[2K")
        statusVisible = false
    }

    private func write(_ text: String) {
        fputs(text, stdout)
        fflush(stdout)
    }

    // MARK: Input

    /// Disables line buffering and echo so single keys reach the event loop.
    public func enableRawInput() {
        guard isInputTTY, savedAttributes == nil else { return }
        var attributes = termios()
        guard tcgetattr(STDIN_FILENO, &attributes) == 0 else { return }
        savedAttributes = attributes
        attributes.c_lflag &= ~tcflag_t(ICANON | ECHO)
        withUnsafeMutableBytes(of: &attributes.c_cc) { bytes in
            bytes[Int(VMIN)] = 1
            bytes[Int(VTIME)] = 0
        }
        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
    }

    public func restoreInput() {
        clearStatus()
        guard var attributes = savedAttributes else { return }
        tcsetattr(STDIN_FILENO, TCSANOW, &attributes)
        savedAttributes = nil
    }

    // MARK: Desk map

    /// Draws the four zones around the laptop, marking the highlighted zone.
    public func deskMap(highlight: DeskZone?, labels: [DeskZone: String] = [:]) -> [String] {
        func cell(_ zone: DeskZone, leftAligned: Bool) -> String {
            let name = zone.displayName
            let extra = labels[zone].map { " " + $0 } ?? ""
            let plain = leftAligned ? "\(zone.shortName)  \(name)\(extra)" : "\(name)\(extra)  \(zone.shortName)"
            let padded = leftAligned
                ? plain.padding(toLength: 28, withPad: " ", startingAt: 0)
                : String(repeating: " ", count: max(0, 28 - plain.count)) + plain
            return zone == highlight ? self.highlight(padded) : padded
        }
        let gap = String(repeating: " ", count: 28)
        return [
            gap + dim("     display side     "),
            cell(.leftTop, leftAligned: false) + "  ┌──────────────────┐  " + cell(.rightTop, leftAligned: true),
            gap + "  │      laptop      │  ",
            cell(.leftBottom, leftAligned: false) + "  └──────────────────┘  " + cell(.rightBottom, leftAligned: true),
            gap + dim("    keyboard side     ")
        ]
    }

    /// A horizontal level meter for dBFS values between -90 and 0.
    public func meter(dbfs: Double, floorDBFS: Double, width: Int = 30) -> String {
        let fraction = min(max((dbfs + 90) / 90, 0), 1)
        let floorFraction = min(max((floorDBFS + 90) / 90, 0), 1)
        let filled = Int((fraction * Double(width)).rounded())
        let floorIndex = min(Int((floorFraction * Double(width)).rounded()), width - 1)
        var characters = Array(repeating: Character("·"), count: width)
        for index in 0..<filled { characters[index] = "█" }
        if characters[floorIndex] != "█" { characters[floorIndex] = "|" }
        return "[" + String(characters) + "]"
    }
}

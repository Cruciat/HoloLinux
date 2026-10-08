import Foundation
import HoloCore

public struct ArgumentError: Error, LocalizedError, Equatable {
    public var message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

/// A small option parser: `--name value`, `--name=value`, boolean `--flag`,
/// and `--` to end option parsing.
public struct ParsedArguments: Equatable {
    public var positionals: [String] = []
    public var values: [String: String] = [:]
    public var flags: Set<String> = []

    public init(_ arguments: [String], valueOptions: Set<String> = [], flagOptions: Set<String> = []) throws {
        var index = 0
        var optionsEnded = false
        while index < arguments.count {
            let argument = arguments[index]
            index += 1
            if optionsEnded || !argument.hasPrefix("--") || argument == "-" {
                positionals.append(argument)
                continue
            }
            if argument == "--" {
                optionsEnded = true
                continue
            }
            var name = String(argument.dropFirst(2))
            var inlineValue: String?
            if let equals = name.firstIndex(of: "=") {
                inlineValue = String(name[name.index(after: equals)...])
                name = String(name[..<equals])
            }
            if valueOptions.contains(name) {
                if let inlineValue {
                    values[name] = inlineValue
                } else {
                    guard index < arguments.count else { throw ArgumentError("--\(name) needs a value.") }
                    values[name] = arguments[index]
                    index += 1
                }
            } else if flagOptions.contains(name) {
                guard inlineValue == nil else { throw ArgumentError("--\(name) does not take a value.") }
                flags.insert(name)
            } else {
                throw ArgumentError("Unknown option --\(name).")
            }
        }
    }

    public func value(_ name: String) -> String? { values[name] }
    public func has(_ flag: String) -> Bool { flags.contains(flag) }

    public func integer(_ name: String, range: ClosedRange<Int>) throws -> Int? {
        guard let raw = values[name] else { return nil }
        guard let number = Int(raw), range.contains(number) else {
            throw ArgumentError("--\(name) must be a whole number from \(range.lowerBound) to \(range.upperBound).")
        }
        return number
    }
}

public enum ZoneArgument {
    public static let help = "lr (left rear), lf (left front), rr (right rear), rf (right front)"

    public static func parse(_ text: String) throws -> DeskZone {
        let normalized = text.lowercased()
            .replacingOccurrences(of: "_", with: "-")
            .replacingOccurrences(of: " ", with: "-")
        let table: [String: DeskZone] = [
            "lr": .leftTop, "left-rear": .leftTop, "rear-left": .leftTop, "1": .leftTop,
            "lf": .leftBottom, "left-front": .leftBottom, "front-left": .leftBottom, "2": .leftBottom,
            "rr": .rightTop, "right-rear": .rightTop, "rear-right": .rightTop, "3": .rightTop,
            "rf": .rightBottom, "right-front": .rightBottom, "front-right": .rightBottom, "4": .rightBottom
        ]
        guard let zone = table[normalized] else {
            throw ArgumentError("Unknown zone \"\(text)\". Use \(help).")
        }
        return zone
    }
}

public enum StrategyArgument {
    public static func parse(_ text: String) throws -> SensingStrategy {
        guard let strategy = SensingStrategy(rawValue: text.lowercased()) else {
            throw ArgumentError("Unknown sensing strategy \"\(text)\". Use passive, active, or hybrid.")
        }
        return strategy
    }
}

public enum ActionArgument {
    public static let kinds: [(name: String, usage: String)] = [
        ("visual", "visual                 no side effect (log and notification only)"),
        ("sound", "sound [NAME|FILE]      play a freedesktop sound (default: message) or a sound file"),
        ("copy", "copy TEXT              copy text to the clipboard"),
        ("speak", "speak TEXT             speak text aloud"),
        ("url", "url ADDRESS            open an http(s) address in the browser"),
        ("app", "app ID                 launch an app by desktop id (e.g. firefox, org.gnome.Nautilus) or command"),
        ("open", "open PATH              open a file or folder with its default app"),
        ("shell", "shell COMMAND          run a shell command (bash -lc)"),
        ("screenshot", "screenshot             copy a screenshot of the whole screen"),
        ("screenshot-area", "screenshot-area        select an area and copy it")
    ]

    public static func parse(kind: String, value words: [String]) throws -> ZoneActionConfiguration {
        let value = words.joined(separator: " ")
        func requireValue(_ what: String) throws -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw ArgumentError("The \(kind) action needs \(what).") }
            return trimmed
        }
        switch kind.lowercased() {
        case "visual", "none":
            return ZoneActionConfiguration(kind: .none)
        case "sound":
            let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return ZoneActionConfiguration(kind: .sound, soundName: name.isEmpty ? "message" : name)
        case "copy", "copy-text":
            return ZoneActionConfiguration(kind: .copyText, text: try requireValue("the text to copy"))
        case "speak", "speak-text", "say":
            return ZoneActionConfiguration(kind: .speakText, text: try requireValue("the text to speak"))
        case "url", "website", "open-url":
            let address = try requireValue("an address")
            let configuration = ZoneActionConfiguration(kind: .openURL, text: address)
            guard LocalActionPlanner.command(for: configuration) != nil else {
                throw ArgumentError("\"\(address)\" is not an http or https address.")
            }
            return configuration
        case "app", "application", "open-app":
            return ZoneActionConfiguration(kind: .openApplication, text: try requireValue("a desktop id or command"))
        case "open", "file", "folder", "open-item":
            return ZoneActionConfiguration(kind: .openItem, text: try requireValue("a path"))
        case "shell", "command", "run":
            return ZoneActionConfiguration(kind: .runShellCommand, text: try requireValue("a command"))
        case "screenshot":
            return ZoneActionConfiguration(kind: .screenshotClipboard)
        case "screenshot-area", "screenshot-selection", "capture-selection":
            return ZoneActionConfiguration(kind: .screenshotSelection)
        default:
            throw ArgumentError("Unknown action \"\(kind)\". Run `holo actions --help` for the list.")
        }
    }
}

#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import HoloReplaySupport

private struct CLIConfiguration {
    var profileURL: URL?
    var evaluationURL: URL?
    var wavDirectoryURL: URL?
    var mode: ReplayMode = .vectors
    var json = false

    static func parse(_ arguments: [String]) throws -> CLIConfiguration {
        var configuration = CLIConfiguration()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--profile":
                configuration.profileURL = URL(fileURLWithPath: try value(after: argument, at: &index, in: arguments))
            case "--evaluation":
                configuration.evaluationURL = URL(fileURLWithPath: try value(after: argument, at: &index, in: arguments))
            case "--wav-dir":
                configuration.wavDirectoryURL = URL(fileURLWithPath: try value(after: argument, at: &index, in: arguments))
            case "--mode":
                let rawValue = try value(after: argument, at: &index, in: arguments)
                guard let mode = ReplayMode(rawValue: rawValue) else {
                    throw CLIError.invalidMode(rawValue)
                }
                configuration.mode = mode
            case "--json":
                configuration.json = true
            default:
                throw CLIError.unknownArgument(argument)
            }
            index += 1
        }

        guard configuration.profileURL != nil else { throw CLIError.missingArgument("--profile") }
        guard configuration.evaluationURL != nil else { throw CLIError.missingArgument("--evaluation") }
        return configuration
    }

    private static func value(
        after option: String,
        at index: inout Int,
        in arguments: [String]
    ) throws -> String {
        index += 1
        guard index < arguments.count, !arguments[index].hasPrefix("--") else {
            throw CLIError.missingValue(option)
        }
        return arguments[index]
    }
}

private enum CLIError: Error, LocalizedError {
    case missingArgument(String)
    case missingValue(String)
    case invalidMode(String)
    case unknownArgument(String)

    var errorDescription: String? {
        switch self {
        case .missingArgument(let argument): return "missing required argument \(argument)"
        case .missingValue(let argument): return "missing value for \(argument)"
        case .invalidMode(let mode): return "invalid mode \(mode); expected vectors or wav"
        case .unknownArgument(let argument): return "unknown argument \(argument)"
        }
    }
}

@main
enum HoloReplayMain {
    private static let usage = """
    Usage: HoloReplay --profile <profile.json> --evaluation <evaluation.json> [--wav-dir <dir>] [--mode vectors|wav] [--json]
    """

    static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }

        do {
            let configuration = try CLIConfiguration.parse(arguments)
            if configuration.mode == .wav {
                throw ReplayError.wavModeUnavailable
            }
            let profile = try ReplayInput.loadProfile(at: configuration.profileURL!)
            let evaluation = try ReplayInput.loadEvaluation(at: configuration.evaluationURL!)
            let result = try ReplayScorer.score(profile: profile, evaluation: evaluation)
            if configuration.json {
                FileHandle.standardOutput.write(try result.jsonData())
                FileHandle.standardOutput.write(Data("\n".utf8))
            } else {
                FileHandle.standardOutput.write(Data(result.humanReadable().utf8))
            }
        } catch {
            let message = "HoloReplay: \(error.localizedDescription)\n\(usage)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(2)
        }
    }
}

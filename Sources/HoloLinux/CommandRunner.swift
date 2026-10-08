import Foundation

public struct CommandResult: Equatable, Sendable {
    public var status: Int32
    public var output: String
    public var errorOutput: String

    public init(status: Int32, output: String, errorOutput: String = "") {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }
}

/// Runs short helper commands (wpctl, gdbus) and captures their output.
public protocol CommandRunning: Sendable {
    func run(_ executable: String, _ arguments: [String], timeout: Double) -> CommandResult?
}

public struct ProcessCommandRunner: CommandRunning {
    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: Double = 3) -> CommandResult? {
        guard let path = ToolLocator.find(executable) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return nil
        }
        let watchdog = DispatchWorkItem { [process] in
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        // Drain stderr concurrently so a chatty helper cannot fill its pipe
        // and block before closing stdout.
        let errorBuffer = DataBox()
        let errorDrained = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errorBuffer.data = errors.fileHandleForReading.readDataToEndOfFile()
            errorDrained.signal()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        errorDrained.wait()
        let errorData = errorBuffer.data
        process.waitUntilExit()
        watchdog.cancel()
        return CommandResult(
            status: process.terminationStatus,
            output: String(decoding: data, as: UTF8.self),
            errorOutput: String(decoding: errorData, as: UTF8.self)
        )
    }
}

/// Hands data from the stderr reader back to the caller; the semaphore orders the accesses.
private final class DataBox: @unchecked Sendable {
    var data = Data()
}

/// Finds helper executables on PATH, plus the usual system locations that a
/// systemd user service may not have on its PATH.
public enum ToolLocator {
    public static let fallbackDirectories = ["/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]

    public static func find(_ name: String, environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }
        var directories = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        if let home = environment["HOME"] {
            directories.append(home + "/.local/bin")
        }
        directories += fallbackDirectories
        for directory in directories where !directory.isEmpty {
            let candidate = directory + "/" + name
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    public static func isAvailable(_ name: String) -> Bool { find(name) != nil }
}

import Foundation
import HoloCore
import HoloLinux
#if canImport(Glibc)
import Glibc
#endif

setvbuf(stdout, nil, _IOLBF, 0)

let commands: [(name: String, summary: String, run: ([String]) throws -> Int32)] = [
    ("check", "Show the microphone route, helper tools, profiles, and service state", CheckCommand.run),
    ("calibrate", "Guided calibration of the four desk zones", CalibrateCommand.run),
    ("evaluate", "Guided 60-tap accuracy test for the active profile", EvaluateCommand.run),
    ("report", "Show the latest accuracy report", ReportCommand.run),
    ("monitor", "Live input level and tap classification, without actions", MonitorCommand.run),
    ("compare", "Compare passive, active, and hybrid sensing on this desk", CompareCommand.run),
    ("actions", "List, assign, clear, or test zone actions", ActionsCommand.run),
    ("profiles", "List, select, show, rename, or delete desk profiles", ProfilesCommand.run),
    ("config", "Show or change settings (notifications, default device)", ConfigCommand.run),
    ("run", "Listen in the foreground and run actions (what the service runs)", ServiceCommands.run),
    ("pause", "Pause the background service (releases the microphone)", ServiceCommands.pause),
    ("resume", "Resume the background service", ServiceCommands.resume),
    ("status", "Show whether the background service is running", ServiceCommands.status)
]

func printUsage() {
    let terminal = Terminal.shared
    terminal.line("\(terminal.bold("holo")) \(HoloVersion.string) — tap your desk, your Linux laptop responds.")
    terminal.line()
    terminal.line("Usage: holo <command> [options]")
    terminal.line()
    terminal.line("Commands:")
    for command in commands {
        terminal.line("  " + command.name.padding(toLength: 11, withPad: " ", startingAt: 0) + command.summary)
    }
    terminal.line()
    terminal.line("Getting started:")
    terminal.line("  holo check                      confirm the internal microphone is selected")
    terminal.line("  holo monitor                    watch the level meter and try a few taps")
    terminal.line("  holo calibrate                  teach Holo the four zones (40 taps)")
    terminal.line("  holo evaluate                   measure accuracy with 60 new taps")
    terminal.line("  holo actions set lr shell 'notify-send hello'")
    terminal.line("  systemctl --user enable --now holo")
    terminal.line()
    terminal.line("Run `holo <command> --help` for details.")
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let commandName = arguments.first else {
    printUsage()
    exit(0)
}
if ["-h", "--help", "help"].contains(commandName) {
    printUsage()
    exit(0)
}
if ["-V", "--version", "version"].contains(commandName) {
    print("holo \(HoloVersion.string)")
    exit(0)
}
guard let command = commands.first(where: { $0.name == commandName }) else {
    Terminal.shared.error("Unknown command \"\(commandName)\".")
    printUsage()
    exit(64)
}
do {
    exit(try command.run(Array(arguments.dropFirst())))
} catch let error as ArgumentError {
    Terminal.shared.restoreInput()
    Terminal.shared.error(error.message)
    exit(64)
} catch let error as CLIError {
    Terminal.shared.restoreInput()
    Terminal.shared.error(error.message)
    exit(error.status)
} catch {
    Terminal.shared.restoreInput()
    Terminal.shared.error(error.localizedDescription)
    exit(1)
}

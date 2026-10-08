import Foundation
#if canImport(Glibc)
import Glibc
#endif

private var holoSignalWriteDescriptor: Int32 = -1

private func holoSignalHandler(_ signal: Int32) {
    var byte = UInt8(truncatingIfNeeded: signal)
    _ = write(holoSignalWriteDescriptor, &byte, 1)
}

/// A single-threaded loop built on poll(2). Capture threads post work to it;
/// it also delivers keyboard bytes, Unix signals, and a periodic tick.
public final class EventLoop {
    private let lock = NSLock()
    private var pending: [() -> Void] = []
    private let wakeRead: Int32
    private let wakeWrite: Int32
    private var signalRead: Int32 = -1
    private var running = false
    private var stdinOpen = true

    public var watchesStandardInput = false
    public var tickInterval: Double = 0.05
    public var onKey: ((UInt8) -> Void)?
    public var onStandardInputClosed: (() -> Void)?
    public var onSignal: ((Int32) -> Void)?
    public var onTick: (() -> Void)?

    public init() {
        var descriptors: [Int32] = [0, 0]
        if pipe(&descriptors) != 0 {
            fatalError("pipe() failed: \(errno)")
        }
        wakeRead = descriptors[0]
        wakeWrite = descriptors[1]
        Self.setNonBlocking(wakeRead)
        Self.setNonBlocking(wakeWrite)
    }

    deinit {
        close(wakeRead)
        close(wakeWrite)
    }

    /// Routes the given signals into this loop's `onSignal`.
    public func handleSignals(_ signals: [Int32]) {
        var descriptors: [Int32] = [0, 0]
        guard pipe(&descriptors) == 0 else { return }
        signalRead = descriptors[0]
        holoSignalWriteDescriptor = descriptors[1]
        Self.setNonBlocking(signalRead)
        Self.setNonBlocking(descriptors[1])
        for signalNumber in signals {
            signal(signalNumber, holoSignalHandler)
        }
    }

    /// Thread-safe: schedules `work` on the loop thread and wakes it.
    public func post(_ work: @escaping () -> Void) {
        lock.lock()
        pending.append(work)
        lock.unlock()
        var byte: UInt8 = 1
        _ = write(wakeWrite, &byte, 1)
    }

    public func stop() {
        running = false
    }

    public func run() {
        running = true
        var lastTick = HoloClock.now()
        while running {
            var descriptors = [pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0)]
            if signalRead >= 0 {
                descriptors.append(pollfd(fd: signalRead, events: Int16(POLLIN), revents: 0))
            }
            let stdinIndex: Int?
            if watchesStandardInput && stdinOpen {
                stdinIndex = descriptors.count
                descriptors.append(pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0))
            } else {
                stdinIndex = nil
            }
            let timeout = Int32(max(tickInterval * 1_000, 1))
            let ready = poll(&descriptors, nfds_t(descriptors.count), timeout)
            if ready < 0 && errno != EINTR { break }

            if ready > 0 {
                if descriptors[0].revents != 0 { drain(wakeRead) }
                if signalRead >= 0, descriptors[1].revents != 0 {
                    for signalNumber in drain(signalRead) {
                        onSignal?(Int32(signalNumber))
                    }
                }
                if let stdinIndex, descriptors[stdinIndex].revents != 0 {
                    readStandardInput()
                }
            }
            runPending()
            let now = HoloClock.now()
            if now - lastTick >= tickInterval * 0.9 {
                lastTick = now
                onTick?()
            }
        }
        runPending()
    }

    private func runPending() {
        lock.lock()
        let work = pending
        pending.removeAll()
        lock.unlock()
        for item in work {
            item()
            if !running { break }
        }
    }

    private func readStandardInput() {
        var buffer = [UInt8](repeating: 0, count: 64)
        let count = read(STDIN_FILENO, &buffer, buffer.count)
        if count <= 0 {
            if count == 0 || (errno != EAGAIN && errno != EINTR) {
                stdinOpen = false
                onStandardInputClosed?()
            }
            return
        }
        for byte in buffer.prefix(count) {
            onKey?(byte)
        }
    }

    @discardableResult
    private func drain(_ descriptor: Int32) -> [UInt8] {
        var collected: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 64)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            collected += buffer.prefix(count)
        }
        return collected
    }

    private static func setNonBlocking(_ descriptor: Int32) {
        let flags = fcntl(descriptor, F_GETFL)
        _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC)
    }
}

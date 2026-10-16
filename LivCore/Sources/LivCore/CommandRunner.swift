import Foundation
import os

public struct CommandResult: Sendable, Equatable {
    public let status: Int32
    public let output: String
    public let errorOutput: String

    public init(status: Int32, output: String = "", errorOutput: String = "") {
        self.status = status
        self.output = output
        self.errorOutput = errorOutput
    }
}

public enum CommandError: Error, Equatable, LocalizedError {
    case notAbsolute(String)
    case timedOut(String)
    case couldNotStart(String)

    public var errorDescription: String? {
        switch self {
        case .notAbsolute(let path): "The command path is not absolute: \(path)"
        case .timedOut(let command): "\(command) took too long and was stopped."
        case .couldNotStart(let command): "\(command) could not be started."
        }
    }
}

/// Runs one program. A protocol, so tests record what was asked instead of running anything.
public protocol CommandRunning: Sendable {
    /// A status other than 0 is returned, not thrown: the caller decides what it means.
    func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult
}

/// Runs a program with `Process`: absolute path, arguments as an array (never a shell string), no input,
/// a minimal environment, at most 64 KB of each output, and the program is stopped when it takes too long or
/// the task is cancelled.
public struct ProcessCommandRunner: CommandRunning {
    static let outputLimit = 64 * 1024
    /// Pipe ends are not close-on-exec: one created while another program is being started would be inherited by
    /// it, and the reads would not see the end of the output until that program exited. Creating the pipes and
    /// starting the program are therefore serialised.
    private static let spawnLock = NSLock()

    public init() {}

    public func run(_ executable: String, _ arguments: [String], timeout: Duration) async throws -> CommandResult {
        guard executable.hasPrefix("/") else { throw CommandError.notAbsolute(executable) }
        let process = Process()
        process.executableURL = URL(filePath: executable)
        process.arguments = arguments
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "LANG": "en_US.UTF-8",
        ]
        process.standardInput = FileHandle.nullDevice
        let control = Control(process)
        let name = URL(filePath: executable).lastPathComponent

        let result = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                let outHandle: FileHandle
                let errHandle: FileHandle
                do {
                    (outHandle, errHandle) = try Self.spawnLock.withLock {
                        let outPipe = Pipe()
                        let errPipe = Pipe()
                        try control.launch(outPipe, errPipe)
                        return (outPipe.fileHandleForReading, errPipe.fileHandleForReading)
                    }
                } catch is CancellationError {
                    continuation.resume(throwing: CancellationError())
                    return
                } catch {
                    continuation.resume(throwing: CommandError.couldNotStart(name))
                    return
                }
                let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { control.stop(timedOut: true) }
                DispatchQueue.global().async {
                    // Both pipes are read at the same time, so a program that fills one never blocks on it.
                    let group = DispatchGroup()
                    let captured = OSAllocatedUnfairLock(initialState: (out: Data(), err: Data()))
                    group.enter()
                    DispatchQueue.global().async {
                        let data = Self.drain(outHandle)
                        captured.withLock { $0.out = data }
                        group.leave()
                    }
                    group.enter()
                    DispatchQueue.global().async {
                        let data = Self.drain(errHandle)
                        captured.withLock { $0.err = data }
                        group.leave()
                    }
                    group.wait()
                    let status = control.finish()
                    let (out, err) = captured.withLock { ($0.out, $0.err) }
                    continuation.resume(returning: CommandResult(
                        status: status,
                        output: String(decoding: out, as: UTF8.self),
                        errorOutput: String(decoding: err, as: UTF8.self)
                    ))
                }
            }
        } onCancel: {
            control.stop()
        }

        if control.timedOut { throw CommandError.timedOut(name) }
        if control.wasStopped { throw CancellationError() }
        return result
    }

    /// Reads until the program closes its end, keeping the first `outputLimit` bytes and discarding the rest.
    private static func drain(_ handle: FileHandle) -> Data {
        var kept = Data()
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            if kept.count < outputLimit { kept.append(chunk.prefix(outputLimit - kept.count)) }
        }
        return kept
    }

    /// Lets cancellation and the timeout end the process from other threads.
    private final class Control: @unchecked Sendable {
        private struct State {
            var launched = false
            var stopRequested = false
            var timedOut = false
        }

        private let process: Process
        private let exited = DispatchSemaphore(value: 0)
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(_ process: Process) {
            self.process = process
            // `waitUntilExit` waits on a run loop, and from a background thread its wake-up was sometimes lost
            // under parallel load, so the wait hung. The termination handler runs on a dispatch queue instead.
            let exited = exited
            process.terminationHandler = { _ in exited.signal() }
        }

        func launch(_ out: Pipe, _ err: Pipe) throws {
            try state.withLock { state in
                if state.stopRequested { throw CancellationError() }
                process.standardOutput = out
                process.standardError = err
                try process.run()
                state.launched = true
            }
        }

        func stop(timedOut: Bool = false) {
            state.withLock { state in
                state.stopRequested = true
                if timedOut { state.timedOut = true }
                if state.launched, process.isRunning { process.terminate() }
            }
        }

        var timedOut: Bool { state.withLock { $0.timedOut } }
        var wasStopped: Bool { state.withLock { $0.stopRequested } }

        func finish() -> Int32 {
            exited.wait()
            return process.terminationStatus
        }
    }
}

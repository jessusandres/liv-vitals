import Darwin
import Foundation
import os

/// What the Dev Projects scan needs to know from git. A protocol, so tests do not depend on this machine's git.
public protocol GitInspecting: Sendable {
    /// Of `paths` (inside `repository`), the ones git tracks at least one file under.
    func trackedPaths(_ paths: [URL], in repository: URL) async throws -> Set<URL>

    /// When the last commit that touches `path` was made, or nil when none does.
    func lastCommitDate(touching path: URL, in repository: URL) async throws -> Date?
}

public enum GitError: Error, Equatable, LocalizedError {
    case timedOut
    case failed(status: Int32)
    case outsideRepository(URL)

    public var errorDescription: String? {
        switch self {
        case .timedOut: "git took too long to answer."
        case .failed(let status): "git failed with status \(status)."
        case .outsideRepository(let url): "\(url.path) is not inside the repository."
        }
    }
}

/// The folder of the repository that holds `url`, found by looking for `.git` (a folder, or a file in a
/// worktree) with `lstat`, from the parent of `url` up to `root`. Runs no git.
public func gitRepositoryRoot(containing url: URL, stopAt root: URL) -> URL? {
    let stop = PathMath.components(of: root)
    var current = url.deletingLastPathComponent().standardizedFileURL
    while true {
        let key = PathMath.components(of: current)
        guard PathMath.isSameOrInside(key, of: stop) else { return nil }
        var status = stat()
        if lstat(current.appending(path: ".git").path, &status) == 0 {
            return URL(filePath: current.path, directoryHint: .isDirectory)
        }
        if key.count == stop.count { return nil }
        current = current.deletingLastPathComponent()
    }
}

/// Reads repositories with the real `git`, and only reads: every call passes `--no-optional-locks` and is
/// limited to `ls-files` and `log`.
///
/// It uses the git inside the developer tools. The `git` stub in the system folder would open macOS's
/// install dialog when no tools are installed, so it is never run.
public struct SystemGit: GitInspecting {
    public let executable: URL

    private static let timeout = Duration.seconds(10)
    private static let batchSize = 200

    public init(executable: URL) {
        self.executable = executable
    }

    /// nil when no developer tools are installed.
    public init?() {
        guard let executable = Self.locate() else { return nil }
        self.executable = executable
    }

    /// `xcode-select -p` prints the active developer folder without ever showing a dialog. The Command Line
    /// Tools folder is the fallback. The result is used only if the binary is really there.
    private static func locate() -> URL? {
        var folders: [URL] = []
        if let active = developerFolder() { folders.append(active) }
        folders.append(URL(filePath: "/Library/Developer/CommandLineTools", directoryHint: .isDirectory))
        return folders
            .map { $0.appending(path: "usr/bin/git") }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func developerFolder() -> URL? {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/xcode-select")
        process.arguments = ["-p"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return path.hasPrefix("/") ? URL(filePath: path, directoryHint: .isDirectory) : nil
    }

    // MARK: - GitInspecting

    public func trackedPaths(_ paths: [URL], in repository: URL) async throws -> Set<URL> {
        var tracked = Set<URL>()
        for start in stride(from: 0, to: paths.count, by: Self.batchSize) {
            let batch = Array(paths[start..<min(start + Self.batchSize, paths.count)])
            let relatives = try batch.map { try Self.relativePath(of: $0, in: repository) }
            let output = try await run(
                ["--literal-pathspecs", "--no-optional-locks", "-C", repository.path, "ls-files", "-z", "--"] + relatives
            )
            let listed = output.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
            for (url, relative) in zip(batch, relatives) {
                let prefix = relative + "/"
                if listed.contains(where: { $0 == relative || $0.hasPrefix(prefix) }) { tracked.insert(url) }
            }
        }
        return tracked
    }

    public func lastCommitDate(touching path: URL, in repository: URL) async throws -> Date? {
        let relative = try Self.relativePath(of: path, in: repository)
        let output = try await run(["--literal-pathspecs", "--no-optional-locks", "-C", repository.path, "log", "-1", "--format=%ct", "--", relative])
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return TimeInterval(text).map { Date(timeIntervalSince1970: $0) }
    }

    /// `path` relative to `repository`, or "." for the repository itself.
    private static func relativePath(of path: URL, in repository: URL) throws -> String {
        let full = path.standardizedFileURL.path
        let base = repository.standardizedFileURL.path
        if full == base { return "." }
        guard full.hasPrefix(base + "/") else { throw GitError.outsideRepository(path) }
        return String(full.dropFirst(base.count + 1))
    }

    private func run(_ arguments: [String]) async throws -> Data {
        // A minimal environment: no prompts, no optional locks, nothing inherited that could change what git does.
        let environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": NSHomeDirectory(),
            "GIT_TERMINAL_PROMPT": "0",
            "GIT_OPTIONAL_LOCKS": "0",
        ]
        return try await ProcessRunner.run(executable, arguments, environment: environment, timeout: Self.timeout)
    }
}

/// Runs one program with no shell and no input, collects its output, and stops it when it takes too long
/// or the task is cancelled.
enum ProcessRunner {
    /// Wraps the process so cancellation and the timeout can end it from other threads.
    private final class Control: @unchecked Sendable {
        private struct State {
            var launched = false
            var stopRequested = false
            var timedOut = false
        }

        private let process: Process
        private let state = OSAllocatedUnfairLock(initialState: State())

        init(_ process: Process) {
            self.process = process
        }

        func launch() throws {
            try state.withLock { state in
                if state.stopRequested { throw CancellationError() }
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
            process.waitUntilExit()
            return process.terminationStatus
        }
    }

    static func run(_ executable: URL, _ arguments: [String], environment: [String: String], timeout: Duration) async throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let control = Control(process)
        let reading = pipe.fileHandleForReading

        let (data, status) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(Data, Int32), Error>) in
                do {
                    try control.launch()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let seconds = Double(timeout.components.seconds)
                DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { control.stop(timedOut: true) }
                DispatchQueue.global().async {
                    // Read until the program closes its output, so a large answer never blocks it.
                    let data = reading.readDataToEndOfFile()
                    continuation.resume(returning: (data, control.finish()))
                }
            }
        } onCancel: {
            control.stop()
        }

        if control.timedOut { throw GitError.timedOut }
        if control.wasStopped { throw CancellationError() }
        guard status == 0 else { throw GitError.failed(status: status) }
        return data
    }
}

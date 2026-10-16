import Foundation
import Testing
@testable import LivCore

/// Runs the real git, so these need developer tools on the machine and are skipped without them.
struct SystemGitTests {
    private static let available = SystemGit() != nil
    private static let commitSeconds: TimeInterval = 1_709_632_800

    /// Runs git in `folder` with a global configuration inside the test folder, never the user's.
    private func git(_ git: SystemGit, _ arguments: [String], in folder: URL, home: URL) throws {
        let process = Process()
        process.executableURL = git.executable
        process.arguments = arguments
        process.currentDirectoryURL = folder
        process.environment = [
            "PATH": "/usr/bin:/bin",
            "HOME": home.path,
            "GIT_CONFIG_GLOBAL": home.appending(path: "gitconfig").path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_DATE": "\(Int(Self.commitSeconds)) +0000",
            "GIT_COMMITTER_DATE": "\(Int(Self.commitSeconds)) +0000",
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0, "git \(arguments.joined(separator: " ")) failed")
    }

    @Test(.enabled(if: SystemGitTests.available, "git is not installed"))
    func itSeesTrackedFoldersIgnoresIgnoredOnesAndReadsTheCommitDate() async throws {
        let system = try #require(SystemGit())
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            try tmp.file("repo/tracked/dist/a.js", bytes: 10)
            try tmp.file("repo/ignored/dist/b.js", bytes: 10)
            try tmp.file("repo/.gitignore", bytes: 0)
            try "ignored/dist\n".write(to: tmp.path("repo/.gitignore"), atomically: true, encoding: .utf8)
            let repo = tmp.resolved.appending(path: "repo", directoryHint: .isDirectory)

            try git(system, ["init", "-q"], in: repo, home: home)
            try git(system, ["add", "."], in: repo, home: home)
            try git(system, ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "first"], in: repo, home: home)

            let tracked = repo.appending(path: "tracked/dist", directoryHint: .isDirectory)
            let ignored = repo.appending(path: "ignored/dist", directoryHint: .isDirectory)
            let found = try await system.trackedPaths([tracked, ignored], in: repo)
            #expect(found == [tracked])

            let date = try await system.lastCommitDate(touching: repo, in: repo)
            #expect(date == Date(timeIntervalSince1970: Self.commitSeconds))
            let inFolder = try await system.lastCommitDate(touching: tracked, in: repo)
            #expect(inFolder == Date(timeIntervalSince1970: Self.commitSeconds))
        }
    }

    @Test(.enabled(if: SystemGitTests.available, "git is not installed"))
    func aFolderOutsideTheRepositoryIsRefusedAndAMissingRepositoryFails() async throws {
        let system = try #require(SystemGit())
        try await TemporaryDirectory.use { tmp in
            try tmp.directory("plain")
            let plain = tmp.resolved.appending(path: "plain", directoryHint: .isDirectory)
            let elsewhere = tmp.resolved.appending(path: "elsewhere", directoryHint: .isDirectory)

            await #expect(throws: GitError.self) { _ = try await system.trackedPaths([elsewhere], in: plain) }
            await #expect(throws: GitError.self) { _ = try await system.trackedPaths([plain.appending(path: "dist")], in: plain) }
        }
    }
}

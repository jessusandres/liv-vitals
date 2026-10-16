import Foundation
@testable import LivCore

/// A git a test scripts, so no test depends on the git installed on this Mac.
struct FakeGit: GitInspecting {
    /// Paths (resolved) that count as tracked.
    var tracked: Set<String> = []
    /// Last commit per repository path.
    var commits: [String: Date] = [:]
    /// Repositories where every question fails.
    var failing: Set<String> = []

    struct Failure: Error {}

    func trackedPaths(_ paths: [URL], in repository: URL) async throws -> Set<URL> {
        if failing.contains(repository.path) { throw Failure() }
        return Set(paths.filter { tracked.contains($0.path) })
    }

    func lastCommitDate(touching path: URL, in repository: URL) async throws -> Date? {
        if failing.contains(repository.path) { throw Failure() }
        return commits[path.path]
    }
}

extension TemporaryDirectory {
    /// Sets the modification date of a file or folder to `days` days before now.
    func age(_ relative: String, days: Double) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -days * 86_400)],
            ofItemAtPath: path(relative).path
        )
    }
}

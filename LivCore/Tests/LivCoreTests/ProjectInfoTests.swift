import Foundation
import Testing
@testable import LivCore

struct ProjectInfoTests {
    private func match(_ tmp: TemporaryDirectory, artifact: String, root: String = "home/code") -> ArtifactMatch {
        let url = tmp.resolved.appending(path: artifact, directoryHint: .isDirectory)
        return ArtifactMatch(
            kind: "node-modules",
            url: url,
            markerFolder: url.deletingLastPathComponent(),
            root: tmp.resolved.appending(path: root, directoryHint: .isDirectory)
        )
    }

    // MARK: Which project

    @Test func theProjectIsTheRepositoryRootWhenThereIsOne() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.directory("home/code/mono/.git")
            try tmp.file("home/code/mono/services/api/package.json", bytes: 1)
            try tmp.directory("home/code/mono/services/api/node_modules")

            let project = ProjectInspector.project(for: match(tmp, artifact: "home/code/mono/services/api/node_modules"))
            #expect(project.isGitRepository)
            #expect(project.url.path == tmp.resolved.appending(path: "home/code/mono").path)
        }
    }

    @Test func withoutARepositoryTheProjectIsTheFolderWithTheMarker() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("home/code/plain/package.json", bytes: 1)
            try tmp.directory("home/code/plain/node_modules")

            let project = ProjectInspector.project(for: match(tmp, artifact: "home/code/plain/node_modules"))
            #expect(!project.isGitRepository)
            #expect(project.url.path == tmp.resolved.appending(path: "home/code/plain").path)
        }
    }

    @Test func aRepositoryAboveTheSearchedFolderIsNotTheProject() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.directory("home/.git")
            try tmp.file("home/code/plain/package.json", bytes: 1)
            try tmp.directory("home/code/plain/node_modules")

            let project = ProjectInspector.project(for: match(tmp, artifact: "home/code/plain/node_modules"))
            #expect(!project.isGitRepository)
        }
    }

    @Test func gitRepositoryRootSeesAFolderAndAFile() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.directory("home/code/folder/.git")
            try tmp.directory("home/code/folder/a/b")
            try tmp.file("home/code/worktree/.git", bytes: 5)
            try tmp.directory("home/code/worktree/a")
            let root = tmp.resolved.appending(path: "home/code", directoryHint: .isDirectory)

            let first = gitRepositoryRoot(containing: tmp.resolved.appending(path: "home/code/folder/a/b/dist"), stopAt: root)
            let second = gitRepositoryRoot(containing: tmp.resolved.appending(path: "home/code/worktree/a/dist"), stopAt: root)
            let none = gitRepositoryRoot(containing: tmp.resolved.appending(path: "home/code/dist"), stopAt: root)
            #expect(first?.lastPathComponent == "folder")
            #expect(second?.lastPathComponent == "worktree")
            #expect(none == nil)
        }
    }

    // MARK: When it was edited

    @Test func theDateIsTheLaterOfTheLastCommitAndTheNewestFile() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("home/code/app/package.json", bytes: 1)
            try tmp.file("home/code/app/src/main.js", bytes: 1)
            try tmp.age("home/code/app/package.json", days: 40)
            try tmp.age("home/code/app/src/main.js", days: 20)
            let project = tmp.resolved.appending(path: "home/code/app", directoryHint: .isDirectory)

            let older = Date(timeIntervalSinceNow: -30 * 86_400)
            let newer = Date(timeIntervalSinceNow: -5 * 86_400)
            var git = FakeGit(commits: [project.path: older])
            let fromFile = try await ProjectInspector.info(for: project, isGitRepository: true, artifacts: [], git: git)
            #expect(abs(fromFile.lastActivity!.timeIntervalSinceNow + 20 * 86_400) < 5)

            git.commits[project.path] = newer
            let fromCommit = try await ProjectInspector.info(for: project, isGitRepository: true, artifacts: [], git: git)
            #expect(fromCommit.lastActivity == newer)
            #expect(fromCommit.isGitRepository)
        }
    }

    @Test func withoutGitOrWhenGitFailsTheFilesAloneGiveTheDate() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("home/code/app/package.json", bytes: 1)
            try tmp.age("home/code/app/package.json", days: 12)
            let project = tmp.resolved.appending(path: "home/code/app", directoryHint: .isDirectory)

            let withoutGit = try await ProjectInspector.info(for: project, isGitRepository: true, artifacts: [], git: nil)
            let failing = try await ProjectInspector.info(
                for: project, isGitRepository: true, artifacts: [], git: FakeGit(failing: [project.path])
            )
            #expect(abs(withoutGit.lastActivity!.timeIntervalSinceNow + 12 * 86_400) < 5)
            #expect(failing.lastActivity == withoutGit.lastActivity)
        }
    }

    @Test func filesInsideArtifactsAndGitDoNotCountAsEdits() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("home/code/app/package.json", bytes: 1)
            try tmp.age("home/code/app/package.json", days: 30)
            // Installed just now, which is not an edit of the project.
            try tmp.file("home/code/app/node_modules/dep/index.js", bytes: 1)
            try tmp.file("home/code/app/dist/bundle.js", bytes: 1)
            try tmp.file("home/code/app/.git/index", bytes: 1)
            try tmp.file("home/code/app/.DS_Store", bytes: 1)
            let project = tmp.resolved.appending(path: "home/code/app", directoryHint: .isDirectory)
            let artifacts = [project.appending(path: "dist", directoryHint: .isDirectory)]

            let info = try await ProjectInspector.info(for: project, isGitRepository: false, artifacts: artifacts, git: nil)
            #expect(abs(info.lastActivity!.timeIntervalSinceNow + 30 * 86_400) < 5)
        }
    }

    @Test func aProjectWithNothingToReadHasNoDate() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.directory("home/code/empty")
            let project = tmp.resolved.appending(path: "home/code/empty", directoryHint: .isDirectory)

            let info = try await ProjectInspector.info(for: project, isGitRepository: false, artifacts: [], git: nil)
            #expect(info.lastActivity == nil)
        }
    }

    @Test func theEntryLimitStopsTheReadingAndUsesWhatWasSeen() async throws {
        try await TemporaryDirectory.use { tmp in
            for index in 1...3 { try tmp.file("home/code/big/old\(index).txt", bytes: 1) }
            for index in 1...3 { try tmp.age("home/code/big/old\(index).txt", days: 50) }
            // Below the limit's reach: the folder holds four entries and the limit is three.
            try tmp.file("home/code/big/sub/new.txt", bytes: 1)
            let project = tmp.resolved.appending(path: "home/code/big", directoryHint: .isDirectory)

            let limited = try await ProjectInspector.info(for: project, isGitRepository: false, artifacts: [], git: nil, entryLimit: 3)
            let unlimited = try await ProjectInspector.info(for: project, isGitRepository: false, artifacts: [], git: nil)
            #expect(abs(limited.lastActivity!.timeIntervalSinceNow + 50 * 86_400) < 5)
            #expect(abs(unlimited.lastActivity!.timeIntervalSinceNow) < 60)
        }
    }
}

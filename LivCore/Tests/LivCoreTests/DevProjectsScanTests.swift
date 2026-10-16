import Foundation
import Testing
@testable import LivCore

struct DevProjectsScanTests {
    private struct World {
        let tmp: TemporaryDirectory
        let home: URL
        let code: URL

        init(_ tmp: TemporaryDirectory) throws {
            self.tmp = tmp
            home = try tmp.directory("home")
            code = try tmp.directory("home/code")
        }

        /// A project with `package.json` and an installed `node_modules`, last edited `days` days ago.
        @discardableResult
        func nodeProject(_ name: String, days: Double = 30, git: Bool = false) throws -> URL {
            try tmp.file("home/code/\(name)/package.json", bytes: 100)
            try tmp.file("home/code/\(name)/node_modules/dep/index.js", bytes: 20_000)
            if git { try tmp.directory("home/code/\(name)/.git") }
            try tmp.age("home/code/\(name)/package.json", days: days)
            return tmp.resolved.appending(path: "home/code/\(name)", directoryHint: .isDirectory)
        }

        func scan(
            git: (any GitInspecting)? = FakeGit(),
            skipRecent: Bool = true,
            whitelist: [URL] = []
        ) async throws -> ScanResult {
            let guardian = SafetyGuard(home: home, allowedRoots: [code], whitelist: whitelist)
            return try await DevProjectsScan(roots: [code], guard: guardian, git: git, skipRecentProjects: skipRecent).run()
        }
    }

    private func item(_ result: ScanResult, _ suffix: String) throws -> CleanupItem {
        try #require(result.items.first { $0.url.path.hasSuffix(suffix) }, "no item ending in \(suffix)")
    }

    // MARK: Basics

    @Test func anOldProjectOffersItsArtifactCheckedWithTheRebuildHint() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let project = try world.nodeProject("old")

            let result = try await world.scan()
            let found = try item(result, "old/node_modules")
            #expect(result.items.count == 1)
            #expect(found.category == .projectArtifacts)
            #expect(found.ruleID == "node-modules")
            #expect(found.group == project)
            #expect(found.isSelectedByDefault)
            #expect(found.note == ArtifactKind.builtIn[0].rebuildHint)
            #expect(found.size.bytes >= 20_000)
            #expect(abs(found.lastModified!.timeIntervalSinceNow + 30 * 86_400) < 5)
            #expect(found.url.hasDirectoryPath)
        }
    }

    @Test func anEmptyArtifactIsNotShown() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/empty/package.json", bytes: 10)
            try tmp.directory("home/code/empty/node_modules")
            try tmp.age("home/code/empty/package.json", days: 30)

            #expect(try await world.scan().items.isEmpty)
        }
    }

    @Test func rootsThatCannotBeUsedComeBackAsIssues() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let missing = tmp.path("home/Projects")
            let guardian = SafetyGuard(home: world.home, allowedRoots: [world.code])

            let result = try await DevProjectsScan(roots: [missing, world.code], guard: guardian, git: FakeGit()).run()
            #expect(result.items.isEmpty)
            #expect(result.issues.map(\.url) == [missing])
        }
    }

    // MARK: Git

    @Test func whatGitTracksIsNotOffered() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let project = try world.nodeProject("repo", git: true)
            try tmp.file("home/code/repo/dist/bundle.js", bytes: 20_000)
            // Tracked files are part of the project, so their date counts like any other file's.
            try tmp.age("home/code/repo/dist/bundle.js", days: 30)
            let tracked = project.appending(path: "dist").path

            let result = try await world.scan(git: FakeGit(tracked: [tracked]))
            #expect(result.items.map(\.url.lastPathComponent) == ["node_modules"])
            #expect(try item(result, "repo/node_modules").isSelectedByDefault)
        }
    }

    @Test func aFailingGitLeavesTheRepositoryUncheckedWithANote() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let project = try world.nodeProject("repo", git: true)
            try world.nodeProject("plain")

            let result = try await world.scan(git: FakeGit(failing: [project.path]))
            let repo = try item(result, "repo/node_modules")
            #expect(!repo.isSelectedByDefault)
            #expect(repo.note == DevProjectsScan.gitFailedNote)
            // A project outside any repository has nothing to rule out.
            #expect(try item(result, "plain/node_modules").isSelectedByDefault)
        }
    }

    @Test func withoutGitARepositoryIsUncheckedWithANoteAndAPlainFolderIsNot() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try world.nodeProject("repo", git: true)
            try world.nodeProject("plain")

            let result = try await world.scan(git: nil)
            let repo = try item(result, "repo/node_modules")
            #expect(!repo.isSelectedByDefault)
            #expect(repo.note == DevProjectsScan.gitMissingNote)
            #expect(try item(result, "plain/node_modules").isSelectedByDefault)
        }
    }

    // MARK: Recent projects

    @Test func aRecentProjectIsUncheckedWhenTheSettingIsOnAndCheckedWhenItIsOff() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try world.nodeProject("fresh", days: 2)

            let skipping = try item(try await world.scan(skipRecent: true), "fresh/node_modules")
            #expect(!skipping.isSelectedByDefault)
            #expect(skipping.note == "Project edited 2 days ago.")

            let notSkipping = try item(try await world.scan(skipRecent: false), "fresh/node_modules")
            #expect(notSkipping.isSelectedByDefault)
        }
    }

    @Test func aRecentCommitCountsEvenWhenTheFilesAreOld() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let project = try world.nodeProject("repo", days: 90, git: true)
            let commit = Date(timeIntervalSinceNow: -86_400)

            let result = try await world.scan(git: FakeGit(commits: [project.path: commit]))
            let found = try item(result, "repo/node_modules")
            #expect(!found.isSelectedByDefault)
            #expect(found.note == "Project edited 1 day ago.")
            #expect(found.lastModified == commit)
        }
    }

    // MARK: Catalog and sizes

    @Test func aKindThatStartsUncheckedStaysUnchecked() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/py/requirements.txt", bytes: 10)
            try tmp.file("home/code/py/.venv/pyvenv.cfg", bytes: 50)
            try tmp.file("home/code/py/.venv/lib/a.py", bytes: 20_000)
            try tmp.age("home/code/py/requirements.txt", days: 60)

            let found = try item(try await world.scan(), "py/.venv")
            #expect(!found.isSelectedByDefault)
            #expect(found.note == ArtifactKind.builtIn.first { $0.id == "python-venv" }?.rebuildHint)
        }
    }

    @Test func anArtifactMostlySharedWithFilesOutsideItIsUncheckedWithTheSharedNote() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let store = try tmp.file("store/data.bin", bytes: 200_000)
            try tmp.file("home/code/pnpm/package.json", bytes: 10)
            try tmp.hardLink("home/code/pnpm/node_modules/data.bin", to: store)
            try tmp.age("home/code/pnpm/package.json", days: 60)

            let found = try item(try await world.scan(), "pnpm/node_modules")
            #expect(!found.isSelectedByDefault)
            #expect(found.note == CleanupItem.sharedSpaceNote)
        }
    }

    @Test func itemsOfOneProjectShareItsGroupAndTheResultGroupsByProject() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let big = try world.nodeProject("big")
            try tmp.file("home/code/big/dist/out.js", bytes: 60_000)
            let small = try world.nodeProject("small")

            let result = try await world.scan()
            #expect(result.items.count == 3)
            let groups = result.projectGroups
            #expect(groups.map(\.project) == [big, small])
            #expect(groups[0].items.count == 2)
            #expect(groups[0].items.first!.size >= groups[0].items.last!.size)
        }
    }

    @Test func aWhitelistedProjectIsNotOffered() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try world.nodeProject("secret")
            try world.nodeProject("open")

            let result = try await world.scan(whitelist: [tmp.path("home/code/secret")])
            #expect(result.items.map { $0.group!.lastPathComponent } == ["open"])
        }
    }
}

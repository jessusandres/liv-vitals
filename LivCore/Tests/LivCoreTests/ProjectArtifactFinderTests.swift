import Darwin
import Foundation
import Testing
@testable import LivCore

struct ProjectArtifactFinderTests {
    /// A fake home with a `code` folder as the only project root, and a finder built the way the scan builds it.
    private struct World {
        let home: URL
        let code: URL

        init(_ tmp: TemporaryDirectory) throws {
            home = try tmp.directory("home")
            code = try tmp.directory("home/code")
        }

        func finder(
            roots: [URL]? = nil,
            whitelist: [URL] = [],
            maxDepth: Int = 6,
            kinds: [ArtifactKind] = ArtifactKind.builtIn
        ) -> ProjectArtifactFinder {
            let used = roots ?? [code]
            let guardian = SafetyGuard(home: home, allowedRoots: used, whitelist: whitelist)
            return ProjectArtifactFinder(roots: used, guard: guardian, kinds: kinds, maxDepth: maxDepth)
        }

        /// Matches as `kind:path/below/code`, sorted.
        func summary(_ matches: [ArtifactMatch]) -> [String] {
            let base = code.resolvingSymlinksInPath().path + "/"
            return matches.map { "\($0.kind):\($0.url.path.dropFirst(base.count))" }.sorted()
        }
    }

    // MARK: Markers

    @Test func aNodeModulesFolderNextToPackageJsonIsAnArtifact() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/app/package.json", bytes: 10)
            try tmp.file("home/code/app/node_modules/dep/index.js", bytes: 10)
            try tmp.file("home/code/other/node_modules/dep/index.js", bytes: 10)

            let found = try world.finder().find()
            #expect(world.summary(found.matches) == ["node-modules:app/node_modules"])
            #expect(found.matches[0].url.hasDirectoryPath)
            #expect(found.matches[0].markerFolder.lastPathComponent == "app")
        }
    }

    @Test func aLooseDistFolderWithoutAMarkerIsNotAnArtifact() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            // The `bootstrap/dist` case: the marker is a level above, not next to the folder.
            try tmp.file("home/code/nexum/package.json", bytes: 10)
            try tmp.file("home/code/nexum/lambdas/ws/bootstrap/dist/index.js", bytes: 10)
            try tmp.file("home/code/nexum/lambdas/ws/package.json", bytes: 10)
            try tmp.file("home/code/nexum/lambdas/ws/dist/index.js", bytes: 10)

            let found = try world.finder().find()
            #expect(world.summary(found.matches) == ["js-dist:nexum/lambdas/ws/dist"])
        }
    }

    @Test func targetTakesItsKindFromTheMarkerNextToIt() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/rust/Cargo.toml", bytes: 10)
            try tmp.file("home/code/rust/target/debug/a", bytes: 10)
            try tmp.file("home/code/java/pom.xml", bytes: 10)
            try tmp.file("home/code/java/target/classes/a", bytes: 10)

            let found = try world.finder().find()
            #expect(world.summary(found.matches) == ["cargo-target:rust/target", "maven-target:java/target"])
        }
    }

    @Test func buildNextToAnXcodeprojIsFoundThroughTheGlob() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.directory("home/code/mac/Mac.xcodeproj")
            try tmp.file("home/code/mac/build/Release/app", bytes: 10)
            try tmp.file("home/code/lonely/build/out", bytes: 10)

            let found = try world.finder().find()
            #expect(world.summary(found.matches) == ["xcode-build:mac/build"])
        }
    }

    @Test func whenAFolderFitsTwoKindsTheFirstOneInTheCatalogWins() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/both/package.json", bytes: 10)
            try tmp.file("home/code/both/build.gradle", bytes: 10)
            try tmp.file("home/code/both/build/out", bytes: 10)

            let found = try world.finder().find()
            #expect(world.summary(found.matches) == ["js-build:both/build"])
        }
    }

    @Test func pythonEnvironmentsNeedTheirPyvenvCfgWhateverTheyAreCalled() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            // uv project: pyproject.toml + uv.lock and a real environment.
            try tmp.file("home/code/uvapp/pyproject.toml", bytes: 10)
            try tmp.file("home/code/uvapp/uv.lock", bytes: 10)
            try tmp.file("home/code/uvapp/.venv/pyvenv.cfg", bytes: 10)
            // Other names for an environment.
            try tmp.file("home/code/old/requirements.txt", bytes: 10)
            try tmp.file("home/code/old/env/pyvenv.cfg", bytes: 10)
            try tmp.file("home/code/dot/setup.py", bytes: 10)
            try tmp.file("home/code/dot/.env/pyvenv.cfg", bytes: 10)
            // Same names, not environments: no pyvenv.cfg inside, or a plain `.env` file.
            try tmp.file("home/code/notvenv/requirements.txt", bytes: 10)
            try tmp.file("home/code/notvenv/env/settings.txt", bytes: 10)
            try tmp.file("home/code/notvenv/.env", bytes: 10)
            try tmp.file("home/code/hollow/pyproject.toml", bytes: 10)
            try tmp.file("home/code/hollow/.venv/bin/python", bytes: 10)

            let found = try world.finder().find()
            #expect(world.summary(found.matches) == [
                "python-venv:dot/.env", "python-venv:old/env", "python-venv:uvapp/.venv",
            ])
        }
    }

    @Test func anEnvironmentWithOnlyALockfileNextToItIsFound() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/lockonly/poetry.lock", bytes: 10)
            try tmp.file("home/code/lockonly/venv/pyvenv.cfg", bytes: 10)

            #expect(world.summary(try world.finder().find().matches) == ["python-venv:lockonly/venv"])
        }
    }

    // MARK: Where it does not go

    @Test func itDoesNotEnterAnArtifactItFound() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/rust/Cargo.toml", bytes: 10)
            try tmp.file("home/code/rust/target/sub/Cargo.toml", bytes: 10)
            try tmp.file("home/code/rust/target/sub/target/debug/a", bytes: 10)
            try tmp.file("home/code/app/package.json", bytes: 10)
            try tmp.file("home/code/app/node_modules/foo/package.json", bytes: 10)
            try tmp.file("home/code/app/node_modules/foo/node_modules/bar/a.js", bytes: 10)

            let found = try world.finder().find()
            #expect(world.summary(found.matches) == ["cargo-target:rust/target", "node-modules:app/node_modules"])
        }
    }

    @Test func itDoesNotEnterGitSymlinksOrPackages() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/repo/.git/modules/x/package.json", bytes: 10)
            try tmp.file("home/code/repo/.git/modules/x/node_modules/a", bytes: 10)

            let outside = try tmp.directory("outside/project")
            try tmp.file("outside/project/package.json", bytes: 10)
            try tmp.file("outside/project/node_modules/a", bytes: 10)
            try tmp.symlink("home/code/link", to: outside)

            try tmp.file("home/code/Tool.app/Contents/package.json", bytes: 10)
            try tmp.file("home/code/Tool.app/Contents/node_modules/a", bytes: 10)

            let found = try world.finder().find()
            #expect(found.matches.isEmpty)
            #expect(found.issues.isEmpty)
        }
    }

    @Test func maxDepthLimitsHowDeepAnArtifactMayBe() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/a/package.json", bytes: 10)
            try tmp.file("home/code/a/node_modules/x", bytes: 10)
            try tmp.file("home/code/a/b/package.json", bytes: 10)
            try tmp.file("home/code/a/b/node_modules/x", bytes: 10)

            // Counting the artifact itself: a/node_modules is two levels below the root, a/b/node_modules is three.
            #expect(world.summary(try world.finder(maxDepth: 2).find().matches) == ["node-modules:a/node_modules"])
            #expect(world.summary(try world.finder(maxDepth: 3).find().matches) == ["node-modules:a/b/node_modules", "node-modules:a/node_modules"])
        }
    }

    @Test func aWhitelistedFolderIsNotSearched() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/skip/package.json", bytes: 10)
            try tmp.file("home/code/skip/node_modules/a", bytes: 10)
            try tmp.file("home/code/keep/package.json", bytes: 10)
            try tmp.file("home/code/keep/node_modules/a", bytes: 10)
            try tmp.file("home/code/keep/dist/a", bytes: 10)

            let found = try world.finder(whitelist: [tmp.path("home/code/skip"), tmp.path("home/code/keep/dist")]).find()
            #expect(world.summary(found.matches) == ["node-modules:keep/node_modules"])
        }
    }

    // MARK: Roots

    @Test func aMissingRootAndAProtectedRootComeBackAsIssues() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/Documents/proj/package.json", bytes: 10)
            try tmp.file("home/Documents/proj/node_modules/a", bytes: 10)
            try tmp.file("home/code/app/package.json", bytes: 10)
            try tmp.file("home/code/app/node_modules/a", bytes: 10)
            let missing = tmp.path("home/Projects")
            let documents = tmp.path("home/Documents")

            let found = try world.finder(roots: [missing, documents, world.code]).find()
            #expect(world.summary(found.matches) == ["node-modules:app/node_modules"])
            #expect(found.issues.map(\.url) == [missing, documents])
            #expect(found.issues[0].reason == "That folder does not exist.")
            #expect(found.issues[1].reason.hasPrefix("Protected location"))
        }
    }

    @Test func nestedRootsAreSearchedOnce() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/app/package.json", bytes: 10)
            try tmp.file("home/code/app/node_modules/a", bytes: 10)

            let found = try world.finder(roots: [tmp.path("home/code/app"), world.code, world.code]).find()
            #expect(world.summary(found.matches) == ["node-modules:app/node_modules"])
        }
    }

    @Test func anUnreadableFolderIsReportedAndTheRestIsStillSearched() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let locked = try tmp.directory("home/code/locked")
            try tmp.file("home/code/app/package.json", bytes: 10)
            try tmp.file("home/code/app/node_modules/a", bytes: 10)
            #expect(chmod(locked.path, 0o000) == 0)
            defer { chmod(locked.path, 0o755) }

            let found = try world.finder().find()
            #expect(world.summary(found.matches) == ["node-modules:app/node_modules"])
            #expect(found.issues.map(\.url.lastPathComponent) == ["locked"])
        }
    }

    @Test func aCancelledSearchStops() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/code/app/package.json", bytes: 10)
            let finder = world.finder()

            let task = Task { () throws -> Int in
                while !Task.isCancelled { await Task.yield() }
                return try finder.find().matches.count
            }
            task.cancel()
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }
}

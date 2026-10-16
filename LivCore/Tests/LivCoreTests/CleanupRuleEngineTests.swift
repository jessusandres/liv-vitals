import Foundation
import Testing
@testable import LivCore

struct CleanupRuleEngineTests {
    /// A fake home inside the temporary folder, with an engine built the way the app builds it.
    private struct World {
        let home: URL
        let engine: CleanupRuleEngine

        init(_ tmp: TemporaryDirectory, rules: [CleanupRule], fullDiskAccess: Bool = true, whitelist: [URL] = []) throws {
            home = try tmp.directory("home")
            let guardian = SafetyGuard(
                home: home,
                allowedRoots: CleanupRuleEngine.roots(for: rules, home: home),
                whitelist: whitelist
            )
            engine = CleanupRuleEngine(home: home, fullDiskAccess: fullDiskAccess, guard: guardian)
        }

        func relative(_ matches: [RuleMatch]) -> [String] {
            matches.map { String($0.url.path.dropFirst(home.path.count + 1)) }
        }
    }

    private func rule(_ id: String, _ patterns: [String], excluding: [String] = [], minAge: Duration? = nil, fullDiskAccess: Bool = false) -> CleanupRule {
        CleanupRule(id: id, category: .userCaches, patterns: patterns, excluding: excluding, minAge: minAge, requiresFullDiskAccess: fullDiskAccess)
    }

    private func builtIn(_ ids: String...) -> [CleanupRule] {
        ids.compactMap { id in CleanupRule.builtIn.first { $0.id == id } }
    }

    // MARK: Expansion

    @Test func aStarMatchesOneComponentAtTheEndAndInTheMiddle() async throws {
        try await TemporaryDirectory.use { tmp in
            let rules = [
                rule("last", ["Library/Caches/*"]),
                rule("middle", ["Library/Application Support/Google/Chrome/*/Code Cache"]),
            ]
            try tmp.file("home/Library/Caches/com.one/a.bin", bytes: 1)
            try tmp.file("home/Library/Caches/com.two/a.bin", bytes: 1)
            try tmp.directory("home/Library/Application Support/Google/Chrome/Default/Code Cache")
            try tmp.directory("home/Library/Application Support/Google/Chrome/Profile 1/Code Cache")
            try tmp.directory("home/Library/Application Support/Google/Chrome/Profile 2/Other")
            let world = try World(tmp, rules: rules)

            let found = world.engine.matches(for: rules).matches
            #expect(world.relative(found) == [
                "Library/Caches/com.one",
                "Library/Caches/com.two",
                "Library/Application Support/Google/Chrome/Default/Code Cache",
                "Library/Application Support/Google/Chrome/Profile 1/Code Cache",
            ])
            #expect(found.map(\.rule.id) == ["last", "last", "middle", "middle"])
        }
    }

    @Test func matchesCarryADirectoryHintOnlyForFolders() async throws {
        try await TemporaryDirectory.use { tmp in
            let rules = [rule("all", ["Library/Caches/*"])]
            try tmp.file("home/Library/Caches/folder/inner.bin", bytes: 1)
            try tmp.file("home/Library/Caches/loose.bin", bytes: 1)
            let world = try World(tmp, rules: rules)

            let found = world.engine.matches(for: rules).matches
            let byName = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0.url.hasDirectoryPath) })
            #expect(byName == ["folder": true, "loose.bin": false])
        }
    }

    @Test func missingFoldersMatchNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let rules = CleanupRule.builtIn
            let world = try World(tmp, rules: rules)
            let result = world.engine.matches(for: rules)
            #expect(result.matches.isEmpty)
        }
    }

    @Test func symlinksAreNeverFollowed() async throws {
        try await TemporaryDirectory.use { tmp in
            let rules = [rule("deep", ["Library/Caches/Google/Chrome/*/Cache"]), rule("top", ["Library/Caches/*"])]
            let elsewhere = try tmp.directory("elsewhere/Chrome/Default/Cache")
            _ = elsewhere
            // `Chrome` is a link to a folder with the right shape: nothing may be found through it.
            try tmp.symlink("home/Library/Caches/Google/Chrome", to: tmp.path("elsewhere/Chrome"))
            // A link can still be an item on its own, as itself.
            try tmp.symlink("home/Library/Caches/linked", to: tmp.path("elsewhere"))
            let world = try World(tmp, rules: rules)

            let found = world.engine.matches(for: rules).matches
            #expect(!world.relative(found).contains { $0.hasSuffix("Default/Cache") })
            let link = try #require(found.first { $0.url.lastPathComponent == "linked" })
            #expect(!link.url.hasDirectoryPath)
        }
    }

    // MARK: Filters

    @Test func excludingSkipsNamesAndTheXcodeExceptionStillAppears() async throws {
        try await TemporaryDirectory.use { tmp in
            let rules = builtIn("xcode-caches", "user-caches")
            try tmp.file("home/Library/Caches/com.apple.dt.Xcode/a.bin", bytes: 1)
            try tmp.file("home/Library/Caches/com.apple.Safari/a.bin", bytes: 1)
            try tmp.file("home/Library/Caches/COM.APPLE.other/a.bin", bytes: 1)
            try tmp.file("home/Library/Caches/com.spotify.client/a.bin", bytes: 1)
            let world = try World(tmp, rules: rules)

            let found = world.engine.matches(for: rules).matches
            #expect(world.relative(found) == ["Library/Caches/com.apple.dt.Xcode", "Library/Caches/com.spotify.client"])
            #expect(found.map(\.rule.id) == ["xcode-caches", "user-caches"])
        }
    }

    @Test func userCachesDoesNotSwallowAFolderThatHoldsAnotherRulesMatch() async throws {
        try await TemporaryDirectory.use { tmp in
            let rules = builtIn("chrome-cache", "homebrew-cache", "user-caches")
            try tmp.directory("home/Library/Caches/Google/Chrome/Default/Cache")
            try tmp.file("home/Library/Caches/Google/Chrome/Default/Cache/data_0", bytes: 1)
            try tmp.file("home/Library/Caches/Homebrew/downloads/big.dmg", bytes: 1)
            try tmp.file("home/Library/Caches/Homebrew/api/formula.json", bytes: 1)
            try tmp.file("home/Library/Caches/com.example.app/a.bin", bytes: 1)
            let world = try World(tmp, rules: rules)

            let found = world.engine.matches(for: rules).matches
            #expect(world.relative(found) == [
                "Library/Caches/Google/Chrome/Default/Cache",
                "Library/Caches/Homebrew/api",
                "Library/Caches/com.example.app",
            ])
            // Neither `Google` nor `Homebrew` as a whole, and `downloads` is left for Installers.
            #expect(found.map(\.rule.id) == ["chrome-cache", "homebrew-cache", "user-caches"])
        }
    }

    @Test func minAgeKeepsOnlyOldEnoughItems() async throws {
        try await TemporaryDirectory.use { tmp in
            let rules = [rule("old", ["Library/Logs/DiagnosticReports/*"], minAge: .seconds(7 * 86_400))]
            let oldReport = try tmp.file("home/Library/Logs/DiagnosticReports/old.ips", bytes: 1)
            try tmp.file("home/Library/Logs/DiagnosticReports/new.ips", bytes: 1)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -10 * 86_400)], ofItemAtPath: oldReport.path)
            let world = try World(tmp, rules: rules)

            #expect(world.relative(world.engine.matches(for: rules).matches) == ["Library/Logs/DiagnosticReports/old.ips"])
        }
    }

    @Test func protectedAndWhitelistedPathsAreDropped() async throws {
        try await TemporaryDirectory.use { tmp in
            let rules = [rule("library", ["Library/*/*"])]
            try tmp.file("home/Library/Keychains/login.keychain-db", bytes: 1)
            try tmp.file("home/Library/Caches/keep/a.bin", bytes: 1)
            try tmp.file("home/Library/Caches/clean/a.bin", bytes: 1)
            let whitelisted = tmp.path("home/Library/Caches/keep")
            let world = try World(tmp, rules: rules, whitelist: [whitelisted])

            #expect(world.relative(world.engine.matches(for: rules).matches) == ["Library/Caches/clean"])
        }
    }

    // MARK: Full Disk Access

    @Test func withoutFullDiskAccessTheRulesThatNeedItAreSkippedAndTheirFoldersAreNotOpened() async throws {
        try await TemporaryDirectory.use { tmp in
            let protectedRule = rule("trash", ["locked/*"], fullDiskAccess: true)
            let plain = rule("plain", ["Library/Caches/*"])
            try tmp.file("home/locked/secret.bin", bytes: 1)
            try tmp.file("home/Library/Caches/a/a.bin", bytes: 1)
            let locked = tmp.path("home/locked")
            // A folder that cannot be listed: touching it would fail, and on a real Mac would raise a prompt.
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
            let rules = [protectedRule, plain]
            let world = try World(tmp, rules: rules, fullDiskAccess: false)

            let result = world.engine.matches(for: rules)
            #expect(result.skippedRules.map(\.id) == ["trash"])
            #expect(world.relative(result.matches) == ["Library/Caches/a"])

            // With the permission the rule is evaluated, and an unreadable folder just yields nothing.
            let allowed = try World(tmp, rules: rules, fullDiskAccess: true)
            #expect(allowed.engine.matches(for: rules).skippedRules.isEmpty)
        }
    }

    @Test func theBuiltInCatalogNeedsFullDiskAccessOnlyForSafariAndTheTrash() {
        let needing = CleanupRule.builtIn.filter(\.requiresFullDiskAccess).map(\.id)
        #expect(needing == ["safari-cache", "trash"])
    }

    // MARK: Nesting and roots

    @Test func insideOneRuleTheOuterFolderReplacesTheInnerOne() async throws {
        try await TemporaryDirectory.use { tmp in
            // `*/Cache` is listed first so the inner folder is found before the outer one.
            let rules = [rule("nested", ["Library/Caches/*/Cache", "Library/Caches/*"])]
            try tmp.file("home/Library/Caches/app/Cache/f.bin", bytes: 1)
            try tmp.file("home/Library/Caches/other/f.bin", bytes: 1)
            let world = try World(tmp, rules: rules)
            #expect(world.relative(world.engine.matches(for: rules).matches) == ["Library/Caches/app", "Library/Caches/other"])
        }
    }

    @Test func theFirstRuleWinsWhenTwoReachTheSameFolder() async throws {
        try await TemporaryDirectory.use { tmp in
            let rules = [rule("first", ["Library/Caches/shared"]), rule("second", ["Library/Caches/*"])]
            try tmp.file("home/Library/Caches/shared/a.bin", bytes: 1)
            try tmp.file("home/Library/Caches/other/a.bin", bytes: 1)
            let world = try World(tmp, rules: rules)

            let found = world.engine.matches(for: rules).matches
            #expect(found.map(\.rule.id) == ["first", "second"])
            #expect(world.relative(found) == ["Library/Caches/shared", "Library/Caches/other"])
        }
    }

    @Test func rootsAreTheDeepestLiteralFoldersAndNeverTheTargetItself() {
        let home = URL(filePath: "/Users/example")
        let roots = CleanupRuleEngine.roots(
            for: [
                rule("a", ["Library/Caches/*", "Library/Caches/Yarn"]),
                rule("b", ["Library/Application Support/Google/Chrome/*/Code Cache", ".npm/_cacache"]),
                rule("c", ["Library/pnpm/store"]),
            ],
            home: home
        )
        #expect(roots.map { $0.standardizedFileURL.path } == [
            "/Users/example/Library/Caches",
            "/Users/example/Library/Application Support/Google/Chrome",
            "/Users/example/.npm",
            "/Users/example/Library/pnpm",
        ])
    }

    @Test func everyBuiltInRuleHasAnIDAndStaysOutOfTheRiskyPlaces() {
        let ids = CleanupRule.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        for pattern in CleanupRule.builtIn.flatMap(\.patterns) {
            #expect(!pattern.hasPrefix("/") && !pattern.hasPrefix("~"))
            #expect(!pattern.contains("Containers"))
            #expect(!pattern.hasPrefix("Library/Application Support/*"))
            #expect(!pattern.contains("Documents") && !pattern.contains("Desktop"))
        }
        // Specific rules come before `user-caches`, which steps around them.
        let order = ids
        #expect(order.firstIndex(of: "chrome-cache")! < order.firstIndex(of: "user-caches")!)
        #expect(order.firstIndex(of: "xcode-caches")! < order.firstIndex(of: "user-caches")!)
    }
}

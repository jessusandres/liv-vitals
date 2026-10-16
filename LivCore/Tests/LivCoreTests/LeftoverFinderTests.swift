import Foundation
import Testing
@testable import LivCore

struct LeftoverFinderTests {
    /// A fake home and `/Library` inside the test folder, with two installed apps.
    private struct Fixture {
        let tmp: TemporaryDirectory
        let home: URL
        let systemLibrary: URL
        let postman: InstalledApp
        let chrome: InstalledApp
        let canary: InstalledApp

        init(_ tmp: TemporaryDirectory) throws {
            self.tmp = tmp
            home = try tmp.directory("home")
            systemLibrary = try tmp.directory("Library")
            postman = InstalledApp(url: tmp.path("Applications/Postman.app"), bundleID: "com.postmanlabs.mac", name: "Postman", executableName: "Postman")
            chrome = InstalledApp(url: tmp.path("Applications/Google Chrome.app"), bundleID: "com.google.Chrome", name: "Google Chrome")
            canary = InstalledApp(url: tmp.path("Applications/Google Chrome Canary.app"), bundleID: "com.google.Chrome.canary", name: "Google Chrome Canary")
        }

        func find(fullDiskAccess: Bool = false, whitelist: [URL] = [], known: Set<String> = []) -> LeftoverFinder.Result {
            let guardian = SafetyGuard(home: home, allowedRoots: LeftoverFinder.userRoots(home: home), whitelist: whitelist)
            return LeftoverFinder(
                home: home, systemLibrary: systemLibrary, fullDiskAccess: fullDiskAccess,
                installed: [postman, chrome, canary], guard: guardian
            ).find { known.contains($0) }
        }

        func names(_ result: LeftoverFinder.Result, of app: InstalledApp) -> [String] {
            (result.byApp[app.url] ?? []).map { relative($0.url) }.sorted()
        }

        func relative(_ url: URL) -> String {
            let prefix = tmp.url.resolvingSymlinksInPath().path + "/"
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
    }

    @Test func matchesByBundleIDInEveryShape() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            try tmp.directory("home/Library/Caches/com.postmanlabs.mac")
            try tmp.directory("home/Library/Caches/com.postmanlabs.mac.ShipIt")
            try tmp.directory("home/Library/HTTPStorages/com.postmanlabs.mac")
            try tmp.file("home/Library/HTTPStorages/com.postmanlabs.mac.binarycookies")
            try tmp.file("home/Library/Preferences/com.postmanlabs.mac.plist")
            try tmp.file("home/Library/Preferences/ByHost/com.postmanlabs.mac.0A1B2C.plist")
            try tmp.directory("home/Library/Saved Application State/com.postmanlabs.mac.savedState")
            try tmp.file("home/Library/Cookies/com.postmanlabs.mac.binarycookies")
            try tmp.directory("home/Library/WebKit/com.postmanlabs.mac")
            // Not a match: another developer's name that only starts the same.
            try tmp.directory("home/Library/Caches/com.postmanlabs.macfoo")

            let found = fixture.find()
            #expect(fixture.names(found, of: fixture.postman) == [
                "home/Library/Caches/com.postmanlabs.mac",
                "home/Library/Caches/com.postmanlabs.mac.ShipIt",
                "home/Library/Cookies/com.postmanlabs.mac.binarycookies",
                "home/Library/HTTPStorages/com.postmanlabs.mac",
                "home/Library/HTTPStorages/com.postmanlabs.mac.binarycookies",
                "home/Library/Preferences/ByHost/com.postmanlabs.mac.0A1B2C.plist",
                "home/Library/Preferences/com.postmanlabs.mac.plist",
                "home/Library/Saved Application State/com.postmanlabs.mac.savedState",
                "home/Library/WebKit/com.postmanlabs.mac",
            ])
            let folder = try #require(found.byApp[fixture.postman.url]?.first { $0.location == .caches })
            #expect(folder.url.hasDirectoryPath)
        }
    }

    @Test func theMostSpecificInstalledAppWins() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            try tmp.directory("home/Library/Caches/com.google.Chrome")
            try tmp.directory("home/Library/Caches/com.google.Chrome.canary")
            try tmp.directory("home/Library/Caches/com.google.Chrome.helper")

            let found = fixture.find()
            #expect(fixture.names(found, of: fixture.chrome) == ["home/Library/Caches/com.google.Chrome", "home/Library/Caches/com.google.Chrome.helper"])
            #expect(fixture.names(found, of: fixture.canary) == ["home/Library/Caches/com.google.Chrome.canary"])
        }
    }

    @Test func matchesByNameOnlyWhereAppsUseNamesAndWhenTheNameIsUnique() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            try tmp.directory("home/Library/Application Support/Postman")
            try tmp.directory("home/Library/Logs/postman")
            // Preferences are always named by bundle ID.
            try tmp.file("home/Library/Preferences/Postman.plist")

            let found = fixture.find()
            #expect(fixture.names(found, of: fixture.postman) == ["home/Library/Application Support/Postman", "home/Library/Logs/postman"])
        }
    }

    @Test func sharedNamesMatchNobody() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            try tmp.directory("home/Library/Application Support/Electron")
            let first = InstalledApp(url: tmp.path("A.app"), bundleID: "com.a.app", name: "A App", executableName: "Electron")
            let second = InstalledApp(url: tmp.path("B.app"), bundleID: "com.b.app", name: "B App", executableName: "Electron")
            let guardian = SafetyGuard(home: home, allowedRoots: LeftoverFinder.userRoots(home: home))
            let found = LeftoverFinder(home: home, systemLibrary: tmp.path("Library"), fullDiskAccess: false, installed: [first, second], guard: guardian).find()
            #expect(found.byApp.isEmpty)
        }
    }

    @Test func containersAreListedOnlyWithFullDiskAccess() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            try tmp.directory("home/Library/Containers/com.postmanlabs.mac")
            try tmp.directory("home/Library/Group Containers/group.com.postmanlabs.mac")
            try tmp.directory("home/Library/Group Containers/ABCDE12345.com.postmanlabs.mac.shared")

            #expect(fixture.find(fullDiskAccess: false).byApp.isEmpty)
            let found = fixture.find(fullDiskAccess: true)
            #expect(fixture.names(found, of: fixture.postman) == [
                "home/Library/Containers/com.postmanlabs.mac",
                "home/Library/Group Containers/ABCDE12345.com.postmanlabs.mac.shared",
                "home/Library/Group Containers/group.com.postmanlabs.mac",
            ])
            #expect(found.byApp[fixture.postman.url]?.filter(\.location.isShared).count == 2)
        }
    }

    @Test func launchJobsMatchByLabelOrProgramAndSystemOnesNeedAdmin() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            func job(_ relative: String, program: String) throws {
                let data = try PropertyListSerialization.data(fromPropertyList: ["ProgramArguments": [program, "--quiet"]], format: .xml, options: 0)
                try tmp.file(relative)
                try data.write(to: tmp.path(relative))
            }
            try job("home/Library/LaunchAgents/com.postmanlabs.mac.updater.plist", program: "/usr/bin/true")
            try job("home/Library/LaunchAgents/io.vendor.agent.plist", program: fixture.postman.url.path + "/Contents/MacOS/agent")
            try job("Library/LaunchDaemons/com.google.Chrome.helper.plist", program: "/usr/bin/true")
            try tmp.file("Library/PrivilegedHelperTools/com.google.Chrome.priv")

            let found = fixture.find()
            #expect(fixture.names(found, of: fixture.postman) == [
                "home/Library/LaunchAgents/com.postmanlabs.mac.updater.plist",
                "home/Library/LaunchAgents/io.vendor.agent.plist",
            ])
            let system = try #require(found.byApp[fixture.chrome.url])
            #expect(system.count == 2)
            #expect(system.allSatisfy { $0.needsAdmin })
        }
    }

    @Test func whitelistedAndProtectedEntriesAreDropped() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            let kept = try tmp.directory("home/Library/Caches/com.postmanlabs.mac")
            try tmp.file("home/Library/Preferences/com.postmanlabs.mac.plist")
            let found = fixture.find(whitelist: [kept])
            #expect(fixture.names(found, of: fixture.postman) == ["home/Library/Preferences/com.postmanlabs.mac.plist"])
        }
    }

    @Test func orphansAreBundleIDsNobodyKnows() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            try tmp.directory("home/Library/Caches/com.gone.App")
            try tmp.file("home/Library/Preferences/com.gone.App.plist")
            try tmp.directory("home/Library/Caches/com.apple.Something")
            try tmp.directory("home/Library/Caches/Homebrew")
            try tmp.directory("home/Library/Caches/org.known.Tool.helper")
            try tmp.directory("home/Library/Application Scripts/com.gone.Other")
            // Same developer as an installed app: kept, it may be data that app shares.
            try tmp.directory("home/Library/Application Support/com.postmanlabs.shared")

            let found = fixture.find(known: ["org.known.Tool"])
            #expect(found.orphans.map { fixture.relative($0.url) }.sorted() == [
                "home/Library/Caches/com.gone.App",
                "home/Library/Preferences/com.gone.App.plist",
            ])
            #expect(found.orphans.allSatisfy { $0.key == "com.gone.App" })
        }
    }

    @Test func aLaunchAgentWhoseProgramStillExistsIsNoOrphan() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            let program = try tmp.file("home/Library/Vendor/agent")
            for (name, path) in [("com.vendor.live.plist", program.path), ("com.vendor.dead.plist", "/nonexistent/agent")] {
                let data = try PropertyListSerialization.data(fromPropertyList: ["Program": path], format: .xml, options: 0)
                try tmp.file("home/Library/LaunchAgents/\(name)")
                try data.write(to: tmp.path("home/Library/LaunchAgents/\(name)"))
            }
            #expect(fixture.find().orphans.map(\.url.lastPathComponent) == ["com.vendor.dead.plist"])
        }
    }

    @Test func bundleIDShape() {
        #expect(LeftoverFinder.looksLikeBundleID("com.example.App"))
        #expect(LeftoverFinder.looksLikeBundleID("org.swift.swift-pm_cache"))
        #expect(!LeftoverFinder.looksLikeBundleID("Homebrew"))
        #expect(!LeftoverFinder.looksLikeBundleID("com.example"))
        #expect(!LeftoverFinder.looksLikeBundleID("com..example.App"))
        #expect(!LeftoverFinder.looksLikeBundleID("Google Chrome.app.x"))
    }
}

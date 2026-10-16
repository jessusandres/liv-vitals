import Foundation
import Testing
@testable import LivCore

struct PrivilegedRemovalPolicyTests {
    private struct World {
        let tmp: TemporaryDirectory
        let apps: URL
        let library: URL
        let policy: PrivilegedRemovalPolicy

        init(_ tmp: TemporaryDirectory) throws {
            self.tmp = tmp
            apps = try tmp.directory("Applications")
            library = try tmp.directory("Library")
            for folder in ["LaunchDaemons", "LaunchAgents", "PrivilegedHelperTools", "Caches"] {
                try tmp.directory("Library/\(folder)")
            }
            policy = PrivilegedRemovalPolicy(appFolders: [apps], systemLibrary: library)
        }

        func resolved(_ relative: String) -> String {
            tmp.resolved.appending(path: relative).path
        }
    }

    private func refusal(_ policy: PrivilegedRemovalPolicy, _ url: URL) -> SafetyViolation? {
        do {
            _ = try policy.validate(url)
            return nil
        } catch {
            return error
        }
    }

    private func isBlocked(_ violation: SafetyViolation?) -> Bool {
        if case .blocked = violation { return true }
        return false
    }

    private func isOutside(_ violation: SafetyViolation?) -> Bool {
        if case .outsideAllowedRoots = violation { return true }
        return false
    }

    // MARK: Apps

    @Test func anAppDirectlyInAnApplicationsFolderIsAllowed() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let app = try tmp.app("Applications/Tool.app", id: "com.example.tool")
            let allowed = try world.policy.validate(app)
            #expect(allowed.path == world.resolved("Applications/Tool.app"))
        }
    }

    @Test func anAppInAPlainSubfolderIsAllowedButNotDeeperOrInAnUpdaterFolder() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let plain = try tmp.app("Applications/Utilities/Tool.app", id: "com.example.tool")
            let deeper = try tmp.app("Applications/A/B/Tool.app", id: "com.example.deep")
            let updater = try tmp.app("Applications/(A Document Being Saved By Sparkle)/Tool.app", id: "com.example.tmp")
            #expect(refusal(world.policy, plain) == nil)
            #expect(isOutside(refusal(world.policy, deeper)))
            #expect(isOutside(refusal(world.policy, updater)))
        }
    }

    @Test func anAppleAppIsRefusedUnlessItComesFromTheAppStore() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let safari = try tmp.app("Applications/Safari.app", id: "com.apple.Safari")
            let xcode = try tmp.app("Applications/Xcode.app", id: "com.apple.dt.Xcode", appStore: true)
            #expect(isBlocked(refusal(world.policy, safari)))
            #expect(refusal(world.policy, xcode) == nil)
        }
    }

    @Test func aSymlinkIsNeverRemoved() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let real = try tmp.app("Applications/Real.app", id: "com.example.real")
            let link = try tmp.symlink("Applications/Link.app", to: real)
            #expect(isBlocked(refusal(world.policy, link)))

            let launchTarget = try tmp.file("elsewhere/x.plist", bytes: 3)
            let launchLink = try tmp.symlink("Library/LaunchDaemons/link.plist", to: launchTarget)
            #expect(isBlocked(refusal(world.policy, launchLink)))
        }
    }

    @Test func aFolderNamedLikeAnAppButNotAnAppBundleIsRefused() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let fake = try tmp.directory("Applications/Fake.app")
            let file = try tmp.file("Applications/Plain.app", bytes: 10)
            #expect(isBlocked(refusal(world.policy, fake)))
            #expect(isBlocked(refusal(world.policy, file)))
        }
    }

    @Test func theFoldersThemselvesAreRefused() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            for folder in [world.apps, world.library.appending(path: "LaunchDaemons"), world.library.appending(path: "PrivilegedHelperTools")] {
                if case .isAllowedRoot = refusal(world.policy, folder) {} else {
                    Issue.record("\(folder.path) was not refused as a root")
                }
            }
        }
    }

    // MARK: System files

    @Test func aLaunchFileInTheSystemLibraryIsAllowedUnlessItIsApples() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let daemon = try tmp.file("Library/LaunchDaemons/com.example.helper.plist", bytes: 20)
            let agent = try tmp.file("Library/LaunchAgents/com.example.agent.plist", bytes: 20)
            let helper = try tmp.file("Library/PrivilegedHelperTools/com.example.helper", bytes: 20)
            let apple = try tmp.file("Library/LaunchDaemons/com.apple.thing.plist", bytes: 20)
            #expect(try world.policy.validate(daemon).path == world.resolved("Library/LaunchDaemons/com.example.helper.plist"))
            #expect(refusal(world.policy, agent) == nil)
            #expect(refusal(world.policy, helper) == nil)
            #expect(isBlocked(refusal(world.policy, apple)))
        }
    }

    @Test func onlyRegularFilesDirectlyInThoseThreeFoldersAreAllowed() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let folder = try tmp.directory("Library/LaunchDaemons/sub")
            let nested = try tmp.file("Library/LaunchDaemons/sub/x.plist", bytes: 20)
            let elsewhere = try tmp.file("Library/Caches/com.example.cache", bytes: 20)
            #expect(isBlocked(refusal(world.policy, folder)))
            #expect(isOutside(refusal(world.policy, nested)))
            #expect(isOutside(refusal(world.policy, elsewhere)))
            #expect(isOutside(refusal(world.policy, tmp.path("home/Library/LaunchAgents/x.plist"))))
        }
    }

    // MARK: Paths

    @Test func dotDotIsNormalizedBeforeTheCheck() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.app("Applications/Tool.app", id: "com.example.tool")
            try tmp.file("Library/Caches/x", bytes: 5)

            let viaDotDot = world.apps.appending(path: "../Applications/Tool.app")
            #expect(try world.policy.validate(viaDotDot).path == world.resolved("Applications/Tool.app"))
            let escaping = world.apps.appending(path: "../Library/Caches/x")
            #expect(isOutside(refusal(world.policy, escaping)))
            // Something inside a bundle is not an app of its own.
            #expect(isOutside(refusal(world.policy, world.apps.appending(path: "Tool.app/Contents"))))
        }
    }

    @Test func aPathThatIsNotAFileURLIsRefused() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let remote = try #require(URL(string: "https://example.test/Tool.app"))
            if case .notAbsolute = refusal(world.policy, remote) {} else { Issue.record("a web URL was accepted") }
        }
    }

    // MARK: Destinations

    private func destinationRefusal(_ world: World, _ destination: String, from source: URL) -> SafetyViolation? {
        do {
            _ = try world.policy.validateDestination(world.tmp.path(destination), movedFrom: source)
            return nil
        } catch {
            return error
        }
    }

    @Test func destinationsAcceptAnAppAndAServiceFileInTheAllowedFolders() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let app = try tmp.app("home/.Trash/Tool.app", id: "com.example.tool")
            let plist = try tmp.file("home/.Trash/com.example.helper.plist", bytes: 3)
            let utility = try tmp.app("home/.Trash/Other.app", id: "com.example.other")

            #expect(destinationRefusal(world, "Applications/Tool.app", from: app) == nil)
            #expect(destinationRefusal(world, "Applications/Utilities/Other.app", from: utility) == nil)
            for folder in ["LaunchDaemons", "LaunchAgents", "PrivilegedHelperTools"] {
                #expect(destinationRefusal(world, "Library/\(folder)/com.example.helper.plist", from: plist) == nil)
            }
            let accepted = try world.policy.validateDestination(tmp.path("Applications/Tool.app"), movedFrom: app)
            #expect(accepted.path == world.resolved("Applications/Tool.app"))
        }
    }

    @Test func destinationsRefuseAppleNamesAppleBundlesAndOtherPlaces() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let safari = try tmp.app("home/.Trash/Safari.app", id: "com.apple.Safari")
            let xcode = try tmp.app("home/.Trash/Xcode.app", id: "com.apple.dt.Xcode", appStore: true)
            let plist = try tmp.file("home/.Trash/com.apple.thing.plist", bytes: 3)
            let other = try tmp.file("home/.Trash/com.example.helper.plist", bytes: 3)

            #expect(isBlocked(destinationRefusal(world, "Applications/Safari.app", from: safari)))
            #expect(destinationRefusal(world, "Applications/Xcode.app", from: xcode) == nil)
            #expect(isBlocked(destinationRefusal(world, "Library/LaunchDaemons/com.apple.thing.plist", from: plist)))
            // Deeper than the service folder, a folder in the wrong place, and the folders themselves.
            #expect(isOutside(destinationRefusal(world, "Library/LaunchDaemons/sub/com.example.helper.plist", from: other)))
            #expect(isOutside(destinationRefusal(world, "Library/Caches/com.example.helper.plist", from: other)))
            #expect(isOutside(destinationRefusal(world, "Applications/A/B/Safari.app", from: xcode)))
            if case .isAllowedRoot = destinationRefusal(world, "Applications", from: other) {} else { Issue.record("the folder itself was accepted") }
            if case .isAllowedRoot = destinationRefusal(world, "Library/LaunchAgents", from: other) {} else { Issue.record("the folder itself was accepted") }
        }
    }

    @Test func destinationsRefuseASourceThatIsNotARegularAppOrFile() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let folder = try tmp.directory("home/.Trash/NotAnApp.app")
            let link = try tmp.symlink("home/.Trash/link.plist", to: tmp.path("somewhere"))
            let real = try tmp.file("home/.Trash/real.bin")
            #expect(isBlocked(destinationRefusal(world, "Applications/NotAnApp.app", from: folder)))
            #expect(isBlocked(destinationRefusal(world, "Applications/Missing.app", from: tmp.path("home/.Trash/Missing.app"))))
            #expect(isBlocked(destinationRefusal(world, "Library/LaunchDaemons/link.plist", from: link)))
            #expect(isBlocked(destinationRefusal(world, "Applications/real.app", from: real)))
        }
    }
}

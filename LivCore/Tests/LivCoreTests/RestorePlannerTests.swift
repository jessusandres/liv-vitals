import Foundation
import Testing
@testable import LivCore

struct RestorePlannerTests {
    /// A fake home with its own Trash, and fake `Applications` and `Library` folders, all in the temp folder.
    private struct World {
        let tmp: TemporaryDirectory
        let home: URL
        let apps: URL
        let library: URL
        let planner: RestorePlanner

        init(_ tmp: TemporaryDirectory) throws {
            self.tmp = tmp
            home = try tmp.directory("home")
            try tmp.directory("home/.Trash")
            try tmp.directory("home/Library/Caches")
            apps = try tmp.directory("Applications")
            library = try tmp.directory("Library")
            for folder in ["LaunchDaemons", "LaunchAgents", "PrivilegedHelperTools"] {
                try tmp.directory("Library/\(folder)")
            }
            planner = RestorePlanner(home: home, appFolders: [apps], systemLibrary: library)
        }

        func resolved(_ relative: String) -> URL { tmp.resolved.appending(path: relative) }

        func item(_ original: String, trashed: String?, bytes: Int64 = 10) -> HistoryItem {
            HistoryItem(
                originalPath: tmp.path(original).path,
                trashedPath: trashed.map { tmp.path($0).path },
                bytes: bytes
            )
        }
    }

    private func reason(_ step: RestoreStep) -> String? {
        if case .skip(let reason) = step { return reason }
        return nil
    }

    @Test func aFileFromLibraryCachesGoesBackAsTheUser() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/a.bin", bytes: 4)
            let step = world.planner.plan(world.item("home/Library/Caches/a.bin", trashed: "home/.Trash/a.bin"))
            #expect(step == .asUser(
                from: world.resolved("home/.Trash/a.bin"),
                to: world.resolved("home/Library/Caches/a.bin")
            ))
        }
    }

    @Test func anItemDeletedForGoodCannotBePutBack() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let step = world.planner.plan(world.item("home/Library/Caches/a.bin", trashed: nil))
            #expect(reason(step) == "Deleted for good; it cannot be put back.")
        }
    }

    @Test func aPathOutsideTheTrashIsRefused() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/Library/Caches/secret.bin")
            try tmp.file("home/.Trash/sub/deep.bin")
            let elsewhere = world.planner.plan(world.item("home/Library/Caches/copy.bin", trashed: "home/Library/Caches/secret.bin"))
            let dotdot = world.planner.plan(world.item("home/Library/Caches/copy.bin", trashed: "home/.Trash/../Library/Caches/secret.bin"))
            let nested = world.planner.plan(world.item("home/Library/Caches/copy.bin", trashed: "home/.Trash/sub/deep.bin"))
            #expect(reason(elsewhere) == "Not in the Trash.")
            #expect(reason(dotdot) == "Not in the Trash.")
            #expect(reason(nested) == "Not in the Trash.")
        }
    }

    @Test func aLinkInTheTrashIsRefused() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let target = try tmp.file("home/Library/Caches/real.bin")
            try tmp.symlink("home/.Trash/link", to: target)
            let step = world.planner.plan(world.item("home/Library/Caches/link", trashed: "home/.Trash/link"))
            #expect(reason(step) == "Not in the Trash.")
        }
    }

    @Test func anItemTheTrashLostIsSkippedAsUsual() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            let step = world.planner.plan(world.item("home/Library/Caches/gone.bin", trashed: "home/.Trash/gone.bin"))
            #expect(reason(step) == "No longer in the Trash.")
        }
    }

    @Test func nothingIsOverwrittenAndNoFolderIsCreated() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/a.bin")
            try tmp.file("home/Library/Caches/a.bin")
            try tmp.file("home/.Trash/b.bin")
            let taken = world.planner.plan(world.item("home/Library/Caches/a.bin", trashed: "home/.Trash/a.bin"))
            let noFolder = world.planner.plan(world.item("home/Library/Caches/missing/b.bin", trashed: "home/.Trash/b.bin"))
            #expect(reason(taken) == "Something else is at the original location.")
            #expect(reason(noFolder) == "Its folder no longer exists.")
        }
    }

    @Test func aLinkAtTheOriginalLocationCountsAsSomethingThere() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/a.bin")
            try tmp.symlink("home/Library/Caches/a.bin", to: tmp.path("nowhere"))
            let step = world.planner.plan(world.item("home/Library/Caches/a.bin", trashed: "home/.Trash/a.bin"))
            #expect(reason(step) == "Something else is at the original location.")
        }
    }

    @Test func anAppInAnApplicationsFolderTheUserCannotWriteNeedsTheAdministrator() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.app("home/.Trash/Tool.app", id: "com.example.tool")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: world.apps.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: world.apps.path) }

            let step = world.planner.plan(world.item("Applications/Tool.app", trashed: "home/.Trash/Tool.app"))
            #expect(step == .asAdmin(from: world.resolved("home/.Trash/Tool.app"), to: world.resolved("Applications/Tool.app")))
        }
    }

    @Test func anAppTheUserCanWriteGoesBackAsTheUser() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.app("home/.Trash/Tool.app", id: "com.example.tool")
            let step = world.planner.plan(world.item("Applications/Tool.app", trashed: "home/.Trash/Tool.app"))
            #expect(step == .asUser(from: world.resolved("home/.Trash/Tool.app"), to: world.resolved("Applications/Tool.app")))
        }
    }

    @Test func anAppleAppOrServiceIsNotPutBackAsAdministrator() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.app("home/.Trash/Safari.app", id: "com.apple.Safari")
            try tmp.file("home/.Trash/com.apple.thing.plist")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: world.apps.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: world.library.appending(path: "LaunchDaemons").path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: world.apps.path)
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: world.library.appending(path: "LaunchDaemons").path)
            }
            let app = world.planner.plan(world.item("Applications/Safari.app", trashed: "home/.Trash/Safari.app"))
            let service = world.planner.plan(world.item("Library/LaunchDaemons/com.apple.thing.plist", trashed: "home/.Trash/com.apple.thing.plist"))
            #expect(reason(app) == "Apple's own apps are never put back as an administrator.")
            #expect(reason(service) == "Apple's own services are never put back as an administrator.")
        }
    }

    @Test func aServiceFileGoesBackAsAdministratorWhenTheFolderIsNotWritable() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/com.example.helper.plist", bytes: 5)
            let daemons = world.library.appending(path: "LaunchDaemons")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: daemons.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: daemons.path) }

            let step = world.planner.plan(world.item("Library/LaunchDaemons/com.example.helper.plist", trashed: "home/.Trash/com.example.helper.plist"))
            #expect(step == .asAdmin(
                from: world.resolved("home/.Trash/com.example.helper.plist"),
                to: world.resolved("Library/LaunchDaemons/com.example.helper.plist")
            ))
        }
    }

    @Test func aPlaceOutsideEveryAllowedRootIsRefused() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/a.bin")
            try tmp.directory("elsewhere")
            let step = world.planner.plan(world.item("elsewhere/a.bin", trashed: "home/.Trash/a.bin"))
            #expect(reason(step) != nil)
        }
    }

    @Test func theDesktopTakesInstallersOnly() async throws {
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.directory("home/Desktop")
            try tmp.file("home/.Trash/Setup.dmg")
            try tmp.file("home/.Trash/notes.txt")
            let installer = world.planner.plan(world.item("home/Desktop/Setup.dmg", trashed: "home/.Trash/Setup.dmg"))
            let other = world.planner.plan(world.item("home/Desktop/notes.txt", trashed: "home/.Trash/notes.txt"))
            #expect(installer == .asUser(from: world.resolved("home/.Trash/Setup.dmg"), to: world.resolved("home/Desktop/Setup.dmg")))
            #expect(reason(other) != nil)
        }
    }

    @Test func theWhitelistDoesNotStopAnItemFromComingBack() async throws {
        // The planner has no whitelist at all: it guards against removing, and this is the way back.
        try await TemporaryDirectory.use { tmp in
            let world = try World(tmp)
            try tmp.file("home/.Trash/cache.bin")
            try tmp.directory("home/Library/Caches/Kept")
            let step = world.planner.plan(world.item("home/Library/Caches/Kept/cache.bin", trashed: "home/.Trash/cache.bin"))
            #expect(step == .asUser(from: world.resolved("home/.Trash/cache.bin"), to: world.resolved("home/Library/Caches/Kept/cache.bin")))
        }
    }
}

import Foundation
import Testing
@testable import LivCore

struct CleanupPlanTests {
    private func item(_ url: URL, _ bytes: Int64) -> CleanupItem {
        CleanupItem(url: url, category: .userCaches, size: ByteSize(bytes))
    }

    /// A fake home whose `Library/Caches` is the only allowed root.
    private func makeGuard(_ tmp: TemporaryDirectory) throws -> (guardian: SafetyGuard, home: URL, root: URL) {
        let home = try tmp.directory("home")
        let root = try tmp.directory("home/Library/Caches")
        return (SafetyGuard(home: home, allowedRoots: [root]), home, root)
    }

    @Test func splitsAllowedFromBlockedAndSumsOnlyAllowed() async throws {
        try await TemporaryDirectory.use { tmp in
            let (guardian, home, root) = try makeGuard(tmp)
            let plan = CleanupPlanner.plan(
                [
                    item(root.appending(path: "a"), 100),
                    item(home.appending(path: "Library/Keychains/login"), 7),
                    item(root.appending(path: "c"), 30),
                    item(tmp.path("elsewhere/file"), 9),
                ],
                action: .moveToTrash,
                guard: guardian
            )
            #expect(plan.allowed.map(\.item.name) == ["a", "c"])
            #expect(plan.blocked.map(\.item.name) == ["login", "file"])
            #expect(plan.allowedSize == ByteSize(130))
            #expect(plan.operations.allSatisfy { $0.action == .moveToTrash })
            #expect(plan.blocked.compactMap(\.violation).map(\.kind) == ["protected", "outsideAllowedRoots"])
        }
    }

    @Test func itemNestedInsideAnotherPlannedItemIsDropped() async throws {
        try await TemporaryDirectory.use { tmp in
            let (guardian, _, root) = try makeGuard(tmp)
            // The child comes first in the input; the ancestor must still win.
            let plan = CleanupPlanner.plan(
                [item(root.appending(path: "a/b"), 50), item(root.appending(path: "a"), 100)],
                action: .delete,
                guard: guardian
            )
            #expect(plan.operations.map(\.item.name) == ["a"])
            #expect(plan.allowedSize == ByteSize(100))
        }
    }

    @Test func duplicatesCollapseToOne() async throws {
        try await TemporaryDirectory.use { tmp in
            let (guardian, _, root) = try makeGuard(tmp)
            let plan = CleanupPlanner.plan(
                [
                    item(root.appending(path: "c"), 30),
                    item(root.appending(path: "c"), 30),
                    item(root.appending(path: "x/../c"), 30),
                ],
                action: .moveToTrash,
                guard: guardian
            )
            #expect(plan.operations.count == 1)
            #expect(plan.allowedSize == ByteSize(30))
        }
    }

    @Test func blockedFolderDoesNotHideAnAllowedItemInsideIt() async throws {
        try await TemporaryDirectory.use { tmp in
            let (guardian, home, root) = try makeGuard(tmp)
            let plan = CleanupPlanner.plan(
                [item(home.appending(path: "Library"), 1_000), item(root.appending(path: "a"), 10)],
                action: .moveToTrash,
                guard: guardian
            )
            #expect(plan.blocked.map(\.item.name) == ["Library"])
            #expect(plan.allowed.map(\.item.name) == ["a"])
        }
    }

    @Test func theActionCanBeChosenPerItemAndTheOldSignatureStillWorks() async throws {
        try await TemporaryDirectory.use { tmp in
            let (guardian, _, root) = try makeGuard(tmp)
            let inTrash = CleanupItem(url: root.appending(path: "old"), category: .trash, size: ByteSize(5))
            let cache = item(root.appending(path: "cache"), 10)

            let mixed = CleanupPlanner.plan([inTrash, cache], action: { $0.category == .trash ? .delete : .moveToTrash }, guard: guardian)
            #expect(mixed.operations.map(\.action) == [.delete, .moveToTrash])

            let uniform = CleanupPlanner.plan([inTrash, cache], action: .moveToTrash, guard: guardian)
            #expect(uniform.operations.map(\.action) == [.moveToTrash, .moveToTrash])
        }
    }

    @Test func blockedItemsAreNeverAllowed() async throws {
        try await TemporaryDirectory.use { tmp in
            let (guardian, _, root) = try makeGuard(tmp)
            let blocked = CleanupItem(
                url: root.appending(path: "locked"), category: .applications, size: ByteSize(5), blockedReason: "Needs administrator rights."
            )
            let plan = CleanupPlanner.plan([blocked, item(root.appending(path: "free"), 3)], action: .moveToTrash, guard: guardian)
            #expect(plan.allowed.map(\.item.name) == ["free"])
            #expect(plan.blocked.first?.violation?.description == "Needs administrator rights.")
        }
    }
}

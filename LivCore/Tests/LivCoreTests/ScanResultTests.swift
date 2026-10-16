import Foundation
import Testing
@testable import LivCore

struct ScanResultTests {
    private func item(_ path: String, _ category: CleanupCategory, _ bytes: Int64, selected: Bool = true) -> CleanupItem {
        CleanupItem(url: URL(fileURLWithPath: path), category: category, size: ByteSize(bytes), isSelectedByDefault: selected)
    }

    @Test func totalSizeSumsAllItems() {
        let result = ScanResult(items: [
            item("/tmp/a", .logs, 100),
            item("/tmp/b", .userCaches, 250),
        ])
        #expect(result.totalSize == ByteSize(350))
        #expect(ScanResult.empty.totalSize == .zero)
    }

    @Test func groupsAreSortedBySizeDescending() {
        let result = ScanResult(items: [
            item("/tmp/log1", .logs, 10),
            item("/tmp/cache1", .userCaches, 50),
            item("/tmp/cache2", .userCaches, 70),
            item("/tmp/log2", .logs, 20),
        ])
        let groups = result.groups
        #expect(groups.map(\.category) == [.userCaches, .logs])
        #expect(groups[0].size == ByteSize(120))
        #expect(groups[0].items.map(\.name) == ["cache2", "cache1"])
    }

    @Test func defaultSelectionSkipsUnselectedItems() {
        let kept = item("/tmp/recent", .projectArtifacts, 500, selected: false)
        let result = ScanResult(items: [item("/tmp/old", .projectArtifacts, 300), kept])
        #expect(!result.defaultSelection.contains(kept.id))
        #expect(result.size(of: result.defaultSelection) == ByteSize(300))
    }

    @Test func projectGroupsGatherItemsByProjectLargestFirstAndLeaveOutItemsWithoutOne() {
        func artifact(_ path: String, _ bytes: Int64, project: String?) -> CleanupItem {
            CleanupItem(
                url: URL(fileURLWithPath: path), category: .projectArtifacts, size: ByteSize(bytes),
                group: project.map { URL(fileURLWithPath: $0) }
            )
        }
        let result = ScanResult(items: [
            artifact("/p/small/node_modules", 10, project: "/p/small"),
            artifact("/p/big/dist", 30, project: "/p/big"),
            artifact("/p/big/node_modules", 90, project: "/p/big"),
            artifact("/p/tie-b/dist", 10, project: "/p/tie-b"),
            artifact("/tmp/loose", 500, project: nil),
        ])

        let groups = result.projectGroups
        #expect(groups.map(\.project.path) == ["/p/big", "/p/small", "/p/tie-b"])
        #expect(groups[0].size == ByteSize(120))
        #expect(groups[0].items.map(\.name) == ["node_modules", "dist"])
    }

    @Test func byteSizeFormatsLikeFinder() {
        #expect(ByteSize.zero.formatted == "Zero KB")
        #expect(ByteSize.megabytes(5).formatted == "5 MB")
    }
}

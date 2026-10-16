import Foundation
import Testing
@testable import LivCore

struct ScanMergerTests {
    private func item(_ path: String, _ bytes: Int64 = 10) -> CleanupItem {
        CleanupItem(url: URL(filePath: path), category: .userCaches, size: ByteSize(bytes))
    }

    @Test func theSameURLInTwoScansKeepsTheFirst() {
        let merged = ScanMerger.merge([
            ("Cleanup", ScanResult(items: [item("/h/a")])),
            ("Installers", ScanResult(items: [item("/h/a", 99), item("/h/b")])),
        ])
        #expect(merged.map(\.item.url.path) == ["/h/a", "/h/b"])
        #expect(merged.map(\.source) == ["Cleanup", "Installers"])
        #expect(merged[0].item.size == ByteSize(10))
    }

    @Test func aFolderWinsOverWhatIsInsideItEvenFromALaterScan() {
        let merged = ScanMerger.merge([
            ("Cleanup", ScanResult(items: [item("/h/Caches/x/file.bin"), item("/h/other")])),
            ("Dev Projects", ScanResult(items: [item("/h/Caches/x")])),
        ])
        #expect(merged.map(\.item.url.path) == ["/h/other", "/h/Caches/x"])
        #expect(merged.map(\.source) == ["Cleanup", "Dev Projects"])
    }

    @Test func similarNamesAreNotNested() {
        let merged = ScanMerger.merge([
            ("A", ScanResult(items: [item("/h/Cache")])),
            ("B", ScanResult(items: [item("/h/Cache2"), item("/h/cache/inner")])),
        ])
        // "/h/cache/inner" is inside "/h/Cache": paths compare without regard to case.
        #expect(merged.map(\.item.url.path) == ["/h/Cache", "/h/Cache2"])
    }

    @Test func combineAddsUpAccessCountsAndKeepsEveryIssue() {
        let one = ScanIssue(url: URL(filePath: "/h/x"), reason: "First")
        let two = ScanIssue(url: URL(filePath: "/h/y"), reason: "Second")
        let combined = ScanMerger.combine([
            ("A", ScanResult(items: [item("/h/a")], locationsNeedingAccess: 2, issues: [one])),
            ("B", ScanResult(items: [item("/h/a"), item("/h/b")], locationsNeedingAccess: 1, issues: [two])),
        ])
        #expect(combined.items.map(\.url.path) == ["/h/a", "/h/b"])
        #expect(combined.locationsNeedingAccess == 3)
        #expect(combined.issues.map(\.reason) == ["First", "Second"])
    }

    @Test func noScansGiveNothing() {
        #expect(ScanMerger.merge([]).isEmpty)
        #expect(ScanMerger.combine([]).items.isEmpty)
    }
}

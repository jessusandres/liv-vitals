import Darwin
import Foundation
import os
import Testing
@testable import LivCore

/// The `getattrlistbulk` enumeration must give exactly what the `readdir` + `fstatat` one gives.
struct FileScannerBulkTests {
    private func sparseFile(_ url: URL, apparent: Int64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_WRONLY, 0o644)
        defer { close(descriptor) }
        _ = ftruncate(descriptor, off_t(apparent))
        _ = write(descriptor, "x", 1)
    }

    private func buildTree(_ tmp: TemporaryDirectory) throws {
        let outside = try tmp.directory("outside")
        try tmp.file("outside/huge.bin", bytes: 500_000)
        let target = try tmp.file("root/a/target.bin", bytes: 120_000)
        try tmp.file("root/small.txt", bytes: 10)
        try tmp.file("root/empty-file")
        try tmp.file("root/.hidden/secret.bin", bytes: 50_000)
        try tmp.file("root/accénts y espacios/ñandú.txt", bytes: 4_097)
        try tmp.file("root/a/b/c/d/deep.bin", bytes: 8_193)
        try tmp.directory("root/empty")
        try tmp.directory("root/a/b/also-empty")
        try tmp.symlink("root/link-to-file", to: target)
        try tmp.symlink("root/link-to-folder", to: outside)
        try tmp.hardLink("root/a/target-link-1.bin", to: target)
        try tmp.hardLink("root/a/b/target-link-2.bin", to: target)
        let outer = try tmp.file("root/shared.bin", bytes: 60_000)
        try tmp.hardLink("outside/shared-elsewhere.bin", to: outer)
        try sparseFile(tmp.path("root/sparse.bin"), apparent: 50_000_000)
        for index in 0..<700 { try tmp.file("root/wide/file-\(index).dat", bytes: index % 7 * 1_000) }
        let withXattr = try tmp.file("root/xattr.txt", bytes: 100)
        _ = setxattr(withXattr.path, "com.test.attr", "value", 5, 0, 0)
    }

    private func check(_ node: DiskNode, _ other: DiskNode) {
        #expect(node.url == other.url)
        #expect(node.size == other.size)
        #expect(node.ownSize == other.ownSize)
        #expect(node.isDirectory == other.isDirectory)
        #expect(node.isCollapsed == other.isCollapsed)
        #expect(node.children.count == other.children.count)
        let byURL = Dictionary(uniqueKeysWithValues: other.children.map { ($0.url, $0) })
        for child in node.children {
            if let twin = byURL[child.url] { check(child, twin) } else { Issue.record("missing \(child.url.path)") }
        }
    }

    @Test(arguments: [0, 1, 2, 5])
    func bulkTreeMatchesTheLegacyOne(depth: Int) async throws {
        try await TemporaryDirectory.use { tmp in
            try buildTree(tmp)
            let root = tmp.path("root")
            let legacy = try await FileScanner(legacyEnumeration: true).tree(at: root, depth: depth)
            let bulk = try await FileScanner().tree(at: root, depth: depth)
            check(bulk.node, legacy.node)
            #expect(Set(bulk.issues) == Set(legacy.issues))
        }
    }

    @Test func bulkMeasurementMatchesTheLegacyOneIncludingHardLinks() async throws {
        try await TemporaryDirectory.use { tmp in
            try buildTree(tmp)
            let root = tmp.path("root")
            let legacy = try await FileScanner(legacyEnumeration: true).measure(root)
            let bulk = try await FileScanner().measure(root)
            #expect(bulk.size == legacy.size)
            #expect(bulk.fileCount == legacy.fileCount)
            #expect(bulk.sharedSize == legacy.sharedSize)
            #expect(bulk.sharedSize.bytes > 0)
            #expect(bulk.issues == legacy.issues)
        }
    }

    @Test func unreadableSubfolderGivesTheSameIssue() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("root/open/file.bin", bytes: 10_000)
            let locked = try tmp.file("root/locked/secret.bin", bytes: 10_000)
            let folder = locked.deletingLastPathComponent()
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
            let legacy = try await FileScanner(legacyEnumeration: true).measure(tmp.path("root"))
            let bulk = try await FileScanner().measure(tmp.path("root"))
            #expect(bulk.size == legacy.size)
            #expect(bulk.issues == legacy.issues)
            #expect(bulk.issues.count == 1)
        }
    }

    @Test func cancellationStopsInTheMiddleOfAWideFolder() async throws {
        try await TemporaryDirectory.use { tmp in
            let root = try tmp.directory("wide")
            for index in 0..<6_000 { FileManager.default.createFile(atPath: root.appending(path: "file-with-a-longer-name-\(index).dat").path, contents: nil) }

            for legacy in [false, true] {
                let batches = OSAllocatedUnfairLock(initialState: 0)
                let task = Task {
                    try await FileScanner(legacyEnumeration: legacy, batchObserver: { _ in
                        batches.withLock { $0 += 1 }
                        withUnsafeCurrentTask { $0?.cancel() }
                    }).measure(root)
                }
                await #expect(throws: CancellationError.self) { try await task.value }
                #expect(batches.withLock { $0 } == 1)
            }
        }
    }

    @Test func measureAllSettlesSharedSizeForEveryRoot() async throws {
        try await TemporaryDirectory.use { tmp in
            let a = try tmp.file("one/shared.bin", bytes: 40_000)
            try tmp.hardLink("outside/shared-elsewhere.bin", to: a)
            try tmp.file("one/plain.bin", bytes: 1_000)
            let b = try tmp.file("two/inside.bin", bytes: 30_000)
            try tmp.hardLink("two/inside-too.bin", to: b)
            try tmp.file("three/plain.bin", bytes: 5_000)

            let roots = ["one", "two", "three"].map { tmp.path($0) }
            let all = try await FileScanner().measureAll(roots)
            for root in roots {
                let alone = try await FileScanner().measure(root)
                #expect(all[root]?.sharedSize == alone.sharedSize)
                #expect(all[root]?.size == alone.size)
            }
            #expect(all[roots[0]]?.sharedSize.bytes ?? 0 > 0)
            #expect(all[roots[1]]?.sharedSize == .zero)
            #expect(all[roots[2]]?.sharedSize == .zero)
        }
    }

    /// Manual A/B on a real folder: `LIV_SCAN_CORPUS=/Applications/Xcode.app swift test --filter corpus`.
    @Test func corpusEquivalenceAndTiming() async throws {
        guard let path = ProcessInfo.processInfo.environment["LIV_SCAN_CORPUS"] else { return }
        let root = URL(filePath: path)
        let clock = ContinuousClock()
        var legacy: (node: DiskNode, issues: [ScanIssue])?
        var bulk: (node: DiskNode, issues: [ScanIssue])?
        for pass in 1...2 {
            let legacyTime = try await clock.measure { legacy = try await FileScanner(legacyEnumeration: true).tree(at: root, depth: 2) }
            let bulkTime = try await clock.measure { bulk = try await FileScanner().tree(at: root, depth: 2) }
            print("CORPUS pass \(pass): legacy \(legacyTime), bulk \(bulkTime), size \(bulk!.node.size.bytes)")
        }
        #expect(legacy!.node.size == bulk!.node.size)
        check(bulk!.node, legacy!.node)
        #expect(Set(legacy!.issues) == Set(bulk!.issues))
    }
}

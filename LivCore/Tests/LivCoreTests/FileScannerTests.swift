import Darwin
import Foundation
import os
import Testing
@testable import LivCore

struct FileScannerTests {
    /// Allocated bytes according to `/usr/bin/du`, the oracle the scanner must agree with.
    private func duBytes(_ url: URL) throws -> Int64 {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/du")
        process.arguments = ["-s", url.path]
        process.environment = ["BLOCKSIZE": "512"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let blocks = try #require(output.split(whereSeparator: \.isWhitespace).first.flatMap { Int64($0) })
        return blocks * 512
    }

    @Test func measureMatchesDuOnATreeWithHiddenFilesSymlinksAndHardLinks() async throws {
        try await TemporaryDirectory.use { tmp in
            let outside = try tmp.directory("outside")
            try tmp.file("outside/huge.bin", bytes: 2_000_000)
            let target = try tmp.file("root/data/target.bin", bytes: 120_000)
            try tmp.file("root/small.txt", bytes: 10)
            try tmp.file("root/.hidden/secret.bin", bytes: 50_000)
            try tmp.file("root/data/nested/deep/file.bin", bytes: 8_193)
            try tmp.directory("root/empty")
            try tmp.symlink("root/link-to-file", to: target)
            try tmp.symlink("root/link-to-folder", to: outside)
            try tmp.hardLink("root/data/target-hardlink.bin", to: target)

            let measured = try await FileScanner().measure(tmp.path("root"))
            #expect(measured.size.bytes == (try duBytes(tmp.path("root"))))
            #expect(measured.issues.isEmpty)
        }
    }

    @Test func symlinkToFolderDoesNotAddItsTarget() async throws {
        try await TemporaryDirectory.use { tmp in
            let outside = try tmp.directory("outside")
            try tmp.file("outside/huge.bin", bytes: 3_000_000)
            try tmp.symlink("root/link", to: outside)

            let measured = try await FileScanner().measure(tmp.path("root"))
            #expect(measured.size.bytes < 100_000)
            #expect(measured.fileCount == 1)
        }
    }

    @Test func hardLinkInsideATreeCountsOnce() async throws {
        try await TemporaryDirectory.use { tmp in
            let original = try tmp.file("with/a.bin", bytes: 100_000)
            try tmp.file("without/a.bin", bytes: 100_000)
            try tmp.hardLink("with/b.bin", to: original)

            let scanner = FileScanner()
            let with = try await scanner.measure(tmp.path("with"))
            let without = try await scanner.measure(tmp.path("without"))
            #expect(with.size == without.size)
            #expect(with.fileCount == 2)
        }
    }

    @Test func measureAllCountsAHardLinkPairOnce() async throws {
        try await TemporaryDirectory.use { tmp in
            let original = try tmp.file("one/a.bin", bytes: 100_000)
            let link = try tmp.hardLink("two/b.bin", to: original)

            let scanner = FileScanner()
            let single = try await scanner.measure(original)
            let results = try await scanner.measureAll([original, link])
            #expect(results.count == 2)
            #expect(results.values.map(\.size).sum() == single.size)
        }
    }

    @Test func measureAllReportsMissingPathsWithoutFailing() async throws {
        try await TemporaryDirectory.use { tmp in
            let present = try tmp.file("a/file.bin", bytes: 5_000)
            let missing = tmp.path("not-installed")

            let results = try await FileScanner().measureAll([present, missing, present], maxConcurrency: 2)
            #expect(results.count == 2)
            #expect(results[present]?.size.bytes ?? 0 >= 5_000)
            #expect(results[missing]?.size == .zero)
            #expect(results[missing]?.issues.count == 1)
        }
    }

    @Test func measureAllMatchesIndividualMeasurements() async throws {
        try await TemporaryDirectory.use { tmp in
            let folders = try (0..<6).map { index -> URL in
                try tmp.file("f\(index)/a.bin", bytes: 1_000 * (index + 1))
                try tmp.file("f\(index)/sub/b.bin", bytes: 700)
                return tmp.path("f\(index)")
            }
            let scanner = FileScanner()
            let results = try await scanner.measureAll(folders, maxConcurrency: 3)
            for folder in folders {
                #expect(results[folder]?.size == (try await scanner.measure(folder)).size)
            }
        }
    }

    @Test func whitelistedFolderContributesNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            try tmp.file("root/other/a.bin", bytes: 4_000)
            try tmp.file("root/keep/big.bin", bytes: 500_000)
            let guardian = SafetyGuard(home: home, allowedRoots: [tmp.path("root")], whitelist: [tmp.path("root/keep")])

            let plain = FileScanner()
            let guarded = FileScanner(guard: guardian)
            let whole = try await plain.measure(tmp.path("root"))
            let kept = try await plain.measure(tmp.path("root/keep"))
            let skipping = try await guarded.measure(tmp.path("root"))
            #expect(skipping.size.bytes + kept.size.bytes == whole.size.bytes)
            #expect(skipping.fileCount == 1)
        }
    }

    @Test func deniedFolderIsReportedAndTheMeasurementFinishes() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("root/ok.bin", bytes: 4_000)
            try tmp.file("root/locked/hidden.bin", bytes: 4_000)
            let locked = tmp.path("root/locked")
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

            let measured = try await FileScanner().measure(tmp.path("root"))
            #expect(measured.issues.map(\.url.lastPathComponent) == ["locked"])
            #expect(measured.issues.first?.reason == "Permission denied")
            #expect(measured.fileCount == 1)
        }
    }

    @Test func missingRootThrows() async throws {
        try await TemporaryDirectory.use { tmp in
            await #expect(throws: ScanError.self) {
                try await FileScanner().measure(tmp.path("missing"))
            }
        }
    }

    @Test func cancellationStopsTheWalk() async throws {
        try await TemporaryDirectory.use { tmp in
            for folder in 0..<50 {
                for index in 0..<100 { try tmp.file("root/d\(folder)/f\(index)") }
            }
            let root = tmp.path("root")
            let scanner = FileScanner(progressInterval: .zero)
            let task = Task {
                // The first progress report arrives mid-walk; cancel from there.
                try await scanner.measure(root) { _ in withUnsafeCurrentTask { $0?.cancel() } }
            }
            await #expect(throws: CancellationError.self) { try await task.value }
        }
    }

    @Test func progressEndsWithTheFinalFileCount() async throws {
        try await TemporaryDirectory.use { tmp in
            for index in 0..<30 { try tmp.file("root/f\(index).bin", bytes: 100) }
            let seen = OSAllocatedUnfairLock(initialState: [ScanProgress]())

            let measured = try await FileScanner().measure(tmp.path("root")) { update in
                seen.withLock { $0.append(update) }
            }
            let updates = seen.withLock { $0 }
            #expect(!updates.isEmpty)
            #expect(updates.last?.filesVisited == measured.fileCount)
            #expect(updates.last?.bytesCounted == measured.size)
        }
    }

    @Test func progressIsThrottledToTheInterval() async throws {
        try await TemporaryDirectory.use { tmp in
            for folder in 0..<20 {
                for index in 0..<100 { try tmp.file("root/d\(folder)/f\(index)") }
            }
            let seen = OSAllocatedUnfairLock(initialState: 0)

            _ = try await FileScanner(progressInterval: .seconds(600)).measure(tmp.path("root")) { _ in
                seen.withLock { $0 += 1 }
            }
            // One report at the first checkpoint, one final report.
            #expect(seen.withLock { $0 } == 2)
        }
    }

    @Test func treeCollapsesFoldersBelowTheDepthAndKeepsTotals() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("root/top.bin", bytes: 3_000)
            try tmp.file("root/a/a1.bin", bytes: 5_000)
            try tmp.file("root/a/deep/d1.bin", bytes: 7_000)
            try tmp.file("root/a/deep/deeper/d2.bin", bytes: 9_000)
            try tmp.file("root/b/b1.bin", bytes: 2_000)
            let root = tmp.path("root")
            let scanner = FileScanner()
            let whole = try await scanner.measure(root)

            let shallow = try await scanner.tree(at: root, depth: 1)
            #expect(shallow.node.size == whole.size)
            #expect(Set(shallow.node.children.map(\.name)) == ["top.bin", "a", "b"])
            let folderA = try #require(shallow.node.children.first { $0.name == "a" })
            #expect(folderA.isDirectory && folderA.children.isEmpty)
            #expect(folderA.size == (try await scanner.measure(tmp.path("root/a"))).size)

            let flat = try await scanner.tree(at: root, depth: 0)
            #expect(flat.node.children.isEmpty)
            #expect(flat.node.size == whole.size)

            let two = try await scanner.tree(at: root, depth: 2)
            let expandedA = try #require(two.node.children.first { $0.name == "a" })
            #expect(Set(expandedA.children.map(\.name)) == ["a1.bin", "deep"])
            #expect(expandedA.children.first { $0.name == "deep" }?.children.isEmpty == true)
            #expect(two.node.size == whole.size)
        }
    }

    @Test func everyFolderInAFullTreeMatchesItsOwnMeasurement() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("root/x/y/z/file.bin", bytes: 9_000)
            try tmp.file("root/x/other.bin", bytes: 1_000)
            try tmp.directory("root/empty")
            let scanner = FileScanner()

            let full = try await scanner.tree(at: tmp.path("root"), depth: 10)
            var folders = [full.node]
            while let folder = folders.popLast() {
                #expect(folder.size == (try await scanner.measure(folder.url)).size)
                folders += folder.children.filter(\.isDirectory)
            }
        }
    }

    @Test func emptyFolderAtTheDepthLimitIsNotCollapsed() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.directory("root/empty")
            try tmp.file("root/full/a.bin", bytes: 1_000)

            let shallow = try await FileScanner().tree(at: tmp.path("root"), depth: 1)
            let empty = try #require(shallow.node.children.first { $0.name == "empty" })
            let full = try #require(shallow.node.children.first { $0.name == "full" })
            #expect(!empty.isCollapsed)
            #expect(full.isCollapsed)

            // Depth 0 on an empty root is a plain folder too.
            let flat = try await FileScanner().tree(at: tmp.path("root/empty"), depth: 0)
            #expect(!flat.node.isCollapsed)
        }
    }

    // MARK: Shared space

    private func allocated(_ url: URL) -> Int64 {
        var status = stat()
        lstat(url.path, &status)
        return Int64(status.st_blocks) * 512
    }

    @Test func nothingIsSharedWithoutHardLinksOutsideWhatWasMeasured() async throws {
        try await TemporaryDirectory.use { tmp in
            let original = try tmp.file("root/a.bin", bytes: 100_000)
            try tmp.file("root/b.bin", bytes: 50_000)
            // A hard link pair that lives entirely inside the measured folder is not shared with anything else.
            try tmp.hardLink("root/sub/a-link.bin", to: original)

            let measured = try await FileScanner().measure(tmp.path("root"))
            #expect(measured.sharedSize == .zero)
            #expect(measured.size.bytes == (try duBytes(tmp.path("root"))))
        }
    }

    @Test func aFileWithANameOutsideIsReportedAsShared() async throws {
        try await TemporaryDirectory.use { tmp in
            let inside = try tmp.file("root/store/data.bin", bytes: 100_000)
            try tmp.file("root/own.bin", bytes: 20_000)
            try tmp.hardLink("project/node_modules/data.bin", to: inside)

            let scanner = FileScanner()
            let measured = try await scanner.measure(tmp.path("root"))
            #expect(measured.sharedSize.bytes == allocated(inside))
            // `size` is untouched, so the oracle still holds and the file is counted once.
            #expect(measured.size.bytes == (try duBytes(tmp.path("root"))))
            #expect(measured.sharedSize < measured.size)

            let tree = try await scanner.tree(at: tmp.path("root"), depth: 1)
            #expect(tree.node.size == measured.size)
        }
    }

    @Test func measureAllSettlesSharedSpaceAcrossAllTheRoots() async throws {
        try await TemporaryDirectory.use { tmp in
            let first = try tmp.file("one/data.bin", bytes: 100_000)
            // Both names are inside the call: nothing is shared with the outside.
            try tmp.hardLink("two/data-link.bin", to: first)
            let together = try await FileScanner().measureAll([tmp.path("one"), tmp.path("two")])
            #expect(together.values.allSatisfy { $0.sharedSize == .zero })

            // A third name outside: the walk that counted the bytes reports them as shared.
            try tmp.hardLink("elsewhere/data-again.bin", to: first)
            let withOutside = try await FileScanner().measureAll([tmp.path("one"), tmp.path("two")])
            #expect(withOutside.values.map(\.sharedSize.bytes).reduce(0, +) == allocated(first))
        }
    }
}

import Darwin
import Foundation
import os
import Testing
@testable import LivCore

/// `tree` walks with several threads; its result must not depend on them.
struct FileScannerParallelTests {
    /// Small fixed-seed generator, so the random trees are the same on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    /// Nested folders with files of mixed sizes, hard links between sibling and distant folders, a link with a name
    /// outside the root, a symlink, an unreadable folder, empty folders and names with accents and spaces.
    private func randomTree(_ tmp: TemporaryDirectory, seed: UInt64) throws {
        var random = SeededGenerator(state: seed)
        var folders = ["root"]
        var files: [URL] = []
        for index in 0..<60 {
            let parent = folders[Int.random(in: 0..<folders.count, using: &random)]
            let name = index % 9 == 0 ? "carpeta ñ \(index)" : "dir-\(index)"
            folders.append(parent + "/" + name)
            try tmp.directory(parent + "/" + name)
        }
        for index in 0..<400 {
            let folder = folders[Int.random(in: 0..<folders.count, using: &random)]
            files.append(try tmp.file("\(folder)/file-\(index).bin", bytes: Int.random(in: 0...20_000, using: &random)))
        }
        for index in 0..<40 {
            let target = files[Int.random(in: 0..<files.count, using: &random)]
            let folder = folders[Int.random(in: 0..<folders.count, using: &random)]
            try tmp.hardLink("\(folder)/link-\(index).bin", to: target)
        }
        try tmp.hardLink("outside/elsewhere.bin", to: files[0])
        try tmp.symlink("root/link-to-outside", to: tmp.path("outside"))
        try tmp.file("root/locked/secret.bin", bytes: 1_000)
        chmod(tmp.path("root/locked").path, 0o000)
    }

    private func unlock(_ tmp: TemporaryDirectory) {
        chmod(tmp.path("root/locked").path, 0o755)
    }

    @Test(arguments: [0, 1, 2, 4])
    func oneWorkerAndEightGiveTheSameTree(depth: Int) async throws {
        try await TemporaryDirectory.use { tmp in
            try randomTree(tmp, seed: UInt64(depth) + 7)
            defer { unlock(tmp) }
            let root = tmp.path("root")
            let single = try await FileScanner(legacyEnumeration: false, treeWorkers: 1).tree(at: root, depth: depth)
            let many = try await FileScanner(legacyEnumeration: false, treeWorkers: 8).tree(at: root, depth: depth)
            #expect(many.node == single.node)
            #expect(many.issues == single.issues)
            #expect(many.issues.count == 1)

            let legacy = try await FileScanner(legacyEnumeration: true, treeWorkers: 8).tree(at: root, depth: depth)
            #expect(legacy.node == many.node)
        }
    }

    @Test func fiftyRunsGiveTheSameTree() async throws {
        try await TemporaryDirectory.use { tmp in
            try randomTree(tmp, seed: 42)
            defer { unlock(tmp) }
            let scanner = FileScanner(legacyEnumeration: false, treeWorkers: 8)
            let first = try await scanner.tree(at: tmp.path("root"), depth: 2)
            for _ in 0..<49 {
                let again = try await scanner.tree(at: tmp.path("root"), depth: 2)
                #expect(again.node == first.node)
                #expect(again.issues == first.issues)
            }
        }
    }

    @Test func theTotalMatchesTheSequentialMeasurement() async throws {
        try await TemporaryDirectory.use { tmp in
            try randomTree(tmp, seed: 3)
            defer { unlock(tmp) }
            let measured = try await FileScanner().measure(tmp.path("root"))
            for depth in [0, 2] {
                let tree = try await FileScanner().tree(at: tmp.path("root"), depth: depth)
                #expect(tree.node.size == measured.size)
                #expect(Set(tree.issues) == Set(measured.issues))
            }
        }
    }

    @Test func aHardLinkBetweenSiblingsBelongsToTheSmallerPath() async throws {
        try await TemporaryDirectory.use { tmp in
            // Created in "b" first, so neither creation order nor listing order can pick the owner.
            let original = try tmp.file("root/b/data.bin", bytes: 80_000)
            try tmp.hardLink("root/a/deep/data-link.bin", to: original)
            try tmp.file("root/a-b/other.bin", bytes: 1_000)

            for workers in [1, 8] {
                let tree = try await FileScanner(legacyEnumeration: false, treeWorkers: workers).tree(at: tmp.path("root"), depth: 1)
                let a = try #require(tree.node.children.first { $0.name == "a" })
                let b = try #require(tree.node.children.first { $0.name == "b" })
                #expect(a.size.bytes > 80_000)
                #expect(b.size == b.ownSize)
                #expect(tree.node.size == (try await FileScanner().measure(tmp.path("root"))).size)
            }
        }
    }

    @Test func pathsAreOrderedComponentByComponent() {
        #expect(FileScanner.pathPrecedes("/r/a/z", "/r/a-b"))
        #expect(FileScanner.pathPrecedes("/r/a", "/r/a/b"))
        #expect(!FileScanner.pathPrecedes("/r/b", "/r/a/b"))
        #expect(!FileScanner.pathPrecedes("/r/a", "/r/a"))
    }

    @Test func cancellingStopsEveryWorker() async throws {
        try await TemporaryDirectory.use { tmp in
            for folder in 0..<40 {
                let directory = try tmp.directory("wide/folder-\(folder)")
                for index in 0..<200 {
                    FileManager.default.createFile(atPath: directory.appending(path: "file-\(index).dat").path, contents: nil)
                }
            }
            let handle = OSAllocatedUnfairLock<Task<(node: DiskNode, issues: [ScanIssue]), any Error>?>(initialState: nil)
            let batches = OSAllocatedUnfairLock(initialState: 0)
            let scanner = FileScanner(legacyEnumeration: false, batchObserver: { _ in
                batches.withLock { $0 += 1 }
                // The task is stored right after it is created; wait for it rather than miss the cancellation.
                while handle.withLock({ $0 == nil }) { usleep(100) }
                handle.withLock { $0?.cancel() }
            }, treeWorkers: 8)
            let task = Task { try await scanner.tree(at: tmp.path("wide"), depth: 2) }
            handle.withLock { $0 = task }
            await #expect(throws: CancellationError.self) { try await task.value }
            #expect(batches.withLock { $0 } < 41)
        }
    }
}

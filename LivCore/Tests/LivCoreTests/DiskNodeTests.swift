import Foundation
import Testing
@testable import LivCore

struct DiskNodeTests {
    private let root = URL(fileURLWithPath: "/tmp/root")

    private var tree: DiskNode {
        .directory(root, children: [
            .file(root.appending(path: "small.txt"), size: ByteSize(10)),
            .directory(root.appending(path: "media"), children: [
                .file(root.appending(path: "media/movie.mov"), size: ByteSize(700)),
                .file(root.appending(path: "media/song.mp3"), size: ByteSize(90)),
            ]),
        ])
    }

    @Test func directorySizeIsSumOfChildrenSortedLargestFirst() {
        #expect(tree.size == ByteSize(800))
        #expect(tree.children.map(\.name) == ["media", "small.txt"])
    }

    @Test func findsNestedNodes() {
        #expect(tree.node(at: root.appending(path: "media/song.mp3"))?.size == ByteSize(90))
        #expect(tree.node(at: root.appending(path: "missing")) == nil)
    }

    @Test func collapsedDirectoryKeepsItsSizeWithoutChildren() {
        let collapsed = DiskNode.collapsedDirectory(root.appending(path: "big"), size: ByteSize(500))
        #expect(collapsed.isDirectory)
        #expect(collapsed.children.isEmpty)
        #expect(collapsed.size == ByteSize(500))

        let parent = DiskNode.directory(root, children: [collapsed, .file(root.appending(path: "a"), size: ByteSize(5))])
        #expect(parent.size == ByteSize(505))
        // Removing a sibling must not zero the collapsed folder.
        #expect(parent.removing(root.appending(path: "a")).size == ByteSize(500))
    }

    @Test func directoryOwnSizeCountsTowardItsTotalAndSurvivesRemoval() {
        let folder = DiskNode.directory(
            root,
            ownSize: ByteSize(4),
            children: [.file(root.appending(path: "a"), size: ByteSize(10))]
        )
        #expect(folder.size == ByteSize(14))
        #expect(folder.removing(root.appending(path: "a")).size == ByteSize(4))
    }

    @Test func removingNestedNodeRecomputesSizes() {
        let pruned = tree.removing(root.appending(path: "media/movie.mov"))
        #expect(pruned.size == ByteSize(100))
        #expect(pruned.children.map(\.name) == ["media", "small.txt"])
        #expect(pruned.node(at: root.appending(path: "media"))?.size == ByteSize(90))
    }

    @Test func onlyCollapsedDirectoriesAreMarkedCollapsed() {
        #expect(DiskNode.collapsedDirectory(root, size: ByteSize(5)).isCollapsed)
        #expect(!tree.isCollapsed)
        #expect(!DiskNode.directory(root, children: []).isCollapsed)
        // Removing from a tree keeps collapsed folders collapsed.
        let withCollapsed = DiskNode.directory(root, children: [.collapsedDirectory(root.appending(path: "big"), size: ByteSize(9))])
        #expect(withCollapsed.removing(root.appending(path: "none")).node(at: root.appending(path: "big"))?.isCollapsed == true)
    }

    @Test func replacingSwapsTheNodeAndRecomputesAncestorSizes() {
        let big = root.appending(path: "media/big")
        let base = DiskNode.directory(root, children: [
            .directory(root.appending(path: "media"), ownSize: ByteSize(4), children: [
                .collapsedDirectory(big, size: ByteSize(100)),
            ]),
        ])
        let loaded = DiskNode.directory(big, ownSize: ByteSize(10), children: [.file(big.appending(path: "a"), size: ByteSize(90))])

        let result = base.replacing(big, with: loaded)
        #expect(result.node(at: big)?.isCollapsed == false)
        #expect(result.node(at: big)?.children.map(\.name) == ["a"])
        #expect(result.size == base.size)
        #expect(result.node(at: root.appending(path: "media"))?.size == ByteSize(104))

        // A different total flows up to every ancestor.
        let grown = DiskNode.directory(big, ownSize: ByteSize(10), children: [.file(big.appending(path: "a"), size: ByteSize(190))])
        #expect(base.replacing(big, with: grown).size == ByteSize(204))

        // Unknown URL: unchanged.
        #expect(base.replacing(root.appending(path: "missing"), with: loaded) == base)
    }
}

import Foundation

/// A file or folder in a disk usage tree. A folder's size is the sum of its children plus its own size.
public struct DiskNode: Identifiable, Hashable, Sendable {
    public var id: URL { url }

    public let url: URL
    public let isDirectory: Bool
    public let size: ByteSize
    /// The space the folder entry itself takes, on top of its children. Zero for files.
    public let ownSize: ByteSize
    /// True for a folder whose contents were not read, only its total size. See `collapsedDirectory`.
    public let isCollapsed: Bool
    /// Children sorted largest first.
    public let children: [DiskNode]

    public static func file(_ url: URL, size: ByteSize) -> DiskNode {
        DiskNode(url: url, isDirectory: false, size: size, ownSize: .zero, isCollapsed: false, children: [])
    }

    public static func directory(_ url: URL, children: [DiskNode]) -> DiskNode {
        directory(url, ownSize: .zero, children: children)
    }

    /// A folder whose own entry takes `ownSize` bytes, as measured on disk.
    public static func directory(_ url: URL, ownSize: ByteSize, children: [DiskNode]) -> DiskNode {
        DiskNode(
            url: url,
            isDirectory: true,
            size: ownSize + children.map(\.size).sum(),
            ownSize: ownSize,
            isCollapsed: false,
            children: children.sorted { $0.size > $1.size }
        )
    }

    /// A folder shown as one block with its total size, without its contents.
    /// `replacing(_:with:)` swaps it for the real folder once its contents are read.
    public static func collapsedDirectory(_ url: URL, size: ByteSize) -> DiskNode {
        DiskNode(url: url, isDirectory: true, size: size, ownSize: size, isCollapsed: true, children: [])
    }

    private init(url: URL, isDirectory: Bool, size: ByteSize, ownSize: ByteSize, isCollapsed: Bool, children: [DiskNode]) {
        self.url = url
        self.isDirectory = isDirectory
        self.size = size
        self.ownSize = ownSize
        self.isCollapsed = isCollapsed
        self.children = children
    }

    public var name: String { url.lastPathComponent }

    /// The node with the given URL anywhere in this tree.
    public func node(at target: URL) -> DiskNode? {
        if url == target { return self }
        for child in children {
            if let found = child.node(at: target) { return found }
        }
        return nil
    }

    /// A copy of this tree without the node at `target`, with folder sizes recomputed.
    public func removing(_ target: URL) -> DiskNode {
        guard isDirectory, !isCollapsed else { return self }
        let remaining = children.filter { $0.url != target }.map { $0.removing(target) }
        return .directory(url, ownSize: ownSize, children: remaining)
    }

    /// A copy of this tree with the node at `target` swapped for `replacement`, and the sizes of its
    /// ancestors recomputed. Returns the tree unchanged when `target` is not in it.
    public func replacing(_ target: URL, with replacement: DiskNode) -> DiskNode {
        if url == target { return replacement }
        guard isDirectory, !isCollapsed, node(at: target) != nil else { return self }
        return .directory(url, ownSize: ownSize, children: children.map { $0.replacing(target, with: replacement) })
    }
}

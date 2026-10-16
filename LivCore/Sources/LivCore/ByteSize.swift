import Foundation

/// A number of bytes on disk, formatted the way Finder shows file sizes.
public struct ByteSize: Hashable, Comparable, Sendable, Codable {
    public let bytes: Int64

    public init(_ bytes: Int64) {
        precondition(bytes >= 0, "ByteSize cannot be negative")
        self.bytes = bytes
    }

    public static let zero = ByteSize(0)

    public static func kilobytes(_ value: Int64) -> ByteSize { ByteSize(value * 1_000) }
    public static func megabytes(_ value: Int64) -> ByteSize { ByteSize(value * 1_000_000) }
    public static func gigabytes(_ value: Int64) -> ByteSize { ByteSize(value * 1_000_000_000) }

    public var formatted: String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    public static func < (lhs: ByteSize, rhs: ByteSize) -> Bool { lhs.bytes < rhs.bytes }
    public static func + (lhs: ByteSize, rhs: ByteSize) -> ByteSize { ByteSize(lhs.bytes + rhs.bytes) }
}

extension Sequence where Element == ByteSize {
    public func sum() -> ByteSize { reduce(.zero, +) }
}

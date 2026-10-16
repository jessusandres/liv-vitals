import Foundation

/// One finished cleanup, as shown in History.
public struct CleanupRecord: Identifiable, Hashable, Sendable, Codable {
    public let id: UUID
    public let date: Date
    /// The module that ran the cleanup, e.g. "Cleanup" or "Dev Projects".
    public let source: String
    public let itemCount: Int
    public let freed: ByteSize
    public let movedToTrash: Bool

    public init(id: UUID = UUID(), date: Date, source: String, itemCount: Int, freed: ByteSize, movedToTrash: Bool) {
        self.id = id
        self.date = date
        self.source = source
        self.itemCount = itemCount
        self.freed = freed
        self.movedToTrash = movedToTrash
    }
}

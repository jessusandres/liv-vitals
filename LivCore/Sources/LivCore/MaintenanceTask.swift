/// A system maintenance action offered by the Performance module.
public struct MaintenanceTask: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let summary: String
    public let requiresAdmin: Bool
    public let isSelectedByDefault: Bool

    public init(id: String, title: String, summary: String, requiresAdmin: Bool, isSelectedByDefault: Bool = true) {
        self.id = id
        self.title = title
        self.summary = summary
        self.requiresAdmin = requiresAdmin
        self.isSelectedByDefault = isSelectedByDefault
    }
}

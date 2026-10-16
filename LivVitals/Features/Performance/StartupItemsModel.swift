import LivCore
import Observation

/// The startup items grouped by the app they belong to. Nothing here changes them: they are only shown.
@Observable
final class StartupItemsModel {
    /// The items of one app, or of no known app.
    struct Group: Identifiable {
        let owner: InstalledApp?
        let items: [LaunchItem]

        var id: String { owner?.url.path ?? "unknown" }
        var title: String { owner?.name ?? "Unknown" }
    }

    private(set) var items: [LaunchItem]
    private(set) var isLoading = false
    private(set) var hasLoaded: Bool

    @ObservationIgnored private let service: any StartupItemsProviding

    /// - Parameter items: Already-known items, for previews and snapshots.
    init(service: any StartupItemsProviding, items: [LaunchItem] = []) {
        self.service = service
        self.items = items
        hasLoaded = !items.isEmpty
    }

    /// Apps by name, then the items no installed app owns, last.
    var groups: [Group] {
        let byOwner = Dictionary(grouping: items) { $0.owner?.url.path }
        return byOwner
            .map { _, items in Group(owner: items[0].owner, items: items.sorted { $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending }) }
            .sorted { lhs, rhs in
                switch (lhs.owner, rhs.owner) {
                case (nil, nil): false
                case (nil, _): false
                case (_, nil): true
                case (let a?, let b?): a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
                }
            }
    }

    /// Items whose program is gone: usually what an app removed by hand left behind.
    var missingProgramCount: Int { items.filter { !$0.programExists }.count }

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        items = await service.items()
        hasLoaded = true
    }
}

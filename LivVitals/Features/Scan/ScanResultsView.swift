import LivCore
import SwiftUI

struct ScanResultsView: View {
    @Bindable var model: ScanFlowModel
    let permissions: PermissionsModel

    private var module: AppModule { model.module }

    var body: some View {
        VStack(spacing: 18) {
            ModuleHeader(
                module: module,
                subtitle: "\(model.result.totalSize.formatted) found in \(model.result.items.count) items"
            ) {
                HStack(spacing: 10) {
                    if module == .applications {
                        Picker("Sort by", selection: $model.appOrder) {
                            ForEach(ScanFlowModel.AppOrder.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                    }
                    TextField("Search", text: $model.searchText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: module == .applications ? 140 : 180)
                    Button("Start Over", action: model.reset)
                }
            }

            if model.locationsNeedingAccess > 0 { accessNotice }
            if !model.issues.isEmpty { issuesNotice }
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            ScrollView {
                LazyVStack(spacing: 10) {
                    if module == .smartCare { SmartCareHealthCard(health: model.health) }
                    if module == .applications {
                        ForEach(apps, id: \.project) { group in
                            GroupCard(
                                model: model, folder: group.project, items: group.items, size: group.size,
                                title: group.project.deletingPathExtension().lastPathComponent,
                                detail: lastUsedText(group.items),
                                rowTitle: { libraryPath(of: $0) }
                            )
                        }
                        if !orphans.isEmpty {
                            CategoryCard(
                                model: model, category: .appLeftovers, items: orphans, size: orphans.map(\.size).sum(),
                                title: "Leftovers of Removed Apps"
                            )
                        }
                    } else if module == .devProjects {
                        ForEach(projects, id: \.project) { group in
                            GroupCard(
                                model: model, folder: group.project, items: group.items, size: group.size,
                                title: group.project.lastPathComponent,
                                detail: group.items.first?.lastModified.map { "Edited \($0.formatted(.relative(presentation: .named)))" },
                                rowTitle: { relativePath(of: $0, in: group.project) }
                            )
                        }
                        if model.result.items.isEmpty {
                            Text("No build folders or dependencies were found in your project folders.")
                                .foregroundStyle(.secondary)
                                .padding(.top, 24)
                        }
                    } else {
                        ForEach(groups, id: \.category) { group in
                            CategoryCard(model: model, category: group.category, items: group.items, size: group.size)
                        }
                    }
                    if module == .smartCare, !model.maintenanceTasks.isEmpty { SmartCareMaintenanceCard(model: model) }
                    if groups.isEmpty && projects.isEmpty && !model.result.items.isEmpty && !model.searchText.isEmpty {
                        Text("Nothing matches “\(model.searchText)”.")
                            .foregroundStyle(.secondary)
                            .padding(.top, 24)
                    }
                }
                .padding(.bottom, 8)
            }
            .scrollIndicators(.never)

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(selectionTitle)
                        .font(.headline)
                    Text(model.selectionSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CircleActionButton(
                    title: module == .applications ? String(localized: "Uninstall") : module == .smartCare ? String(localized: "Run") : String(localized: "Clean"),
                    subtitle: model.selection.isEmpty ? nil : model.selectedSize.formatted,
                    theme: module.theme,
                    diameter: 96,
                    isEnabled: model.hasWork,
                    action: model.requestClean
                )
            }
            .card(padding: 14)
        }
        .sheet(item: $model.confirmation) { confirmation in
            CleanConfirmationSheet(
                confirmation: confirmation,
                onConfirm: model.confirmClean,
                onCancel: model.cancelConfirmation
            )
        }
    }

    private var selectionTitle: String {
        let items = String(localized: "\(model.selection.count) of \(model.result.items.count) items selected")
        guard module == .smartCare, !model.maintenanceTasks.isEmpty else { return items }
        let tasks = String(localized: "\(model.selectedMaintenance.count) tasks")
        return "\(items) · \(tasks)"
    }

    /// The groups that have items matching the search, with their sizes for what matches.
    private var groups: [(category: CleanupCategory, items: [CleanupItem], size: ByteSize)] {
        model.result.groups.compactMap { group in
            let items = group.items.filter(model.matchesSearch)
            return items.isEmpty ? nil : (group.category, items, items.map(\.size).sum())
        }
    }

    /// The apps that have items matching the search, in the order the user picked.
    private var apps: [(project: URL, items: [CleanupItem], size: ByteSize)] {
        let matching = projects
        switch model.appOrder {
        case .size: return matching
        case .name:
            return matching.sorted { $0.project.lastPathComponent.localizedCaseInsensitiveCompare($1.project.lastPathComponent) == .orderedAscending }
        case .lastUsed:
            // Never-used apps first: they are the likeliest to go.
            return matching.sorted { (appItem(of: $0.items)?.lastModified ?? .distantPast) < (appItem(of: $1.items)?.lastModified ?? .distantPast) }
        }
    }

    /// Leftovers no installed app claims, shown apart from the apps.
    private var orphans: [CleanupItem] {
        model.result.items.filter { $0.group == nil && $0.category == .appLeftovers && model.matchesSearch($0) }.sorted { $0.size > $1.size }
    }

    private func appItem(of items: [CleanupItem]) -> CleanupItem? { items.first { $0.category == .applications } }

    private func lastUsedText(_ items: [CleanupItem]) -> String {
        let app = appItem(of: items)
        let used = app?.lastModified.map { String(localized: "Used \($0.formatted(.relative(presentation: .named)))") } ?? String(localized: "Last use unknown")
        return app?.needsAdmin == true ? String(localized: "Requires admin · \(used)") : used
    }

    /// `Caches/com.example.App` for what is in `~/Library`, the full path for the rest.
    private func libraryPath(of item: CleanupItem) -> String {
        if item.category == .applications { return String(localized: "Application") }
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library").path + "/"
        return item.url.path.hasPrefix(library) ? String(item.url.path.dropFirst(library.count)) : item.url.abbreviatedPath
    }

    /// `node_modules` or `lambdas/ws-connect/dist`: where the item sits inside its project.
    private func relativePath(of item: CleanupItem, in project: URL) -> String {
        let prefix = project.path + "/"
        return item.url.path.hasPrefix(prefix) ? String(item.url.path.dropFirst(prefix.count)) : item.name
    }

    /// The projects that have items matching the search, with their sizes for what matches.
    private var projects: [(project: URL, items: [CleanupItem], size: ByteSize)] {
        model.result.projectGroups.compactMap { group in
            let items = group.items.filter(model.matchesSearch)
            return items.isEmpty ? nil : (group.project, items, items.map(\.size).sum())
        }
    }

    /// Folders the scan could not use, e.g. a project folder that no longer exists.
    private var issuesNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(model.issues, id: \.self) { issue in
                Label("\(issue.url.abbreviatedPath): \(issue.reason)", systemImage: "exclamationmark.circle")
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 10)
    }

    /// Locations macOS keeps behind Full Disk Access are not even opened without it.
    private var accessNotice: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill").foregroundStyle(.secondary)
            let count = model.locationsNeedingAccess
            Text("\(count) locations need Full Disk Access, so they were not scanned.")
            Spacer()
            Button("Open System Settings", action: permissions.openSettings)
        }
        .font(.callout)
        .card(padding: 10)
    }
}

/// Asks before anything is moved or deleted, with the numbers the user is agreeing to.
struct CleanConfirmationSheet: View {
    let confirmation: CleanConfirmation
    let onConfirm: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: confirmation.isPermanent ? "exclamationmark.triangle.fill" : "trash.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(confirmation.isPermanent ? Color.orange : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.title2.bold())
                    if confirmation.itemCount > 0 {
                        Text("\(confirmation.itemCount) items · \(confirmation.totalSize.formatted)")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                if confirmation.itemCount == 0 {
                    // Maintenance only: nothing is moved.
                } else if confirmation.isDryRun {
                    Label("Nothing will be moved or deleted. What would happen is written to the log.", systemImage: "eye")
                } else {
                    if confirmation.trashCount > 0 {
                        Label("\(confirmation.trashCount) items (\(confirmation.trashSize.formatted)) move to the Trash.", systemImage: "trash")
                    }
                    if confirmation.permanentCount > 0 {
                        Label("\(confirmation.permanentCount) items (\(confirmation.permanentSize.formatted)) are deleted permanently and cannot be recovered.", systemImage: "xmark.bin")
                            .foregroundStyle(.orange)
                    }
                }
                if confirmation.maintenanceCount > 0 {
                    Label(
                        confirmation.itemCount > 0
                            ? String(localized: "\(confirmation.maintenanceCount) maintenance tasks run after the cleaning.")
                            : String(localized: "\(confirmation.maintenanceCount) maintenance tasks run."),
                        systemImage: "wrench.and.screwdriver"
                    )
                }
                if confirmation.maintenanceAdminCount > 0, !confirmation.isDryRun {
                    Label(
                        "\(confirmation.maintenanceAdminCount) of them need your administrator password, asked once.",
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.orange)
                }
                if !confirmation.appsToQuit.isEmpty {
                    let names = confirmation.appsToQuit.formatted(.list(type: .and))
                    Label(
                        confirmation.quitsAppsAutomatically ? "\(names) will be quit first." : "Quit \(names) first, or their items may fail.",
                        systemImage: "app.badge"
                    )
                    .foregroundStyle(.secondary)
                }
                if confirmation.adminCount > 0, !confirmation.isDryRun {
                    Label(
                        "\(confirmation.adminCount) items need your administrator password, asked once.",
                        systemImage: "lock.shield"
                    )
                    .foregroundStyle(.orange)
                }
                if !confirmation.servicesToStop.isEmpty, !confirmation.isDryRun {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("These services are stopped first:", systemImage: "stop.circle")
                        ForEach(confirmation.servicesToStop, id: \.self) { label in
                            Text(label).font(.caption.monospaced()).foregroundStyle(.secondary).padding(.leading, 24)
                        }
                    }
                    .foregroundStyle(.secondary)
                }
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel, action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, role: confirmation.isPermanent ? .destructive : nil, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 460)
    }

    private var title: String {
        if confirmation.itemCount == 0 { return confirmation.isDryRun ? String(localized: "Simulate maintenance?") : String(localized: "Run maintenance?") }
        if confirmation.isDryRun { return String(localized: "Simulate cleaning?") }
        return confirmation.isPermanent ? String(localized: "Delete permanently?") : String(localized: "Move to Trash?")
    }

    private var confirmTitle: String {
        if confirmation.isDryRun { return String(localized: "Simulate") }
        if confirmation.itemCount == 0 { return String(localized: "Run") }
        return confirmation.isPermanent ? String(localized: "Delete Permanently") : String(localized: "Move to Trash")
    }
}

private struct CategoryCard: View {
    /// Long categories show this many items until the user asks for the rest.
    private static let visibleLimit = 50

    let model: ScanFlowModel
    let category: CleanupCategory
    let items: [CleanupItem]
    let size: ByteSize
    let title: String

    @State private var isExpanded = false
    @State private var showsAll = false

    init(model: ScanFlowModel, category: CleanupCategory, items: [CleanupItem], size: ByteSize, title: String? = nil) {
        self.model = model
        self.category = category
        self.items = items
        self.size = size
        self.title = title ?? category.localizedTitle
    }

    private var visibleItems: [CleanupItem] {
        showsAll || items.count <= Self.visibleLimit ? items : Array(items.prefix(Self.visibleLimit))
    }

    private func toggleExpanded() {
        withMotion(.spring(duration: 0.3)) { isExpanded.toggle() }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                CheckBox(state: model.checkState(of: items), tint: category.color, label: title) { model.toggleAll(items) }
                Image(systemName: category.systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(category.color.gradient, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text("\(items.count) items")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(size.formatted)
                    .font(.headline.monospacedDigit())
                ExpandChevron(title: title, isExpanded: isExpanded) { toggleExpanded() }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if isExpanded || !model.searchText.isEmpty {
                VStack(spacing: 0) {
                    ForEach(visibleItems) { item in
                        Divider().padding(.leading, 44)
                        ItemRow(item: item, isSelected: model.selection.contains(item.id), tint: category.color) {
                            model.toggle(item)
                        }
                    }
                    if visibleItems.count < items.count {
                        Button("Show all (\(items.count))") { withMotion { showsAll = true } }
                            .buttonStyle(.link)
                            .padding(.top, 10)
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card(padding: 14)
    }
}

/// One project of Dev Projects or one app of the Uninstaller: its items together, so the whole group is
/// checked or left alone at once.
private struct GroupCard: View {
    let model: ScanFlowModel
    let folder: URL
    let items: [CleanupItem]
    let size: ByteSize
    let title: String
    let detail: String?
    let rowTitle: (CleanupItem) -> String

    @State private var isExpanded = false

    private var tint: Color { (items.first?.category ?? .projectArtifacts).color }
    private var isBlocked: Bool { items.allSatisfy(\.isBlocked) }

    private func toggleExpanded() {
        withMotion(.spring(duration: 0.3)) { isExpanded.toggle() }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if isBlocked {
                    LockBadge(reason: items.first?.blockedReason)
                } else {
                    CheckBox(state: model.checkState(of: items), tint: tint, label: title) { model.toggleAll(items) }
                }
                SystemIcon(url: folder, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    HStack(spacing: 6) {
                        Text(folder.abbreviatedPath)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if let detail {
                            Text("· \(detail)").layoutPriority(1)
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Text(size.formatted)
                    .font(.headline.monospacedDigit())
                ExpandChevron(title: title, isExpanded: isExpanded) { toggleExpanded() }
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if isExpanded || !model.searchText.isEmpty {
                VStack(spacing: 0) {
                    ForEach(items) { item in
                        Divider().padding(.leading, 44)
                        ItemRow(
                            item: item,
                            isSelected: model.selection.contains(item.id),
                            tint: tint,
                            title: rowTitle(item),
                            showsLocation: false,
                            showsDate: false
                        ) {
                            model.toggle(item)
                        }
                    }
                }
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .card(padding: 14)
    }
}

/// Stands in for a checkbox on what cannot be removed now; hovering tells why.
private struct LockBadge: View {
    let reason: String?

    var body: some View {
        Image(systemName: "lock.fill")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(width: 20, height: 20)
            .help(reason ?? "Cannot be removed")
            .accessibilityLabel(reason ?? AccessibilityText.lockedFallback)
    }
}

private struct ItemRow: View {
    let item: CleanupItem
    let isSelected: Bool
    let tint: Color
    /// Replaces the item's name, e.g. with its path inside a project.
    var title: String?
    /// Whether the folder the item is in shows under its name.
    var showsLocation = true
    var showsDate = true
    let toggle: () -> Void

    private var displayTitle: String {
        title ?? (item.url.pathExtension == "app" ? item.url.deletingPathExtension().lastPathComponent : item.name)
    }

    var body: some View {
        HStack(spacing: 12) {
            if item.isBlocked {
                LockBadge(reason: item.blockedReason)
            } else {
                CheckBox(state: isSelected ? .all : .none, tint: tint, label: displayTitle, action: toggle)
            }
            SystemIcon(url: item.url, size: 28)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(displayTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if item.needsAdmin {
                        Text("Admin")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                            .help("Removing it asks for your administrator password.")
                            .accessibilityLabel(AccessibilityText.needsAdmin)
                    }
                }
                if showsLocation {
                    Text(item.url.abbreviatedPath)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if let reason = item.blockedReason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else if let note = item.note {
                    Text(note)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .lineLimit(2)
                }
            }
            Spacer()
            if showsDate, let modified = item.lastModified {
                Text(modified, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(item.size.formatted)
                .font(.callout.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .padding(.leading, 8)
    }
}

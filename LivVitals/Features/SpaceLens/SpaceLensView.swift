import LivCore
import SwiftUI

struct SpaceLensView: View {
    @Bindable var model: SpaceLensModel
    let permissions: PermissionsModel

    private let module = AppModule.spaceLens
    private static let palette: [Color] = [.purple, .pink, .orange, .blue, .teal, .green, .indigo, .red, .cyan, .yellow]

    var body: some View {
        Group {
            switch model.phase {
            case .idle: idle
            case .scanning: scanning
            case .ready: ready
            }
        }
        .padding(28)
    }

    private var idle: some View {
        VStack(spacing: 22) {
            Spacer()
            ModuleIcon(module: module, size: 96)
                .shadow(color: module.theme.end.opacity(0.4), radius: 24, y: 10)
            Text(module.title).font(.largeTitle.bold())
            Text(module.tagline).font(.title3).foregroundStyle(.secondary)
            if let message = model.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            Spacer()
            CircleActionButton(title: String(localized: "Scan"), theme: module.theme, action: model.scan)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var scanning: some View {
        VStack(spacing: 20) {
            ProgressView().controlSize(.large).scaleEffect(1.6).frame(height: 80)
            Text("Measuring your home folder…").font(.headline)
            if let progress = model.scanProgress {
                Text("\(progress.filesVisited.formatted()) files · \(progress.bytesCounted.formatted)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
                Text(progress.currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
            }
            if permissions.status != .granted {
                Text("macOS may ask to let Liv Vitals read some folders. Allow it to continue; Full Disk Access avoids the prompts.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            Button("Cancel", action: model.cancelScan).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder private var ready: some View {
        readyContent
            .confirmationDialog(
                removalTitle,
                isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.cancelRemoval() } }),
                presenting: model.pendingRemoval
            ) { node in
                Button(model.pendingRemovalIsPermanent ? "Delete Permanently" : "Move to Trash", role: model.pendingRemovalIsPermanent ? .destructive : nil) {
                    model.confirmRemoval()
                }
                Button("Cancel", role: .cancel) { model.cancelRemoval() }
            } message: { node in
                Text("\(node.name)\n\(node.url.abbreviatedPath)\n\(node.size.formatted)")
            }
    }

    private var removalTitle: String {
        guard let node = model.pendingRemoval else { return String(localized: "Remove?") }
        return model.pendingRemovalIsPermanent ? String(localized: "Delete “\(node.name)” permanently?") : String(localized: "Move “\(node.name)” to the Trash?")
    }

    @ViewBuilder private var readyContent: some View {
        if let focused = model.focused {
            VStack(spacing: 16) {
                ModuleHeader(module: module, subtitle: headerSubtitle) { rescanControl(focused) }
                if !model.issues.isEmpty { issuesBanner }
                breadcrumbBar(focused)
                HStack(spacing: 18) {
                    SunburstView(
                        root: focused,
                        title: displayName(of: focused),
                        canGoUp: model.breadcrumb.count > 1,
                        hovered: $model.hovered,
                        color: color(for:),
                        onOpen: model.open,
                        onCenterTap: model.goUp,
                        menuItems: { node in
                            AnyView(Group {
                                Button("Reveal in Finder") { model.reveal(node) }
                                Button("Move to Trash") { model.requestRemoval(node) }
                                    .disabled(!model.canRemove(node))
                            })
                        }
                    )
                    .id(focused.url)
                    .transition(.scale(scale: 0.9).combined(with: .opacity))
                    .frame(minWidth: 380)

                    childList(of: focused)
                        .frame(width: 340)
                }
            }
        }
    }

    /// "Rescan" measures the folder the user is in; while it runs, the old view stays and can be cancelled.
    @ViewBuilder private func rescanControl(_ focused: DiskNode) -> some View {
        if model.rescanningURL != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                if let progress = model.scanProgress {
                    Text("\(progress.filesVisited.formatted()) files")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Button("Cancel", action: model.cancelRescan)
            }
        } else {
            Button("Rescan", action: model.rescanFocused)
                .help("Rescan \(displayName(of: focused))")
        }
    }

    private var headerSubtitle: String {
        let total = model.root?.size.formatted ?? ""
        guard let scannedAt = model.scannedAt else { return String(localized: "\(total) in your home folder") }
        return String(localized: "\(total) in your home folder · scanned \(scannedAt.formatted(date: .omitted, time: .shortened))")
    }

    /// Folders macOS would not let the scanner read are left out of the totals; the permission usually explains why.
    private var issuesBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text("\(model.issues.count) items could not be read, so the totals may be low.")
            Spacer()
            if permissions.status != .granted {
                Button("Grant Full Disk Access", action: permissions.openSettings)
            }
        }
        .font(.callout)
        .card(padding: 10)
    }

    private func breadcrumbBar(_ focused: DiskNode) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(model.breadcrumb.enumerated()), id: \.element.url) { index, node in
                if index > 0 {
                    Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.secondary)
                }
                Button(displayName(of: node)) { model.open(node) }
                    .buttonStyle(.plain)
                    .font(.callout.weight(index == model.breadcrumb.count - 1 ? .semibold : .regular))
            }
            Spacer()
            Button {
                model.reveal(focused)
            } label: {
                Label("Reveal in Finder", systemImage: "folder")
            }
            .buttonStyle(.borderless)
            .font(.callout)
        }
    }

    private func childList(of folder: DiskNode) -> some View {
        let children = model.visibleChildren(of: folder)
        return VStack(alignment: .leading, spacing: 10) {
            Text("\(displayName(of: folder)) · \(folder.children.count) items")
                .font(.headline)
            TextField("Filter by name", text: $model.filterText)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(children) { child in
                        ChildRow(
                            node: child,
                            fraction: Double(child.size.bytes) / Double(max(folder.size.bytes, 1)),
                            color: color(for: child),
                            isHovered: model.hovered == child.url,
                            isLoading: model.loading.contains(child.url),
                            isProtected: model.isProtected(child),
                            canRemove: model.canRemove(child),
                            onOpen: { model.open(child) },
                            onReveal: { model.reveal(child) },
                            onRemove: { model.requestRemoval(child) }
                        )
                        .onHover { inside in model.hovered = inside ? child.url : nil }
                    }
                    if children.isEmpty && !model.filterText.isEmpty {
                        Text("Nothing matches “\(model.filterText)”.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 12)
                    }
                }
            }
            .scrollIndicators(.never)
            if let error = model.loadError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let message = model.removalMessage {
                Label(message, systemImage: "info.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Label("Removed items \(removalExplanation). Locked folders are protected and cannot be removed.", systemImage: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .card()
    }

    private var removalExplanation: String {
        model.pendingRemovalIsPermanent ? String(localized: "are deleted permanently") : String(localized: "go to the Trash")
    }

    private func displayName(of node: DiskNode) -> String {
        node.url == model.root?.url ? "Home" : node.name
    }

    /// Each top-level folder of the focused view keeps one hue; deeper nodes inherit it.
    private func color(for node: DiskNode) -> Color {
        guard let focused = model.focused else { return .gray }
        let index = focused.children.firstIndex { $0.url == node.url || node.url.path.hasPrefix($0.url.path + "/") } ?? 0
        return Self.palette[index % Self.palette.count]
    }
}

private struct ChildRow: View {
    let node: DiskNode
    let fraction: Double
    let color: Color
    let isHovered: Bool
    let isLoading: Bool
    let isProtected: Bool
    let canRemove: Bool
    let onOpen: () -> Void
    let onReveal: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 9, height: 9)
            SystemIcon(url: node.url, prefer: .file, size: 22)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(node.name).lineLimit(1).truncationMode(.middle)
                    if isProtected {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Protected: Liv Vitals will never remove this.")
                            .accessibilityLabel("Protected: Liv Vitals will never remove this.")
                    }
                }
                GeometryReader { proxy in
                    Capsule().fill(color.opacity(0.7))
                        .frame(width: max(2, proxy.size.width * fraction))
                }
                .frame(height: 4)
            }
            if isLoading { ProgressView().controlSize(.small) }
            Text(node.size.formatted)
                .font(.callout.monospacedDigit())
                .frame(width: 70, alignment: .trailing)
            Button(action: onReveal) {
                Image(systemName: "magnifyingglass.circle")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(node.name) in Finder")
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovered ? 1 : 0)
            .disabled(!canRemove)
            .help(isProtected ? "Protected: cannot be removed" : "Move to Trash")
            .accessibilityLabel("Move \(node.name) to the Trash")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(isHovered ? Color.primary.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // One click opens a folder, as it does in the sunburst. The buttons above take their own clicks.
        .onTapGesture(perform: onOpen)
        // The list is the way to move through the folders with VoiceOver or the keyboard: the sunburst only has the pointer.
        .accessibilityElement(children: .contain)
        .accessibilityAction(named: node.isDirectory ? "Open folder" : "Show details", onOpen)
        .contextMenu {
            Button("Reveal in Finder", action: onReveal)
            Button("Move to Trash", action: onRemove).disabled(!canRemove)
        }
    }
}

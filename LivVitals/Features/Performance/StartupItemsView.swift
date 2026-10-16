import AppKit
import LivCore
import SwiftUI

/// "Startup Items" in Performance: what launches by itself, by app. Only shown, never changed.
struct StartupItemsSection: View {
    let model: StartupItemsModel

    static let loginItemsSettings = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Startup Items").font(.title3.bold())
                    Text(caption).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.isLoading { ProgressView().controlSize(.small) }
                Button("Open Login Items Settings") {
                    if let url = Self.loginItemsSettings { NSWorkspace.shared.open(url) }
                }
            }
            .padding(.top, 8)

            if model.groups.isEmpty && model.hasLoaded {
                Text("Nothing starts by itself apart from Apple's own services.")
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
            ForEach(model.groups) { group in
                AppStartupCard(group: group)
            }
        }
        .task { await model.load() }
    }

    private var caption: String {
        let count = model.items.count
        guard count > 0 else { return String(localized: "Programs that start by themselves. Liv Vitals only shows them.") }
        let missing = model.missingProgramCount
        let base = String(localized: "\(count) items start by themselves. Liv Vitals only shows them.")
        guard missing > 0 else { return base }
        return base + " " + String(localized: "\(missing) of them point to programs that are gone.")
    }
}

/// The items of one app.
private struct AppStartupCard: View {
    let group: StartupItemsModel.Group

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                if let owner = group.owner {
                    SystemIcon(url: owner.url, size: 26)
                } else {
                    Image(systemName: "questionmark.app.dashed").font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 26, height: 26)
                }
                Text(group.title).font(.headline)
                Text("\(group.items.count)").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            ForEach(group.items) { item in
                Divider()
                StartupItemRow(item: item)
            }
        }
        .card(padding: 14)
    }
}

private struct StartupItemRow: View {
    let item: LaunchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(item.label).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Text(scopeTitle)
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(.quaternary, in: Capsule())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                    .buttonStyle(.link)
                    .font(.caption)
            }
            if let program = item.program {
                Text(URL(filePath: program).abbreviatedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if !item.programExists {
                Label("Its program is gone; the app was probably removed.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var scopeTitle: String {
        switch item.scope {
        case .user: String(localized: "User")
        case .systemAgent, .systemDaemon: String(localized: "All users")
        }
    }
}

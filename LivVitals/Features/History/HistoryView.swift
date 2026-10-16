import LivCore
import SwiftUI

struct HistoryView: View {
    let store: AppStore

    private let module = AppModule.history
    private var model: HistoryModel { store.historyModel }

    var body: some View {
        VStack(spacing: 18) {
            ModuleHeader(module: module)

            HStack(spacing: 12) {
                stat("Total freed", store.history.map(\.record.freed).sum().formatted, systemImage: "externaldrive.badge.checkmark")
                stat("Cleanups", "\(store.history.count)", systemImage: "sparkles")
                stat("Items removed", "\(store.history.map(\.record.itemCount).reduce(0, +))", systemImage: "doc.on.doc")
            }

            if model.isPuttingBack { progressBanner }
            if let result = model.result { ResultBanner(result: result, dismiss: model.dismissResult) }
            if let message = model.errorMessage { errorBanner(message) }

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.history) { run in
                        RunCard(model: model, run: run)
                    }
                }
            }
            .scrollIndicators(.never)
        }
        .padding(28)
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(get: { model.request != nil }, set: { if !$0 { model.cancelRequest() } }),
            titleVisibility: .visible,
            presenting: model.request
        ) { _ in
            Button("Put Back") { model.confirmPutBack() }
            Button("Cancel", role: .cancel) { model.cancelRequest() }
        } message: { request in
            Text(confirmationMessage(request))
        }
    }

    private var confirmationTitle: String {
        guard let request = model.request else { return String(localized: "Put Back") }
        let count = request.preview.restorable
        return String(localized: "Put \(count) items back?")
    }

    private func confirmationMessage(_ request: HistoryModel.Request) -> String {
        var lines = [String(localized: "They go from the Trash to where they were.")]
        if request.preview.needsPassword > 0 {
            let count = request.preview.needsPassword
            lines.append(String(localized: "\(count) ask for your password."))
        }
        if !request.preview.skipped.isEmpty {
            let count = request.preview.skipped.count
            lines.append(String(localized: "\(count) items stay where they are."))
        }
        return lines.joined(separator: " ")
    }

    private var progressBanner: some View {
        HStack(spacing: 10) {
            if let fraction = model.progress?.fraction {
                ProgressView(value: fraction).frame(width: 120)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(model.progress?.currentPath.isEmpty == false ? model.progress!.currentPath : "Putting items back…")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Cancel", action: model.cancelPutBack)
        }
        .card(padding: 12)
    }

    private func errorBanner(_ message: String) -> some View {
        HStack {
            Label(message, systemImage: "exclamationmark.triangle")
            Spacer()
            Button("Dismiss", action: model.dismissResult)
        }
        .card(padding: 12)
    }

    private func stat(_ title: LocalizedStringKey, _ value: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.callout)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// What the last "Put Back" did, with what it left alone and why.
private struct ResultBanner: View {
    let result: RestoreOutcome
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(headline, systemImage: result.restored > 0 ? "arrow.uturn.backward.circle.fill" : "info.circle")
                    .font(.headline)
                Spacer()
                Button("Dismiss", action: dismiss)
            }
            if let notice = result.notice {
                Text(notice).font(.callout).foregroundStyle(.secondary)
            }
            problems(result.skipped, title: "Left where they are")
            problems(result.failed, title: "Could not be put back")
        }
        .card(padding: 12)
    }

    private var headline: String {
        switch result.restored {
        case 0: String(localized: "Nothing was put back")
        default: String(localized: "\(result.restored) items put back")
        }
    }

    @ViewBuilder
    private func problems(_ list: [RestoreProblem], title: LocalizedStringKey) -> some View {
        if !list.isEmpty {
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(list.prefix(50).enumerated()), id: \.offset) { _, problem in
                        HStack(alignment: .firstTextBaseline) {
                            Text(URL(filePath: problem.originalPath).abbreviatedPath)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(problem.reason).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if list.count > 50 {
                        Text("and \(list.count - 50) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 4) {
                    Text(title)
                    Text("(\(list.count))")
                }
            }
            .font(.callout)
        }
    }
}

private struct RunCard: View {
    let model: HistoryModel
    let run: HistoryRun

    private var record: CleanupRecord { run.record }
    private var isOpen: Bool { model.expanded.contains(run.id) }
    private var sourceModule: AppModule {
        AppModule.allCases.first { $0.title == record.source } ?? .cleanup
    }

    var body: some View {
        VStack(spacing: 10) {
            header
            if isOpen { items }
        }
        .card(padding: 12)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                withMotion(.snappy(duration: 0.2)) { model.toggle(run.id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 12)
                    ModuleIcon(module: sourceModule, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.source).font(.headline)
                        Text(record.date, format: .dateTime.day().month(.wide).year().hour().minute())
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(record.source), \(record.itemCount) items")

            if run.restoredCount > 0 {
                Text("Put back \(run.restoredCount)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
            Text(badge)
                .font(.caption.weight(.medium))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.primary.opacity(0.07), in: Capsule())
            Text("\(record.itemCount) items")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 70, alignment: .trailing)
            Text(record.freed.formatted)
                .font(.headline.monospacedDigit())
                .frame(width: 80, alignment: .trailing)
            putBackButton
        }
    }

    private var badge: String {
        if record.movedToTrash { return String(localized: "Moved to Trash") }
        return run.items.allSatisfy { $0.trashedPath == nil } ? String(localized: "Deleted for good") : String(localized: "Deleted")
    }

    @ViewBuilder
    private var putBackButton: some View {
        let restorable = model.restorable(in: run)
        if restorable.isEmpty {
            Color.clear.frame(width: 84, height: 1)
        } else {
            Button("Put Back") {
                Task { await model.askPutBack(restorable, of: run.id) }
            }
            .disabled(model.isPuttingBack)
            .frame(width: 84)
            .accessibilityLabel("Put back \(record.itemCount) items from \(record.source)")
        }
    }

    private var items: some View {
        VStack(spacing: 0) {
            Divider()
            if run.items.isEmpty {
                Text("The details of this cleanup are loading.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 10)
            }
            ForEach(run.items) { item in
                ItemRow(model: model, run: run, item: item)
            }
        }
    }
}

private struct ItemRow: View {
    let model: HistoryModel
    let run: HistoryRun
    let item: HistoryItem

    var body: some View {
        let status = model.status(of: item)
        HStack(spacing: 10) {
            SystemIcon(url: iconURL(status), prefer: .file, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(filePath: item.originalPath).lastPathComponent)
                    .lineLimit(1)
                Text(URL(filePath: item.originalPath).deletingLastPathComponent().abbreviatedPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 12)
            Text(status.title)
                .font(.caption.weight(.medium))
                .foregroundStyle(status == .putBack ? Color.green : .secondary)
            Text(ByteSize(item.bytes).formatted)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 80, alignment: .trailing)
            if status == .inTheTrash {
                Button("Put Back") { Task { await model.askPutBack([item], of: run.id) } }
                    .controlSize(.small)
                    .disabled(model.isPuttingBack)
                    .frame(width: 84)
                    .accessibilityLabel("Put back \(URL(filePath: item.originalPath).lastPathComponent)")
            } else {
                Color.clear.frame(width: 84, height: 1)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
    }

    /// The item in the Trash when it is there, otherwise where it used to be.
    private func iconURL(_ status: HistoryModel.ItemStatus) -> URL {
        if status == .inTheTrash, let trashed = item.trashedPath { return URL(filePath: trashed) }
        return URL(filePath: item.originalPath)
    }
}

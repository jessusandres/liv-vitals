import LivCore
import SwiftUI

struct PerformanceView: View {
    let model: PerformanceModel
    let adminRule: AdminRuleModel
    let startup: StartupItemsModel

    private let module = AppModule.performance

    var body: some View {
        VStack(spacing: 18) {
            ModuleHeader(module: module)

            AdminRuleControls(model: adminRule)
                .font(.callout)
                .foregroundStyle(.secondary)
                .card(padding: 12)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(model.tasks) { task in
                        TaskRow(
                            task: task,
                            isSelected: model.selection.contains(task.id),
                            status: model.status[task.id],
                            isLocked: model.phase != .ready,
                            tint: module.theme.start
                        ) { model.toggle(task) }
                    }
                    StartupItemsSection(model: startup)
                }
            }
            .scrollIndicators(.never)

            HStack(spacing: 18) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(summaryTitle).font(.headline)
                    Text(summaryCaption).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if model.phase == .done {
                    CircleActionButton(title: String(localized: "Done"), theme: module.theme, diameter: 96, action: model.reset)
                } else {
                    CircleActionButton(
                        title: String(localized: "Run"),
                        subtitle: String(localized: "\(model.selection.count) tasks"),
                        theme: module.theme,
                        diameter: 96,
                        isEnabled: model.phase == .ready && !model.selection.isEmpty,
                        action: model.run
                    )
                }
            }
            .card(padding: 14)
        }
        .padding(28)
    }

    private var summaryTitle: String {
        switch model.phase {
        case .ready: return String(localized: "\(model.selection.count) of \(model.tasks.count) tasks selected")
        case .running: return String(localized: "Running maintenance…")
        case .done:
            let failed = model.status.values.filter { if case .failed = $0 { true } else { false } }.count
            let skipped = model.status.values.filter { if case .skipped = $0 { true } else { false } }.count
            if failed + skipped == 0 { return String(localized: "All selected tasks finished") }
            return String(localized: "Finished: \(failed) failed, \(skipped) skipped")
        }
    }

    private var summaryCaption: String {
        let count = model.adminTaskCount
        if count == 0 { return String(localized: "No password needed.") }
        if adminRule.isInstalled { return String(localized: "\(count) admin tasks run without a password.") }
        return String(localized: "\(count) admin tasks need your password, asked once.")
    }
}

private struct TaskRow: View {
    let task: MaintenanceTask
    let isSelected: Bool
    let status: PerformanceModel.Status?
    let isLocked: Bool
    let tint: Color
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            CheckBox(state: isSelected ? .all : .none, tint: tint, label: task.title, action: toggle)
                .disabled(isLocked)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(task.title).font(.headline)
                    if task.requiresAdmin {
                        Text("Admin")
                            .accessibilityLabel(AccessibilityText.needsAdmin)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.orange.opacity(0.2), in: Capsule())
                            .foregroundStyle(.orange)
                    }
                }
                Text(task.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let reason {
                    Text(reason)
                        .font(.caption)
                        .foregroundStyle(isFailure ? Color.red : Color.orange)
                        .lineLimit(3)
                }
            }
            Spacer()
            statusView.frame(width: 24)
        }
        .card(padding: 14)
        .opacity(isLocked && status == nil ? 0.5 : 1)
    }

    private var reason: String? {
        switch status {
        case .failed(let text): text
        case .skipped(let text): "Skipped: \(text)"
        default: nil
        }
    }

    private var isFailure: Bool {
        if case .failed = status { return true }
        return false
    }

    @ViewBuilder private var statusView: some View {
        switch status {
        case .running: ProgressView().controlSize(.small).accessibilityLabel("Running")
        case .finished: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).transition(.scale).accessibilityLabel("Finished")
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(.red).transition(.scale).accessibilityLabel("Failed")
        case .skipped: Image(systemName: "minus.circle.fill").foregroundStyle(.orange).transition(.scale).accessibilityLabel("Skipped")
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary).accessibilityLabel("Waiting")
        case nil: EmptyView()
        }
    }
}

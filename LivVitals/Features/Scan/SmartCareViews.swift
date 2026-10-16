import LivCore
import SwiftUI

/// Smart Care's health card: one reading of the Mac, with no actions.
struct SmartCareHealthCard: View {
    let health: MetricsSnapshot?

    var body: some View {
        HStack(spacing: 18) {
            Image(systemName: "heart.text.square.fill")
                .font(.system(size: 30))
                .foregroundStyle(.white, AppModule.smartCare.theme.gradient)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Health").font(.headline)
                Text(summary).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let health {
                metric("Score", "\(health.health)", level(of: health))
                metric("Free disk", ByteSize(Int64(health.disk.availableBytes)).formatted, nil)
                metric("Memory", Self.pressureTitle(health.memory.pressure), nil)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .card(padding: 14)
    }

    private static func pressureTitle(_ pressure: MemoryPressure) -> String {
        switch pressure {
        case .normal: String(localized: "Normal")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        }
    }

    private var summary: String {
        health == nil ? String(localized: "Reading your Mac…") : String(localized: "How your Mac is doing right now.")
    }

    private func level(of health: MetricsSnapshot) -> String {
        HealthScore.level(for: health.health).localizedTitle
    }

    private func metric(_ title: LocalizedStringKey, _ value: String, _ caption: String?) -> some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline.monospacedDigit())
            if let caption { Text(caption).font(.caption2).foregroundStyle(.secondary) }
        }
        .frame(minWidth: 70, alignment: .trailing)
    }
}

/// The maintenance tasks Smart Care runs after cleaning. Tasks that ask for a password start unchecked unless
/// the optional sudoers rule is installed.
struct SmartCareMaintenanceCard: View {
    let model: ScanFlowModel

    @State private var isExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
                    .background(AppModule.performance.theme.start.gradient, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Maintenance").font(.headline)
                    Text("\(model.selectedMaintenance.count) of \(model.maintenanceTasks.count) tasks selected")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ExpandChevron(title: "Maintenance", isExpanded: isExpanded, toggle: toggleExpanded)
            }
            .contentShape(Rectangle())
            .onTapGesture(perform: toggleExpanded)

            if isExpanded {
                VStack(spacing: 0) {
                    ForEach(model.maintenanceTasks) { task in
                        HStack(spacing: 12) {
                            CheckBox(
                                state: model.maintenanceSelection.contains(task.id) ? .all : .none,
                                tint: AppModule.performance.theme.start,
                                label: task.title
                            ) { model.toggleMaintenance(task) }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.title)
                                Text(caption(of: task)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 7)
                    }
                }
                .padding(.top, 8)
            }
        }
        .card(padding: 14)
    }

    private func toggleExpanded() {
        withMotion(.spring(duration: 0.3)) { isExpanded.toggle() }
    }

    private func caption(of task: MaintenanceTask) -> String {
        guard task.requiresAdmin, !model.isAdminRuleInstalled else { return task.summary }
        return String(localized: "\(task.summary) Asks for your password.")
    }
}

/// How the maintenance part of a Smart Care run ended, for the end screen.
struct SmartCareMaintenanceSummary: View {
    let report: ScanFlowModel.MaintenanceReport

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(headline, systemImage: "wrench.and.screwdriver")
            if !report.failed.isEmpty || !report.skipped.isEmpty {
                DisclosureGroup("Details") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(report.failed, id: \.task.id) { entry in line(entry.task.title, entry.reason) }
                        ForEach(report.skipped, id: \.task.id) { entry in line(entry.task.title, entry.reason) }
                    }
                    .padding(.top, 4)
                }
            }
        }
        .frame(maxWidth: 560, alignment: .leading)
        .card(padding: 12)
    }

    private var headline: String {
        var parts = [String(localized: "\(report.done.count) tasks done")]
        if !report.failed.isEmpty { parts.append(String(localized: "\(report.failed.count) failed")) }
        if !report.skipped.isEmpty { parts.append(String(localized: "\(report.skipped.count) skipped")) }
        return String(localized: "Maintenance: \(parts.formatted())")
    }

    private func line(_ title: String, _ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.callout)
            Text(reason).font(.caption).foregroundStyle(.secondary)
        }
    }
}

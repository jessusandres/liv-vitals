import AppKit
import LivCore
import SwiftUI

struct ScanFlowView: View {
    let model: ScanFlowModel
    let permissions: PermissionsModel

    @Environment(\.showsPreviewData) private var showsPreviewData

    private var module: AppModule { model.module }

    var body: some View {
        Group {
            switch model.phase {
            case .idle: idle
            case .scanning: working(title: "Scanning…", caption: "Looking through \(module.title.lowercased()) locations")
            case .results: ScanResultsView(model: model, permissions: permissions)
            case .cleaning:
                working(
                    title: module == .applications ? "Uninstalling…" : "Cleaning…",
                    caption: module == .applications ? "Removing the selected apps and their files" : "Cleaning the selected items"
                )
            case .done: done
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
        .padding(28)
    }

    private var idle: some View {
        VStack(spacing: 22) {
            Spacer()
            ModuleIcon(module: module, size: 96)
                .shadow(color: module.theme.end.opacity(0.4), radius: 24, y: 10)
            VStack(spacing: 8) {
                Text(module.title).font(.largeTitle.bold())
                Text(module.tagline)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 460)
                if showsPreviewData { PreviewBadge() }
                if let message = model.errorMessage {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                ForEach(module.highlights, id: \.self) { line in
                    Label(line, systemImage: "checkmark.circle.fill")
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.needsProjectFolder {
                VStack(spacing: 10) {
                    Label("None of your project folders exist yet.", systemImage: "folder.badge.questionmark")
                        .font(.headline)
                    Text("Choose the folder that holds your projects, such as ~/Developer.")
                        .foregroundStyle(.secondary)
                    Button("Choose Folder…", action: chooseProjectFolders)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            } else {
                CircleActionButton(title: String(localized: "Scan"), theme: module.theme, action: model.startScan)
                if module == .installers, !showsPreviewData, permissions.status != .granted {
                    Text("macOS may ask to let Liv Vitals see Downloads and the Desktop. Allow it to find installers there.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 420)
                }
            }
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
    }

    private func chooseProjectFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        panel.message = "Choose the folders that hold your projects."
        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
        guard panel.runModal() == .OK else { return }
        model.addProjectFolders(panel.urls)
    }

    private func working(title: LocalizedStringKey, caption: LocalizedStringKey) -> some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                ProgressRing(progress: model.progress, theme: module.theme, lineWidth: 16, label: "Scan progress")
                    .frame(width: 220, height: 220)
                VStack(spacing: 4) {
                    Text(model.progress, format: .percent.precision(.fractionLength(0)))
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(title).foregroundStyle(.secondary)
                }
            }
            VStack(spacing: 6) {
                Text(caption).font(.headline)
                Text(model.currentPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 520)
            }
            Spacer()
            Button("Stop", action: model.cancel)
                .controlSize(.large)
                .disabled(model.phase == .cleaning)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
    }

    private var done: some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: model.lastOutcome?.wasDryRun == true ? "eye.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 88))
                .foregroundStyle(.white, module.theme.gradient)
                .symbolEffect(.bounce, value: model.phase)
            if let outcome = model.lastOutcome {
                Text(model.isMaintenanceOnly ? "Maintenance finished" : Self.title(for: outcome))
                    .font(.largeTitle.bold())
                    .multilineTextAlignment(.center)
                Text(model.isMaintenanceOnly ? "Smart Care ran the tasks you chose." : Self.subtitle(for: outcome))
                    .font(.title3)
                    .foregroundStyle(.secondary)
                if outcome.trashedSize.bytes > 0 && !outcome.wasDryRun {
                    Label("The space becomes free once you empty the Trash.", systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .card(padding: 12)
                }
                if let notice = outcome.notice, !outcome.wasDryRun {
                    Label(notice, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 560, alignment: .leading)
                        .card(padding: 12)
                }
                problems(of: outcome)
                if let report = model.maintenanceReport, !report.isEmpty { SmartCareMaintenanceSummary(report: report) }
            }
            emptyTrash
            Spacer()
            HStack(spacing: 12) {
                Button("Scan Again", action: model.startScan)
                Button("Done", action: model.reset)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("Empty the Trash?", isPresented: Bindable(model).isConfirmingEmptyTrash) {
            Button("Empty Trash", role: .destructive, action: model.confirmEmptyTrash)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Everything in the Trash is deleted permanently, including items that were there before this cleanup.")
        }
    }

    /// Failed and skipped items, each with its reason, folded away until asked for.
    @ViewBuilder private func problems(of outcome: CleanupOutcome) -> some View {
        if !outcome.failures.isEmpty || !outcome.skipped.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                if !outcome.failures.isEmpty {
                    DisclosureGroup("\(outcome.failures.count) could not be cleaned") {
                        problemList(outcome.failures)
                    }
                }
                if !outcome.skipped.isEmpty {
                    DisclosureGroup("\(outcome.skipped.count) skipped") {
                        problemList(outcome.skipped)
                    }
                }
            }
            .frame(maxWidth: 560)
            .card(padding: 12)
        }
    }

    private func problemList(_ problems: [CleanupProblem]) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(problems.enumerated()), id: \.offset) { _, problem in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(problem.item.url.abbreviatedPath)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(problem.reason).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 130)
        .padding(.top, 6)
    }

    @ViewBuilder private var emptyTrash: some View {
        if let emptied = model.trashOutcome {
            Label("Trash emptied: \(emptied.deletedSize.formatted) deleted.", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
        } else if model.offersEmptyTrash {
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Button("Empty Trash", role: .destructive, action: model.requestEmptyTrash)
                        .disabled(!model.canEmptyTrash)
                    if model.isEmptyingTrash { ProgressView().controlSize(.small) }
                }
                if !model.hasFullDiskAccess() {
                    HStack(spacing: 6) {
                        Text("Emptying the Trash needs Full Disk Access.")
                        Button("Open System Settings", action: permissions.openSettings).buttonStyle(.link)
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// "4.2 GB moved to Trash", "1.1 GB deleted", or both; a dry run says it changed nothing.
    static func title(for outcome: CleanupOutcome) -> String {
        if outcome.wasDryRun { return String(localized: "Dry run: nothing was moved") }
        var parts: [String] = []
        if outcome.trashedSize.bytes > 0 { parts.append(String(localized: "\(outcome.trashedSize.formatted) moved to Trash")) }
        if outcome.deletedSize.bytes > 0 { parts.append(String(localized: "\(outcome.deletedSize.formatted) deleted")) }
        return parts.isEmpty ? String(localized: "Nothing was cleaned") : parts.joined(separator: " · ")
    }

    static func subtitle(for outcome: CleanupOutcome) -> String {
        if outcome.wasDryRun { return String(localized: "The log shows what would have happened.") }
        let done = String(localized: "\(outcome.record.itemCount) items cleaned")
        let problems = outcome.failures.count + outcome.skipped.count
        return problems == 0 ? done : String(localized: "\(done), \(problems) not")
    }
}

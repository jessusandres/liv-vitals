import LivCore
import Observation
import SwiftUI

/// What the user is about to confirm, worked out from the selection and the current settings.
struct CleanConfirmation: Identifiable, Equatable {
    let id = UUID()
    var itemCount: Int
    var totalSize: ByteSize
    var trashCount: Int
    var trashSize: ByteSize
    var permanentCount: Int
    var permanentSize: ByteSize
    /// Apps that should be quit first, because their caches are among the selection.
    var appsToQuit: [String]
    var isDryRun: Bool
    /// The Uninstaller quits those apps itself; other modules ask the user to.
    var quitsAppsAutomatically = false
    /// How many items need the administrator's password (asked once, for all of them).
    var adminCount = 0
    /// Labels of the launchd services that are stopped before their files go.
    var servicesToStop: [String] = []
    /// Smart Care: the maintenance tasks that run after the cleaning, and how many of them ask for the password.
    var maintenanceCount = 0
    var maintenanceAdminCount = 0

    /// Anything deleted for good makes the whole confirmation a warning.
    var isPermanent: Bool { permanentCount > 0 && !isDryRun }
}

/// Drives the five-step flow shared by the cleaning modules: idle → scanning → results → cleaning → done.
/// The scanner decides where results come from and what cleaning really does.
@Observable
final class ScanFlowModel {
    enum Phase { case idle, scanning, results, cleaning, done }

    let module: AppModule
    private(set) var phase: Phase = .idle
    private(set) var progress: Double = 0
    private(set) var currentPath = ""
    private(set) var result: ScanResult = .empty
    private(set) var selection: Set<CleanupItem.ID> = []
    private(set) var lastOutcome: CleanupOutcome?
    /// Why the last scan or cleaning stopped, shown on the screen it came back to.
    private(set) var errorMessage: String?
    /// Set while the confirmation sheet is up.
    var confirmation: CleanConfirmation?
    /// Filters the results by name or path.
    var searchText = ""
    /// How the Uninstaller orders its apps.
    var appOrder: AppOrder = .size

    enum AppOrder: String, CaseIterable, Identifiable {
        case size = "Size"
        case name = "Name"
        case lastUsed = "Last Used"
        var id: Self { self }
    }

    // Smart Care only: a reading of the Mac's health and the maintenance tasks that run after the cleaning.
    private(set) var health: MetricsSnapshot?
    private(set) var maintenanceTasks: [MaintenanceTask] = []
    private(set) var maintenanceSelection: Set<String> = []
    /// With the sudoers rule installed the admin tasks run without a password dialog.
    private(set) var isAdminRuleInstalled = false
    private(set) var maintenanceReport: MaintenanceReport?

    /// How the maintenance tasks of a Smart Care run ended.
    struct MaintenanceReport: Equatable {
        var done: [MaintenanceTask] = []
        var failed: [(task: MaintenanceTask, reason: String)] = []
        var skipped: [(task: MaintenanceTask, reason: String)] = []

        var isEmpty: Bool { done.isEmpty && failed.isEmpty && skipped.isEmpty }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.done == rhs.done && lhs.failed.map(\.task) == rhs.failed.map(\.task) && lhs.skipped.map(\.task) == rhs.skipped.map(\.task)
        }
    }

    // Empty Trash, offered after items were moved there.
    var isConfirmingEmptyTrash = false
    private(set) var isEmptyingTrash = false
    private(set) var trashOutcome: CleanupOutcome?

    var onCleaned: ((CleanupRecord) -> Void)?
    /// Read when the user acts, so a change in Settings applies to the next action.
    @ObservationIgnored var options: () -> CleanOptions = { CleanOptions() }
    @ObservationIgnored var previewBeforeCleaning: () -> Bool = { true }
    @ObservationIgnored var hasFullDiskAccess: () -> Bool = { false }
    /// What the scan reads from Settings, evaluated when it starts.
    @ObservationIgnored var scanOptions: () -> ScanOptions = { ScanOptions() }
    /// The folders Dev Projects searches. Read by the screen, so a change in Settings shows at once.
    @ObservationIgnored var projectRoots: () -> [URL] = { [] }
    /// Adds a folder to those Dev Projects searches; returns why it was refused, or nil.
    @ObservationIgnored var addProjectRoot: (URL) -> String? = { _ in nil }

    /// Smart Care's extras. Nil outside the app (tests, previews) and for the other modules.
    @ObservationIgnored var maintenance: (any MaintenanceRunning)?
    @ObservationIgnored var maintenanceOptions: () -> MaintenanceOptions = { MaintenanceOptions() }
    @ObservationIgnored var isRuleInstalled: () async -> Bool = { false }
    @ObservationIgnored var readHealth: () async -> MetricsSnapshot? = { nil }

    @ObservationIgnored private let scanner: any CleanupScanning
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var healthTask: Task<Void, Never>?

    init(module: AppModule, scanner: any CleanupScanning) {
        self.module = module
        self.scanner = scanner
    }

    private var isSmartCare: Bool { module == .smartCare }

    /// Whatever the Run / Clean button would do: items to clean or, in Smart Care, tasks to run.
    var hasWork: Bool { !selection.isEmpty || (isSmartCare && !maintenanceSelection.isEmpty) }

    var selectedMaintenance: [MaintenanceTask] { maintenanceTasks.filter { maintenanceSelection.contains($0.id) } }

    func toggleMaintenance(_ task: MaintenanceTask) {
        if maintenanceSelection.contains(task.id) { maintenanceSelection.remove(task.id) } else { maintenanceSelection.insert(task.id) }
    }

    /// True when a Smart Care run did maintenance and cleaned nothing.
    var isMaintenanceOnly: Bool {
        isSmartCare && maintenanceReport?.isEmpty == false && (lastOutcome?.isEmpty ?? true)
    }

    var selectedSize: ByteSize { result.size(of: selection) }
    var selectedItems: [CleanupItem] { result.items.filter { selection.contains($0.id) } }
    var lastCleanup: CleanupRecord? { lastOutcome?.record }
    var locationsNeedingAccess: Int { result.locationsNeedingAccess }
    /// Folders the scan could not use, e.g. a project folder that does not exist.
    var issues: [ScanIssue] { result.issues }

    /// Dev Projects needs at least one project folder that exists before a scan can find anything.
    var hasUsableProjectFolders: Bool {
        projectRoots().contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The idle screen asks for a folder instead of offering a scan that cannot find anything. A simulated
    /// scan needs no folder.
    var needsProjectFolder: Bool {
        module == .devProjects && !scanner.isSimulated(module) && !hasUsableProjectFolders
    }

    /// Adds the folders the user picked. The first one that is refused is explained on the screen.
    func addProjectFolders(_ folders: [URL]) {
        // Every folder is tried, so one refusal does not keep the others out.
        errorMessage = folders.compactMap(addProjectRoot).first
    }

    // MARK: - Scanning

    func startScan() {
        work?.cancel()
        progress = 0
        currentPath = ""
        errorMessage = nil
        lastOutcome = nil
        trashOutcome = nil
        searchText = ""
        maintenanceReport = nil
        transition(to: .scanning)
        let relay = ProgressRelay<ScanUpdate> { [weak self] in self?.apply($0) }
        let scanOptions = scanOptions()
        // The reading arrives when it arrives; the results do not wait for it.
        healthTask?.cancel()
        health = nil
        if isSmartCare { healthTask = Task { health = await readHealth() } }
        work = Task {
            defer { relay.finish() }
            do {
                let found = try await scanner.scan(module: module, options: scanOptions, onUpdate: relay.send)
                await prepareMaintenance()
                result = found
                // Nothing is uninstalled unless the user picks it: an app's checkbox selects it with its leftovers.
                selection = module == .applications ? [] : found.defaultSelection
                transition(to: .results)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                transition(to: .idle)
            }
        }
    }

    // MARK: - Cleaning

    /// The "Clean" button. Asks first when the settings, a permanent delete or an open app call for it.
    func requestClean() {
        let items = selectedItems
        guard hasWork, phase == .results else { return }
        let options = options()
        let tasks = isSmartCare ? selectedMaintenance : []
        Task {
            let apps = items.isEmpty ? [] : await scanner.runningOwners(of: items)
            var summary = Self.confirmation(for: items, options: options, appsToQuit: apps)
            summary.quitsAppsAutomatically = module == .applications
            summary.maintenanceCount = tasks.count
            summary.maintenanceAdminCount = isAdminRuleInstalled ? 0 : tasks.filter(\.requiresAdmin).count
            if previewBeforeCleaning() || summary.isPermanent || !apps.isEmpty || summary.adminCount > 0 || summary.maintenanceAdminCount > 0 {
                confirmation = summary
            } else {
                clean()
            }
        }
    }

    func confirmClean() {
        confirmation = nil
        clean()
    }

    func cancelConfirmation() {
        confirmation = nil
    }

    /// Cleans the selected items now. The confirmation, when needed, has been handled before this.
    func clean() {
        let items = selectedItems
        let tasks = isSmartCare ? selectedMaintenance : []
        guard !items.isEmpty || !tasks.isEmpty else { return }
        work?.cancel()
        progress = 0
        errorMessage = nil
        maintenanceReport = nil
        transition(to: .cleaning)
        let options = options()
        let relay = ProgressRelay<ScanUpdate> { [weak self] in self?.apply($0) }
        work = Task {
            defer { relay.finish() }
            do {
                let outcome = items.isEmpty
                    ? Self.emptyOutcome(source: module.title, dryRun: options.dryRun)
                    : try await scanner.clean(module: module, items, source: module.title, options: options, onUpdate: relay.send)
                lastOutcome = outcome
                report(outcome)
                if !tasks.isEmpty { maintenanceReport = try await runMaintenance(tasks, dryRun: options.dryRun, relay: relay) }
                transition(to: .done)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                transition(to: result.items.isEmpty ? .idle : .results)
            }
        }
    }

    /// Runs the maintenance tasks of a Smart Care run, all at once so the ones that need a password share a dialog.
    private func runMaintenance(
        _ tasks: [MaintenanceTask], dryRun: Bool, relay: ProgressRelay<ScanUpdate>
    ) async throws -> MaintenanceReport {
        guard let maintenance else { return MaintenanceReport() }
        relay.send(ScanUpdate(fraction: 1, currentPath: "Running maintenance…"))
        var options = maintenanceOptions()
        options.dryRun = options.dryRun || dryRun
        let titles = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.title) })
        let outcomes = try await maintenance.run(tasks, options: options) { event in
            if case .started(let id) = event { relay.send(ScanUpdate(fraction: 1, currentPath: titles[id] ?? id)) }
        }
        var report = MaintenanceReport()
        for task in tasks {
            switch outcomes[task.id] {
            case .done?: report.done.append(task)
            case .failed(let reason)?: report.failed.append((task, reason))
            case .skipped(let reason)?: report.skipped.append((task, reason))
            case nil: report.skipped.append((task, "It did not run."))
            }
        }
        return report
    }

    private static func emptyOutcome(source: String, dryRun: Bool) -> CleanupOutcome {
        CleanupOutcome(
            record: CleanupRecord(date: .now, source: source, itemCount: 0, freed: .zero, movedToTrash: false),
            trashedSize: .zero, deletedSize: .zero, failures: [], skipped: [], wasDryRun: dryRun
        )
    }

    /// Which tasks start checked: the ones Performance checks by default, and the ones that ask for a password
    /// only when the sudoers rule is installed, so Smart Care never surprises with a dialog.
    private func prepareMaintenance() async {
        guard isSmartCare, let maintenance else { return }
        maintenanceTasks = maintenance.tasks
        isAdminRuleInstalled = await isRuleInstalled()
        maintenanceSelection = Set(maintenanceTasks.filter { $0.isSelectedByDefault && (!$0.requiresAdmin || isAdminRuleInstalled) }.map(\.id))
    }

    func cancel() {
        work?.cancel()
        transition(to: result.items.isEmpty ? .idle : .results)
    }

    func reset() {
        work?.cancel()
        result = .empty
        selection = []
        lastOutcome = nil
        trashOutcome = nil
        searchText = ""
        confirmation = nil
        maintenanceReport = nil
        transition(to: .idle)
    }

    // MARK: - Empty Trash

    /// Offered once something was moved to the Trash, for real modules only.
    var offersEmptyTrash: Bool {
        guard let outcome = lastOutcome, !outcome.wasDryRun else { return false }
        return outcome.trashedSize.bytes > 0 && trashOutcome == nil && !scanner.isSimulated(module)
    }

    var canEmptyTrash: Bool { hasFullDiskAccess() && !isEmptyingTrash }

    func requestEmptyTrash() {
        guard canEmptyTrash else { return }
        isConfirmingEmptyTrash = true
    }

    func confirmEmptyTrash() {
        isConfirmingEmptyTrash = false
        guard canEmptyTrash else { return }
        isEmptyingTrash = true
        errorMessage = nil
        let options = options()
        Task {
            do {
                let outcome = try await scanner.emptyTrash(options: options, onUpdate: { _ in })
                trashOutcome = outcome
                report(outcome)
            } catch {
                errorMessage = error.localizedDescription
            }
            isEmptyingTrash = false
        }
    }

    /// Tells the app about a real run. A dry run changed nothing, so it is not history.
    private func report(_ outcome: CleanupOutcome) {
        if !outcome.wasDryRun, outcome.record.itemCount > 0 { onCleaned?(outcome.record) }
    }

    // MARK: - Summaries

    /// What the selection will do, in one line for the results footer.
    var selectionSummary: String {
        guard !selection.isEmpty else {
            if isSmartCare, !maintenanceSelection.isEmpty { return "Only the maintenance tasks run." }
            return module == .applications ? "Select apps to uninstall." : String(localized: "Select items to clean.")
        }
        let options = options()
        if options.dryRun { return "Simulation: nothing will be moved or deleted." }
        let summary = Self.confirmation(for: selectedItems, options: options, appsToQuit: [])
        switch (summary.trashCount > 0, summary.permanentCount > 0) {
        case (true, true): return String(localized: "Some items go to the Trash; the Trash itself is emptied for good.")
        case (false, true): return String(localized: "Selected items are deleted permanently.")
        default: return String(localized: "Selected items go to the Trash.")
        }
    }

    static func confirmation(for items: [CleanupItem], options: CleanOptions, appsToQuit: [String]) -> CleanConfirmation {
        // What needs the administrator's password always goes to the Trash, even with "Move to Trash" off.
        let toTrash = items.filter { $0.needsAdmin || $0.action(moveToTrash: options.moveToTrash) == .moveToTrash }
        let permanent = items.filter { !$0.needsAdmin && $0.action(moveToTrash: options.moveToTrash) == .delete }
        var summary = CleanConfirmation(
            itemCount: items.count,
            totalSize: items.map(\.size).sum(),
            trashCount: toTrash.count,
            trashSize: toTrash.map(\.size).sum(),
            permanentCount: permanent.count,
            permanentSize: permanent.map(\.size).sum(),
            appsToQuit: appsToQuit,
            isDryRun: options.dryRun
        )
        summary.adminCount = items.filter(\.needsAdmin).count
        summary.servicesToStop = items.compactMap(serviceLabel(of:))
        return summary
    }

    /// The label of the launchd job a launch plist defines, when `item` is one.
    private static func serviceLabel(of item: CleanupItem) -> String? {
        guard item.url.pathExtension.lowercased() == "plist",
              ["LaunchAgents", "LaunchDaemons"].contains(item.url.deletingLastPathComponent().lastPathComponent)
        else { return nil }
        return LaunchJob.read(at: item.url)?.label ?? item.url.deletingPathExtension().lastPathComponent
    }

    func matchesSearch(_ item: CleanupItem) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return true }
        if let project = item.group, project.lastPathComponent.localizedCaseInsensitiveContains(query) { return true }
        return item.name.localizedCaseInsensitiveContains(query) || item.url.abbreviatedPath.localizedCaseInsensitiveContains(query)
    }

    private func apply(_ update: ScanUpdate) {
        if let fraction = update.fraction { progress = fraction }
        currentPath = update.currentPath
    }

    // MARK: - Selection

    func toggle(_ item: CleanupItem) {
        guard !item.isBlocked else { return }
        if selection.contains(item.id) { selection.remove(item.id) } else { selection.insert(item.id) }
    }

    /// Blocked items never count: a group is fully checked when everything that can be checked is.
    func checkState(of items: [CleanupItem]) -> CheckState {
        let selectable = items.filter { !$0.isBlocked }
        let selectedCount = selectable.filter { selection.contains($0.id) }.count
        if selectedCount == 0 { return .none }
        return selectedCount == selectable.count ? .all : .some
    }

    /// In the Uninstaller an app's checkbox picks the app and the leftovers that are safe to take along, and
    /// clears everything once something is picked. Elsewhere it checks or clears the whole group.
    func toggleAll(_ items: [CleanupItem]) {
        let selectable = items.filter { !$0.isBlocked }
        let ids = selectable.map(\.id)
        if module == .applications {
            if checkState(of: items) != .none {
                selection.subtract(ids)
            } else {
                let recommended = selectable.filter(\.isSelectedByDefault).map(\.id)
                selection.formUnion(recommended.isEmpty ? ids : recommended)
            }
            return
        }
        if checkState(of: items) == .all { selection.subtract(ids) } else { selection.formUnion(ids) }
    }

    private func transition(to newPhase: Phase) {
        withMotion(.spring(duration: 0.45)) { phase = newPhase }
    }
}

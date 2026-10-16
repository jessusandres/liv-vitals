import Foundation
import LivCore
import LivWidgetsUI
import Observation

/// Owns every module's state so it survives switching modules in the sidebar.
@Observable
final class AppStore {
    let services: ServiceContainer
    let settings: AppSettings
    let permissions: PermissionsModel
    let performance: PerformanceModel
    let adminRule: AdminRuleModel
    let startupItems: StartupItemsModel
    let spaceLens: SpaceLensModel
    let monitor: MonitorModel
    let desktopWidgets: DesktopWidgetsModel
    let loginItem: LoginItemModel
    let historyModel: HistoryModel
    @ObservationIgnored private var scanFlows: [AppModule: ScanFlowModel] = [:]

    /// Creating the store does no work; services are only used once a screen asks for them.
    init(services: ServiceContainer) {
        self.services = services
        let settings = AppSettings(store: services.settingsStore, home: services.home)
        self.settings = settings
        permissions = PermissionsModel(provider: services.permissions, settings: settings)
        monitor = MonitorModel(service: services.metrics)
        desktopWidgets = DesktopWidgetsModel(reporter: services.widgets)
        loginItem = LoginItemModel(controller: services.loginItem)
        performance = PerformanceModel(runner: services.maintenance)
        performance.options = { MaintenanceOptions(dryRun: settings.dryRun) }
        adminRule = AdminRuleModel(privileged: services.privileged)
        startupItems = StartupItemsModel(service: services.startupItems)
        historyModel = HistoryModel(service: services.history)
        let home = services.home
        spaceLens = SpaceLensModel(
            service: services.diskTree,
            home: home,
            makeGuard: {
                // The same rules the cleaning service applies: the whole home, minus protected and whitelisted folders.
                SafetyGuard(home: home, allowedRoots: [home], whitelist: settings.protectedPaths.map { URL(filePath: $0) })
            },
            cleaner: services.cleanup,
            cleanOptions: { settings.cleanOptions }
        )
        spaceLens.onCleaned = { [weak self] in self?.record($0) }
        settings.onIndicatorsChanged = { [weak self] in self?.syncIndicatorSampling() }
        syncIndicatorSampling()
    }

    /// Menu bar indicators need readings even with no window open; `MonitorModel` samples slowly and without `top` for them.
    func syncIndicatorSampling() {
        monitor.setIndicatorRefresh(seconds: settings.enabledIndicators.isEmpty ? nil : settings.indicatorRefresh)
    }

    /// A module the menu bar asked for ("Open Liv Vitals", "Configure…"); the main window takes it and clears it.
    var requestedModule: AppModule?

    /// Set by "Show Welcome Guide" in Settings; the first-run guide is decided by `permissions.shouldShowOnboarding`.
    var isWelcomeGuideRequested = false

    var isWelcomeGuideVisible: Bool { isWelcomeGuideRequested || permissions.shouldShowOnboarding }

    func showWelcomeGuide() {
        isWelcomeGuideRequested = true
    }

    /// Finishing or skipping ends the guide; either way the first run is not shown again.
    func closeWelcomeGuide() {
        isWelcomeGuideRequested = false
        permissions.dismissOnboarding()
    }

    /// Every finished cleanup, newest first.
    var history: [HistoryRun] { historyModel.runs }

    /// Shows a finished real cleanup in History at once. The log is the source of truth and is read again later.
    private func record(_ record: CleanupRecord) {
        historyModel.insert(record)
    }

    func loadHistory() async {
        await historyModel.load()
    }

    func scanFlow(for module: AppModule) -> ScanFlowModel {
        if let existing = scanFlows[module] { return existing }
        let model = ScanFlowModel(module: module, scanner: services.cleanup)
        model.options = { [settings] in settings.cleanOptions }
        model.scanOptions = { [settings] in settings.scanOptions }
        model.projectRoots = { [settings] in settings.projectRoots.map { URL(filePath: $0, directoryHint: .isDirectory) } }
        model.addProjectRoot = { [settings] folder in settings.addProjectRoot(folder.path)?.errorDescription }
        model.previewBeforeCleaning = { [settings] in settings.previewBeforeCleaning }
        model.hasFullDiskAccess = { [permissions] in permissions.status == .granted }
        model.onCleaned = { [weak self] in self?.record($0) }
        if module == .smartCare {
            let services = services
            model.maintenance = services.maintenance
            model.maintenanceOptions = { [settings] in MaintenanceOptions(dryRun: settings.dryRun) }
            model.isRuleInstalled = { await services.privileged.isRuleInstalled() }
            model.readHealth = { await Self.firstReading(of: services.metrics) }
        }
        scanFlows[module] = model
        return model
    }

    /// One reading of the Mac's health, or nil when none arrives within a few seconds.
    private static func firstReading(of metrics: any MetricsProviding) async -> MetricsSnapshot? {
        await withTaskGroup(of: MetricsSnapshot?.self) { group in
            group.addTask {
                var readings = metrics.snapshots(every: .seconds(1)).makeAsyncIterator()
                return await readings.next()
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Whether `module` is fed by a simulated service while the app runs on real data.
    /// Each stage that makes a module real removes it from the list below.
    func showsPreviewData(for module: AppModule) -> Bool {
        guard services.labelsSimulatedData else { return false }
        switch module {
        case .smartCare, .cleanup, .devProjects, .installers, .applications: return services.cleanup.isSimulated(module)
        case .performance: return services.maintenance.isSimulated
        case .history: return services.history.isSimulated
        case .spaceLens: return services.diskTree.isSimulated
        case .monitor: return services.metrics.isSimulated
        case .settings: return false
        }
    }
}

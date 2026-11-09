import Foundation
import LivCore
import LivWidgetsUI

/// Every service the app uses, built once and handed to `AppStore`.
///
/// `.live` talks to the real Mac wherever that exists. `.mock` is fully simulated and never touches the
/// disk, so previews and `make snapshots` behave the same on any machine.
struct ServiceContainer: Sendable {
    var cleanup: any CleanupScanning
    var diskTree: any DiskTreeProviding
    var metrics: any MetricsProviding
    var maintenance: any MaintenanceRunning
    /// What needs administrator rights: the optional rule and the Uninstaller's system files.
    var privileged: any PrivilegedRunning
    /// The launch agents and daemons Performance lists.
    var startupItems: any StartupItemsProviding
    var history: any HistoryProviding
    var permissions: any PermissionProviding
    var loginItem: any LoginItemControlling
    var settingsStore: SettingsStore
    var home: URL
    /// Whether modules fed by simulated services say so. Off for previews and snapshots, which are simulated on purpose.
    var labelsSimulatedData: Bool
    /// Which desktop widgets are added, and the button that reloads them. Only the real Mac answers.
    var widgets: any WidgetInstallationReporting = UnavailableWidgetInstallations()
    /// Keep awake's power assertions and the events that decide when it runs. The defaults hold nothing and hear nothing.
    var keepAwake: any PowerAssertionHolding = MockPowerAssertions()
    var keepAwakeConditions: @MainActor @Sendable () -> any KeepAwakeConditionSource = { MockKeepAwakeConditions() }

    /// Real where a real service exists; the rest stays simulated and is labelled until its stage lands.
    /// Cleanup and Space Lens act on real files here.
    static var live: ServiceContainer {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let permissions = LivePermissions(home: home)
        // One log, written by the cleaning service and read back by History.
        let log = OperationLog(fileURL: home.appending(path: "Library/Application Support/LivVitals/operations.jsonl"))
        let privileged = SystemPrivilegedRunner()
        return ServiceContainer(
            cleanup: LiveCleanupScanner(home: home, permissions: permissions, log: log, privileged: privileged),
            diskTree: LiveDiskTree(),
            metrics: LiveMetrics(),
            maintenance: LiveMaintenance(commands: ProcessCommandRunner(), privileged: privileged, log: log),
            privileged: privileged,
            startupItems: LiveStartupItems(home: home),
            history: LiveHistory(log: log, home: home, privileged: privileged),
            permissions: permissions,
            loginItem: SystemLoginItem(),
            settingsStore: .standard(home: home),
            home: home,
            labelsSimulatedData: true,
            widgets: SystemWidgetInstallations(),
            keepAwake: LivePowerAssertions(),
            keepAwakeConditions: { LiveKeepAwakeConditions() }
        )
    }

    static var mock: ServiceContainer {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return ServiceContainer(
            cleanup: MockCleanupScanner(),
            diskTree: MockDiskTree(),
            metrics: MockMetrics(),
            maintenance: MockMaintenance(),
            privileged: MockPrivileged(),
            startupItems: MockStartupItems(),
            history: MockHistory(),
            permissions: MockPermissions(),
            loginItem: MockLoginItem(),
            settingsStore: SettingsStore(fileURL: nil, home: home),
            home: home,
            labelsSimulatedData: false
        )
    }
}

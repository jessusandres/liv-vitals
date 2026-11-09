#if DEBUG
import AppKit
import LivCore
import SwiftUI

/// Debug-only: `LivVitals -LivSnapshotDir <dir>` renders each module state to PNG in light and dark mode, then quits.
/// Lets layout be reviewed without Screen Recording permission. Not compiled into Release builds.
enum DebugSnapshots {
    private struct Scenario {
        let name: String
        let module: AppModule
        /// Simulated unless a scenario asks for something real, e.g. the live Monitor.
        var services: ServiceContainer = .mock
        /// Renders this menu bar panel at its own size instead of the whole window.
        var panel: MetricKind?
        var prepare: @MainActor (AppStore) async -> Void = { _ in }
        /// Renders this instead of the whole window, for views that only exist in a sheet. Declared after
        /// `prepare` so a trailing closure still means `prepare`.
        var view: (@MainActor () -> AnyView)?
    }

    private static let size = CGSize(width: 1120, height: 740)

    private static let scenarios: [Scenario] = [
        Scenario(name: "01-smartcare-idle", module: .smartCare),
        // The health card on top, the usual categories, and the maintenance tasks below them.
        Scenario(name: "01b-smartcare-results", module: .smartCare) { store in
            store.scanFlow(for: .smartCare).startScan()
            await wait(4.5)
        },
        Scenario(name: "01c-smartcare-done", module: .smartCare) { store in
            let flow = store.scanFlow(for: .smartCare)
            flow.startScan()
            await wait(4.5)
            flow.clean()
            await wait(4)
        },
        Scenario(name: "02-cleanup-scanning", module: .cleanup) { store in
            store.scanFlow(for: .cleanup).startScan()
            await wait(1.2)
        },
        Scenario(name: "03-cleanup-results", module: .cleanup) { store in
            store.scanFlow(for: .cleanup).startScan()
            await wait(3.5)
        },
        Scenario(name: "04-cleanup-done", module: .cleanup) { store in
            let flow = store.scanFlow(for: .cleanup)
            flow.startScan()
            await wait(3.5)
            flow.clean()
            await wait(3)
        },
        // What the user sees when asked to confirm, and the end screen when some items could not be cleaned.
        Scenario(name: "03b-cleanup-confirm", module: .cleanup) { store in
            store.scanFlow(for: .cleanup).startScan()
            await wait(3.5)
            store.scanFlow(for: .cleanup).requestClean()
            await wait(1)
        },
        Scenario(name: "03c-confirm-sheet-permanent", module: .cleanup, view: {
            AnyView(
                CleanConfirmationSheet(
                    confirmation: CleanConfirmation(
                        itemCount: 17, totalSize: ByteSize(18_830_000_000), trashCount: 16, trashSize: ByteSize(16_730_000_000),
                        permanentCount: 1, permanentSize: ByteSize(2_100_000_000), appsToQuit: ["Google Chrome", "Safari"], isDryRun: false
                    ),
                    onConfirm: {}, onCancel: {}
                )
                .background(.background)
                .frame(width: 1120, height: 740)
            )
        }),
        Scenario(name: "04b-cleanup-done-problems", module: .cleanup, services: .mockWithCleaningProblems) { store in
            let flow = store.scanFlow(for: .cleanup)
            flow.startScan()
            await wait(3.5)
            flow.clean()
            await wait(3)
        },
        Scenario(name: "05-uninstaller-results", module: .applications) { store in
            store.scanFlow(for: .applications).startScan()
            await wait(3.5)
        },
        // One card per project; the search opens them all so the rows and their notes show.
        Scenario(name: "05b-devprojects-results", module: .devProjects) { store in
            let flow = store.scanFlow(for: .devProjects)
            flow.startScan()
            await wait(3.5)
            flow.searchText = "code"
        },
        Scenario(name: "06-performance", module: .performance),
        // The same screen once the optional rule is installed: no password, and the button to remove it.
        Scenario(name: "06b-performance-rule", module: .performance, services: .mockWithAdminRule) { store in
            await store.adminRule.refresh()
        },
        // The startup items sit below the tasks, so this renders the section alone, with simulated items.
        Scenario(name: "06c-startup-items", module: .performance, view: {
            AnyView(
                ScrollView {
                    StartupItemsSection(model: StartupItemsModel(service: MockStartupItems(), items: MockData.startupItems))
                        .padding(28)
                }
                .background(.background)
                .frame(width: 1120, height: 740)
            )
        }),
        Scenario(name: "07-spacelens", module: .spaceLens) { store in
            store.spaceLens.scan()
            await wait(2.5)
        },
        Scenario(name: "07b-spacelens-library", module: .spaceLens) { store in
            store.spaceLens.scan()
            await wait(2.5)
            if let largest = store.spaceLens.root?.children.first { store.spaceLens.open(largest) }
            await wait(0.6)
        },
        Scenario(name: "08c-panel-cpu", module: .monitor, panel: .cpu) { store in await openPanel(store) },
        Scenario(name: "08d-panel-cpu-open", module: .monitor, panel: .cpu) { store in await openPanel(store, sections: ["cpu.apps"]) },
        Scenario(name: "08e-panel-memory", module: .monitor, panel: .memory) { store in await openPanel(store) },
        Scenario(name: "08f-panel-memory-open", module: .monitor, panel: .memory) { store in await openPanel(store, sections: ["memory.apps"]) },
        Scenario(name: "08g-panel-temperature", module: .monitor, panel: .temperature) { store in await openPanel(store) },
        Scenario(name: "08h-panel-temperature-open", module: .monitor, panel: .temperature) { store in await openPanel(store, sections: ["temperature.sensors"]) },
        Scenario(name: "08-monitor", module: .monitor) { store in
            store.monitor.start()
            await wait(0.3)
        },
        // Real readings from this Mac, so the output differs per machine; for eyeballing the layout with live numbers.
        Scenario(name: "08b-monitor-live", module: .monitor, services: .mockWithLiveMetrics) { store in
            store.monitor.start()
            await wait(5)
        },
        Scenario(name: "09-history", module: .history),
        // Two runs opened: one with an item already put back, one to put back from.
        Scenario(name: "09b-history-expanded", module: .history) { store in
            await store.loadHistory()
            for run in store.history.prefix(1) + store.history.filter({ $0.restoredCount > 0 }) { store.historyModel.expanded.insert(run.id) }
        },
        // After "Put Back" on the first run: the summary and the new status of its items.
        Scenario(name: "09c-history-put-back", module: .history) { store in
            await store.loadHistory()
            guard let run = store.history.first else { return }
            store.historyModel.expanded.insert(run.id)
            await store.historyModel.askPutBack(store.historyModel.restorable(in: run), of: run.id)
            store.historyModel.confirmPutBack()
            await store.historyModel.finishPuttingBack()
        },
        Scenario(name: "10-settings", module: .settings),
        // The lower half of the form: installer folders, permissions and the reset button.
        Scenario(name: "10b-settings-lower", module: .settings, view: {
            let store = AppStore(services: .mock)
            return AnyView(
                SettingsView(store: store)
                    .frame(width: 1120, height: 1800)
                    .offset(y: -820)
                    .frame(width: 1120, height: 740, alignment: .top)
                    .clipped()
                    .background(.background)
            )
        }),
        Scenario(name: "11a-onboarding-welcome", module: .settings, view: onboarding(.welcome)),
        Scenario(name: "11b-onboarding-full-disk-access", module: .settings, view: onboarding(.fullDiskAccess)),
        Scenario(name: "11c-onboarding-app-management", module: .settings, view: onboarding(.appManagement)),
        Scenario(name: "11d-onboarding-admin-rule", module: .settings, view: onboarding(.adminRule)),
        Scenario(name: "12-about", module: .settings, view: {
            AnyView(AboutView().background(.background).frame(width: 1120, height: 740))
        }),
    ]

    private static func openPanel(_ store: AppStore, sections: Set<String> = []) async {
        store.monitor.setIndicatorRefresh(seconds: 2, temperature: true)
        store.monitor.start()
        store.monitor.expandedPanelSections = sections
        await wait(2)
    }

    private static func onboarding(_ step: OnboardingModel.Step) -> @MainActor () -> AnyView {
        {
            let store = AppStore(services: .mock)
            return AnyView(
                OnboardingView(permissions: store.permissions, adminRule: store.adminRule, initialStep: step, onFinish: {})
                    .background(.background)
                    .frame(width: 1120, height: 740)
            )
        }
    }

    static func runIfRequested() {
        guard let path = UserDefaults.standard.string(forKey: "LivSnapshotDir") else { return }
        let directory = URL(fileURLWithPath: path)
        Task { @MainActor in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (suffix, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for scenario in scenarios {
                    let store = AppStore(services: scenario.services)
                    await scenario.prepare(store)
                    await render(scenario, store: store, appearance: appearance, to: directory.appending(path: "\(scenario.name)-\(suffix).png"))
                }
            }
            exit(0)
        }
    }

    private static func render(_ scenario: Scenario, store: AppStore, appearance: NSAppearance.Name, to url: URL) async {
        let root = scenario.panel.map { AnyView(IndicatorPanelView(store: store, metric: $0).background(.background)) }
            ?? scenario.view?()
            ?? AnyView(RootView(selection: scenario.module, store: store))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: CGRect(origin: CGPoint(x: -10_000, y: -10_000), size: scenario.panel == nil ? size : host.fittingSize),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        await wait(0.8)
        host.layoutSubtreeIfNeeded()
        if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }

    private static func wait(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}

extension ServiceContainer {
    /// Everything simulated, with cleaning that reports a failure and a skipped item.
    static var mockWithCleaningProblems: ServiceContainer {
        var services = ServiceContainer.mock
        services.cleanup = MockCleanupScanner(simulatesProblems: true)
        return services
    }

    /// Everything simulated, with the admin rule already installed.
    static var mockWithAdminRule: ServiceContainer {
        var services = ServiceContainer.mock
        services.privileged = MockPrivileged(ruleInstalled: true)
        return services
    }

    /// Everything simulated except the system metrics.
    static var mockWithLiveMetrics: ServiceContainer {
        var services = ServiceContainer.mock
        services.metrics = LiveMetrics()
        return services
    }
}
#endif

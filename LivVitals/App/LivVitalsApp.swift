import AppKit
import LivCore
import SwiftUI

@main
struct LivVitalsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store: AppStore
    /// Hides the Dock icon when the window is closed. Absent under tests, which must not change the host app.
    @State private var dock: DockPresence?

    /// `-LivStartModule monitor` opens that module first, so `scripts/monitor-cpu-probe.sh` can measure it without clicking.
    /// Only in Debug and probe builds; the shipping app always starts on Smart Care.
    private static var startModule: AppModule {
        #if DEBUG || PERF_PROBE
        UserDefaults.standard.string(forKey: "LivStartModule").flatMap(AppModule.init(rawValue:)) ?? .smartCare
        #else
        .smartCare
        #endif
    }

    init() {
        // Hosting unit tests must never read or write the user's real files or start live sampling.
        let isTesting = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
        // First launch after the rename from Liv Cleaner: copy (never move) its settings and history. Never under tests.
        if !isTesting { _ = try? DataFolderMigration.run() }
        let store = AppStore(services: isTesting ? .mock : .live)
        _store = State(initialValue: store)
        _dock = State(initialValue: isTesting ? nil : DockPresence(
            hideFromDock: { store.settings.hideFromDockWhenClosed },
            menuBarShown: { store.settings.hasMenuBarContent }
        ))
        #if DEBUG
        DebugSnapshots.runIfRequested()
        #endif
        #if DEBUG || PERF_PROBE
        PerfProbe.runIfRequested()
        #endif
    }

    var body: some Scene {
        // One main window, so the menu bar widget can bring it back with `openWindow(id: "main")`.
        Window("Liv Vitals", id: "main") {
            RootView(selection: Self.startModule, store: store)
                .frame(minWidth: 980, minHeight: 640)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1120, height: 740)
        .windowResizability(.contentMinSize)

        MenuBarExtra(
            isInserted: Binding(
                get: { store.settings.showMenuBarExtra },
                set: { store.settings.showMenuBarExtra = $0 }
            )
        ) {
            MenuBarView(store: store)
        } label: {
            Image(systemName: "sparkles")
        }
        .menuBarExtraStyle(.window)

        // One menu bar item per metric, each inserted by its own setting (all off until the user turns them on).
        Group {
            IndicatorScene(store: store, metric: .cpu)
            IndicatorScene(store: store, metric: .memory)
            IndicatorScene(store: store, metric: .gpu)
            IndicatorScene(store: store, metric: .disk)
            IndicatorScene(store: store, metric: .diskActivity)
            IndicatorScene(store: store, metric: .network)
            IndicatorScene(store: store, metric: .battery)
        }

        Window("About Liv Vitals", id: "about") {
            AboutView()
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .appInfo) { AboutCommand() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// With anything in the menu bar (the health icon or an indicator), closing the window leaves the app running there.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        let settings = SettingsStore.standard().load()
        return !(settings.showMenuBarExtra || settings.indicators.contains { $0.enabled })
    }
}

private struct AboutCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("About Liv Vitals") {
            openWindow(id: "about")
            NSApp.activate()
        }
    }
}

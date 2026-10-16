import SwiftUI

struct RootView: View {
    @State private var selection: AppModule
    @State private var store: AppStore

    init(selection: AppModule = .smartCare, store: AppStore) {
        _selection = State(initialValue: selection)
        _store = State(initialValue: store)
    }

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(selection: $selection)
                .frame(width: 220)
            Divider().opacity(0.4)
            ModuleContent(module: selection, store: store)
                .id(selection)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(ModuleBackground(theme: selection.theme))
        .motion(.easeInOut(duration: 0.35), value: selection)
        .environment(\.showsPreviewData, store.showsPreviewData(for: selection))
        .onChange(of: store.requestedModule, initial: true) { _, requested in
            guard let requested else { return }
            selection = requested
            store.requestedModule = nil
        }
        .task { await store.loadHistory() }
        .sheet(isPresented: Binding(
            get: { store.isWelcomeGuideVisible },
            set: { if !$0 { store.closeWelcomeGuide() } }
        )) {
            OnboardingView(permissions: store.permissions, adminRule: store.adminRule, onFinish: store.closeWelcomeGuide)
        }
    }
}

/// Routes each module to its screen.
private struct ModuleContent: View {
    let module: AppModule
    let store: AppStore

    var body: some View {
        switch module {
        case .smartCare, .cleanup, .devProjects, .installers, .applications:
            ScanFlowView(model: store.scanFlow(for: module), permissions: store.permissions)
        case .performance:
            PerformanceView(model: store.performance, adminRule: store.adminRule, startup: store.startupItems)
        case .spaceLens:
            SpaceLensView(model: store.spaceLens, permissions: store.permissions)
        case .monitor:
            MonitorView(model: store.monitor)
        case .history:
            HistoryView(store: store)
        case .settings:
            SettingsView(store: store)
        }
    }
}

#Preview {
    RootView(store: AppStore(services: .mock)).frame(width: 1100, height: 720)
}

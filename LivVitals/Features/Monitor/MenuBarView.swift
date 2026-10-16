import AppKit
import SwiftUI

/// The popover of the menu bar widget. It samples only while it is open.
struct MenuBarView: View {
    let store: AppStore

    @Environment(\.openWindow) private var openWindow

    private var monitor: MonitorModel { store.monitor }
    private let theme = AppModule.monitor.theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                ZStack {
                    ProgressRing(progress: Double(monitor.healthScore) / 100, theme: theme, lineWidth: 6)
                    Text("\(monitor.healthScore)")
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .contentTransition(.numericText())
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Mac Health").font(.caption).foregroundStyle(.secondary)
                    Text(monitor.healthTitle).font(.headline)
                }
            }

            Divider()

            VStack(spacing: 8) {
                row("CPU", "\(Int(monitor.cpuNow))%", systemImage: "cpu")
                row("Memory", String(format: "%.1f of %.0f GB", monitor.memoryUsedGB, monitor.memoryTotalGB), systemImage: "memorychip")
                row("Disk", String(format: "%.0f GB free", monitor.diskFreeGB), systemImage: "internaldrive")
                row("Network", "↓ \(monitor.downloadText)  ↑ \(monitor.uploadText)", systemImage: "network")
            }

            Divider()

            HStack {
                Button("Open Liv Vitals") {
                    DockPresence.showInDock()
                    openWindow(id: "main")
                    NSApp.activate()
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 300)
        .onAppear(perform: monitor.start)
        .onDisappear(perform: monitor.stop)
    }

    private func row(_ title: LocalizedStringKey, _ value: String, systemImage: String) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
            Spacer()
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }
}

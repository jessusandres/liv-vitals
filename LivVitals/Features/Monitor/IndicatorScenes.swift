import AppKit
import Charts
import LivCore
import SwiftUI

/// One menu bar item for one metric. There are seven, declared in `LivVitalsApp`; each is inserted or removed by its
/// setting, the way the health icon is. Dragging one out of the bar with ⌘ turns the setting off.
struct IndicatorScene: Scene {
    let store: AppStore
    let metric: MetricKind

    var body: some Scene {
        MenuBarExtra(
            isInserted: Binding(
                get: { store.settings.indicator(metric).enabled },
                set: { value in store.settings.updateIndicator(metric) { $0.enabled = value } }
            )
        ) {
            IndicatorPanelView(store: store, metric: metric)
        } label: {
            IndicatorLabel(store: store, metric: metric)
        }
        .menuBarExtraStyle(.window)
    }
}

/// The picture in the menu bar, read aloud as the number it shows.
struct IndicatorLabel: View {
    let store: AppStore
    let metric: MetricKind

    var body: some View {
        let setting = store.settings.indicator(metric)
        let value = IndicatorFormatter.value(metric, from: store.monitor.latest)
        let image = IndicatorImageRenderer.image(for: setting, value: value, history: store.monitor.series[metric] ?? [])
        Image(nsImage: image)
            .accessibilityLabel(value.spoken)
    }
}

/// The panel that opens from an indicator: the number, what it is made of, the recent past, and the way back to the app.
struct IndicatorPanelView: View {
    let store: AppStore
    let metric: MetricKind

    @Environment(\.openWindow) private var openWindow

    private var monitor: MonitorModel { store.monitor }
    private var snapshot: MetricsSnapshot? { monitor.latest }
    private var value: IndicatorValue { IndicatorFormatter.value(metric, from: snapshot) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Label(metric.localizedTitle, systemImage: metric.symbol).font(.headline)
                Spacer()
                Text(value.text).font(.title2.weight(.semibold).monospacedDigit())
                if let secondary = value.secondary {
                    Text(secondary).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(value.spoken)

            history

            VStack(spacing: 6) { details }
                .font(.callout)

            Divider()

            HStack {
                Button("Open Liv Vitals") { open(.monitor) }
                Button("Configure…") { open(.settings) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 320)
        .onAppear(perform: monitor.start)
        .onDisappear(perform: monitor.stop)
    }

    private func open(_ module: AppModule) {
        store.requestedModule = module
        DockPresence.showInDock()
        openWindow(id: "main")
        NSApp.activate()
    }

    // MARK: - The recent past

    @ViewBuilder private var history: some View {
        let values = monitor.series[metric] ?? []
        let ceiling = metric.isThroughput ? max(values.max() ?? 1, 1) : 100
        Chart(Array(values.enumerated()), id: \.offset) { index, point in
            AreaMark(x: .value("Time", index), y: .value("Value", point))
                .foregroundStyle(LinearGradient(colors: [metric.color.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
            LineMark(x: .value("Time", index), y: .value("Value", point))
                .foregroundStyle(metric.color)
        }
        .chartYScale(domain: 0...ceiling)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .frame(height: 56)
        .accessibilityHidden(true)
    }

    // MARK: - What it is made of

    @ViewBuilder private var details: some View {
        switch metric {
        case .cpu:
            row("Now", value.text)
            row("Average (10 s)", percent(snapshot?.cpuAverage))
        case .memory:
            if let memory = snapshot?.memory {
                row("App", gigabytes(memory.appBytes))
                row("Wired", gigabytes(memory.wiredBytes))
                row("Compressed", gigabytes(memory.compressedBytes))
                row("Cached files", gigabytes(memory.cachedBytes))
                row("Pressure", monitor.memoryPressureTitle)
                row("Available", String(format: "%.1f GB", monitor.memoryAvailableGB))
            }
        case .gpu:
            if let device = snapshot?.gpu?.active {
                row("Device", device.name)
                if let renderer = device.renderer { row("Renderer", percent(renderer)) }
                if let tiler = device.tiler { row("Tiler", percent(tiler)) }
            } else {
                Text("This Mac does not report GPU activity.").foregroundStyle(.secondary)
            }
        case .disk:
            if let disk = snapshot?.disk {
                row("Used", decimalGigabytes(disk.usedBytes))
                row("Free", decimalGigabytes(disk.availableBytes))
                row("Total", decimalGigabytes(disk.totalBytes))
            }
        case .diskActivity:
            if let activity = snapshot?.diskActivity {
                row("Read", IndicatorFormatter.rate(activity.readBytesPerSecond))
                row("Write", IndicatorFormatter.rate(activity.writeBytesPerSecond))
            } else {
                Text("This Mac does not report disk activity.").foregroundStyle(.secondary)
            }
        case .network:
            row("Download", monitor.downloadText)
            row("Upload", monitor.uploadText)
        case .battery:
            if let battery = snapshot?.battery {
                row("Status", battery.isCharging ? String(localized: "Charging") : battery.isOnACPower ? String(localized: "On power adapter") : String(localized: "On battery"))
                row("Health", battery.health.map(percent) ?? "—")
                row("Cycle count", battery.cycleCount.map(String.init) ?? "—")
            } else {
                Text("This Mac has no battery.").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ text: String) -> some View {
        LabeledContent(title) { Text(text).monospacedDigit().foregroundStyle(.secondary) }
    }

    private func percent(_ fraction: Double?) -> String {
        guard let fraction else { return "—" }
        return "\(Int((fraction * 100).rounded()))%"
    }

    /// Binary gigabytes, as Activity Monitor shows memory.
    private func gigabytes(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }

    /// Decimal gigabytes, as Finder shows disk space.
    private func decimalGigabytes(_ bytes: UInt64) -> String {
        String(format: "%.0f GB", Double(bytes) / 1e9)
    }
}

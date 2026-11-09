import AppKit
import Charts
import LivCore
import SwiftUI

/// One menu bar item for one metric. There are eight, declared in `LivVitalsApp`; each is inserted or removed by its
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
        let value = IndicatorFormatter.value(metric, from: store.monitor.latest, showTemperature: setting.showTemperature)
        let image = IndicatorImageRenderer.image(for: setting, value: value, history: store.monitor.series[metric] ?? [])
        Image(nsImage: image)
            .accessibilityLabel(value.spoken)
    }
}

/// The panel that opens from an indicator: the number, what it is made of, the recent past, and the way back to the app.
/// Details sit in sections that start folded; which ones are open is remembered for the session by `MonitorModel`.
struct IndicatorPanelView: View {
    let store: AppStore
    let metric: MetricKind

    @Environment(\.openWindow) private var openWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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

            if let fraction = value.fraction {
                // Drawn by hand: ProgressView turns gray whenever its window is not key.
                Capsule().fill(.quaternary)
                    .overlay(alignment: .leading) {
                        GeometryReader { Capsule().fill(metric.color).frame(width: $0.size.width * min(max(fraction, 0), 1)) }
                    }
                    .frame(height: 6)
                    .accessibilityHidden(true)
            }

            if metric == .temperature, let reading = snapshot?.temperature { temperatureTiles(reading) }

            history

            VStack(alignment: .leading, spacing: 8) { details }
                .font(.callout)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: monitor.expandedPanelSections)

            Divider()

            HStack {
                Button("Open Liv Vitals") { open(.monitor) }
                Button("Configure…") { open(.settings) }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(16)
        .frame(width: 340)
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
        let ceiling = metric.isThroughput ? max(values.max() ?? 1, 1) : max(100, values.max() ?? 0)
        let showsGuide = !metric.isThroughput && metric != .temperature
        Chart {
            ForEach(Array(values.enumerated()), id: \.offset) { index, point in
                AreaMark(x: .value("Time", index), y: .value("Value", point))
                    .foregroundStyle(LinearGradient(colors: [metric.color.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", index), y: .value("Value", point))
                    .foregroundStyle(metric.color)
            }
            if showsGuide {
                RuleMark(y: .value("Maximum", 100))
                    .lineStyle(StrokeStyle(lineWidth: 0.5, dash: [3, 3]))
                    .foregroundStyle(.secondary.opacity(0.35))
                    .annotation(position: .overlay, alignment: .topLeading, spacing: 0) {
                        Text("100%").font(.system(size: 8).monospacedDigit()).foregroundStyle(.secondary)
                    }
            }
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
            section("apps", "Top apps") { processList(monitor.processes, showing: .cpu) }
        case .memory:
            if let memory = snapshot?.memory {
                row("App", gigabytes(memory.appBytes))
                row("Wired", gigabytes(memory.wiredBytes))
                row("Compressed", gigabytes(memory.compressedBytes))
                row("Cached files", gigabytes(memory.cachedBytes))
                LabeledContent("Pressure") { PressurePill(pressure: memory.pressure, title: monitor.memoryPressureTitle) }
                row("Available", String(format: "%.1f GB", monitor.memoryAvailableGB))
            }
            section("apps", "Top apps") { processList(monitor.memoryProcesses, showing: .memory) }
        case .gpu:
            if let device = snapshot?.gpu?.active {
                row("Device", device.name)
                if let renderer = device.renderer { row("Renderer", percent(renderer)) }
                if let tiler = device.tiler { row("Tiler", percent(tiler)) }
                section("gpus", "GPUs") {
                    ForEach(snapshot?.gpu?.devices ?? [], id: \.id) { device in
                        row(LocalizedStringKey(device.name), [percent(device.utilization), device.memoryBytes.map(gigabytes)].compactMap { $0 }.joined(separator: " · "))
                    }
                }
            } else {
                Text("This Mac does not report GPU activity.").foregroundStyle(.secondary)
            }
        case .disk:
            if let disk = snapshot?.disk {
                row("Used", decimalGigabytes(disk.usedBytes))
                row("Free", decimalGigabytes(disk.availableBytes))
                row("Total", decimalGigabytes(disk.totalBytes))
            }
            section("activity", "Activity") {
                if let activity = snapshot?.diskActivity {
                    row("Read", IndicatorFormatter.rate(activity.readBytesPerSecond))
                    row("Write", IndicatorFormatter.rate(activity.writeBytesPerSecond))
                } else {
                    Text("This Mac does not report disk activity.").foregroundStyle(.secondary)
                }
            }
        case .diskActivity:
            if let activity = snapshot?.diskActivity {
                row("Read", IndicatorFormatter.rate(activity.readBytesPerSecond))
                row("Write", IndicatorFormatter.rate(activity.writeBytesPerSecond))
            } else {
                Text("This Mac does not report disk activity.").foregroundStyle(.secondary)
            }
            if let disk = snapshot?.disk {
                section("storage", "Storage") {
                    row("Used", decimalGigabytes(disk.usedBytes))
                    row("Free", decimalGigabytes(disk.availableBytes))
                }
            }
        case .network:
            row("Download", monitor.downloadText)
            row("Upload", monitor.uploadText)
            section("minute", "Last minute") {
                let values = monitor.series[.network] ?? []
                row("Peak", IndicatorFormatter.rate(values.max() ?? 0))
                row("Average", IndicatorFormatter.rate(values.isEmpty ? 0 : values.reduce(0, +) / Double(values.count)))
            }
        case .battery:
            if let battery = snapshot?.battery {
                row("Status", battery.isCharging ? String(localized: "Charging") : battery.isOnACPower ? String(localized: "On power adapter") : String(localized: "On battery"))
                section("details", "Details") {
                    row("Health", battery.health.map(percent) ?? "—")
                    row("Cycle count", battery.cycleCount.map(String.init) ?? "—")
                }
            } else {
                Text("This Mac has no battery.").foregroundStyle(.secondary)
            }
        case .temperature:
            if let reading = snapshot?.temperature {
                section("sensors", "Sensors") {
                    if reading.sensors.isEmpty {
                        Text("No sensor details available.").foregroundStyle(.secondary)
                    }
                    // A Mac reports a hundred or more sensors, so the list scrolls instead of growing the panel.
                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(reading.sensors, id: \.name) { sensor in
                                HStack {
                                    Text(verbatim: sensor.name)
                                    Spacer()
                                    Text(celsius(sensor.celsius)).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                        .padding(.trailing, 12)
                    }
                    .frame(maxHeight: 220)
                }
            } else {
                Text("Temperatures are not available on this Mac.").foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ title: LocalizedStringKey, _ text: String) -> some View {
        LabeledContent(title) { Text(text).monospacedDigit().foregroundStyle(.secondary) }
            .accessibilityElement(children: .combine)
    }

    /// A fold that starts closed. VoiceOver hears its expanded or collapsed state from the native disclosure control.
    private func section<Content: View>(_ id: String, _ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        let key = "\(metric.rawValue).\(id)"
        let body = content()
        let isExpanded = Binding(
            get: { monitor.expandedPanelSections.contains(key) },
            set: { open in
                if open { monitor.expandedPanelSections.insert(key) } else { monitor.expandedPanelSections.remove(key) }
            }
        )
        return DisclosureGroup(isExpanded: isExpanded) {
            VStack(alignment: .leading, spacing: 6) { body }.padding(.top, 6)
        } label: {
            // The whole row toggles, not only the small chevron.
            Button { isExpanded.wrappedValue.toggle() } label: {
                Text(title).font(.callout.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private enum ProcessValue { case cpu, memory }

    /// The busiest apps. The list is empty in light mode and for the first second of full mode, so it says so.
    @ViewBuilder private func processList(_ processes: [ProcessUsage], showing kind: ProcessValue) -> some View {
        if processes.isEmpty {
            Text("Loading…").foregroundStyle(.secondary)
        }
        ForEach(processes) { process in
            let text = switch kind {
            case .cpu: String(format: "%.0f%%", process.cpuPercent)
            case .memory: ByteCountFormatter.string(fromByteCount: Int64(process.memoryBytes), countStyle: .memory)
            }
            HStack(spacing: 8) {
                SystemIcon(image: monitor.icons.icon(for: process), size: 16)
                Text(process.name).lineLimit(1)
                Spacer()
                Text(text).monospacedDigit().foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(process.name), \(text)")
        }
    }

    // MARK: - Temperature

    private func temperatureTiles(_ reading: TemperatureReading) -> some View {
        HStack(spacing: 8) {
            TemperatureTile(title: "CPU", symbol: "cpu", text: celsius(reading.cpu))
            TemperatureTile(title: "GPU", symbol: "display", text: celsius(reading.gpu))
            if reading.battery != nil {
                TemperatureTile(title: "Battery", symbol: "battery.100percent", text: celsius(reading.battery))
            }
        }
    }

    private func celsius(_ degrees: Double?) -> String {
        degrees.map { "\(Int($0.rounded()))°" } ?? "—"
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

/// Memory pressure as a small colored pill, the way Activity Monitor colors its graph.
private struct PressurePill: View {
    let pressure: MemoryPressure
    let title: String

    private var color: Color {
        switch pressure {
        case .normal: .green
        case .warning: .yellow
        case .critical: .red
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(color.opacity(0.18), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
    }
}

/// One temperature, big, under a small label.
private struct TemperatureTile: View {
    let title: LocalizedStringKey
    let symbol: String
    let text: String

    var body: some View {
        VStack(spacing: 2) {
            Label(title, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
            Text(text).font(.title3.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

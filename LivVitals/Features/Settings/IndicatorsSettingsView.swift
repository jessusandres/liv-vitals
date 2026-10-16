import AppKit
import LivCore
import LivWidgetsUI
import SwiftUI

/// Settings › Menu Bar Indicators: which readings appear in the menu bar, and how.
struct IndicatorsSettingsSection: View {
    let settings: AppSettings
    let monitor: MonitorModel

    var body: some View {
        @Bindable var settings = settings
        Section {
            ForEach(MetricKind.allCases) { metric in
                IndicatorRow(settings: settings, monitor: monitor, metric: metric)
            }
            Picker("Refresh every", selection: $settings.indicatorRefresh) {
                ForEach(IndicatorSetting.refreshChoices, id: \.self) { seconds in
                    Text("\(seconds) s").tag(seconds)
                }
            }
        } header: {
            Text("Menu Bar Indicators")
                .onAppear(perform: monitor.start)
                .onDisappear(perform: monitor.stop)
        } footer: {
            Text("Each one is a separate item in the menu bar. Hold ⌘ and drag to rearrange them. They are off until you turn them on.")
        }
    }
}

private struct IndicatorRow: View {
    let settings: AppSettings
    let monitor: MonitorModel
    let metric: MetricKind

    private var current: IndicatorSetting { settings.indicator(metric) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(
                get: { current.enabled },
                set: { value in settings.updateIndicator(metric) { $0.enabled = value } }
            )) {
                Label(metric.localizedTitle, systemImage: metric.symbol)
            }
            if current.enabled {
                IndicatorPreview(
                    image: IndicatorImageRenderer.image(
                        for: current,
                        value: IndicatorFormatter.value(metric, from: monitor.latest),
                        history: monitor.series[metric] ?? []
                    )
                )
                .padding(.leading, 28)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(IndicatorFormatter.value(metric, from: monitor.latest).spoken)
                HStack(spacing: 14) {
                    Picker("Style", selection: Binding(
                        get: { current.style },
                        set: { value in settings.updateIndicator(metric) { $0.style = value } }
                    )) {
                        ForEach(metric.styles) { style in Text(style.localizedTitle).tag(style) }
                    }
                    Picker("Color", selection: Binding(
                        get: { current.tint },
                        set: { value in settings.updateIndicator(metric) { $0.tint = value } }
                    )) {
                        ForEach(IndicatorTint.allCases) { tint in Text(tint.localizedTitle).tag(tint) }
                    }
                    Toggle("Label", isOn: Binding(
                        get: { current.showLabel },
                        set: { value in settings.updateIndicator(metric) { $0.showLabel = value } }
                    ))
                    .toggleStyle(.checkbox)
                }
                .padding(.leading, 28)
            }
        }
    }
}

/// Settings › Desktop Widgets: the three widgets that stay, whether each is added, how to add them, and a refresh button.
struct DesktopWidgetsSettingsSection: View {
    let monitor: MonitorModel
    let model: DesktopWidgetsModel

    private let columns = [GridItem(.adaptive(minimum: 190), spacing: 12)]

    var body: some View {
        Section {
            Text("Widgets refresh about every 15 minutes, and macOS decides when, so they only show values that change slowly: battery health, storage and device facts. For live values (CPU, memory, GPU, disk activity, network), use the menu bar indicators above.")
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("How to add a widget")
                    .font(.headline)
                Text("1. Right-click the desktop (or click the date in the menu bar to open Notification Center).")
                Text("2. Choose Edit Widgets.")
                Text("3. Search for Liv Vitals.")
                Text("4. Pick Battery Health, Storage or Device, then click it or drag it onto the desktop.")
                Text("Widgets cannot be added from this app; macOS only lets you add them from Edit Widgets.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(WidgetKind.allCases) { kind in
                    VStack(alignment: .leading, spacing: 4) {
                        WidgetFace(kind: kind, entry: LivWidgetEntry(date: .now, snapshot: monitor.latest, device: DeviceInfo.read()))
                            .padding(12)
                            .frame(width: 329, height: 155)
                            .background(.background, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .scaleEffect(0.55, anchor: .topLeading)
                            .frame(width: 181, height: 86, alignment: .topLeading)
                        Text(kind.title).font(.caption).foregroundStyle(.secondary)
                        PlacementLabel(placement: model.placement(of: kind))
                    }
                }
            }
            LabeledContent("Reload every widget now. macOS may still take a moment.") {
                Button("Refresh widgets") { Task { await model.refreshWidgets() } }
            }
        } header: {
            Text("Desktop Widgets")
        }
        .task { await model.refreshStatus() }
    }
}

/// "Added" or "Not added" under a widget preview; nothing when macOS could not say.
private struct PlacementLabel: View {
    let placement: WidgetPlacement

    var body: some View {
        switch placement {
        case .added:
            Label("Added", systemImage: "checkmark.circle.fill")
                .font(.caption2)
                .foregroundStyle(.green)
        case .notAdded:
            Label("Not added", systemImage: "circle.dashed")
                .font(.caption2)
                .foregroundStyle(.secondary)
        case .unknown:
            Label("Status unavailable", systemImage: "questionmark.circle")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

/// The image the menu bar shows, drawn here too so the preview is the real thing. A template image takes the text color.
private struct IndicatorPreview: View {
    let image: NSImage

    var body: some View {
        Image(nsImage: image)
            .renderingMode(image.isTemplate ? .template : .original)
            .foregroundStyle(.primary)
    }
}

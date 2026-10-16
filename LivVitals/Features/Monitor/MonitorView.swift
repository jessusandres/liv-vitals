import AppKit
import LivCore
import Charts
import Observation
import SwiftUI
import UniformTypeIdentifiers

struct MonitorView: View {
    let model: MonitorModel

    private let module = AppModule.monitor
    private let columns = [GridItem(.flexible(), spacing: 12), GridItem(.flexible(), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                ModuleHeader(module: module) { healthBadge }
                LazyVGrid(columns: columns, spacing: 12) {
                    cpuCard
                    memoryCard
                    networkCard
                    diskCard
                    batteryCard
                    processesCard
                }
            }
            .padding(28)
        }
        .scrollIndicators(.never)
        .onAppear(perform: model.start)
        .onDisappear(perform: model.stop)
    }

    private var healthBadge: some View {
        HStack(spacing: 10) {
            ZStack {
                ProgressRing(progress: Double(model.healthScore) / 100, theme: module.theme, lineWidth: 6, label: "Health score")
                Text("\(model.healthScore)")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
            }
            .frame(width: 46, height: 46)
            VStack(alignment: .leading) {
                Text("Health").font(.caption).foregroundStyle(.secondary)
                Text(model.healthTitle)
                    .font(.headline)
            }
        }
    }

    private var cpuCard: some View {
        MetricCard(title: "CPU", systemImage: "cpu", value: "\(Int(model.cpuNow))%") {
            Chart(model.cpu) { sample in
                AreaMark(x: .value("Time", sample.id), y: .value("Load", sample.value))
                    .foregroundStyle(
                        LinearGradient(colors: [module.theme.start.opacity(0.5), .clear], startPoint: .top, endPoint: .bottom)
                    )
                LineMark(x: .value("Time", sample.id), y: .value("Load", sample.value))
                    .foregroundStyle(module.theme.start)
            }
            .chartYScale(domain: 0...100)
            .chartXAxis(.hidden)
            .chartYAxis { AxisMarks(values: [0, 50, 100]) }
            .frame(height: 110)
        }
    }

    private var memoryCard: some View {
        MetricCard(
            title: "Memory",
            systemImage: "memorychip",
            value: String(format: "%.1f of %.0f GB", model.memoryUsedGB, model.memoryTotalGB)
        ) {
            HStack(spacing: 18) {
                Gauge(value: model.memoryUsedFraction) {
                    Text("Used")
                } currentValueLabel: {
                    Text(model.memoryUsedFraction, format: .percent.precision(.fractionLength(0)))
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(module.theme.gradient)
                .scaleEffect(1.3)
                .frame(width: 80, height: 80)
                VStack(alignment: .leading, spacing: 3) {
                    LabeledContent("App", value: String(format: "%.1f GB", model.memoryAppGB))
                    LabeledContent("Wired", value: String(format: "%.1f GB", model.memoryWiredGB))
                    LabeledContent("Compressed", value: String(format: "%.1f GB", model.memoryCompressedGB))
                    LabeledContent("Pressure", value: model.memoryPressureTitle)
                    LabeledContent("Available", value: String(format: "%.1f GB", model.memoryAvailableGB))
                }
            }
            .frame(height: 110)
        }
    }

    private var networkCard: some View {
        let points = model.download.map { NetworkPoint(direction: "Download", sample: $0) }
            + model.upload.map { NetworkPoint(direction: "Upload", sample: $0) }
        return MetricCard(
            title: "Network",
            systemImage: "network",
            value: "↓ \(model.downloadText)  ↑ \(model.uploadText)"
        ) {
            Chart(points) { point in
                LineMark(x: .value("Time", point.sample.id), y: .value("MB/s", point.sample.value))
                    .foregroundStyle(by: .value("Direction", point.direction))
                    .interpolationMethod(.catmullRom)
            }
            .chartForegroundStyleScale(["Download": module.theme.start, "Upload": Color.orange])
            .chartXAxis(.hidden)
            .chartLegend(position: .bottom, alignment: .leading)
            .frame(height: 110)
        }
    }

    private var diskCard: some View {
        MetricCard(
            title: "Disk",
            systemImage: "internaldrive",
            value: String(format: "%.0f GB free", model.diskFreeGB)
        ) {
            VStack(alignment: .leading, spacing: 10) {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.primary.opacity(0.1))
                        Capsule().fill(module.theme.gradient)
                            .frame(width: proxy.size.width * model.diskUsedFraction)
                    }
                }
                .frame(height: 8)
                Text(String(format: "%.0f GB used of %.0f GB", model.diskUsedGB, model.diskTotalGB))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Label("Space Lens shows what takes up this space.", systemImage: "circle.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(height: 110, alignment: .top)
        }
    }

    @ViewBuilder private var batteryCard: some View {
        if let battery = model.battery {
            MetricCard(
                title: "Battery",
                systemImage: battery.isCharging ? "battery.100.bolt" : "battery.75percent",
                value: battery.level.formatted(.percent.precision(.fractionLength(0)))
            ) {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Status", value: battery.isCharging ? "Charging" : battery.isOnACPower ? "On power adapter" : "On battery")
                    LabeledContent("Health", value: battery.health.map { $0.formatted(.percent.precision(.fractionLength(0))) } ?? "—")
                    LabeledContent("Cycle count", value: battery.cycleCount.map(String.init) ?? "—")
                }
                .frame(height: 110, alignment: .top)
            }
        } else {
            MetricCard(title: "Battery", systemImage: "powerplug", value: "") {
                Text("This Mac has no battery.")
                    .foregroundStyle(.secondary)
                    .frame(height: 110, alignment: .topLeading)
            }
        }
    }

    private var processesCard: some View {
        MetricCard(title: "Top Processes", systemImage: "list.bullet", value: "") {
            VStack(spacing: 6) {
                ForEach(model.processes) { process in
                    HStack {
                        SystemIcon(image: model.icons.icon(for: process), size: 16)
                        Text(process.name).lineLimit(1)
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: Int64(process.memoryBytes), countStyle: .memory))
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                        Text(String(format: "%.0f%%", process.cpuPercent))
                            .monospacedDigit()
                            .frame(width: 44, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
            .frame(height: 110, alignment: .top)
        }
    }
}

/// Download and upload share sample ids, so each point needs its own identity for the chart.
private struct NetworkPoint: Identifiable {
    let direction: String
    let sample: MonitorModel.Sample
    var id: String { "\(direction)-\(sample.id)" }
}

private struct MetricCard<Content: View>: View {
    let title: LocalizedStringKey
    let systemImage: String
    let value: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(title, systemImage: systemImage).font(.headline)
                Spacer()
                Text(value)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            content
        }
        .card()
    }
}

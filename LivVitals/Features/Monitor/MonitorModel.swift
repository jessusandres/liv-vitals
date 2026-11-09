import Foundation
import LivCore
import Observation
import SwiftUI

/// Live system readings for the Monitor screen and the menu bar widget.
///
/// Sampling runs only while something is watching. Each watcher calls `start()` when it appears and `stop()`
/// when it goes away; the window and the widget can be open at once and share one sampler.
@Observable
final class MonitorModel {
    struct Sample: Identifiable {
        let id: Int
        let value: Double
    }

    private static let historyLength = 60
    private static let gibibyte = 1_073_741_824.0

    private(set) var latest: MetricsSnapshot?
    /// Percent, 0...100.
    private(set) var cpu: [Sample] = []
    /// Megabytes per second.
    private(set) var download: [Sample] = []
    private(set) var upload: [Sample] = []
    /// Folds that are open in the menu bar panels, as `"<metric>.<section>"`. Kept while the app runs, not saved.
    var expandedPanelSections: Set<String> = []

    @ObservationIgnored private let service: any MetricsProviding
    @ObservationIgnored private var watchers = 0
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var sampleCount = 0
    @ObservationIgnored let icons = ProcessIconCache()

    init(service: any MetricsProviding) {
        self.service = service
    }

    // MARK: - Watching

    private enum Mode: Equatable {
        /// A window or panel is open: every second, with the busiest processes.
        case full(temperature: Bool, gpu: Bool)
        /// Only menu bar indicators are showing: slower, and no `top` process.
        case light(Duration, temperature: Bool, gpu: Bool)
    }

    @ObservationIgnored private var indicatorInterval: Duration?
    /// Sensors are read only while the temperature indicator is on.
    @ObservationIgnored private var indicatorTemperature = false
    @ObservationIgnored private var indicatorGPUTemperature = false
    @ObservationIgnored private var mode: Mode?

    /// Recent values of every metric, for chart-style indicators and the panels. Percent for most, bytes per second for
    /// network and disk activity.
    private(set) var series: [MetricKind: [Double]] = [:]

    var isSampling: Bool { work != nil }

    /// A window or panel starts watching. Each watcher calls `start()` when it appears and `stop()` when it goes away.
    func start() {
        watchers += 1
        updateSampling()
    }

    func stop() {
        watchers = max(0, watchers - 1)
        updateSampling()
    }

    /// Menu bar indicators keep the readings coming at this interval while they are showing; nil when none is.
    func setIndicatorRefresh(seconds: Int?, temperature: Bool = false, gpuTemperature: Bool = false) {
        indicatorInterval = seconds.map { .seconds($0) }
        indicatorTemperature = temperature
        indicatorGPUTemperature = gpuTemperature
        updateSampling()
    }

    private func updateSampling() {
        let wanted: Mode? = watchers > 0
            ? .full(temperature: indicatorTemperature, gpu: indicatorGPUTemperature)
            : indicatorInterval.map { .light($0, temperature: indicatorTemperature, gpu: indicatorGPUTemperature) }
        guard wanted != mode else { return }
        work?.cancel()
        work = nil
        mode = wanted
        guard let wanted else { return }
        // Opened here, not inside the task, so sampling has begun by the time this returns. A stream that replaces
        // another starts with no rates (the first reading has nothing to compare with), so its first snapshot is skipped.
        let stream = switch wanted {
        case .full(let temperature, let gpu):
            service.snapshots(every: .seconds(1), includeProcesses: true, includeTemperature: temperature, includeGPUTemperature: gpu)
        case .light(let interval, let temperature, let gpu):
            service.snapshots(every: interval, includeProcesses: false, includeTemperature: temperature, includeGPUTemperature: gpu)
        }
        let replacesAReading = latest != nil
        work = Task {
            var skipFirst = replacesAReading
            for await snapshot in stream {
                if skipFirst {
                    skipFirst = false
                    continue
                }
                // No animation: redrawing the whole screen as it eased between values every second cost a core (10.B).
                apply(snapshot)
            }
        }
    }

    private func apply(_ snapshot: MetricsSnapshot) {
        latest = snapshot
        // Light readings carry no processes; keep the last list instead of emptying the Monitor between two modes.
        if !snapshot.topProcesses.isEmpty { icons.keep(only: Set((snapshot.topProcesses + snapshot.topMemoryProcesses).map(\.pid))) }
        sampleCount += 1
        append(&cpu, snapshot.cpu * 100)
        append(&download, snapshot.downloadBytesPerSecond / 1_000_000)
        append(&upload, snapshot.uploadBytesPerSecond / 1_000_000)
        for metric in MetricKind.allCases {
            let value = IndicatorFormatter.value(metric, from: snapshot)
            guard value.isAvailable else { continue }
            var values = series[metric, default: []]
            values.append(value.chartValue)
            if values.count > Self.historyLength { values.removeFirst(values.count - Self.historyLength) }
            series[metric] = values
        }
    }

    private func append(_ series: inout [Sample], _ value: Double) {
        series.append(Sample(id: sampleCount, value: value))
        if series.count > Self.historyLength { series.removeFirst(series.count - Self.historyLength) }
    }

    // MARK: - Values for the views

    var cpuNow: Double { (latest?.cpu ?? 0) * 100 }

    /// Binary gigabytes, as Activity Monitor shows memory.
    var memoryUsedGB: Double { Double(latest?.memory.usedBytes ?? 0) / Self.gibibyte }
    var memoryTotalGB: Double { Double(latest?.memory.totalBytes ?? ProcessInfo.processInfo.physicalMemory) / Self.gibibyte }
    var memoryUsedFraction: Double { latest?.memory.usedFraction ?? 0 }
    var memoryAppGB: Double { Double(latest?.memory.appBytes ?? 0) / Self.gibibyte }
    var memoryWiredGB: Double { Double(latest?.memory.wiredBytes ?? 0) / Self.gibibyte }
    var memoryCompressedGB: Double { Double(latest?.memory.compressedBytes ?? 0) / Self.gibibyte }
    /// Total minus used. It is not free memory: most of it is cached files macOS gives back on demand.
    var memoryAvailableGB: Double { max(0, memoryTotalGB - memoryUsedGB) }

    var memoryPressureTitle: String {
        switch latest?.memory.pressure ?? .normal {
        case .normal: String(localized: "Normal")
        case .warning: String(localized: "Warning")
        case .critical: String(localized: "Critical")
        }
    }

    /// Decimal gigabytes, as Finder shows disk space.
    var diskUsedGB: Double { Double(latest?.disk.usedBytes ?? 0) / 1e9 }
    var diskTotalGB: Double { Double(latest?.disk.totalBytes ?? 0) / 1e9 }
    var diskFreeGB: Double { Double(latest?.disk.availableBytes ?? 0) / 1e9 }
    var diskUsedFraction: Double { latest?.disk.usedFraction ?? 0 }

    var battery: BatteryReading? { latest?.battery }
    var processes: [ProcessUsage] { latest?.topProcesses ?? [] }
    var memoryProcesses: [ProcessUsage] { latest?.topMemoryProcesses ?? [] }

    var healthScore: Int { latest?.health ?? 100 }
    var healthTitle: String { HealthScore.level(for: healthScore).localizedTitle }

    var downloadText: String { Self.rateText(latest?.downloadBytesPerSecond ?? 0) }
    var uploadText: String { Self.rateText(latest?.uploadBytesPerSecond ?? 0) }

    /// `1.2 MB/s`, `340 KB/s`, `0 KB/s`.
    static func rateText(_ bytesPerSecond: Double) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytesPerSecond), countStyle: .decimal) + "/s"
    }
}

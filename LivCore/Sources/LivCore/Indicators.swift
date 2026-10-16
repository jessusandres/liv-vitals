import Foundation

// What the menu bar indicators, their panels and the widgets show. One implementation of the numbers and the text, so
// the three places cannot disagree (the Stage 10 problem). Pure: no UI, no system calls.

public enum MetricKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case cpu, memory, gpu, disk, diskActivity, network, battery

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .cpu: "Processor"
        case .memory: "Memory"
        case .gpu: "GPU"
        case .disk: "Disk"
        case .diskActivity: "Disk Activity"
        case .network: "Network"
        case .battery: "Battery"
        }
    }

    /// The label drawn next to the value in the menu bar.
    public var shortTitle: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "RAM"
        case .gpu: "GPU"
        case .disk: "SSD"
        case .diskActivity: "I/O"
        case .network: "NET"
        case .battery: "BAT"
        }
    }

    public var symbol: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .gpu: "display"
        case .disk: "internaldrive"
        case .diskActivity: "internaldrive.fill"
        case .network: "network"
        case .battery: "battery.100percent"
        }
    }

    /// Network and disk activity are speeds with no natural maximum, so they show as a speed or a chart, not a gauge.
    public var isThroughput: Bool { self == .network || self == .diskActivity }

    public var styles: [IndicatorStyle] {
        isThroughput ? [.speed, .chart, .number, .icon] : [.number, .chart, .bars, .gauge, .icon]
    }

    public var defaultStyle: IndicatorStyle { isThroughput ? .speed : (self == .cpu ? .chart : .number) }
}

public enum IndicatorStyle: String, CaseIterable, Codable, Sendable, Identifiable {
    case icon, number, chart, bars, gauge, speed

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .icon: "Icon"
        case .number: "Number"
        case .chart: "Chart"
        case .bars: "Bars"
        case .gauge: "Gauge"
        case .speed: "Speed"
        }
    }
}

public enum IndicatorTint: String, CaseIterable, Codable, Sendable, Identifiable {
    case system, metric, purple, blue, teal, pink, orange

    public var id: String { rawValue }

    public var title: String { rawValue.capitalized }
}

/// How one metric appears in the menu bar. Every indicator starts off: the user opts in.
public struct IndicatorSetting: Codable, Sendable, Hashable, Identifiable {
    public var metric: MetricKind
    public var enabled: Bool
    public var style: IndicatorStyle
    public var tint: IndicatorTint
    public var showLabel: Bool
    public var showIcon: Bool

    public var id: MetricKind { metric }

    public init(
        metric: MetricKind,
        enabled: Bool = false,
        style: IndicatorStyle? = nil,
        tint: IndicatorTint = .system,
        showLabel: Bool = true,
        showIcon: Bool = false
    ) {
        self.metric = metric
        self.enabled = enabled
        self.style = style ?? metric.defaultStyle
        self.tint = tint
        self.showLabel = showLabel
        self.showIcon = showIcon
    }

    /// A file written by another version may lack fields, or name a style this metric does not offer.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let metric = try values.decode(MetricKind.self, forKey: .metric)
        let style = try? values.decodeIfPresent(IndicatorStyle.self, forKey: .style)
        self.init(
            metric: metric,
            enabled: (try? values.decodeIfPresent(Bool.self, forKey: .enabled)) ?? false,
            style: style.flatMap { metric.styles.contains($0) ? $0 : nil },
            tint: (try? values.decodeIfPresent(IndicatorTint.self, forKey: .tint)) ?? .system,
            showLabel: (try? values.decodeIfPresent(Bool.self, forKey: .showLabel)) ?? true,
            showIcon: (try? values.decodeIfPresent(Bool.self, forKey: .showIcon)) ?? false
        )
    }

    /// All seven metrics, once each and in the standard order, whatever the stored list held.
    public static func normalized(_ stored: [IndicatorSetting]?) -> [IndicatorSetting] {
        MetricKind.allCases.map { metric in
            stored?.first { $0.metric == metric } ?? IndicatorSetting(metric: metric)
        }
    }

    public static let defaults = normalized(nil)

    /// Seconds between readings while an indicator is showing.
    public static let refreshChoices = [1, 2, 3, 5, 10]
    public static let defaultRefresh = 2
}

/// What one indicator shows for one reading.
public struct IndicatorValue: Sendable, Equatable {
    /// `21%`, `↓ 1.2 MB/s`, or `—` when the machine does not give the reading.
    public var text: String
    /// Second line of the speed style (`↑ 340 KB/s`).
    public var secondary: String?
    /// 0...1 for gauges and bars; nil for speeds and missing readings.
    public var fraction: Double?
    /// The number a chart plots: a percentage, or the total bytes per second for throughput.
    public var chartValue: Double
    /// Read aloud by VoiceOver.
    public var spoken: String

    public var isAvailable: Bool { text != IndicatorFormatter.missing }

    public init(text: String, secondary: String? = nil, fraction: Double? = nil, chartValue: Double = 0, spoken: String) {
        self.text = text
        self.secondary = secondary
        self.fraction = fraction
        self.chartValue = chartValue
        self.spoken = spoken
    }
}

public enum IndicatorFormatter {
    public static let missing = "—"

    public static func value(_ metric: MetricKind, from snapshot: MetricsSnapshot?) -> IndicatorValue {
        guard let snapshot else { return unavailable(metric) }
        switch metric {
        case .cpu:
            return percent(snapshot.cpu, spokenName: "Processor")
        case .memory:
            let memory = snapshot.memory
            let used = gigabytes(memory.usedBytes, binary: true)
            let total = gigabytes(memory.totalBytes, binary: true)
            var value = percent(memory.usedFraction, spokenName: "Memory")
            value.spoken = "Memory, \(used) of \(total) gigabytes, \(Int((memory.usedFraction * 100).rounded())) percent"
            return value
        case .gpu:
            guard let gpu = snapshot.gpu else { return unavailable(metric) }
            return percent(gpu.utilization, spokenName: "GPU")
        case .disk:
            let disk = snapshot.disk
            var value = percent(disk.usedFraction, spokenName: "Disk")
            value.spoken = "Disk, \(gigabytes(disk.availableBytes, binary: false)) gigabytes free, \(Int((disk.usedFraction * 100).rounded())) percent used"
            return value
        case .diskActivity:
            guard let activity = snapshot.diskActivity else { return unavailable(metric) }
            return IndicatorValue(
                text: "R \(rate(activity.readBytesPerSecond))",
                secondary: "W \(rate(activity.writeBytesPerSecond))",
                chartValue: activity.readBytesPerSecond + activity.writeBytesPerSecond,
                spoken: "Disk activity, reading \(rate(activity.readBytesPerSecond, spoken: true)), writing \(rate(activity.writeBytesPerSecond, spoken: true))"
            )
        case .network:
            return IndicatorValue(
                text: "↓ \(rate(snapshot.downloadBytesPerSecond))",
                secondary: "↑ \(rate(snapshot.uploadBytesPerSecond))",
                chartValue: snapshot.downloadBytesPerSecond + snapshot.uploadBytesPerSecond,
                spoken: "Network, download \(rate(snapshot.downloadBytesPerSecond, spoken: true)), upload \(rate(snapshot.uploadBytesPerSecond, spoken: true))"
            )
        case .battery:
            guard let battery = snapshot.battery else { return unavailable(metric) }
            var value = percent(battery.level, spokenName: "Battery")
            let state = battery.isCharging ? "charging" : battery.isOnACPower ? "on power adapter" : "on battery"
            value.spoken = "Battery, \(Int((battery.level * 100).rounded())) percent, \(state)"
            return value
        }
    }

    public static func unavailable(_ metric: MetricKind) -> IndicatorValue {
        IndicatorValue(text: missing, spoken: "\(metric.title), not available")
    }

    /// `1.2 MB/s`, `340 KB/s`, `0 KB/s`. Decimal units, always a dot, so the text does not depend on the locale.
    public static func rate(_ bytesPerSecond: Double, spoken: Bool = false) -> String {
        let bytes = max(0, bytesPerSecond.isFinite ? bytesPerSecond : 0)
        let text: String
        if bytes < 1_000_000 {
            text = "\(Int((bytes / 1_000).rounded())) KB/s"
        } else if bytes < 1_000_000_000 {
            text = String(format: "%.1f MB/s", bytes / 1_000_000)
        } else {
            text = String(format: "%.2f GB/s", bytes / 1_000_000_000)
        }
        guard spoken else { return text }
        return text
            .replacingOccurrences(of: "KB/s", with: "kilobytes per second")
            .replacingOccurrences(of: "MB/s", with: "megabytes per second")
            .replacingOccurrences(of: "GB/s", with: "gigabytes per second")
    }

    private static func percent(_ fraction: Double, spokenName: String) -> IndicatorValue {
        let clamped = min(1, max(0, fraction.isFinite ? fraction : 0))
        let number = Int((clamped * 100).rounded())
        return IndicatorValue(text: "\(number)%", fraction: clamped, chartValue: clamped * 100, spoken: "\(spokenName), \(number) percent")
    }

    /// Binary (memory, as Activity Monitor) or decimal (disk, as Finder), one decimal for small numbers.
    private static func gigabytes(_ bytes: UInt64, binary: Bool) -> String {
        let value = Double(bytes) / (binary ? 1_073_741_824 : 1_000_000_000)
        return value < 100 ? String(format: "%.1f", value) : String(format: "%.0f", value)
    }
}

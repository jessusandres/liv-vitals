import LivCore
import SwiftUI

/// What a widget reads once: the numbers, and the facts about the Mac.
public struct LivWidgetEntry: Sendable {
    public var date: Date
    /// nil until a reading exists (the gallery placeholder); every face then shows dashes.
    public var snapshot: MetricsSnapshot?
    public var device: DeviceInfo

    public init(date: Date, snapshot: MetricsSnapshot?, device: DeviceInfo) {
        self.date = date
        self.snapshot = snapshot
        self.device = device
    }
}

/// The picture of one widget at the medium size. The numbers and their text come from `IndicatorFormatter`, the same code the
/// menu bar indicators use, so a widget and an indicator cannot disagree.
public struct WidgetFace: View {
    public let kind: WidgetKind
    public let entry: LivWidgetEntry

    public init(kind: WidgetKind, entry: LivWidgetEntry) {
        self.kind = kind
        self.entry = entry
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(kind.title, systemImage: kind.symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            content
            Spacer(minLength: 0)
            if kind != .device, entry.snapshot != nil {
                Text("Updated \(entry.date, style: .time)")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    /// Read aloud as one sentence, whatever the layout.
    var spoken: String {
        switch kind {
        case .device:
            "Device, macOS \(entry.device.macOSVersion), \(entry.device.chip), up \(DeviceInfo.uptimeText(entry.device.uptime))"
        case .batteryHealth:
            if let battery = entry.snapshot?.battery {
                "Battery health, \(battery.health.map(Self.percent) ?? "not reported") maximum capacity, \(battery.cycleCount.map { "\($0) cycles" } ?? "cycles not available"), charge \(Self.percent(battery.level)), \(Self.batteryState(battery).lowercased())"
            } else {
                "Battery health, not available"
            }
        case .storage:
            if let disk = entry.snapshot?.disk {
                "Storage, \(Self.gigabytes(disk.availableBytes)) gigabytes free of \(Self.gigabytes(disk.totalBytes)), \(Self.percent(disk.usedFraction).replacingOccurrences(of: "%", with: " percent")) used"
            } else {
                "Storage, not available"
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .batteryHealth:
            batteryFace
        case .storage:
            storageFace
        case .device:
            deviceFace
        }
    }

    // MARK: - Faces

    private var batteryFace: some View {
        let battery = entry.snapshot?.battery
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(battery?.health.map(Self.percent) ?? IndicatorFormatter.missing)
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                Text("Maximum capacity").font(.system(size: 10)).foregroundStyle(.secondary)
                Text("Cycles \(battery?.cycleCount.map(String.init) ?? IndicatorFormatter.missing) · Charge \(battery.map { Self.percent($0.level) } ?? IndicatorFormatter.missing)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(verbatim: battery.map(Self.batteryState) ?? IndicatorFormatter.missing)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(kind.color)
            }
            Spacer(minLength: 0)
            Ring(fraction: battery?.health, color: kind.color).frame(width: 58, height: 58)
        }
    }

    private var storageFace: some View {
        let disk = entry.snapshot?.disk
        return HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: disk.map { "\(Self.gigabytes($0.availableBytes)) GB" } ?? IndicatorFormatter.missing)
                    .font(.system(size: 30, weight: .bold))
                    .monospacedDigit()
                Text("Free").font(.system(size: 10)).foregroundStyle(.secondary)
                Text(verbatim: disk.map { "\(Self.gigabytes($0.usedBytes)) GB used of \(Self.gigabytes($0.totalBytes)) GB" } ?? IndicatorFormatter.missing)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Ring(fraction: disk?.usedFraction, color: kind.color).frame(width: 58, height: 58)
        }
    }

    private var deviceFace: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(entry.device.chip).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                Text(entry.device.macOSVersion).font(.system(size: 28, weight: .bold)).monospacedDigit()
                Text("macOS").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 4) {
                Text("Up time").foregroundStyle(.secondary)
                Text(DeviceInfo.uptimeText(entry.device.uptime)).fontWeight(.medium)
                Text("Boot date").foregroundStyle(.secondary).padding(.top, 4)
                Text(entry.device.bootDate.formatted(date: .abbreviated, time: .shortened)).fontWeight(.medium)
            }
            .font(.system(size: 10))
        }
    }

    // MARK: - Text helpers

    static func percent(_ fraction: Double) -> String { "\(Int((min(1, max(0, fraction)) * 100).rounded()))%" }

    /// Whole decimal gigabytes, as the Storage settings of macOS count them.
    static func gigabytes(_ bytes: UInt64) -> Int { Int((Double(bytes) / 1e9).rounded()) }

    /// Where the battery stands: charging, full on the charger, held on the charger, or running down.
    static func batteryState(_ battery: BatteryReading) -> String {
        if battery.isCharging { return "Charging" }
        if battery.isOnACPower { return battery.level >= 0.99 ? "Fully charged" : "On power, not charging" }
        return "On battery"
    }
}

private struct Ring: View {
    let fraction: Double?
    let color: Color

    var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 7)
            Circle().trim(from: 0, to: min(1, max(0, fraction ?? 0)))
                .stroke(color, style: StrokeStyle(lineWidth: 7, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

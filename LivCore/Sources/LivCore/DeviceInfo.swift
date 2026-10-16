import Darwin
import Foundation

/// What the Device widget shows about this Mac. It leaves out the computer's name and every address on purpose: a widget sits
/// on the desktop, where screenshots are taken.
public struct DeviceInfo: Sendable, Equatable {
    public var chip: String
    public var model: String
    public var macOSVersion: String
    public var uptime: TimeInterval
    public var bootDate: Date

    public init(chip: String, model: String, macOSVersion: String, uptime: TimeInterval, bootDate: Date) {
        self.chip = chip
        self.model = model
        self.macOSVersion = macOSVersion
        self.uptime = uptime
        self.bootDate = bootDate
    }

    /// `3 d 4 h`, `5 h 12 min`, `7 min`. Seconds are never shown: the widget refreshes every few minutes at best.
    public static func uptimeText(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds.isFinite ? seconds : 0) / 60)
        let days = minutes / 1_440
        let hours = (minutes % 1_440) / 60
        let rest = minutes % 60
        if days > 0 { return "\(days) d \(hours) h" }
        if hours > 0 { return "\(hours) h \(rest) min" }
        return "\(rest) min"
    }

    public static func read(now: Date = .now) -> DeviceInfo {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        let uptime = ProcessInfo.processInfo.systemUptime
        return DeviceInfo(
            chip: sysctlString("machdep.cpu.brand_string") ?? "Apple silicon",
            model: sysctlString("hw.model") ?? "Mac",
            macOSVersion: "\(version.majorVersion).\(version.minorVersion)" + (version.patchVersion > 0 ? ".\(version.patchVersion)" : ""),
            uptime: uptime,
            bootDate: now.addingTimeInterval(-uptime)
        )
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cBuffer: buffer)
    }
}

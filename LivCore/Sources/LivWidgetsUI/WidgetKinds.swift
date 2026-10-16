import Foundation
import LivCore
import SwiftUI

/// The three widgets that stay. WidgetKit refreshes a widget about every 15 minutes at most (and the free personal team has no
/// App Group to share live numbers with), so only values that are still true when 15 minutes old are widgets: battery health,
/// storage and the facts about the Mac. CPU, GPU, disk activity, network and memory moved to the live menu bar indicators.
/// Ported from the author's Device Monitor (GPL-3.0-or-later) and rebuilt on `LivCore`'s numbers.
public enum WidgetKind: String, CaseIterable, Sendable, Identifiable {
    case batteryHealth, storage, device

    public var id: String { rawValue }

    /// The identifier WidgetKit knows the widget by. Different from Device Monitor's, so both can be installed.
    public var widgetID: String { "dev.asger.LivVitals.widget.\(rawValue)" }

    public var title: String {
        switch self {
        case .batteryHealth: "Battery Health"
        case .storage: "Storage"
        case .device: "Device"
        }
    }

    /// Plain text with no interpolation: WidgetKit rejects formatted text in a widget's metadata.
    public var summary: String {
        switch self {
        case .batteryHealth: "Battery health, cycle count and charge state. Updated on macOS's widget schedule."
        case .storage: "Free and used space on the startup disk. Updated on macOS's widget schedule."
        case .device: "macOS version, chip and time since the last restart."
        }
    }

    public var symbol: String {
        switch self {
        case .batteryHealth: "battery.100percent"
        case .storage: "internaldrive"
        case .device: "laptopcomputer"
        }
    }

    /// The indicator metric whose numbers the face shows; nil for the two widgets that show something else.
    public var metric: MetricKind? {
        switch self {
        case .storage: .disk
        case .batteryHealth, .device: nil
        }
    }

    public var color: Color {
        switch self {
        case .batteryHealth: Color(red: 0.13, green: 0.71, blue: 0.62)
        case .storage: Color(red: 0.90, green: 0.34, blue: 0.66)
        case .device: .secondary
        }
    }
}

/// When a widget asks macOS for new numbers. macOS decides whether and when to grant it.
public enum WidgetSchedule {
    public static let refreshInterval: TimeInterval = 15 * 60

    public static func nextRefresh(after date: Date) -> Date {
        date.addingTimeInterval(refreshInterval)
    }
}

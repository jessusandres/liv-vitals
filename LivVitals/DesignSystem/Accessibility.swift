import AppKit
import LivCore
import SwiftUI

/// The words VoiceOver reads for controls that show no text of their own. Plain functions so a test can check
/// every one without rendering a view.
nonisolated enum AccessibilityText {
    static func selection(_ state: CheckState) -> String {
        switch state {
        case .all: "Selected"
        case .some: "Partly selected"
        case .none: "Not selected"
        }
    }

    static func percent(_ progress: Double) -> String {
        "\(Int((min(max(progress, 0), 1) * 100).rounded())) percent"
    }

    static func circleButton(title: String, subtitle: String?) -> String {
        subtitle.map { "\(title), \($0)" } ?? title
    }

    static func expandButton(_ title: String, isExpanded: Bool) -> String {
        (isExpanded ? "Collapse " : "Expand ") + title
    }

    static func sunburstSegment(name: String, size: String, isDirectory: Bool) -> String {
        isDirectory ? "\(name), \(size), folder" : "\(name), \(size)"
    }

    static let needsAdmin = "Asks for your administrator password"
    static let lockedFallback = "Cannot be removed"
}

/// Runs `body` with animation unless the user asked macOS to reduce motion. For code outside a view, which cannot
/// read the environment.
@MainActor
func withMotion<Result>(_ animation: Animation? = .default, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? nil : animation, body)
}

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation?
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {
    /// `animation(_:value:)` that stays still under "Reduce Motion".
    func motion<Value: Equatable>(_ animation: Animation?, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }
}

/// The chevron of an expandable card: reachable with Tab and VoiceOver, where the card's own tap is not.
struct ExpandChevron: View {
    let title: String
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(AccessibilityText.expandButton(title, isExpanded: isExpanded))
    }
}

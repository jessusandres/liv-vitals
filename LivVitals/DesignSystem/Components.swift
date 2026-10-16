import LivCore
import SwiftUI

/// The large round call-to-action button ("Scan", "Clean", "Run").
struct CircleActionButton: View {
    let title: String
    var subtitle: String?
    let theme: ModuleTheme
    var diameter: CGFloat = 150
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.gradient.opacity(0.25))
                    .frame(width: diameter * 1.18, height: diameter * 1.18)
                    .scaleEffect(isHovering ? 1.06 : 1)
                Circle()
                    .fill(theme.gradient)
                    .frame(width: diameter, height: diameter)
                    .shadow(color: theme.end.opacity(0.45), radius: 18, y: 8)
                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: diameter * 0.16, weight: .semibold, design: .rounded))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: diameter * 0.095, weight: .medium, design: .rounded))
                            .opacity(0.85)
                            .contentTransition(.numericText())
                    }
                }
                .foregroundStyle(.white)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { hovering in
            withMotion(.spring(duration: 0.3)) { isHovering = hovering }
        }
        .accessibilityLabel(AccessibilityText.circleButton(title: title, subtitle: subtitle))
    }
}

struct ProgressRing: View {
    let progress: Double
    let theme: ModuleTheme
    var lineWidth: CGFloat = 14
    /// What the ring measures. Without one the ring is decoration: a number beside it already says the same.
    var label: String?

    var body: some View {
        ring
            .accessibilityElement(children: .ignore)
            .accessibilityHidden(label == nil)
            .accessibilityLabel(label ?? "")
            .accessibilityValue(AccessibilityText.percent(progress))
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(.primary.opacity(0.08), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(
                    AngularGradient(colors: [theme.start, theme.end, theme.start], center: .center),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .motion(.easeOut(duration: 0.2), value: progress)
        }
    }
}

/// Rounded translucent container used for every panel.
struct CardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(.white.opacity(0.08))
            )
    }
}

extension View {
    func card(padding: CGFloat = 16) -> some View { modifier(CardModifier(padding: padding)) }
}

/// Module icon on its gradient tile.
struct ModuleIcon: View {
    let module: AppModule
    var size: CGFloat = 28

    var body: some View {
        Image(systemName: module.systemImage)
            .font(.system(size: size * 0.5, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(module.theme.gradient, in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

private struct ShowsPreviewDataKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// True while the module on screen is fed by a simulated service.
    var showsPreviewData: Bool {
        get { self[ShowsPreviewDataKey.self] }
        set { self[ShowsPreviewDataKey.self] = newValue }
    }
}

/// Tells the user the numbers on screen are made up, so the installed app never looks like it cleans for real.
struct PreviewBadge: View {
    var body: some View {
        Label("Preview data", systemImage: "eye")
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.18), in: Capsule())
            .foregroundStyle(.orange)
            .help("This module shows simulated data. Nothing on your Mac is scanned or changed.")
    }
}

/// Title row shown at the top of every module.
struct ModuleHeader<Trailing: View>: View {
    let module: AppModule
    var subtitle: String?
    @ViewBuilder var trailing: Trailing

    @Environment(\.showsPreviewData) private var showsPreviewData

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ModuleIcon(module: module, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(module.title).font(.title2.bold())
                    if showsPreviewData { PreviewBadge() }
                }
                Text(subtitle ?? module.tagline)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            trailing
        }
    }
}

extension ModuleHeader where Trailing == EmptyView {
    init(module: AppModule, subtitle: String? = nil) {
        self.init(module: module, subtitle: subtitle) { EmptyView() }
    }
}

enum CheckState {
    case all, some, none

    var systemImage: String {
        switch self {
        case .all: "checkmark.square.fill"
        case .some: "minus.square.fill"
        case .none: "square"
        }
    }
}

struct CheckBox: View {
    let state: CheckState
    let tint: Color
    /// The name of what the box selects, so VoiceOver reads "Caches, Selected" and not just "Selected".
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: state.systemImage)
                .font(.system(size: 16))
                .foregroundStyle(state == .none ? Color.secondary : tint)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityValue(AccessibilityText.selection(state))
        .accessibilityAddTraits(.isToggle)
    }
}

extension CleanupCategory {
    var systemImage: String {
        switch self {
        case .userCaches: "archivebox"
        case .logs: "doc.text"
        case .trash: "trash"
        case .browserData: "safari"
        case .developerTools: "hammer"
        case .applications: "app.dashed"
        case .appLeftovers: "puzzlepiece.extension"
        case .installers: "shippingbox"
        case .projectArtifacts: "folder.badge.gearshape"
        case .largeFiles: "doc.zipper"
        }
    }

    var color: Color {
        switch self {
        case .userCaches: .teal
        case .logs: .gray
        case .trash: .red
        case .browserData: .blue
        case .developerTools: .indigo
        case .applications: .cyan
        case .appLeftovers: .purple
        case .installers: .orange
        case .projectArtifacts: .mint
        case .largeFiles: .pink
        }
    }
}

extension URL {
    /// The path with the home folder shown as `~`.
    nonisolated var abbreviatedPath: String { (path as NSString).abbreviatingWithTildeInPath }
}

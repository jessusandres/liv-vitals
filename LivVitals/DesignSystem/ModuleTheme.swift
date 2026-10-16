import SwiftUI

/// The two-color gradient that identifies a module.
struct ModuleTheme: Equatable {
    let start: Color
    let end: Color

    var gradient: LinearGradient {
        LinearGradient(colors: [start, end], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension AppModule {
    var theme: ModuleTheme {
        switch self {
        case .smartCare: ModuleTheme(start: Color(red: 0.36, green: 0.30, blue: 0.95), end: Color(red: 0.75, green: 0.25, blue: 0.85))
        case .cleanup: ModuleTheme(start: Color(red: 0.03, green: 0.62, blue: 0.58), end: Color(red: 0.25, green: 0.78, blue: 0.40))
        case .devProjects: ModuleTheme(start: Color(red: 0.08, green: 0.50, blue: 0.75), end: Color(red: 0.18, green: 0.78, blue: 0.72))
        case .installers: ModuleTheme(start: Color(red: 0.95, green: 0.50, blue: 0.20), end: Color(red: 0.90, green: 0.25, blue: 0.50))
        case .applications: ModuleTheme(start: Color(red: 0.15, green: 0.42, blue: 0.95), end: Color(red: 0.20, green: 0.72, blue: 0.95))
        case .performance: ModuleTheme(start: Color(red: 0.92, green: 0.28, blue: 0.25), end: Color(red: 0.98, green: 0.62, blue: 0.20))
        case .spaceLens: ModuleTheme(start: Color(red: 0.55, green: 0.25, blue: 0.90), end: Color(red: 0.95, green: 0.35, blue: 0.65))
        case .monitor: ModuleTheme(start: Color(red: 0.15, green: 0.35, blue: 0.85), end: Color(red: 0.42, green: 0.25, blue: 0.80))
        case .history: ModuleTheme(start: Color(red: 0.33, green: 0.45, blue: 0.62), end: Color(red: 0.50, green: 0.40, blue: 0.70))
        case .settings: ModuleTheme(start: Color(red: 0.45, green: 0.48, blue: 0.56), end: Color(red: 0.60, green: 0.62, blue: 0.70))
        }
    }
}

/// Full-window backdrop: the module gradient washed over the window color, stronger in dark mode.
struct ModuleBackground: View {
    let theme: ModuleTheme
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            theme.gradient.opacity(colorScheme == .dark ? 0.55 : 0.28)
            RadialGradient(
                colors: [theme.end.opacity(colorScheme == .dark ? 0.35 : 0.20), .clear],
                center: .topTrailing,
                startRadius: 40,
                endRadius: 700
            )
        }
        .ignoresSafeArea()
    }
}

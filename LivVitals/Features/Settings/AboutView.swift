import Foundation
import SwiftUI

/// What the About window shows, read from the app's bundle.
struct AboutInfo: Equatable {
    let name: String
    let version: String
    let build: String
    let copyright: String

    init(bundle: Bundle = .main) {
        let info = bundle.infoDictionary ?? [:]
        name = info["CFBundleDisplayName"] as? String ?? info["CFBundleName"] as? String ?? "Liv Vitals"
        version = info["CFBundleShortVersionString"] as? String ?? "?"
        build = info["CFBundleVersion"] as? String ?? "?"
        let declared = info["NSHumanReadableCopyright"] as? String ?? ""
        copyright = declared.isEmpty ? "Personal project by Jesús Andrés." : declared
    }

    var versionLine: String { "Version \(version) (\(build))" }

    static let licenses = [
        "Liv Vitals uses no third-party libraries.",
        "The menu bar indicators and widgets were adapted from the author's own Device Monitor (GPL-3.0-or-later). No third-party code is included.",
    ]
}

struct AboutView: View {
    let info = AboutInfo()

    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
                .accessibilityHidden(true)
            Text(info.name).font(.title.bold())
            Text(info.versionLine).foregroundStyle(.secondary)
            Text(info.copyright).font(.caption).foregroundStyle(.secondary)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Licenses").font(.headline)
                ForEach(AboutInfo.licenses, id: \.self) { Text($0).font(.callout).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(24)
        .frame(width: 380)
    }
}

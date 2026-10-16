import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Real macOS icons for files, folders and apps, as Finder shows them. Read-only; results are cached.
enum SystemIcons {
    enum Preference {
        /// Show the app a path belongs to (Spotify for its cache folder), falling back to the file icon.
        case owningApp
        /// Show the file or folder itself (the special Pictures icon), falling back to the owning app.
        case file
    }

    private static var cache: [String: NSImage] = [:]
    private static let workspace = NSWorkspace.shared
    private static let applicationFolders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities"]
    /// Path components that never name an app.
    private static let genericComponents: Set<String> = [
        "Library", "Caches", "Logs", "Application Support", "Containers", "Group Containers",
        "Preferences", "Developer", "Saved Application State", "WebKit", "HTTPStorages", "Default",
        "Downloads", "Desktop", "Documents", "Movies", "Music", "Pictures", "Public", "code", "Projects",
    ]

    static func icon(for url: URL, prefer preference: Preference = .owningApp) -> NSImage {
        let key = "\(preference)|\(url.path)"
        if let cached = cache[key] { return cached }
        let image = resolve(url, preference)
        cache[key] = image
        return image
    }

    /// Icon of an installed app by bundle identifier or display name, if it is installed.
    static func appIcon(bundleIdentifier: String? = nil, name: String? = nil) -> NSImage? {
        if let bundleIdentifier, let url = workspace.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return workspace.icon(forFile: url.path)
        }
        if let name, let url = installedApp(named: name) {
            return workspace.icon(forFile: url.path)
        }
        return nil
    }

    private static func resolve(_ url: URL, _ preference: Preference) -> NSImage {
        let exists = FileManager.default.fileExists(atPath: url.path)
        if url.pathExtension == "app" {
            if exists { return workspace.icon(forFile: url.path) }
            return appIcon(name: url.deletingPathExtension().lastPathComponent) ?? workspace.icon(for: .applicationBundle)
        }
        switch preference {
        case .owningApp:
            if let app = owningAppIcon(of: url) { return app }
            if exists { return workspace.icon(forFile: url.path) }
        case .file:
            if exists { return workspace.icon(forFile: url.path) }
            if let app = owningAppIcon(of: url) { return app }
        }
        return typeIcon(for: url)
    }

    /// Walks the path from the deepest component up, looking for a bundle id or an installed app name.
    private static func owningAppIcon(of url: URL) -> NSImage? {
        let home = URL(fileURLWithPath: NSHomeDirectory()).pathComponents
        let components = url.pathComponents.dropFirst(url.path.hasPrefix(NSHomeDirectory()) ? home.count : 1)
        let names = Array(components)
        for index in names.indices.reversed() where !genericComponents.contains(names[index]) {
            let component = names[index]
            if isBundleIdentifier(component), let icon = appIcon(bundleIdentifier: bundleIdentifierPrefix(component)) {
                return icon
            }
            // "Google/Chrome" → "Google Chrome", "Microsoft/Teams" → "Microsoft Teams".
            let withParent = index > names.startIndex ? "\(names[index - 1]) \(component)" : nil
            let name = (component as NSString).deletingPathExtension
            if let icon = appIcon(name: component) ?? appIcon(name: name) ?? withParent.flatMap({ appIcon(name: $0) }) {
                return icon
            }
        }
        return nil
    }

    private static func isBundleIdentifier(_ text: String) -> Bool {
        text.split(separator: ".").count >= 3 && !text.contains(" ")
    }

    /// `com.microsoft.VSCode.ShipIt` → the longest prefix that resolves to an installed app.
    private static func bundleIdentifierPrefix(_ text: String) -> String? {
        var parts = text.split(separator: ".").map(String.init)
        while parts.count >= 3 {
            let id = parts.joined(separator: ".")
            if workspace.urlForApplication(withBundleIdentifier: id) != nil { return id }
            parts.removeLast()
        }
        return nil
    }

    private static func installedApp(named name: String) -> URL? {
        for folder in applicationFolders {
            let url = URL(fileURLWithPath: folder).appending(path: "\(name).app")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func typeIcon(for url: URL) -> NSImage {
        if url.pathExtension.isEmpty { return workspace.icon(for: .folder) }
        return workspace.icon(for: UTType(filenameExtension: url.pathExtension) ?? .data)
    }
}

/// A file, folder or app icon at a fixed size.
struct SystemIcon: View {
    let image: NSImage
    var size: CGFloat = 20

    init(url: URL, prefer preference: SystemIcons.Preference = .owningApp, size: CGFloat = 20) {
        self.image = SystemIcons.icon(for: url, prefer: preference)
        self.size = size
    }

    init(image: NSImage, size: CGFloat = 20) {
        self.image = image
        self.size = size
    }

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

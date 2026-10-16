import AppKit
import LivCore

/// Remembers the icon of each process shown in Top Processes. Looking an icon up goes through `NSRunningApplication` and
/// searches `/Applications`, which is far too much work to repeat for every row on every one-second refresh
/// (it showed up in the CPU profile of the Monitor, Stage 10.B).
@MainActor
final class ProcessIconCache {
    private var icons: [Int32: NSImage] = [:]
    private let resolve: @MainActor (ProcessUsage) -> NSImage
    /// How many times `resolve` ran; tests check it stays at one per process.
    private(set) var lookups = 0

    init(resolve: @escaping @MainActor (ProcessUsage) -> NSImage = ProcessIconCache.systemIcon) {
        self.resolve = resolve
    }

    func icon(for process: ProcessUsage) -> NSImage {
        if let cached = icons[process.pid] { return cached }
        lookups += 1
        let icon = resolve(process)
        icons[process.pid] = icon
        return icon
    }

    /// Forgets the processes that are gone, so a reused pid never shows another app's icon.
    func keep(only pids: Set<Int32>) {
        icons = icons.filter { pids.contains($0.key) }
    }

    /// The app's own icon when the process belongs to an app, a generic one otherwise.
    static func systemIcon(for process: ProcessUsage) -> NSImage {
        NSRunningApplication(processIdentifier: process.pid)?.icon
            ?? SystemIcons.appIcon(bundleIdentifier: nil, name: process.name)
            ?? NSWorkspace.shared.icon(for: .unixExecutable)
    }
}

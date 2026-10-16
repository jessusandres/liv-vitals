import Foundation
import LivCore

/// Fake data for Stage 1. Paths are built in memory only; nothing here touches the disk.
nonisolated enum MockData {
    private static func home(_ path: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appending(path: path)
    }

    private static func mb(_ value: Double) -> ByteSize { ByteSize(Int64(value * 1_000_000)) }

    private static func daysAgo(_ days: Double) -> Date { Date(timeIntervalSinceNow: -days * 86_400) }

    private static func item(
        _ path: String,
        _ category: CleanupCategory,
        mb size: Double,
        days: Double = 30,
        selected: Bool = true,
        note: String? = nil,
        project: String? = nil
    ) -> CleanupItem {
        let url = path.hasPrefix("/") ? URL(fileURLWithPath: path) : home(path)
        return CleanupItem(
            url: url, category: category, size: mb(size), lastModified: daysAgo(days), isSelectedByDefault: selected,
            note: note, group: project.map(home)
        )
    }

    // MARK: - Scan modules

    static func scanResult(for module: AppModule) -> ScanResult {
        switch module {
        case .cleanup: ScanResult(items: cleanupItems)
        case .devProjects: ScanResult(items: projectItems)
        case .installers: ScanResult(items: installerItems)
        case .applications: ScanResult(items: applicationItems)
        case .smartCare: ScanResult(items: cleanupItems + installerItems + projectItems)
        default: .empty
        }
    }

    private static let cleanupItems: [CleanupItem] = [
        item("Library/Caches/com.spotify.client", .userCaches, mb: 1_340, days: 1),
        item("Library/Caches/com.google.Chrome", .userCaches, mb: 820, days: 1),
        item("Library/Caches/Homebrew", .userCaches, mb: 640, days: 12),
        item("Library/Caches/com.apple.Safari", .userCaches, mb: 412, days: 2),
        item("Library/Caches/com.microsoft.VSCode.ShipIt", .userCaches, mb: 96, days: 20),
        item("Library/Logs/JetBrains", .logs, mb: 210, days: 4),
        item("Library/Logs/CoreSimulator", .logs, mb: 130, days: 9),
        item("Library/Logs/DiagnosticReports", .logs, mb: 45, days: 3),
        item(".Trash", .trash, mb: 2_100, days: 6),
        item("Library/Application Support/Google/Chrome/Default/Service Worker/CacheStorage", .browserData, mb: 340, days: 1),
        item("Library/Safari/LocalStorage", .browserData, mb: 60, days: 1, selected: false),
        item("Library/Developer/Xcode/DerivedData", .developerTools, mb: 6_400, days: 2),
        item("Library/pnpm/store", .developerTools, mb: 2_700, days: 5),
        item(".npm/_cacache", .developerTools, mb: 1_900, days: 8),
        item("Library/Developer/CoreSimulator/Caches", .developerTools, mb: 1_100, days: 15),
        item("Library/Containers/com.evernote.Evernote", .appLeftovers, mb: 420, days: 240),
        item("Library/Application Support/zoom.us", .appLeftovers, mb: 180, days: 190),
        item("Library/Preferences/com.skype.skype.plist", .appLeftovers, mb: 0.2, days: 400),
    ]

    private static let projectItems: [CleanupItem] = [
        item("code/api-gateway/target", .projectArtifacts, mb: 3_400, days: 64, note: "Run cargo build to restore it.", project: "code/api-gateway"),
        item("code/web-shop/node_modules", .projectArtifacts, mb: 1_200, days: 41, note: "Run npm install (or pnpm/yarn) to restore it.", project: "code/web-shop"),
        item("code/web-shop/dist", .projectArtifacts, mb: 36, days: 41, note: "Run the project's build script to restore it.", project: "code/web-shop"),
        // A project worked on this week stays unchecked.
        item("code/dashboard/node_modules", .projectArtifacts, mb: 980, days: 2, selected: false, note: "Project edited 2 days ago.", project: "code/dashboard"),
        item("code/ios-app/.build", .projectArtifacts, mb: 860, days: 95, note: "Run swift build to restore it.", project: "code/ios-app"),
        // Git could not confirm that nothing here is versioned.
        item("code/landing/dist", .projectArtifacts, mb: 40, days: 120, selected: false, note: "Could not check git for this project.", project: "code/landing"),
    ]

    private static let installerItems: [CleanupItem] = [
        item("Downloads/Xcode_26.xip", .installers, mb: 9_800, days: 70, note: "Xcode is installed."),
        item("Desktop/ubuntu-24.04-desktop-arm64.iso", .installers, mb: 3_100, days: 150, selected: false, note: "No installed app matches this installer."),
        item("Downloads/Docker.dmg", .installers, mb: 620, days: 33, note: "Docker is installed."),
        item("Library/Caches/Homebrew/downloads", .installers, mb: 450, days: 12, note: "Homebrew downloads these again when it needs them."),
        item("Downloads/zoomusInstallerFull.pkg", .installers, mb: 110, days: 200, selected: false, note: "No installed app matches this installer."),
    ]

    private static let applicationItems: [CleanupItem] = {
        func app(_ name: String, mb size: Double, days: Double, note: String? = nil, needsAdmin: Bool = false, leftovers: [(String, Double)] = []) -> [CleanupItem] {
            let bundle = URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
            let appItem = CleanupItem(
                url: bundle, category: .applications, size: mb(size), lastModified: daysAgo(days),
                note: note, group: bundle, needsAdmin: needsAdmin
            )
            return [appItem] + leftovers.map { path, size in
                CleanupItem(
                    url: home("Library/\(path)"), category: .appLeftovers, size: mb(size), lastModified: daysAgo(days),
                    group: bundle
                )
            }
        }
        return app("OBS", mb: 620, days: 210, leftovers: [("Caches/com.obsproject.obs-studio", 120), ("Preferences/com.obsproject.obs-studio.plist", 0.1)])
            + app("DBeaver", mb: 540, days: 120, leftovers: [("Caches/org.jkiss.dbeaver.core.product", 80), ("HTTPStorages/org.jkiss.dbeaver.core.product", 2)])
            + app("Postman", mb: 480, days: 60, leftovers: [("Application Support/Postman", 160), ("Caches/com.postmanlabs.mac", 45)])
            + app("Discord", mb: 390, days: 0.1, note: "Open now; it will be quit first.", leftovers: [("Application Support/discord", 310)])
            + app("Microsoft Teams", mb: 1_400, days: 90, needsAdmin: true, leftovers: [("Containers/com.microsoft.teams2", 760)])
            + [
                CleanupItem(
                    url: home("Library/Caches/com.evernote.Evernote"), category: .appLeftovers, size: mb(420),
                    lastModified: daysAgo(240), isSelectedByDefault: false, note: "No installed app uses this."
                ),
                CleanupItem(
                    url: home("Library/Preferences/us.zoom.xos.plist"), category: .appLeftovers, size: mb(0.2),
                    lastModified: daysAgo(190), isSelectedByDefault: false, note: "No installed app uses this."
                ),
            ]
    }()

    // MARK: - Performance

    /// The same tasks the real service lists, so the simulated screen never drifts from the real one.
    static let maintenanceTasks: [MaintenanceTask] = MaintenanceCommand.allCases.map(\.task)

    /// Startup items for previews and snapshots, including one whose program is gone.
    static let startupItems: [LaunchItem] = {
        func app(_ name: String, _ id: String) -> InstalledApp {
            InstalledApp(url: URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true), bundleID: id, name: name)
        }
        func item(
            _ label: String, _ scope: LaunchItem.Scope, program: String?, exists: Bool = true, owner: InstalledApp?
        ) -> LaunchItem {
            let folder = scope == .user ? "Library/LaunchAgents" : (scope == .systemAgent ? "/Library/LaunchAgents" : "/Library/LaunchDaemons")
            let url = folder.hasPrefix("/") ? URL(fileURLWithPath: "\(folder)/\(label).plist") : home("\(folder)/\(label).plist")
            return LaunchItem(url: url, scope: scope, label: label, program: program, programExists: exists, owner: owner)
        }
        let chrome = app("Google Chrome", "com.google.Chrome")
        let docker = app("Docker", "com.docker.docker")
        let logi = app("Logi Options+", "com.logi.optionsplus")
        return [
            item("com.google.keystone.agent", .user, program: "/Users/you/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/MacOS/GoogleSoftwareUpdateAgent", owner: chrome),
            item("com.google.keystone.xpcservice", .user, program: "/Users/you/Library/Google/GoogleSoftwareUpdate/GoogleSoftwareUpdate.bundle/Contents/MacOS/GoogleSoftwareUpdateAgent", owner: chrome),
            item("com.docker.vmnetd", .systemDaemon, program: "/Library/PrivilegedHelperTools/com.docker.vmnetd", owner: docker),
            item("com.logi.optionsplus.updater", .systemDaemon, program: "/Applications/Logi Options+.app/Contents/Resources/logioptionsplus_updater", owner: logi),
            item("com.oldvpn.helper", .systemDaemon, program: "/Applications/OldVPN.app/Contents/MacOS/helper", exists: false, owner: nil),
            item("org.example.syncd", .systemAgent, program: "/usr/local/bin/syncd", owner: nil),
        ]
    }()

    // MARK: - Space Lens

    static var diskTree: DiskNode {
        let root = URL(fileURLWithPath: NSHomeDirectory())
        func dir(_ path: String, _ children: [DiskNode]) -> DiskNode { .directory(root.appending(path: path), children: children) }
        func file(_ path: String, _ size: Double) -> DiskNode { .file(root.appending(path: path), size: mb(size)) }

        return .directory(root, children: [
            dir("Library", [
                dir("Library/Developer", [
                    dir("Library/Developer/Xcode", [
                        file("Library/Developer/Xcode/DerivedData", 6_400),
                        file("Library/Developer/Xcode/iOS DeviceSupport", 4_800),
                        file("Library/Developer/Xcode/Archives", 1_200),
                    ]),
                    dir("Library/Developer/CoreSimulator", [
                        file("Library/Developer/CoreSimulator/Devices", 9_300),
                        file("Library/Developer/CoreSimulator/Caches", 1_100),
                    ]),
                ]),
                dir("Library/Caches", [
                    file("Library/Caches/com.spotify.client", 1_340),
                    file("Library/Caches/com.google.Chrome", 820),
                    file("Library/Caches/Homebrew", 640),
                    file("Library/Caches/com.apple.Safari", 412),
                ]),
                dir("Library/Application Support", [
                    file("Library/Application Support/Google", 2_300),
                    file("Library/Application Support/Slack", 1_100),
                    file("Library/Application Support/Code", 900),
                ]),
                dir("Library/Containers", [
                    file("Library/Containers/com.docker.docker", 18_500),
                    file("Library/Containers/com.apple.mail", 2_600),
                ]),
            ]),
            dir("Pictures", [
                file("Pictures/Photos Library.photoslibrary", 38_000),
                file("Pictures/Screenshots", 1_400),
            ]),
            dir("Movies", [
                file("Movies/Trip to Cusco.mov", 7_200),
                file("Movies/Screen Recordings", 3_300),
            ]),
            dir("Downloads", [
                file("Downloads/Xcode_26.xip", 9_800),
                file("Downloads/Docker.dmg", 620),
                file("Downloads/dataset.csv", 1_800),
                file("Downloads/Invoices", 120),
            ]),
            dir("code", [
                dir("code/api-gateway", [
                    file("code/api-gateway/target", 3_400),
                    file("code/api-gateway/src", 40),
                ]),
                dir("code/web-shop", [
                    file("code/web-shop/node_modules", 1_200),
                    file("code/web-shop/src", 25),
                ]),
                file("code/ios-app", 1_300),
            ]),
            dir("Documents", [
                file("Documents/Thesis", 2_100),
                file("Documents/Taxes", 340),
            ]),
            dir("Music", [file("Music/Music", 4_100)]),
        ])
    }

    // MARK: - History

    static let history: [HistoryRun] = [
        run("Cleanup", daysAgo: 3, trash: true, [
            ("Library/Caches/com.spotify.client", 4_200), ("Library/Caches/Google/Chrome", 3_100),
            ("Library/Logs/DiagnosticReports", 900), ("Library/Developer/Xcode/DerivedData", 1_650),
        ]),
        run("Dev Projects", daysAgo: 10, trash: false, [("code/web-app/node_modules", 3_900), ("code/api/target", 1_520)]),
        run("Installers", daysAgo: 18, trash: true, [("Downloads/Xcode_26.xip", 8_100), ("Downloads/Docker.dmg", 2_430)]),
        run("Smart Care", daysAgo: 34, trash: true, [("Library/Caches/Homebrew/downloads", 6_800), ("code/site/.next", 7_300)], restoredFirst: true),
        run("Uninstaller", daysAgo: 61, trash: true, [("Applications/Sketch.app", 2_900), ("Library/Application Support/Sketch", 510)]),
    ]

    /// A finished cleanup with the items it removed, for History previews and snapshots. Paths are under the home folder.
    private static func run(
        _ source: String, daysAgo days: Double, trash: Bool, _ items: [(String, Int)], restoredFirst: Bool = false
    ) -> HistoryRun {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let date = daysAgo(days)
        let entries = items.enumerated().map { index, item in
            HistoryItem(
                originalPath: home.appending(path: item.0).path,
                trashedPath: trash ? home.appending(path: ".Trash/\(URL(filePath: item.0).lastPathComponent)").path : nil,
                bytes: mb(Double(item.1)).bytes,
                restoredAt: restoredFirst && index == 0 ? date.addingTimeInterval(3_600) : nil
            )
        }
        return HistoryRun(
            record: CleanupRecord(
                date: date, source: source, itemCount: entries.count,
                freed: ByteSize(entries.map(\.bytes).reduce(0, +)), movedToTrash: trash
            ),
            items: entries
        )
    }
}

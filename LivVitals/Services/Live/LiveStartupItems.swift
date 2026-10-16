import Foundation
import LivCore

/// What starts by itself on this Mac: the launch agents and daemons, with the app each belongs to. Read-only.
nonisolated struct LiveStartupItems: StartupItemsProviding {
    let isSimulated = false
    let home: URL
    /// `/Library`. A test points it at a fake folder.
    let systemLibrary: URL
    let appFolders: [URL]

    init(
        home: URL,
        systemLibrary: URL = URL(filePath: "/Library", directoryHint: .isDirectory),
        appFolders: [URL]? = nil
    ) {
        self.home = home
        self.systemLibrary = systemLibrary
        self.appFolders = appFolders ?? AppInventory.standardFolders(home: home)
    }

    @concurrent func items() async -> [LaunchItem] {
        let installed = AppInventory(folders: appFolders).apps()
        return LaunchItemInventory(home: home, systemLibrary: systemLibrary, installed: installed).items()
    }
}

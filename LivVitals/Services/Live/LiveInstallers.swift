import Foundation
import LivCore

/// Installers: disk images and packages in Downloads and on the Desktop, and Homebrew's download cache.
nonisolated extension LiveCleanupScanner {
    static let mountedReason = "Mounted right now. Eject it first."
    static let unmatchedNote = "No installed app matches this installer."
    static let homebrewNote = "Homebrew downloads these again when it needs them."

    /// The disk images attached now, from `hdiutil info -plist`. Empty when hdiutil cannot answer.
    static let systemMountedImages: @Sendable () async -> Set<String> = {
        let process = Process()
        process.executableURL = URL(filePath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        do { try process.run() } catch { return [] }
        let timeout = Task {
            try await Task.sleep(for: .seconds(10))
            process.terminate()
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard let info = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { return [] }
        return Set(images.compactMap { $0["image-path"] as? String })
    }

    private var downloadsFolder: URL { home.appending(path: "Downloads", directoryHint: .isDirectory) }
    private var desktopFolder: URL { home.appending(path: "Desktop", directoryHint: .isDirectory) }
    private var homebrewDownloads: URL { home.appending(path: "Library/Caches/Homebrew/downloads", directoryHint: .isDirectory) }

    /// The folders Installers looks in when the user has not chosen any.
    var defaultInstallerFolders: [URL] { [downloadsFolder, desktopFolder] }

    /// The Desktop is searched at its first level only, since the rest of it is protected; the other folders go three deep.
    private func location(for folder: URL) -> InstallerLocation {
        let isDesktop = folder.resolvingSymlinksInPath().standardizedFileURL.path == desktopFolder.resolvingSymlinksInPath().standardizedFileURL.path
        return InstallerLocation(url: folder, maxDepth: isDesktop ? 1 : 3)
    }

    func scanInstallers(_ options: ScanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> ScanResult {
        let folders = options.installerFolders ?? defaultInstallerFolders
        onUpdate(ScanUpdate(fraction: nil, currentPath: (folders.first ?? downloadsFolder).abbreviatedPath))
        let guardian = installerGuard(whitelist: options.whitelist, folders: folders)
        let appNames = AppInventory(folders: appFolders).apps().map(\.name)
        let finder = InstallerFinder(
            locations: folders.map(location(for:)),
            guard: guardian,
            installedAppNames: appNames,
            mountedImages: await mountedImages()
        )
        let files = try finder.find()
        let brew = (try? guardian.validate(homebrewDownloads)) != nil && FileManager.default.fileExists(atPath: homebrewDownloads.path)
            ? [homebrewDownloads] : []

        let measurements = try await measure(files.map(\.url) + brew, guardian: guardian, onUpdate: onUpdate)
        var items = files.compactMap { file -> CleanupItem? in
            guard let size = measurements[file.url]?.size, size.bytes > 0 else { return nil }
            return CleanupItem(
                url: file.url,
                category: .installers,
                size: size,
                lastModified: Self.modificationDate(of: file.url),
                isSelectedByDefault: file.matchedApp != nil && !file.isMounted,
                note: file.matchedApp.map { "\($0) is installed." } ?? Self.unmatchedNote,
                blockedReason: file.isMounted ? Self.mountedReason : nil
            )
        }
        for folder in brew {
            guard let size = measurements[folder]?.size, size.bytes > 0 else { continue }
            items.append(CleanupItem(
                url: folder, category: .installers, size: size,
                lastModified: Self.modificationDate(of: folder), note: Self.homebrewNote
            ))
        }
        return ScanResult(items: items)
    }

    /// The chosen folders, the Homebrew cache and, through a narrow exception, installer files directly on the Desktop.
    /// The rest of the Desktop stays protected.
    func installerGuard(whitelist: [URL], folders: [URL]? = nil) -> SafetyGuard {
        SafetyGuard(
            home: home,
            allowedRoots: (folders ?? defaultInstallerFolders) + [homebrewDownloads.deletingLastPathComponent()],
            whitelist: whitelist,
            exceptions: [SafetyGuard.FileException(folder: desktopFolder, extensions: InstallerFinder.extensions)]
        )
    }
}

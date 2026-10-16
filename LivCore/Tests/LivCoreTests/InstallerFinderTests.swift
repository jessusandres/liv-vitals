import Foundation
import Testing
@testable import LivCore

struct InstallerFinderTests {
    private func finder(_ tmp: TemporaryDirectory, apps: [String] = [], mounted: Set<String> = [], whitelist: [URL] = []) throws -> InstallerFinder {
        let home = try tmp.directory("home")
        let downloads = try tmp.directory("home/Downloads")
        let desktop = try tmp.directory("home/Desktop")
        let guardian = SafetyGuard(
            home: home, allowedRoots: [downloads, desktop], whitelist: whitelist,
            exceptions: [SafetyGuard.FileException(folder: desktop, extensions: InstallerFinder.extensions)]
        )
        return InstallerFinder(
            locations: [InstallerLocation(url: downloads, maxDepth: 2), InstallerLocation(url: desktop, maxDepth: 1)],
            guard: guardian, installedAppNames: apps, mountedImages: mounted
        )
    }

    @Test func findsInstallersByExtensionAndDepth() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("home/Downloads/Tool.dmg", bytes: 10)
            try tmp.file("home/Downloads/Setup.PKG", bytes: 10)
            try tmp.file("home/Downloads/notes.txt")
            try tmp.file("home/Downloads/Old/Disk.iso")
            try tmp.file("home/Downloads/Old/Deeper/Too.deep.xip")
            try tmp.file("home/Downloads/.hidden/Secret.dmg")
            try tmp.file("home/Downloads/Some.app/Contents/Inner.pkg")
            try tmp.file("home/Downloads/Bundle.pkg/Contents/Archive.pax")
            try tmp.directory("home/Downloads/Fake.dmg")
            try tmp.file("home/Desktop/Desk.dmg")
            try tmp.file("home/Desktop/Nested/Desk2.dmg")
            try tmp.symlink("home/Downloads/Link.dmg", to: tmp.path("home/Downloads/Tool.dmg"))

            let found = try finder(tmp).find()
            #expect(found.map(\.url.lastPathComponent).sorted() == ["Bundle.pkg", "Desk.dmg", "Disk.iso", "Setup.PKG", "Tool.dmg"])
            #expect(found.first { $0.url.lastPathComponent == "Bundle.pkg" }?.url.hasDirectoryPath == true)
        }
    }

    @Test func tellsWhichAppAnInstallerIsFor() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.file("home/Downloads/dbeaver-ce-26.2.2-macos-aarch64.dmg")
            try tmp.file("home/Downloads/googlechrome.dmg")
            try tmp.file("home/Downloads/ubuntu-24.04.iso")
            let found = try finder(tmp, apps: ["DBeaver", "Google Chrome", "Go"]).find()
            let matched = Dictionary(uniqueKeysWithValues: found.map { ($0.url.lastPathComponent, $0.matchedApp ?? "-") })
            #expect(matched["dbeaver-ce-26.2.2-macos-aarch64.dmg"] == "DBeaver")
            #expect(matched["googlechrome.dmg"] == "Google Chrome")
            #expect(matched["ubuntu-24.04.iso"] == "-")
        }
    }

    @Test func marksMountedImagesAndSkipsWhitelistedFolders() async throws {
        try await TemporaryDirectory.use { tmp in
            let mounted = try tmp.file("home/Downloads/Mounted.dmg")
            try tmp.file("home/Downloads/Keep/Kept.dmg")
            let found = try finder(tmp, mounted: [mounted.path], whitelist: [tmp.path("home/Downloads/Keep")]).find()
            #expect(found.map(\.url.lastPathComponent) == ["Mounted.dmg"])
            #expect(found.first?.isMounted == true)
        }
    }

    @Test func keys() {
        #expect(InstallerFinder.key("dbeaver-ce-26.2.2-macos-aarch64.dmg") == "dbeaverce")
        #expect(InstallerFinder.key("fb6b0edbbb2bc5e50a9c73631f12fe1d810b5a6e2dc9e9e15a0f12930b3afaaa--Raycast.dmg") == "raycast")
        #expect(InstallerFinder.key("Xcode_26.xip") == "xcode")
        #expect(InstallerFinder.key("Google Chrome") == "googlechrome")
        #expect(InstallerFinder.key("archive.tar") == "archivetar")
    }
}

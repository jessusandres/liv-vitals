import Foundation
import Testing
@testable import LivCore

extension TemporaryDirectory {
    /// A minimal app bundle: `Contents/Info.plist` and an executable-sized file.
    @discardableResult
    func app(_ relative: String, id: String?, name: String? = nil, executable: String? = nil, appStore: Bool = false) throws -> URL {
        let bundle = try directory(relative)
        var info: [String: Any] = ["CFBundleShortVersionString": "1.2"]
        if let id { info["CFBundleIdentifier"] = id }
        if let name { info["CFBundleName"] = name }
        if let executable { info["CFBundleExecutable"] = executable }
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try file("\(relative)/Contents/Info.plist")
        try data.write(to: bundle.appending(path: "Contents/Info.plist"))
        try file("\(relative)/Contents/MacOS/\(executable ?? "app")", bytes: 2_048)
        if appStore { try file("\(relative)/Contents/_MASReceipt/receipt", bytes: 10) }
        return bundle
    }
}

struct AppInventoryTests {
    @Test func readsBundlesAndTheirSubfolders() async throws {
        try await TemporaryDirectory.use { tmp in
            let apps = try tmp.directory("Applications")
            try tmp.app("Applications/Zed.app", id: "dev.zed.Zed", name: "Zed", executable: "zed")
            try tmp.app("Applications/Utilities/Tool.app", id: "com.example.tool")
            try tmp.app("Applications/Broken.app", id: nil)
            try tmp.app("Applications/(A Document Being Saved By Sparkle)/Zed.app", id: "dev.zed.Zed")
            try tmp.file("Applications/readme.txt")
            try tmp.symlink("Applications/Linked.app", to: tmp.path("Applications/Zed.app"))

            let found = AppInventory(folders: [apps, tmp.path("missing")]).apps()
            #expect(found.map(\.bundleID) == ["com.example.tool", "dev.zed.Zed"])

            let zed = try #require(found.first { $0.bundleID == "dev.zed.Zed" })
            #expect(zed.name == "Zed")
            #expect(zed.version == "1.2")
            #expect(zed.executableName == "zed")
            #expect(zed.url.hasDirectoryPath)
            #expect(!zed.needsAdmin)
            #expect(!zed.isAppStore && !zed.isApple)
            // Without CFBundleName the bundle's file name is used.
            #expect(found.first { $0.bundleID == "com.example.tool" }?.name == "Tool")
        }
    }

    @Test func flagsAppStoreAppleAndReadOnlyBundles() async throws {
        try await TemporaryDirectory.use { tmp in
            let apps = try tmp.directory("Applications")
            try tmp.app("Applications/Store.app", id: "com.example.store", appStore: true)
            try tmp.app("Applications/Pages.app", id: "com.apple.iWork.Pages")
            let locked = try tmp.app("Applications/Locked.app", id: "com.example.locked")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }

            let found = Dictionary(uniqueKeysWithValues: AppInventory(folders: [apps]).apps().map { ($0.bundleID, $0) })
            #expect(found["com.example.store"]?.isAppStore == true)
            #expect(found["com.apple.iWork.Pages"]?.isApple == true)
            #expect(found["com.example.locked"]?.needsAdmin == true)
            #expect(found["com.example.store"]?.needsAdmin == false)
        }
    }

    @Test func nameKeysSkipShortNames() {
        let app = InstalledApp(url: URL(filePath: "/Applications/OBS.app"), bundleID: "com.obsproject.obs-studio", name: "OB", executableName: "obs")
        #expect(app.nameKeys == ["obs"])
    }
}

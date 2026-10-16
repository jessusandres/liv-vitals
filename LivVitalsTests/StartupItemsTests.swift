import Foundation
import LivCore
import Testing
@testable import LivVitals

extension TemporaryDirectory {
    /// A launchd job plist that runs `program`.
    @discardableResult
    func launchJob(_ relative: String, label: String, program: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["Label": label, "ProgramArguments": [program]], format: .xml, options: 0).write(to: target)
        return target
    }
}

@MainActor
struct StartupItemsTests {
    private func owner(_ name: String) -> InstalledApp {
        InstalledApp(url: URL(filePath: "/Applications/\(name).app", directoryHint: .isDirectory), bundleID: "com.example.\(name.lowercased())", name: name)
    }

    private func item(_ label: String, owner: InstalledApp?, exists: Bool = true, scope: LaunchItem.Scope = .user) -> LaunchItem {
        LaunchItem(
            url: URL(filePath: "/tmp/\(label).plist"), scope: scope, label: label,
            program: "/bin/\(label)", programExists: exists, owner: owner
        )
    }

    // MARK: The service

    @Test func theRealServiceListsWhatStartsByItselfWithItsOwnerAndWhetherItsProgramExists() async throws {
        try await TemporaryDirectory.use { tmp in
            let tool = try tmp.app("Applications/Tool.app", id: "com.example.tool")
            let runner = try tmp.file("bin/runner", bytes: 10)
            try tmp.launchJob("home/Library/LaunchAgents/com.example.tool.agent.plist", label: "com.example.tool.agent", program: tool.appending(path: "Contents/MacOS/app").path)
            try tmp.launchJob("Library/LaunchDaemons/com.example.gone.plist", label: "com.example.gone", program: tmp.path("bin/missing").path)
            try tmp.launchJob("Library/LaunchAgents/com.example.shared.plist", label: "com.example.shared", program: runner.path)
            try tmp.launchJob("Library/LaunchDaemons/com.apple.thing.plist", label: "com.apple.thing", program: "/bin/ls")

            let service = LiveStartupItems(home: tmp.path("home"), systemLibrary: tmp.path("Library"), appFolders: [tmp.path("Applications")])
            let items = await service.items()

            #expect(!service.isSimulated)
            #expect(items.map(\.label) == ["com.example.gone", "com.example.shared", "com.example.tool.agent"])
            let byLabel = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0) })
            #expect(byLabel["com.example.tool.agent"]?.owner?.bundleID == "com.example.tool")
            #expect(byLabel["com.example.tool.agent"]?.scope == .user)
            #expect(byLabel["com.example.gone"]?.scope == .systemDaemon && byLabel["com.example.gone"]?.programExists == false)
            #expect(byLabel["com.example.shared"]?.scope == .systemAgent && byLabel["com.example.shared"]?.owner == nil)
        }
    }

    @Test func theServiceChangesNothingOnDisk() async throws {
        try await TemporaryDirectory.use { tmp in
            let plist = try tmp.launchJob("home/Library/LaunchAgents/com.example.a.plist", label: "com.example.a", program: "/bin/ls")
            let before = try Data(contentsOf: plist)
            _ = await LiveStartupItems(home: tmp.path("home"), systemLibrary: tmp.path("Library"), appFolders: [tmp.path("Applications")]).items()
            #expect(try Data(contentsOf: plist) == before)
            #expect(FileManager.default.fileExists(atPath: plist.path))
        }
    }

    // MARK: The model

    @Test func itemsAreGroupedByAppSortedByNameWithTheUnknownOnesLast() async {
        let chrome = owner("Chrome")
        let docker = owner("Docker")
        let model = StartupItemsModel(service: FakeStartupItems(found: [
            item("zeta.helper", owner: nil),
            item("com.docker.b", owner: docker),
            item("com.chrome.z", owner: chrome),
            item("com.chrome.a", owner: chrome),
        ]))
        await model.load()

        #expect(model.groups.map(\.title) == ["Chrome", "Docker", "Unknown"])
        #expect(model.groups[0].items.map(\.label) == ["com.chrome.a", "com.chrome.z"])
        #expect(model.groups[2].owner == nil && model.groups[2].items.map(\.label) == ["zeta.helper"])
    }

    @Test func itemsWhoseProgramIsGoneAreCounted() async {
        let model = StartupItemsModel(service: FakeStartupItems(found: [
            item("a", owner: nil, exists: false), item("b", owner: nil), item("c", owner: owner("Tool"), exists: false),
        ]))
        await model.load()
        #expect(model.missingProgramCount == 2)
        #expect(model.items.count == 3)
    }

    @Test func nothingLoadedYetIsNotTheSameAsNothingFound() async {
        let model = StartupItemsModel(service: FakeStartupItems(found: []))
        #expect(!model.hasLoaded && model.groups.isEmpty)
        await model.load()
        #expect(model.hasLoaded && model.groups.isEmpty && model.missingProgramCount == 0)
    }

    @Test func knownItemsShowAtOnceAndTheAppStoreSharesTheModel() async {
        let preloaded = StartupItemsModel(service: FakeStartupItems(), items: [item("a", owner: nil)])
        #expect(preloaded.hasLoaded && preloaded.items.count == 1)

        let store = AppStore(services: .fake(startupItems: FakeStartupItems(found: [item("a", owner: owner("Tool"))])))
        await store.startupItems.load()
        #expect(store.startupItems.groups.map(\.title) == ["Tool"])
    }

    @Test func theSimulatedServiceHasAGoneProgramToShow() async {
        let items = await MockStartupItems().items()
        #expect(MockStartupItems().isSimulated)
        #expect(items.contains { !$0.programExists } && items.contains { $0.owner == nil })
    }
}

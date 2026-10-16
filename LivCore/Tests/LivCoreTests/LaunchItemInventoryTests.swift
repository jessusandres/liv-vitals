import Foundation
import Testing
@testable import LivCore

extension TemporaryDirectory {
    /// A launchd job plist.
    @discardableResult
    func plist(_ relative: String, _ content: [String: Any]) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: content, format: .xml, options: 0).write(to: target)
        return target
    }
}

struct LaunchItemInventoryTests {
    private func inventory(_ tmp: TemporaryDirectory) -> LaunchItemInventory {
        let installed = AppInventory(folders: [tmp.path("Applications")]).apps()
        return LaunchItemInventory(home: tmp.path("home"), systemLibrary: tmp.path("Library"), installed: installed)
    }

    @Test func listsTheThreeFoldersWithTheirScopeAndLeavesAppleAndJunkOut() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.plist("home/Library/LaunchAgents/com.example.user.plist", ["Label": "com.example.user", "Program": "/bin/ls"])
            try tmp.plist("Library/LaunchAgents/com.example.shared.plist", ["Label": "com.example.shared", "Program": "/bin/ls"])
            try tmp.plist("Library/LaunchDaemons/com.example.daemon.plist", ["Label": "com.example.daemon", "Program": "/bin/ls"])
            try tmp.plist("Library/LaunchDaemons/com.apple.thing.plist", ["Label": "com.apple.thing"])
            try tmp.plist("Library/LaunchDaemons/com.example.relabelled.plist", ["Label": "com.apple.disguised"])
            try tmp.file("Library/LaunchDaemons/notes.txt", bytes: 5)
            try tmp.file("Library/LaunchDaemons/garbage.plist", bytes: 9)
            try tmp.symlink("Library/LaunchDaemons/link.plist", to: tmp.path("home/Library/LaunchAgents/com.example.user.plist"))

            let items = inventory(tmp).items()
            #expect(items.map(\.label) == ["com.example.daemon", "com.example.shared", "com.example.user"])
            let scopes = Dictionary(uniqueKeysWithValues: items.map { ($0.label, $0.scope) })
            #expect(scopes["com.example.user"] == .user)
            #expect(scopes["com.example.shared"] == .systemAgent)
            #expect(scopes["com.example.daemon"] == .systemDaemon)
        }
    }

    @Test func anItemBelongsToTheAppByBundleIDOrByItsProgram() async throws {
        try await TemporaryDirectory.use { tmp in
            let tool = try tmp.app("Applications/Tool.app", id: "com.example.tool")
            try tmp.plist("home/Library/LaunchAgents/com.example.tool.helper.plist", ["Label": "com.example.tool.helper", "Program": "/bin/ls"])
            try tmp.plist(
                "home/Library/LaunchAgents/odd.plist",
                ["Label": "odd.name", "ProgramArguments": [tool.appending(path: "Contents/MacOS/app").path, "--agent"]]
            )
            try tmp.plist("home/Library/LaunchAgents/nobody.plist", ["Label": "nobody.owns.this", "Program": "/bin/ls"])

            let byLabel = Dictionary(uniqueKeysWithValues: inventory(tmp).items().map { ($0.label, $0) })
            #expect(byLabel["com.example.tool.helper"]?.owner?.bundleID == "com.example.tool")
            #expect(byLabel["odd.name"]?.owner?.bundleID == "com.example.tool")
            #expect(byLabel["nobody.owns.this"]?.owner == nil)
        }
    }

    @Test func aLabelMissingFromThePlistFallsBackToTheFileName() async throws {
        try await TemporaryDirectory.use { tmp in
            try tmp.app("Applications/Tool.app", id: "com.example.tool")
            try tmp.plist("home/Library/LaunchAgents/com.example.tool.agent.plist", ["Program": "/bin/ls"])

            let item = try #require(inventory(tmp).items().first)
            #expect(item.label == "com.example.tool.agent")
            #expect(item.owner?.bundleID == "com.example.tool")
        }
    }

    @Test func aProgramThatIsGoneIsReported() async throws {
        try await TemporaryDirectory.use { tmp in
            let runner = try tmp.file("bin/runner", bytes: 10)
            try tmp.plist("home/Library/LaunchAgents/com.example.here.plist", ["Label": "com.example.here", "Program": runner.path])
            try tmp.plist("home/Library/LaunchAgents/com.example.gone.plist", ["Label": "com.example.gone", "ProgramArguments": [tmp.path("bin/missing").path]])
            try tmp.plist("home/Library/LaunchAgents/com.example.none.plist", ["Label": "com.example.none"])

            let byLabel = Dictionary(uniqueKeysWithValues: inventory(tmp).items().map { ($0.label, $0) })
            #expect(byLabel["com.example.here"]?.programExists == true)
            #expect(byLabel["com.example.gone"]?.programExists == false)
            #expect(byLabel["com.example.gone"]?.program == tmp.path("bin/missing").path)
            // No program to check is not a missing program.
            #expect(byLabel["com.example.none"]?.programExists == true)
            #expect(byLabel["com.example.none"]?.program == nil)
        }
    }

    @Test func missingFoldersGiveAnEmptyList() async throws {
        try await TemporaryDirectory.use { tmp in
            #expect(inventory(tmp).items().isEmpty)
        }
    }
}

struct LaunchJobTests {
    @Test func programWinsOverProgramArguments() async throws {
        try await TemporaryDirectory.use { tmp in
            let both = try tmp.plist("both.plist", ["Label": "x.y.z", "Program": "/bin/one", "ProgramArguments": ["/bin/two"]])
            let args = try tmp.plist("args.plist", ["ProgramArguments": ["/bin/two", "-v"]])
            #expect(LaunchJob.read(at: both) == LaunchJob(label: "x.y.z", program: "/bin/one"))
            #expect(LaunchJob.read(at: args) == LaunchJob(label: nil, program: "/bin/two"))
        }
    }

    @Test func somethingThatIsNotAPlistIsNil() async throws {
        try await TemporaryDirectory.use { tmp in
            let junk = try tmp.file("junk.plist", bytes: 12)
            #expect(LaunchJob.read(at: junk) == nil)
            #expect(LaunchJob.read(at: tmp.path("missing.plist")) == nil)
        }
    }

    @Test func aTargetNeedsASafeLabelAndNamesItsDomain() {
        #expect(LaunchJobTarget(label: "com.example.tool-helper_2+x", domain: .system)?.specifier == "system/com.example.tool-helper_2+x")
        #expect(LaunchJobTarget(label: "com.example.agent", domain: .user(uid: 501))?.specifier == "gui/501/com.example.agent")
        for bad in ["", "-x", "--help", "a b", "a/b", "a;b", "a\nb", "$(x)", "a\"b", "é", String(repeating: "a", count: 256)] {
            #expect(LaunchJobTarget(label: bad, domain: .system) == nil, "\(bad.debugDescription)")
        }
    }
}

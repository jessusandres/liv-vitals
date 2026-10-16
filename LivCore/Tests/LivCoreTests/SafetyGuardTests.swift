import Foundation
import Testing
@testable import LivCore

extension SafetyViolation {
    /// The case name, so tests can assert on the kind without comparing URLs.
    var kind: String {
        switch self {
        case .notAbsolute: "notAbsolute"
        case .protected: "protected"
        case .whitelisted: "whitelisted"
        case .outsideAllowedRoots: "outsideAllowedRoots"
        case .isAllowedRoot: "isAllowedRoot"
        case .containsProtected: "containsProtected"
        case .blocked: "blocked"
        }
    }
}

struct SafetyGuardTests {
    /// A fake home with `Library/Caches` as the only allowed root, inside the test's temporary folder.
    private struct Fixture {
        let home: URL
        let root: URL

        init(_ tmp: TemporaryDirectory, whitelist: [URL] = []) throws {
            home = try tmp.directory("home")
            root = try tmp.directory("home/Library/Caches")
            self.whitelist = whitelist
        }

        let whitelist: [URL]

        var guardian: SafetyGuard {
            SafetyGuard(home: home, allowedRoots: [root], whitelist: whitelist)
        }
    }

    private func violation(_ guardian: SafetyGuard, _ url: URL) -> String? {
        do {
            _ = try guardian.validate(url)
            return nil
        } catch {
            return error.kind
        }
    }

    @Test func acceptsPathInsideRootAndReturnsNormalizedURL() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            let target = fixture.root.appending(path: "a/./com.example.app")
            let normalized = try fixture.guardian.validate(target)
            #expect(normalized.path == tmp.resolved.path + "/home/Library/Caches/a/com.example.app")
        }
    }

    @Test func rejectsRootOutsideAndRelativePaths() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            #expect(violation(fixture.guardian, fixture.root) == "isAllowedRoot")
            #expect(violation(fixture.guardian, tmp.path("elsewhere/file")) == "outsideAllowedRoots")
            #expect(violation(fixture.guardian, URL(string: "relative/path")!) == "notAbsolute")
        }
    }

    @Test func misleadingPrefixIsOutsideTheRoot() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            let guardian = SafetyGuard(home: home, allowedRoots: [tmp.path("Lib")])
            #expect(violation(guardian, tmp.path("Library/x")) == "outsideAllowedRoots")
            #expect(violation(guardian, tmp.path("Lib/x")) == nil)
        }
    }

    @Test func dotDotThatEscapesTheRootIsRejected() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            #expect(violation(fixture.guardian, fixture.root.appending(path: "a/../../etc")) == "outsideAllowedRoots")
        }
    }

    @Test func parentSymlinkPointingOutsideIsRejected() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            let outside = try tmp.directory("outside")
            try tmp.symlink("home/Library/Caches/link", to: outside)
            #expect(violation(fixture.guardian, fixture.root.appending(path: "link/inner")) == "outsideAllowedRoots")
        }
    }

    @Test func symlinkAsTheTargetItselfIsAcceptedAsTheLink() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            let outside = try tmp.directory("outside")
            let link = try tmp.symlink("home/Library/Caches/link", to: outside)
            let normalized = try fixture.guardian.validate(link)
            #expect(normalized.path == tmp.resolved.path + "/home/Library/Caches/link")
        }
    }

    @Test func protectedPathIgnoresLetterCase() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            let guardian = SafetyGuard(home: home, allowedRoots: [home.appending(path: "Library")])
            #expect(violation(guardian, home.appending(path: "LIBRARY/KEYCHAINS/login.keychain-db")) == "protected")
        }
    }

    @Test func protectedWinsOverAllowedRoot() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            let guardian = SafetyGuard(home: home, allowedRoots: [home.appending(path: "Library")])
            #expect(violation(guardian, home.appending(path: "Library/Keychains/x")) == "protected")
            #expect(violation(guardian, home.appending(path: "Library/Keychains")) == "protected")
            #expect(violation(guardian, home.appending(path: "Library/Caches/x")) == nil)
        }
    }

    @Test func whitelistBlocksTheEntryItsSubfoldersAndItsParents() async throws {
        try await TemporaryDirectory.use { tmp in
            let keep = tmp.path("home/Library/Caches/a/keep")
            let fixture = try Fixture(tmp, whitelist: [keep])
            #expect(violation(fixture.guardian, keep) == "whitelisted")
            #expect(violation(fixture.guardian, keep.appending(path: "sub/file")) == "whitelisted")
            // Removing the parent would remove the whitelisted folder with it.
            #expect(violation(fixture.guardian, fixture.root.appending(path: "a")) == "whitelisted")
            #expect(violation(fixture.guardian, fixture.root.appending(path: "b")) == nil)
        }
    }

    @Test func rootHomeAndTheirAncestorsContainProtectedPaths() async throws {
        try await TemporaryDirectory.use { tmp in
            let fixture = try Fixture(tmp)
            let guardian = fixture.guardian
            #expect(violation(guardian, URL(filePath: "/")) == "containsProtected")
            #expect(violation(guardian, fixture.home) == "containsProtected")
            #expect(violation(guardian, fixture.home.deletingLastPathComponent()) == "containsProtected")
            // `~/Library` holds protected folders such as Keychains.
            #expect(violation(guardian, fixture.home.appending(path: "Library")) == "containsProtected")
        }
    }

    @Test func onlyWhitelistEntriesAreExcludedFromScans() async throws {
        try await TemporaryDirectory.use { tmp in
            let keep = tmp.path("home/Library/Caches/keep")
            let fixture = try Fixture(tmp, whitelist: [keep])
            let guardian = fixture.guardian
            #expect(guardian.isExcludedFromScan(keep))
            #expect(guardian.isExcludedFromScan(keep.appending(path: "deep/file")))
            #expect(!guardian.isExcludedFromScan(fixture.root.appending(path: "keeper")))
            #expect(!guardian.isExcludedFromScan(fixture.home.appending(path: "Library/Keychains")))
        }
    }

    // MARK: - File exceptions (Installers on the Desktop)

    @Test func exceptionAllowsOnlyItsExtensionsDirectlyInTheFolder() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            let desktop = try tmp.directory("home/Desktop")
            let exception = SafetyGuard.FileException(folder: desktop, extensions: ["dmg", "PKG"])
            let guardian = SafetyGuard(home: home, allowedRoots: [desktop], exceptions: [exception])

            #expect(violation(guardian, desktop.appending(path: "Tool.dmg")) == nil)
            #expect(violation(guardian, desktop.appending(path: "Tool.DMG")) == nil)
            #expect(violation(guardian, desktop.appending(path: "Setup.pkg")) == nil)
            #expect(violation(guardian, desktop.appending(path: "notes.txt")) == "protected")
            #expect(violation(guardian, desktop.appending(path: "dmg")) == "protected")
            #expect(violation(guardian, desktop.appending(path: "Folder/Tool.dmg")) == "protected")
            #expect(violation(guardian, desktop) == "protected")
        }
    }

    @Test func withoutExceptionTheDesktopStaysProtected() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            let desktop = try tmp.directory("home/Desktop")
            let guardian = SafetyGuard(home: home, allowedRoots: [desktop])
            #expect(violation(guardian, desktop.appending(path: "Tool.dmg")) == "protected")
        }
    }

    @Test func whitelistStillWinsOverAnException() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = try tmp.directory("home")
            let desktop = try tmp.directory("home/Desktop")
            let keep = desktop.appending(path: "Keep.dmg")
            let guardian = SafetyGuard(
                home: home, allowedRoots: [desktop], whitelist: [keep],
                exceptions: [SafetyGuard.FileException(folder: desktop, extensions: ["dmg"])]
            )
            #expect(violation(guardian, keep) == "whitelisted")
            #expect(violation(guardian, desktop.appending(path: "Other.dmg")) == nil)
        }
    }
}

import Darwin
import Foundation
import Testing
@testable import LivCore

struct FullDiskAccessTests {
    private let home = URL(filePath: "/Users/example")

    /// A probe that answers by file name and records which files were tried.
    private func status(_ answers: [String: FullDiskAccess.ProbeResult]) -> (FullDiskAccess.Status, [String]) {
        nonisolated(unsafe) var asked: [String] = []
        let result = FullDiskAccess.check(home: home) { url in
            asked.append(url.lastPathComponent)
            return answers[url.lastPathComponent] ?? .missing
        }
        return (result, asked)
    }

    @Test func readableProbeFileMeansGranted() {
        #expect(status(["TCC.db": .readable]).0 == .granted)
    }

    @Test func notPermittedMeansDenied() {
        #expect(status(["TCC.db": .notPermitted]).0 == .denied)
    }

    @Test func theFirstConclusiveAnswerWins() {
        let (result, asked) = status(["TCC.db": .notPermitted, "Bookmarks.plist": .readable])
        #expect(result == .denied)
        #expect(asked == ["TCC.db"])
    }

    @Test func aMissingFileFallsThroughToTheNextOne() {
        let (result, asked) = status(["TCC.db": .missing, "Bookmarks.plist": .readable])
        #expect(result == .granted)
        #expect(asked == ["TCC.db", "Bookmarks.plist"])
    }

    @Test func inconclusiveErrorsAreNotTreatedAsDenied() {
        #expect(status(["TCC.db": .inconclusive, "Bookmarks.plist": .inconclusive]).0 == .undetermined)
        #expect(status([:]).0 == .undetermined)
    }

    @Test func openingRealFilesClassifiesThem() async throws {
        try await TemporaryDirectory.use { tmp in
            let readable = try tmp.file("a.txt", bytes: 4)
            #expect(FullDiskAccess.openForReading(readable) == .readable)
            #expect(FullDiskAccess.openForReading(tmp.path("missing.txt")) == .missing)
            // A parent that is a file, not a folder.
            #expect(FullDiskAccess.openForReading(readable.appending(path: "child")) == .missing)

            // Plain file permissions are EACCES, which says nothing about Full Disk Access.
            let locked = try tmp.file("locked.txt", bytes: 4)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked.path) }
            #expect(FullDiskAccess.openForReading(locked) == .inconclusive)
        }
    }

    @Test func settingsURLPointsAtTheFullDiskAccessPane() {
        #expect(FullDiskAccess.settingsURL.absoluteString.hasSuffix("Privacy_AllFiles"))
    }
}

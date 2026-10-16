import Foundation

/// A throwaway folder inside the system temporary directory. Tests never touch any other path.
struct TemporaryDirectory {
    let url: URL

    /// Creates the folder, runs `body`, and deletes the folder afterwards.
    @discardableResult
    static func use<T>(_ body: (TemporaryDirectory) async throws -> T) async throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "LivCoreTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try await body(TemporaryDirectory(url: url))
    }

    /// The folder with its symlinks resolved, as `SafetyGuard` reports paths.
    var resolved: URL { url.resolvingSymlinksInPath() }

    func path(_ relative: String) -> URL {
        url.appending(path: relative)
    }

    @discardableResult
    func directory(_ relative: String) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func file(_ relative: String, bytes: Int = 0) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(count: bytes).write(to: target)
        return target
    }

    @discardableResult
    func symlink(_ relative: String, to destination: URL) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination)
        return target
    }

    @discardableResult
    func hardLink(_ relative: String, to existing: URL) throws -> URL {
        let target = path(relative)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.linkItem(at: existing, to: target)
        return target
    }
}

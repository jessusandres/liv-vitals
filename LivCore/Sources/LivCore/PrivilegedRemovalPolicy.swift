import Darwin
import Foundation

/// What may be moved to the Trash with administrator rights. Everything else is refused, whatever the
/// selection says.
///
/// Allowed: an `.app` directly inside an applications folder (or a plain subfolder of one) that is not Apple's
/// own, and a file directly inside `LaunchDaemons`, `LaunchAgents` or `PrivilegedHelperTools` of the system
/// library whose name does not start with `com.apple.`. Never a symlink, never the folder itself.
///
/// The app checks a path with this policy twice: when it plans and right before it asks for the password.
public struct PrivilegedRemovalPolicy: Sendable {
    private let appFolderKeys: [PathMath.Components]
    private let systemFolderKeys: [PathMath.Components]

    /// - Parameters:
    ///   - appFolders: `/Applications` (and any other folder apps are installed in).
    ///   - systemLibrary: `/Library`.
    public init(appFolders: [URL], systemLibrary: URL) {
        appFolderKeys = appFolders.map { PathMath.components(of: $0.resolvingSymlinksInPath()) }
        let library = systemLibrary.resolvingSymlinksInPath()
        systemFolderKeys = ["LaunchDaemons", "LaunchAgents", "PrivilegedHelperTools"].map {
            PathMath.components(of: library.appending(path: $0, directoryHint: .isDirectory))
        }
    }

    /// The normalized URL, or why not. The symlinks of its parent folders are resolved; act on the result.
    public func validate(_ url: URL) throws(SafetyViolation) -> URL {
        guard url.isFileURL, url.path.hasPrefix("/") else { throw .notAbsolute(url.path) }
        let target = PathMath.canonical(url)
        let key = PathMath.components(of: target)

        if appFolderKeys.contains(key) || systemFolderKeys.contains(key) { throw .isAllowedRoot(target) }

        let parent = Array(key.dropLast())
        let isInApps = appFolderKeys.contains(parent) || appFolderKeys.contains(Array(parent.dropLast()))
        if target.pathExtension.lowercased() == "app", isInApps {
            return try validateApp(target, parent: parent)
        }
        if systemFolderKeys.contains(parent) {
            return try validateSystemFile(target)
        }
        throw .outsideAllowedRoots(target)
    }

    /// Whether `destination` is a place an item may be put back to with administrator rights: the same
    /// folders `validate` allows, judged by the location and the name, since nothing is there yet.
    /// `source` is the item in the Trash; an app bundle is read from there, so Apple's own apps stay refused.
    ///
    /// Checked when a restore is planned and right before the password is asked.
    public func validateDestination(_ destination: URL, movedFrom source: URL) throws(SafetyViolation) -> URL {
        guard destination.isFileURL, destination.path.hasPrefix("/") else { throw .notAbsolute(destination.path) }
        let target = PathMath.canonical(destination)
        let key = PathMath.components(of: target)

        if appFolderKeys.contains(key) || systemFolderKeys.contains(key) { throw .isAllowedRoot(target) }

        let parent = Array(key.dropLast())
        let isInApps = appFolderKeys.contains(parent) || appFolderKeys.contains(Array(parent.dropLast()))
        if target.pathExtension.lowercased() == "app", isInApps {
            if !appFolderKeys.contains(parent) {
                let folder = target.deletingLastPathComponent().lastPathComponent
                if folder.hasPrefix(".") || folder.hasPrefix("(") || !(folder as NSString).pathExtension.isEmpty {
                    throw .outsideAllowedRoots(target)
                }
            }
            var status = stat()
            guard lstat(source.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFDIR else {
                throw .blocked(target, reason: "Not a regular app folder, so it will not be put back as an administrator.")
            }
            guard let app = InstalledApp.read(at: source) else {
                throw .blocked(target, reason: "Not an app bundle, so it will not be put back as an administrator.")
            }
            if app.isApple && !app.isAppStore {
                throw .blocked(target, reason: "Apple's own apps are never put back as an administrator.")
            }
            return target
        }
        if systemFolderKeys.contains(parent) {
            if target.lastPathComponent.lowercased().hasPrefix("com.apple.") {
                throw .blocked(target, reason: "Apple's own services are never put back as an administrator.")
            }
            var status = stat()
            guard lstat(source.path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else {
                throw .blocked(target, reason: "Not a regular file, so it will not be put back as an administrator.")
            }
            return target
        }
        throw .outsideAllowedRoots(target)
    }

    /// True when `url` lies inside an applications folder or one of the system library's service folders:
    /// the places that usually belong to root.
    func isInPrivilegedZone(_ url: URL) -> Bool {
        let key = PathMath.components(of: PathMath.canonical(url))
        return (appFolderKeys + systemFolderKeys).contains { PathMath.isStrictlyInside(key, of: $0) }
    }

    private func validateApp(_ target: URL, parent: PathMath.Components) throws(SafetyViolation) -> URL {
        // A subfolder of an applications folder must be a plain one, like `Utilities`.
        if !appFolderKeys.contains(parent) {
            let folder = target.deletingLastPathComponent().lastPathComponent
            if folder.hasPrefix(".") || folder.hasPrefix("(") || !(folder as NSString).pathExtension.isEmpty {
                throw .outsideAllowedRoots(target)
            }
        }
        var status = stat()
        guard lstat(target.path, &status) == 0 else { throw .outsideAllowedRoots(target) }
        guard (status.st_mode & S_IFMT) == S_IFDIR else {
            throw .blocked(target, reason: "Not a regular app folder, so it will not be removed as an administrator.")
        }
        guard let app = InstalledApp.read(at: target) else {
            throw .blocked(target, reason: "Not an app bundle, so it will not be removed as an administrator.")
        }
        if app.isApple && !app.isAppStore {
            throw .blocked(target, reason: "Apple's own apps are never removed.")
        }
        return target
    }

    private func validateSystemFile(_ target: URL) throws(SafetyViolation) -> URL {
        if target.lastPathComponent.lowercased().hasPrefix("com.apple.") {
            throw .blocked(target, reason: "Apple's own services are never removed.")
        }
        var status = stat()
        guard lstat(target.path, &status) == 0 else { throw .outsideAllowedRoots(target) }
        guard (status.st_mode & S_IFMT) == S_IFREG else {
            throw .blocked(target, reason: "Not a regular file, so it will not be removed as an administrator.")
        }
        return target
    }
}

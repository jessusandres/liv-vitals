import Darwin
import Foundation

/// What "Put Back" does with one item.
public enum RestoreStep: Sendable, Equatable {
    /// The user can move it home themselves.
    case asUser(from: URL, to: URL)
    /// It needs the administrator's password: an app or a service file in a system folder.
    case asAdmin(from: URL, to: URL)
    /// It stays where it is. The reason is in English.
    case skip(String)
}

/// Decides, item by item, whether and how a removed thing can be put back. Nothing is moved here.
///
/// Only items that sit directly inside the user's Trash can be restored, so an edited log cannot make the app
/// move anything else. Nothing is ever overwritten and no folder is created. Both the Trash location and the
/// destination are checked again right before the move, by planning the item once more.
public struct RestorePlanner: Sendable {
    private let trashKey: PathMath.Components
    private let safetyGuard: SafetyGuard
    private let policy: PrivilegedRemovalPolicy

    /// - Parameters:
    ///   - home: The user's home folder; its `.Trash` is the only place an item is restored from.
    ///   - appFolders: `/Applications` (and any other folder apps are installed in).
    ///   - systemLibrary: `/Library`.
    public init(home: URL, appFolders: [URL], systemLibrary: URL) {
        trashKey = PathMath.components(of: home.appending(path: ".Trash", directoryHint: .isDirectory).resolvingSymlinksInPath())
        // The whitelist protects from removing, not from putting something back (decision 4). The protected
        // defaults still apply, with the Desktop open to installer files only.
        safetyGuard = SafetyGuard(
            home: home,
            allowedRoots: [home] + appFolders,
            exceptions: [SafetyGuard.FileException(
                folder: home.appending(path: "Desktop", directoryHint: .isDirectory),
                extensions: InstallerFinder.extensions
            )]
        )
        policy = PrivilegedRemovalPolicy(appFolders: appFolders, systemLibrary: systemLibrary)
    }

    public func plan(_ item: HistoryItem) -> RestoreStep {
        guard let trashedPath = item.trashedPath else {
            return .skip("Deleted for good; it cannot be put back.")
        }
        guard trashedPath.hasPrefix("/"), item.originalPath.hasPrefix("/") else { return .skip("Not in the Trash.") }

        // 1. Where it is now: directly inside the Trash, and not a link.
        let trashed = PathMath.canonical(URL(filePath: trashedPath))
        guard Array(PathMath.components(of: trashed).dropLast()) == trashKey else { return .skip("Not in the Trash.") }
        var status = stat()
        guard lstat(trashed.path, &status) == 0 else { return .skip("No longer in the Trash.") }
        let trashedType = status.st_mode & S_IFMT
        guard trashedType != S_IFLNK else { return .skip("Not in the Trash.") }

        // 2. Where it goes: nothing there, and its folder still exists.
        let original = PathMath.canonical(URL(filePath: item.originalPath, directoryHint: trashedType == S_IFDIR ? .isDirectory : .notDirectory))
        guard lstat(original.path, &status) != 0 else { return .skip("Something else is at the original location.") }
        let folder = original.deletingLastPathComponent()
        var folderStatus = stat()
        guard stat(folder.path, &folderStatus) == 0, (folderStatus.st_mode & S_IFMT) == S_IFDIR else {
            return .skip("Its folder no longer exists.")
        }

        // 3. Who may move it.
        if policy.isInPrivilegedZone(original), !userCanMove(trashed, into: folder) {
            do {
                return .asAdmin(from: trashed, to: try policy.validateDestination(original, movedFrom: trashed))
            } catch {
                return .skip(error.description)
            }
        }
        do {
            return .asUser(from: trashed, to: try safetyGuard.validate(original))
        } catch {
            return .skip(error.description)
        }
    }

    /// A folder moves between folders only when the user may write to the item, to its new folder and to
    /// the Trash it leaves.
    private func userCanMove(_ item: URL, into folder: URL) -> Bool {
        access(folder.path, W_OK) == 0 && access(item.path, W_OK) == 0
    }
}

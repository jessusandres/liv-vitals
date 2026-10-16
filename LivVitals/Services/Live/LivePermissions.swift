import Foundation
import LivCore

/// Reads the real Full Disk Access state of this app.
nonisolated struct LivePermissions: PermissionProviding {
    let home: URL

    func fullDiskAccess() -> FullDiskAccess.Status {
        FullDiskAccess.check(home: home)
    }
}

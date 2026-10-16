import Foundation
import LivCore

/// Measures the real disk with `FileScanner`. Read-only. Whitelisted folders are not skipped on purpose:
/// Space Lens shows everything so the total is true, and only the cleaning modules honor the whitelist.
nonisolated struct LiveDiskTree: DiskTreeProviding {
    let isSimulated = false

    @concurrent func tree(
        at url: URL,
        depth: Int,
        onProgress: @escaping @Sendable (ScanProgress) -> Void
    ) async throws -> (node: DiskNode, issues: [ScanIssue]) {
        try await FileScanner().tree(at: url, depth: depth, progress: onProgress)
    }
}

import Foundation

public enum CleanupAction: String, Sendable, Codable {
    case moveToTrash
    case delete
}

/// One item of a plan, either allowed or blocked with the reason.
public struct PlannedOperation: Sendable, Equatable {
    public let item: CleanupItem
    public let action: CleanupAction
    /// `nil` means the operation is allowed.
    public let violation: SafetyViolation?
}

/// What a cleanup would do, decided before anything is touched.
public struct CleanupPlan: Sendable {
    public let operations: [PlannedOperation]

    public var allowed: [PlannedOperation] { operations.filter { $0.violation == nil } }
    public var blocked: [PlannedOperation] { operations.filter { $0.violation != nil } }
    public var allowedSize: ByteSize { allowed.map(\.item.size).sum() }
}

public enum CleanupPlanner {
    /// Validates every item; duplicates and items nested inside another planned item are dropped.
    ///
    /// Only allowed items collapse into each other: a blocked folder never hides an allowed item
    /// inside it, and the blocked ones are always reported.
    public static func plan(_ items: [CleanupItem], action: CleanupAction, guard safetyGuard: SafetyGuard) -> CleanupPlan {
        plan(items, action: { _ in action }, guard: safetyGuard)
    }

    /// Same, choosing the action per item, e.g. to delete what is already in the Trash instead of moving it there.
    public static func plan(
        _ items: [CleanupItem],
        action: (CleanupItem) -> CleanupAction,
        guard safetyGuard: SafetyGuard
    ) -> CleanupPlan {
        var seenURLs = Set<URL>()
        let candidates = items.filter { seenURLs.insert($0.url).inserted }

        var violations: [SafetyViolation?] = []
        var keys: [PathMath.Components?] = []
        for item in candidates {
            // What the scan already refused never reaches validation, whatever the selection says.
            if let reason = item.blockedReason {
                violations.append(.blocked(item.url, reason: reason))
                keys.append(nil)
                continue
            }
            do {
                let target = try safetyGuard.validate(item.url)
                violations.append(nil)
                keys.append(PathMath.components(of: target))
            } catch {
                violations.append(error)
                keys.append(nil)
            }
        }

        // Shallowest first, so an ancestor is always kept before anything inside it.
        let byDepth = keys.indices.compactMap { index in keys[index].map { (index, $0) } }
            .sorted { ($0.1.count, $0.0) < ($1.1.count, $1.0) }
        var kept = Set<PathMath.Components>()
        var dropped = Set<Int>()
        for (index, key) in byDepth {
            if (1...key.count).contains(where: { kept.contains(Array(key.prefix($0))) }) {
                dropped.insert(index)
            } else {
                kept.insert(key)
            }
        }

        let operations = candidates.indices.filter { !dropped.contains($0) }.map {
            PlannedOperation(item: candidates[$0], action: action(candidates[$0]), violation: violations[$0])
        }
        return CleanupPlan(operations: operations)
    }
}

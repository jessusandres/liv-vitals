import Foundation

/// Combines several scans into one list without listing anything twice (Smart Care).
public enum ScanMerger {
    /// The items of every scan with duplicates and nested items removed, in the order they came in, each with
    /// the name of the scan that found it. On a tie the earlier scan wins; an outer folder always wins over
    /// what is inside it, whatever scan it came from. Paths are compared by components, as the planner does.
    public static func merge(_ scans: [(source: String, result: ScanResult)]) -> [(source: String, item: CleanupItem)] {
        let all = scans.flatMap { scan in scan.result.items.map { (source: scan.source, item: $0) } }
        let keys = all.map { PathMath.components(of: $0.item.url) }

        // Shallowest first, so an ancestor is always kept before anything inside it.
        var kept = Set<PathMath.Components>()
        var dropped = Set<Int>()
        for index in all.indices.sorted(by: { (keys[$0].count, $0) < (keys[$1].count, $1) }) {
            let key = keys[index]
            if (1...max(key.count, 1)).contains(where: { kept.contains(Array(key.prefix($0))) }) {
                dropped.insert(index)
            } else {
                kept.insert(key)
            }
        }
        return all.indices.filter { !dropped.contains($0) }.map { all[$0] }
    }

    /// The merged items as one result: the counts of locations that need access are added up and the issues
    /// of every scan are kept.
    public static func combine(_ scans: [(source: String, result: ScanResult)]) -> ScanResult {
        ScanResult(
            items: merge(scans).map(\.item),
            locationsNeedingAccess: scans.map(\.result.locationsNeedingAccess).reduce(0, +),
            issues: scans.flatMap(\.result.issues)
        )
    }
}

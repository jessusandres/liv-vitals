import Foundation
import LivCore
import os

/// Smart Care: Cleanup, Installers and Dev Projects scanned together, listed once, and cleaned as one run.
/// It never touches the Uninstaller, leftovers of removed apps or Space Lens.
nonisolated extension LiveCleanupScanner {
    static let smartCareSource = "Smart Care"
    /// The modules Smart Care combines, in the order their items win a tie.
    static let smartCareModules: [AppModule] = [.cleanup, .installers, .devProjects]

    func scanSmartCare(_ options: ScanOptions, onUpdate: @escaping @Sendable (ScanUpdate) -> Void) async throws -> ScanResult {
        let fractions = OSAllocatedUnfairLock(initialState: [Double](repeating: 0, count: Self.smartCareModules.count))
        func progress(_ index: Int) -> @Sendable (ScanUpdate) -> Void {
            { update in
                let average = fractions.withLock { values in
                    if let fraction = update.fraction { values[index] = max(values[index], min(fraction, 1)) }
                    return values.reduce(0, +) / Double(values.count)
                }
                onUpdate(ScanUpdate(fraction: average, currentPath: update.currentPath))
            }
        }
        func finished(_ index: Int) {
            let average = fractions.withLock { values in
                values[index] = 1
                return values.reduce(0, +) / Double(values.count)
            }
            onUpdate(ScanUpdate(fraction: average, currentPath: ""))
        }

        // Only project folders that exist: a missing default folder is not worth a notice here.
        var devOptions = options
        devOptions.projectRoots = options.projectRoots.filter { FileManager.default.fileExists(atPath: $0.path) }

        async let cleanup = attempt(.cleanup) { try await scanCleanup(whitelist: options.whitelist, onUpdate: progress(0)) }
        async let installers = attempt(.installers) { try await scanInstallers(options, onUpdate: progress(1)) }
        async let projects = attempt(.devProjects) {
            devOptions.projectRoots.isEmpty ? .empty : try await scanDevProjects(devOptions, onUpdate: progress(2))
        }
        let results = try await [cleanup, installers, projects]
        for index in results.indices { finished(index) }

        let scans = zip(Self.smartCareModules, results).map { module, result -> (source: String, result: ScanResult) in
            var scan = Self.tagged(result, as: module)
            // Installers still unmatched, or mounted, are for the user to pick in the Installers module.
            if module == .installers {
                scan = ScanResult(
                    items: scan.items.filter { $0.isSelectedByDefault && !$0.isBlocked },
                    scannedAt: scan.scannedAt, locationsNeedingAccess: scan.locationsNeedingAccess, issues: scan.issues
                )
            }
            return (module.rawValue, scan)
        }
        return ScanMerger.combine(scans)
    }

    /// One scan that failed does not stop the others; its failure comes back as a notice.
    func attempt(_ module: AppModule, _ body: () async throws -> ScanResult) async throws -> ScanResult {
        do {
            return try await body()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            let name = module == .devProjects ? "Dev Projects" : module == .installers ? "Installers" : "Cleanup"
            let reason = "\(name) could not be scanned: \(error.localizedDescription)"
            return ScanResult(items: [], issues: [ScanIssue(url: home, reason: reason)])
        }
    }

    /// Hands each item back to the module that found it, all under one run so History shows one "Smart Care" row.
    func cleanSmartCare(
        _ items: [CleanupItem],
        source: String,
        options: CleanOptions,
        onUpdate: @escaping @Sendable (ScanUpdate) -> Void
    ) async throws -> CleanupOutcome {
        let runID = options.runID ?? UUID()
        var shared = options
        shared.runID = runID

        let known = Set(Self.smartCareModules.map(\.rawValue))
        let unknown = items.filter { $0.module.map { !known.contains($0) } ?? true }
        var outcomes: [CleanupOutcome] = []
        let groups = Self.smartCareModules.map { module in (module, items.filter { $0.module == module.rawValue }) }
            .filter { !$0.1.isEmpty }

        for (index, (module, group)) in groups.enumerated() {
            try Task.checkCancellation()
            let outcome = try await clean(module: module, group, source: source, options: shared) { update in
                let fraction = update.fraction.map { (Double(index) + $0) / Double(groups.count) }
                onUpdate(ScanUpdate(fraction: fraction, currentPath: update.currentPath))
            }
            outcomes.append(outcome)
        }

        var merged = emptyOutcome(source: source, dryRun: options.dryRun)
        let trashed = outcomes.map(\.trashedSize).sum()
        let deleted = outcomes.map(\.deletedSize).sum()
        merged.record = CleanupRecord(
            id: runID, date: .now, source: source,
            itemCount: outcomes.map(\.record.itemCount).reduce(0, +),
            freed: ByteSize(trashed.bytes + deleted.bytes),
            movedToTrash: deleted.bytes == 0
        )
        merged.trashedSize = trashed
        merged.deletedSize = deleted
        merged.failures = outcomes.flatMap(\.failures)
        merged.skipped = outcomes.flatMap(\.skipped) + unknown.map {
            CleanupProblem(item: $0, reason: "Not found by a module Smart Care can clean with.")
        }
        merged.notice = outcomes.compactMap(\.notice).first
        return merged
    }
}

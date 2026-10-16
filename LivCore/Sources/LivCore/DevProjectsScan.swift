import Foundation
import os

/// How far a Dev Projects scan has got: a fraction once sizes are being measured, the folder at hand always.
public struct DevProjectsProgress: Sendable {
    public let fraction: Double?
    public let currentPath: String

    public init(fraction: Double?, currentPath: String) {
        self.fraction = fraction
        self.currentPath = currentPath
    }
}

/// Finds the artifacts of the user's projects and turns them into items grouped by project.
///
/// find → group by project → drop what git tracks → date each project → measure → items. Nothing is changed
/// on disk. What cannot be checked (no git, git failing, no date) starts unchecked with a note.
public struct DevProjectsScan: Sendable {
    /// A project edited more recently than this is left unchecked when `skipRecentProjects` is on.
    public static let recentWindow: TimeInterval = 7 * 86_400

    public static let gitFailedNote = "Could not check git for this project."
    public static let gitMissingNote = "Git is not available, so tracked files could not be ruled out."
    public static let unknownDateNote = "Could not tell when this project was last edited."

    private let roots: [URL]
    private let safetyGuard: SafetyGuard
    private let git: (any GitInspecting)?
    private let skipRecentProjects: Bool
    private let kinds: [ArtifactKind]
    private let maxDepth: Int
    private let now: Date

    public init(
        roots: [URL],
        guard safetyGuard: SafetyGuard,
        git: (any GitInspecting)?,
        skipRecentProjects: Bool = true,
        kinds: [ArtifactKind] = ArtifactKind.builtIn,
        maxDepth: Int = 6,
        now: Date = .now
    ) {
        self.roots = roots
        self.safetyGuard = safetyGuard
        self.git = git
        self.skipRecentProjects = skipRecentProjects
        self.kinds = kinds
        self.maxDepth = maxDepth
        self.now = now
    }

    private struct Located {
        let match: ArtifactMatch
        let project: URL
        let isRepository: Bool
    }

    public func run(progress: (@Sendable (DevProjectsProgress) -> Void)? = nil) async throws -> ScanResult {
        let finder = ProjectArtifactFinder(roots: roots, guard: safetyGuard, kinds: kinds, maxDepth: maxDepth)
        let found = try finder.find { progress?(DevProjectsProgress(fraction: nil, currentPath: $0)) }
        try Task.checkCancellation()

        let located = found.matches.map { match -> Located in
            let project = ProjectInspector.project(for: match)
            return Located(match: match, project: project.url, isRepository: project.isGitRepository)
        }

        // Git: one question per repository. What it tracks is not offered; what it could not answer stays unchecked.
        var tracked = Set<URL>()
        var unchecked = Set<URL>()
        for (repository, inside) in Dictionary(grouping: located.filter(\.isRepository), by: \.project) {
            try Task.checkCancellation()
            progress?(DevProjectsProgress(fraction: nil, currentPath: repository.path))
            guard let git else { continue }
            do {
                tracked.formUnion(try await git.trackedPaths(inside.map(\.match.url), in: repository))
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                unchecked.insert(repository)
            }
        }

        let remaining = located.filter { !tracked.contains($0.match.url) }
        var infos: [URL: ProjectInfo] = [:]
        for (project, inside) in Dictionary(grouping: remaining, by: \.project) {
            progress?(DevProjectsProgress(fraction: nil, currentPath: project.path))
            infos[project] = try await ProjectInspector.info(
                for: project,
                isGitRepository: inside[0].isRepository,
                artifacts: inside.map(\.match.url),
                git: git
            )
        }

        let measurements = try await measure(remaining.map(\.match.url), progress: progress)
        let kindByID = Dictionary(kinds.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        let items = remaining.compactMap { entry -> CleanupItem? in
            guard let kind = kindByID[entry.match.kind],
                  let measurement = measurements[entry.match.url], measurement.size.bytes > 0 else { return nil }
            return item(for: entry, kind: kind, info: infos[entry.project], measurement: measurement, uncheckedRepositories: unchecked)
        }
        return ScanResult(items: items, issues: found.issues)
    }

    private func item(
        for entry: Located,
        kind: ArtifactKind,
        info: ProjectInfo?,
        measurement: Measurement,
        uncheckedRepositories: Set<URL>
    ) -> CleanupItem {
        let lastActivity = info?.lastActivity
        let age = lastActivity.map { now.timeIntervalSince($0) }
        let isRecent = skipRecentProjects && (age.map { $0 < Self.recentWindow } ?? false)
        let dateUnknown = skipRecentProjects && lastActivity == nil
        let gitMissing = entry.isRepository && git == nil
        let gitFailed = entry.isRepository && uncheckedRepositories.contains(entry.project)
        let mostlyShared = measurement.sharedSize.bytes * 2 > measurement.size.bytes

        // The first reason that applies is the one shown; any of them leaves the item unchecked.
        let note: String
        if isRecent, let age {
            note = Self.editedNote(daysAgo: Int(age / 86_400))
        } else if dateUnknown {
            note = Self.unknownDateNote
        } else if gitFailed {
            note = Self.gitFailedNote
        } else if gitMissing {
            note = Self.gitMissingNote
        } else if mostlyShared {
            note = CleanupItem.sharedSpaceNote
        } else {
            note = kind.rebuildHint
        }
        let selected = kind.defaultSelected && !isRecent && !dateUnknown && !gitFailed && !gitMissing && !mostlyShared

        return CleanupItem(
            url: entry.match.url,
            category: .projectArtifacts,
            size: measurement.size,
            lastModified: lastActivity,
            isSelectedByDefault: selected,
            note: note,
            ruleID: kind.id,
            group: entry.project
        )
    }

    static func editedNote(daysAgo days: Int) -> String {
        switch days {
        case ..<1: "Project edited today."
        case 1: "Project edited 1 day ago."
        default: "Project edited \(days) days ago."
        }
    }

    private func measure(_ urls: [URL], progress: (@Sendable (DevProjectsProgress) -> Void)?) async throws -> [URL: Measurement] {
        // The fraction comes from finished artifacts, the path shown from the walk in progress.
        let state = OSAllocatedUnfairLock(initialState: DevProjectsProgress(fraction: 0, currentPath: ""))
        return try await FileScanner(guard: safetyGuard).measureAll(
            urls,
            progress: { scan in
                guard let progress else { return }
                progress(state.withLock { current in
                    current = DevProjectsProgress(fraction: current.fraction, currentPath: scan.currentPath)
                    return current
                })
            },
            rootFinished: { done, total in
                guard let progress else { return }
                progress(state.withLock { current in
                    current = DevProjectsProgress(fraction: Double(done) / Double(max(total, 1)), currentPath: current.currentPath)
                    return current
                })
            }
        )
    }
}

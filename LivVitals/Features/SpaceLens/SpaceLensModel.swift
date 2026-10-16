import AppKit
import LivCore
import Observation
import SwiftUI

/// Explores the disk for Space Lens: one scan of the home folder two levels deep, then folders load as
/// the user opens them. A folder or file can be moved to the Trash from here, through the same guard and
/// runner as Cleanup.
@Observable
final class SpaceLensModel {
    enum Phase { case idle, scanning, ready }

    private(set) var phase: Phase = .idle
    /// Latest report from the running scan; nil until the first one arrives.
    private(set) var scanProgress: ScanProgress?
    private(set) var errorMessage: String?
    /// Why the last folder could not be opened.
    private(set) var loadError: String?
    private(set) var root: DiskNode?
    private(set) var focusURL: URL?
    private(set) var scannedAt: Date?
    /// Everything the scanner could not read, across the first scan and every folder opened since.
    private(set) var issues: [ScanIssue] = []
    /// Folders being read right now.
    private(set) var loading: Set<URL> = []
    /// The folder a "Rescan" is measuring again, if any. The previous view stays on screen meanwhile.
    private(set) var rescanningURL: URL?
    /// Waiting for the user to confirm removing this node.
    var pendingRemoval: DiskNode?
    /// Why the last removal did not happen, or a note about it (a simulation).
    private(set) var removalMessage: String?
    private(set) var isRemoving = false
    var filterText = ""
    var hovered: URL?

    @ObservationIgnored private let service: any DiskTreeProviding
    @ObservationIgnored private let home: URL
    @ObservationIgnored private let makeGuard: () -> SafetyGuard?
    @ObservationIgnored private let revealInFinder: (URL) -> Void
    @ObservationIgnored private let cleaner: (any CleanupScanning)?
    @ObservationIgnored private let cleanOptions: () -> CleanOptions
    @ObservationIgnored var onCleaned: ((CleanupRecord) -> Void)?
    @ObservationIgnored private var rescanTask: Task<Void, Never>?
    @ObservationIgnored private var guardian: SafetyGuard?
    @ObservationIgnored private var protectedCache: [URL: Bool] = [:]
    @ObservationIgnored private var knownIssueURLs: Set<URL> = []
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    /// - Parameters:
    ///   - makeGuard: Builds the guard that decides which nodes can be removed; the cleaner applies the same rules again.
    ///   - reveal: Shows a path in Finder.
    ///   - cleaner: Does the removal. Without one, nothing can be removed.
    ///   - cleanOptions: Trash or delete, simulation and whitelist, read when the user confirms.
    init(
        service: any DiskTreeProviding,
        home: URL,
        makeGuard: @escaping () -> SafetyGuard? = { nil },
        reveal: @escaping (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) },
        cleaner: (any CleanupScanning)? = nil,
        cleanOptions: @escaping () -> CleanOptions = { CleanOptions() }
    ) {
        self.service = service
        self.home = home
        self.makeGuard = makeGuard
        revealInFinder = reveal
        self.cleaner = cleaner
        self.cleanOptions = cleanOptions
    }

    // MARK: - Scanning

    func scan() {
        work?.cancel()
        loadTask?.cancel()
        rescanTask?.cancel()
        rescanningURL = nil
        removalMessage = nil
        loading = []
        scanProgress = nil
        errorMessage = nil
        loadError = nil
        issues = []
        knownIssueURLs = []
        guardian = makeGuard()
        protectedCache = [:]
        withMotion { phase = .scanning }
        let relay = ProgressRelay<ScanProgress> { [weak self] in self?.scanProgress = $0 }
        work = Task {
            defer { relay.finish() }
            do {
                let result = try await service.tree(at: home, depth: 2, onProgress: relay.send)
                root = result.node
                focusURL = result.node.url
                scannedAt = .now
                filterText = ""
                add(result.issues)
                withMotion(.spring) { phase = .ready }
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
                withMotion { phase = root == nil ? .idle : .ready }
            }
        }
    }

    func cancelScan() {
        work?.cancel()
        withMotion { phase = root == nil ? .idle : .ready }
    }

    // MARK: - Navigation

    var focused: DiskNode? {
        guard let root else { return nil }
        return focusURL.flatMap { root.node(at: $0) } ?? root
    }

    /// Folders from the scan root down to the focused folder.
    var breadcrumb: [DiskNode] {
        guard let root, let target = focused?.url else { return [] }
        func path(from node: DiskNode) -> [DiskNode]? {
            if node.url == target { return [node] }
            for child in node.children {
                if let rest = path(from: child) { return [node] + rest }
            }
            return nil
        }
        return path(from: root) ?? [root]
    }

    /// Enters a folder. One whose contents were not read yet is read first.
    func open(_ node: DiskNode) {
        guard node.isDirectory else { return }
        hovered = nil
        if node.isCollapsed {
            load(node)
        } else if !node.children.isEmpty {
            filterText = ""
            withMotion(.spring(duration: 0.4)) { focusURL = node.url }
        }
    }

    func goUp() {
        let trail = breadcrumb
        guard trail.count > 1 else { return }
        hovered = nil
        filterText = ""
        withMotion(.spring(duration: 0.4)) { focusURL = trail[trail.count - 2].url }
    }

    private func load(_ node: DiskNode) {
        let url = node.url
        guard !loading.contains(url) else { return }
        loadTask?.cancel()
        loading = [url]
        loadError = nil
        loadTask = Task {
            do {
                let result = try await service.tree(at: url, depth: 2, onProgress: { _ in })
                if let current = root {
                    root = current.replacing(url, with: result.node)
                    add(result.issues)
                    filterText = ""
                    withMotion(.spring(duration: 0.4)) { focusURL = url }
                }
            } catch is CancellationError {
                return
            } catch {
                loadError = "Could not open \(node.name): \(error.localizedDescription)"
            }
            loading.remove(url)
        }
    }

    private func add(_ new: [ScanIssue]) {
        for issue in new where knownIssueURLs.insert(issue.url).inserted { issues.append(issue) }
    }

    // MARK: - Rescanning the current folder

    /// Measures again only the folder the user is in; the rest of the tree is kept and the ancestors' sizes
    /// follow. At the top it is the same as `scan()`.
    func rescanFocused() {
        guard let root, let focused else { return scan() }
        if focused.url == root.url { return scan() }

        let url = focused.url
        rescanTask?.cancel()
        rescanningURL = url
        loadError = nil
        let relay = ProgressRelay<ScanProgress> { [weak self] in self?.scanProgress = $0 }
        rescanTask = Task {
            defer { relay.finish() }
            do {
                let result = try await service.tree(at: url, depth: 2, onProgress: relay.send)
                if let current = self.root {
                    self.root = current.replacing(url, with: result.node)
                    forgetIssues(inside: url)
                    add(result.issues)
                    scannedAt = .now
                }
            } catch is CancellationError {
                return
            } catch let error as ScanError {
                if case .notFound = error { folderVanished(url) } else { loadError = "Could not rescan \(focused.name): \(error.localizedDescription)" }
            } catch {
                loadError = "Could not rescan \(focused.name): \(error.localizedDescription)"
            }
            if rescanningURL == url { rescanningURL = nil }
        }
    }

    func cancelRescan() {
        rescanTask?.cancel()
        rescanningURL = nil
    }

    /// The rescanned folder is gone: drop it and move up to the nearest folder still in the tree.
    private func folderVanished(_ url: URL) {
        loadError = "\(url.lastPathComponent) no longer exists."
        guard let current = root else { return }
        let parent = breadcrumb.last { $0.url != url }?.url ?? current.url
        root = current.removing(url)
        withMotion(.spring(duration: 0.4)) { focusURL = parent }
    }

    private func forgetIssues(inside folder: URL) {
        let prefix = folder.path + "/"
        let gone = issues.filter { $0.url.path == folder.path || $0.url.path.hasPrefix(prefix) }
        issues.removeAll { issue in gone.contains { $0.url == issue.url } }
        knownIssueURLs.subtract(gone.map(\.url))
    }

    // MARK: - Moving to the Trash

    /// Whether the guard lets this node be removed. The lock in the list shows the same thing.
    func canRemove(_ node: DiskNode) -> Bool {
        guard cleaner != nil, !isRemoving, let guardian else { return false }
        return (try? guardian.validate(node.url)) != nil
    }

    /// Asks for confirmation; nothing is touched yet.
    func requestRemoval(_ node: DiskNode) {
        guard canRemove(node) else { return }
        removalMessage = nil
        pendingRemoval = node
    }

    func cancelRemoval() {
        pendingRemoval = nil
    }

    /// Whether the pending removal deletes for good instead of using the Trash.
    var pendingRemovalIsPermanent: Bool { !cleanOptions().moveToTrash && !cleanOptions().dryRun }

    func confirmRemoval() {
        guard let node = pendingRemoval, let cleaner, canRemove(node) else { return }
        pendingRemoval = nil
        isRemoving = true
        removalMessage = nil
        let item = CleanupItem(url: node.url, category: .largeFiles, size: node.size)
        let options = cleanOptions()
        Task {
            do {
                let outcome = try await cleaner.clean(module: .spaceLens, [item], source: "Space Lens", options: options, onUpdate: { _ in })
                apply(outcome, for: node)
            } catch {
                removalMessage = "Could not remove \(node.name): \(error.localizedDescription)"
            }
            isRemoving = false
        }
    }

    private func apply(_ outcome: CleanupOutcome, for node: DiskNode) {
        if outcome.wasDryRun {
            removalMessage = "Simulation: \(node.name) was not moved."
        } else if outcome.record.itemCount > 0, let current = root {
            // Sizes of every ancestor follow without measuring the disk again.
            withMotion(.spring(duration: 0.4)) { root = current.removing(node.url) }
            if hovered == node.url { hovered = nil }
            onCleaned?(outcome.record)
        } else if let problem = (outcome.failures + outcome.skipped).first {
            removalMessage = "\(node.name) was not removed: \(problem.reason)"
        }
    }

    // MARK: - Listing

    /// The children of `folder` that match the filter, largest first.
    func visibleChildren(of folder: DiskNode) -> [DiskNode] {
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return folder.children }
        return folder.children.filter { $0.name.localizedCaseInsensitiveContains(query) }
    }

    func reveal(_ node: DiskNode) {
        revealInFinder(node.url)
    }

    /// True for folders Liv Vitals would never remove: protected, in the user's whitelist, or holding such a folder.
    func isProtected(_ node: DiskNode) -> Bool {
        guard let guardian else { return false }
        if let cached = protectedCache[node.url] { return cached }
        var result = false
        do {
            _ = try guardian.validate(node.url)
        } catch {
            switch error {
            case .protected, .whitelisted, .containsProtected: result = true
            case .notAbsolute, .outsideAllowedRoots, .isAllowedRoot, .blocked: break
            }
        }
        protectedCache[node.url] = result
        return result
    }
}

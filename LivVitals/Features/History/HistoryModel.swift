import Foundation
import LivCore
import Observation

/// History and "Put Back": the cleanups read from the log, the runs the user opened, and the put-back flow
/// (ask, confirm, run, summary).
@Observable
final class HistoryModel {
    /// A put-back the user has asked for and not confirmed yet.
    struct Request: Identifiable {
        let id = UUID()
        let run: UUID
        let items: [HistoryItem]
        let preview: RestorePreview
    }

    /// Where an item stands now, for the line under its name.
    enum ItemStatus: Equatable {
        case inTheTrash
        case putBack
        case deleted
        case goneFromTheTrash

        var title: String {
            switch self {
            case .inTheTrash: String(localized: "In the Trash")
            case .putBack: String(localized: "Put back")
            case .deleted: String(localized: "Deleted")
            case .goneFromTheTrash: String(localized: "No longer in the Trash")
            }
        }
    }

    private(set) var runs: [HistoryRun] = []
    var expanded: Set<UUID> = []
    private(set) var request: Request?
    private(set) var isPuttingBack = false
    private(set) var progress: ScanUpdate?
    /// What the last put-back did; shown until the user dismisses it.
    private(set) var result: RestoreOutcome?
    private(set) var errorMessage: String?

    @ObservationIgnored private let service: any HistoryProviding
    @ObservationIgnored private var puttingBackTask: Task<Void, Never>?
    @ObservationIgnored private var presenceCache: [String: Bool] = [:]

    init(service: any HistoryProviding) {
        self.service = service
    }

    var isSimulated: Bool { service.isSimulated }

    func load() async {
        let loaded = await service.runs()
        presenceCache.removeAll()
        runs = loaded
    }

    /// Shows a finished real cleanup at once. The log is the source of truth and is read again right after.
    func insert(_ record: CleanupRecord) {
        runs.insert(HistoryRun(record: record, items: []), at: 0)
        let service = service
        Task {
            await service.record(record)
            await load()
        }
    }

    func toggle(_ run: UUID) {
        if expanded.contains(run) { expanded.remove(run) } else { expanded.insert(run) }
    }

    /// Whether the item is still in the Trash, checked by its path since the Trash itself cannot be listed.
    func status(of item: HistoryItem) -> ItemStatus {
        if item.restoredAt != nil { return .putBack }
        guard let trashed = item.trashedPath else { return .deleted }
        // Simulated items have no files behind them; they count as being in the Trash.
        if service.isSimulated { return .inTheTrash }
        if let known = presenceCache[trashed] { return known ? .inTheTrash : .goneFromTheTrash }
        var info = stat()
        let present = lstat(trashed, &info) == 0
        presenceCache[trashed] = present
        return present ? .inTheTrash : .goneFromTheTrash
    }

    /// The items of `run` that went to the Trash and have not been put back.
    func restorable(in run: HistoryRun) -> [HistoryItem] {
        run.items.filter { $0.trashedPath != nil && $0.restoredAt == nil }
    }

    // MARK: Put Back

    /// Checks what would happen and asks the user to confirm. Does nothing while a put-back is running.
    func askPutBack(_ items: [HistoryItem], of run: UUID) async {
        guard !isPuttingBack, !items.isEmpty else { return }
        result = nil
        errorMessage = nil
        let preview = await service.preview(items)
        if preview.restorable == 0 {
            // Nothing can go back: say why instead of asking.
            result = RestoreOutcome(skipped: preview.skipped)
            return
        }
        request = Request(run: run, items: items, preview: preview)
    }

    func cancelRequest() {
        request = nil
    }

    func confirmPutBack() {
        guard let request, !isPuttingBack else { return }
        self.request = nil
        isPuttingBack = true
        progress = ScanUpdate(fraction: nil, currentPath: "")
        let relay = ProgressRelay<ScanUpdate> { [weak self] in self?.progress = $0 }
        puttingBackTask = Task { [service] in
            defer { relay.finish() }
            do {
                let outcome = try await service.putBack(request.items, of: request.run, onUpdate: relay.send)
                result = outcome
            } catch is CancellationError {
                result = nil
            } catch {
                errorMessage = error.localizedDescription
            }
            isPuttingBack = false
            progress = nil
            await load()
        }
    }

    func cancelPutBack() {
        puttingBackTask?.cancel()
    }

    func dismissResult() {
        result = nil
        errorMessage = nil
    }

    /// Waits for a running put-back, for tests.
    func finishPuttingBack() async {
        await puttingBackTask?.value
    }
}

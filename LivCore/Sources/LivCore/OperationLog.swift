import Foundation

/// One line of the operations log.
public struct LogEntry: Codable, Sendable, Equatable {
    /// `maintenance` is a Performance task: its `path` is `task:<id>`. History ignores it. `restore` is a
    /// "Put Back": `path` is the original location and `trashedPath` where it came from.
    public enum Kind: String, Codable, Sendable { case scan, dryRun, trash, delete, maintenance, restore }
    public enum Outcome: String, Codable, Sendable { case planned, skipped, done, failed }

    /// ISO 8601 in the file, which keeps whole seconds.
    public let date: Date
    public let kind: Kind
    public let path: String
    public let bytes: Int64
    public let outcome: Outcome
    /// English reason when skipped or failed.
    public let detail: String?
    /// The cleanup this line belongs to; every line of one run shares it. Absent in older logs.
    public let runID: UUID?
    /// Where a Trash move ended up, so it can be put back later. Absent in older logs.
    public let trashedPath: String?
    /// The module that ran it ("Cleanup", "Space Lens"), for History. Absent in older logs.
    public let source: String?

    public init(
        date: Date = .now,
        kind: Kind,
        path: String,
        bytes: Int64,
        outcome: Outcome,
        detail: String? = nil,
        runID: UUID? = nil,
        trashedPath: String? = nil,
        source: String? = nil
    ) {
        // Whole seconds, so an entry equals itself after a round trip through the file.
        self.date = Date(timeIntervalSince1970: date.timeIntervalSince1970.rounded(.down))
        self.kind = kind
        self.path = path
        self.bytes = bytes
        self.outcome = outcome
        self.detail = detail
        self.runID = runID
        self.trashedPath = trashedPath
        self.source = source
    }

    private enum CodingKeys: String, CodingKey {
        case date, kind, path, bytes, outcome, detail, runID, trashedPath, source
    }

    /// Writes `null` for empty optionals instead of leaving the keys out, so every line has the same shape.
    /// Reading is the synthesized one: lines written before `runID` and `trashedPath` existed still decode.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(kind, forKey: .kind)
        try container.encode(path, forKey: .path)
        try container.encode(bytes, forKey: .bytes)
        try container.encode(outcome, forKey: .outcome)
        try container.encode(detail, forKey: .detail)
        try container.encode(runID, forKey: .runID)
        try container.encode(trashedPath, forKey: .trashedPath)
        try container.encode(source, forKey: .source)
    }
}

/// Append-only record of what the app scanned, planned and did, in JSON Lines.
public actor OperationLog {
    private let fileURL: URL

    /// The app keeps it at `~/Library/Application Support/LivVitals/operations.jsonl`.
    public init(fileURL: URL) {
        self.fileURL = fileURL
    }

    /// Adds the entries at the end of the file, creating it and its folder if needed.
    public func append(_ entries: [LogEntry]) throws {
        guard !entries.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

        var data = Data()
        for entry in entries {
            data.append(try encoder.encode(entry))
            data.append(0x0A)
        }

        let manager = FileManager.default
        try manager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !manager.fileExists(atPath: fileURL.path) {
            guard manager.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: fileURL.path])
            }
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    /// Every entry in the file, oldest first. An absent file is an empty log.
    public func entries() throws -> [LogEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try Data(contentsOf: fileURL)
            .split(separator: 0x0A)
            .map { try decoder.decode(LogEntry.self, from: Data($0)) }
    }
}

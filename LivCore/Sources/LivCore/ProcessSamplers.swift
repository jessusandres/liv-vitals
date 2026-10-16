import Darwin
import Foundation
import os

/// Where the list of busy processes comes from.
public protocol ProcessSampling: Sendable {
    func sample() throws -> [ProcessUsage]
    /// Stops any background work.
    func finish()
}

extension ProcessSampling {
    public func finish() {}
}

/// For callers that never show processes (menu bar indicators, widgets): nothing is launched and nothing is read.
public struct NullProcessSampler: ProcessSampling {
    public init() {}

    public func sample() throws -> [ProcessUsage] { [] }
}

// MARK: - Turning cumulative CPU time into a rate

/// Compares each process's CPU time with the previous reading. Pure, so it is tested with fixed numbers.
struct ProcessCPUTracker: Sendable {
    struct Reading: Sendable, Equatable {
        var pid: Int32
        var name: String
        var cpuNanoseconds: UInt64
        var memoryBytes: UInt64
    }

    private var previous: [Int32: UInt64] = [:]
    private var previousDate: Date?

    /// The first reading, and any process seen for the first time, has no rate yet and reports 0.
    mutating func usage(for readings: [Reading], at date: Date) -> [ProcessUsage] {
        let elapsed = previousDate.map { date.timeIntervalSince($0) } ?? 0
        let result = readings.map { reading -> ProcessUsage in
            var percent = 0.0
            if elapsed > 0, let before = previous[reading.pid], reading.cpuNanoseconds >= before {
                percent = Double(reading.cpuNanoseconds - before) / (elapsed * 1_000_000_000) * 100
            }
            return ProcessUsage(pid: reading.pid, name: reading.name, cpuPercent: percent, memoryBytes: reading.memoryBytes)
        }
        previous = Dictionary(readings.map { ($0.pid, $0.cpuNanoseconds) }, uniquingKeysWith: { _, last in last })
        previousDate = date
        return result
    }
}

// MARK: - libproc: the user's own processes

/// Reads processes with `proc_pid_rusage`. macOS refuses that call for processes of other users, so only the
/// user's own processes appear. It is the fallback when `top` is not available.
public final class LibprocSampler: ProcessSampling {
    private let tracker = OSAllocatedUnfairLock(initialState: ProcessCPUTracker())
    private let nanosecondsPerTick: Double

    public init() {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        nanosecondsPerTick = Double(timebase.numer) / Double(max(timebase.denom, 1))
    }

    public func sample() throws -> [ProcessUsage] {
        let count = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard count > 0 else { throw MetricsError.systemCallFailed("proc_listpids") }
        var pids = [pid_t](repeating: 0, count: Int(count) / MemoryLayout<pid_t>.size + 16)
        let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard bytes > 0 else { throw MetricsError.systemCallFailed("proc_listpids") }

        let readings = pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).compactMap { pid -> ProcessCPUTracker.Reading? in
            guard pid > 0 else { return nil }
            var info = rusage_info_current()
            let status = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, $0) }
            }
            guard status == 0 else { return nil }
            let ticks = info.ri_user_time &+ info.ri_system_time
            return ProcessCPUTracker.Reading(
                pid: pid,
                name: ProcessNames.name(of: pid) ?? "pid \(pid)",
                cpuNanoseconds: UInt64(Double(ticks) * nanosecondsPerTick),
                memoryBytes: info.ri_phys_footprint
            )
        }
        return tracker.withLock { $0.usage(for: readings, at: .now) }
    }
}

enum ProcessNames {
    /// The full process name. `top` cuts names at 16 characters.
    static func name(of pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cBuffer: buffer)
    }
}

// MARK: - top: every process, root's included

/// Reads one frame of `top -stats pid,command,cpu,mem` at a time, line by line.
struct TopFrameParser {
    let rowsPerFrame: Int
    private var framesSeen = 0
    private var inTable = false
    private var rows: [ProcessUsage] = []

    init(rowsPerFrame: Int) {
        self.rowsPerFrame = rowsPerFrame
    }

    /// Returns a finished frame, or nil while one is still arriving. The first frame is dropped: `top` computes
    /// its CPU from boot, so every value in it is meaningless.
    mutating func feed(_ line: String) -> [ProcessUsage]? {
        if line.hasPrefix("Processes:") {
            let unfinished = emit()
            framesSeen += 1
            return unfinished
        }
        if line.hasPrefix("PID") {
            inTable = true
            return nil
        }
        guard inTable, let row = Self.parseRow(line) else { return nil }
        rows.append(row)
        return rows.count == rowsPerFrame ? emit() : nil
    }

    private mutating func emit() -> [ProcessUsage]? {
        defer {
            rows = []
            inTable = false
        }
        return framesSeen >= 2 && !rows.isEmpty ? rows : nil
    }

    /// `97045  sed   0.0  1184K`. The name may contain spaces; CPU and memory are always the last two columns.
    static func parseRow(_ line: String) -> ProcessUsage? {
        let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 4, let pid = Int32(tokens[0]), let cpu = Double(tokens[tokens.count - 2]),
              let memory = parseMemory(String(tokens[tokens.count - 1]))
        else { return nil }
        let name = tokens[1..<(tokens.count - 2)].joined(separator: " ")
        return ProcessUsage(pid: pid, name: name, cpuPercent: cpu, memoryBytes: memory)
    }

    /// `1184K`, `30M`, `2G`, optionally followed by `+` or `-` (it grew or shrank since the last frame).
    static func parseMemory(_ text: String) -> UInt64? {
        var text = Substring(text)
        if let last = text.last, last == "+" || last == "-" { text.removeLast() }
        guard let unit = text.last else { return nil }
        let power: Double
        switch unit {
        case "B": power = 0
        case "K": power = 1
        case "M": power = 2
        case "G": power = 3
        case "T": power = 4
        default: return nil
        }
        guard let number = Double(text.dropLast()) else { return nil }
        return UInt64(number * pow(1024, power))
    }
}

/// Keeps `/usr/bin/top` running in the background and hands out its latest frame.
///
/// `top` is signed by Apple with the right to inspect every process, root's included, which an ordinary
/// app cannot do itself. Starting it asks for no permission. It is started on the first `latest()` call
/// and stopped by `finish()`.
///
/// `@unchecked Sendable`: every mutable field, including the non-Sendable `Process` and `Pipe`, lives in
/// `state` and is only touched while its lock is held.
public final class TopProcessSampler: @unchecked Sendable {
    private static let rowLimit = 8

    private struct State {
        var process: Process?
        var pipe: Pipe?
        var parser = TopFrameParser(rowsPerFrame: TopProcessSampler.rowLimit)
        var pending = Data()
        var latest: [ProcessUsage] = []
        /// Set when `top` could not start or died by itself.
        var unavailable = false
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())

    public init() {}

    /// The most recent frame (empty until the second one arrives), or nil when `top` cannot be used.
    public func latest() -> [ProcessUsage]? {
        startIfNeeded()
        return state.withLockUnchecked { $0.unavailable ? nil : $0.latest }
    }

    public func finish() {
        let (process, pipe) = state.withLockUnchecked { state -> (Process?, Pipe?) in
            defer {
                state.process = nil
                state.pipe = nil
                state.latest = []
                state.pending = Data()
                state.parser = TopFrameParser(rowsPerFrame: Self.rowLimit)
            }
            return (state.process, state.pipe)
        }
        pipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process?.terminate()
    }

    private func startIfNeeded() {
        state.withLockUnchecked { state in
            guard state.process == nil, !state.unavailable else { return }
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/top")
            process.arguments = ["-l", "0", "-s", "1", "-n", "\(Self.rowLimit)", "-o", "cpu", "-stats", "pid,command,cpu,mem"]
            process.environment = ["LC_ALL": "C"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.markEnded()
                } else {
                    self?.consume(data)
                }
            }
            process.terminationHandler = { [weak self] _ in self?.markEnded() }
            do {
                try process.run()
                state.process = process
                state.pipe = pipe
            } catch {
                state.unavailable = true
            }
        }
    }

    private func consume(_ data: Data) {
        state.withLockUnchecked { state in
            state.pending.append(data)
            while let newline = state.pending.firstIndex(of: 0x0A) {
                let line = String(decoding: state.pending[state.pending.startIndex..<newline], as: UTF8.self)
                state.pending.removeSubrange(state.pending.startIndex...newline)
                if let frame = state.parser.feed(line) {
                    // `top` cuts names at 16 characters; the full one is a cheap lookup for a handful of rows.
                    state.latest = frame.map { row in
                        var row = row
                        if let full = ProcessNames.name(of: row.pid) { row.name = full }
                        return row
                    }
                }
            }
        }
    }

    /// `top` ended without `finish()` being called: stop trusting it.
    private func markEnded() {
        state.withLockUnchecked { state in
            guard state.process != nil else { return }
            state.process = nil
            state.pipe = nil
            state.unavailable = true
        }
    }
}

/// `top` for every process, with `libproc` as the fallback.
public struct DefaultProcessSampler: ProcessSampling {
    private let top = TopProcessSampler()
    private let libproc = LibprocSampler()

    public init() {}

    public func sample() throws -> [ProcessUsage] {
        if let frame = top.latest() { return frame }
        return try libproc.sample()
    }

    public func finish() {
        top.finish()
    }
}

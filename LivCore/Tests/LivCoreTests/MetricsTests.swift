import Foundation
import os
import Testing
@testable import LivCore

// MARK: - Fixtures

private let start = Date(timeIntervalSince1970: 1_800_000_000)

private func memory(pressure: MemoryPressure = .normal, used: UInt64 = 8, total: UInt64 = 16) -> MemoryReading {
    MemoryReading(totalBytes: total, usedBytes: used, wiredBytes: 2, compressedBytes: 1, pressure: pressure)
}

private func raw(
    at seconds: TimeInterval = 0,
    busy: UInt64 = 0,
    idle: UInt64 = 0,
    pressure: MemoryPressure = .normal,
    diskUsed: Double = 0.5,
    bytesIn: UInt64 = 0,
    bytesOut: UInt64 = 0,
    processes: [ProcessUsage] = []
) -> RawMetrics {
    RawMetrics(
        date: start.addingTimeInterval(seconds),
        cpuTicks: CPUTicks(user: busy, system: 0, idle: idle, nice: 0),
        memory: memory(pressure: pressure),
        disk: DiskReading(totalBytes: 1_000, availableBytes: UInt64(1_000 * (1 - diskUsed))),
        network: NetworkCounters(bytesIn: bytesIn, bytesOut: bytesOut),
        battery: nil,
        processes: processes
    )
}

// MARK: - Aggregator

struct MetricsAggregatorTests {
    @Test func theFirstReadingHasNoRates() {
        var aggregator = MetricsAggregator()
        let snapshot = aggregator.ingest(raw(busy: 500, idle: 500, bytesIn: 9_999))
        #expect(snapshot.cpu == 0)
        #expect(snapshot.downloadBytesPerSecond == 0)
        #expect(snapshot.uploadBytesPerSecond == 0)
    }

    @Test func cpuAndNetworkAreRatesBetweenTwoReadings() {
        var aggregator = MetricsAggregator()
        _ = aggregator.ingest(raw(at: 0, busy: 100, idle: 100, bytesIn: 1_000, bytesOut: 200))
        let snapshot = aggregator.ingest(raw(at: 2, busy: 130, idle: 170, bytesIn: 6_000, bytesOut: 1_200))
        #expect(snapshot.cpu == 0.3)
        #expect(snapshot.downloadBytesPerSecond == 2_500)
        #expect(snapshot.uploadBytesPerSecond == 500)
    }

    @Test func noElapsedTicksKeepsTheLastCpuValue() {
        var aggregator = MetricsAggregator()
        _ = aggregator.ingest(raw(at: 0, busy: 0, idle: 0))
        _ = aggregator.ingest(raw(at: 1, busy: 50, idle: 50))
        let repeated = aggregator.ingest(raw(at: 2, busy: 50, idle: 50))
        #expect(repeated.cpu == 0.5)
    }

    @Test func aCounterThatWentDownCountsAsNoTraffic() {
        var aggregator = MetricsAggregator()
        _ = aggregator.ingest(raw(at: 0, bytesIn: 9_000, bytesOut: 9_000))
        let snapshot = aggregator.ingest(raw(at: 1, bytesIn: 100, bytesOut: 100))
        #expect(snapshot.downloadBytesPerSecond == 0)
        #expect(snapshot.uploadBytesPerSecond == 0)
    }

    @Test func aClockThatDidNotAdvanceGivesNoNetworkRate() {
        var aggregator = MetricsAggregator()
        _ = aggregator.ingest(raw(at: 5, bytesIn: 0))
        #expect(aggregator.ingest(raw(at: 5, bytesIn: 1_000)).downloadBytesPerSecond == 0)
        #expect(aggregator.ingest(raw(at: 4, bytesIn: 2_000)).downloadBytesPerSecond == 0)
    }

    @Test func cpuAverageCoversTheLastTenReadings() {
        var aggregator = MetricsAggregator()
        var busy: UInt64 = 0
        var idle: UInt64 = 0
        var last = aggregator.ingest(raw(at: 0))
        // Ten readings at 100 % busy after two idle ones: only the ten count.
        for index in 1...2 { idle += 100; last = aggregator.ingest(raw(at: Double(index), busy: busy, idle: idle)) }
        #expect(last.cpuAverage == 0)
        for index in 3...12 { busy += 100; last = aggregator.ingest(raw(at: Double(index), busy: busy, idle: idle)) }
        #expect(last.cpu == 1)
        #expect(last.cpuAverage == 1)
    }

    @Test func topProcessesAreTheFiveBusiest() {
        let processes = (1...7).map { ProcessUsage(pid: Int32($0), name: "p\($0)", cpuPercent: Double($0 * 10), memoryBytes: 1) }
        var aggregator = MetricsAggregator()
        let snapshot = aggregator.ingest(raw(processes: processes.shuffled()))
        #expect(snapshot.topProcesses.map(\.pid) == [7, 6, 5, 4, 3])
    }

    @Test func healthComesFromTheAverageCpuPressureAndDisk() {
        var aggregator = MetricsAggregator()
        #expect(aggregator.ingest(raw(pressure: .critical, diskUsed: 0.5)).health == 65)
        var fresh = MetricsAggregator()
        #expect(fresh.ingest(raw(pressure: .normal, diskUsed: 0.95)).health == 80)
    }
}

// MARK: - Health score

struct HealthScoreTests {
    @Test(arguments: [
        (0.30, MemoryPressure.normal, 0.50, 100),
        (0.60, .normal, 0.50, 100),
        (1.00, .normal, 0.50, 80),
        (0.80, .normal, 0.50, 90),
        (0.00, .warning, 0.50, 85),
        (0.00, .critical, 0.50, 65),
        (0.00, .normal, 0.85, 100),
        (0.00, .normal, 0.95, 80),
        (0.00, .normal, 1.00, 70),
        (1.00, .critical, 1.00, 15),
    ] as [(Double, MemoryPressure, Double, Int)])
    func formulaMatchesTheDocumentedPenalties(cpu: Double, pressure: MemoryPressure, disk: Double, expected: Int) {
        #expect(HealthScore.compute(cpu: cpu, memoryPressure: pressure, diskUsedFraction: disk) == expected)
    }

    @Test func scoreStaysInsideZeroToOneHundred() {
        #expect(HealthScore.compute(cpu: 50, memoryPressure: .critical, diskUsedFraction: 50) == 0)
        #expect(HealthScore.compute(cpu: -1, memoryPressure: .normal, diskUsedFraction: -1) == 100)
    }

    @Test func levelsSplitAtEightyAndSixty() {
        #expect(HealthScore.level(for: 100) == .good)
        #expect(HealthScore.level(for: 80) == .good)
        #expect(HealthScore.level(for: 79) == .fair)
        #expect(HealthScore.level(for: 60) == .fair)
        #expect(HealthScore.level(for: 59) == .busy)
        #expect(HealthScore.Level.fair.title == "Fair")
    }
}

// MARK: - Per-process CPU

struct ProcessCPUTrackerTests {
    private func reading(_ pid: Int32, nanoseconds: UInt64) -> ProcessCPUTracker.Reading {
        ProcessCPUTracker.Reading(pid: pid, name: "p\(pid)", cpuNanoseconds: nanoseconds, memoryBytes: 10)
    }

    @Test func rateIsCpuTimeOverWallTimeAsPercentOfOneCore() {
        var tracker = ProcessCPUTracker()
        let first = tracker.usage(for: [reading(1, nanoseconds: 1_000_000_000)], at: start)
        #expect(first.first?.cpuPercent == 0)

        let second = tracker.usage(for: [reading(1, nanoseconds: 1_500_000_000)], at: start.addingTimeInterval(1))
        #expect(second.first?.cpuPercent == 50)

        // Two cores busy for the whole second.
        let third = tracker.usage(for: [reading(1, nanoseconds: 3_500_000_000)], at: start.addingTimeInterval(2))
        #expect(third.first?.cpuPercent == 200)
    }

    @Test func newProcessesAndResetCountersReportZero() {
        var tracker = ProcessCPUTracker()
        _ = tracker.usage(for: [reading(1, nanoseconds: 5_000_000_000)], at: start)
        let result = tracker.usage(
            for: [reading(1, nanoseconds: 100), reading(2, nanoseconds: 9_000_000_000)],
            at: start.addingTimeInterval(1)
        )
        #expect(result.map(\.cpuPercent) == [0, 0])
        #expect(result.map(\.memoryBytes) == [10, 10])
    }
}

// MARK: - top output

struct TopFrameParserTests {
    /// Two real frames of `top -l 2 -s 1 -n 6 -o cpu -stats pid,command,cpu,mem`, trimmed to what the parser reads.
    private let output = """
    Processes: 1070 total, 4 running, 1066 sleeping, 6697 threads
    2026/10/14 17:45:58
    CPU usage: 5.18% user, 9.13% sys, 85.67% idle

    PID    COMMAND          %CPU MEM
    97045  sed              0.0  1184K
    97044  cut              0.0  1168K
    97043  cat              0.0  1184K
    97042  top              0.0  6576K
    97041  zsh              0.0  2224K
    96462  Google Chrome He 0.0  30M
    Processes: 1070 total, 5 running, 1 stuck, 1064 sleeping, 6690 threads
    2026/10/14 17:45:59
    CPU usage: 6.44% user, 4.13% sys, 89.42% idle

    PID    COMMAND          %CPU MEM
    427    WindowServer     41.2 1093M+
    50593  Claude Helper    17.8 358M-
    0      kernel_task      10.6 26M
    97042  top              8.2  6752K+
    50614  Claude Helper (R 7.8  797M+
    625    BDLDaemon        6.5  408M
    """

    private func frames(rowsPerFrame: Int, from text: String) -> [[ProcessUsage]] {
        var parser = TopFrameParser(rowsPerFrame: rowsPerFrame)
        return text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { parser.feed(String($0)) }
    }

    @Test func theFirstFrameIsDroppedAndTheSecondIsParsed() throws {
        let found = frames(rowsPerFrame: 6, from: output)
        #expect(found.count == 1)
        let rows = try #require(found.first)
        #expect(rows.map(\.pid) == [427, 50593, 0, 97042, 50614, 625])
        #expect(rows[0].name == "WindowServer")
        #expect(rows[0].cpuPercent == 41.2)
        #expect(rows[0].memoryBytes == UInt64(1093.0 * 1_048_576))
        // Names with spaces and a trailing marker survive.
        #expect(rows[4].name == "Claude Helper (R")
        #expect(rows[3].memoryBytes == UInt64(6752.0 * 1_024))
    }

    @Test func aFrameShorterThanTheLimitIsFlushedByTheNextOne() {
        // Only 3 rows per frame arrive before the next header, though the parser expects 6.
        let text = """
        Processes: 1 total
        PID COMMAND %CPU MEM
        1 a 0.0 1K
        Processes: 1 total
        PID COMMAND %CPU MEM
        2 b 5.0 2K
        3 c 4.0 3K
        Processes: 1 total
        """
        let found = frames(rowsPerFrame: 6, from: text)
        #expect(found.count == 1)
        #expect(found.first?.map(\.pid) == [2, 3])
    }

    @Test func rowParsingHandlesOddInputs() {
        #expect(TopFrameParser.parseRow("123  my app 2  3.5  12M")?.name == "my app 2")
        #expect(TopFrameParser.parseRow("123  x  3.5  12M")?.cpuPercent == 3.5)
        #expect(TopFrameParser.parseRow("PID COMMAND %CPU MEM") == nil)
        #expect(TopFrameParser.parseRow("123 x notanumber 12M") == nil)
        #expect(TopFrameParser.parseRow("123 x 1.0") == nil)
        #expect(TopFrameParser.parseRow("") == nil)
    }

    @Test func memoryUnitsConvertToBytes() {
        #expect(TopFrameParser.parseMemory("512B") == 512)
        #expect(TopFrameParser.parseMemory("1K") == 1_024)
        #expect(TopFrameParser.parseMemory("1.5M+") == 1_572_864)
        #expect(TopFrameParser.parseMemory("2G-") == 2_147_483_648)
        #expect(TopFrameParser.parseMemory("1T") == 1_099_511_627_776)
        #expect(TopFrameParser.parseMemory("12") == nil)
        #expect(TopFrameParser.parseMemory("") == nil)
        #expect(TopFrameParser.parseMemory("xM") == nil)
    }
}

// MARK: - The stream

/// Hands out scripted readings and remembers whether it was told to stop.
private final class ScriptedSampler: MetricsSampling, Sendable {
    private struct State {
        var reads = 0
        var finished = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let failFirst: Int

    init(failFirst: Int = 0) {
        self.failFirst = failFirst
    }

    var reads: Int { state.withLock { $0.reads } }
    var finished: Bool { state.withLock { $0.finished } }

    func read(includeProcesses: Bool) throws -> RawMetrics {
        let count = state.withLock { state -> Int in
            state.reads += 1
            return state.reads
        }
        if count <= failFirst { throw MetricsError.systemCallFailed("scripted") }
        let step = UInt64(count)
        return raw(at: Double(count), busy: step * 10, idle: step * 10)
    }

    func finish() {
        state.withLock { $0.finished = true }
    }
}

struct MetricsMonitorTests {
    @Test func emitsSnapshotsAndStopsTheSamplerWhenTheConsumerLeaves() async {
        let sampler = ScriptedSampler()
        var snapshots: [MetricsSnapshot] = []
        for await snapshot in MetricsMonitor.snapshots(sampler: sampler, every: .milliseconds(1)) {
            snapshots.append(snapshot)
            if snapshots.count == 3 { break }
        }
        #expect(snapshots.count == 3)
        #expect(snapshots[1].cpu == 0.5)

        for _ in 0..<200 where !sampler.finished { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(sampler.finished)
        let readsAtStop = sampler.reads
        try? await Task.sleep(for: .milliseconds(50))
        // Sampling really stopped.
        #expect(sampler.reads <= readsAtStop + 1)
    }

    @Test func aSlowConsumerOnlyKeepsTheNewestSnapshot() async {
        let sampler = ScriptedSampler()
        let stream = MetricsMonitor.snapshots(sampler: sampler, every: .milliseconds(1))
        // Nobody is listening yet; the sampler keeps producing.
        for _ in 0..<400 where sampler.reads < 20 { try? await Task.sleep(for: .milliseconds(5)) }
        let readsBeforeConsuming = sampler.reads
        #expect(readsBeforeConsuming >= 20)
        var received: [MetricsSnapshot] = []
        for await snapshot in stream {
            received.append(snapshot)
            if received.count == 2 { break }
        }
        // Reading N is stamped N seconds after the epoch. Unbounded buffering would hand out reading 1 first;
        // with only the newest kept, the first delivery comes from the backlog's tail.
        #expect(received.count == 2)
        #expect(received[0].date.timeIntervalSince(start) > 10)
        #expect(received[1].date > received[0].date)
    }

    @Test func aFailedReadingIsSkippedAndTheNextOneIsTried() async {
        let sampler = ScriptedSampler(failFirst: 2)
        var first: MetricsSnapshot?
        for await snapshot in MetricsMonitor.snapshots(sampler: sampler, every: .milliseconds(1)) {
            first = snapshot
            break
        }
        #expect(first != nil)
        #expect(sampler.reads >= 3)
    }

    @Test func cancellingTheConsumingTaskStopsTheStream() async {
        let sampler = ScriptedSampler()
        let task = Task {
            var count = 0
            for await _ in MetricsMonitor.snapshots(sampler: sampler, every: .milliseconds(1)) { count += 1 }
            return count
        }
        try? await Task.sleep(for: .milliseconds(30))
        task.cancel()
        _ = await task.value
        for _ in 0..<200 where !sampler.finished { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(sampler.finished)
    }
}

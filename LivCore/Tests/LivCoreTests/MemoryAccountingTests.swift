import Foundation
import Testing
@testable import LivCore

/// Pins the memory formulas against Activity Monitor's definitions (measured on 2026-10-15)
/// so they cannot drift again. No test reads the real system.
struct MemoryAccountingTests {
    /// The page counts `vm_stat` printed on the measuring Mac (16 KiB pages, 48 GiB of RAM).
    private let measured = VMCounters(
        internalPages: 1_316_584,
        purgeablePages: 20_018,
        wiredPages: 358_159,
        compressorPages: 797_470,
        externalPages: 591_770,
        pageSize: 16_384
    )
    private let total: UInt64 = 51_539_607_552

    @Test func usedIsAppMemoryPlusWiredPlusCompressed() {
        let reading = MemoryAccounting.reading(from: measured, totalBytes: total, pressure: .normal)
        #expect(reading.appBytes == 1_296_566 * 16_384)
        #expect(reading.wiredBytes == 358_159 * 16_384)
        #expect(reading.compressedBytes == 797_470 * 16_384)
        #expect(reading.usedBytes == 40_176_762_880)
        // About 37.4 GiB: Activity Monitor showed 38.5 to 38.8 at the time, Device Monitor's formula 31.9.
        #expect(abs(Double(reading.usedBytes) / 1_073_741_824 - 37.41) < 0.01)
    }

    @Test func cachedFilesAreFileBackedPlusPurgeable() {
        let reading = MemoryAccounting.reading(from: measured, totalBytes: total, pressure: .normal)
        #expect(reading.cachedBytes == (591_770 + 20_018) * 16_384)
    }

    /// The error Device Monitor made: using the active list instead of App Memory. Anonymous pages parked on the
    /// inactive list are still app memory, so the result must depend on `internal` and never on active/inactive.
    @Test func inactiveAnonymousPagesStillCount() {
        var small = measured
        small.internalPages = 1_000_000
        var large = measured
        large.internalPages = 1_800_000
        let low = MemoryAccounting.reading(from: small, totalBytes: total, pressure: .normal)
        let high = MemoryAccounting.reading(from: large, totalBytes: total, pressure: .normal)
        #expect(high.usedBytes - low.usedBytes == 800_000 * 16_384)
    }

    @Test func pageSizeScalesEverything() {
        var intel = measured
        intel.pageSize = 4_096
        let reading = MemoryAccounting.reading(from: intel, totalBytes: total, pressure: .normal)
        #expect(reading.usedBytes == (1_296_566 + 358_159 + 797_470) * 4_096)
    }

    @Test func purgeableAboveInternalGivesNoAppMemory() {
        var odd = measured
        odd.purgeablePages = odd.internalPages + 10
        let reading = MemoryAccounting.reading(from: odd, totalBytes: total, pressure: .normal)
        #expect(reading.appBytes == 0)
        #expect(reading.usedBytes == (358_159 + 797_470) * 16_384)
    }

    @Test func noCompressorMeansNothingCompressed() {
        var plain = measured
        plain.compressorPages = 0
        let reading = MemoryAccounting.reading(from: plain, totalBytes: total, pressure: .normal)
        #expect(reading.compressedBytes == 0)
        #expect(reading.usedBytes == (1_296_566 + 358_159) * 16_384)
    }

    @Test(arguments: [(Int32(1), MemoryPressure.normal), (2, .warning), (4, .critical), (0, .normal), (3, .normal), (-1, .normal)])
    func pressureLevelsMapToTheThreeStates(level: Int32, expected: MemoryPressure) {
        #expect(MemoryAccounting.pressure(forLevel: level) == expected)
    }
}

// MARK: - CPU figures that were compared with Device Monitor

struct CPUFormulaPinTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func raw(at seconds: TimeInterval, ticks: CPUTicks) -> RawMetrics {
        RawMetrics(
            date: start.addingTimeInterval(seconds),
            cpuTicks: ticks,
            memory: MemoryReading(totalBytes: 16, usedBytes: 8, wiredBytes: 2, compressedBytes: 1, pressure: .normal),
            disk: DiskReading(totalBytes: 1_000, availableBytes: 500),
            network: NetworkCounters(bytesIn: 0, bytesOut: 0),
            battery: nil,
            processes: []
        )
    }

    @Test func niceTimeCountsAsBusy() {
        var aggregator = MetricsAggregator()
        _ = aggregator.ingest(raw(at: 0, ticks: CPUTicks(user: 0, system: 0, idle: 0, nice: 0)))
        let snapshot = aggregator.ingest(raw(at: 1, ticks: CPUTicks(user: 10, system: 10, idle: 60, nice: 20)))
        #expect(snapshot.cpu == 0.4)
    }

    /// `host_statistics` ticks are 32-bit and wrap; a reading below the previous one must not produce a spike.
    @Test func ticksThatWrapKeepTheLastValue() {
        var aggregator = MetricsAggregator()
        _ = aggregator.ingest(raw(at: 0, ticks: CPUTicks(user: 4_294_967_000, system: 0, idle: 4_294_967_000, nice: 0)))
        let first = aggregator.ingest(raw(at: 1, ticks: CPUTicks(user: 4_294_967_050, system: 0, idle: 4_294_967_050, nice: 0)))
        let wrapped = aggregator.ingest(raw(at: 2, ticks: CPUTicks(user: 20, system: 0, idle: 20, nice: 0)))
        #expect(first.cpu == 0.5)
        #expect(wrapped.cpu == first.cpu)
    }

    /// Liv's own row in Top Processes read 54 %: that is percent of one core and is shown as it is, not divided
    /// by the 14 cores.
    @Test func aProcessRowAbove50PercentIsKeptAsParsed() throws {
        let row = try #require(TopFrameParser.parseRow("  75959  LivVitals  54.0  369M"))
        #expect(row.name == "LivVitals")
        #expect(row.cpuPercent == 54.0)
        #expect(row.memoryBytes == 369 * 1_048_576)
    }
}

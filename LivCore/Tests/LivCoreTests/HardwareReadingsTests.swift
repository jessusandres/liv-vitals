import Foundation
import Testing
@testable import LivCore

struct GPUParserTests {
    private func entry(utilization: Any?, key: String = "Device Utilization %", extra: [String: Any] = [:]) -> [String: Any] {
        var stats: [String: Any] = extra
        if let utilization { stats[key] = utilization }
        return ["model": "Apple M4 Pro", "PerformanceStatistics": stats]
    }

    @Test func utilizationIsReadAsAFraction() throws {
        let device = try #require(GPUParser.device(id: 1, properties: entry(utilization: 42, extra: [
            "Renderer Utilization %": 30, "Tiler Utilization %": 12, "In use system memory": 1_048_576,
        ])))
        #expect(device.name == "Apple M4 Pro")
        #expect(device.utilization == 0.42)
        #expect(device.renderer == 0.30)
        #expect(device.tiler == 0.12)
        #expect(device.memoryBytes == 1_048_576)
    }

    @Test func aRealZeroIsAReadingNotAMissingOne() throws {
        let device = try #require(GPUParser.device(id: 1, properties: entry(utilization: 0)))
        #expect(device.utilization == 0)
    }

    @Test func theOlderKeyIsTheFallback() throws {
        let device = try #require(GPUParser.device(id: 1, properties: entry(utilization: 55, key: "GPU Activity(%)")))
        #expect(device.utilization == 0.55)
    }

    @Test func unusableValuesAreMissingNotZero() {
        let values: [Any] = [-1, Double.nan, Double.infinity, true, "12"]
        for value in values {
            #expect(GPUParser.device(id: 1, properties: entry(utilization: value)) == nil)
        }
    }

    @Test func noStatisticsMeansNoReading() {
        #expect(GPUParser.device(id: 1, properties: ["model": "x"]) == nil)
        #expect(GPUParser.reading(from: [(id: UInt64(1), properties: ["model": "x"])]) == nil)
    }

    @Test func overOneHundredIsCapped() throws {
        let device = try #require(GPUParser.device(id: 1, properties: entry(utilization: 250)))
        #expect(device.utilization == 1)
    }

    @Test func withSeveralGpusTheBusiestIsTheHeadline() throws {
        let reading = try #require(GPUParser.reading(from: [
            (id: UInt64(2), properties: entry(utilization: 10)),
            (id: UInt64(1), properties: entry(utilization: 80)),
        ]))
        #expect(reading.devices.map(\.id) == [1, 2])
        #expect(reading.active?.id == 1)
        #expect(reading.utilization == 0.8)
    }

    @Test func aNameStoredAsDataIsDecoded() throws {
        var properties = entry(utilization: 5)
        properties["model"] = Data("Radeon\0junk".utf8)
        #expect(try #require(GPUParser.device(id: 1, properties: properties)).name == "Radeon")
    }
}

struct DiskIOParserTests {
    private func properties(read: Any, written: Any) -> [String: Any] {
        ["Statistics": ["Bytes (Read)": read, "Bytes (Write)": written]]
    }

    @Test func countersAreReadFromTheStatistics() {
        #expect(DiskIOParser.counter(properties: properties(read: 100, written: 50)) == DiskIOCounter(read: 100, written: 50))
    }

    @Test func missingOrNegativeStatisticsGiveNoCounter() {
        #expect(DiskIOParser.counter(properties: [:]) == nil)
        #expect(DiskIOParser.counter(properties: properties(read: -1, written: 5)) == nil)
        #expect(DiskIOParser.counter(properties: ["Statistics": ["Bytes (Read)": 1]]) == nil)
    }

    @Test func deltaSumsTheDriversPresentInBothReadings() {
        let before: [UInt64: DiskIOCounter] = [1: DiskIOCounter(read: 100, written: 10), 2: DiskIOCounter(read: 1_000, written: 0)]
        let now: [UInt64: DiskIOCounter] = [1: DiskIOCounter(read: 150, written: 40), 2: DiskIOCounter(read: 1_200, written: 5)]
        let moved = DiskIOParser.delta(current: now, previous: before)
        #expect(moved.read == 250)
        #expect(moved.written == 35)
    }

    @Test func aCounterThatWentDownAndANewDriverCountAsNothing() {
        let before: [UInt64: DiskIOCounter] = [1: DiskIOCounter(read: 500, written: 500)]
        let now: [UInt64: DiskIOCounter] = [1: DiskIOCounter(read: 100, written: 600), 9: DiskIOCounter(read: 9_999, written: 9_999)]
        let moved = DiskIOParser.delta(current: now, previous: before)
        #expect(moved.read == 0)
        #expect(moved.written == 100)
    }
}

struct DiskActivityAggregationTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    private func raw(at seconds: TimeInterval, counters: [UInt64: DiskIOCounter]?, gpu: GPUReading? = nil) -> RawMetrics {
        RawMetrics(
            date: start.addingTimeInterval(seconds),
            cpuTicks: CPUTicks(user: 0, system: 0, idle: 0, nice: 0),
            memory: MemoryReading(totalBytes: 16, usedBytes: 8, wiredBytes: 2, compressedBytes: 1, pressure: .normal),
            disk: DiskReading(totalBytes: 1_000, availableBytes: 500),
            network: NetworkCounters(bytesIn: 0, bytesOut: 0),
            battery: nil,
            processes: [],
            gpu: gpu,
            diskCounters: counters
        )
    }

    @Test func theFirstReadingHasNoDiskRateAndTheSecondHasOne() {
        var aggregator = MetricsAggregator()
        let first = aggregator.ingest(raw(at: 0, counters: [1: DiskIOCounter(read: 0, written: 0)]))
        let second = aggregator.ingest(raw(at: 2, counters: [1: DiskIOCounter(read: 4_000_000, written: 1_000_000)]))
        #expect(first.diskActivity == nil)
        #expect(second.diskActivity == DiskActivityReading(readBytesPerSecond: 2_000_000, writeBytesPerSecond: 500_000, deviceCount: 1))
    }

    @Test func noCountersMeansNoDiskActivityAndTheGpuPassesThrough() {
        var aggregator = MetricsAggregator()
        let gpu = GPUReading(devices: [GPUDeviceReading(id: 1, name: "GPU", utilization: 0.3)])
        _ = aggregator.ingest(raw(at: 0, counters: nil))
        let snapshot = aggregator.ingest(raw(at: 1, counters: nil, gpu: gpu))
        #expect(snapshot.diskActivity == nil)
        #expect(snapshot.gpu == gpu)
    }

    @Test func nullProcessSamplerReturnsNothing() throws {
        #expect(try NullProcessSampler().sample().isEmpty)
    }
}

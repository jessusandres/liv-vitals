import Foundation
import Testing
@testable import LivCore

/// Runs against the real machine, so it only checks that values are plausible. It reads nothing from the user's files.
struct SystemSamplerTests {
    @Test func readingsAreInsideTheirPhysicalLimits() throws {
        let reading = try SystemSampler(processes: LibprocSampler()).read(includeProcesses: false)

        #expect(reading.memory.totalBytes == ProcessInfo.processInfo.physicalMemory)
        #expect(reading.memory.usedBytes > 0)
        #expect(reading.memory.usedBytes <= reading.memory.totalBytes)
        #expect(reading.memory.wiredBytes <= reading.memory.usedBytes)

        #expect(reading.disk.totalBytes > 0)
        #expect(reading.disk.availableBytes <= reading.disk.totalBytes)

        #expect(reading.cpuTicks.total > 0)
        #expect(reading.cpuTicks.idle > 0)
        #expect(reading.processes.isEmpty)

        if let battery = reading.battery {
            #expect((0...1).contains(battery.level))
            if let health = battery.health { #expect((0...1).contains(health)) }
        }
    }

    @Test func cpuTicksOnlyGrow() throws {
        let sampler = SystemSampler(processes: LibprocSampler())
        let before = try sampler.read(includeProcesses: false).cpuTicks
        let after = try sampler.read(includeProcesses: false).cpuTicks
        #expect(after.total >= before.total)
        #expect(after.idle >= before.idle)
    }

    @Test func networkCountersOnlyGrow() throws {
        let before = try SystemReaders.network()
        let after = try SystemReaders.network()
        #expect(after.bytesIn >= before.bytesIn)
        #expect(after.bytesOut >= before.bytesOut)
    }

    @Test func aStreamProducesRealSnapshotsWithSaneRates() async {
        var snapshots: [MetricsSnapshot] = []
        let sampler = SystemSampler(processes: LibprocSampler())
        for await snapshot in MetricsMonitor.snapshots(sampler: sampler, every: .milliseconds(200), includeProcesses: false) {
            snapshots.append(snapshot)
            if snapshots.count == 3 { break }
        }
        #expect(snapshots.count == 3)
        for snapshot in snapshots {
            #expect((0...1).contains(snapshot.cpu))
            #expect((0...100).contains(snapshot.health))
            #expect(snapshot.downloadBytesPerSecond >= 0)
        }
    }

    @Test func libprocSeesTheTestProcessItself() async throws {
        let sampler = LibprocSampler()
        _ = try sampler.sample()
        try await Task.sleep(for: .milliseconds(300))
        let usage = try sampler.sample()
        let me = try #require(usage.first { $0.pid == ProcessInfo.processInfo.processIdentifier })
        #expect(me.memoryBytes > 0)
        #expect(me.cpuPercent >= 0)
    }

    /// The whole point of using `top`: processes owned by root show up without any privilege.
    @Test func topListsProcessesOfOtherUsersToo() async throws {
        let sampler = TopProcessSampler()
        defer { sampler.finish() }

        var frame: [ProcessUsage] = []
        for _ in 0..<200 where frame.isEmpty {
            // The first frame is dropped, so the first rows arrive after about two seconds.
            try await Task.sleep(for: .milliseconds(50))
            frame = try #require(sampler.latest(), "top could not be started")
        }
        #expect(!frame.isEmpty)
        #expect(frame.count <= 8)
        #expect(frame.allSatisfy { $0.cpuPercent >= 0 && !$0.name.isEmpty })
        // Busiest first, as `-o cpu` sorts them.
        #expect(frame.map(\.cpuPercent) == frame.map(\.cpuPercent).sorted(by: >))
    }

    @Test func theDefaultSamplerUsesTopAndReturnsRows() async throws {
        let sampler = DefaultProcessSampler()
        defer { sampler.finish() }
        var rows: [ProcessUsage] = []
        for _ in 0..<200 where rows.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
            rows = try sampler.sample()
        }
        #expect(!rows.isEmpty)
    }

    @Test func finishingTopStopsItAndItCanStartAgain() async throws {
        let sampler = TopProcessSampler()
        _ = sampler.latest()
        sampler.finish()
        #expect(sampler.latest() != nil)
        sampler.finish()
    }
}

import Foundation

/// Turns a stream of `RawMetrics` into `MetricsSnapshot`s by comparing each reading with the one before.
public struct MetricsAggregator: Sendable {
    private static let averageWindow = 10
    private static let processCount = 8

    private var previous: RawMetrics?
    private var cpu = 0.0
    private var recentCPU: [Double] = []

    public init() {}

    /// The first reading has nothing to compare with, so its CPU and network rates are zero.
    public mutating func ingest(_ raw: RawMetrics) -> MetricsSnapshot {
        var download = 0.0
        var upload = 0.0
        var received: UInt64 = 0
        var sent: UInt64 = 0
        var diskActivity: DiskActivityReading?

        if let previous {
            let busy = Int64(bitPattern: raw.cpuTicks.busy &- previous.cpuTicks.busy)
            let total = Int64(bitPattern: raw.cpuTicks.total &- previous.cpuTicks.total)
            // No ticks elapsed (two readings in the same instant): keep showing the last value.
            if total > 0 { cpu = min(1, max(0, Double(busy) / Double(total))) }

            let seconds = raw.date.timeIntervalSince(previous.date)
            if seconds > 0 {
                received = Self.moved(from: previous.network.bytesIn, to: raw.network.bytesIn)
                sent = Self.moved(from: previous.network.bytesOut, to: raw.network.bytesOut)
                download = Self.rate(from: previous.network.bytesIn, to: raw.network.bytesIn, over: seconds)
                upload = Self.rate(from: previous.network.bytesOut, to: raw.network.bytesOut, over: seconds)
                if let now = raw.diskCounters, let before = previous.diskCounters {
                    let moved = DiskIOParser.delta(current: now, previous: before)
                    diskActivity = DiskActivityReading(
                        readBytesPerSecond: Double(moved.read) / seconds,
                        writeBytesPerSecond: Double(moved.written) / seconds,
                        deviceCount: now.count
                    )
                }
            }
        }
        previous = raw

        recentCPU.append(cpu)
        if recentCPU.count > Self.averageWindow { recentCPU.removeFirst(recentCPU.count - Self.averageWindow) }
        let average = recentCPU.reduce(0, +) / Double(recentCPU.count)

        return MetricsSnapshot(
            date: raw.date,
            cpu: cpu,
            cpuAverage: average,
            memory: raw.memory,
            disk: raw.disk,
            downloadBytesPerSecond: download,
            uploadBytesPerSecond: upload,
            battery: raw.battery,
            topProcesses: Array(raw.processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(Self.processCount)),
            health: HealthScore.compute(cpu: average, memoryPressure: raw.memory.pressure, diskUsedFraction: raw.disk.usedFraction),
            gpu: raw.gpu,
            diskActivity: diskActivity,
            temperature: raw.temperature,
            topMemoryProcesses: Array(raw.processes.sorted { $0.memoryBytes > $1.memoryBytes }.prefix(Self.processCount)),
            networkInterface: raw.networkInterface,
            receivedBytes: received,
            sentBytes: sent
        )
    }

    private static func moved(from old: UInt64, to new: UInt64) -> UInt64 { new >= old ? new - old : 0 }

    /// Bytes per second. A counter that went down (an interface reset) counts as no traffic.
    private static func rate(from old: UInt64, to new: UInt64, over seconds: TimeInterval) -> Double {
        new >= old ? Double(new - old) / seconds : 0
    }
}

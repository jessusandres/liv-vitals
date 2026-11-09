import Foundation

/// Cumulative CPU time in ticks since boot, as `host_statistics` reports it.
public struct CPUTicks: Sendable, Equatable {
    public var user: UInt64
    public var system: UInt64
    public var idle: UInt64
    public var nice: UInt64

    public init(user: UInt64, system: UInt64, idle: UInt64, nice: UInt64) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    public var busy: UInt64 { user + system + nice }
    public var total: UInt64 { busy + idle }
}

public enum MemoryPressure: Int, Sendable, Equatable {
    case normal, warning, critical
}

public struct MemoryReading: Sendable, Equatable {
    public var totalBytes: UInt64
    /// App memory plus wired and compressed, the same "Memory Used" Activity Monitor shows.
    public var usedBytes: UInt64
    public var wiredBytes: UInt64
    public var compressedBytes: UInt64
    public var pressure: MemoryPressure
    /// Anonymous memory minus purgeable: Activity Monitor's "App Memory".
    public var appBytes: UInt64
    /// File-backed plus purgeable memory the system can reclaim: Activity Monitor's "Cached Files".
    public var cachedBytes: UInt64

    public init(
        totalBytes: UInt64,
        usedBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        pressure: MemoryPressure,
        appBytes: UInt64 = 0,
        cachedBytes: UInt64 = 0
    ) {
        self.totalBytes = totalBytes
        self.usedBytes = usedBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.pressure = pressure
        self.appBytes = appBytes
        self.cachedBytes = cachedBytes
    }

    public var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
}

public struct DiskReading: Sendable, Equatable {
    public var totalBytes: UInt64
    public var availableBytes: UInt64

    public init(totalBytes: UInt64, availableBytes: UInt64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public var usedBytes: UInt64 { totalBytes > availableBytes ? totalBytes - availableBytes : 0 }
    public var usedFraction: Double { totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) }
}

/// Bytes moved since boot, summed over the physical interfaces.
public struct NetworkCounters: Sendable, Equatable {
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(bytesIn: UInt64, bytesOut: UInt64) {
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

public struct BatteryReading: Sendable, Equatable {
    /// 0...1
    public var level: Double
    public var isCharging: Bool
    public var isOnACPower: Bool
    public var cycleCount: Int?
    /// Maximum capacity relative to the design capacity, 0...1; nil when the system does not report it.
    public var health: Double?

    public init(level: Double, isCharging: Bool, isOnACPower: Bool, cycleCount: Int?, health: Double?) {
        self.level = level
        self.isCharging = isCharging
        self.isOnACPower = isOnACPower
        self.cycleCount = cycleCount
        self.health = health
    }
}

/// One process with its current CPU use, already a rate.
public struct ProcessUsage: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    /// Percent of one core, so 100 is one busy core and a busy process can exceed it, as in Activity Monitor.
    public var cpuPercent: Double
    public var memoryBytes: UInt64

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

/// One reading of the whole machine, with counters that only grow. `MetricsAggregator` turns two of them into rates.
public struct RawMetrics: Sendable, Equatable {
    public var date: Date
    public var cpuTicks: CPUTicks
    public var memory: MemoryReading
    public var disk: DiskReading
    public var network: NetworkCounters
    /// nil on a Mac without a battery.
    public var battery: BatteryReading?
    public var processes: [ProcessUsage]
    /// nil when the machine does not report a GPU utilization.
    public var gpu: GPUReading?
    /// Bytes moved since boot per storage driver; nil when none is readable.
    public var diskCounters: [UInt64: DiskIOCounter]?
    /// nil unless temperature sensing was asked for and the machine answered.
    public var temperature: TemperatureReading?
    /// nil unless asked for (panels and windows) or when offline.
    public var networkInterface: NetworkInterfaceInfo?

    public init(
        date: Date,
        cpuTicks: CPUTicks,
        memory: MemoryReading,
        disk: DiskReading,
        network: NetworkCounters,
        battery: BatteryReading?,
        processes: [ProcessUsage],
        gpu: GPUReading? = nil,
        diskCounters: [UInt64: DiskIOCounter]? = nil,
        temperature: TemperatureReading? = nil,
        networkInterface: NetworkInterfaceInfo? = nil
    ) {
        self.date = date
        self.cpuTicks = cpuTicks
        self.memory = memory
        self.disk = disk
        self.network = network
        self.battery = battery
        self.processes = processes
        self.gpu = gpu
        self.diskCounters = diskCounters
        self.temperature = temperature
        self.networkInterface = networkInterface
    }
}

/// What the Monitor and the menu bar widget show.
public struct MetricsSnapshot: Sendable, Equatable {
    public var date: Date
    /// 0...1, all cores together.
    public var cpu: Double
    /// Mean of the last 10 readings; the health score uses it so one spike does not move it.
    public var cpuAverage: Double
    public var memory: MemoryReading
    public var disk: DiskReading
    public var downloadBytesPerSecond: Double
    public var uploadBytesPerSecond: Double
    public var battery: BatteryReading?
    /// The busiest processes, most first.
    public var topProcesses: [ProcessUsage]
    /// 0...100, see `HealthScore`.
    public var health: Int
    public var gpu: GPUReading?
    public var diskActivity: DiskActivityReading?
    public var temperature: TemperatureReading?
    /// The processes using the most memory, most first.
    public var topMemoryProcesses: [ProcessUsage]
    public var networkInterface: NetworkInterfaceInfo?
    /// Bytes moved since the previous reading; a counter reset counts as 0.
    public var receivedBytes: UInt64
    public var sentBytes: UInt64

    public init(
        date: Date,
        cpu: Double,
        cpuAverage: Double,
        memory: MemoryReading,
        disk: DiskReading,
        downloadBytesPerSecond: Double,
        uploadBytesPerSecond: Double,
        battery: BatteryReading?,
        topProcesses: [ProcessUsage],
        health: Int,
        gpu: GPUReading? = nil,
        diskActivity: DiskActivityReading? = nil,
        temperature: TemperatureReading? = nil,
        topMemoryProcesses: [ProcessUsage] = [],
        networkInterface: NetworkInterfaceInfo? = nil,
        receivedBytes: UInt64 = 0,
        sentBytes: UInt64 = 0
    ) {
        self.date = date
        self.cpu = cpu
        self.cpuAverage = cpuAverage
        self.memory = memory
        self.disk = disk
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
        self.battery = battery
        self.topProcesses = topProcesses
        self.health = health
        self.gpu = gpu
        self.diskActivity = diskActivity
        self.temperature = temperature
        self.topMemoryProcesses = topMemoryProcesses
        self.networkInterface = networkInterface
        self.receivedBytes = receivedBytes
        self.sentBytes = sentBytes
    }
}

/// Reads the machine once. Tests use a fake; the app uses `SystemSampler`.
public protocol MetricsSampling: Sendable {
    func read(includeProcesses: Bool) throws -> RawMetrics
    /// Called when nobody is watching any more, so the sampler can stop background work.
    func finish()
}

extension MetricsSampling {
    public func finish() {}
}

public enum MetricsError: Error, Equatable, Sendable, CustomStringConvertible {
    case systemCallFailed(String)

    public var description: String {
        switch self {
        case .systemCallFailed(let name): "System call failed: \(name)"
        }
    }
}

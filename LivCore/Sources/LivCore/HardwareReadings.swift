import Foundation

// GPU and storage activity: ported from the author's Device Monitor (GPL-3.0-or-later), rewritten with pure parsers
// so they are tested with fake registry dictionaries. A reading the machine does not give is `nil` ("—" on screen),
// never an invented zero; a real 0 % is a valid reading.

// MARK: - GPU

public struct GPUDeviceReading: Sendable, Equatable {
    public var id: UInt64
    public var name: String
    /// 0...1
    public var utilization: Double
    public var renderer: Double?
    public var tiler: Double?
    public var memoryBytes: UInt64?

    public init(id: UInt64, name: String, utilization: Double, renderer: Double? = nil, tiler: Double? = nil, memoryBytes: UInt64? = nil) {
        self.id = id
        self.name = name
        self.utilization = utilization
        self.renderer = renderer
        self.tiler = tiler
        self.memoryBytes = memoryBytes
    }
}

public struct GPUReading: Sendable, Equatable {
    public var devices: [GPUDeviceReading]

    public init(devices: [GPUDeviceReading]) {
        self.devices = devices
    }

    /// With several GPUs the headline is the busiest one.
    public var active: GPUDeviceReading? { devices.max { $0.utilization < $1.utilization } }
    public var utilization: Double { active?.utilization ?? 0 }
}

public enum GPUParser {
    /// One `IOAccelerator` registry entry. Nil when it carries no usable utilization.
    public static func device(id: UInt64, properties: [String: Any]) -> GPUDeviceReading? {
        guard let stats = properties["PerformanceStatistics"] as? [String: Any],
              let utilization = percentage(stats["Device Utilization %"]) ?? percentage(stats["GPU Activity(%)"])
        else { return nil }
        let name = string(properties["model"]) ?? "GPU"
        let memory = (stats["In use system memory"] as? NSNumber).flatMap { number -> UInt64? in
            guard CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0 else { return nil }
            return number.uint64Value
        }
        return GPUDeviceReading(
            id: id,
            name: name,
            utilization: utilization,
            renderer: percentage(stats["Renderer Utilization %"]),
            tiler: percentage(stats["Tiler Utilization %"]),
            memoryBytes: memory
        )
    }

    public static func reading(from entries: [(id: UInt64, properties: [String: Any])]) -> GPUReading? {
        let devices = entries.compactMap { device(id: $0.id, properties: $0.properties) }.sorted { $0.id < $1.id }
        return devices.isEmpty ? nil : GPUReading(devices: devices)
    }

    /// A 0...100 number as 0...1; booleans, negatives and non-finite values are rejected.
    static func percentage(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue >= 0
        else { return nil }
        return min(100, number.doubleValue) / 100
    }

    private static func string(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        if let data = value as? Data { return String(decoding: data.prefix { $0 != 0 }, as: UTF8.self) }
        return nil
    }
}

// MARK: - Storage activity

/// Bytes a storage driver has moved since boot.
public struct DiskIOCounter: Sendable, Equatable {
    public var read: UInt64
    public var written: UInt64

    public init(read: UInt64, written: UInt64) {
        self.read = read
        self.written = written
    }
}

/// Read and write speed of the internal storage, already a rate.
public struct DiskActivityReading: Sendable, Equatable {
    public var readBytesPerSecond: Double
    public var writeBytesPerSecond: Double
    public var deviceCount: Int

    public init(readBytesPerSecond: Double, writeBytesPerSecond: Double, deviceCount: Int) {
        self.readBytesPerSecond = readBytesPerSecond
        self.writeBytesPerSecond = writeBytesPerSecond
        self.deviceCount = deviceCount
    }
}

public enum DiskIOParser {
    /// One `IOBlockStorageDriver` entry's `Statistics` dictionary.
    public static func counter(properties: [String: Any]) -> DiskIOCounter? {
        guard let stats = properties["Statistics"] as? [String: Any],
              let read = stats["Bytes (Read)"] as? NSNumber, let written = stats["Bytes (Write)"] as? NSNumber,
              CFGetTypeID(read) != CFBooleanGetTypeID(), CFGetTypeID(written) != CFBooleanGetTypeID(),
              read.doubleValue >= 0, written.doubleValue >= 0
        else { return nil }
        return DiskIOCounter(read: read.uint64Value, written: written.uint64Value)
    }

    /// Bytes moved between two readings, summed over the drivers present in both. A counter that went down (a driver
    /// that restarted) counts as nothing, and a driver seen for the first time has no baseline yet.
    public static func delta(current: [UInt64: DiskIOCounter], previous: [UInt64: DiskIOCounter]) -> (read: UInt64, written: UInt64) {
        var read: UInt64 = 0
        var written: UInt64 = 0
        for (id, now) in current {
            guard let before = previous[id] else { continue }
            if now.read >= before.read { read &+= now.read - before.read }
            if now.written >= before.written { written &+= now.written - before.written }
        }
        return (read, written)
    }
}

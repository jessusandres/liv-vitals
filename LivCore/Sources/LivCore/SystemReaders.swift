import Darwin
import Foundation
import IOKit
import IOKit.ps

extension String {
    /// Text from a null-terminated C character buffer.
    init(cBuffer: [CChar]) {
        self.init(decoding: cBuffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// One function per hardware reading. Each only reads; none changes anything on the system.
enum SystemReaders {
    static func cpuTicks() throws -> CPUTicks {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw MetricsError.systemCallFailed("host_statistics") }
        // The tuple is indexed by CPU_STATE_USER, SYSTEM, IDLE, NICE.
        return CPUTicks(
            user: UInt64(info.cpu_ticks.0),
            system: UInt64(info.cpu_ticks.1),
            idle: UInt64(info.cpu_ticks.2),
            nice: UInt64(info.cpu_ticks.3)
        )
    }

    static func memory() throws -> MemoryReading {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let status = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { throw MetricsError.systemCallFailed("host_statistics64") }

        var pageSize: vm_size_t = 0
        host_page_size(mach_host_self(), &pageSize)
        let page = UInt64(pageSize)

        // The formula lives in `MemoryAccounting` so it is tested without the system.
        let counters = VMCounters(
            internalPages: UInt64(stats.internal_page_count),
            purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count),
            compressorPages: UInt64(stats.compressor_page_count),
            externalPages: UInt64(stats.external_page_count),
            pageSize: page
        )
        return MemoryAccounting.reading(from: counters, totalBytes: ProcessInfo.processInfo.physicalMemory, pressure: memoryPressure())
    }

    private static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .normal }
        return MemoryAccounting.pressure(forLevel: level)
    }

    static func disk() throws -> DiskReading {
        let values = try URL(filePath: "/").resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
        ])
        guard let total = values.volumeTotalCapacity else { throw MetricsError.systemCallFailed("volumeTotalCapacity") }
        let available = values.volumeAvailableCapacityForImportantUsage ?? 0
        return DiskReading(totalBytes: UInt64(max(0, total)), availableBytes: UInt64(max(0, available)))
    }

    /// Sums the 64-bit counters of the physical interfaces (`en*`). Tunnels such as VPNs carry the same
    /// traffic again and loopback is internal, so counting them would inflate the numbers.
    static func network() throws -> NetworkCounters {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var length = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &length, nil, 0) == 0 else {
            throw MetricsError.systemCallFailed("sysctl NET_RT_IFLIST2")
        }
        var buffer = [UInt8](repeating: 0, count: length)
        guard sysctl(&mib, UInt32(mib.count), &buffer, &length, nil, 0) == 0 else {
            throw MetricsError.systemCallFailed("sysctl NET_RT_IFLIST2")
        }

        var received: UInt64 = 0
        var sent: UInt64 = 0
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let messageLength = Int(header.ifm_msglen)
                guard messageLength > 0 else { break }
                if Int32(header.ifm_type) == RTM_IFINFO2, offset + MemoryLayout<if_msghdr2>.size <= length {
                    let message = raw.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                    var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                    if if_indextoname(UInt32(message.ifm_index), &name) != nil,
                       String(cBuffer: name).hasPrefix("en"),
                       message.ifm_flags & IFF_UP != 0 {
                        received &+= message.ifm_data.ifi_ibytes
                        sent &+= message.ifm_data.ifi_obytes
                    }
                }
                offset += messageLength
            }
        }
        return NetworkCounters(bytesIn: received, bytesOut: sent)
    }

    /// nil on a Mac without a battery.
    static func battery() -> BatteryReading? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int
            else { continue }
            let maximum = max(1, description[kIOPSMaxCapacityKey] as? Int ?? 100)
            let details = batteryRegistryDetails()
            return BatteryReading(
                level: min(1, max(0, Double(current) / Double(maximum))),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                isOnACPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue,
                cycleCount: details.cycleCount,
                health: details.health
            )
        }
        return nil
    }

    /// Cycle count and capacity health come from the `AppleSmartBattery` registry entry.
    private static func batteryRegistryDetails() -> (cycleCount: Int?, health: Double?) {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, nil) }
        defer { IOObjectRelease(service) }

        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any]
        else { return (nil, nil) }

        let cycles = dictionary["CycleCount"] as? Int

        // Apple Silicon: `MaxCapacity` is already the percentage System Information shows. Intel reports
        // it in mAh (above 100), so health is the raw maximum over the design capacity instead.
        if let percent = dictionary["MaxCapacity"] as? Int, (1...100).contains(percent) {
            return (cycles, Double(percent) / 100)
        }
        let nested = dictionary["BatteryData"] as? [String: Any] ?? [:]
        func capacity(_ key: String) -> Int? { (dictionary[key] as? Int) ?? (nested[key] as? Int) }
        let design = capacity("DesignCapacity")
        let maximum = capacity("AppleRawMaxCapacity") ?? capacity("NominalChargeCapacity")
        var health: Double?
        if let design, let maximum, design > 0, maximum > 0 {
            health = min(1, Double(maximum) / Double(design))
        }
        return (cycles, health)
    }
}

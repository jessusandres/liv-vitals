import Foundation
import IOKit
import os

// Read-only port of the author's Vorssaint SMC client (GPL-3.0-or-later): it asks AppleSMC for temperature keys and
// nothing else. There is no write path on purpose.

/// Minimal read-only client for the System Management Controller.
final class SMCClient {
    struct Key: Sendable {
        let code: UInt32
        let name: String
        let dataSize: UInt32
        let dataType: String
    }

    private var connection: io_connect_t = 0

    // Selector and command bytes of the SMC user client.
    private static let handleYPCEvent: UInt32 = 2
    private static let cmdReadKey: UInt8 = 5
    private static let cmdKeyFromIndex: UInt8 = 8
    private static let cmdKeyInfo: UInt8 = 9

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess else { return nil }
    }

    deinit {
        if connection != 0 { IOServiceClose(connection) }
    }

    /// Every SMC key whose name passes `filter`, with its size and type.
    func keys(where filter: (String) -> Bool) -> [Key] {
        var result: [Key] = []
        for index in 0..<keyCount() {
            var probe = SMCParamStruct()
            probe.data8 = Self.cmdKeyFromIndex
            probe.data32 = UInt32(index)
            guard let out = call(&probe), out.result == 0 else { continue }

            let name = Self.fourCCString(out.key)
            guard filter(name) else { continue }

            var infoIn = SMCParamStruct()
            infoIn.key = out.key
            infoIn.data8 = Self.cmdKeyInfo
            guard let info = call(&infoIn), info.result == 0 else { continue }

            result.append(Key(code: out.key, name: name, dataSize: info.keyInfo.dataSize, dataType: Self.fourCCString(info.keyInfo.dataType)))
        }
        return result
    }

    func readValue(_ key: Key) -> Double? {
        guard key.dataSize > 0, key.dataSize <= 32 else { return nil }
        var input = SMCParamStruct()
        input.key = key.code
        input.keyInfo.dataSize = key.dataSize
        input.data8 = Self.cmdReadKey
        guard let out = call(&input), out.result == 0 else { return nil }
        let bytes = withUnsafeBytes(of: out.bytes) { Array($0.prefix(Int(key.dataSize))) }
        return SMCValueCodec.decode(bytes, type: key.dataType)
    }

    private func keyCount() -> Int {
        var input = SMCParamStruct()
        input.key = Self.fourCC("#KEY")
        input.keyInfo.dataSize = 4
        input.data8 = Self.cmdReadKey
        guard let out = call(&input), out.result == 0 else { return 0 }
        let b = withUnsafeBytes(of: out.bytes) { Array($0.prefix(4)) }
        return Int(UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3]))
    }

    private func call(_ input: inout SMCParamStruct) -> SMCParamStruct? {
        var output = SMCParamStruct()
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let result = IOConnectCallStructMethod(
            connection, Self.handleYPCEvent, &input, MemoryLayout<SMCParamStruct>.stride, &output, &outSize
        )
        return result == kIOReturnSuccess ? output : nil
    }

    private static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private static func fourCCString(_ v: UInt32) -> String {
        let chars = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: chars, encoding: .ascii) ?? "????"
    }
}

/// Wire format of the AppleSMC user client (fixed 80-byte layout).
struct SMCParamStruct {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

struct SMCVersion {
    var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SMCPLimitData {
    var version: UInt16 = 0, length: UInt16 = 0
    var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
}

struct SMCKeyInfoData {
    var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
}

/// Reads the CPU, GPU and battery temperatures. A light read (`detailed: false`) asks only for the CPU sensors, plus the
/// GPU ones when `includeGPU` is set; a detailed one, used while a panel is open, also reads the GPU, the battery and
/// every sensor for the list.
/// Blocking: call it off the main thread.
public final class SMCTemperatureSampler: @unchecked Sendable {
    private struct Keys: Sendable {
        var platform: CPUTemperaturePlatform
        var preferredCPU: [SMCClient.Key]
        var fallbackCPU: [SMCClient.Key]
        var gpu: [SMCClient.Key]
        var battery: [SMCClient.Key]
    }

    private struct State {
        var client: SMCClient?
        var opened = false
        var cpuCache: CachedSensorReading?
        var gpuCache: CachedSensorReading?
        var batteryCache: CachedSensorReading?
        var cpuPeak = RecentPeak()
        var gpuPeak = RecentPeak()
    }

    // shortcut: keys are enumerated once per process and shared by every sampler, so switching between light and
    // full streams does not walk every SMC key again; revisit if keys ever need rediscovery (hot-plug does not apply).
    private static let keys = OSAllocatedUnfairLock<Keys?>(initialState: nil)

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    /// Longest a missed read keeps showing the last value.
    private let maxAge: TimeInterval

    public init(maxAge: TimeInterval = 30) {
        self.maxAge = maxAge
    }

    /// nil when the SMC cannot be opened or no plausible CPU temperature is readable.
    public func read(detailed: Bool, includeGPU: Bool = false) -> TemperatureReading? {
        state.withLockUnchecked { state in
            if !state.opened {
                state.opened = true
                state.client = SMCClient()
            }
            guard let client = state.client else { return nil }
            let keys = Self.discoveredKeys(using: client)
            let now = ProcessInfo.processInfo.systemUptime

            var cpuReadings = Self.readings(of: keys.preferredCPU, with: client)
            var cpu = TemperatureSensorSelector.displayedCPUTemperature(readings: cpuReadings, platform: keys.platform)
            // The core set decides the value when it answers; the rest is swept when it is silent, or for the list.
            if cpu == nil || detailed {
                cpuReadings += Self.readings(of: keys.fallbackCPU, with: client)
                cpu = cpu ?? TemperatureSensorSelector.displayedCPUTemperature(readings: cpuReadings, platform: keys.platform)
            }
            guard let stable = TemperatureSensorSelector.stabilizedTemperature(cpu, cache: &state.cpuCache, now: now, maxAge: maxAge),
                  let cpu = state.cpuPeak.add(stable, now: now) else {
                return nil
            }
            guard detailed || includeGPU else { return TemperatureReading(cpu: cpu) }

            let gpuReadings = Self.readings(of: keys.gpu, with: client)
            let gpu = state.gpuPeak.add(TemperatureSensorSelector.stabilizedTemperature(
                gpuReadings.map(\.value).max(), cache: &state.gpuCache, now: now, maxAge: maxAge
            ), now: now)
            guard detailed else { return TemperatureReading(cpu: cpu, gpu: gpu) }

            let batteryReadings = Self.readings(of: keys.battery, with: client)
            let battery = TemperatureSensorSelector.stabilizedTemperature(
                batteryReadings.map(\.value).max(), cache: &state.batteryCache, now: now, maxAge: maxAge, minimum: 1
            )
            let sensors = (
                cpuReadings.map { ("CPU", $0) } + gpuReadings.map { ("GPU", $0) } + batteryReadings.map { ("Battery", $0) }
            )
            .filter { $0.1.value >= TemperatureSensorSelector.minimumChipTemperature && $0.1.value < TemperatureSensorSelector.maximumTemperature }
            .map { TemperatureReading.Sensor(name: "\($0.0) · \($0.1.key)", celsius: $0.1.value) }
            .sorted { $0.celsius > $1.celsius }
            return TemperatureReading(cpu: cpu, gpu: gpu, battery: battery, sensors: sensors)
        }
    }

    private static func discoveredKeys(using client: SMCClient) -> Keys {
        keys.withLockUnchecked { cached in
            if let cached { return cached }
            let platform = TemperatureSensorSelector.currentPlatform()
            let all = client.keys { name in
                TemperatureSensorSelector.isCPUTemperatureKey(name, platform: platform)
                    || name.hasPrefix("Tg")
                    || name.range(of: "^TB[0-9]T$", options: .regularExpression) != nil
            }
            let cpu = all.filter { TemperatureSensorSelector.isCPUTemperatureKey($0.name, platform: platform) }
            let preferred = cpu.filter { TemperatureSensorSelector.isCPUCoreKey($0.name, platform: platform) }
            let preferredNames = Set(preferred.map(\.name))
            let discovered = Keys(
                platform: platform,
                preferredCPU: preferred,
                fallbackCPU: cpu.filter { !preferredNames.contains($0.name) },
                gpu: all.filter { $0.name.hasPrefix("Tg") },
                battery: all.filter { $0.name.hasPrefix("TB") }
            )
            // An empty walk may be a transient SMC failure; leave it uncached so the next read tries again.
            if !all.isEmpty { cached = discovered }
            return discovered
        }
    }

    private static func readings(of keys: [SMCClient.Key], with client: SMCClient) -> [(key: String, value: Double)] {
        keys.compactMap { key in client.readValue(key).map { (key.name, $0) } }
    }
}

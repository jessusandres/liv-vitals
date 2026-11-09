import Darwin
import Foundation

// CPU, GPU and battery temperatures from the SMC: key selection, value filtering and decoding, ported from the
// author's Vorssaint (GPL-3.0-or-later) and trimmed to what a read-only indicator needs. Pure, so it is tested
// without hardware. `SMCTemperatureSampler` does the actual reading.

/// What the temperature indicator and its panel show. A reading exists only when the CPU temperature is known.
public struct TemperatureReading: Sendable, Equatable {
    public struct Sensor: Sendable, Equatable {
        public var name: String
        public var celsius: Double

        public init(name: String, celsius: Double) {
            self.name = name
            self.celsius = celsius
        }
    }

    public var cpu: Double
    public var gpu: Double?
    public var battery: Double?
    /// Every readable sensor, hottest first; empty in a light reading.
    public var sensors: [Sensor]

    public init(cpu: Double, gpu: Double? = nil, battery: Double? = nil, sensors: [Sensor] = []) {
        self.cpu = cpu
        self.gpu = gpu
        self.battery = battery
        self.sensors = sensors
    }
}

enum CPUTemperaturePlatform: Equatable {
    case appleM1Family
    case appleM2Family
    case appleM3Family
    case appleM4Family
    case appleM4ProFamily
    case appleM5Family
    case unmappedAppleSilicon
    case generic
}

struct CachedSensorReading: Equatable {
    var value: Double
    var updatedAt: TimeInterval
    var missedSamples: Int
}

/// The highest reading of the last `window` seconds. Apple silicon parks an idle core cluster and its sensors then
/// report a placeholder (0 or 40 °C), so the hottest live sensor jumps between clusters from one second to the next;
/// a short peak hold shows the chip's temperature instead of which cluster happened to be awake.
struct RecentPeak {
    var window: TimeInterval = 5
    private var samples: [(time: TimeInterval, value: Double)] = []

    init(window: TimeInterval = 5) { self.window = window }

    mutating func add(_ value: Double?, now: TimeInterval) -> Double? {
        samples.removeAll { now - $0.time >= window }
        if let value { samples.append((now, value)) }
        return samples.map(\.value).max()
    }
}

enum TemperatureSensorSelector {
    static let minimumChipTemperature = 10.0
    static let maximumTemperature = 125.0

    private static let appleM1CPUCoreKeys: Set<String> = [
        "Tp09", "Tp0T",
        "Tp01", "Tp05", "Tp0D", "Tp0H",
        "Tp0L", "Tp0P", "Tp0X", "Tp0b",
    ]

    private static let appleM2CPUCoreKeys: Set<String> = [
        "Tp1h", "Tp1t", "Tp1p", "Tp1l",
        "Tp01", "Tp05", "Tp09", "Tp0D",
        "Tp0X", "Tp0b", "Tp0f", "Tp0j",
    ]

    private static let appleM3CPUCoreKeys: Set<String> = [
        "Te05", "Te0L", "Te0P", "Te0S",
        "Tf04", "Tf09", "Tf0A", "Tf0B",
        "Tf0D", "Tf0E", "Tf44", "Tf49",
        "Tf4A", "Tf4B", "Tf4D", "Tf4E",
    ]

    private static let appleM4CPUCoreKeys: Set<String> = [
        "Te05", "Te0S", "Te09", "Te0H",
        "Tp01", "Tp05", "Tp09", "Tp0D",
        "Tp0V", "Tp0Y", "Tp0b", "Tp0e",
    ]

    // Read on an M4 Pro (Mac16,8), which lacks three of the base M4 keys and
    // runs hottest on sensors outside them. Each Tpx/Tex key repeats the
    // hottest of a few Tp/Te sensors; in idle and loaded samples no other
    // Tp/Te key read hotter beyond the moment between two reads. The Tex
    // keys keep answering while the P cores are parked.
    private static let appleM4ProCPUCoreKeys: Set<String> = [
        "Tex0", "Tex1", "Tex2", "Tex3",
        "Tpx0", "Tpx1", "Tpx2", "Tpx3", "Tpx4", "Tpx5",
        "Tpx8", "Tpx9", "TpxA", "TpxB", "TpxC", "TpxD",
    ]

    private static let appleM5CPUCoreKeys: Set<String> = [
        "Tp00", "Tp04", "Tp08", "Tp0C",
        "Tp0G", "Tp0K",
        "Tp0O", "Tp0R", "Tp0U", "Tp0X",
        "Tp0a", "Tp0d", "Tp0g", "Tp0j",
        "Tp0m", "Tp0p", "Tp0u", "Tp0y",
    ]

    static func platform(brandString: String?) -> CPUTemperaturePlatform {
        let brand = brandString?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch appleSiliconGeneration(in: brand) {
        case 1: return .appleM1Family
        case 2: return .appleM2Family
        case 3: return .appleM3Family
        case 4: return brand == "Apple M4 Pro" ? .appleM4ProFamily : .appleM4Family
        case 5: return .appleM5Family
        default: return brand.hasPrefix("Apple ") ? .unmappedAppleSilicon : .generic
        }
    }

    static func currentPlatform() -> CPUTemperaturePlatform {
        var size = 0
        guard sysctlbyname("machdep.cpu.brand_string", nil, &size, nil, 0) == 0, size > 0 else {
            return .unmappedAppleSilicon
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("machdep.cpu.brand_string", &buffer, &size, nil, 0) == 0 else {
            return .unmappedAppleSilicon
        }
        return platform(brandString: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
    }

    static func displayedCPUTemperature(readings: [(key: String, value: Double)],
                                        platform: CPUTemperaturePlatform) -> Double? {
        let valid = readings.filter { isPlausibleTemperature($0.value) }
        guard !valid.isEmpty else { return nil }

        let core = valid.filter { isCPUCoreKey($0.key, platform: platform) }
        if let value = core.map({ $0.value }).max() {
            return value
        }
        // Not every Mac carries the sensors its chip generation is mapped to.
        // One that does not showed the hottest reading of its CPU families
        // instead, for as long as the app has had this panel, until 3.3.3
        // restricted the answer to the mapped sensors and left those Macs with
        // nothing. This is that reading, restored exactly. Fan control is a
        // separate decision and keeps requiring its own mapped readings.
        return valid.map { $0.value }.max()
    }

    static func isCPUCoreKey(_ key: String, platform: CPUTemperaturePlatform) -> Bool {
        switch platform {
        case .appleM1Family:
            return appleM1CPUCoreKeys.contains(key)
        case .appleM2Family:
            return appleM2CPUCoreKeys.contains(key)
        case .appleM3Family:
            return appleM3CPUCoreKeys.contains(key)
        case .appleM4Family:
            return appleM4CPUCoreKeys.contains(key)
        case .appleM4ProFamily:
            return appleM4ProCPUCoreKeys.contains(key)
        case .appleM5Family:
            return appleM5CPUCoreKeys.contains(key)
        case .unmappedAppleSilicon, .generic:
            return false
        }
    }

    static func isCPUTemperatureKey(_ key: String,
                                    platform: CPUTemperaturePlatform) -> Bool {
        if key.hasPrefix("Tp") || key.hasPrefix("Te") { return true }
        return platform == .appleM3Family && key.hasPrefix("Tf")
    }

    static func stabilizedTemperature(_ reading: Double?,
                                      cache: inout CachedSensorReading?,
                                      now: TimeInterval,
                                      maxAge: TimeInterval,
                                      minimum: Double = minimumChipTemperature) -> Double? {
        if let reading, reading >= minimum, reading < maximumTemperature {
            cache = CachedSensorReading(value: reading, updatedAt: now, missedSamples: 0)
            return reading
        }
        guard var cached = cache else { return nil }
        cached.missedSamples += 1
        if cached.missedSamples <= 4, now - cached.updatedAt <= maxAge {
            cache = cached
            return cached.value
        }
        cache = nil
        return nil
    }

    private static func appleSiliconGeneration(in brand: String) -> Int? {
        guard brand.hasPrefix("Apple M") else { return nil }
        let remainder = brand.dropFirst("Apple M".count)
        guard let first = remainder.first, let generation = Int(String(first)) else { return nil }
        guard generation >= 1, generation <= 5 else { return nil }
        let afterGeneration = remainder.dropFirst()
        guard afterGeneration.isEmpty || afterGeneration.first == " " else { return nil }
        return generation
    }

    private static func isPlausibleTemperature(_ value: Double) -> Bool {
        value >= minimumChipTemperature && value < maximumTemperature
    }
}

/// Decodes the value types temperature keys use. Read-only: nothing here encodes.
enum SMCValueCodec {
    static func decode(_ bytes: [UInt8], type: String) -> Double? {
        switch type {
        case "flt " where bytes.count == 4:
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8 | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Double(Float32(bitPattern: bits))
            return value.isFinite ? value : nil
        case "fpe2" where bytes.count == 2:
            return Double(UInt16(bytes[0]) << 8 | UInt16(bytes[1])) / 4.0
        case "sp78" where bytes.count == 2:
            return Double(Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))) / 256.0
        default:
            return nil
        }
    }
}

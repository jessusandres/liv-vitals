import Foundation
import Testing
@testable import LivCore

struct TemperatureTests {
    private typealias Selector = TemperatureSensorSelector

    // MARK: - Plausible range

    @Test func valuesOutsideTheChipRangeAreRejected() {
        for value in [0.0, -5, 9.9, 125, 200, .nan] {
            #expect(Selector.displayedCPUTemperature(readings: [("Tp01", value)], platform: .generic) == nil)
        }
        #expect(Selector.displayedCPUTemperature(readings: [("Tp01", 10)], platform: .generic) == 10)
        #expect(Selector.displayedCPUTemperature(readings: [("Tp01", 124.9)], platform: .generic) == 124.9)
    }

    // MARK: - Selection

    @Test func mappedCoreKeysWinOverHotterNonCoreKeys() {
        let readings: [(key: String, value: Double)] = [("Tpx0", 50), ("Tpx1", 55), ("Tp0z", 90)]
        #expect(Selector.displayedCPUTemperature(readings: readings, platform: .appleM4ProFamily) == 55)
    }

    @Test func withoutACoreKeyTheHottestPlausibleKeyIsShown() {
        let readings: [(key: String, value: Double)] = [("Tp0z", 48), ("Te09", 61), ("Tp0y", 300)]
        #expect(Selector.displayedCPUTemperature(readings: readings, platform: .appleM4ProFamily) == 61)
        #expect(Selector.displayedCPUTemperature(readings: [], platform: .generic) == nil)
    }

    @Test func theBrandStringPicksThePlatform() {
        #expect(Selector.platform(brandString: "Apple M4 Pro") == .appleM4ProFamily)
        #expect(Selector.platform(brandString: "Apple M4 Max") == .appleM4Family)
        #expect(Selector.platform(brandString: "Apple M1") == .appleM1Family)
        #expect(Selector.platform(brandString: "Apple M9") == .unmappedAppleSilicon)
        #expect(Selector.platform(brandString: "Intel(R) Core(TM) i7-9750H CPU @ 2.60GHz") == .generic)
        #expect(Selector.platform(brandString: nil) == .generic)
    }

    @Test func cpuKeysAreTpAndTeAndTfOnlyOnM3() {
        #expect(Selector.isCPUTemperatureKey("Tp01", platform: .generic))
        #expect(Selector.isCPUTemperatureKey("Te05", platform: .generic))
        #expect(!Selector.isCPUTemperatureKey("Tf04", platform: .appleM4Family))
        #expect(Selector.isCPUTemperatureKey("Tf04", platform: .appleM3Family))
        #expect(!Selector.isCPUTemperatureKey("Tg0f", platform: .appleM3Family))
    }

    // MARK: - Stabilisation

    @Test func aMissKeepsTheLastValueForFourReadsThenDropsIt() {
        var cache: CachedSensorReading?
        #expect(Selector.stabilizedTemperature(60, cache: &cache, now: 0, maxAge: 100) == 60)
        for tick in 1...4 {
            #expect(Selector.stabilizedTemperature(nil, cache: &cache, now: Double(tick), maxAge: 100) == 60)
        }
        #expect(Selector.stabilizedTemperature(nil, cache: &cache, now: 5, maxAge: 100) == nil)
        #expect(cache == nil)
    }

    @Test func aMissOlderThanMaxAgeDropsTheValue() {
        var cache: CachedSensorReading?
        _ = Selector.stabilizedTemperature(60, cache: &cache, now: 0, maxAge: 10)
        #expect(Selector.stabilizedTemperature(nil, cache: &cache, now: 11, maxAge: 10) == nil)
    }

    @Test func anImplausibleReadingCountsAsAMiss() {
        var cache: CachedSensorReading?
        _ = Selector.stabilizedTemperature(60, cache: &cache, now: 0, maxAge: 100)
        #expect(Selector.stabilizedTemperature(130, cache: &cache, now: 1, maxAge: 100) == 60)
        #expect(Selector.stabilizedTemperature(5, cache: &cache, now: 2, maxAge: 100, minimum: 10) == 60)
    }

    // MARK: - Decoding

    @Test func sp78DecodesSignedFixedPoint() {
        #expect(SMCValueCodec.decode([0x3C, 0x80], type: "sp78") == 60.5)
        #expect(SMCValueCodec.decode([0xFF, 0x00], type: "sp78") == -1)
    }

    @Test func fltDecodesLittleEndianFloat() {
        let bits = Float32(42.5).bitPattern
        let bytes = [UInt8(bits & 0xff), UInt8((bits >> 8) & 0xff), UInt8((bits >> 16) & 0xff), UInt8(bits >> 24)]
        #expect(SMCValueCodec.decode(bytes, type: "flt ") == 42.5)
        #expect(SMCValueCodec.decode([0, 0, 0xC0, 0x7F], type: "flt ") == nil) // NaN
    }

    @Test func fpe2DecodesQuarterSteps() {
        #expect(SMCValueCodec.decode([0x01, 0x91], type: "fpe2") == 100.25)
    }

    @Test func aWrongSizeOrUnknownTypeDecodesToNil() {
        #expect(SMCValueCodec.decode([0x3C], type: "sp78") == nil)
        #expect(SMCValueCodec.decode([1, 2, 3, 4], type: "zzzz") == nil)
    }

    // MARK: - SMC wire format

    @Test func theSMCParamStructIsEightyBytes() {
        #expect(MemoryLayout<SMCParamStruct>.stride == 80)
        #expect(MemoryLayout<SMCParamStruct>.size == 80)
    }

    // MARK: - This Mac

    /// Tolerates a Mac without a readable SMC; where one answers, the value must be plausible.
    @Test func thisMacReportsAPlausibleCPUTemperatureWhenItCan() {
        let reading = SMCTemperatureSampler().read(detailed: true)
        if let reading { print("CPU temperature: \(reading.cpu) °C, GPU: \(String(describing: reading.gpu)), battery: \(String(describing: reading.battery)), sensors: \(reading.sensors.count)") }
        if let cpu = reading?.cpu { #expect((10..<125).contains(cpu)) }
    }

    @Test func aParkedClusterDoesNotDropTheShownTemperatureForFiveSeconds() {
        var peak = RecentPeak()
        #expect(peak.add(77, now: 0) == 77)
        #expect(peak.add(54, now: 1) == 77)   // the P cluster parked; its sensors went to a placeholder
        #expect(peak.add(nil, now: 2) == 77)
        #expect(peak.add(54, now: 5) == 54)   // the 77 is now 5 s old
        #expect(peak.add(nil, now: 20) == nil)
    }
}

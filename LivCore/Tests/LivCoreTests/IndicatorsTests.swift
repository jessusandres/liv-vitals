import Foundation
import Testing
@testable import LivCore

struct IndicatorFormatterTests {
    private let gib = 1_073_741_824.0

    private func snapshot(
        cpu: Double = 0.21,
        battery: BatteryReading? = BatteryReading(level: 0.8, isCharging: false, isOnACPower: true, cycleCount: 103, health: 1),
        gpu: GPUReading? = GPUReading(devices: [GPUDeviceReading(id: 1, name: "GPU", utilization: 0.12)]),
        diskActivity: DiskActivityReading? = DiskActivityReading(readBytesPerSecond: 1_200_000, writeBytesPerSecond: 340_000, deviceCount: 1)
    ) -> MetricsSnapshot {
        MetricsSnapshot(
            date: Date(timeIntervalSince1970: 0),
            cpu: cpu,
            cpuAverage: cpu,
            memory: MemoryReading(totalBytes: UInt64(48 * gib), usedBytes: UInt64(37.4 * gib), wiredBytes: 0, compressedBytes: 0, pressure: .normal),
            disk: DiskReading(totalBytes: 494_000_000_000, availableBytes: 310_000_000_000),
            downloadBytesPerSecond: 1_200_000,
            uploadBytesPerSecond: 340_000,
            battery: battery,
            topProcesses: [],
            health: 100,
            gpu: gpu,
            diskActivity: diskActivity
        )
    }

    @Test func eachMetricHasItsTextAndFraction() {
        let snap = snapshot()
        #expect(IndicatorFormatter.value(.cpu, from: snap).text == "21%")
        #expect(IndicatorFormatter.value(.cpu, from: snap).fraction == 0.21)
        #expect(IndicatorFormatter.value(.memory, from: snap).text == "78%")
        #expect(IndicatorFormatter.value(.gpu, from: snap).text == "12%")
        #expect(IndicatorFormatter.value(.disk, from: snap).text == "37%")
        #expect(IndicatorFormatter.value(.battery, from: snap).text == "80%")
        let network = IndicatorFormatter.value(.network, from: snap)
        #expect(network.text == "↓ 1.2 MB/s")
        #expect(network.secondary == "↑ 340 KB/s")
        #expect(network.fraction == nil)
        #expect(network.chartValue == 1_540_000)
        let io = IndicatorFormatter.value(.diskActivity, from: snap)
        #expect(io.text == "R 1.2 MB/s")
        #expect(io.secondary == "W 340 KB/s")
    }

    @Test func cpuAndGpuShowTheirTemperatureNextToTheUsage() {
        var snap = snapshot()
        snap.temperature = TemperatureReading(cpu: 78.4, gpu: 51.2)
        let cpu = IndicatorFormatter.value(.cpu, from: snap, showTemperature: true)
        #expect(cpu.text == "21% 78°")
        #expect(cpu.temperatureText == "78°")
        #expect(cpu.spoken == "Processor, 21 percent, 78 degrees Celsius")
        #expect(IndicatorFormatter.value(.gpu, from: snap, showTemperature: true).text == "12% 51°")
        #expect(IndicatorFormatter.value(.cpu, from: snap).text == "21%")
        #expect(IndicatorFormatter.value(.memory, from: snap, showTemperature: true).text == "78%")
    }

    @Test func aMissingTemperatureLeavesJustTheUsage() {
        var snap = snapshot()
        #expect(IndicatorFormatter.value(.cpu, from: snap, showTemperature: true).text == "21%")
        snap.temperature = TemperatureReading(cpu: 60)
        let gpu = IndicatorFormatter.value(.gpu, from: snap, showTemperature: true)
        #expect(gpu.text == "12%")
        #expect(gpu.temperatureText == nil)
        #expect(IndicatorFormatter.value(.gpu, from: snapshot(gpu: nil), showTemperature: true).text == "—")
    }

    @Test func temperatureShowsTheCpuInWholeDegrees() {
        var snap = snapshot()
        snap.temperature = TemperatureReading(cpu: 58.6, gpu: 50, battery: nil)
        let value = IndicatorFormatter.value(.temperature, from: snap)
        #expect(value.text == "59°")
        #expect(value.fraction == nil)
        #expect(value.chartValue == 58.6)
        #expect(value.spoken == "Temperature, 59 degrees Celsius")
        #expect(IndicatorFormatter.value(.temperature, from: snapshot()).text == "—")
        #expect(MetricKind.temperature.styles == [.number, .chart, .icon])
        #expect(MetricKind.temperature.shortTitle == "TMP")
    }

    @Test func aMissingReadingIsADashNeverAZero() {
        let snap = snapshot(battery: nil, gpu: nil, diskActivity: nil)
        for metric in [MetricKind.battery, .gpu, .diskActivity] {
            let value = IndicatorFormatter.value(metric, from: snap)
            #expect(value.text == "—")
            #expect(!value.isAvailable)
            #expect(value.fraction == nil)
            #expect(value.spoken == "\(metric.title), not available")
        }
        for metric in MetricKind.allCases {
            #expect(IndicatorFormatter.value(metric, from: nil).text == "—")
        }
    }

    @Test func spokenTextSaysWhatTheNumberIs() {
        let snap = snapshot()
        #expect(IndicatorFormatter.value(.cpu, from: snap).spoken == "Processor, 21 percent")
        #expect(IndicatorFormatter.value(.memory, from: snap).spoken == "Memory, 37.4 of 48.0 gigabytes, 78 percent")
        #expect(IndicatorFormatter.value(.disk, from: snap).spoken == "Disk, 310 gigabytes free, 37 percent used")
        #expect(IndicatorFormatter.value(.battery, from: snap).spoken == "Battery, 80 percent, on power adapter")
        #expect(IndicatorFormatter.value(.network, from: snap).spoken
            == "Network, download 1.2 megabytes per second, upload 340 kilobytes per second")
    }

    @Test(arguments: [
        (0.0, "0 KB/s"), (400.0, "0 KB/s"), (999_499.0, "999 KB/s"), (1_000_000.0, "1.0 MB/s"),
        (12_340_000.0, "12.3 MB/s"), (2_500_000_000.0, "2.50 GB/s"), (-5.0, "0 KB/s"), (Double.nan, "0 KB/s"),
    ])
    func ratesUseDecimalUnitsAndADot(bytes: Double, expected: String) {
        #expect(IndicatorFormatter.rate(bytes) == expected)
    }

    @Test func fractionsAreClampedToZeroToOne() {
        #expect(IndicatorFormatter.value(.cpu, from: snapshot(cpu: 1.7)).fraction == 1)
        #expect(IndicatorFormatter.value(.cpu, from: snapshot(cpu: -0.2)).fraction == 0)
    }
}

struct MetricKindTests {
    @Test func throughputMetricsOfferSpeedAndTheRestOfferGauges() {
        for metric in MetricKind.allCases {
            #expect(metric.styles.contains(metric.defaultStyle))
            #expect(metric.styles.contains(.number))
            #expect(metric.styles.contains(.speed) == metric.isThroughput)
            #expect(metric.styles.contains(.gauge) == (!metric.isThroughput && metric != .temperature))
        }
        #expect(MetricKind.allCases.count == 8)
    }

    @Test func shortTitlesAreTheMenuBarLabels() {
        #expect(MetricKind.allCases.map(\.shortTitle) == ["CPU", "RAM", "GPU", "SSD", "I/O", "NET", "BAT", "TMP"])
    }
}

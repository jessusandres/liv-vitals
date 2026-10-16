import AppKit
import LivCore
import SwiftUI
import Testing
import WidgetKit
@testable import LivWidgetsUI

private let device = DeviceInfo(
    chip: "Apple M4 Pro", model: "Mac16,8", macOSVersion: "27.0.1",
    uptime: 3 * 86_400 + 4 * 3_600 + 120, bootDate: Date(timeIntervalSince1970: 1_800_000_000)
)

private func snapshot(battery: BatteryReading? = BatteryReading(level: 0.66, isCharging: false, isOnACPower: false, cycleCount: 104, health: 1)) -> MetricsSnapshot {
    let gib: UInt64 = 1_073_741_824
    return MetricsSnapshot(
        date: Date(timeIntervalSince1970: 1_800_000_000),
        cpu: 0.21,
        cpuAverage: 0.21,
        memory: MemoryReading(totalBytes: 48 * gib, usedBytes: 37 * gib, wiredBytes: 5 * gib, compressedBytes: 12 * gib, pressure: .normal, appBytes: 20 * gib, cachedBytes: 10 * gib),
        disk: DiskReading(totalBytes: 494_000_000_000, availableBytes: 310_000_000_000),
        downloadBytesPerSecond: 1_200_000,
        uploadBytesPerSecond: 340_000,
        battery: battery,
        topProcesses: [],
        health: 100,
        gpu: GPUReading(devices: [GPUDeviceReading(id: 1, name: "Apple M4 Pro", utilization: 0.12)]),
        diskActivity: DiskActivityReading(readBytesPerSecond: 2_000_000, writeBytesPerSecond: 500_000, deviceCount: 1)
    )
}

struct WidgetKindTests {
    @Test func theKeptWidgetsAreSlowChangingOnesWithUniqueIds() {
        #expect(WidgetKind.allCases == [.batteryHealth, .storage, .device])
        let ids = WidgetKind.allCases.map(\.widgetID)
        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { $0.hasPrefix("dev.asger.LivVitals.widget.") })
        #expect(ids.allSatisfy { !$0.hasPrefix("dev.asger.DeviceMonitor") })
        // The instantaneous readings are menu bar indicators, not widgets.
        for dropped in ["cpu", "memory", "gpu", "disk", "diskActivity", "network"] {
            #expect(WidgetKind(rawValue: dropped) == nil)
        }
    }

    /// WidgetKit rejects formatted text in the metadata, so every title and summary is a plain literal.
    @Test func metadataIsPlainTextWithoutPlaceholders() {
        for kind in WidgetKind.allCases {
            #expect(!kind.title.isEmpty)
            #expect(!kind.summary.isEmpty)
            #expect(!kind.title.contains("%") && !kind.summary.contains("%") && !kind.summary.contains("\\("))
            #expect(!kind.symbol.isEmpty)
        }
    }

    @Test func theRefreshIsFifteenMinutesAway() {
        let now = Date(timeIntervalSince1970: 0)
        #expect(WidgetSchedule.nextRefresh(after: now) == now.addingTimeInterval(900))
    }

    @Test func onlyStorageSharesAnIndicatorMetric() {
        #expect(WidgetKind.storage.metric == .disk)
        #expect(WidgetKind.batteryHealth.metric == nil)
        #expect(WidgetKind.device.metric == nil)
    }
}

/// Builds the real WidgetKit configurations, so metadata WidgetKit would reject is caught here and not on the desktop.
struct WidgetConfigurationTests {
    @Test @MainActor func everyDefinitionBuildsItsConfiguration() {
        _ = LivBatteryHealthWidget().body
        _ = LivStorageWidget().body
        _ = LivDeviceWidget().body
        for kind in WidgetKind.allCases { _ = LivWidgetDefinition.configuration(for: kind) }
    }
}

@MainActor
struct WidgetFaceTests {
    private func rendersSomething(_ kind: WidgetKind, _ entry: LivWidgetEntry) -> Bool {
        let renderer = ImageRenderer(content: WidgetFace(kind: kind, entry: entry).frame(width: 329, height: 155))
        renderer.scale = 1
        return renderer.nsImage != nil
    }

    @Test func everyFaceRendersWithAndWithoutAReading() {
        for kind in WidgetKind.allCases {
            #expect(rendersSomething(kind, LivWidgetEntry(date: .now, snapshot: snapshot(), device: device)))
            #expect(rendersSomething(kind, LivWidgetEntry(date: .now, snapshot: nil, device: device)))
        }
    }

    @Test func aMacWithoutABatteryStillDrawsTheBatteryFace() {
        let entry = LivWidgetEntry(date: .now, snapshot: snapshot(battery: nil), device: device)
        #expect(rendersSomething(.batteryHealth, entry))
    }

    @Test func facesReadTheirNumbersAsOneSentence() {
        let entry = LivWidgetEntry(date: .now, snapshot: snapshot(), device: device)
        #expect(WidgetFace(kind: .batteryHealth, entry: entry).spoken
            == "Battery health, 100% maximum capacity, 104 cycles, charge 66%, on battery")
        #expect(WidgetFace(kind: .storage, entry: entry).spoken
            == "Storage, 310 gigabytes free of 494, 37 percent used")
        #expect(WidgetFace(kind: .device, entry: entry).spoken == "Device, macOS 27.0.1, Apple M4 Pro, up 3 d 4 h")
    }

    @Test func aMissingReadingIsSpokenAsNotAvailableNeverAsZero() {
        let entry = LivWidgetEntry(date: .now, snapshot: nil, device: device)
        #expect(WidgetFace(kind: .storage, entry: entry).spoken == "Storage, not available")
        #expect(WidgetFace(kind: .batteryHealth, entry: entry).spoken == "Battery health, not available")
        let noBattery = LivWidgetEntry(date: .now, snapshot: snapshot(battery: nil), device: device)
        #expect(WidgetFace(kind: .batteryHealth, entry: noBattery).spoken == "Battery health, not available")
    }

    @Test func theBatteryStateNamesChargingFullHeldAndRunningDown() {
        func state(level: Double, charging: Bool, ac: Bool) -> String {
            WidgetFace.batteryState(BatteryReading(level: level, isCharging: charging, isOnACPower: ac, cycleCount: 1, health: 1))
        }
        #expect(state(level: 0.5, charging: true, ac: true) == "Charging")
        #expect(state(level: 1, charging: false, ac: true) == "Fully charged")
        #expect(state(level: 0.8, charging: false, ac: true) == "On power, not charging")
        #expect(state(level: 0.5, charging: false, ac: false) == "On battery")
    }

    @Test func storageCountsDecimalGigabytes() {
        #expect(WidgetFace.gigabytes(310_000_000_000) == 310)
        #expect(WidgetFace.gigabytes(494_400_000_000) == 494)
    }
}

/// A fake in place of `WidgetCenter`: the tests never reach the real desktop.
private struct FakeInstallations: WidgetInstallationReporting {
    var kinds: Set<String>?
    func installedKinds() async -> Set<String>? { kinds }
    func reloadAll() {}
}

struct WidgetPlacementTests {
    @Test func aWidgetIsAddedWhenMacOSListsItsKind() {
        let installed: Set<String> = [WidgetKind.storage.widgetID, "dev.asger.SomeoneElse.widget"]
        #expect(WidgetPlacement.of(.storage, installed: installed) == .added)
        #expect(WidgetPlacement.of(.device, installed: installed) == .notAdded)
        #expect(WidgetPlacement.of(.device, installed: []) == .notAdded)
    }

    @Test func noAnswerIsUnknownNeverNotAdded() {
        #expect(WidgetPlacement.of(.storage, installed: nil) == .unknown)
    }

    @Test func theUnavailableReporterSaysNothing() async {
        #expect(await UnavailableWidgetInstallations().installedKinds() == nil)
    }

    @Test func aFakeReporterAnswersThroughTheProtocol() async {
        let reporter: any WidgetInstallationReporting = FakeInstallations(kinds: [WidgetKind.batteryHealth.widgetID])
        let kinds = await reporter.installedKinds()
        #expect(WidgetPlacement.of(.batteryHealth, installed: kinds) == .added)
    }
}

struct DeviceInfoTests {
    static let uptimeCases: [(Double, String)] = {
        var cases: [(Double, String)] = []
        cases.append((0, "0 min"))
        cases.append((59, "0 min"))
        cases.append((7 * 60, "7 min"))
        cases.append((5 * 3_600 + 12 * 60, "5 h 12 min"))
        cases.append((3 * 86_400 + 4 * 3_600, "3 d 4 h"))
        cases.append((-10, "0 min"))
        cases.append((Double.nan, "0 min"))
        return cases
    }()

    @Test(arguments: DeviceInfoTests.uptimeCases)
    func uptimeIsShownInTheTwoLargestUnits(seconds: Double, expected: String) {
        #expect(DeviceInfo.uptimeText(seconds) == expected)
    }

    @Test func theBootDateIsUptimeBeforeNowAndTheNameOfTheComputerIsNeverRead() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let info = DeviceInfo.read(now: now)
        #expect(info.bootDate == now.addingTimeInterval(-info.uptime))
        #expect(!info.macOSVersion.isEmpty)
        // The Device widget sits on the desktop, so it carries the chip and the OS, never the computer's name.
        let labels = Mirror(reflecting: info).children.compactMap(\.label)
        #expect(!labels.contains("name") && !labels.contains("hostName"))
    }
}

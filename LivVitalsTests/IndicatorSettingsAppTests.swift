import Foundation
import LivCore
import Observation
import os
import Testing
@testable import LivVitals

@MainActor
struct IndicatorSettingsAppTests {
    private func makeSettings(_ tmp: TemporaryDirectory) throws -> (AppSettings, SettingsStore) {
        let home = tmp.path("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let store = SettingsStore(fileURL: tmp.path("Support/settings.json"), home: home)
        return (AppSettings(store: store, home: home, saveDelay: .milliseconds(10)), store)
    }

    @Test func everyIndicatorStartsOffAndTheMenuBarHasOnlyTheHealthIcon() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            #expect(settings.indicators.count == 7)
            #expect(settings.enabledIndicators.isEmpty)
            #expect(settings.hasMenuBarContent == settings.showMenuBarExtra)
        }
    }

    @Test func anIndicatorKeepsTheMenuBarAliveEvenWithoutTheHealthIcon() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            settings.showMenuBarExtra = false
            #expect(!settings.hasMenuBarContent)
            settings.updateIndicator(.network) { $0.enabled = true }
            #expect(settings.hasMenuBarContent)
            #expect(settings.enabledIndicators.map(\.metric) == [.network])
        }
    }

    @Test func changesAreSavedAndSurviveARestart() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, store) = try makeSettings(tmp)
            settings.updateIndicator(.cpu) { $0.enabled = true; $0.style = .gauge; $0.tint = .teal; $0.showLabel = false }
            settings.indicatorRefresh = 5
            #expect(await waitUntil { store.load().indicatorRefresh == 5 })
            let saved = store.load().indicators.first { $0.metric == .cpu }
            #expect(saved == IndicatorSetting(metric: .cpu, enabled: true, style: .gauge, tint: .teal, showLabel: false))
        }
    }

    @Test func aStyleTheMetricDoesNotOfferIsIgnored() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            settings.updateIndicator(.network) { $0.style = .gauge }
            #expect(settings.indicator(.network).style == .speed)
            settings.updateIndicator(.memory) { $0.style = .speed }
            #expect(settings.indicator(.memory).style == .number)
        }
    }

    @Test func settingTheSameValueSavesNothing() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            settings.updateIndicator(.cpu) { $0.enabled = false }
            settings.indicatorRefresh = settings.indicatorRefresh
            try? await Task.sleep(for: .milliseconds(150))
            #expect(!FileManager.default.fileExists(atPath: tmp.path("Support/settings.json").path))
        }
    }

    @Test func resetPutsTheIndicatorsBackOff() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            settings.updateIndicator(.gpu) { $0.enabled = true }
            settings.indicatorRefresh = 10
            settings.resetToDefaults()
            #expect(settings.enabledIndicators.isEmpty)
            #expect(settings.indicatorRefresh == 2)
        }
    }

    /// The menu bar items write back the value they just read. If that notified observers, every write would redraw the
    /// item, which would write again: the 100 % CPU loop found while measuring 10.E.
    @Test func writingBackTheSameValueDoesNotNotifyObservers() async throws {
        try await TemporaryDirectory.use { tmp in
            let (settings, _) = try makeSettings(tmp)
            let notified = OSAllocatedUnfairLock(initialState: false)
            withObservationTracking { _ = settings.indicators } onChange: { notified.withLock { $0 = true } }
            settings.updateIndicator(.cpu) { $0.enabled = false }
            #expect(!notified.withLock { $0 })
            settings.updateIndicator(.cpu) { $0.enabled = true }
            #expect(notified.withLock { $0 })
        }
    }

    /// `-LivIndicators` (probes and snapshots) forces indicators on for one launch. It once leaked into the real
    /// settings.json when something else was saved; the override must never reach the file.
    @Test func theLaunchOverrideIsNeverSaved() async throws {
        try await TemporaryDirectory.use { tmp in
            let home = tmp.path("home")
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let store = SettingsStore(fileURL: tmp.path("Support/settings.json"), home: home)
            let settings = AppSettings(store: store, home: home, saveDelay: .milliseconds(10), launchIndicators: "cpu,network")
            #expect(settings.enabledIndicators.map(\.metric) == [.cpu, .network])

            settings.moveToTrash = false
            #expect(await waitUntil { !store.load().moveToTrash })
            #expect(store.load().indicators.allSatisfy { !$0.enabled })
        }
    }
}

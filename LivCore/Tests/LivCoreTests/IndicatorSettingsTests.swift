import Foundation
import Testing
@testable import LivCore

/// Settings schema 4 (Stage 10.D): the menu bar indicators and their refresh interval.
struct IndicatorSettingsTests {
    private func makeStore(_ tmp: TemporaryDirectory) throws -> (store: SettingsStore, file: URL, home: URL) {
        let home = try tmp.directory("home")
        let file = tmp.path("Support/LivVitals/settings.json")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        return (SettingsStore(fileURL: file, home: home), file, home)
    }

    @Test func defaultsHaveAllEightMetricsOffInStandardOrder() {
        let defaults = IndicatorSetting.defaults
        #expect(defaults.map(\.metric) == MetricKind.allCases)
        #expect(defaults.allSatisfy { !$0.enabled })
        #expect(defaults.allSatisfy { $0.style == $0.metric.defaultStyle })
        #expect(Settings.defaults(home: URL(filePath: "/Users/example")).indicatorRefresh == 2)
    }

    @Test func anOlderListWithoutTemperatureDecodesWithItOff() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, _) = try makeStore(tmp)
            let json = #"{"schemaVersion":4,"indicators":[{"metric":"cpu","enabled":true},{"metric":"temperature","enabled":true,"style":"gauge"}]}"#
            try Data(json.utf8).write(to: file)
            let indicators = store.load().indicators
            #expect(indicators.first { $0.metric == .cpu }?.enabled == true)
            let temperature = try #require(indicators.first { $0.metric == .temperature })
            #expect(temperature.style == .number)
            let withoutIt = IndicatorSetting.normalized([IndicatorSetting(metric: .cpu, enabled: true)])
            #expect(withoutIt.first { $0.metric == .temperature }?.enabled == false)
        }
    }

    @Test func theTemperatureOptionDefaultsOnForCpuAndGpuAndOlderFilesKeepWorking() throws {
        let old = try JSONDecoder().decode(IndicatorSetting.self, from: Data(#"{"metric":"gpu","enabled":true}"#.utf8))
        #expect(old.showTemperature)
        #expect(old.wantsTemperature)
        let off = try JSONDecoder().decode(IndicatorSetting.self, from: Data(#"{"metric":"cpu","enabled":true,"showTemperature":false}"#.utf8))
        #expect(!off.wantsTemperature)
        #expect(!IndicatorSetting(metric: .cpu).wantsTemperature)
        #expect(!IndicatorSetting(metric: .memory, enabled: true).wantsTemperature)
    }

    @Test(arguments: [1, 2, 3])
    func filesFromEarlierSchemasLoadWithTheIndicatorsOff(version: Int) async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, _) = try makeStore(tmp)
            try Data(#"{"schemaVersion":\#(version),"dryRun":true,"showMenuBarExtra":false}"#.utf8).write(to: file)
            let settings = store.load()
            #expect(settings.dryRun)
            #expect(!settings.showMenuBarExtra)
            #expect(settings.indicators == IndicatorSetting.defaults)
            #expect(settings.indicatorRefresh == 2)
        }
    }

    @Test func indicatorsRoundTrip() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, _, home) = try makeStore(tmp)
            var settings = Settings.defaults(home: home)
            settings.indicators[0] = IndicatorSetting(metric: .cpu, enabled: true, style: .gauge, tint: .teal, showLabel: false, showIcon: true)
            settings.indicators[5].enabled = true
            settings.indicatorRefresh = 5
            try store.save(settings)
            let loaded = store.load()
            #expect(loaded == settings)
            #expect(loaded.schemaVersion == 4)
        }
    }

    @Test func aStyleThatTheMetricDoesNotOfferFallsBackToItsDefault() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, _) = try makeStore(tmp)
            // A gauge for the network and a speed for memory are not offered.
            let json = #"""
            {"schemaVersion":4,"indicators":[
              {"metric":"network","enabled":true,"style":"gauge"},
              {"metric":"memory","enabled":true,"style":"speed","tint":"nonsense"}
            ]}
            """#
            try Data(json.utf8).write(to: file)
            let indicators = store.load().indicators
            #expect(indicators.count == 8)
            let network = try #require(indicators.first { $0.metric == .network })
            #expect(network.enabled)
            #expect(network.style == .speed)
            let memory = try #require(indicators.first { $0.metric == .memory })
            #expect(memory.style == .number)
            #expect(memory.tint == .system)
        }
    }

    @Test func missingDuplicateAndUnknownMetricsAreNormalized() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, _) = try makeStore(tmp)
            let json = #"{"schemaVersion":4,"indicators":[{"metric":"gpu","enabled":true},{"metric":"gpu","enabled":false},{"metric":"fans","enabled":true}]}"#
            try Data(json.utf8).write(to: file)
            let indicators = store.load().indicators
            #expect(indicators.map(\.metric) == MetricKind.allCases)
            #expect(indicators.first { $0.metric == .gpu }?.enabled == true)
        }
    }

    @Test(arguments: [0, 4, 7, 60, -1])
    func aRefreshIntervalOutsideTheChoicesGoesBackToTheDefault(seconds: Int) async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, _) = try makeStore(tmp)
            try Data(#"{"schemaVersion":4,"indicatorRefresh":\#(seconds)}"#.utf8).write(to: file)
            #expect(store.load().indicatorRefresh == 2)
        }
    }

    @Test func aFileFromANewerVersionIsStillIgnored() async throws {
        try await TemporaryDirectory.use { tmp in
            let (store, file, home) = try makeStore(tmp)
            try Data(#"{"schemaVersion":6,"indicatorRefresh":10}"#.utf8).write(to: file)
            #expect(store.load() == Settings.defaults(home: home))
        }
    }
}

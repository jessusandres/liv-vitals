import Foundation
import LivCore
import Testing
@testable import LivVitals

@MainActor
struct MonitorModelTests {
    private func makeModel(_ metrics: FakeMetrics = FakeMetrics()) -> (MonitorModel, FakeMetrics) {
        (MonitorModel(service: metrics), metrics)
    }

    private func nettop(_ lines: String) -> CommandResult { CommandResult(status: 0, output: ",bytes_in,bytes_out,\n" + lines) }

    @Test func topAppsSamplingGivesRatesAndStopsWhenCancelled() async {
        let commands = FakeCommands(sequences: ["/usr/bin/nettop": [nettop("a.1,1000,0,\n"), nettop("a.1,3000,500,\n")]])
        let model = MonitorModel(service: FakeMetrics(), commands: commands)
        model.networkAppsInterval = .milliseconds(20)
        let task = Task { await model.sampleNetworkApps() }
        #expect(await waitUntil { model.networkApps?.first?.name == "a" })
        #expect(commands.calls.first == "/usr/bin/nettop -P -L 1 -n -x -J bytes_in,bytes_out")
        task.cancel()
        await task.value
        #expect(model.networkApps == nil)
        let calls = commands.calls.count
        try? await Task.sleep(for: .milliseconds(100))
        #expect(commands.calls.count == calls)
    }

    @Test func aFailingNettopSetsTheFailedFlag() async {
        let commands = FakeCommands(throwing: ["/usr/bin/nettop"])
        let model = MonitorModel(service: FakeMetrics(), commands: commands)
        model.networkAppsInterval = .milliseconds(20)
        let task = Task { await model.sampleNetworkApps() }
        #expect(await waitUntil { model.networkAppsFailed })
        task.cancel()
        await task.value
    }

    @Test func nothingIsSampledUntilSomeoneWatches() {
        let (model, metrics) = makeModel()
        #expect(!model.isSampling)
        #expect(metrics.started == 0)
    }

    @Test func twoWatchersShareOneSamplerAndTheLastOneToLeaveStopsIt() async {
        let (model, metrics) = makeModel()
        model.start()
        model.start()
        #expect(metrics.started == 1)

        model.stop()
        #expect(model.isSampling)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(metrics.terminated == 0)

        model.stop()
        #expect(!model.isSampling)
        #expect(await waitUntil { metrics.terminated == 1 })
    }

    @Test func watchingAgainAfterEveryoneLeftOpensAFreshStream() async {
        let (model, metrics) = makeModel()
        model.start()
        model.stop()
        model.start()
        #expect(metrics.started == 2)
        model.stop()
    }

    @Test func extraStopsDoNotUnderflowTheWatcherCount() {
        let (model, metrics) = makeModel()
        model.stop()
        model.stop()
        model.start()
        #expect(metrics.started == 1)
        #expect(model.isSampling)
        model.stop()
        #expect(!model.isSampling)
    }

    @Test func snapshotsUpdateTheCurrentValues() async {
        let (model, metrics) = makeModel()
        model.start()
        defer { model.stop() }

        let processes = [ProcessUsage(pid: 7, name: "Xcode", cpuPercent: 34, memoryBytes: 3_000_000_000)]
        metrics.send(.sample(cpu: 0.25, pressure: .warning, battery: nil, processes: processes, health: 72))
        #expect(await waitUntil { model.latest != nil })

        #expect(model.cpuNow == 25)
        #expect(model.memoryUsedGB == 8)
        #expect(model.memoryTotalGB == 16)
        #expect(model.memoryUsedFraction == 0.5)
        #expect(model.memoryPressureTitle == "Warning")
        // The breakdown uses Activity Monitor's names, and "Available" is total minus used, not free memory.
        #expect(model.memoryAppGB == 5)
        #expect(model.memoryWiredGB == 1)
        #expect(model.memoryCompressedGB == 1)
        #expect(model.memoryAvailableGB == 8)
        #expect(model.diskUsedGB == 300)
        #expect(model.diskFreeGB == 200)
        #expect(model.diskTotalGB == 500)
        #expect(model.battery == nil)
        #expect(model.processes == processes)
        #expect(model.healthScore == 72)
        #expect(model.healthTitle == "Fair")
        #expect(model.downloadText.hasSuffix("/s"))
        #expect(model.download.last?.value == 2.5)
        #expect(model.upload.last?.value == 0.5)
    }

    @Test func historyKeepsTheLastSixtySamplesWithIncreasingIDs() async {
        let (model, metrics) = makeModel()
        model.start()
        defer { model.stop() }

        for step in 0..<75 { metrics.send(.sample(cpu: Double(step) / 100)) }
        #expect(await waitUntil { model.cpu.last?.id == 75 })
        #expect(model.cpu.count == 60)
        #expect(model.cpu.first?.id == 16)
        #expect(model.cpu.last?.value == 74)
        #expect(model.download.count == 60)
    }

    @Test func valuesAreNeutralBeforeTheFirstSnapshot() {
        let (model, _) = makeModel()
        #expect(model.cpuNow == 0)
        #expect(model.processes.isEmpty)
        #expect(model.healthScore == 100)
        #expect(model.diskUsedFraction == 0)
        #expect(model.memoryTotalGB > 0)
    }

    @Test func monitorIsLabelledSimulatedOnlyForSimulatedMetrics() {
        let live = AppStore(services: .fake())
        #expect(!live.showsPreviewData(for: .monitor))
    }

    // MARK: - Menu bar indicators (Stage 10.E)

    @Test func indicatorsAloneSampleSlowlyAndWithoutProcesses() async {
        let (model, metrics) = makeModel()
        model.setIndicatorRefresh(seconds: 2)
        #expect(model.isSampling)
        #expect(metrics.requests.count == 1)
        #expect(metrics.requests[0].interval == .seconds(2))
        #expect(!metrics.requests[0].includeProcesses)

        model.setIndicatorRefresh(seconds: nil)
        #expect(!model.isSampling)
        #expect(await waitUntil { metrics.terminated == 1 })
    }

    @Test func aWatcherSwitchesToFullSamplingAndBackWhenItLeaves() {
        let (model, metrics) = makeModel()
        model.setIndicatorRefresh(seconds: 3)
        model.start()
        #expect(metrics.requests.count == 2)
        #expect(metrics.requests[1].interval == .seconds(1))
        #expect(metrics.requests[1].includeProcesses)

        model.stop()
        #expect(metrics.requests.count == 3)
        #expect(metrics.requests[2].interval == .seconds(3))
        #expect(!metrics.requests[2].includeProcesses)
        #expect(model.isSampling)

        model.setIndicatorRefresh(seconds: nil)
        #expect(!model.isSampling)
    }

    @Test func temperatureIsRequestedOnlyWhileTheIndicatorIsOn() {
        let (model, metrics) = makeModel()
        model.setIndicatorRefresh(seconds: 2)
        #expect(!metrics.requests[0].includeTemperature)

        model.setIndicatorRefresh(seconds: 2, temperature: true)
        #expect(metrics.requests.count == 2)
        #expect(metrics.requests[1].includeTemperature)

        model.setIndicatorRefresh(seconds: 2, temperature: true)
        #expect(metrics.requests.count == 2)

        model.start()
        #expect(metrics.requests[2].includeProcesses)
        #expect(metrics.requests[2].includeTemperature)
        model.stop()
        #expect(metrics.requests[3].includeTemperature)

        model.setIndicatorRefresh(seconds: 2, temperature: true, gpuTemperature: true)
        #expect(metrics.requests.count == 5)
        #expect(metrics.requests[4].includeGPUTemperature)
        model.setIndicatorRefresh(seconds: 2, temperature: false)
        #expect(metrics.requests.count == 6)
        #expect(!metrics.requests[5].includeTemperature)
        model.setIndicatorRefresh(seconds: nil)
    }

    @Test func changingTheRefreshRestartsTheStreamOnlyWhenItDiffers() {
        let (model, metrics) = makeModel()
        model.setIndicatorRefresh(seconds: 2)
        model.setIndicatorRefresh(seconds: 2)
        #expect(metrics.requests.count == 1)
        model.setIndicatorRefresh(seconds: 5)
        #expect(metrics.requests.count == 2)
        model.setIndicatorRefresh(seconds: nil)
    }

    /// A stream that replaces another has no earlier reading to compare with, so its first snapshot has no rates: skipped.
    @Test func theFirstSnapshotOfAReplacementStreamIsSkipped() async {
        let (model, metrics) = makeModel()
        model.setIndicatorRefresh(seconds: 2)
        metrics.send(.sample(cpu: 0.5))
        #expect(await waitUntil { model.latest != nil })

        model.start()
        defer { model.stop(); model.setIndicatorRefresh(seconds: nil) }
        metrics.send(.sample(cpu: 0))
        metrics.send(.sample(cpu: 0.2))
        #expect(await waitUntil { model.cpuNow == 20 })
        #expect(model.cpu.count == 2)
    }

    @Test func everyMetricKeepsItsRecentValuesForTheCharts() async {
        let (model, metrics) = makeModel()
        model.start()
        defer { model.stop() }
        for step in 0..<70 { metrics.send(.sample(cpu: Double(step) / 100)) }
        #expect(await waitUntil { model.series[.cpu]?.last == 69 })
        #expect(model.series[.cpu]?.count == 60)
        #expect(model.series[.memory]?.last == 50)
        #expect(model.series[.network]?.last == 3_000_000)
        // Battery was not reported in these snapshots, so there is nothing to plot, and no invented zeros.
        #expect(model.series[.battery] == nil)
        #expect(model.series[.gpu] == nil)
    }
}

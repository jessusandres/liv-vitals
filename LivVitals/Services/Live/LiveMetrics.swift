import Foundation
import LivCore

/// Real CPU, memory, disk, network, battery and process readings. Each stream gets its own sampler, so
/// stopping one stops the `top` process it started.
nonisolated struct LiveMetrics: MetricsProviding {
    let isSimulated = false

    func snapshots(every interval: Duration, includeProcesses: Bool, includeTemperature: Bool, includeGPUTemperature: Bool) -> AsyncStream<MetricsSnapshot> {
        MetricsMonitor.snapshots(
            sampler: SystemSampler(
                processes: includeProcesses ? DefaultProcessSampler() : NullProcessSampler(),
                temperatures: includeTemperature ? SMCTemperatureSampler() : nil,
                gpuTemperature: includeGPUTemperature
            ),
            every: interval,
            includeProcesses: includeProcesses
        )
    }
}

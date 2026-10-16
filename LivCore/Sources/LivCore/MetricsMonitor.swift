import Foundation

public enum MetricsMonitor {
    /// A snapshot every `interval` for as long as the consumer keeps listening. Stopping (or cancelling) the
    /// consumer stops the sampling and calls `finish()` on the sampler.
    ///
    /// A reading that fails is skipped; the next one is tried on schedule.
    public static func snapshots(
        sampler: any MetricsSampling,
        every interval: Duration = .seconds(1),
        includeProcesses: Bool = true
    ) -> AsyncStream<MetricsSnapshot> {
        AsyncStream { continuation in
            let task = Task {
                var aggregator = MetricsAggregator()
                while !Task.isCancelled {
                    if let raw = try? sampler.read(includeProcesses: includeProcesses) {
                        continuation.yield(aggregator.ingest(raw))
                    }
                    try? await Task.sleep(for: interval)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in
                task.cancel()
                sampler.finish()
            }
        }
    }
}

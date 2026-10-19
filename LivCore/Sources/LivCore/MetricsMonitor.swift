import Foundation

public enum MetricsMonitor {
    /// A snapshot every `interval` for as long as the consumer keeps listening. Stopping (or cancelling) the
    /// consumer stops the sampling and calls `finish()` on the sampler.
    ///
    /// A reading that fails is skipped; the next one is tried on schedule.
    ///
    /// Only the newest snapshot is buffered: a consumer that falls behind skips stale readings instead of
    /// queueing them, so memory stays bounded and it always sees the freshest values.
    public static func snapshots(
        sampler: any MetricsSampling,
        every interval: Duration = .seconds(1),
        includeProcesses: Bool = true
    ) -> AsyncStream<MetricsSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
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

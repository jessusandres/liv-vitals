import Foundation

/// Reads the real machine: CPU, memory, disk, network, battery and, on request, the busiest processes.
public struct SystemSampler: MetricsSampling {
    private let processes: any ProcessSampling

    public init(processes: any ProcessSampling = DefaultProcessSampler()) {
        self.processes = processes
    }

    public func read(includeProcesses: Bool) throws -> RawMetrics {
        RawMetrics(
            date: .now,
            cpuTicks: try SystemReaders.cpuTicks(),
            memory: try SystemReaders.memory(),
            disk: try SystemReaders.disk(),
            network: try SystemReaders.network(),
            battery: SystemReaders.battery(),
            // A process list that cannot be read must not hide the rest of the numbers.
            processes: includeProcesses ? ((try? processes.sample()) ?? []) : [],
            gpu: SystemReaders.gpu(),
            diskCounters: SystemReaders.diskCounters()
        )
    }

    public func finish() {
        processes.finish()
    }
}

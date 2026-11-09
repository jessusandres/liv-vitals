import Foundation

/// Reads the real machine: CPU, memory, disk, network, battery and, on request, the busiest processes.
public struct SystemSampler: MetricsSampling {
    private let processes: any ProcessSampling
    private let temperatures: SMCTemperatureSampler?
    private let gpuTemperature: Bool

    /// `temperatures` is nil unless the temperature indicator is on, so no sensor is touched otherwise.
    public init(
        processes: any ProcessSampling = DefaultProcessSampler(),
        temperatures: SMCTemperatureSampler? = nil,
        gpuTemperature: Bool = false
    ) {
        self.processes = processes
        self.temperatures = temperatures
        self.gpuTemperature = gpuTemperature
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
            diskCounters: SystemReaders.diskCounters(),
            // A panel (processes on) also gets the GPU, the battery and the sensor list.
            temperature: temperatures?.read(detailed: includeProcesses, includeGPU: gpuTemperature),
            networkInterface: includeProcesses ? NetworkInterfaceInfo.current() : nil
        )
    }

    public func finish() {
        processes.finish()
    }
}

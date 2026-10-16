import Foundation

/// A 0...100 summary of how stressed the Mac is. Starts at 100 and subtracts three penalties:
///
/// - CPU: `(cpu% − 60) × 0.5` above 60 % busy, so at most 20.
/// - Memory: 0 at normal pressure, 15 at warning, 35 at critical. Pressure, not "used", because macOS
///   keeps memory full on purpose and only pressure says it is a problem.
/// - Disk: `(used − 85 %) × 200` above 85 % full, so at most 30.
public enum HealthScore {
    public enum Level: Sendable, Equatable {
        case good, fair, busy

        public var title: String {
            switch self {
            case .good: "Good"
            case .fair: "Fair"
            case .busy: "Busy"
            }
        }
    }

    /// - Parameters:
    ///   - cpu: 0...1, ideally averaged over a few seconds.
    ///   - diskUsedFraction: 0...1
    public static func compute(cpu: Double, memoryPressure: MemoryPressure, diskUsedFraction: Double) -> Int {
        let cpuPenalty = max(0, cpu * 100 - 60) * 0.5
        let memoryPenalty: Double = switch memoryPressure {
        case .normal: 0
        case .warning: 15
        case .critical: 35
        }
        let diskPenalty = max(0, diskUsedFraction - 0.85) * 200
        let score = (100 - cpuPenalty - memoryPenalty - diskPenalty).rounded()
        return Int(min(100, max(0, score)))
    }

    /// 80 and above is good, 60 and above fair, the rest busy.
    public static func level(for score: Int) -> Level {
        score >= 80 ? .good : score >= 60 ? .fair : .busy
    }
}

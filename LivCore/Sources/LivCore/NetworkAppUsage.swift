// SPDX-License-Identifier: GPL-3.0-or-later
// The nettop CSV parsing and the per-pid delta are adapted from the author's Vorssaint (GPL-3.0-or-later).

import Foundation

/// One app's current network rate.
public struct NetworkAppUsage: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var name: String
    public var bytesInPerSecond: Double
    public var bytesOutPerSecond: Double

    public var id: Int32 { pid }

    public init(pid: Int32, name: String, bytesInPerSecond: Double, bytesOutPerSecond: Double) {
        self.pid = pid
        self.name = name
        self.bytesInPerSecond = bytesInPerSecond
        self.bytesOutPerSecond = bytesOutPerSecond
    }
}

/// Cumulative bytes one process has moved, as `nettop` reports them.
public struct NetworkAppCounters: Sendable, Equatable {
    public var name: String
    public var bytesIn: UInt64
    public var bytesOut: UInt64

    public init(name: String, bytesIn: UInt64, bytesOut: UInt64) {
        self.name = name
        self.bytesIn = bytesIn
        self.bytesOut = bytesOut
    }
}

/// Parses `nettop -P -L 1 -n -x -J bytes_in,bytes_out`: lines like `apsd.383,1659548,579092,`.
public enum NettopParser {
    /// Counters by pid. Parsed from the right, so a name with commas or dots survives. The header, a line cut off by
    /// the output limit (it loses the trailing comma) and anything without a numeric pid are skipped.
    public static func parse(_ csv: String) -> [Int32: NetworkAppCounters] {
        var rows: [Int32: NetworkAppCounters] = [:]
        for line in csv.split(whereSeparator: \.isNewline) {
            let columns = line.split(separator: ",", omittingEmptySubsequences: false)
            guard columns.count >= 4, columns[columns.count - 1].isEmpty,
                  let bytesIn = UInt64(columns[columns.count - 3]),
                  let bytesOut = UInt64(columns[columns.count - 2])
            else { continue }
            let label = columns[0..<(columns.count - 3)].joined(separator: ",")
            guard let dot = label.lastIndex(of: "."),
                  let pid = Int32(label[label.index(after: dot)...]) else { continue }
            rows[pid] = NetworkAppCounters(name: String(label[..<dot]), bytesIn: bytesIn, bytesOut: bytesOut)
        }
        return rows
    }
}

/// Turns two cumulative `nettop` readings into per-second rates.
public struct NetworkAppRates: Sendable {
    private static let limit = 8

    private var previous: (at: ContinuousClock.Instant, counters: [Int32: NetworkAppCounters])?

    public init() {}

    /// nil on the first call, which only sets the baseline. A pid seen for the first time and a counter that went
    /// down count as no traffic. Idle apps are dropped; the busiest 8 come back, most first.
    public mutating func rates(cumulative: [Int32: NetworkAppCounters], at now: ContinuousClock.Instant) -> [NetworkAppUsage]? {
        defer { previous = (now, cumulative) }
        guard let previous else { return nil }
        let elapsed = now - previous.at
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        guard seconds > 0 else { return [] }
        let rows = cumulative.compactMap { pid, counters -> NetworkAppUsage? in
            // A pid the system gave to another process counts as a first sighting, not as its predecessor's traffic.
            guard let old = previous.counters[pid], old.name == counters.name else { return nil }
            let down = counters.bytesIn >= old.bytesIn ? Double(counters.bytesIn - old.bytesIn) / seconds : 0
            let up = counters.bytesOut >= old.bytesOut ? Double(counters.bytesOut - old.bytesOut) / seconds : 0
            guard down > 0 || up > 0 else { return nil }
            return NetworkAppUsage(pid: pid, name: counters.name, bytesInPerSecond: down, bytesOutPerSecond: up)
        }
        return Array(rows.sorted { $0.bytesInPerSecond + $0.bytesOutPerSecond > $1.bytesInPerSecond + $1.bytesOutPerSecond }.prefix(Self.limit))
    }

    public mutating func reset() { previous = nil }
}

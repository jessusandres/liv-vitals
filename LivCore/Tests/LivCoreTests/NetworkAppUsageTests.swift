import Foundation
import Testing
@testable import LivCore

struct NettopParserTests {
    @Test func parsesARealLine() {
        let rows = NettopParser.parse("apsd.383,1659548,579092,\n")
        #expect(rows == [383: NetworkAppCounters(name: "apsd", bytesIn: 1_659_548, bytesOut: 579_092)])
    }

    @Test func skipsTheHeader() {
        #expect(NettopParser.parse(",bytes_in,bytes_out,\nfoo.1,5,6,\n").keys.sorted() == [1])
    }

    @Test func keepsDotsInTheNameAndTakesThePidAfterTheLastDot() {
        let rows = NettopParser.parse("com.apple.WebKit.Networking.812,10,20,\n")
        #expect(rows[812]?.name == "com.apple.WebKit.Networking")
    }

    @Test func keepsACommaInTheName() {
        let rows = NettopParser.parse("Foo, Inc.77,10,20,\n")
        #expect(rows == [77: NetworkAppCounters(name: "Foo, Inc", bytesIn: 10, bytesOut: 20)])
    }

    @Test func skipsALineWithoutAPid() {
        #expect(NettopParser.parse("nopid,10,20,\n").isEmpty)
        #expect(NettopParser.parse("foo.bar,10,20,\n").isEmpty)
    }

    @Test func dropsATruncatedLastLine() {
        let rows = NettopParser.parse("a.1,10,20,\nb.2,30,4")
        #expect(rows.keys.sorted() == [1])
    }
}

struct NetworkAppRatesTests {
    private func counters(_ name: String, _ bytesIn: UInt64, _ bytesOut: UInt64) -> NetworkAppCounters {
        NetworkAppCounters(name: name, bytesIn: bytesIn, bytesOut: bytesOut)
    }

    private let t0 = ContinuousClock.now

    @Test func theFirstCallOnlyPrimes() {
        var tracker = NetworkAppRates()
        #expect(tracker.rates(cumulative: [1: counters("a", 100, 100)], at: t0) == nil)
    }

    @Test func dividesTheDeltaByTheElapsedTime() throws {
        var tracker = NetworkAppRates()
        _ = tracker.rates(cumulative: [1: counters("a", 1_000, 100)], at: t0)
        let rowsRaw = tracker.rates(cumulative: [1: counters("a", 5_000, 300)], at: t0 + .seconds(2))
        let rows = try #require(rowsRaw)
        #expect(rows == [NetworkAppUsage(pid: 1, name: "a", bytesInPerSecond: 2_000, bytesOutPerSecond: 100)])
    }

    @Test func aNewPidCountsAsNoTrafficUntilItIsSeenTwice() throws {
        var tracker = NetworkAppRates()
        _ = tracker.rates(cumulative: [:], at: t0)
        let firstRaw = tracker.rates(cumulative: [2: counters("b", 9_000, 9_000)], at: t0 + .seconds(1))
        let first = try #require(firstRaw)
        #expect(first.isEmpty)
        let secondRaw = tracker.rates(cumulative: [2: counters("b", 9_500, 9_000)], at: t0 + .seconds(2))
        let second = try #require(secondRaw)
        #expect(second.map(\.bytesInPerSecond) == [500])
    }

    @Test func aReusedPidUnderAnotherNameStartsOver() throws {
        var tracker = NetworkAppRates()
        _ = tracker.rates(cumulative: [7: counters("old", 100, 100)], at: t0)
        let rowsRaw = tracker.rates(cumulative: [7: counters("new", 900_000, 100)], at: t0 + .seconds(1))
        let rows = try #require(rowsRaw)
        #expect(rows.isEmpty)
    }

    @Test func anExitedPidDisappears() throws {
        var tracker = NetworkAppRates()
        _ = tracker.rates(cumulative: [1: counters("a", 0, 0)], at: t0)
        let rowsRaw = tracker.rates(cumulative: [:], at: t0 + .seconds(1))
        let rows = try #require(rowsRaw)
        #expect(rows.isEmpty)
    }

    @Test func aCounterResetCountsAsZero() throws {
        var tracker = NetworkAppRates()
        _ = tracker.rates(cumulative: [1: counters("a", 9_000, 9_000)], at: t0)
        let rowsRaw = tracker.rates(cumulative: [1: counters("a", 10, 9_100)], at: t0 + .seconds(1))
        let rows = try #require(rowsRaw)
        #expect(rows.map(\.bytesInPerSecond) == [0])
        #expect(rows.map(\.bytesOutPerSecond) == [100])
    }

    @Test func sortsByTotalAndKeepsEight() throws {
        var tracker = NetworkAppRates()
        let before = Dictionary(uniqueKeysWithValues: (1...10).map { (Int32($0), counters("p\($0)", 0, 0)) })
        _ = tracker.rates(cumulative: before, at: t0)
        let after = Dictionary(uniqueKeysWithValues: (1...10).map { (Int32($0), counters("p\($0)", UInt64($0) * 100, 0)) })
        let rowsRaw = tracker.rates(cumulative: after, at: t0 + .seconds(1))
        let rows = try #require(rowsRaw)
        #expect(rows.count == 8)
        #expect(rows.map(\.pid) == [10, 9, 8, 7, 6, 5, 4, 3])
    }

    @Test func resetForgetsTheBaseline() {
        var tracker = NetworkAppRates()
        _ = tracker.rates(cumulative: [1: counters("a", 0, 0)], at: t0)
        tracker.reset()
        #expect(tracker.rates(cumulative: [1: counters("a", 5, 5)], at: t0 + .seconds(1)) == nil)
    }

    /// Hardware probe: runs the real nettop twice and prints the top 3. Tolerates failure (no nettop, sandbox).
    @Test func liveProbe() async throws {
        func sample() throws -> [Int32: NetworkAppCounters] {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/nettop")
            process.arguments = ["-P", "-L", "1", "-n", "-x", "-J", "bytes_in,bytes_out"]
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return NettopParser.parse(String(decoding: data, as: UTF8.self))
        }
        guard let first = try? sample() else { return }
        var tracker = NetworkAppRates()
        _ = tracker.rates(cumulative: first, at: .now)
        try await Task.sleep(for: .seconds(1))
        guard let second = try? sample(), let rows = tracker.rates(cumulative: second, at: .now) else { return }
        print("PROBE parsed \(second.count) processes; top 3:")
        for row in rows.prefix(3) {
            print("PROBE \(row.name) (\(row.pid)) down \(IndicatorFormatter.rate(row.bytesInPerSecond)) up \(IndicatorFormatter.rate(row.bytesOutPerSecond))")
        }
    }
}

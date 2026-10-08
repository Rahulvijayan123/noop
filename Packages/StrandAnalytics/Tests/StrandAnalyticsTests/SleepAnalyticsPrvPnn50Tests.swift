import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// pNN50 in the PRV diagnostics group (spec-02 §1, docs/spec-02/CONTRACT.md §4.1): the SD1/SD2 pair set
// exactly (original timestamp/seq/ord/source adjacency AND cleaner contiguity), pooled 100·ΣNN50/Σpairs
// with its numerator and denominator, null with SD1's reason when no window qualifies.
final class SleepAnalyticsPrvPnn50Tests: XCTestCase {

    private let t0 = 1_789_000_000
    private var start: Int { t0 - t0 % 300 }

    private func input(end: Int, beats: [RRInterval]) -> SleepAnalyticsInput {
        SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-test-\(start)", start: start, end: end,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stages: [StageSegment(start: start, end: end, stage: "light")])],
            timezoneId: "Etc/UTC",
            hr: (start..<end).map { HRSample(ts: $0, bpm: 58) },
            gravity: [], skinTemp: [], beats: beats, deviceFamily: .whoop5,
            stageSourceVersion: "s", inputRevision: 1)
    }

    private func group(end: Int, beats: [RRInterval],
                       config: SleepAnalyticsConfig = .v1) -> SleepAnalyticsPrvDiagnosticsGroup {
        let i = input(end: end, beats: beats)
        return SleepAnalyticsV1.prvGroup(timeline: SleepAnalyticsV1.normalize(input: i, config: .v1),
                                         input: i, config: config)
    }

    /// One beat per second from `from` (offset into the window), values from `rr(k)`.
    private func beats(count: Int, from: Int = 0, ordBase: Int = 0, _ rr: (Int) -> Int) -> [RRInterval] {
        (0..<count).map { k in
            RRInterval(ts: start + from + k, rrMs: rr(k), srcChannel: nil, ord: ordBase + k, seq: ordBase + k)
        }
    }

    func testHandComputedPooledPnn50() throws {
        // Cycle 1000, 1060, 1000, 1020, 1000: successive differences +60, −60, +20, −20, 0.
        // Pairs i = 1…271 with i % 5 ∈ {1, 2} exceed 50 ms: 55 + 54 = 109 of 271.
        let cycle = [1000, 1060, 1000, 1020, 1000]
        let series = beats(count: 272) { cycle[$0 % 5] }
        let g = group(end: start + 300, beats: series)
        XCTAssertEqual(g.eligibleWindowCount.value, 1)
        XCTAssertEqual(g.pnn50PairCount?.value, 271)
        XCTAssertEqual(g.nn50Count?.value, 109)
        XCTAssertEqual(try XCTUnwrap(g.nightlyPnn50Pct?.value), 100.0 * 109.0 / 271.0, accuracy: 1e-12)
        XCTAssertEqual(g.nightlyPnn50Pct?.unit, "%")
        XCTAssertEqual(g.nightlyPnn50Pct?.status, .available)
        XCTAssertEqual(g.pnn50Method, "pnn50GapAware_original_adjacency_v1")
        XCTAssertEqual(g.windows.first?.nn50Count, 109)
        XCTAssertEqual(try XCTUnwrap(g.windows.first?.pnn50Pct), 100.0 * 109.0 / 271.0, accuracy: 1e-12)
        // The denominator IS the SD1/SD2 pair count.
        XCTAssertEqual(g.pnn50PairCount?.value, g.validPairs.value)
        XCTAssertEqual(g.windows.first?.pairs, 271)
        // Independent oracle: plain successive differences over the gapless series.
        var oracle = 0
        for k in 1..<series.count where abs(series[k].rrMs - series[k - 1].rrMs) > 50 { oracle += 1 }
        XCTAssertEqual(oracle, 109)
    }

    func testPooledProportionIsNotAMeanOfWindowPercentages() throws {
        // Window 1: 300 beats alternating 900/1000 (every pair |Δ| = 100 → 100%); window 2: 272 beats
        // at a constant 1000 ms (0%). The pair straddling the window boundary belongs to neither.
        let w1 = beats(count: 300) { $0 % 2 == 0 ? 900 : 1000 }
        let w2 = beats(count: 272, from: 300, ordBase: 300) { _ in 1000 }
        let g = group(end: start + 600, beats: w1 + w2)
        XCTAssertEqual(g.eligibleWindowCount.value, 2)
        XCTAssertEqual(g.windows.map(\.nn50Count), [299, 0])
        XCTAssertEqual(g.pnn50PairCount?.value, 299 + 271)
        XCTAssertEqual(g.nn50Count?.value, 299)
        XCTAssertEqual(try XCTUnwrap(g.nightlyPnn50Pct?.value), 100.0 * 299.0 / 570.0, accuracy: 1e-12)
        XCTAssertNotEqual(try XCTUnwrap(g.nightlyPnn50Pct?.value), 50.0, accuracy: 1)
    }

    func testWallClockGapPairIsExcluded() throws {
        // 150 beats at 1000 ms, a 3-second hole, then 147 beats at 1100 ms. Only the pair across the
        // hole differs by > 50 ms; it is not an original adjacency, so NN50 stays 0.
        let before = beats(count: 150) { _ in 1000 }
        let after = beats(count: 147, from: 153, ordBase: 150) { _ in 1100 }
        let g = group(end: start + 300, beats: before + after)
        XCTAssertEqual(g.eligibleWindowCount.value, 1)
        XCTAssertEqual(g.pnn50PairCount?.value, 149 + 146)
        XCTAssertEqual(g.nn50Count?.value, 0)
        XCTAssertEqual(try XCTUnwrap(g.nightlyPnn50Pct?.value), 0, accuracy: 0)
        XCTAssertEqual(g.nightlyPnn50Pct?.status, .available, "a genuine zero with qualifying pairs")
    }

    func testRemovedBeatDoesNotSpliceItsNeighboursIntoAPair() throws {
        // 1000 ms before, one 400 ms ectopic (Malik-rejected), 1100 ms after: the spliced neighbours
        // (1000 → 1100) would be an NN50 pair; the gap-aware mask excludes it.
        let series = beats(count: 272) { k in k < 130 ? 1000 : (k == 130 ? 400 : 1100) }
        let g = group(end: start + 300, beats: series)
        XCTAssertEqual(g.eligibleWindowCount.value, 1)
        XCTAssertEqual(g.nn50Count?.value, 0)
        XCTAssertEqual(g.pnn50PairCount?.value, 269)
        // The non-gap-aware statistic over the same cleaned values WOULD count the splice.
        let cleaned = HRVAnalyzer.cleanRR(series.map { Double($0.rrMs) })
        var spliced = 0
        for k in 1..<cleaned.count where abs(cleaned[k] - cleaned[k - 1]) > 50 { spliced += 1 }
        XCTAssertEqual(spliced, 1)
    }

    func testNoEligibleWindowIsNullWithSd1Reason() {
        let none = group(end: start + 300, beats: [])
        XCTAssertNil(none.nightlyPnn50Pct?.value)
        XCTAssertEqual(none.nightlyPnn50Pct?.status, .unavailable)
        XCTAssertEqual(none.nightlyPnn50Pct?.reason, none.nightlySd1Ms.reason)
        XCTAssertEqual(none.pnn50PairCount?.status, .unavailable)
        XCTAssertEqual(none.nn50Count?.reason, none.nightlySd1Ms.reason)
        XCTAssertEqual(none.pnn50Method, "pnn50GapAware_original_adjacency_v1")

        // Sparse window (150 beats): withheld by the existing gates → same reason as SD1.
        let sparse = group(end: start + 300, beats: beats(count: 151) { _ in 1000 })
        XCTAssertEqual(sparse.eligibleWindowCount.value, 0)
        XCTAssertNil(sparse.nightlyPnn50Pct?.value)
        XCTAssertEqual(sparse.nightlyPnn50Pct?.reason, sparse.nightlySd1Ms.reason)
    }

    func testSd1Sd2UnchangedByPnn50() throws {
        let series = beats(count: 272) { $0 % 2 == 0 ? 900 : 1000 }
        let g = group(end: start + 300, beats: series)
        var us: [Double] = [], vs: [Double] = []
        for k in 1..<series.count {
            let a = Double(series[k - 1].rrMs), b = Double(series[k].rrMs)
            us.append((b - a) / 2.0.squareRoot()); vs.append((a + b) / 2.0.squareRoot())
        }
        XCTAssertEqual(try XCTUnwrap(g.nightlySd1Ms.value), try XCTUnwrap(SleepAnalyticsV1.stdev(us)), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(g.nightlySd2Ms.value), try XCTUnwrap(SleepAnalyticsV1.stdev(vs)), accuracy: 1e-9)
        XCTAssertEqual(g.nightlyPnn50Pct?.value, 100)
    }

    func testDisabledConfigDisablesPnn50() {
        var config = SleepAnalyticsConfig.v1
        config.prvDiagnosticsEnabled = false
        let g = group(end: start + 300, beats: beats(count: 272) { _ in 1000 }, config: config)
        XCTAssertEqual(g.nightlyPnn50Pct?.status, .disabled)
        XCTAssertEqual(g.pnn50PairCount?.status, .disabled)
        XCTAssertEqual(g.nn50Count?.status, .disabled)
    }

    func testWireKeysRoundTrip() throws {
        let g = group(end: start + 300, beats: beats(count: 272) { $0 % 2 == 0 ? 900 : 1000 })
        let data = try JSONEncoder().encode(g)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let metric = try XCTUnwrap(json["nightly_pnn50_pct"] as? [String: Any])
        XCTAssertEqual(metric["unit"] as? String, "%")
        XCTAssertEqual(metric["value"] as? Double, 100)
        XCTAssertEqual((json["pnn50_pair_count"] as? [String: Any])?["value"] as? Int, 271)
        XCTAssertEqual((json["nn50_count"] as? [String: Any])?["value"] as? Int, 271)
        XCTAssertEqual(json["pnn50_method"] as? String, "pnn50GapAware_original_adjacency_v1")
        let window = try XCTUnwrap((json["windows"] as? [[String: Any]])?.first)
        XCTAssertEqual(window["pnn50_pct"] as? Double, 100)
        XCTAssertEqual(window["nn50_count"] as? Int, 271)
        let decoded = try JSONDecoder().decode(SleepAnalyticsPrvDiagnosticsGroup.self, from: data)
        XCTAssertEqual(decoded, g)
    }
}

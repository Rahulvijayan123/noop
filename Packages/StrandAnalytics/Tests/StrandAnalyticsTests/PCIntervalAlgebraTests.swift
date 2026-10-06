import XCTest
@testable import StrandAnalytics

/// V01: interval accounting. Expected values are worked out by hand from the fixture, not from the implementation.
final class PCIntervalAlgebraTests: XCTestCase {
    typealias PC = PhysiologyContext

    private func rec(_ s: Int, _ e: Int, _ label: String?, rev: Int = 1, unknown: Double = 0,
                     available: Int? = nil, id: String? = nil) -> PC.LabelRecord {
        PC.LabelRecord(interval: .init(s, e), label: label, unknownFraction: unknown, revision: rev,
                       availableAt: available, tieBreak: id ?? "r\(rev):\(s):\(label ?? "nil")")
    }

    private func track(_ records: [PC.LabelRecord], cutoff: Int? = nil) -> PC.ResolvedTrack {
        PC.IntervalAlgebra.resolve(records, source: .hartEpochs, heartRateDependent: false, availableBy: cutoff)
    }

    func testTransitionsGapsUnknownAndRevisionsReconcileToTheWholeInterval() {
        // [0,30) stationary r1, [30,60) walking r1 revised to stationary r2, [60,120) no record,
        // [120,150) abstained, [150,600) stationary.
        let t = track([rec(0, 30, "stationary"), rec(30, 60, "walking"), rec(30, 60, "stationary", rev: 2),
                       rec(120, 150, nil), rec(150, 600, "stationary")])
        let c = PC.IntervalAlgebra.composition(over: .init(0, 600), track: t)
        XCTAssertEqual(c.seconds(of: "stationary"), 510, accuracy: 1e-9)   // 30 + 30 (revised) + 450
        XCTAssertEqual(c.seconds(of: "walking"), 0, accuracy: 1e-9)        // superseded, not double counted
        XCTAssertEqual(c.unknownS, 30, accuracy: 1e-9)
        XCTAssertEqual(c.uncoveredS, 60, accuracy: 1e-9)                   // the gap stays unknown/uncovered
        XCTAssertEqual(c.share(of: "stationary"), 510.0 / 600.0, accuracy: 1e-12)
        XCTAssertEqual(c.resolvedOverlapS, 30)
        XCTAssertEqual(t.conflictS, 30)
        XCTAssertTrue(PC.IntervalAlgebra.reconciles(c))
        XCTAssertTrue(c.reasons.contains(PC.IntervalAlgebra.uncoveredTime))
        XCTAssertTrue(c.reasons.contains(PC.IntervalAlgebra.unknownLabelTime))
        XCTAssertTrue(c.reasons.contains(PC.IntervalAlgebra.overlappingRecordsResolved))
        XCTAssertNil(c.dominantLabel)                                      // 85% < 90% of the WHOLE interval
    }

    func testFinalSecondLabelIsNotTheIntervalLabel() {
        let t = track([rec(0, 870, "stationary"), rec(870, 900, "walking")])
        let c = PC.IntervalAlgebra.composition(over: .init(0, 900), track: t)
        XCTAssertEqual(c.share(of: "stationary"), 870.0 / 900.0, accuracy: 1e-12)
        XCTAssertEqual(c.share(of: "walking"), 30.0 / 900.0, accuracy: 1e-12)
        XCTAssertEqual(c.dominantLabel, "stationary")
        XCTAssertEqual(c.transitions, 1)
        XCTAssertFalse(c.mixed)                                            // walking 3.3% < 10% mixed floor
    }

    func testPartialOverlapAtBothEdgesCountsOnlyTheOverlap() {
        // A 2-minute respiratory support [60, 180) over 30-s epochs that straddle both edges.
        let t = track([rec(45, 75, "walking"), rec(75, 165, "stationary"), rec(165, 195, "walking")])
        let c = PC.IntervalAlgebra.composition(over: .init(60, 180), track: t)
        XCTAssertEqual(c.seconds(of: "walking"), 15 + 15, accuracy: 1e-9)
        XCTAssertEqual(c.seconds(of: "stationary"), 90, accuracy: 1e-9)
        XCTAssertEqual(c.uncoveredS, 0, accuracy: 1e-9)
        XCTAssertEqual(c.transitions, 2)
        XCTAssertTrue(c.mixed)
    }

    func testAbstainedFractionOfAnEpochIsUnknownNotLabelled() {
        let t = track([rec(0, 30, "stationary", unknown: 0.5)])
        let c = PC.IntervalAlgebra.composition(over: .init(0, 30), track: t)
        XCTAssertEqual(c.seconds(of: "stationary"), 15, accuracy: 1e-9)
        XCTAssertEqual(c.unknownS, 15, accuracy: 1e-9)
        XCTAssertTrue(PC.IntervalAlgebra.reconciles(c))
    }

    func testDuplicateRecordsAreCountedOnce() {
        let t = track([rec(0, 60, "walking", id: "a"), rec(0, 60, "walking", id: "b")])
        let c = PC.IntervalAlgebra.composition(over: .init(0, 60), track: t)
        XCTAssertEqual(c.seconds(of: "walking"), 60, accuracy: 1e-9)
        XCTAssertEqual(t.overlapS, 60)
        XCTAssertEqual(t.conflictS, 0)
    }

    func testResolutionIsIndependentOfInputOrder() {
        let records = [rec(0, 40, "walking", rev: 1, id: "a"), rec(20, 80, "stationary", rev: 3, id: "b"),
                       rec(30, 90, "running", rev: 2, id: "c"), rec(85, 120, nil, rev: 1, id: "d")]
        let a = track(records)
        let b = track(records.reversed())
        let c = track([records[2], records[0], records[3], records[1]])
        XCTAssertEqual(a, b)
        XCTAssertEqual(a, c)
        // Highest revision wins where it covers: [20,80) stationary; [80,90) running (r2 beats r1 nil); [0,20) walking.
        let comp = PC.IntervalAlgebra.composition(over: .init(0, 120), track: a)
        XCTAssertEqual(comp.seconds(of: "walking"), 20, accuracy: 1e-9)
        XCTAssertEqual(comp.seconds(of: "stationary"), 60, accuracy: 1e-9)
        XCTAssertEqual(comp.seconds(of: "running"), 10, accuracy: 1e-9)
        XCTAssertEqual(comp.unknownS, 30, accuracy: 1e-9)
        XCTAssertEqual(comp.uncoveredS, 0, accuracy: 1e-9)
    }

    func testRecordsPublishedAfterTheCutoffAreNotSeen() {
        let records = [rec(0, 60, "stationary", rev: 1, available: 100),
                       rec(0, 60, "walking", rev: 2, available: 500)]
        let live = PC.IntervalAlgebra.composition(over: .init(0, 60), track: track(records, cutoff: 200))
        XCTAssertEqual(live.seconds(of: "stationary"), 60, accuracy: 1e-9)
        let retro = PC.IntervalAlgebra.composition(over: .init(0, 60), track: track(records))
        XCTAssertEqual(retro.seconds(of: "walking"), 60, accuracy: 1e-9)
        XCTAssertEqual(track(records, cutoff: 200).droppedUnavailable, 1)
    }

    func testNoRecordsMeansUncoveredNotStationary() {
        let c = PC.IntervalAlgebra.composition(over: .init(0, 300), track: .empty())
        XCTAssertEqual(c.uncoveredS, 300, accuracy: 1e-9)
        XCTAssertTrue(c.labels.isEmpty)
        XCTAssertTrue(c.reasons.contains(PC.IntervalAlgebra.noActivityRecords))
    }

    func testPrecedingHistoryIsSeparateFromTheMeasurement() {
        let start = 10_000
        // Walking ended 400 s before the measurement; stationary since; measurement itself is stationary.
        let t = track([rec(start - 1000, start - 400, "walking"), rec(start - 400, start + 300, "stationary")])
        let p = PC.IntervalAlgebra.precedingHistory(before: start, track: t, lookbackS: 1800)
        XCTAssertEqual(p.stillRunS, 400)
        XCTAssertEqual(p.stillRunEndedBy, PC.IntervalAlgebra.stillRunMovement)
        XCTAssertEqual(p.secondsSinceSupportedActivity, 400)
        XCTAssertEqual(p.lastSupportedActivityLabel, "walking")
        XCTAssertEqual(p.coveredS, 1000)                                    // [start-1000, start) inside 1800 s
        // The measurement interval itself is fully stationary — the history is what carries the walking.
        let c = PC.IntervalAlgebra.composition(over: .init(start, start + 300), track: t)
        XCTAssertEqual(c.dominantLabel, "stationary")
    }

    func testStillRunStopsAtGapsAndAtTheLookback() {
        let start = 10_000
        let gap = track([rec(start - 900, start - 500, "stationary"), rec(start - 200, start, "stationary")])
        let g = PC.IntervalAlgebra.precedingHistory(before: start, track: gap, lookbackS: 1800)
        XCTAssertEqual(g.stillRunS, 200)
        XCTAssertEqual(g.stillRunEndedBy, PC.IntervalAlgebra.stillRunGap)
        XCTAssertNil(g.secondsSinceSupportedActivity)

        let long = track([rec(start - 5000, start, "stationary")])
        let l = PC.IntervalAlgebra.precedingHistory(before: start, track: long, lookbackS: 1800)
        XCTAssertEqual(l.stillRunS, 1800)
        XCTAssertEqual(l.stillRunEndedBy, PC.IntervalAlgebra.stillRunLookbackLimit)

        let unknown = track([rec(start - 600, start - 300, "stationary"), rec(start - 300, start, nil)])
        let u = PC.IntervalAlgebra.precedingHistory(before: start, track: unknown, lookbackS: 1800)
        XCTAssertEqual(u.stillRunS, 0)
        XCTAssertEqual(u.stillRunEndedBy, PC.IntervalAlgebra.stillRunUnknownLabel)
    }

    func testTimeSinceActivityCanExceedTheLookback() {
        let start = 20_000
        let t = track([rec(start - 9000, start - 7200, "running"), rec(start - 600, start, "stationary")])
        let p = PC.IntervalAlgebra.precedingHistory(before: start, track: t, lookbackS: 1800)
        XCTAssertEqual(p.secondsSinceSupportedActivity, 7200)
        XCTAssertEqual(p.lastSupportedActivityLabel, "running")
        XCTAssertEqual(p.stillRunS, 600)
        XCTAssertEqual(p.stillRunEndedBy, PC.IntervalAlgebra.stillRunGap)
    }

    func testCompositionAlwaysReconcilesOnRandomOverlappingRevisions() {
        var rng = SplitMix(seed: 42)
        let labels: [String?] = ["stationary", "walking", "running", "other_movement", nil]
        for _ in 0..<200 {
            var records: [PC.LabelRecord] = []
            for k in 0..<Int(rng.next() % 40 + 1) {
                let s = Int(rng.next() % 3000)
                let e = s + Int(rng.next() % 400 + 1)
                records.append(rec(s, e, labels[Int(rng.next() % 5)], rev: Int(rng.next() % 4),
                                   unknown: Double(rng.next() % 3) / 4, id: "k\(k)"))
            }
            let t = track(records)
            for (a, b) in zip(t.spans, t.spans.dropFirst()) { XCTAssertLessThanOrEqual(a.interval.end, b.interval.start) }
            let s = Int(rng.next() % 3000), e = s + Int(rng.next() % 900 + 1)
            let c = PC.IntervalAlgebra.composition(over: .init(s, e), track: t)
            XCTAssertTrue(PC.IntervalAlgebra.reconciles(c), "interval \(s)-\(e)")
            XCTAssertLessThanOrEqual(c.coveredS, Double(c.intervalS) + 1e-9)
        }
    }

    func testLocalTimeHandlesDstAndZones() {
        // 2026-03-08 is the US spring-forward day: local midnight to midnight is 23 hours.
        let day = PC.Engine.dayInterval("2026-03-08", timezoneId: "America/Los_Angeles")
        XCTAssertEqual(day.duration, 23 * 3600)
        let fall = PC.Engine.dayInterval("2026-11-01", timezoneId: "America/Los_Angeles")
        XCTAssertEqual(fall.duration, 25 * 3600)
        let t = PC.localTime(at: day.start + 3 * 3600, timezoneId: "America/Los_Angeles")
        XCTAssertEqual(t.localDay, "2026-03-08")
        XCTAssertEqual(t.secondsOfDay, 4 * 3600)                            // 03:00 UTC-wise is 04:00 local after the jump
        XCTAssertEqual(t.utcOffsetS, -7 * 3600)
    }
}

/// Deterministic generator for property tests.
struct SplitMix {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

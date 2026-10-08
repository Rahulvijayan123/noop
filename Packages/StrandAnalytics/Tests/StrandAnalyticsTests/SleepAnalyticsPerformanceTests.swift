import XCTest
import WhoopProtocol
@testable import StrandAnalytics

// SleepAnalyticsPerformanceTests — wall-clock cost of the whole `sleep_analytics_v1` compute on a
// realistic worker-shaped input (spec-02 thermal owner, docs/spec-02/notes/thermal.md
// "Performance"). The worker computes this document inside the scoring pass, which can hold the
// per-user scoring lock, so the added cost of the wider thermal span and the morning-response group
// is measured here and recorded in the notes.
//
// The input mirrors what `DayScorer.scoreAndBuildPayloads` hands the adapter: 1 Hz HR, gravity and
// skin temperature over a 24-hour read (the worker's night read is a 84 h superset bound; real data
// exists only where the strap recorded), an 8-hour main night of native 30 s stages, and ~1.1 beats/s
// of R-R intervals across the night. The test asserts only a loose upper bound (the Mac running it is
// heavily loaded); the printed `PERF` lines are the measurement.
final class SleepAnalyticsPerformanceTests: XCTestCase {

    private func realisticInput() -> SleepAnalyticsInput {
        let readStart = 1_789_000_000 - 1_789_000_000 % 60
        let readEnd = readStart + 24 * 3600
        let nightStart = readStart + 14 * 3600          // e.g. 22:00 local
        let nightEnd = nightStart + 8 * 3600            // 06:00 local
        // A deterministic stage cycle: wake prefix, then ~90 min cycles, wake suffix.
        let cycle = ["light", "light", "deep", "deep", "light", "rem"]
        var stages: [StageSegment] = []
        var t = nightStart
        stages.append(StageSegment(start: t, end: t + 600, stage: "wake")); t += 600
        var k = 0
        while t < nightEnd - 600 {
            let len = 900
            stages.append(StageSegment(start: t, end: min(t + len, nightEnd - 600), stage: cycle[k % cycle.count]))
            t += len; k += 1
        }
        stages.append(StageSegment(start: nightEnd - 600, end: nightEnd, stage: "wake"))

        var hr: [HRSample] = []; hr.reserveCapacity(readEnd - readStart)
        var gravity: [GravitySample] = []; gravity.reserveCapacity(readEnd - readStart)
        var temp: [SkinTempSample] = []; temp.reserveCapacity(readEnd - readStart)
        for ts in readStart..<readEnd {
            let phase = Double(ts - readStart) / 86_400.0 * 2 * .pi
            hr.append(HRSample(ts: ts, bpm: 60 + Int(10 * sin(phase)) + (ts % 7 == 0 ? 1 : 0)))
            let wiggle = (ts % 97 == 0) ? 0.05 : 0.0
            gravity.append(GravitySample(ts: ts, x: wiggle, y: 0, z: 1))
            temp.append(SkinTempSample(ts: ts, raw: 3300 + Int(50 * cos(phase))))
        }
        var beats: [RRInterval] = []
        var bt = Double(nightStart)
        var seq = 0
        while bt < Double(nightEnd) {
            let rr = 900 + (seq % 11) * 4
            beats.append(RRInterval(ts: Int(bt), rrMs: rr, srcChannel: nil, ord: seq % 4, seq: seq))
            bt += Double(rr) / 1000.0; seq += 1
        }
        return SleepAnalyticsInput(
            fragments: [SleepAnalyticsInput.Fragment(
                id: "sleep-perf-\(nightStart)", start: nightStart, end: nightEnd,
                sourceKind: .nativeWhoop, sourceEpochSeconds: 30,
                stageGridAnchorSeconds: nightStart, stages: stages)],
            timezoneId: "America/Los_Angeles",
            hr: hr, gravity: gravity, skinTemp: temp, beats: beats, deviceFamily: .whoop5,
            stageSourceVersion: "sleep-stager-v2-perf", inputRevision: 1)
    }

    private func milliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    func testFullNightComputeCost() {
        let input = realisticInput()
        let config = SleepAnalyticsConfig()
        let timeline = SleepAnalyticsV1.normalize(input: input, config: config)
        var full: [Double] = [], thermal: [Double] = [], morning: [Double] = []
        var document: SleepAnalyticsDocument?
        for _ in 0..<3 {
            full.append(milliseconds { document = SleepAnalyticsV1.compute(input: input, config: config) })
            thermal.append(milliseconds {
                _ = SleepAnalyticsV1.thermalGroup(timeline: timeline, input: input, config: config)
            })
            morning.append(milliseconds {
                _ = SleepAnalyticsV1.morningResponseGroup(timeline: timeline, input: input, config: config)
            })
        }
        let med: ([Double]) -> Double = { $0.sorted()[$0.count / 2] }
        print(String(format: "PERF sleep_analytics_v1 compute_ms=%.1f thermal_ms=%.1f morning_ms=%.1f "
                     + "(median of 3; hr=%d gravity=%d temp=%d beats=%d; algorithm=%@)",
                     med(full), med(thermal), med(morning),
                     input.hr.count, input.gravity.count, input.skinTemp.count, input.beats.count,
                     SleepAnalyticsV1.algorithmVersion))
        XCTAssertNotNil(document)
        // Loose sanity bound only (debug build on a loaded machine).
        XCTAssertLessThan(med(full), 120_000)
    }
}

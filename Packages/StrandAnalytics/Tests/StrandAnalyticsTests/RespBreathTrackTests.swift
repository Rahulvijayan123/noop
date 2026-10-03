import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The per-run respiratory track: a rate for a short window from breaths read inside unbroken stretches of
/// beats, where `respRateFromRR` would discard every 300 s window that holds a dropout.
///
/// Fixtures are synthetic respiratory sinus arrhythmia: beat length modulated by a sine at a known breathing
/// rate, with `ts` advancing consistently with the beats (whole seconds, several beats may share one).
final class RespBreathTrackTests: XCTestCase {
    private let t0 = 1_800_000_000

    /// `runs` are (offset, length) pairs in seconds from `t0`; beats are laid down inside each with the
    /// breathing phase continuous across the whole fixture, so a dropout removes beats and nothing else.
    private func rsa(perMinute: Double, runs: [(Int, Int)], baseMs: Double = 900, depthMs: Double = 60) -> [RRInterval] {
        var out: [RRInterval] = []
        for (offset, length) in runs {
            var t = Double(t0 + offset)
            let end = Double(t0 + offset + length)
            while t < end {
                let phase = (t - Double(t0)) * perMinute / 60.0
                let rr = baseMs + depthMs * sin(2 * Double.pi * phase)
                out.append(RRInterval(ts: Int(t), rrMs: Int(rr.rounded())))
                t += rr / 1000.0
            }
        }
        return out
    }

    func testRecoversTheBreathingRateFromAShortWindow() throws {
        let track = SleepStager.respBreathTrack(rsa(perMinute: 15, runs: [(0, 600)]))
        let estimate = try XCTUnwrap(track.estimate(from: t0 + 240, to: t0 + 360, currentFrom: t0 + 300))
        XCTAssertEqual(estimate.breathsPerMinute, 15, accuracy: 1.5)
        XCTAssertGreaterThanOrEqual(estimate.intervals, 20)
        XCTAssertEqual(estimate.coveredSeconds, 120, accuracy: 1)
    }

    func testFasterBreathingReadsHigher() throws {
        func rate(_ perMinute: Double) throws -> Double {
            let track = SleepStager.respBreathTrack(rsa(perMinute: perMinute, runs: [(0, 600)]))
            return try XCTUnwrap(track.estimate(from: t0 + 240, to: t0 + 360, currentFrom: t0 + 300)).breathsPerMinute
        }
        let slow = try rate(9), medium = try rate(14), fast = try rate(20)
        XCTAssertEqual(slow, 9, accuracy: 1.5)
        XCTAssertEqual(fast, 20, accuracy: 2.0)
        XCTAssertLessThan(slow, medium)
        XCTAssertLessThan(medium, fast)
    }

    /// The case the track exists for: 70 s of beats, 40 s of nothing, repeated. Every 300 s window of the
    /// nightly kernel holds a splice, so it has no answer; every two-minute window here holds a run.
    func testAnswersWhereTheNightlyKernelHasNoCleanWindow() throws {
        var runs: [(Int, Int)] = []
        for k in 0..<10 { runs.append((k * 110, 70)) }
        let rr = rsa(perMinute: 15, runs: runs)
        XCTAssertTrue(SleepStager.respRateFromRR(rr, start: t0, end: t0 + 1_100).isNaN,
                      "the fixture must be one the nightly kernel cannot read")

        let track = SleepStager.respBreathTrack(rr)
        var answered = 0
        for minute in 2..<17 {
            let end = t0 + minute * 60
            if let estimate = track.estimate(from: end - 120, to: end, currentFrom: end - 60) {
                answered += 1
                XCTAssertEqual(estimate.breathsPerMinute, 15, accuracy: 2.0, "minute \(minute)")
                XCTAssertLessThan(estimate.coveredSeconds, 120)
            }
        }
        XCTAssertGreaterThanOrEqual(answered, 8, "most minutes sit within 60 s of a run")
    }

    func testADropoutIsNotReadAsABreath() {
        // Flat beats then a step to a different length across a 60 s hole: stitched, the step would look
        // like one slow oscillation; split into runs, each is flat and holds no breath.
        let before = (0..<60).map { RRInterval(ts: t0 + $0, rrMs: 1_000) }
        let after = (0..<60).map { RRInterval(ts: t0 + 120 + $0, rrMs: 800) }
        let track = SleepStager.respBreathTrack(before + after)
        XCTAssertTrue(track.intervals.isEmpty)
        XCTAssertEqual(track.runs.count, 2)
    }

    func testBreathsAreStampedOnTheWallClockOfTheirOwnRun() throws {
        let track = SleepStager.respBreathTrack(rsa(perMinute: 15, runs: [(0, 90), (300, 90)]))
        XCTAssertFalse(track.intervals.isEmpty)
        for interval in track.intervals {
            let inFirst = (t0...t0 + 90).contains(interval.ts)
            let inSecond = (t0 + 300...t0 + 390).contains(interval.ts)
            XCTAssertTrue(inFirst || inSecond, "\(interval.ts - t0) is inside a hole")
        }
        XCTAssertEqual(track.intervals.sorted { $0.ts < $1.ts }, track.intervals)
    }

    func testAWindowNeedsBreathsInTheCurrentSlice() {
        let track = SleepStager.respBreathTrack(rsa(perMinute: 15, runs: [(0, 100)]))
        XCTAssertNotNil(track.estimate(from: t0 + 20, to: t0 + 100, currentFrom: t0 + 60))
        XCTAssertNil(track.estimate(from: t0 + 20, to: t0 + 200, currentFrom: t0 + 140),
                     "the beats stopped before the current slice, so the window would only repeat an older answer")
        XCTAssertNil(track.estimate(from: t0 + 300, to: t0 + 400, currentFrom: t0 + 340))
    }

    func testTooFewBreathsGiveNoRate() {
        let track = SleepStager.respBreathTrack(rsa(perMinute: 15, runs: [(0, 30)]))
        XCTAssertNil(track.estimate(from: t0, to: t0 + 30, currentFrom: t0 + 15, minIntervals: 12))
    }

    func testShortRunsAreNotRead() {
        let track = SleepStager.respBreathTrack(rsa(perMinute: 15, runs: [(0, 15)]))
        XCTAssertTrue(track.runs.isEmpty)
        XCTAssertTrue(track.intervals.isEmpty)
    }

    func testStreamsTooShortOrEmptyAreInert() {
        XCTAssertEqual(SleepStager.respBreathTrack([]), .empty)
        XCTAssertEqual(SleepStager.respBreathTrack([RRInterval(ts: t0, rrMs: 900)]), .empty)
        XCTAssertNil(RespBreathTrack.empty.estimate(from: t0, to: t0 + 60, currentFrom: t0))
        XCTAssertNil(RespBreathTrack.empty.estimate(from: t0 + 60, to: t0, currentFrom: t0))
    }

    func testOutOfRangeBeatsAreFilteredAndRowOrderDoesNotMatter() {
        var rr = rsa(perMinute: 15, runs: [(0, 300)])
        let reference = SleepStager.respBreathTrack(rr)
        rr.shuffle()
        XCTAssertEqual(SleepStager.respBreathTrack(rr).runs, reference.runs)
        let junk = rr + [RRInterval(ts: t0 + 10, rrMs: 50), RRInterval(ts: t0 + 11, rrMs: 5_000)]
        XCTAssertEqual(SleepStager.respBreathTrack(junk).runs, reference.runs)
    }

    func testALongUnbrokenStretchIsReadMinuteByMinute() throws {
        let track = SleepStager.respBreathTrack(rsa(perMinute: 13, runs: [(0, 7_200)]))
        var estimates: [Double] = []
        for minute in 2..<120 {
            let end = t0 + minute * 60
            if let estimate = track.estimate(from: end - 120, to: end, currentFrom: end - 60) {
                estimates.append(estimate.breathsPerMinute)
            }
        }
        XCTAssertGreaterThan(estimates.count, 110, "an unbroken stretch should answer almost every minute")
        XCTAssertEqual(HRVAnalyzer.median(estimates), 13, accuracy: 1.0)
    }
}

import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// D4-14: a pre-sleep window that follows exertion is flagged and never compared with, or folded into,
/// the resting pre-sleep history.
final class PreSleepRecentExertionTests: XCTestCase {
    private func samples(_ start: Int, bpm: Int, count: Int) -> [HRSample] {
        (0..<count).map { HRSample(ts: start + $0 * 60, bpm: bpm) }
    }
    private let sleep = SleepSession(start: 10_000, end: 36_000, efficiency: 0.9,
                                     stages: [], restingHR: nil, avgHRV: nil)
    private var history: [PreSleepHeartRateFeedback.HistoricalReading] {
        [60.0, 61.0, 62.0, 63.0].enumerated().map {
            PreSleepHeartRateFeedback.HistoricalReading(day: "2026-08-0\($0.offset + 1)", meanBpm: $0.element)
        }
    }
    private func evaluate(bouts: [PreSleepHeartRateFeedback.ExertionBout],
                          history: [PreSleepHeartRateFeedback.HistoricalReading]? = nil)
        -> PreSleepHeartRateFeedback.Feedback {
        PreSleepHeartRateFeedback.evaluate(
            enabled: true, sessions: [sleep], hr: samples(8_800, bpm: 78, count: 12),
            history: history ?? self.history, journalEntries: [], day: "2026-08-05",
            minimumValidSamples: 10, preSleepWindowSeconds: 1_800, exertionBouts: bouts)
    }

    /// The brief's case: a 20-min walk ending 10 min before the window starts (window 8 200-10 000).
    func testAWalkEndingTenMinutesBeforeTheWindowIsFlaggedAndNotCompared() {
        let walk = PreSleepHeartRateFeedback.ExertionBout(start: 8_200 - 600 - 1_200, end: 8_200 - 600)
        let f = evaluate(bouts: [walk])
        XCTAssertEqual(f.eligibility, .recentExertion(secondsBefore: 600))
        XCTAssertEqual(f.uncertainty, [.recentExertion(secondsBefore: 600)])
        XCTAssertNil(f.comparison, "not compared with the resting history")
        XCTAssertEqual(f.observation?.meanBpm, 78, "the observation itself is still reported")
        // Without the walk the same night is compared as before.
        XCTAssertEqual(evaluate(bouts: []).eligibility, .eligible)
        XCTAssertNotNil(evaluate(bouts: []).comparison)
    }

    func testABoutEndingLongBeforeTheWindowDoesNotFlag() {
        let old = PreSleepHeartRateFeedback.ExertionBout(start: 0, end: 8_200 - PreSleepHeartRateFeedback.recentExertionLookbackSeconds - 1)
        XCTAssertEqual(evaluate(bouts: [old]).eligibility, .eligible)
        XCTAssertEqual(PreSleepHeartRateFeedback.recentExertion(windowStartTs: 8_200, windowEndTs: 10_000,
                                                                bouts: [.init(start: 8_000, end: 9_000)]), 0,
                       "a bout overlapping the window counts as 0 s before")
    }

    /// Post-exertion history nights never enter the resting fold.
    func testPostExertionHistoryNightsAreExcludedFromTheFold() {
        var h = history
        h.append(.init(day: "2026-08-04", meanBpm: 90, recentExertion: true))   // duplicate day, flagged
        h.insert(.init(day: "2026-07-30", meanBpm: 95, recentExertion: true), at: 0)
        let f = evaluate(bouts: [], history: h)
        XCTAssertEqual(f.comparison?.baselineBpm, 61.5)
        XCTAssertEqual(f.comparison?.baselineNights, 4)
    }
}

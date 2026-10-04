import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// Locks the analyzeDay hot-path optimization (#996): the integer UTC-bounds membership check that replaced
/// the per-sample `dayString(ts, offsetSec:) == day` DateFormatter must be BYTE-IDENTICAL to it. If the two
/// ever diverge, samples get attributed to the wrong calendar day (wrong step / calorie / Effort totals), so
/// this sweeps timestamps densely across BOTH midnight edges at a range of fixed offsets — including the
/// FRACTIONAL ones (+5:30 Kolkata, +5:45 Kathmandu, −9:30 Marquesas, −3:30 Newfoundland) the whole-hour
/// Kotlin sweep leaves uncovered — and asserts the two agree at every point. Mirrors the Android
/// `AnalyticsEngineDayBoundsTest` (same anchor, same prime step, superset of its offsets) so the
/// cross-platform golden vectors stay in lockstep.
final class AnalyticsEngineDayBoundsTests: XCTestCase {

    // MARK: - Membership equivalence sweep

    func testIntegerBoundsMatchDayStringAcrossMidnightAndOffsets() {
        let anchor = 1_700_000_000  // 2023-11-14T22:13:20Z
        // UTC, the whole-hour extremes NOOP actually threads (±12/13/14 h are the real-world edges),
        // AND the fractional offsets the lane's timezone table carries (#996 review swept these too).
        let offsets = [0,
                       -4 * 3600, 5 * 3600, 13 * 3600, -12 * 3600, 14 * 3600,
                       5 * 3600 + 1800,   // +5:30 Kolkata
                       5 * 3600 + 2700,   // +5:45 Kathmandu
                       -(9 * 3600 + 1800), // −9:30 Marquesas
                       -(3 * 3600 + 1800)] // −3:30 Newfoundland
        for off in offsets {
            let day = AnalyticsEngine.dayString(anchor, offsetSec: off)
            let start = AnalyticsEngine.dayStartUtcSeconds(day)
            // ±28 h around the anchor at a prime step, so both midnight edges of `day` are crossed densely
            // and never in phase with the day grid.
            var ts = anchor - 100_800
            while ts < anchor + 100_800 {
                let viaFormatter = AnalyticsEngine.dayString(ts, offsetSec: off) == day
                let viaBounds = (ts + off) >= start && (ts + off) < start + 86_400
                XCTAssertEqual(viaFormatter, viaBounds, "ts=\(ts) off=\(off)")
                ts += 97
            }
        }
    }

    func testExactMidnightEdgesAtFractionalOffset() {
        // The two boundary seconds are where an off-by-one would hide: the local-midnight second is IN
        // the day, the next local-midnight second is OUT. +5:30 so a whole-hour bug can't pass by luck.
        let off = 5 * 3600 + 1800
        let day = "2021-06-15"
        let start = AnalyticsEngine.dayStartUtcSeconds(day)   // 2021-06-15T00:00:00Z = 1623715200
        XCTAssertEqual(start, 1_623_715_200)
        let localMidnightUtcTs = start - off                  // wall-clock 00:00 +05:30 as a UTC instant
        for (probe, expected) in [(localMidnightUtcTs, true),          // first second of the local day
                                  (localMidnightUtcTs - 1, false),     // last second of the day before
                                  (localMidnightUtcTs + 86_399, true), // last second of the local day
                                  (localMidnightUtcTs + 86_400, false)] {  // first second of the next
            XCTAssertEqual(AnalyticsEngine.dayString(probe, offsetSec: off) == day, expected, "probe=\(probe)")
            XCTAssertEqual((probe + off) >= start && (probe + off) < start + 86_400, expected, "probe=\(probe)")
        }
    }

    // MARK: - dayStartUtcSeconds

    func testDayStartUtcSecondsIsUtcMidnight() {
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("1970-01-01"), 0)
        // 1_700_000_000 is 2023-11-14T22:13:20Z, so that day's UTC midnight is 80_000 s earlier.
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("2023-11-14"), 1_699_920_000)
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("2021-06-15"), 1_623_715_200)
    }

    func testDayStartUtcSecondsRoundTripsThroughDayString() {
        // dayString(dayStartUtcSeconds(day)) == day for a spread of days (incl. a leap-year Feb 29).
        for day in ["1970-01-01", "2021-06-15", "2023-11-14", "2024-02-29", "2026-12-31"] {
            XCTAssertEqual(AnalyticsEngine.dayString(AnalyticsEngine.dayStartUtcSeconds(day)), day)
        }
    }

    func testMalformedDayFallsBackToEmptyEpochWindowNotATrap() {
        // Nil-tolerant failure mode (#996 review): a malformed `day` degrades to 0 — an empty 1970 window
        // no real sample matches — on BOTH platforms (Kotlin runCatching → 0), never a crash. Unreachable
        // in practice (`day` always comes from dayString), locked so the parity can't silently drift.
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds("not-a-day"), 0)
        XCTAssertEqual(AnalyticsEngine.dayStartUtcSeconds(""), 0)
    }

    // MARK: - Byte-identity pin: same inputs → same DailyMetric numbers

    /// The optimization's whole contract: analyzeDay over FULL streams (which the tsInDay bounds check must
    /// trim to the day) produces the IDENTICAL DailyMetric as analyzeDay over streams PRE-trimmed with the
    /// old formatter compare. Runs at a fractional offset with spill samples planted on both sides of the
    /// local day, so any membership divergence changes the step/kcal/Effort numbers and fails Equatable.
    func testAnalyzeDayByteIdenticalToFormatterPrefilteredStreams() {
        for off in [5 * 3600 + 1800, -(9 * 3600 + 1800)] {   // +5:30 and −9:30
            let day = "2021-06-15"
            let localMid = AnalyticsEngine.dayStartUtcSeconds(day) - off
            // Full calendar-day HR every 10 s with ±2 h spill into the neighbour days; varying bpm so a
            // wrongly-included/excluded sample shifts the calorie/Effort sums, not just the count.
            let dayHr = stride(from: localMid - 7_200, to: localMid + 86_400 + 7_200, by: 10)
                .map { HRSample(ts: $0, bpm: 60 + ($0 / 10) % 40) }
            // Cumulative @57 counter every minute (+7/min) with the same spill; the spill deltas must be
            // excluded from the day total by BOTH filters identically.
            var counter = 100
            let daySteps: [StepSample] = stride(from: localMid - 7_200,
                                                to: localMid + 86_400 + 7_200, by: 60).map { ts in
                counter += 7
                return StepSample(ts: ts, counter: counter & 0xFFFF)
            }
            let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

            let full = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr, daySteps: daySteps,
                                                  profile: profile, tzOffsetSeconds: off)
            // The OLD path, byte for byte: pre-trim each stream with the formatter compare.
            let preHr = dayHr.filter { AnalyticsEngine.dayString($0.ts, offsetSec: off) == day }
            let preSteps = daySteps.filter { AnalyticsEngine.dayString($0.ts, offsetSec: off) == day }
            XCTAssertLessThan(preHr.count, dayHr.count, "fixture must actually spill outside the day")
            let pre = AnalyticsEngine.analyzeDay(day: day, dayHr: preHr, daySteps: preSteps,
                                                 profile: profile, tzOffsetSeconds: off)

            XCTAssertEqual(full.daily, pre.daily, "off=\(off)")
            XCTAssertNotNil(full.daily.steps)          // the pin is vacuous if the day computed nothing
            XCTAssertNotNil(full.daily.activeKcalEst)
        }
    }


    // MARK: - The LocalDayWindows switch-over (T05/T06)

    /// Unpack a `LocalDayWindow` to whole unix seconds so the fixtures below read as plain integers.
    private func bounds(_ window: LocalDayWindow) -> (start: Int, end: Int) {
        (Int(window.start.timeIntervalSince1970), Int(window.nextStart.timeIntervalSince1970))
    }

    /// The switch-over helper's bounds are the zone-correct half-open local day: for every non-DST day
    /// the start equals the fixed-offset local midnight (byte-identical), and every instant inside the
    /// window maps to the day's own key (key and bucket agree by construction).
    func testLocalDayWindowAgreesWithDayKeyForNonDSTDays() throws {
        for (zoneName, day) in [("America/New_York", "2025-06-15"),   // EDT, far from any transition
                                ("America/New_York", "2025-01-15"),   // EST, far from any transition
                                ("Asia/Kolkata", "2025-06-15"),       // no DST at all (+5:30)
                                ("Asia/Kathmandu", "2025-06-15"),     // +5:45 fractional
                                ("UTC", "2025-06-15")] {
            let zone = TimeZone(identifier: zoneName)!
            let window = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: day, zone: zone),
                                       "\(zoneName) \(day) must exist")
            let b = bounds(window)
            let fixedStart = AnalyticsEngine.dayStartUtcSeconds(day)
                - zone.secondsFromGMT(for: window.start)
            XCTAssertEqual(b.start, fixedStart,
                           "\(zoneName) \(day) start must equal the fixed-offset local midnight")
            XCTAssertEqual(b.end - b.start, 86_400, "\(zoneName) \(day) must be 24 h")

            let helper = LocalDayWindows(timeZone: zone)
            for ts in [b.start - 1, b.start, b.start + 3_600, b.end - 1, b.end] {
                let key = helper.dayKey(for: Date(timeIntervalSince1970: TimeInterval(ts)))
                let inWindow = ts >= b.start && ts < b.end
                XCTAssertEqual(inWindow, key == day,
                               "\(zoneName) \(day): ts=\(ts) key=\(key) window=\(inWindow)")
            }
        }
    }

    /// Requirement (a) — the switch is plumbing: on a non-DST day, analyzeDay fed the
    /// LocalDayWindows-derived window is BYTE-IDENTICAL to the fixed-offset path (no dayWindow) and to
    /// the formatter pre-filter, at fractional offsets too.
    func testAnalyzeDayWithDayWindowIsByteIdenticalToFixedOffsetForNonDSTDays() throws {
        for (zoneName, day) in [("America/New_York", "2025-06-15"),
                                ("Asia/Kathmandu", "2025-06-15")] {
            let zone = TimeZone(identifier: zoneName)!
            let window = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: day, zone: zone))
            let b = bounds(window)
            let off = zone.secondsFromGMT(for: window.start)
            // Full calendar-day streams with ±2 h spill into the neighbours.
            let dayHr = stride(from: b.start - 7_200, to: b.end + 7_200, by: 10)
                .map { HRSample(ts: $0, bpm: 60 + ($0 / 10) % 40) }
            var counter = 100
            let daySteps: [StepSample] = stride(from: b.start - 7_200,
                                                to: b.end + 7_200, by: 60).map { ts in
                counter += 7
                return StepSample(ts: ts, counter: counter & 0xFFFF)
            }
            let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

            let shipped = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr, daySteps: daySteps,
                                                     profile: profile, tzOffsetSeconds: off,
                                                     dayWindow: window)
            let fixed = AnalyticsEngine.analyzeDay(day: day, dayHr: dayHr, daySteps: daySteps,
                                                   profile: profile, tzOffsetSeconds: off)
            let preHr = dayHr.filter { AnalyticsEngine.dayString($0.ts, offsetSec: off) == day }
            let preSteps = daySteps.filter { AnalyticsEngine.dayString($0.ts, offsetSec: off) == day }
            let pre = AnalyticsEngine.analyzeDay(day: day, dayHr: preHr, daySteps: preSteps,
                                                 profile: profile, tzOffsetSeconds: off)

            XCTAssertEqual(shipped.daily, fixed.daily,
                           "\(zoneName) \(day): dayWindow must equal the fixed-offset path")
            XCTAssertEqual(shipped.daily, pre.daily,
                           "\(zoneName) \(day): dayWindow must equal the formatter pre-filter")
            XCTAssertNotNil(shipped.daily.steps)
            XCTAssertNotNil(shipped.daily.activeKcalEst)
        }
    }

    /// Requirement (b) — on a DST day the shipped answer is the zone-correct one, and it may differ from
    /// the old fixed-offset answer ONLY where the old answer was wrong. Two pins:
    ///   * 2025-03-09 (23 h spring-forward): the old window ran an hour INTO 03-10 and double-counted
    ///     its first hour; the shipped window stops at the true next midnight.
    ///   * 2025-11-02 (25 h fall-back): the old window stopped an hour BEFORE the true next midnight and
    ///     dropped the day's last hour; the shipped window includes it.
    func testAnalyzeDayWithDayWindowIsTheShippedDSTAnswer() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

        // ── Spring-forward 2025-03-09: [07:00Z, 07:00Z+23h) ─────────────────────────
        do {
            let day = "2025-03-09"
            let window = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: day, zone: zone))
            let b = bounds(window)
            XCTAssertEqual(b.end - b.start, 23 * 3_600, "spring-forward day must be 23 h")
            let off = zone.secondsFromGMT(for: window.start)
            // A step counter planted every minute, spilling ±2 h beyond the TRUE day. The final hour of
            // the spill is 03-10's first hour — inside the old fixed-offset window, outside the shipped one.
            var counter = 100
            let daySteps: [StepSample] = stride(from: b.start - 7_200,
                                                to: b.end + 7_200, by: 60).map { ts in
                counter += 7
                return StepSample(ts: ts, counter: counter & 0xFFFF)
            }
            let shipped = AnalyticsEngine.analyzeDay(day: day, daySteps: daySteps, profile: profile,
                                                     tzOffsetSeconds: off, dayWindow: window)
            let old = AnalyticsEngine.analyzeDay(day: day, daySteps: daySteps, profile: profile,
                                                 tzOffsetSeconds: off)
            let trueDay = daySteps.filter { $0.ts >= b.start && $0.ts < b.end }
            let trueTotal = AnalyticsEngine.analyzeDay(day: day, daySteps: trueDay, profile: profile,
                                                       tzOffsetSeconds: off, dayWindow: window)
            XCTAssertEqual(shipped.daily.steps, trueTotal.daily.steps,
                           "shipped answer must equal the true-day-only total")
            XCTAssertEqual(shipped.daily.steps, 7 * (trueDay.count - 1),
                           "every planted tick inside the true day must count")
            XCTAssertNotEqual(shipped.daily.steps, old.daily.steps,
                              "the OLD fixed-offset window reached an hour into 03-10 and over-counted")
        }

        // ── Fall-back 2025-11-02: [04:00Z, 04:00Z+25h) ─────────────────────────────
        do {
            let day = "2025-11-02"
            let window = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: day, zone: zone))
            let b = bounds(window)
            XCTAssertEqual(b.end - b.start, 25 * 3_600, "fall-back day must be 25 h")
            let off = zone.secondsFromGMT(for: window.start)
            // A sleep session whose END falls in the day's LAST hour (23:00–00:00 EST, before the next
            // local midnight): the shipped window matches it, the old fixed-offset window did not.
            let session = SleepSession(start: b.end - 2 * 3_600, end: b.end - 1_800,
                                       efficiency: 0.9,
                                       stages: [StageSegment(start: b.end - 2 * 3_600,
                                                             end: b.end - 1_800, stage: "deep")],
                                       restingHR: 55, avgHRV: 80)
            let shipped = AnalyticsEngine.analyzeDay(day: day, profile: profile, tzOffsetSeconds: off,
                                                     dayWindow: window, providedSleep: [session])
            let old = AnalyticsEngine.analyzeDay(day: day, profile: profile, tzOffsetSeconds: off,
                                                 providedSleep: [session])
            XCTAssertEqual(shipped.sleepSessions.count, 1,
                           "the day's last hour must attribute to THIS day (zone-correct bounds)")
            XCTAssertEqual(shipped.daily.totalSleepMin, 90,
                           "90 min asleep in the last hour of the 25 h day")
            XCTAssertTrue(old.sleepSessions.isEmpty,
                          "the OLD fixed-offset window stopped an hour early and dropped this night")
        }
    }

    /// The worker and the app both derive the window from the SAME package helper, so a claim in any
    /// zone resolves the same bounds the app's scan uses. Pins the exact numbers the DST fixtures above
    /// depend on, so a time-zone database bump that moves a boundary reddens HERE rather than in a
    /// metric diff.
    func testLocalDayWindowPinsTheDSTBoundaryInstants() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let spring = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: "2025-03-09", zone: zone))
        XCTAssertEqual(Int(spring.start.timeIntervalSince1970), 1_741_496_400)   // 2025-03-09T07:00:00Z
        XCTAssertEqual(Int(spring.nextStart.timeIntervalSince1970), 1_741_579_200) // 2025-03-10T06:00:00Z
        let fall = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: "2025-11-02", zone: zone))
        XCTAssertEqual(Int(fall.start.timeIntervalSince1970), 1_762_056_000)     // 2025-11-02T04:00:00Z
        XCTAssertEqual(Int(fall.nextStart.timeIntervalSince1970), 1_762_146_000) // 2025-11-03T05:00:00Z
    }

    /// Requirement (b) in the SECOND fixture zone the spec names (T06): America/Los_Angeles spring and
    /// fall. The shipped answer follows LA's own 23 h / 25 h windows, and the old fixed-offset answer
    /// differs ONLY where it was wrong (the boundary hour).
    func testLocalDayWindowIsTheShippedDSTAnswerInLosAngeles() throws {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        let profile = UserProfile(weightKg: 75, heightCm: 178, age: 30, sex: "male")

        // Spring-forward 2025-03-09: [08:00Z, 08:00Z+23h) — PST→PDT.
        do {
            let day = "2025-03-09"
            let window = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: day, zone: zone))
            let b = bounds(window)
            XCTAssertEqual(b.start, 1_741_507_200, "2025-03-09 08:00Z")
            XCTAssertEqual(b.end, 1_741_590_000, "2025-03-10 07:00Z")
            XCTAssertEqual(b.end - b.start, 23 * 3_600, "LA spring-forward day must be 23 h")
            let off = zone.secondsFromGMT(for: window.start)   // -8h (PST at the day's start)
            var counter = 100
            let daySteps: [StepSample] = stride(from: b.start - 7_200,
                                                to: b.end + 7_200, by: 60).map { ts in
                counter += 7
                return StepSample(ts: ts, counter: counter & 0xFFFF)
            }
            let shipped = AnalyticsEngine.analyzeDay(day: day, daySteps: daySteps, profile: profile,
                                                     tzOffsetSeconds: off, dayWindow: window)
            let trueDay = daySteps.filter { $0.ts >= b.start && $0.ts < b.end }
            XCTAssertEqual(shipped.daily.steps, 7 * (trueDay.count - 1),
                           "LA spring-forward: the shipped window must stop at the true next midnight "
                           + "(the old fixed-offset window reached an hour into 03-10)")
        }

        // Fall-back 2025-11-02: [07:00Z, 07:00Z+25h) — PDT→PST.
        do {
            let day = "2025-11-02"
            let window = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: day, zone: zone))
            let b = bounds(window)
            XCTAssertEqual(b.start, 1_762_066_800, "2025-11-02 07:00Z")
            XCTAssertEqual(b.end, 1_762_156_800, "2025-11-03 08:00Z")
            XCTAssertEqual(b.end - b.start, 25 * 3_600, "LA fall-back day must be 25 h")
            let off = zone.secondsFromGMT(for: window.start)   // -7h (PDT at the day's start)
            let session = SleepSession(start: b.end - 2 * 3_600, end: b.end - 1_800,
                                       efficiency: 0.9,
                                       stages: [StageSegment(start: b.end - 2 * 3_600,
                                                             end: b.end - 1_800, stage: "deep")],
                                       restingHR: 55, avgHRV: 80)
            let shipped = AnalyticsEngine.analyzeDay(day: day, profile: profile, tzOffsetSeconds: off,
                                                     dayWindow: window, providedSleep: [session])
            XCTAssertEqual(shipped.sleepSessions.count, 1,
                           "LA fall-back: the day's last hour must attribute to THIS day")
            XCTAssertEqual(shipped.daily.totalSleepMin, 90)
        }
    }

    /// A mid-run zone change is expressible at this layer as two windows over the same dates: the SAME
    /// UTC instant belongs to a different local day in each zone, and each window's bounds follow its own
    /// zone's rule. Pins the key/bounds agreement per zone (the expressible form of T06 travel).
    func testZoneChangeMidRunWindowsFollowEachZonesRule() throws {
        let ny = TimeZone(identifier: "America/New_York")!
        let la = TimeZone(identifier: "America/Los_Angeles")!
        let helperNY = LocalDayWindows(timeZone: ny)
        let helperLA = LocalDayWindows(timeZone: la)

        // 2025-11-02 05:00Z is 01:00 EDT in NY (Nov 2) and 22:00 PDT in LA (Nov 1): a phone that
        // changed zone mid-run puts this instant on a different local day in each zone.
        let instant = Date(timeIntervalSince1970: 1_762_059_600)   // 2025-11-02T05:00:00Z
        XCTAssertEqual(helperNY.dayKey(for: instant), "2025-11-02")
        XCTAssertEqual(helperLA.dayKey(for: instant), "2025-11-01")

        // Each zone's own day window contains the instant exactly as its key says.
        let nyWindow = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: "2025-11-02", zone: ny))
        let laWindow = try XCTUnwrap(AnalyticsEngine.localDayWindow(day: "2025-11-01", zone: la))
        XCTAssertTrue(Int(nyWindow.start.timeIntervalSince1970) <= 1_762_059_600
                        && 1_762_059_600 < Int(nyWindow.nextStart.timeIntervalSince1970),
                      "NY 2025-11-02 must contain the instant")
        XCTAssertTrue(Int(laWindow.start.timeIntervalSince1970) <= 1_762_059_600
                        && 1_762_059_600 < Int(laWindow.nextStart.timeIntervalSince1970),
                       "LA 2025-11-01 must contain the instant (its key says Nov 1)")
        XCTAssertEqual(Int(laWindow.start.timeIntervalSince1970), 1_761_980_400,   // 2025-11-01 07:00Z
                       "LA 2025-11-01 (PDT) starts at its own 07:00Z local midnight")
        XCTAssertEqual(Int(nyWindow.start.timeIntervalSince1970), 1_762_056_000,   // 2025-11-02 04:00Z
                       "NY 2025-11-02 (EDT) starts at its own 04:00Z local midnight")
    }
}

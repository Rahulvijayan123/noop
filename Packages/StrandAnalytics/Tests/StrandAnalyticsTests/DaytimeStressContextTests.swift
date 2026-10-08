import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// D4-05 / D6-05 / D8-12: daytime stress and its personal baseline read hours in their sleep / activity /
/// posture context, with ONE mask rule for the scorer and the baseline aggregate.
final class DaytimeStressContextTests: XCTestCase {

    /// Hours `hours` of day 0 (tz 0), each a full hour of 1 Hz HR at the paired bpm.
    private func dayHR(_ hours: [Int], _ bpms: [Int]) -> [HRSample] {
        var out: [HRSample] = []
        for (h, bpm) in zip(hours, bpms) {
            out += (0..<3_600).map { HRSample(ts: h * 3_600 + $0, bpm: bpm) }
        }
        return out
    }

    private func iv(_ fromHour: Double, _ toHour: Double, _ cls: ActivityClass) -> ActivityContextInterval {
        ActivityContextInterval(start: Int(fromHour * 3_600), end: Int(toHour * 3_600), activityClass: cls,
                                confidence: 0.8)
    }

    /// The verifier's acceptance case, as a sleep-in: 06:00-10:00 asleep at 50 bpm, 70 bpm from 10:00 to
    /// 22:00. With the sleep block supplied the aggregate and the day-relative reference are 70; without it
    /// the P10 floor is the sleeping HR (50) and the calm reference is pulled down to 65.
    func testSleepInsideTheClockWindowLeavesTheAggregateAndTheReference() {
        let hours = Array(6..<22)
        let bpms = hours.map { $0 < 10 ? 50 : 70 }
        let hr = dayHR(hours, bpms)
        let sleep = DaytimeStress.DayContext(sleepSpans: [.init(start: 0, end: 10 * 3_600)])

        let without = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: [], tzOffsetSeconds: 0)
        let with = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: [], tzOffsetSeconds: 0, context: sleep)
        XCTAssertEqual(without.hr ?? 0, 50, accuracy: 1e-9, "old behaviour: the sleep hours are the P10 floor")
        XCTAssertEqual(with.hr ?? 0, 70, accuracy: 1e-9)

        let plain = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0)
        let ctx = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0, context: sleep)
        // Old: the 70-bpm hours score above the 50-bpm calm reference. New: the asleep hours leave the
        // read, the reference is 70, and a flat awake day reads flat.
        XCTAssertGreaterThan(plain.hours.first { $0.hour == 12 }?.level ?? 0, 1.0)
        let noon = ctx.hours.first { $0.hour == 12 }
        XCTAssertNotNil(noon?.level)
        XCTAssertLessThan(noon!.level!, plain.hours.first { $0.hour == 12 }!.level!)
        XCTAssertEqual(ctx.sleepMaskedHours, 4)
        let six = ctx.hours.first { $0.hour == 6 }
        XCTAssertEqual(six?.maskedForSleep, true)
        XCTAssertNil(six?.level)
        XCTAssertEqual(six?.maskedForActivity, false, "asleep is not activity")
    }

    /// A nap 14:00-14:45 (75% of the hour) is masked; a 20-minute doze is not "mostly asleep".
    func testANapHourIsMaskedOnlyWhenMostlyAsleep() {
        let hours = Array(8..<20)
        let hr = dayHR(hours, hours.map { _ in 70 })
        let nap = DaytimeStress.DayContext(sleepSpans: [.init(start: 14 * 3_600, end: 14 * 3_600 + 2_700),
                                                        .init(start: 16 * 3_600, end: 16 * 3_600 + 1_200)])
        let r = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0, context: nap)
        XCTAssertEqual(r.hours.first { $0.hour == 14 }?.maskedForSleep, true)
        XCTAssertEqual(r.hours.first { $0.hour == 16 }?.maskedForSleep, false)
        XCTAssertEqual(r.hours.first { $0.hour == 16 }?.context?.sleepShare ?? 0, 1_200.0 / 3_600, accuracy: 1e-9)
    }

    /// The SAME ambulatory mask in the aggregate as in the scorer: a context-active hour leaves both.
    func testAnAmbulatoryContextHourIsExcludedFromBothSides() {
        let hours = Array(8..<18)
        let bpms = hours.map { $0 == 10 ? 55 : 70 }   // a low-HR hour that is nonetheless "walking"
        let hr = dayHR(hours, bpms)
        let walk = DaytimeStress.DayContext(intervals: [iv(10, 11, .walking)])
        let agg = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: [], tzOffsetSeconds: 0, context: walk)
        XCTAssertEqual(agg.hr ?? 0, 70, accuracy: 1e-9)
        let r = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0, context: walk)
        XCTAssertEqual(r.hours.first { $0.hour == 10 }?.maskedForActivity, true)
        XCTAssertEqual(r.activityMaskedHours, 1)
    }

    /// D8-12: posture shares are provenance on the hour; nothing is invented. A committed-standing hour is
    /// flagged, kept out of the calm reference and the aggregate, and cannot alone back sustained-high; a
    /// posture-unresolved hour is flagged as unresolved and otherwise scored as before.
    func testPostureFlagsAreProvenanceAndUprightHoursCannotTripSustainedHigh() {
        let hours = Array(8..<18)
        // 08-14 seated at 60; 15-17 standing still at 80 (orthostatic + some arousal).
        let hr = dayHR(hours, hours.map { $0 >= 15 ? 80 : 60 })
        var ivs = [iv(8, 15, .sitting), iv(15, 18, .standing)]
        let ctx = DaytimeStress.DayContext(intervals: ivs)
        let plain = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0)
        let r = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0, context: ctx)
        XCTAssertTrue(plain.sustainedHigh, "posture-blind: three still standing hours trip the nudge")
        XCTAssertFalse(r.sustainedHigh)
        XCTAssertEqual(r.uprightCommittedHours, 3)
        let h16 = r.hours.first { $0.hour == 16 }
        XCTAssertEqual(h16?.context?.postureFlag, .uprightCommitted)
        XCTAssertEqual(h16?.context?.uprightShare ?? 0, 1, accuracy: 1e-9)
        XCTAssertNotNil(h16?.level, "the standing hour is still scored: its HR is real")
        let agg = DaytimeStress.dayDaytimeAggregate(hr: hr, rr: [], tzOffsetSeconds: 0, context: ctx)
        XCTAssertEqual(agg.hr ?? 0, 60, accuracy: 1e-9)

        ivs = [iv(8, 18, .stationary)]
        let unresolved = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0,
                                               context: .init(intervals: ivs))
        XCTAssertEqual(unresolved.hours.first { $0.hour == 16 }?.context?.postureFlag, .postureUnresolved)
        XCTAssertEqual(unresolved.postureUnresolvedHours, 10)
        XCTAssertEqual(unresolved.hours.map(\.level), plain.hours.map(\.level),
                       "unresolved posture is never turned into a posture call")
        XCTAssertEqual(unresolved.sustainedHigh, plain.sustainedHigh)
    }

    /// No context is byte-identical to the clock-only read, and a different context never reuses a
    /// memoized result.
    func testEmptyContextIsByteIdenticalAndContextIsPartOfTheMemoKey() {
        let hours = Array(6..<22)
        let hr = dayHR(hours, hours.map { $0 < 8 ? 50 : 70 })
        XCTAssertEqual(DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0),
                       DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0, context: .none))
        let a = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0)
        let b = DaytimeStress.analyze(hr: hr, rr: [], tzOffsetSeconds: 0,
                                      context: .init(sleepSpans: [.init(start: 0, end: 8 * 3_600)]))
        XCTAssertNotEqual(a, b)
        XCTAssertEqual(DaytimeStress.dayDaytimeAggregate(hr: hr, rr: [], tzOffsetSeconds: 0).hr,
                       DaytimeStress.dayDaytimeAggregate(hr: hr, rr: [], tzOffsetSeconds: 0,
                                                         gravity: [], context: .none).hr)
    }
}

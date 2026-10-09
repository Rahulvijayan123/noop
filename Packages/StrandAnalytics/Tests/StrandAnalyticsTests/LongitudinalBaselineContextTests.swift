import XCTest
import WhoopStore
@testable import StrandAnalytics

final class LongitudinalBaselineContextTests: XCTestCase {

    private func sitting(_ start: Int, _ end: Int, hr: Double, detail: String? = nil) -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(startTs: start, endTs: end, activityClass: "sitting", confidence: 0.9,
                                   evidenceQuality: 0.9, posture: "seated_likely", locomotion: "stationary",
                                   sleepState: "awake", wearState: "on_wrist", intensity: 0.05,
                                   hrSamples: end - start, hrMean: hr, detail: detail)
    }

    func testAVehicleRideNeverFeedsTheRestStrata() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = 1_780_000_000 - 1_780_000_000 % 86_400 + 12 * 3600
        let rows = [sitting(noon, noon + 600, hr: 60),
                    sitting(noon + 600, noon + 2400, hr: 60),
                    sitting(noon + 2400, noon + 4200, hr: 95, detail: ActivityDetail.inVehicle.rawValue)]
        let obs = LongitudinalBaseline.ContextMaterializer.observations(rows: rows, calendar: cal)
        for series in [LBSeries.awakeRestHR, .awakeSeatedHR] {
            let value = try XCTUnwrap(obs[series]?.first?.value, "\(series)")
            XCTAssertEqual(value, 60, accuracy: 1e-9, "\(series) mixed the ride's heart rate into seated rest")
        }
    }

    private func row(_ cls: String, _ start: Int, _ end: Int, hr: Double, posture: String? = nil,
                     locomotion: String = "stationary", intensity: Double = 0.05) -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(startTs: start, endTs: end, activityClass: cls, confidence: 0.9,
                                   evidenceQuality: 0.9, posture: posture, locomotion: locomotion,
                                   sleepState: "awake", wearState: "on_wrist", intensity: intensity,
                                   hrSamples: end - start, hrMean: hr)
    }

    /// Rule exercise-session-1: a gym session (brisk sets, still rests at 120 bpm) and its recovery feed the exercise
    /// series and never the awake-rest strata (audit 2026-10-09: recovery tails leaked into awake rest).
    func testExerciseSessionAndRecoveryNeverReachRest() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let t0 = 1_780_000_000 - 1_780_000_000 % 86_400 + 10 * 3600
        var rows: [ActivityContextIntervalRow] = []
        // 60 min seated at 66.
        rows.append(sitting(t0, t0 + 3600, hr: 66))
        // 60 min gym: 1 min brisk set, 2 min still rest at 120.
        var t = t0 + 3600
        while t < t0 + 7200 {
            rows.append(row("brisk_walking", t, t + 60, hr: 135, locomotion: "brisk_walking", intensity: 0.6))
            rows.append(row("stationary", t + 60, t + 180, hr: 120))
            t += 180
        }
        // 40 min still recovery: 110 → 72.
        for k in 0..<40 {
            rows.append(row("stationary", t + k * 60, t + (k + 1) * 60, hr: 110 - Double(k) * 0.95))
        }
        t += 2400
        rows.append(sitting(t, t + 3600, hr: 66))
        let sessions = LongitudinalBaseline.ContextMaterializer.exerciseSessions(rows: rows)
        XCTAssertEqual(sessions.count, 1)
        let obs = LongitudinalBaseline.ContextMaterializer.observations(rows: rows, calendar: cal)
        let rest = try XCTUnwrap(obs[.awakeRestHR]?.first?.value)
        XCTAssertEqual(rest, 66, accuracy: 0.5, "session / recovery heart rate leaked into awake rest")
        let session = try XCTUnwrap(obs[.exerciseSessionHR]?.first?.value)
        XCTAssertGreaterThan(session, 115)
        XCTAssertNotNil(obs[.exerciseRecoveryHR]?.first?.value)
    }

    /// A still interval whose posture the decoder left unknown does not break a seated bout (they alternated every
    /// 1–2 minutes on real data and kept every posture stratum empty).
    func testUnknownPostureStillIntervalsDoNotBreakASeatedBout() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let t0 = 1_780_000_000 - 1_780_000_000 % 86_400 + 12 * 3600
        var rows: [ActivityContextIntervalRow] = []
        var t = t0
        while t < t0 + 3600 {
            rows.append(row("sitting_desk", t, t + 90, hr: 64, posture: "seated_likely"))
            rows.append(row("stationary", t + 90, t + 150, hr: 64))
            t += 150
        }
        let obs = LongitudinalBaseline.ContextMaterializer.observations(rows: rows, calendar: cal)
        let seated = try XCTUnwrap(obs[.awakeSeatedHR]?.first, "seated stratum stayed empty")
        XCTAssertEqual(seated.value ?? 0, 64, accuracy: 1e-9)
    }
}

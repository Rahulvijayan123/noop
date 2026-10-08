import XCTest
import StrandAnalytics
@testable import Strand

/// Spec-02 readback for `daily.sleep_analytics_v1` (docs/spec-02/CONTRACT.md §4): producer-shaped JSON →
/// `HostedDayResult` → the shared `SleepAnalyticsDocument` → `SleepAnalyticsDisplayModel`.
///
/// pNN50 with its denominator and optical-PRV labelling, the thermal slopes labelled after the estimated window
/// END, the 30-minute morning response with separate coverage per signal and its interpretation, stage-associated
/// movement with its disclosure; an old document renders exactly as before; a malformed spec-02 group never costs
/// the existing groups.
final class Spec02SleepAnalyticsReadbackTests: XCTestCase {

    static let start = 1_762_383_600
    static let end = 1_762_412_400

    static func metric(_ value: Double?, _ unit: String, _ status: String, _ reason: String? = nil) -> [String: Any] {
        var m: [String: Any] = ["unit": unit, "status": status]
        if let value { m["value"] = value }
        if let reason { m["reason"] = reason }
        return m
    }

    static func count(_ value: Int?, _ status: String, _ reason: String? = nil) -> [String: Any] {
        var m: [String: Any] = ["unit": "count", "status": status]
        if let value { m["value"] = value }
        if let reason { m["reason"] = reason }
        return m
    }

    static func signal(_ name: String, unit: String, rule: String, before: Double?, after: Double?,
                       beforeValid: Int, afterValid: Int, reason: String? = nil) -> [String: Any] {
        let points: [[String: Any]] = (-30..<30).map { offset in
            let valid = offset < 0 ? (offset + 30) < beforeValid : offset < afterValid
            let v: Any = valid ? ((offset < 0 ? before : after) ?? 2.0) : NSNull()
            return ["offset_min": offset, "value": v, "support": valid ? 52 : 4, "valid": valid]
        }
        let change: [String: Any] = (before != nil && after != nil)
            ? metric(after! - before!, unit, "available")
            : metric(nil, unit, "unavailable", reason ?? "insufficient_coverage")
        return [
            "signal": name, "unit": unit, "minute_rule": rule, "points": points,
            "before_valid_minutes": beforeValid, "after_valid_minutes": afterValid,
            "eligible_minutes_each_side": 30,
            "before_median": before.map { metric($0, unit, "available") } ?? metric(nil, unit, "unavailable", reason ?? "insufficient_coverage"),
            "after_median": after.map { metric($0, unit, "available") } ?? metric(nil, unit, "unavailable", reason ?? "insufficient_coverage"),
            "change": change,
        ]
    }

    /// The analytics fixture with every spec-02 addition.
    static func spec02JSON() -> [String: Any] {
        var json = SleepAnalyticsSectionTests.fullDocumentJSON()
        let quality = (json["continuity"] as! [String: Any])["quality"] as! [String: Any]

        var prv = json["prv_diagnostics"] as! [String: Any]
        prv["nightly_pnn50_pct"] = metric(12.396, "%", "available")
        prv["pnn50_pair_count"] = count(9_600, "available")
        prv["nn50_count"] = count(1_190, "available")
        prv["pnn50_method"] = "pnn50GapAware_original_adjacency_v1"
        var windows = prv["windows"] as! [[String: Any]]
        windows[0]["pnn50_pct"] = 11.8
        windows[0]["nn50_count"] = 72
        prv["windows"] = windows
        json["prv_diagnostics"] = prv

        var movement = json["movement"] as! [String: Any]
        func stage(_ label: String, eligible: Double, moving: Double, pct: Double?, bouts: Int,
                   rate: Double?, rateStatus: String = "available") -> [String: Any] {
            ["label": label,
             "eligible_seconds": metric(eligible, "s", "available"),
             "movement_seconds": metric(moving, "s", "available"),
             "movement_percentage": pct.map { metric($0, "%", "available") } ?? metric(nil, "%", "unavailable", "zero_denominator"),
             "movement_bout_starts": count(bouts, "available"),
             "movement_bouts_per_eligible_hour": rate.map { metric($0, "per_h", rateStatus) }
                ?? metric(nil, "per_h", "unavailable", "zero_denominator")]
        }
        movement["stage_movement"] = [
            stage("wake", eligible: 1_700, moving: 420, pct: 24.7, bouts: 6, rate: 12.7, rateStatus: "partial"),
            stage("light", eligible: 12_000, moving: 360, pct: 3.0, bouts: 4, rate: 1.2),
            stage("deep", eligible: 6_000, moving: 60, pct: 1.0, bouts: 1, rate: 0.6),
            stage("rem", eligible: 4_800, moving: 120, pct: 2.5, bouts: 2, rate: 1.5),
            stage("unknown", eligible: 0, moving: 0, pct: nil, bouts: 0, rate: nil),
        ]
        movement["stage_movement_note"] = "stages_may_depend_on_motion"
        json["movement"] = movement

        json["morning_response"] = [
            "quality": quality,
            "anchor_kind": "effective_window_end",
            "anchor_ts": end, "anchor_at": "2025-11-06T07:00:00Z",
            "window_before_seconds": 1800, "window_after_seconds": 1800,
            "heart_rate": signal("heart_rate", unit: "bpm", rule: "hr_min_30_distinct_seconds",
                                 before: 54, after: 63, beforeValid: 28, afterValid: 26),
            "skin_temperature": signal("skin_temperature", unit: "°C", rule: "thermal_accepted_minute_bin",
                                       before: 33.1, after: 32.62, beforeValid: 30, afterValid: 24),
            "movement": signal("movement", unit: "s/min", rule: "movement_min_30_adjacencies",
                               before: 1.5, after: nil, beforeValid: 25, afterValid: 12,
                               reason: "insufficient_coverage"),
            "algorithm_version": "morning-response-1",
            "interpretation": "response_around_detected_boundary_not_awakening_physiology",
        ]
        return json
    }

    private func hosted(_ json: [String: Any]) -> HostedDayResult? {
        HostedDayResult(day: "2025-11-06",
                        object: ["result_revision": "sha256:abc", "daily": ["sleep_analytics_v1": json], "sleep": []])
    }

    private func model(_ json: [String: Any]) throws -> SleepAnalyticsDisplayModel {
        let doc = try XCTUnwrap(hosted(json)?.sleepAnalytics)
        return SleepAnalyticsDisplayModel(document: doc, sessions: [SleepAnalyticsSectionTests.currentSession()])
    }

    private func group(_ m: SleepAnalyticsDisplayModel, _ id: String) throws -> SleepAnalyticsDisplayModel.DetailGroup {
        try XCTUnwrap(m.details.first { $0.id == id }, id)
    }

    private func value(_ g: SleepAnalyticsDisplayModel.DetailGroup, _ label: String) -> String? {
        g.rows.first { $0.label == label }?.value
    }

    // MARK: - Decode: persisted values arrive unchanged

    func testSpec02FieldsDecodeExactly() throws {
        let doc = try XCTUnwrap(hosted(Self.spec02JSON())?.sleepAnalytics)
        XCTAssertEqual(doc.prvDiagnostics.nightlyPnn50Pct?.value, 12.396)
        XCTAssertEqual(doc.prvDiagnostics.pnn50PairCount?.value, 9_600)
        XCTAssertEqual(doc.prvDiagnostics.nn50Count?.value, 1_190)
        XCTAssertEqual(doc.prvDiagnostics.pnn50Method, "pnn50GapAware_original_adjacency_v1")
        XCTAssertEqual(doc.prvDiagnostics.windows.first?.pnn50Pct, 11.8)
        XCTAssertEqual(doc.prvDiagnostics.windows.first?.nn50Count, 72)
        XCTAssertNil(doc.prvDiagnostics.windows.last?.pnn50Pct)
        let morning = try XCTUnwrap(doc.morningResponse)
        XCTAssertEqual(morning.algorithmVersion, "morning-response-1")
        XCTAssertEqual(morning.anchorTs, Self.end)
        XCTAssertEqual(morning.heartRate.points.count, 60)
        XCTAssertEqual(morning.heartRate.beforeValidMinutes, 28)
        XCTAssertEqual(morning.skinTemperature.afterMedian.value, 32.62)
        XCTAssertNil(morning.movement.afterMedian.value)
        XCTAssertEqual(morning.movement.change.reason, .insufficientCoverage)
        XCTAssertEqual(doc.movement.stageMovement?.count, 5)
        XCTAssertEqual(doc.movement.stageMovementNote, "stages_may_depend_on_motion")
        XCTAssertEqual(doc.algorithmVersion, "nara-sleep-analytics-1")
    }

    // MARK: - pNN50

    func testPnn50ShowsItsDenominatorAndOpticalLabelling() throws {
        let prv = try group(try model(Self.spec02JSON()), "prv")
        XCTAssertEqual(value(prv, "pNN50 (optical PRV)"),
                       "12.4% · 1,190 of 9,600 adjacent pairs differ by > 50 ms")
        XCTAssertEqual(value(prv, "Source"), "Optical pulse intervals (pulse-rate variability), not ECG")
        XCTAssertEqual(value(prv, "pNN50 definition"), "pnn50GapAware_original_adjacency_v1")
        XCTAssertTrue(prv.summary.contains("pNN50 12.4%"))
        // Beside SD1/SD2, which are unchanged.
        XCTAssertEqual(value(prv, "SD1 (ms)")?.hasPrefix("41.2 ms"), true)
    }

    func testAnUnavailablePnn50SaysWhyAndNeverZero() throws {
        var json = Self.spec02JSON()
        var prv = json["prv_diagnostics"] as! [String: Any]
        prv["nightly_pnn50_pct"] = Self.metric(nil, "%", "unavailable", "unresolved_adjacency")
        prv["pnn50_pair_count"] = Self.count(nil, "unavailable", "unresolved_adjacency")
        prv["nn50_count"] = Self.count(nil, "unavailable", "unresolved_adjacency")
        json["prv_diagnostics"] = prv
        let g = try group(try model(json), "prv")
        XCTAssertEqual(value(g, "pNN50 (optical PRV)"), "Unavailable · beat timing could not be resolved")
        XCTAssertFalse(g.summary.contains("pNN50"))
    }

    // MARK: - Thermal slopes

    func testThermalSlopesAreLabelledAfterTheEstimatedWindowEnd() throws {
        let g = try group(try model(Self.spec02JSON()), "thermalTrend")
        XCTAssertEqual(value(g, "Hour before sleep onset"), "−0.3 °C/h over 48 of 60 min")
        XCTAssertEqual(value(g, "30 min after estimated window end"), "+0.4 °C/h over 24 of 30 min")
        for row in g.rows { XCTAssertFalse(row.label.lowercased().contains("waking"), row.label) }
    }

    // MARK: - Morning response

    func testMorningResponseKeepsSeparateCoveragePerSignal() throws {
        let g = try group(try model(Self.spec02JSON()), "morningResponse")
        XCTAssertEqual(g.title, "Around the end of the sleep window")
        XCTAssertEqual(value(g, "Heart rate, 30 min before → after"),
                       "54 bpm → 63 bpm (+9 bpm) · before 28 of 30 min · after 26 of 30 min valid")
        XCTAssertEqual(value(g, "Skin temperature, 30 min before → after"),
                       "33.10 °C → 32.62 °C (−0.48 °C) · before 30 of 30 min · after 24 of 30 min valid")
        // A side without enough valid minutes: unavailable with its reason, never a fabricated median.
        XCTAssertEqual(value(g, "Movement, 30 min before → after"),
                       "Unavailable · too few valid minutes on one side · before 25 of 30 min · after 12 of 30 min valid")
        XCTAssertEqual(value(g, "Anchored at"), "Estimated end of the sleep window, 07:00")
        XCTAssertEqual(value(g, "Definition"), "morning-response-1")
        XCTAssertTrue(value(g, "About this")?.contains("not proof") == true)
        XCTAssertEqual(g.summary, "HR 54 bpm → 63 bpm (+9 bpm) · temp 33.10 °C → 32.62 °C (−0.48 °C)")
    }

    // MARK: - Stage-associated movement

    func testStageMovementCarriesItsDisclosure() throws {
        let g = try group(try model(Self.spec02JSON()), "stageMovement")
        XCTAssertEqual(value(g, "Light (est.)"), "3% of 3 h 20 m moving · 1.2 bouts/h")
        XCTAssertEqual(value(g, "Deep (est.)"), "1% of 1 h 40 m moving · 0.6 bouts/h")
        XCTAssertEqual(value(g, "Wake (est.)"), "25% of 28 min moving · 12.7 bouts/h (short exposure)")
        XCTAssertEqual(value(g, "Unknown stage"), "Unavailable · not enough data to compare")
        XCTAssertEqual(value(g, "Note"),
                       "Stages are estimated partly from wrist movement, so movement and stage are not independent")
        XCTAssertEqual(g.summary, "Wake 25% · Light 3% · Deep 1% · REM 2%")
    }

    // MARK: - Old document and group failure

    func testAnOldDocumentRendersExactlyAsBefore() throws {
        let m = try model(SleepAnalyticsSectionTests.fullDocumentJSON())
        XCTAssertEqual(m.details.map(\.id), ["stageTiming", "stageBouts", "transitions", "thermalTrend", "prv", "coverage"])
        let prv = try group(m, "prv")
        XCTAssertEqual(prv.rows.map(\.label), ["SD1 (ms)", "SD2 (ms)", "Ratio SD1/SD2", "Eligible windows", "Rejected beats"])
        XCTAssertEqual(m.rows.map(\.id), ["waso", "longestStretch", "awakenings", "remLatency", "movement", "tempSpread"])
    }

    func testAMalformedMorningResponseNeverCostsTheOtherGroups() throws {
        var json = Self.spec02JSON()
        var morning = json["morning_response"] as! [String: Any]
        morning.removeValue(forKey: "heart_rate")
        json["morning_response"] = morning
        let doc = try XCTUnwrap(hosted(json)?.sleepAnalytics, "the document must survive one malformed group")
        XCTAssertNil(doc.morningResponse)
        XCTAssertEqual(doc.prvDiagnostics.nightlyPnn50Pct?.value, 12.396, "a good pNN50 is kept")
        XCTAssertEqual(doc.movement.stageMovement?.count, 5)
        XCTAssertEqual(doc.continuity.observedWasoSeconds.value, 1_800)
    }

    func testMalformedSpec02FieldsInSeveralGroupsStillKeepTheDocument() throws {
        var json = Self.spec02JSON()
        var prv = json["prv_diagnostics"] as! [String: Any]
        prv["pnn50_pair_count"] = "lots"
        json["prv_diagnostics"] = prv
        var movement = json["movement"] as! [String: Any]
        movement["stage_movement"] = [["label": "light"]]
        json["movement"] = movement
        let doc = try XCTUnwrap(hosted(json)?.sleepAnalytics)
        XCTAssertNil(doc.prvDiagnostics.nightlyPnn50Pct)
        XCTAssertNil(doc.movement.stageMovement)
        XCTAssertNil(doc.morningResponse)
        XCTAssertEqual(doc.prvDiagnostics.nightlySd1Ms.value, 41.2)
    }

    func testAMalformedCoreGroupIsStillRejected() {
        var json = Self.spec02JSON()
        json.removeValue(forKey: "continuity")
        XCTAssertNil(hosted(json)?.sleepAnalytics, "dropping spec-02 additions never papers over a broken core group")
    }
}

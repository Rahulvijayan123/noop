import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// The Swift reason table must equal contracts/reason-codes.json (the edge function, SQL registry and Python mirror
/// are pinned to the same file by their own tests).
final class DataReasonTests: XCTestCase {
    private func contract() throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("contracts/reason-codes.json")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testTableEqualsContract() throws {
        let c = try contract()
        XCTAssertEqual(c["version"] as? String, DataReasonCatalog.version)
        let codes = try XCTUnwrap(c["codes"] as? [[String: Any]])
        XCTAssertEqual(codes.count, DataReasonCatalog.codes.count)
        for (j, s) in zip(codes, DataReasonCatalog.codes) {
            XCTAssertEqual(j["code"] as? String, s.code)
            XCTAssertEqual(j["family"] as? String, s.family)
            XCTAssertEqual(j["default_certainty"] as? String, s.defaultCertainty.rawValue)
            XCTAssertEqual(j["effect"] as? String, s.effect.rawValue)
        }
        let legacy = try XCTUnwrap(c["legacy"] as? [String: [String: [String: String]]])
        XCTAssertEqual(Set(legacy.keys), Set(DataReasonCatalog.legacy.keys))
        for (vocab, m) in legacy {
            XCTAssertEqual(Set(m.keys), Set(DataReasonCatalog.legacy[vocab]?.keys.map { $0 } ?? []), vocab)
            for (k, v) in m {
                let s = try XCTUnwrap(DataReasonCatalog.legacy[vocab]?[k])
                XCTAssertEqual(v["code"], s.code, "\(vocab).\(k)")
                XCTAssertEqual(v["certainty"], s.certainty.rawValue, "\(vocab).\(k)")
                XCTAssertEqual(v["subcode"], s.subcode, "\(vocab).\(k)")
                XCTAssertNotNil(DataReasonCatalog.byCode[s.code], "\(vocab).\(k) maps to an unknown code")
            }
        }
    }

    func testEveryWatchdogQualityReasonTheAssessorEmitsIsMappedOrInformational() {
        // Informational evidence notes that are not causes.
        let informational: Set<String> = ["beat_coverage_only", "motion_from_occupancy"]
        let emitted = ["wrist_off_event", "optical_baseline_zero", "charging", "strap_reset_unrecovered", "hr_absent",
                       "skin_temp_unconfirmed", "rr_pileup", "optical_saturation", "contact_not_detected",
                       "optical_sentinel", "motion_mode_optics", "beat_coverage_low", "beat_overcount",
                       "hr_in_motion_unverified", "optical_sentinel_at_rest", "no_signal_metadata", "no_motion_sample"]
        for r in emitted where !informational.contains(r) {
            XCTAssertNotNil(DataReason.from(vocabulary: "watchdog_quality", legacy: r), r)
        }
        // An inferred cause is never reported as confirmed.
        XCTAssertEqual(DataReason.from(vocabulary: "watchdog_quality", legacy: "motion_mode_optics")?.certainty, .inferred)
        XCTAssertEqual(DataReason.from(vocabulary: "watchdog_quality", legacy: "wrist_off_event")?.certainty, .confirmed)
    }
}

/// Observed quality reasons from the strap's own record stream (audit 2026-10-09, B-quality).
final class WatchdogRecordIndexQualityTests: XCTestCase {
    func testRecordIndexGapSeparatesNotRecordingFromTransportLoss() {
        let now = 1_790_000_000 - 1_790_000_000 % 60
        let feed = Watchdog.syntheticFeed(now: now, hr: 70, hrv: 50, temp: 33.5, resp: 14, motion: 0.02)
        guard case .success(var w) = WatchdogWindowBuilder.build(feed) else { return XCTFail("window") }
        // HR missing for minutes 10–19 of the window.
        for i in 10..<20 { w.hr[i] = nil }
        var q = WatchdogQualityFeed.synthetic(for: w)
        for i in 10..<20 { q.hrSecondsByMinute[w.startUnix + i * 60] = 0 }
        // Records every second except a paused stretch (index +1 across 10 minutes) …
        var idx = 1000
        for t in stride(from: w.startUnix, to: w.startUnix + 10 * 60, by: 1) { q.v18RecordIndex[t] = idx; idx += 1 }
        for t in stride(from: w.startUnix + 20 * 60, to: now, by: 1) { q.v18RecordIndex[t] = idx; idx += 1 }
        w.quality = q
        let paused = WatchdogSignalQuality.assess(window: w)
        XCTAssertEqual(paused[14].onBody, .off)
        XCTAssertTrue(paused[14].reasons.contains("strap_not_recording"))
        XCTAssertEqual(DataReason.fromWatchdogQuality(paused[14].reasons).first?.code, "strap_not_recording")
        // … versus records lost in transport (index jumps by the gap): wear stays unknown, the gap is named.
        var q2 = q
        q2.v18RecordIndex = [:]
        idx = 1000
        for t in stride(from: w.startUnix, to: now, by: 1) {
            if t < w.startUnix + 10 * 60 || t >= w.startUnix + 20 * 60 { q2.v18RecordIndex[t] = idx }
            idx += 1
        }
        w.quality = q2
        let lost = WatchdogSignalQuality.assess(window: w)
        XCTAssertNotEqual(lost[14].onBody, .off)
        XCTAssertTrue(lost[14].reasons.contains("transport_gap"))
    }
}

final class WatchdogQualityMinutesTests: XCTestCase {
    func testSummarizesCountsAndClassifiesGaps() throws {
        let t0 = 1_790_000_000 - 1_790_000_000 % 60
        var aux: [V18AuxSample] = []
        var idx = 500
        // Minute 0: 60 records, 30 with the amplitude marker, baselines up to 40.
        for s in 0..<60 {
            aux.append(V18AuxSample(ts: t0 + s, recordIndex: idx, opticalBaselineA: 20 + s % 21, opticalBaselineB: 10,
                                    opticalAmpA: s % 2 == 0 ? 128 : 90, opticalAmpB: s % 2 == 0 ? 128 : 90))
            idx += 1
        }
        // Minutes 1–3: no records, index +1 across (paused). Minute 4 onwards records again.
        for s in 240..<300 { aux.append(V18AuxSample(ts: t0 + s, recordIndex: idx)); idx += 1 }
        // Minutes 5–6: no records, index jumps by the gap (lost); minute 7 records.
        idx += 120
        for s in 420..<480 { aux.append(V18AuxSample(ts: t0 + s, recordIndex: idx)); idx += 1 }
        let rows = WatchdogQualityMinutes.summarize(aux, from: t0, to: t0 + 480)
        let byMinute = Dictionary(uniqueKeysWithValues: rows.map { (($0.minuteStart - t0) / 60, $0) })
        let first = try XCTUnwrap(byMinute[0])
        XCTAssertEqual(first.v18N, 60)
        XCTAssertEqual(first.sentinelN, 30)
        XCTAssertEqual(first.baselineMax, 40)
        XCTAssertTrue(first.reasons.contains("optical_sentinel"))
        for m in 1...3 { XCTAssertEqual(byMinute[m]?.recordGap, "paused", "minute \(m)") }
        XCTAssertEqual(byMinute[2]?.reasons, ["strap_not_recording"])
        for m in 5...6 { XCTAssertEqual(byMinute[m]?.recordGap, "lost", "minute \(m)") }
        XCTAssertNil(byMinute[4]?.recordGap)
        let body = WatchdogQualityMinutes.body(deviceId: "dev", rows: rows)
        XCTAssertEqual(body["version"] as? String, "phone-quality-1")
        XCTAssertEqual((body["minutes"] as? [[String: Any]])?.count, rows.count)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
    }
}

final class WatchdogEpisodeServerBodyTests: XCTestCase {
    func testBodyCarriesLineageAndIsJSON() throws {
        var row = WatchdogEpisodeLedgerRow(episodeId: "wd-1", deviceId: "my-whoop", openedUnix: 100, lastUnix: 400,
                                           maxSeverity: "severe", safety: true, personalOff: false,
                                           notifyDelivery: "sent", liveAlerts: true, offMinutes: [60, 120])
        row.exercise = WatchdogExerciseSnapshot(rule: "exercise-session-1", phase: "session", sessionStartUnix: 50,
                                                sessionLastMovementUnix: nil, restReference: 66, restBasis: "awake_rest_reference",
                                                ceilingBpm: 199, ceilingBasis: "age_formula_plus_5",
                                                sessionReference: "learning", recoveryReference: "learning", routine: nil)
        let note = WatchdogEpisodeAnnotation(episodeId: "wd-1", deviceId: "my-whoop", eventUnix: 100, enteredUnix: 500)
        let body = WatchdogEpisodeLedger.serverBody(rows: [row], annotations: [note], serverDeviceId: "dev",
                                                    localDeviceId: "my-whoop", versions: ["exercise_rule": "exercise-session-1"],
                                                    nowUnix: 600)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
        let ep = try XCTUnwrap((body["episodes"] as? [[String: Any]])?.first)
        XCTAssertEqual(ep["episode_id"] as? String, "wd-1")
        XCTAssertEqual(ep["off_minute_count"] as? Int, 2)
        XCTAssertEqual(ep["client_updated_at"] as? Int, 500)
        XCTAssertEqual((ep["exercise"] as? [String: Any])?["ceilingBpm"] as? Double, 199)
        XCTAssertEqual((ep["annotation"] as? [String: Any])?["episodeId"] as? String, "wd-1")
        XCTAssertNotEqual(WatchdogEpisodeLedger.fingerprint(row, annotation: nil),
                          WatchdogEpisodeLedger.fingerprint(row, annotation: note))
        // No `confirmed` known (a row from before exercise-session-2): the key is absent, not invented.
        XCTAssertNil((ep["exercise"] as? [String: Any])?["confirmed"])
    }

    /// Rule exercise-session-2: the snapshot carries `confirmed` and the phase `active` to the server, and ledger rows
    /// written before -2 (no `confirmed`) still decode.
    func testExerciseConfirmedAndActivePhaseReachTheBody() throws {
        var row = WatchdogEpisodeLedgerRow(episodeId: "wd-2", deviceId: "my-whoop", openedUnix: 100, lastUnix: 400,
                                           maxSeverity: "candidate", safety: false, personalOff: true,
                                           notifyDelivery: "", liveAlerts: true)
        row.exercise = WatchdogExerciseSnapshot(rule: ExerciseSessionRule.rule, phase: ExerciseSessionPhase.active.rawValue,
                                                sessionStartUnix: 50, sessionLastMovementUnix: 300, restReference: 66,
                                                restBasis: "awake_rest_reference", ceilingBpm: 199,
                                                ceilingBasis: "age_formula_plus_5", sessionReference: "learning",
                                                recoveryReference: "learning", routine: nil, confirmed: false)
        let body = WatchdogEpisodeLedger.serverBody(rows: [row], annotations: [], serverDeviceId: "dev",
                                                    localDeviceId: "my-whoop",
                                                    versions: ["exercise_rule": ExerciseSessionRule.rule], nowUnix: 600)
        XCTAssertNoThrow(try JSONSerialization.data(withJSONObject: body))
        let ep = try XCTUnwrap((body["episodes"] as? [[String: Any]])?.first)
        let exercise = try XCTUnwrap(ep["exercise"] as? [String: Any])
        XCTAssertEqual(exercise["confirmed"] as? Bool, false)
        XCTAssertEqual(exercise["phase"] as? String, "active")
        XCTAssertEqual(exercise["rule"] as? String, "exercise-session-2")
        var confirmed = row
        confirmed.exercise?.confirmed = true
        confirmed.exercise?.phase = "session"
        let body2 = WatchdogEpisodeLedger.serverBody(rows: [confirmed], annotations: [], serverDeviceId: "dev",
                                                     localDeviceId: "my-whoop", versions: [:], nowUnix: 600)
        let ep2 = try XCTUnwrap((body2["episodes"] as? [[String: Any]])?.first)
        XCTAssertEqual((ep2["exercise"] as? [String: Any])?["confirmed"] as? Bool, true)
        XCTAssertNotEqual(WatchdogEpisodeLedger.fingerprint(row, annotation: nil),
                          WatchdogEpisodeLedger.fingerprint(confirmed, annotation: nil))

        // A ledger row persisted before -2: its snapshot has no `confirmed` and decodes with nil.
        let legacy = """
        {"episodeId":"wd-old","deviceId":"my-whoop","openedUnix":100,"lastUnix":400,"maxSeverity":"severe",
         "safety":false,"personalOff":true,"notifyDelivery":"","liveAlerts":true,"offMinutes":[],"unavailableMinutes":0,
         "exercise":{"rule":"exercise-session-1","phase":"recovery","sessionStartUnix":50,"sessionLastMovementUnix":300,
         "restReference":66,"restBasis":"awake_rest_reference","ceilingBpm":199,"ceilingBasis":"age_formula_plus_5",
         "sessionReference":"learning","recoveryReference":"learning"}}
        """
        let decoded = try JSONDecoder().decode(WatchdogEpisodeLedgerRow.self, from: Data(legacy.utf8))
        XCTAssertEqual(decoded.exercise?.phase, "recovery")
        XCTAssertNil(decoded.exercise?.confirmed)
    }
}

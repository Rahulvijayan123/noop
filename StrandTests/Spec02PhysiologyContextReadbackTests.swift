import XCTest
import StrandAnalytics
@testable import Strand

/// Spec-02 readback for the physiology context day document (docs/spec-02/CONTRACT.md §6):
/// `sleep.day_night_heart_rate`, `pulse_episodes` and `bouts[].recovery.respiratory_recovery`, written as the
/// producer contract spells them (snake_case JSON), read through `PhysiologyContextDocument.decode` (the path the
/// `scores/context` route feeds) and the history parser (the `scores/context/history` route), into the detail and
/// history view models. Values, coverage and versions arrive as persisted; an older document has none of the
/// sections; one malformed spec-02 member never costs the member that carries it.
final class Spec02PhysiologyContextReadbackTests: XCTestCase {

    typealias PC = PhysiologyContext
    typealias W = PhysiologyContextWording

    private let tz = "America/Los_Angeles"
    private let day = "2026-10-01"
    private let gb = Locale(identifier: "en_GB")
    private var dayWindow: PC.Interval { PC.Engine.dayInterval(day, timezoneId: tz) }

    // MARK: - Fixtures

    /// A small synthetic day run through the real engine (the same shape PhysiologyContextAppTests uses).
    private func builtDocument() -> PC.DayDocument {
        let w = dayWindow
        let night = PC.Interval(w.start - 50 * 60, w.start + 6 * 3600 + 42 * 60)
        let hr = stride(from: w.start + 14 * 3600, to: w.start + 14 * 3600 + 900, by: 1).map {
            PC.HeartRateObservation(ts: $0, bpm: 58 + ($0 % 7), availableAt: $0 + 40)
        }
        let nightly = PC.MeasurementInput(
            metric: .hrvRmssd,
            method: PC.MethodRef(id: "snapshot.hrv_rmssd.night", algorithmVersion: "frwhoop-server-1",
                                 aggregation: .session, windowS: night.duration, units: "ms"),
            source: PC.SourceRef(product: .scoringSnapshot, key: "daily.hrv_rmssd_ms", inputRevision: 3,
                                 resultRevision: 12),
            value: 48.5, support: night, sessionId: "sleep-1")
        let input = PC.DayInput(
            identity: PC.DayIdentity(deviceScope: "whoop-TEST", day: day, timezoneId: tz, dayWindow: w),
            mode: .retrospective, availabilityCutoff: w.end + 31 * 3600, generatedAt: w.end + 31 * 3600,
            heartRate: hr, measurements: [nightly],
            sleepSessions: [PC.SleepSessionInput(id: "sleep-1", interval: night, isNap: false, detector: "v2")],
            regime: PC.DeviceRegimeInput(scoringAlgorithmVersion: "frwhoop-server-1"),
            inputRevisions: [PC.InputRevision(input: "scoring_snapshot", revision: "12")])
        return PC.Engine.buildDay(input, history: .empty)
    }

    /// `awake` / `asleep` medians with their own coverage, as CONTRACT §6 spells the member.
    private var dayNightJSON: [String: Any] {
        ["state": "supported", "awake_median_bpm": 64.0, "sleep_median_bpm": 52.0, "difference_bpm": 12.0,
         "percent_dip": 18.75,
         "percent_dip_definition": "100*(awake_median_bpm-sleep_median_bpm)/awake_median_bpm",
         "awake_samples": 39_400, "sleep_samples": 26_190, "awake_eligible_s": 48_000, "sleep_eligible_s": 27_000,
         "awake_coverage": 0.82, "sleep_coverage": 0.97,
         "reasons": ["percent_dip_definition", "rhythm_proxy_only"]]
    }

    private var episodeStart: Int { dayWindow.start + 2 * 3600 + 600 }

    private var pulseJSON: [String: Any] {
        let thresholds: [[String: Any]] = [
            ["name": "high_enter_bpm", "value": 100], ["name": "high_exit_bpm", "value": 95],
            ["name": "low_enter_bpm", "value": 40], ["name": "low_exit_bpm", "value": 43],
            ["name": "min_duration_s", "value": 600],
        ]
        let accel: (Int, String) -> [String: Any] = { offset, context in
            ["ts": self.dayWindow.start + offset, "baseline_bpm": 58.0, "peak_bpm": 74.0, "rise_bpm": 16.0,
             "rise_s": 9, "movement_offset_s": -3, "context": context]
        }
        return [
            "version": "pc-pulse-1", "state": "supported", "thresholds": thresholds,
            "qualified_inactive_s": 30_000, "qualified_asleep_s": 24_000, "qualified_awake_s": 6_000,
            "episodes": [[
                "id": "sustained_high-\(episodeStart)", "kind": "sustained_high",
                "interval": ["start": episodeStart, "end": episodeStart + 840], "duration_s": 840,
                "median_bpm": 104.0, "extreme_bpm": 112.0, "qualified_s": 820, "context": "awake",
                "censoring": ["episode_censored_gap"], "reasons": ["pulse_episode_high"],
            ]],
            "high_episode_count": 1, "low_episode_count": 0, "high_episode_s": 840, "low_episode_s": 0,
            "acceleration_events": [accel(3600, "asleep"), accel(7200, "asleep"), accel(50_000, "awake")],
            "acceleration_events_per_asleep_hour": 0.4, "acceleration_events_per_awake_hour": 0.6,
            "reasons": ["cause_not_attributed", "not_rhythm_classification"],
        ]
    }

    private func respiratoryJSON(state: String, lastAbove: Int? = 360, at: Int? = 720, by: Int? = nil,
                                 reasons: [String] = ["respiratory_observations_resumed"]) -> [String: Any] {
        let end = dayWindow.start + 7 * 3600 + 1800
        var r: [String: Any] = [
            "method": "pc-resp-recovery-1", "state": state, "reference_bpm": 14.2,
            "reference_window": ["start": end - 1800 - 900, "end": end - 1800], "reference_samples": 6,
            "tolerance_bpm": 1.5, "motion_subsided_at": end + 200, "first_observation_offset_s": 240,
            "follow_up": ["start": end, "end": end + 1800],
            "observations": [["offset_s": 240, "bpm": 18.1, "above_reference_bpm": 3.9],
                             ["offset_s": 720, "bpm": 15.0, "above_reference_bpm": 0.8]],
            "censoring": [], "reasons": reasons,
        ]
        if let lastAbove { r["last_above_offset_s"] = lastAbove }
        if let at { r["returned_at_offset_s"] = at }
        if let by { r["returned_by_offset_s"] = by }
        return r
    }

    private func boutJSON(respiratory: [String: Any]?) throws -> [String: Any] {
        let w = dayWindow
        let interval = PC.Interval(w.start + 7 * 3600, w.start + 7 * 3600 + 1800)
        var b = PC.ExertionBout(id: "bout-1", interval: interval, day: day, kind: "walking", status: .complete,
                                durationS: 1800, reasons: [])
        let none = PC.BoutChannel(channel: "hrv", state: .unsupported, reasons: [])
        b.recovery = PC.BoutRecovery(followUp: PC.Interval(interval.end, interval.end + 300), anchorHrBpm: 120,
                                     referenceBpm: 80, observations: [], truncatedAt: nil, censoring: [],
                                     timeToReturnS: nil, hrv: none, respiratory: none, reasons: [])
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: PC.encoder().encode(b)) as? [String: Any])
        if let respiratory {
            var recovery = try XCTUnwrap(object["recovery"] as? [String: Any])
            recovery["respiratory_recovery"] = respiratory
            object["recovery"] = recovery
        }
        return object
    }

    /// The engine's document as JSON, with the spec-02 members added in their CONTRACT wire spelling.
    private func documentJSON(dayNight: Any? = nil, pulse: Any? = nil, bouts: [[String: Any]] = []) throws -> [String: Any] {
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: PC.encoder().encode(builtDocument())) as? [String: Any])
        if let dayNight {
            var sleep = try XCTUnwrap(object["sleep"] as? [String: Any])
            sleep["day_night_heart_rate"] = dayNight
            object["sleep"] = sleep
        }
        if let pulse { object["pulse_episodes"] = pulse }
        if !bouts.isEmpty { object["bouts"] = bouts }
        return object
    }

    private func makeContextDay(_ object: [String: Any]) throws -> PhysiologyContextDay {
        let document = try XCTUnwrap(PhysiologyContextDocument.decode(try JSONSerialization.data(withJSONObject: object)))
        return PhysiologyContextDay(day: day, deviceId: "whoop-TEST", metric: nil, status: .available,
                                    mode: .retrospective, contextRevision: 7, finality: .final, document: document,
                                    pairing: nil, job: nil, fetchedAtMs: 0)
    }

    private func section(_ model: MeasurementContextDetailModel, _ id: String) -> ContextDetailSection? {
        model.sections.first { $0.id == id }
    }

    // MARK: - Wire shape

    func testTheSharedTypesWriteTheContractKeys() throws {
        // The engine now always computes both products (unavailable with reasons when the input is thin); clear
        // them to check that an ABSENT product is omitted from the wire rather than written as a placeholder.
        var doc = builtDocument()
        doc.pulseEpisodes = nil
        doc.sleep.dayNightHeartRate = nil
        let old = try XCTUnwrap(try JSONSerialization.jsonObject(with: PC.encoder().encode(doc)) as? [String: Any])
        XCTAssertNil(old["pulse_episodes"], "an absent product is omitted, never an empty placeholder")
        XCTAssertNil((old["sleep"] as? [String: Any])?["day_night_heart_rate"])

        let decoded = try XCTUnwrap(PhysiologyContextDocument.decode(try JSONSerialization.data(
            withJSONObject: try documentJSON(dayNight: dayNightJSON, pulse: pulseJSON))))
        doc.sleep.dayNightHeartRate = decoded.dayNightHeartRate
        doc.pulseEpisodes = decoded.pulseEpisodes
        let encoded = try XCTUnwrap(try JSONSerialization.jsonObject(with: PC.encoder().encode(doc)) as? [String: Any])
        let dn = try XCTUnwrap((encoded["sleep"] as? [String: Any])?["day_night_heart_rate"] as? [String: Any])
        XCTAssertEqual(Set(dn.keys), Set(dayNightJSON.keys))
        let pulse = try XCTUnwrap(encoded["pulse_episodes"] as? [String: Any])
        XCTAssertEqual(Set(pulse.keys), Set(pulseJSON.keys))
    }

    // MARK: - Awake vs asleep heart rate

    func testAwakeAndAsleepMediansKeepTheirOwnCoverage() throws {
        let contextDay = try makeContextDay(try documentJSON(dayNight: dayNightJSON, pulse: pulseJSON))
        let dn = try XCTUnwrap(contextDay.document?.dayNightHeartRate)
        XCTAssertEqual(dn.awakeMedianBpm, 64.0)
        XCTAssertEqual(dn.sleepMedianBpm, 52.0)
        XCTAssertEqual(dn.percentDip, 18.75)
        XCTAssertEqual(dn.awakeCoverage, 0.82)
        XCTAssertEqual(dn.percentDipDefinition, PC.DayNightHeartRate.percentDipFormula)

        let model = MeasurementContextDetailModel.build(day: contextDay, metric: .restingHeartRate, isStale: false,
                                                        locale: gb)
        let s = try XCTUnwrap(section(model, "dayNightHeartRate"))
        XCTAssertEqual(s.title, "Awake and asleep heart rate")
        let awake = try XCTUnwrap(s.rows.first { $0.id == "awake" })
        XCTAssertEqual(awake.value, "64 bpm")
        XCTAssertTrue(awake.note?.hasPrefix("82% of 13 h 20 min observed") == true, awake.note ?? "")
        let asleep = try XCTUnwrap(s.rows.first { $0.id == "asleep" })
        XCTAssertEqual(asleep.value, "52 bpm")
        XCTAssertTrue(asleep.note?.hasPrefix("97% of 7 h 30 min observed") == true, asleep.note ?? "")
        XCTAssertEqual(s.rows.first { $0.id == "difference" }?.value, "+12 bpm")
        let dip = try XCTUnwrap(s.rows.first { $0.id == "dip" })
        XCTAssertEqual(dip.value, "18.8%")
        XCTAssertEqual(dip.note, "Awake minus asleep, as a percentage of the awake median")
        let footnote = try XCTUnwrap(s.footnote)
        XCTAssertTrue(footnote.contains("not independent"))
        XCTAssertTrue(footnote.contains("Daily rhythm is estimated from timing only"))
    }

    @MainActor
    func testTheCoachReadsTheSheetsOwnRowsAndSaysWhenTheContextIsStale() throws {
        let contextDay = try makeContextDay(try documentJSON(dayNight: dayNightJSON, pulse: pulseJSON))
        let text = CoachServerContext.describe(state: .available(contextDay), metric: .restingHeartRate, day: day)
        XCTAssertTrue(text.contains("Awake and asleep heart rate:"), text)
        XCTAssertTrue(text.contains("  • Awake median: 64 bpm ("), text)
        XCTAssertFalse(text.contains("NOTE:"), text)
        let stale = CoachServerContext.describe(state: .stale(contextDay), metric: .restingHeartRate, day: day)
        XCTAssertTrue(stale.contains("NOTE: This context was built from an earlier version"), stale)
        XCTAssertEqual(CoachServerContext.describe(state: .unavailable(.noData), metric: .hrvRmssd, day: day),
                       "The server has no measurement context for \(day).")
        XCTAssertEqual(CoachServerContext.metric(named: "HRV"), .hrvRmssd)
        XCTAssertNil(CoachServerContext.day("yesterday"))
        for question in ["why is my hrv low", "am i getting sick"] {
            let names = Set(CoachToolExecutor.definitions(for: question)
                .compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
            XCTAssertTrue(names.contains("get_measurement_context"), question)
        }
    }

    func testAMissingSideSaysWhyAndShowsNoNumber() throws {
        var dn = dayNightJSON
        dn["state"] = "partial"
        dn["sleep_median_bpm"] = NSNull()
        dn["difference_bpm"] = NSNull()
        dn["percent_dip"] = NSNull()
        dn["sleep_samples"] = 120
        dn["reasons"] = ["sleep_hr_insufficient"]
        let model = MeasurementContextDetailModel.build(day: try makeContextDay(try documentJSON(dayNight: dn)),
                                                        metric: .restingHeartRate, isStale: false, locale: gb)
        let s = try XCTUnwrap(section(model, "dayNightHeartRate"))
        let asleep = try XCTUnwrap(s.rows.first { $0.id == "asleep" })
        XCTAssertEqual(asleep.value, "Not available")
        XCTAssertTrue(asleep.note?.contains("Too little heart-rate data during sleep") == true, asleep.note ?? "")
        XCTAssertNil(s.rows.first { $0.id == "difference" })
        XCTAssertNil(s.rows.first { $0.id == "dip" })
    }

    // MARK: - Pulse episodes

    func testPulseEpisodesAreDescriptiveWithExposureAndThresholds() throws {
        let contextDay = try makeContextDay(try documentJSON(dayNight: dayNightJSON, pulse: pulseJSON))
        let p = try XCTUnwrap(contextDay.document?.pulseEpisodes)
        XCTAssertEqual(p.version, "pc-pulse-1")
        XCTAssertEqual(p.episodes.first?.medianBpm, 104.0)
        XCTAssertEqual(p.accelerationEvents.count, 3)

        let model = MeasurementContextDetailModel.build(day: contextDay, metric: .restingHeartRate, isStale: false,
                                                        locale: gb)
        let s = try XCTUnwrap(section(model, "pulseEpisodes"))
        func row(_ id: String) -> ContextDetailRow? { s.rows.first { $0.id == id } }
        XCTAssertEqual(row("exposure")?.value, "8 h 20 min")
        XCTAssertEqual(row("exposure")?.note, "6 h 40 min asleep \u{00B7} 1 h 40 min awake")
        XCTAssertEqual(row("high")?.value, "1 episode \u{00B7} 14 min")
        XCTAssertEqual(row("low")?.value, "None found")
        let episode = try XCTUnwrap(row("episode-sustained_high-\(episodeStart)"))
        XCTAssertEqual(episode.title, "Sustained high pulse, 02:10\u{2013}02:24")
        XCTAssertEqual(episode.value, "median 104 bpm \u{00B7} highest 112 bpm")
        XCTAssertEqual(episode.note, "while awake \u{00B7} 14 min \u{00B7} Cut short: a gap in the heart-rate data")
        XCTAssertEqual(row("accelerations")?.value, "3")
        XCTAssertEqual(row("accelerations")?.note, "0.4 per hour asleep \u{00B7} 0.6 per hour awake")
        XCTAssertEqual(row("threshold-high")?.value, "\u{2265} 100 bpm")
        XCTAssertEqual(row("threshold-high")?.note, "Ends below 95 bpm")
        XCTAssertEqual(row("threshold-low")?.value, "\u{2264} 40 bpm")
        XCTAssertEqual(row("threshold-duration")?.value, "10 min")
        XCTAssertTrue(s.footnote?.contains("not a heart-rhythm classification") == true)
        XCTAssertTrue(s.footnote?.contains("no cause is attributed") == true)
        // Version and thresholds sit in Diagnostics.
        XCTAssertEqual(model.diagnostics.first { $0.id == "d-pulse" }?.value, "pc-pulse-1 supported")
        // Not on the HRV page.
        let hrv = MeasurementContextDetailModel.build(day: contextDay, metric: .hrvRmssd, isStale: false, locale: gb)
        XCTAssertNil(section(hrv, "pulseEpisodes"))
        XCTAssertNil(section(hrv, "dayNightHeartRate"))
        // No clinical or inferential wording.
        for text in model.allText {
            XCTAssertNil(W.containsForbiddenTerm(text), text)
            for clinical in ["tachy", "brady", "arrhythm", "fibrillation", "afib", "apnea"] {
                XCTAssertFalse(text.lowercased().contains(clinical), text)
            }
        }
    }

    func testAnUnevaluatedCountIsNotZero() {
        XCTAssertEqual(W.episodeCount(nil, seconds: nil), "Not evaluated")
        XCTAssertEqual(W.episodeCount(0, seconds: 0), "None found")
        XCTAssertEqual(W.episodeCount(2, seconds: 1500), "2 episodes \u{00B7} 25 min")
    }

    // MARK: - Breathing after a bout

    func testRespiratoryReturnReachesTheHistoryRow() throws {
        let history = PhysiologyContextRepository.parseHistory(
            ["bouts": [try boutJSON(respiratory: respiratoryJSON(state: "returned"))], "episodes": [], "daily_values": []],
            from: "2026-09-02", to: day, deviceId: "whoop-TEST", mode: .retrospective, fetchedAtMs: 0)
        let bout = try XCTUnwrap(history.bouts.first)
        let r = try XCTUnwrap(bout.recovery?.respiratoryRecovery)
        XCTAssertEqual(r.method, "pc-resp-recovery-1")
        XCTAssertEqual(r.referenceBpm, 14.2)
        XCTAssertEqual(r.observations.count, 2)
        let model = PhysiologyContextHistoryModel.build(history, metric: .restingHeartRate,
                                                        zone: TimeZone(identifier: tz)!, locale: gb)
        XCTAssertEqual(model.bouts.first?.breathing,
                       "Breathing rate back near the earlier level between 6 min and 12 min after (14.2 br/min)")
        for text in model.allText { XCTAssertNil(W.containsForbiddenTerm(text), text) }
    }

    func testRespiratoryReturnStates() throws {
        func decoded(_ json: [String: Any]) throws -> PC.RespiratoryRecovery {
            try PC.decoder().decode(PC.RespiratoryRecovery.self, from: JSONSerialization.data(withJSONObject: json))
        }
        XCTAssertEqual(W.respiratoryReturn(try decoded(respiratoryJSON(state: "returned_by", lastAbove: nil, at: nil, by: 240)),
                                           locale: gb),
                       "Breathing rate already near the earlier level at the first reading, 4 min after (14.2 br/min)")
        XCTAssertEqual(W.respiratoryReturn(try decoded(respiratoryJSON(state: "not_returned", lastAbove: nil, at: nil)),
                                           locale: gb),
                       "Breathing rate not back near the earlier level within 30 min after (14.2 br/min)")
        XCTAssertEqual(W.respiratoryReturn(try decoded(respiratoryJSON(state: "unknown", lastAbove: nil, at: nil,
                                                                       reasons: ["respiratory_reference_unavailable"])),
                                           locale: gb),
                       "Breathing rate afterwards unknown: no breathing-rate level from before the activity")
    }

    // MARK: - Old documents and member failures

    func testAnOlderDocumentHasNoneOfTheNewSections() throws {
        // A document stored before spec-02: the engine's output without the members spec-02 added.
        var older = try documentJSON()
        older["pulse_episodes"] = nil
        if var sleep = older["sleep"] as? [String: Any] {
            sleep["day_night_heart_rate"] = nil
            older["sleep"] = sleep
        }
        let contextDay = try makeContextDay(older)
        XCTAssertNil(contextDay.document?.pulseEpisodes)
        XCTAssertNil(contextDay.document?.dayNightHeartRate)
        XCTAssertNotNil(contextDay.document?.full)
        let model = MeasurementContextDetailModel.build(day: contextDay, metric: .restingHeartRate, isStale: false,
                                                        locale: gb)
        XCTAssertNil(section(model, "pulseEpisodes"))
        XCTAssertNil(section(model, "dayNightHeartRate"))
        let history = PhysiologyContextRepository.parseHistory(
            ["bouts": [try boutJSON(respiratory: nil)]], from: "2026-09-02", to: day, deviceId: "whoop-TEST",
            mode: nil, fetchedAtMs: 0)
        XCTAssertEqual(history.bouts.count, 1)
        XCTAssertNil(PhysiologyContextHistoryModel.build(history, metric: .restingHeartRate,
                                                         zone: TimeZone(identifier: tz)!, locale: gb).bouts.first?.breathing)
    }

    func testAMalformedSpec02MemberNeverCostsItsCarrier() throws {
        let object = try documentJSON(dayNight: ["state": "supported"], pulse: ["version": 3],
                                      bouts: [try boutJSON(respiratory: ["state": "returned"])])
        let document = try XCTUnwrap(PhysiologyContextDocument.decode(try JSONSerialization.data(withJSONObject: object)))
        XCTAssertNil(document.pulseEpisodes)
        XCTAssertNil(document.dayNightHeartRate)
        XCTAssertNotNil(document.sleep, "the sleep summary survives a malformed day/night member")
        XCTAssertEqual(document.bouts.count, 1, "the bout survives a malformed respiratory return")
        XCTAssertNil(document.bouts.first?.recovery?.respiratoryRecovery)
        XCTAssertNotNil(document.full)
        XCTAssertEqual(Set(document.undecodedMembers),
                       ["pulse_episodes", "sleep.day_night_heart_rate", "bouts.recovery.respiratory_recovery"])
    }
}

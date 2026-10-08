import XCTest
import StrandAnalytics
@testable import Strand

/// Spec-02 readback for `daily.sleep_features` (docs/spec-02/CONTRACT.md §2, §5): producer-shaped JSON →
/// `HostedDayResult` → the shared `SleepFeatureDocument` → `SleepFeatureDisplayModel` / `SleepFeatureSectionPlan`.
///
/// Pinned here:
///   • the section-hiding regression: with BOTH `sleep_features` and `sleep_analytics_v1` on the day, regularity,
///     stage physiology, settling, breathing and the spec-02 chapters still render; only continuity and
///     architecture step aside (and come back when the analytics document is absent);
///   • an old document without any spec-02 key still decodes and renders as before;
///   • every new value reaches the presentation model exactly as persisted (display formatting only), with its
///     coverage and method version; an unavailable block shows its reason and never a placeholder number;
///   • the decoder accepts the CONTRACT §5.4 phase-relation keys and a single-`reason` phase gate.
final class Spec02SleepFeaturesReadbackTests: XCTestCase {

    // MARK: - Fixtures

    /// The pre-spec-02 realistic document (no new key anywhere).
    static func oldDocumentJSON() throws -> [String: Any] {
        let data = try XCTUnwrap(SleepFeatureDocumentTests.realisticFixture.data(using: .utf8))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The same night with every spec-02 block a producer publishes: available, partial and withheld cases with
    /// realistic numbers.
    static func spec02DocumentJSON() throws -> [String: Any] {
        var doc = try oldDocumentJSON()
        var nights = try XCTUnwrap(doc["nights"] as? [[String: Any]])
        var night = nights[0]

        var resp = try XCTUnwrap(night["respiratory_variability"] as? [String: Any])
        resp["method_version"] = "resp-variability-2"
        resp["supported_range"] = ["detector_band_bpm": [6, 24], "min_peak_spacing_s": 2.5,
                                   "display_rate_range_bpm": [8, 25], "source": "SleepStager.respBreathTrack"]
        resp["interval_distribution"] = [
            "status": "available", "reasons": [], "n_intervals": 6120,
            "median_s": 4.25, "iqr_s": 0.6, "p05_s": 3.41, "p10_s": 3.62, "p25_s": 3.98,
            "p75_s": 4.58, "p90_s": 4.97, "p95_s": 5.22,
            "source": "consecutive_intervals_within_usable_runs",
        ]
        resp["stable_modulation"] = [
            "status": "partial", "reasons": ["thin_data"], "definition_version": "stable-resp-modulation-1",
            "criteria": ["max_cv_interval": 0.15, "min_run_min": 5],
            "stable_minutes": 250.0, "evaluated_minutes": 390.0, "unknown_minutes": 42.0,
            "stable_fraction_of_evaluated": 0.641, "stable_fraction_of_night": 0.521,
        ]
        var stages = try XCTUnwrap(resp["stage_conditioned"] as? [String: Any])
        var deep = try XCTUnwrap(stages["deep"] as? [String: Any])
        deep["sd_interval_s"] = 0.31
        deep["rmssd_interval_s"] = 0.28
        deep["median_interval_s"] = 4.62
        deep["iqr_interval_s"] = 0.44
        stages["deep"] = deep
        resp["stage_conditioned"] = stages
        night["respiratory_variability"] = resp

        night["prv_nonlinear"] = [
            "status": "available", "reasons": [], "method_version": "prv-nonlinear-1", "neurokit2": "0.2.13",
            "source": "prv_optical", "secondary": true,
            "config": ["segment_beats": 300, "sampen_dimension": 2, "sampen_tolerance_sd": 0.2,
                       "dfa_scales": [4, 16], "min_segments": 3, "dfa_overlap": false, "max_segments": 24],
            "segments_used": 12, "segments_rejected": 3, "segments_available": 40, "segments_evaluated": 15,
            "sample_entropy": ["median": 1.42, "iqr": 0.21, "segments": 12],
            "dfa_alpha1": ["median": 0.98, "iqr": 0.12, "segments": 12],
        ]

        var thermal = try XCTUnwrap(night["thermal"] as? [String: Any])
        thermal["observed_skin_temp_rhythm"] = [
            "status": "available", "reasons": [],
            "mesor_c": 33.42, "amplitude_c": 0.61, "acrophase_h": 3.4, "fit_quality": 0.62,
            "is": 0.58, "iv": 0.71, "daily_amplitude_c": 0.74, "phase_stability_h": 0.9,
            "notes": ["acrophase is skin-temperature acrophase"],
            "method_version": "skin-temp-rhythm-1", "history_revision_digest": "sha256:rhythm",
            "qualifying_days": 6, "days_evaluated": 9,
            "coverage": ["day_hours_supported": 62, "night_hours_supported": 48,
                         "quadrants_observed": [true, true, true, true]],
            "uncertainty": ["acrophase_se_h": 0.6, "amplitude_se_c": 0.08, "method": "cosinor_delta"],
            "phase_status": ["status": "available"],
            "iv_definition": "consecutive_valid_hour_pairs_across_midnight",
            "phase_relations": [
                "hr_minus_temp_acrophase_h": ["status": "available", "reasons": [], "a_label": "hr_acrophase",
                                              "a_h": 15.2, "b_label": "temp_acrophase", "b_h": 3.4,
                                              "difference_h": -0.2, "support_days": 6],
                "sleep_midpoint_minus_temp_acrophase_h": ["status": "withheld", "reasons": ["insufficient_days"]],
            ],
            "phase_drift": [
                "status": "available", "reasons": [], "method": "utc_linear", "utc_drift_h_per_day": 0.21,
                "days_used": 6,
                "daily_phases": [["day": "2026-09-28", "acrophase_utc_h": 10.4, "acrophase_local_h": 3.4,
                                  "utc_offset_h": -7]],
                "clock_changes": [["day": "2026-09-30", "from_offset_h": -7, "to_offset_h": -4, "kind": "timezone"]],
                "observed_realignment": ["status": "available", "reasons": [], "clock_shift_h": 3,
                                         "utc_phase_change_h": -1.8, "days_since_change": 3,
                                         "fraction_realigned": 0.6],
            ],
        ]
        night["thermal"] = thermal
        nights[0] = night
        doc["nights"] = nights

        doc["rest_activity_rhythm"] = [
            "status": "withheld", "reasons": ["movement_history_unavailable"], "method_version": "rest-activity-1",
            "signal": "gravity_movement_seconds_per_minute", "epoch_seconds": 3600,
            "is": NSNull(), "iv": NSNull(), "l5": NSNull(), "m10": NSNull(), "ra": NSNull(), "days_used": 0,
        ]
        doc["rebound"] = [
            "status": "available", "reasons": [], "definition_version": "sleep-rebound-1",
            "history_revision_digest": "sha256:rebound",
            "personal_reference": ["median_asleep_min": 425.0, "median_awake_min": 32.0, "nights": 24],
            "rules": ["short_below_fraction": 0.85, "fragmented_awake_above_fraction": 1.5],
            "after_short": ["pairs": 4,
                            "next_night_asleep_diff_min": ["median": 28.0, "iqr": 40.0],
                            "next_night_awake_diff_min": ["median": -5.0, "iqr": 9.0]],
            "after_fragmented": ["pairs": 0],
            "notes": "descriptive",
        ]
        return doc
    }

    static func decode(_ json: [String: Any]) throws -> SleepFeatureDocument {
        let data = try JSONSerialization.data(withJSONObject: json)
        return try JSONDecoder().decode(SleepFeatureDocument.self, from: data)
    }

    /// The analytics document's minimal current fixture (another suite's), so both documents ride on one day.
    static func hosted(features: [String: Any]?, analytics: Bool) -> HostedDayResult? {
        var daily: [String: Any] = ["sleep_total_min": 414]
        if let features { daily["sleep_features"] = features }
        if analytics { daily["sleep_analytics_v1"] = SleepAnalyticsSectionTests.fullDocumentJSON() }
        return HostedDayResult(day: "2026-10-03", object: ["result_revision": "sha256:r", "daily": daily, "sleep": []])
    }

    private func makePlan(_ json: [String: Any], analytics: Bool) throws -> SleepFeatureSectionPlan {
        let result = try XCTUnwrap(Self.hosted(features: json, analytics: analytics))
        let document = try XCTUnwrap(result.sleepFeatures)
        XCTAssertEqual(result.sleepAnalytics != nil, analytics)
        let night = try XCTUnwrap(document.night(matchingStart: nil, end: nil))
        return SleepFeatureSectionPlan(document: document, night: night, analyticsPresent: result.sleepAnalytics != nil)
    }

    private func model(_ json: [String: Any], analytics: Bool = true) throws -> SleepFeatureDisplayModel {
        let document = try Self.decode(json)
        let night = try XCTUnwrap(document.night(matchingStart: nil, end: nil))
        return SleepFeatureDisplayModel(document: document, night: night, analyticsPresent: analytics)
    }

    private func row(_ model: SleepFeatureDisplayModel, _ chapter: SleepFeatureCards.Chapter,
                     _ label: String) -> SleepFeatureDisplayModel.Row? {
        model.rows(for: chapter).first { $0.label == label }
    }

    // MARK: - The section-hiding regression

    func testBothDocumentsPresentStillRenderTheFeatureChapters() throws {
        let plan = try makePlan(Self.spec02DocumentJSON(), analytics: true)
        XCTAssertFalse(plan.isEmpty, "sleep_analytics_v1 must not hide the whole Sleep details section")
        XCTAssertEqual(plan.chapters, [.regularity, .physiology, .settling, .breathing,
                                       .temperatureRhythm, .restActivityRhythm, .rebound, .prvResearch])
        // Continuity / architecture belong to the analytics section: never shown twice.
        XCTAssertFalse(plan.chapters.contains(.continuity))
        XCTAssertFalse(plan.chapters.contains(.architecture))
        XCTAssertFalse(plan.headline.contains { $0.label == "Awake in bed" || $0.label == "Longest stretch" })
        XCTAssertEqual(plan.headline.map(\.label), ["Regularity", "Breathing (est.)", "Lowest HR after"])
        XCTAssertEqual(plan.headline.map(\.value), ["62", "13.5", "18m"])
    }

    func testWithoutTheAnalyticsDocumentContinuityAndArchitectureStillRender() throws {
        let plan = try makePlan(Self.spec02DocumentJSON(), analytics: false)
        XCTAssertEqual(plan.chapters, [.continuity, .regularity, .architecture, .physiology, .settling, .breathing,
                                       .temperatureRhythm, .restActivityRhythm, .rebound, .prvResearch])
        XCTAssertEqual(plan.headline.map(\.label), ["Awake in bed", "Longest stretch", "Regularity"])
        XCTAssertEqual(plan.headline.map(\.value), ["18m", "42m", "62"])
    }

    func testAnOldDocumentWithoutNewKeysDecodesAndRendersAsBefore() throws {
        let old = try Self.oldDocumentJSON()
        let document = try Self.decode(old)
        let night = try XCTUnwrap(document.nights.first)
        XCTAssertNil(document.rebound)
        XCTAssertNil(document.restActivityRhythm)
        XCTAssertNil(night.prvNonlinear)
        XCTAssertNil(night.respiratoryVariability?.intervalDistribution)
        XCTAssertNil(night.respiratoryVariability?.stableModulation)
        XCTAssertNil(night.respiratoryVariability?.supportedRange)
        XCTAssertNil(night.thermal?.observedSkinTempRhythm?.methodVersion)

        for analytics in [true, false] {
            let plan = try makePlan(old, analytics: analytics)
            XCTAssertTrue(plan.chapters.contains(.regularity))
            XCTAssertTrue(plan.chapters.contains(.physiology))
            XCTAssertTrue(plan.chapters.contains(.settling))
            XCTAssertTrue(plan.chapters.contains(.breathing))
            XCTAssertEqual(plan.chapters.contains(.continuity), !analytics)
            XCTAssertFalse(plan.chapters.contains(.prvResearch))
            XCTAssertFalse(plan.chapters.contains(.rebound))
            XCTAssertFalse(plan.chapters.contains(.restActivityRhythm))
        }
        // The old document's withheld rhythm shows its reason, never numbers.
        let m = try model(old)
        XCTAssertEqual(m.summary(for: .temperatureRhythm)?.line,
                       "Not available: needs several days of full-day temperature")
        // The old breathing rows are still there, unchanged.
        XCTAssertEqual(row(m, .breathing, "Rate (estimated)")?.value, "13.5 br/min")
        XCTAssertEqual(row(m, .breathing, "Breath-interval variation (CV)")?.value, "8%")
        XCTAssertEqual(row(m, .breathing, "Coverage")?.value, "90%")
        XCTAssertNil(row(m, .breathing, "Typical breath interval"), "absent block → no row, never a placeholder")
    }

    // MARK: - Round trip: persisted values reach the model exactly

    func testBreathingRoundTrip() throws {
        let m = try model(Self.spec02DocumentJSON())
        XCTAssertEqual(m.summary(for: .breathing)?.line,
                       "14 br/min estimated · 64% of evaluated time with steady breathing rhythm")
        XCTAssertEqual(row(m, .breathing, "Breath-interval SD")?.value, "0.19 s")
        XCTAssertEqual(row(m, .breathing, "Breath-interval RMSSD")?.value, "0.21 s")
        let typical = try XCTUnwrap(row(m, .breathing, "Typical breath interval"))
        XCTAssertEqual(typical.value, "4.25 s (IQR 0.60 s)")
        XCTAssertEqual(typical.note, "From 6,120 consecutive breath intervals inside usable stretches")
        XCTAssertEqual(row(m, .breathing, "10th–90th percentile")?.value, "3.62 s – 4.97 s")
        XCTAssertEqual(row(m, .breathing, "5th–95th percentile")?.value, "3.41 s – 5.22 s")
        // Stable modulation: components, never a score.
        XCTAssertEqual(row(m, .breathing, "Steady breathing rhythm")?.value, "4h 10m of 6h 30m evaluated (64%)")
        XCTAssertEqual(row(m, .breathing, "Not evaluated")?.value, "42m")
        XCTAssertEqual(row(m, .breathing, "Share of the whole night")?.value, "52%")
        XCTAssertTrue(m.rows(for: .breathing).contains { $0.label == "Definition" && $0.value == "stable-resp-modulation-1" })
        // Per-stage rate and variability.
        XCTAssertEqual(row(m, .breathing, "Deep (est.)")?.value,
                       "12.9 br/min · SD 0.31 s · RMSSD 0.28 s · median 4.62 s (IQR 0.44 s)")
        XCTAssertEqual(row(m, .breathing, "Deep (est.)")?.note, "11 windows")
        XCTAssertEqual(row(m, .breathing, "Light (est.)")?.value, "13.3 br/min")
        // Supported range provenance + method version.
        XCTAssertEqual(row(m, .breathing, "Supported range")?.value, "detected 6–24 br/min · shown 8–25 br/min")
        XCTAssertEqual(row(m, .breathing, "Source")?.value, "Estimated from the heart-rate rhythm, not measured airflow")
        XCTAssertTrue(m.rows(for: .breathing).contains { $0.label == "Definition" && $0.value == "resp-variability-2" })
        // No clinical respiratory wording anywhere.
        for r in m.rows(for: .breathing) {
            for text in [r.label, r.value, r.note ?? ""] {
                XCTAssertNil(SleepFeatureWording.forbiddenTerms.first { text.lowercased().contains($0) }, text)
            }
        }
    }

    func testAWithheldSubBlockShowsItsReasonNotANumber() throws {
        var json = try Self.spec02DocumentJSON()
        var nights = try XCTUnwrap(json["nights"] as? [[String: Any]])
        var resp = try XCTUnwrap(nights[0]["respiratory_variability"] as? [String: Any])
        resp["interval_distribution"] = ["status": "withheld", "reasons": ["no_adjacent_pairs_within_runs"],
                                         "n_intervals": 0, "median_s": NSNull()]
        nights[0]["respiratory_variability"] = resp
        json["nights"] = nights
        let m = try model(json)
        XCTAssertEqual(row(m, .breathing, "Typical breath interval")?.value,
                       "Not available: no consecutive breaths to compare")
        XCTAssertNil(row(m, .breathing, "10th–90th percentile"))
    }

    func testSecondaryPrvStatisticsRoundTrip() throws {
        let m = try model(Self.spec02DocumentJSON())
        XCTAssertEqual(m.summary(for: .prvResearch)?.line, "Secondary · sample entropy 1.42 · DFA α1 0.98")
        XCTAssertEqual(row(m, .prvResearch, "Sample entropy")?.value, "1.42 (IQR 0.21)")
        XCTAssertEqual(row(m, .prvResearch, "Sample entropy")?.note, "Median over 12 segments")
        XCTAssertEqual(row(m, .prvResearch, "DFA α1")?.value, "0.98 (IQR 0.12)")
        XCTAssertEqual(row(m, .prvResearch, "Gap-free segments")?.value, "12 used · 3 rejected")
        XCTAssertEqual(row(m, .prvResearch, "Gap-free segments")?.note,
                       "Each 300 consecutive beats; nothing joined across gaps · 15 of 40 available segments evaluated (at most 24, spread over the night)")
        XCTAssertEqual(row(m, .prvResearch, "Parameters")?.value,
                       "m = 2 · r = 0.2 SD · DFA scales 4–16 beats, non-overlapping boxes")
        XCTAssertEqual(row(m, .prvResearch, "Definition")?.value, "prv-nonlinear-1 · NeuroKit2 0.2.13")
        let about = try XCTUnwrap(row(m, .prvResearch, "About this")?.value)
        XCTAssertTrue(about.contains("pulse-rate variability, not ECG"))
        XCTAssertTrue(about.contains("Secondary"))
    }

    func testAWithheldPrvBlockShowsTheProducerReason() throws {
        var json = try Self.spec02DocumentJSON()
        var nights = try XCTUnwrap(json["nights"] as? [[String: Any]])
        nights[0]["prv_nonlinear"] = ["status": "withheld", "reasons": ["compute_budget_exceeded"],
                                      "method_version": "prv-nonlinear-1", "neurokit2": "0.2.13",
                                      "source": "prv_optical", "secondary": true,
                                      "sample_entropy": ["median": NSNull(), "iqr": NSNull(), "segments": 0]]
        json["nights"] = nights
        let m = try model(json)
        XCTAssertEqual(m.summary(for: .prvResearch)?.line, "Not available: took too long to compute this time")
        XCTAssertNil(row(m, .prvResearch, "Sample entropy"))
        XCTAssertEqual(SleepFeatureWording.reason("no_rr_beats"), "no beats recorded this night")
        XCTAssertEqual(SleepFeatureWording.reason("not_main_night"), "does not apply to this night")
    }

    func testSkinTemperatureRhythmRoundTrip() throws {
        let m = try model(Self.spec02DocumentJSON())
        XCTAssertEqual(m.summary(for: .temperatureRhythm)?.line, "Peak around 03:24 · amplitude 0.61 °C · 6 days")
        XCTAssertEqual(row(m, .temperatureRhythm, "Rhythm-adjusted mean (mesor)")?.value, "33.42 °C")
        XCTAssertEqual(row(m, .temperatureRhythm, "Amplitude")?.value, "0.61 °C ± 0.08 °C")
        XCTAssertEqual(row(m, .temperatureRhythm, "Peak time (acrophase)")?.value, "03:24 ± 0.6 h")
        XCTAssertEqual(row(m, .temperatureRhythm, "Days used")?.value, "6 of 9 checked")
        XCTAssertEqual(row(m, .temperatureRhythm, "Coverage")?.value,
                       "62 h daytime · 48 h night · 4 of 4 quarters of the day")
        XCTAssertEqual(row(m, .temperatureRhythm, "Temperature regularity (IS / IV)")?.value,
                       "IS 0.58 · IV 0.71")
        // CONTRACT §5.4 keys decode (the decoder used to read only the short keys).
        let hr = try XCTUnwrap(row(m, .temperatureRhythm, "Heart-rate peak minus temperature peak"))
        XCTAssertEqual(hr.value, "−0.2 h")
        XCTAssertEqual(hr.note, "Heart-rate peak 15:12 · Temperature peak 03:24 · 6 days")
        XCTAssertEqual(row(m, .temperatureRhythm, "Sleep midpoint minus temperature peak")?.value,
                       "Not available: not enough qualifying days yet")
        // Drift on elapsed time; the clock change is listed and never counted as drift.
        XCTAssertEqual(row(m, .temperatureRhythm, "Peak-time drift")?.value, "+0.2 h per day")
        XCTAssertEqual(row(m, .temperatureRhythm, "Clock changes")?.value, "2026-09-30 time-zone change (+3.0 h)")
        XCTAssertEqual(row(m, .temperatureRhythm, "Observed realignment")?.value, "60% of the clock shift after 3 days")
        XCTAssertEqual(row(m, .temperatureRhythm, "Definition")?.value, "skin-temp-rhythm-1")
        XCTAssertTrue(row(m, .temperatureRhythm, "About this")?.value.contains("Not core body temperature") == true)
    }

    func testAnUnavailablePhaseWithholdsTheTimeAndSaysWhy() throws {
        var json = try Self.spec02DocumentJSON()
        var nights = try XCTUnwrap(json["nights"] as? [[String: Any]])
        var thermal = try XCTUnwrap(nights[0]["thermal"] as? [String: Any])
        var rhythm = try XCTUnwrap(thermal["observed_skin_temp_rhythm"] as? [String: Any])
        // CONTRACT §5.4 writes the phase gate as {status, reason}.
        rhythm["phase_status"] = ["status": "unavailable", "reason": "zero_amplitude"]
        thermal["observed_skin_temp_rhythm"] = rhythm
        nights[0]["thermal"] = thermal
        json["nights"] = nights
        let document = try Self.decode(json)
        XCTAssertEqual(document.nights.first?.thermal?.observedSkinTempRhythm?.phaseStatus?.reasons, ["zero_amplitude"])
        XCTAssertEqual(document.nights.first?.thermal?.observedSkinTempRhythm?.phaseStatus?.status, .unavailable)
        let m = try model(json)
        XCTAssertEqual(row(m, .temperatureRhythm, "Peak time (acrophase)")?.value,
                       "Not available: the temperature rhythm was too flat to time")
        XCTAssertFalse(m.summary(for: .temperatureRhythm)?.line.contains("03:24") ?? true)
    }

    func testTheShortPhaseRelationKeysStillDecode() throws {
        let json = """
        {"hr_minus_temp": {"status": "available", "reasons": [], "difference_h": 1.5},
         "sleep_midpoint_minus_temp": {"status": "withheld", "reasons": ["insufficient_days"]}}
        """
        let relations = try JSONDecoder().decode(SleepPhaseRelations.self, from: Data(json.utf8))
        XCTAssertEqual(relations.hrMinusTemp?.differenceH, 1.5)
        XCTAssertEqual(relations.sleepMidpointMinusTemp?.reasons, ["insufficient_days"])
    }

    func testWithheldRestActivityRhythmShowsTheReasonAndNoPlaceholderNumbers() throws {
        let m = try model(Self.spec02DocumentJSON())
        XCTAssertEqual(m.summary(for: .restActivityRhythm)?.line, "Not available: needs several days of movement data")
        XCTAssertEqual(m.rows(for: .restActivityRhythm),
                       [.init("Why not available", "Needs several days of movement data"),
                        .init("Definition", "rest-activity-1")])
    }

    func testAvailableRestActivityRhythmRoundTrip() throws {
        var json = try Self.spec02DocumentJSON()
        json["rest_activity_rhythm"] = [
            "status": "available", "reasons": [], "method_version": "rest-activity-1",
            "signal": "gravity_movement_seconds_per_minute", "epoch_seconds": 3600,
            "is": 0.52, "iv": 0.83, "l5": 0.6, "m10": 7.4, "l5_start_h": 1.0, "m10_start_h": 9.5,
            "ra": 0.85, "days_used": 7,
        ]
        let m = try model(json)
        XCTAssertEqual(row(m, .restActivityRhythm, "Interdaily stability (IS)")?.value, "0.52")
        XCTAssertEqual(row(m, .restActivityRhythm, "Intradaily variability (IV)")?.value, "0.83")
        XCTAssertEqual(row(m, .restActivityRhythm, "Least active 5 h (L5)")?.value, "0.6 s/min")
        XCTAssertEqual(row(m, .restActivityRhythm, "Least active 5 h (L5)")?.note, "Starting around 01:00")
        XCTAssertEqual(row(m, .restActivityRhythm, "Most active 10 h (M10)")?.note, "Starting around 09:30")
        XCTAssertEqual(row(m, .restActivityRhythm, "Relative amplitude (RA)")?.value, "0.85")
        XCTAssertEqual(row(m, .restActivityRhythm, "Signal")?.value, "wrist movement seconds per minute, hourly")
    }

    func testReboundRoundTripIsDescriptive() throws {
        let m = try model(Self.spec02DocumentJSON())
        XCTAssertEqual(m.summary(for: .rebound)?.line, "+28m asleep after short")
        XCTAssertEqual(row(m, .rebound, "Your usual night")?.value, "7h 5m asleep · 32m awake")
        XCTAssertEqual(row(m, .rebound, "Your usual night")?.note, "Median of 24 nights")
        XCTAssertEqual(row(m, .rebound, "Night after a short night")?.value,
                       "+28m asleep (IQR 40m) · −5m awake (IQR 9m)")
        XCTAssertEqual(row(m, .rebound, "Night after a short night")?.note,
                       "4 pairs of nights, compared with your usual night")
        XCTAssertEqual(row(m, .rebound, "Night after a broken night")?.value, "No such nights in this period")
        // Pairs below the summary minimum: the count, never an invented median.
        var json = try Self.spec02DocumentJSON()
        var rebound = try XCTUnwrap(json["rebound"] as? [String: Any])
        rebound["after_fragmented"] = ["pairs": 2, "next_night_asleep_diff_min": ["median": NSNull(), "iqr": NSNull()]]
        rebound["reasons"] = ["after_fragmented_insufficient_pairs"]
        json["rebound"] = rebound
        XCTAssertEqual(row(try model(json), .rebound, "Night after a broken night")?.value, "2 pairs, too few to summarize")
        XCTAssertEqual(row(m, .rebound, "Definition")?.value, "sleep-rebound-1")
        XCTAssertTrue(row(m, .rebound, "About this")?.value.contains("Not a cause and not a prediction") == true)
    }

    // MARK: - Wording

    func testEverySleepFeatureReasonReadsAsPlainWords() {
        XCTAssertGreaterThanOrEqual(SleepFeatureWording.phrases.count, 50)
        for (code, phrase) in SleepFeatureWording.phrases.sorted(by: { $0.key < $1.key }) {
            XCTAssertFalse(phrase.isEmpty, code)
            XCTAssertFalse(phrase.contains("_"), "\(code): \"\(phrase)\" reads like a code")
            XCTAssertFalse(phrase.hasSuffix("."), code)
            XCTAssertLessThanOrEqual(phrase.count, 100, code)
            XCTAssertNil(SleepFeatureWording.forbiddenTerms.first { phrase.lowercased().contains($0) }, code)
            XCTAssertEqual(SleepFeatureWording.reason(code), phrase)
        }
        // Spec-02 rhythm / breathing / PRV codes are worded.
        for code in ["multi_day_history_not_requested", "insufficient_daytime_temperature", "zero_amplitude",
                     "unstable_phase", "mixed_devices", "insufficient_days", "not_applicable",
                     "no_adjacent_pairs_within_runs", "no_breath_intervals", "insufficient_segments"] {
            XCTAssertNotNil(SleepFeatureWording.phrases[code], code)
        }
        XCTAssertEqual(SleepFeatureWording.reason("brand_new_code"), "brand new code")
        XCTAssertEqual(SleepFeatureWording.reasonList(["zero_amplitude", "zero_amplitude", "thin_data"]),
                       "The temperature rhythm was too flat to time; based on little data")
    }

    func testNoNewSleepFeatureCopyMakesAClinicalOrCausalClaim() throws {
        let m = try model(Self.spec02DocumentJSON())
        var texts = m.chapters.flatMap { [$0.title, $0.line] } + m.headline.map(\.label)
        for chapter in SleepFeatureCards.Chapter.allCases {
            texts += m.rows(for: chapter).flatMap { [$0.label, $0.value, $0.note].compactMap { $0 } }
        }
        for text in texts {
            XCTAssertNil(SleepFeatureWording.forbiddenTerms.first { text.lowercased().contains($0) }, text)
            XCTAssertFalse(text.contains("/100"), "no composite 0–100 score: \(text)")
        }
    }
}

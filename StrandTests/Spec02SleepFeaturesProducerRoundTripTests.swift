import XCTest
import StrandAnalytics
@testable import Strand

/// Spec-02 producer → app round trip for `daily.sleep_features`. Python cannot run inside XCTest, so the document is
/// one the Python producer actually computed: `Resources/spec02_sleep_features_producer.json`, written and
/// re-checked by `Tools/InferenceWorker/tests/test_spec02_app_fixture.py` (golden discipline: that test recomputes it
/// and asserts equality). Here it rides under `daily.sleep_features` of a snapshot, next to a `sleep_analytics_v1`
/// document, through JSON bytes and the app's own decode path (`HostedDayResult`). The Sleep details model must show
/// the producer's values. Expected values are read from the raw JSON (an independent parse), not from the app decoder.
final class Spec02SleepFeaturesProducerRoundTripTests: XCTestCase {

    static func rawDocument() throws -> [String: Any] {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "spec02_sleep_features_producer",
                                                           withExtension: "json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    static func appModel() throws -> (raw: [String: Any], night: [String: Any], model: SleepFeatureDisplayModel,
                                      plan: SleepFeatureSectionPlan) {
        let raw = try rawDocument()
        let snapshot: [String: Any] = [
            "result_revision": "sha256:producer",
            "daily": ["sleep_features": raw, "sleep_analytics_v1": SleepAnalyticsSectionTests.fullDocumentJSON()],
            "sleep": [],
        ]
        let wire = try JSONSerialization.data(withJSONObject: snapshot)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: wire) as? [String: Any])
        let hosted = try XCTUnwrap(HostedDayResult(day: "2026-10-05", object: object))
        XCTAssertNotNil(hosted.sleepAnalytics)
        let document = try XCTUnwrap(hosted.sleepFeatures, "the app must decode the producer's document")
        let night = try XCTUnwrap(document.night(matchingStart: nil, end: nil))
        let rawNight = try XCTUnwrap((raw["nights"] as? [[String: Any]])?.first { ($0["is_nap"] as? Bool) == false })
        let analytics = hosted.sleepAnalytics != nil
        return (raw, rawNight,
                SleepFeatureDisplayModel(document: document, night: night, analyticsPresent: analytics),
                SleepFeatureSectionPlan(document: document, night: night, analyticsPresent: analytics))
    }

    private func row(_ m: SleepFeatureDisplayModel, _ c: SleepFeatureCards.Chapter, _ label: String) -> SleepFeatureDisplayModel.Row? {
        m.rows(for: c).first { $0.label == label }
    }

    private func num(_ o: [String: Any]?, _ k: String) throws -> Double {
        try XCTUnwrap(o?[k] as? Double ?? (o?[k] as? Int).map(Double.init), k)
    }

    func testEverySpec02ChapterRendersBesideTheAnalyticsDocument() throws {
        let (_, _, _, plan) = try Self.appModel()
        XCTAssertEqual(plan.chapters, [.regularity, .physiology, .settling, .breathing, .temperatureRhythm,
                                       .restActivityRhythm, .rebound, .prvResearch])
    }

    func testBreathingShowsTheProducerValues() throws {
        let (_, night, m, _) = try Self.appModel()
        let rv = try XCTUnwrap(night["respiratory_variability"] as? [String: Any])
        XCTAssertEqual(row(m, .breathing, "Breath-interval SD")?.value, SleepFeatureFormat.seconds(try num(rv, "sd_interval_s")))
        XCTAssertEqual(row(m, .breathing, "Breath-interval RMSSD")?.value,
                       SleepFeatureFormat.seconds(try num(rv, "rmssd_interval_s")))
        let d = rv["interval_distribution"] as? [String: Any]
        XCTAssertEqual(row(m, .breathing, "Typical breath interval")?.value,
                       "\(SleepFeatureFormat.seconds(try num(d, "median_s"))) (IQR \(SleepFeatureFormat.seconds(try num(d, "iqr_s"))))")
        XCTAssertEqual(row(m, .breathing, "Typical breath interval")?.note,
                       "From \(SleepFeatureFormat.count(Int(try num(d, "n_intervals")))) consecutive breath intervals inside usable stretches")
        XCTAssertEqual(row(m, .breathing, "10th–90th percentile")?.value,
                       "\(SleepFeatureFormat.seconds(try num(d, "p10_s"))) – \(SleepFeatureFormat.seconds(try num(d, "p90_s")))")
        let sm = rv["stable_modulation"] as? [String: Any]
        XCTAssertEqual(row(m, .breathing, "Steady breathing rhythm")?.value,
                       "\(SleepFeatureFormat.minutes(try num(sm, "stable_minutes"))) of "
                       + "\(SleepFeatureFormat.minutes(try num(sm, "evaluated_minutes"))) evaluated "
                       + "(\(SleepFeatureFormat.fractionPercent(try num(sm, "stable_fraction_of_evaluated"))))")
        XCTAssertEqual(row(m, .breathing, "Not evaluated")?.value, SleepFeatureFormat.minutes(try num(sm, "unknown_minutes")))
        let deep = (rv["stage_conditioned"] as? [String: Any])?["deep"] as? [String: Any]
        XCTAssertEqual(row(m, .breathing, "Deep (est.)")?.value,
                       "\(SleepFeatureFormat.value(try num(deep, "rate_bpm"), suffix: " br/min")) · "
                       + "SD \(SleepFeatureFormat.seconds(try num(deep, "sd_interval_s"))) · "
                       + "RMSSD \(SleepFeatureFormat.seconds(try num(deep, "rmssd_interval_s"))) · "
                       + "median \(SleepFeatureFormat.seconds(try num(deep, "median_interval_s"))) "
                       + "(IQR \(SleepFeatureFormat.seconds(try num(deep, "iqr_interval_s"))))")
        XCTAssertEqual(row(m, .breathing, "Supported range")?.value, "detected 6–24 br/min · shown 8–25 br/min")
        XCTAssertTrue(m.rows(for: .breathing).contains { $0.label == "Definition" && $0.value == rv["method_version"] as? String })
    }

    func testSecondaryPrvStatisticsShowTheProducerValues() throws {
        let (_, night, m, _) = try Self.appModel()
        let p = try XCTUnwrap(night["prv_nonlinear"] as? [String: Any])
        let se = p["sample_entropy"] as? [String: Any], dfa = p["dfa_alpha1"] as? [String: Any]
        XCTAssertEqual(row(m, .prvResearch, "Sample entropy")?.value,
                       SleepFeatureFormat.medianIqr(try num(se, "median"), try num(se, "iqr")))
        XCTAssertEqual(row(m, .prvResearch, "DFA α1")?.value,
                       SleepFeatureFormat.medianIqr(try num(dfa, "median"), try num(dfa, "iqr")))
        XCTAssertEqual(row(m, .prvResearch, "Gap-free segments")?.value,
                       "\(Int(try num(p, "segments_used"))) used · \(Int(try num(p, "segments_rejected"))) rejected")
        XCTAssertTrue(row(m, .prvResearch, "Gap-free segments")?.note?.contains(
            "\(Int(try num(p, "segments_evaluated"))) of \(Int(try num(p, "segments_available"))) available segments evaluated") == true)
        XCTAssertEqual(row(m, .prvResearch, "Definition")?.value,
                       "\(p["method_version"] as? String ?? "") · NeuroKit2 \(p["neurokit2"] as? String ?? "")")
    }

    func testTemperatureRhythmShowsTheProducerValues() throws {
        let (_, night, m, _) = try Self.appModel()
        let t = try XCTUnwrap((night["thermal"] as? [String: Any])?["observed_skin_temp_rhythm"] as? [String: Any])
        let u = t["uncertainty"] as? [String: Any]
        XCTAssertEqual(row(m, .temperatureRhythm, "Rhythm-adjusted mean (mesor)")?.value,
                       SleepFeatureFormat.celsius(try num(t, "mesor_c")))
        XCTAssertEqual(row(m, .temperatureRhythm, "Amplitude")?.value,
                       "\(SleepFeatureFormat.celsius(try num(t, "amplitude_c"))) ± \(SleepFeatureFormat.celsius(try num(u, "amplitude_se_c")))")
        XCTAssertEqual(row(m, .temperatureRhythm, "Peak time (acrophase)")?.value,
                       "\(SleepFeatureFormat.clockHours(try num(t, "acrophase_h"))) ± \(SleepFeatureFormat.hours(try num(u, "acrophase_se_h")))")
        XCTAssertEqual(row(m, .temperatureRhythm, "Temperature regularity (IS / IV)")?.value,
                       "IS \(String(format: "%.2f", try num(t, "is"))) · IV \(String(format: "%.2f", try num(t, "iv")))")
        let hr = (t["phase_relations"] as? [String: Any])?["hr_minus_temp"] as? [String: Any]
        XCTAssertEqual(row(m, .temperatureRhythm, "Heart-rate peak minus temperature peak")?.value,
                       SleepFeatureFormat.signedHours(try num(hr, "difference_h")))
        XCTAssertTrue(row(m, .temperatureRhythm, "Heart-rate peak minus temperature peak")?.note?
            .hasPrefix("Heart-rate peak \(SleepFeatureFormat.clockHours(try num(hr, "a_h")))") == true)
        let drift = t["phase_drift"] as? [String: Any]
        XCTAssertEqual(row(m, .temperatureRhythm, "Peak-time drift")?.value,
                       "\(SleepFeatureFormat.signedHours(try num(drift, "utc_drift_h_per_day"))) per day")
        XCTAssertEqual(row(m, .temperatureRhythm, "Days used")?.value,
                       "\(Int(try num(t, "qualifying_days"))) of \(Int(try num(t, "days_evaluated"))) checked")
    }

    func testRestActivityRhythmShowsTheProducerValues() throws {
        let (raw, _, m, _) = try Self.appModel()
        let r = try XCTUnwrap(raw["rest_activity_rhythm"] as? [String: Any])
        XCTAssertEqual(r["status"] as? String, "available")
        XCTAssertEqual(row(m, .restActivityRhythm, "Interdaily stability (IS)")?.value, String(format: "%.2f", try num(r, "is")))
        XCTAssertEqual(row(m, .restActivityRhythm, "Intradaily variability (IV)")?.value, String(format: "%.2f", try num(r, "iv")))
        XCTAssertEqual(row(m, .restActivityRhythm, "Least active 5 h (L5)")?.value, SleepFeatureFormat.movement(try num(r, "l5")))
        XCTAssertEqual(row(m, .restActivityRhythm, "Most active 10 h (M10)")?.value, SleepFeatureFormat.movement(try num(r, "m10")))
        XCTAssertEqual(row(m, .restActivityRhythm, "Relative amplitude (RA)")?.value, String(format: "%.2f", try num(r, "ra")))
        XCTAssertEqual(row(m, .restActivityRhythm, "Days used")?.value, "\(Int(try num(r, "days_used")))")
        XCTAssertEqual(row(m, .restActivityRhythm, "Signal")?.value, "wrist movement seconds per minute, hourly")
    }

    func testReboundShowsTheProducerValues() throws {
        let (raw, _, m, _) = try Self.appModel()
        let r = try XCTUnwrap(raw["rebound"] as? [String: Any])
        let ref = r["personal_reference"] as? [String: Any]
        XCTAssertEqual(row(m, .rebound, "Your usual night")?.value,
                       "\(SleepFeatureFormat.minutes(try num(ref, "median_asleep_min"))) asleep · "
                       + "\(SleepFeatureFormat.minutes(try num(ref, "median_awake_min"))) awake")
        let short = r["after_short"] as? [String: Any]
        let asleep = short?["next_night_asleep_diff_min"] as? [String: Any]
        let awake = short?["next_night_awake_diff_min"] as? [String: Any]
        XCTAssertEqual(row(m, .rebound, "Night after a short night")?.value,
                       "\(SleepFeatureFormat.signedMinutes(try num(asleep, "median"))) asleep (IQR \(SleepFeatureFormat.minutes(try num(asleep, "iqr")))) · "
                       + "\(SleepFeatureFormat.signedMinutes(try num(awake, "median"))) awake (IQR \(SleepFeatureFormat.minutes(try num(awake, "iqr"))))")
        XCTAssertEqual(row(m, .rebound, "Night after a short night")?.note,
                       "\(Int(try num(short, "pairs"))) pairs of nights, compared with your usual night")
        XCTAssertEqual(row(m, .rebound, "Definition")?.value, r["definition_version"] as? String)
    }
}

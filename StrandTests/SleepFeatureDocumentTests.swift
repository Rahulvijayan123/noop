import XCTest
import StrandAnalytics
@testable import Strand

/// App-side decode tests for the sleep-features shared document (spec-25 §7.3 / §10 and
/// docs/SLEEP_FEATURES_CONTRACT.md section 8 "App: decode tests ... HostedDayResult
/// sleep_features decode non-fatal; card rendering smoke").
///
/// What is pinned here:
///   • the exact wire shape decodes into the typed values the Sleep page renders (so a rename on
///     either the Python serializer or this schema is a failing test, not a silent nil day);
///   • malformed / partial / future-schema payloads decode to nil-or-partial and NEVER crash or
///     fail the whole day (contract section 2: "missing/malformed/future schema → nil, day
///     intact");
///   • a hosted result without the `sleep_features` key yields nil (feature-off, byte-identical
///     to a build with no enrichment).
final class SleepFeatureDocumentTests: XCTestCase {

    private func decode(_ json: String) -> SleepFeatureDocument? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SleepFeatureDocument.self, from: data)
    }

    // MARK: - Realistic fixture (extended from the contract §2 response example)

    func testDecodesRealisticFixture() throws {
        let doc = try XCTUnwrap(decode(Self.realisticFixture))

        XCTAssertEqual(doc.schemaVersion, 1)
        XCTAssertEqual(doc.algorithmVersion, "nara-sleep-features-1")
        XCTAssertEqual(doc.status, .partial)
        XCTAssertEqual(doc.statusReasons, ["onset_edge_unobserved"])

        let night = try XCTUnwrap(doc.nights.first)
        XCTAssertEqual(night.nightId, "night-2026-10-03-main")
        XCTAssertEqual(night.isNap, false)
        XCTAssertEqual(night.stageSource, "sleep-v2")
        XCTAssertEqual(night.stageAlgorithmVersion, "sleep-stager-v2")
        XCTAssertEqual(night.startAt, "2026-10-02T21:00:00Z")
        XCTAssertEqual(night.endAt, "2026-10-03T05:00:00Z")

        // continuity (A1)
        let continuity = try XCTUnwrap(night.continuity)
        XCTAssertEqual(continuity.tibMin ?? -1, 480, accuracy: 0.01)
        XCTAssertEqual(continuity.tstMin ?? -1, 414, accuracy: 0.01)
        XCTAssertEqual(continuity.solMin ?? -1, 22, accuracy: 0.01)
        XCTAssertEqual(continuity.wasoMin ?? -1, 18, accuracy: 0.01)
        XCTAssertEqual(continuity.terminalWakeMin ?? -1, 4, accuracy: 0.01)
        XCTAssertEqual(continuity.sleepEfficiencyPct ?? -1, 86.3, accuracy: 0.01)
        XCTAssertEqual(continuity.sleepMaintenanceEfficiencyPct ?? -1, 93.5, accuracy: 0.01)
        XCTAssertEqual(continuity.recurrentAwakenings ?? -1, 9)
        XCTAssertEqual(continuity.recurrentAwakeningIndexPerH ?? -1, 1.1, accuracy: 0.01)
        XCTAssertEqual(continuity.longestSleepBoutMin ?? -1, 42, accuracy: 0.01)
        XCTAssertEqual(continuity.meanSleepBoutMin ?? -1, 21, accuracy: 0.01)
        XCTAssertEqual(continuity.sfiYasaPerH ?? -1, 2.3, accuracy: 0.01)
        XCTAssertEqual(continuity.awakeningDuration?.count ?? -1, 9)
        XCTAssertEqual(continuity.awakeningDuration?.medianMin ?? -1, 2, accuracy: 0.01)

        // architecture (A2)
        let arch = try XCTUnwrap(night.architecture)
        XCTAssertEqual(arch.transitionCounts.count, 4)
        XCTAssertEqual(arch.transitionCounts.flatMap { $0 }.reduce(0, +), 86)
        XCTAssertEqual(arch.transitionProbabilities.count, 4)
        XCTAssertEqual(arch.remLatencyFromOnsetMin ?? -1, 82, accuracy: 0.01)
        XCTAssertEqual(arch.deepLatencyFromOnsetMin ?? -1, 11, accuracy: 0.01)
        XCTAssertEqual(arch.deepFrontLoadFraction ?? -1, 0.61, accuracy: 0.01)
        XCTAssertEqual(arch.remLateFraction ?? -1, 0.47, accuracy: 0.01)
        XCTAssertEqual(arch.entropyRateBitsPerTransition ?? -1, 0.85, accuracy: 0.01)
        XCTAssertEqual(arch.bouts(for: "rem")?.medianMin ?? -1, 18, accuracy: 0.01)
        XCTAssertEqual(arch.bouts(for: "deep")?.medianMin ?? -1, 14, accuracy: 0.01)
        XCTAssertEqual(arch.bouts(for: "deep")?.totalMin ?? -1, 96, accuracy: 0.01)
        XCTAssertEqual(arch.eligiblePairs ?? -1, 820)

        // regularity (A3)
        let regularity = try XCTUnwrap(doc.regularity)
        XCTAssertEqual(regularity.pairPolicy, "elapsed_24h")
        let sri7 = try XCTUnwrap(regularity.sri7d)
        XCTAssertEqual(sri7.status, .available)
        XCTAssertEqual(sri7.value ?? -1000, 62, accuracy: 0.01)
        XCTAssertEqual(sri7.pairedMinutes ?? -1, 6748)
        XCTAssertEqual(sri7.eligibleMinutes ?? -1, 9032)
        XCTAssertEqual(sri7.validDays ?? -1, 7)
        XCTAssertEqual(regularity.sri14d?.status, .partial)
        XCTAssertEqual(regularity.sri14d?.value, nil)
        let clock = try XCTUnwrap(regularity.clockProfile)
        XCTAssertEqual(clock.bedTime?.circadianMeanMin ?? -1, 1265, accuracy: 0.01)
        XCTAssertEqual(clock.sleepOnset?.circadianSdMin ?? -1, 21, accuracy: 0.01)
        XCTAssertEqual(clock.finalWake?.circadianSdMin ?? -1, 18, accuracy: 0.01)
        XCTAssertEqual(clock.adjacentNightPhaseShiftMin?.value ?? -1000, 12, accuracy: 0.01)

        // stage_physiology (A4)
        let phys = try XCTUnwrap(night.stagePhysiology)
        XCTAssertEqual(phys.stageSource, "sleep-v2")
        XCTAssertEqual(phys.light?.hrMedianBpm ?? -1, 58, accuracy: 0.01)
        XCTAssertEqual(phys.deep?.hrP10Bpm ?? -1, 51, accuracy: 0.01)
        XCTAssertEqual(phys.deep?.rmssdMs?.median ?? -1, 61.2, accuracy: 0.01)
        XCTAssertEqual(phys.deep?.rmssdMs?.iqr ?? -1, 9.8, accuracy: 0.01)
        XCTAssertEqual(phys.rem?.skinTempMedianC ?? -1, 31.1, accuracy: 0.01)
        XCTAssertEqual(phys.light?.thinData ?? true, false)

        // settling (A5)
        let settling = try XCTUnwrap(night.settling)
        XCTAssertEqual(settling.hrPreOnsetSlopeBpmMin ?? -1, -1.1, accuracy: 0.01)
        XCTAssertEqual(settling.hrEarlySleepSlopeBpmMin ?? -1, -0.6, accuracy: 0.01)
        XCTAssertEqual(settling.hrDropBpm ?? -1, 6.5, accuracy: 0.01)
        XCTAssertEqual(settling.hrSettlingLatencyMin ?? -1, 12, accuracy: 0.01)
        XCTAssertEqual(settling.hrCurve.count, 4)
        XCTAssertEqual(settling.hrCurve.first?.valid ?? false, true)
        XCTAssertEqual(settling.tempCurve.count, 4)
        XCTAssertEqual(settling.hrvEarlySleepCurve.first?.rmssdMs ?? -1, 72.4, accuracy: 0.01)

        // thermal (A6)
        let thermal = try XCTUnwrap(night.thermal)
        XCTAssertEqual(thermal.baselineC ?? -100, 29.4, accuracy: 0.01)
        XCTAssertEqual(thermal.earlySleepDeltaC ?? -100, 1.1, accuracy: 0.01)
        XCTAssertEqual(thermal.riseSlopeCMin ?? -100, 0.03, accuracy: 0.01)
        XCTAssertEqual(thermal.thermalTransition?.supported ?? false, true)
        XCTAssertEqual(thermal.thermalTransition?.onsetMin ?? -100, -8, accuracy: 0.01)
        XCTAssertEqual(thermal.thermalToSleepLatencyMin ?? -1000, 8, accuracy: 0.01)
        XCTAssertEqual(thermal.observedSkinTempRhythm?.status, .withheld)

        // respiratory_variability (A7)
        let resp = try XCTUnwrap(night.respiratoryVariability)
        XCTAssertEqual(resp.estimateSource, "rsa_derived_rr")
        XCTAssertEqual(resp.unobservedBreathIsNotApnea ?? false, true)
        XCTAssertEqual(resp.rateBpm ?? -1, 13.5, accuracy: 0.01)
        XCTAssertEqual(resp.cvInterval ?? -1, 0.08, accuracy: 0.01)
        XCTAssertEqual(resp.rmssdIntervalS ?? -1, 0.21, accuracy: 0.01)
        XCTAssertEqual(resp.intervalsValid ?? -1, 2240)
        XCTAssertEqual(resp.quality?.usableWindows ?? -1, 30)
        XCTAssertEqual(resp.stageConditioned["deep"]?.rateBpm ?? -1, 12.9, accuracy: 0.01)

        // metric_status + coverage
        XCTAssertEqual(night.metricStatus?.nightGate?.status, .partial)
        XCTAssertEqual(night.metricStatus?.moduleErrors, [])
        let coverage = try XCTUnwrap(night.coverage)
        XCTAssertEqual(coverage.knownFraction ?? -1, 0.97, accuracy: 0.01)
        XCTAssertEqual(coverage.validHrMin ?? -1, 462)
        XCTAssertEqual(coverage.sources?.hr ?? -1, 16632)

        // capabilities (B1 gate)
        XCTAssertEqual(doc.capabilities?.oxygenEvents?.ready, false)
        XCTAssertEqual(doc.capabilities?.oxygenEvents?.reason, "unverified_sparse_oxygen")
        XCTAssertEqual(doc.capabilities?.waveformStaging?.ready, false)
        XCTAssertEqual(doc.capabilities?.sleepecgShadow?.status, .notRun)

        // night matching helper
        let start = try XCTUnwrap(night.startAtUnix)
        let end = try XCTUnwrap(night.endAtUnix)
        XCTAssertEqual(doc.night(matchingStart: start + 60, end: end - 60)?.nightId, "night-2026-10-03-main")
        // No overlap still resolves to the longest non-nap night (the "main night" fallback).
        XCTAssertEqual(doc.night(matchingStart: start - 200_000, end: start - 100_000)?.nightId,
                       "night-2026-10-03-main")
    }

    // MARK: - Tolerant decoding (never a crash, day intact)

    func testMalformedMetricLeafNeverFailsDocument() throws {
        // A continuity leaf becomes a wrong type: the whole document (and the rest of the night)
        // must survive, with only that leaf nil.
        let json = Self.realisticFixture
            .replacingOccurrences(of: "\"waso_min\": 18.0", with: "\"waso_min\": \"garbage\"")
        let doc = try XCTUnwrap(decode(json))
        let night = try XCTUnwrap(doc.nights.first)
        XCTAssertNil(night.continuity?.wasoMin)
        XCTAssertEqual(night.continuity?.tstMin ?? -1, 414, accuracy: 0.01)
        XCTAssertEqual(night.continuity?.sleepMaintenanceEfficiencyPct ?? -1, 93.5, accuracy: 0.01)
    }

    func testMalformedWholeNightIsSkippedButValidNightsSurvive() throws {
        // One night is not an object at all; the valid night beside it still decodes.
        let doc = try XCTUnwrap(decode(Self.twoNightFixtureWithMalformedSecond))
        XCTAssertEqual(doc.nights.count, 1)
        XCTAssertEqual(doc.nights.first?.nightId, "night-2026-10-03-main")
    }

    func testPartialAndFutureSchemaNeverCrash() throws {
        // Future schema bump: unknown keys ignored, an unknown status becomes .unknown, missing
        // blocks stay nil.
        let future = """
        {"schema_version": 2, "algorithm_version": "nara-sleep-features-99",
         "status": "some_future_status", "status_reasons": ["new_reason"],
         "nights": [], "future_key": {"x": 1}}
        """
        let doc = try XCTUnwrap(decode(future))
        XCTAssertEqual(doc.schemaVersion, 2)
        XCTAssertEqual(doc.algorithmVersion, "nara-sleep-features-99")
        XCTAssertEqual(doc.status, .unknown)
        XCTAssertEqual(doc.statusReasons, ["new_reason"])
        XCTAssertEqual(doc.nights.count, 0)
        XCTAssertNil(doc.regularity)
        XCTAssertNil(doc.capabilities)

        // A minimal-but-valid document.
        let minimal = """
        {"schema_version": 1, "algorithm_version": "nara-sleep-features-1",
         "status": "available", "status_reasons": [], "nights": []}
        """
        XCTAssertNotNil(decode(minimal))

        // A night with almost everything absent still decodes (nil leaves, no crash).
        let sparseNight = """
        {"schema_version": 1, "algorithm_version": "nara-sleep-features-1",
         "status": "withheld", "status_reasons": ["no_nights"],
         "nights": [{"night_id": "n1"}], "regularity": {}}
        """
        let sparse = try XCTUnwrap(decode(sparseNight))
        XCTAssertEqual(sparse.nights.first?.nightId, "n1")
        XCTAssertNil(sparse.nights.first?.continuity)
        XCTAssertNotNil(sparse.regularity)
        XCTAssertNil(sparse.regularity?.sri7d)
    }

    func testNotAJSONObjectReturnsNil() {
        // Top-level not an object: decode returns nil (the caller treats it as feature-off).
        XCTAssertNil(decode("[1,2,3]"))
        XCTAssertNil(decode("\"just a string\""))
        XCTAssertNil(decode(""))
    }

    // MARK: - HostedDayResult wiring (spec 7.3 "decode in HostedDayResult ... day intact")

    func testPayloadWithoutSleepFeaturesYieldsNilAndDayIntact() {
        let object: [String: Any] = [
            "result_revision": "sha256:abc",
            "daily": ["sleep_total_min": 414, "sleep_efficiency": 0.91],
            "sleep": [
                ["id": "s1", "start_at": "2026-10-02T21:00:00Z", "end_at": "2026-10-03T05:00:00Z",
                 "is_nap": false, "efficiency": 0.91, "resting_hr_bpm": 52, "hrv_rmssd_ms": 61.2,
                 "stages": [["start": 1_000, "end": 1_200, "stage": "light"]]],
            ],
        ]
        let result = HostedDayResult(day: "2026-10-03", object: object)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.sleepFeatures)
        // The rest of the day survives (non-fatal decode).
        XCTAssertEqual(result?.daily.totalSleepMin ?? -1, 414)
        XCTAssertEqual(result?.resultRevision, "sha256:abc")
        XCTAssertEqual(result?.sleep.count, 1)
    }

    func testPayloadWithMalformedSleepFeaturesYieldsNilAndDayIntact() {
        let object: [String: Any] = [
            "result_revision": "sha256:abc",
            "daily": ["sleep_features": "not-an-object", "sleep_total_min": 400],
            "sleep": [],
        ]
        let result = HostedDayResult(day: "2026-10-03", object: object)
        XCTAssertNotNil(result)
        XCTAssertNil(result?.sleepFeatures)
        XCTAssertEqual(result?.daily.totalSleepMin ?? -1, 400)
    }

    func testPayloadWithSleepFeaturesDecodesOnHostedResult() throws {
        let raw = try XCTUnwrap(Self.realisticFixture.data(using: .utf8))
        let document = try XCTUnwrap(try JSONSerialization.jsonObject(with: raw) as? [String: Any])
        let object: [String: Any] = [
            "result_revision": "sha256:abc",
            "daily": ["sleep_features": document],
            "sleep": [],
        ]
        let result = HostedDayResult(day: "2026-10-03", object: object)
        let doc = try XCTUnwrap(result?.sleepFeatures)
        XCTAssertEqual(doc.nights.first?.nightId, "night-2026-10-03-main")
        XCTAssertEqual(doc.nights.first?.continuity?.tstMin ?? -1, 414, accuracy: 0.01)
        XCTAssertEqual(doc.capabilities?.oxygenEvents?.ready, false)
    }

    // MARK: - Fixtures

    /// A realistic document, extended from the contract §2 response example, exercising every
    /// typed block the Sleep page renders.
    private static let realisticFixture = """
    {
      "schema_version": 1,
      "algorithm_version": "nara-sleep-features-1",
      "status": "partial",
      "status_reasons": ["onset_edge_unobserved"],
      "nights": [
        {
          "night_id": "night-2026-10-03-main",
          "start_utc": "2026-10-02T21:00:00Z",
          "end_utc": "2026-10-03T05:00:00Z",
          "is_nap": false,
          "user_edited": false,
          "stage_source": "sleep-v2",
          "stage_algorithm_version": "sleep-stager-v2",
          "continuity": {
            "status": "partial", "reasons": ["onset_edge_unobserved"],
            "tib_min": 480.0, "tst_min": 414.0, "sol_min": 22.0,
            "sol_5min_run_min": 27.0, "spt_min": 432.0,
            "waso_min": 18.0, "terminal_wake_min": 4.0,
            "sleep_efficiency_pct": 86.3, "sleep_maintenance_efficiency_pct": 93.5,
            "recurrent_awakenings": 9, "recurrent_awakenings_60s_plus": 6,
            "recurrent_awakening_index_per_h": 1.1,
            "return_to_sleep_latency_median_min": 2.5,
            "awakening_duration": {"count": 9, "median_min": 2.0, "p90_min": 4.0, "max_min": 7.0},
            "longest_sleep_bout_min": 42.0, "mean_sleep_bout_min": 21.0,
            "sleep_bouts": {"count": 20},
            "sfi_yasa_per_h": 2.3,
            "yasa_stats": {"SFI": 2.3, "SOL": 22.0, "WASO": 18.0, "TST": 414.0}
          },
          "architecture": {
            "status": "partial", "reasons": ["onset_edge_unobserved"],
            "transition_counts": [[4, 3, 0, 0], [3, 28, 8, 0], [0, 9, 14, 4], [0, 0, 4, 9]],
            "transition_probabilities": [[0.5, 0.4, 0.0, 0.1], [0.1, 0.7, 0.1, 0.1],
                                          [0.0, 0.2, 0.7, 0.1], [0.0, 0.1, 0.2, 0.7]],
            "row_weights": [0.15, 0.5, 0.25, 0.1],
            "entropy_rate_bits_per_transition": 0.85,
            "bouts": {
              "wake": {"count": 10, "median_min": 1.5, "p90_min": 3.0, "max_min": 7.0, "total_min": 18.0},
              "light": {"count": 9, "median_min": 24.0, "p90_min": 46.0, "max_min": 60.0, "total_min": 216.0},
              "deep": {"count": 7, "median_min": 14.0, "p90_min": 20.0, "max_min": 26.0, "total_min": 96.0},
              "rem": {"count": 6, "median_min": 18.0, "p90_min": 30.0, "max_min": 34.0, "total_min": 102.0}
            },
            "rem_latency_from_onset_min": 82.0,
            "deep_latency_from_onset_min": 11.0,
            "deep_front_load_fraction": 0.61,
            "rem_late_fraction": 0.47,
            "eligible_pairs": 820, "excluded_pairs_uns": 14, "excluded_pairs_gap": 3,
            "sleep_period_third_known_fraction": 0.98
          },
          "stage_physiology": {
            "status": "available", "reasons": [],
            "stage_source": "sleep-v2", "model_dependent": true,
            "notes": "Stage-conditioned physiology is model-dependent.",
            "stages": {
              "wake": {
                "status": "partial", "reasons": ["no_windows"], "hr_median_bpm": 66.0,
                "hr_p10_bpm": 60.0, "hr_p90_bpm": 74.0,
                "rmssd_ms": {"median": 48.1, "iqr": 12.0, "windows": 1},
                "sdnn_ms": {"median": 55.2, "iqr": 14.0, "windows": 1},
                "resp_median_bpm": 14.0, "resp_variability_cv": 0.09,
                "skin_temp_median_c": 29.8, "skin_temp_mad_c": 0.2,
                "movement_events_per_h": null,
                "valid_min": 42, "windows": 1, "excluded_mixed_stage_min": 0.0,
                "thin_data": true
              },
              "light": {
                "status": "available", "reasons": [], "hr_median_bpm": 58.0,
                "hr_p10_bpm": 53.0, "hr_p90_bpm": 63.0,
                "rmssd_ms": {"median": 68.4, "iqr": 11.2, "windows": 6},
                "sdnn_ms": {"median": 74.1, "iqr": 12.5, "windows": 6},
                "resp_median_bpm": 13.2, "resp_variability_cv": 0.07,
                "skin_temp_median_c": 30.4, "skin_temp_mad_c": 0.3,
                "movement_events_per_h": null,
                "valid_min": 208, "windows": 6, "excluded_mixed_stage_min": 0.0,
                "thin_data": false
              },
              "deep": {
                "status": "available", "reasons": [], "hr_median_bpm": 54.0,
                "hr_p10_bpm": 51.0, "hr_p90_bpm": 57.0,
                "rmssd_ms": {"median": 61.2, "iqr": 9.8, "windows": 5},
                "sdnn_ms": {"median": 66.0, "iqr": 10.4, "windows": 5},
                "resp_median_bpm": 13.0, "resp_variability_cv": 0.06,
                "skin_temp_median_c": 30.9, "skin_temp_mad_c": 0.2,
                "movement_events_per_h": null,
                "valid_min": 160, "windows": 5, "excluded_mixed_stage_min": 0.0,
                "thin_data": false
              },
              "rem": {
                "status": "available", "reasons": [], "hr_median_bpm": 60.0,
                "hr_p10_bpm": 55.0, "hr_p90_bpm": 65.0,
                "rmssd_ms": {"median": 55.6, "iqr": 10.0, "windows": 5},
                "sdnn_ms": {"median": 60.8, "iqr": 11.0, "windows": 5},
                "resp_median_bpm": 13.8, "resp_variability_cv": 0.08,
                "skin_temp_median_c": 31.1, "skin_temp_mad_c": 0.2,
                "movement_events_per_h": null,
                "valid_min": 152, "windows": 5, "excluded_mixed_stage_min": 0.0,
                "thin_data": false
              }
            }
          },
          "settling": {
            "status": "partial", "reasons": ["thin_data"],
            "hr_pre_onset_slope_bpm_min": -1.1,
            "hr_early_sleep_slope_bpm_min": -0.6,
            "hr_drop_bpm": 6.5,
            "hr_nadir_latency_min": 18.0,
            "hr_settling_latency_min": 12.0,
            "hrv_early_sleep_curve": [
              {"ts": 1769997600, "rmssd_ms": 72.4, "pairs": 240, "coverage": 0.94},
              {"ts": 1769997900, "rmssd_ms": 75.1, "pairs": 238, "coverage": 0.93}
            ],
            "hrv_early_sleep_log_slope_per_min": 0.011,
            "hr_curve": [
              {"ts": 1769997000, "bpm": 71.0, "valid": true},
              {"ts": 1769997060, "bpm": 70.0, "valid": true},
              {"ts": 1769997120, "bpm": null, "valid": false},
              {"ts": 1769997180, "bpm": 64.0, "valid": true}
            ],
            "temp_curve": [
              {"ts": 1769997000, "celsius": 29.2, "valid": true},
              {"ts": 1769997060, "celsius": 29.3, "valid": true},
              {"ts": 1769997120, "celsius": null, "valid": false},
              {"ts": 1769997180, "celsius": 29.6, "valid": true}
            ]
          },
          "thermal": {
            "status": "partial", "reasons": ["no_detectable_transition"],
            "baseline_c": 29.4, "early_sleep_delta_c": 1.1,
            "rise_slope_c_min": 0.03, "peak_latency_min": 55.0, "pre_wake_slope_c_min": -0.02,
            "thermal_transition": {
              "onset_min": -8.0, "rss_single": 0.24, "rss_split": 0.15,
              "improvement_pct": 37.5, "post_slope_c_min": 0.012, "sustained_c": 0.55,
              "supported": true
            },
            "thermal_to_sleep_latency_min": 8.0,
            "observed_skin_temp_rhythm": {
              "status": "withheld", "reasons": ["multi_day_history_not_requested"],
              "mesor_c": null, "amplitude_c": null, "acrophase_h": null,
              "fit_quality": null, "is": null, "iv": null,
              "daily_amplitude_c": null, "phase_stability_h": null,
              "notes": ["acrophase is skin-temperature acrophase"]
            },
            "notes": ["Exploratory breakpoint feature: NOT an established sleep-onset detector."]
          },
          "respiratory_variability": {
            "status": "available", "reasons": [],
            "estimate_source": "rsa_derived_rr",
            "unobserved_breath_is_not_apnea": true,
            "algorithm_source": "resp-breath-track",
            "notes": "RSA-derived estimates; an unobserved breath is not an apnea.",
            "intervals_valid": 2240, "rate_bpm": 13.5,
            "sd_interval_s": 0.19, "cv_interval": 0.08, "rmssd_interval_s": 0.21,
            "valid_run_min": 372.0,
            "quality": {"usable_windows": 30, "total_windows": 32, "night_run_coverage": 0.9},
            "stage_conditioned": {
              "wake": {"rate_bpm": null, "cv_interval": null, "windows": 1},
              "light": {"rate_bpm": 13.3, "cv_interval": 0.07, "windows": 12},
              "deep": {"rate_bpm": 12.9, "cv_interval": 0.06, "windows": 11},
              "rem": {"rate_bpm": 14.2, "cv_interval": 0.09, "windows": 6}
            },
            "outlier_fraction_vs_personal": {
              "status": "withheld", "reasons": ["no_personal_baseline"], "fraction": null
            }
          },
          "metric_status": {
            "night_gate": {"status": "partial", "reasons": ["onset_edge_unobserved"]},
            "module_errors": []
          },
          "coverage": {
            "known_fraction": 0.97, "known_epoch_fraction": 0.97,
            "valid_hr_min": 462, "observed_hr_min": 470,
            "valid_temp_min": 448, "observed_temp_min": 452,
            "hr_gap_max_s": 12.0, "temp_gap_max_s": 40.0,
            "rr_rows": 21080, "rr_rejected_fraction": 0.03,
            "breath_intervals": 4100, "breath_run_min": 372.0,
            "overlap_seconds": 0.0,
            "observed_onset_edge": false, "observed_offset_edge": true,
            "max_unresolved_gap_s": 0.0,
            "sources": {"hr": 16632, "temp": 15210, "rr": 21080, "resp": 4100},
            "night_span_s": 28800.0
          }
        }
      ],
      "regularity": {
        "pair_policy": "elapsed_24h",
        "sri_7d": {"value": 62.0, "paired_minutes": 6748, "eligible_minutes": 9032,
                   "valid_days": 7, "status": "available", "reasons": []},
        "sri_14d": {"value": null, "paired_minutes": 11620, "eligible_minutes": 18200,
                    "valid_days": 11, "status": "partial", "reasons": ["insufficient_paired_minutes"]},
        "sri_30d": {"value": null, "paired_minutes": 0, "eligible_minutes": 0,
                    "valid_days": 0, "status": "withheld", "reasons": ["no_history"]},
        "pair_coverage_by_hour": [0, 0, 0, 0, 0, 0, 0, 0, 120, 300, 420, 440, 300, 220, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        "clock_profile": {
          "bed_time": {"circadian_mean_min": 1265.0, "circadian_sd_min": 19.0, "n": 7,
                       "status": "available", "reasons": []},
          "sleep_onset": {"circadian_mean_min": 1290.0, "circadian_sd_min": 21.0, "n": 7,
                          "status": "available", "reasons": []},
          "final_wake": {"circadian_mean_min": 300.0, "circadian_sd_min": 18.0, "n": 7,
                         "status": "available", "reasons": []},
          "midsleep": {"circadian_mean_min": 75.0, "circadian_sd_min": 17.0, "n": 7,
                       "status": "available", "reasons": []},
          "adjacent_night_phase_shift_min": {"value": 12.0, "n": 6, "status": "available",
                                             "reasons": []},
          "social_jetlag_min": {"value": null, "status": "withheld",
                                "reasons": ["workday_labels_unavailable"]},
          "dst_transition_days": 0
        },
        "status": "partial", "reasons": ["insufficient_paired_minutes"],
        "history_revision_digest": "sha256:digest"
      },
      "dependencies": {
        "yasa": "0.8.0", "numpy": "1.26.4", "scipy": "1.13.0", "neurokit2": "0.2.13",
        "sleepecg": "0.5.9", "config_version": "sleep-features-defaults-1",
        "config": {"continuity_known_fraction": 0.95, "entropy_min_pairs": 100, "history_days": 31}
      },
      "capabilities": {
        "oxygen_events": {"ready": false, "reason": "unverified_sparse_oxygen"},
        "waveform_staging": {"ready": false, "reason": "continuous_ppg_not_delivered"},
        "cvhr_screening": {"ready": false, "reason": "no_validated_port"},
        "ppg_autonomic_events": {"ready": false, "reason": "no_continuous_ppg"},
        "cpc_cycles": {"ready": false, "reason": "no_independent_respiratory_modulation_signal"},
        "sleepecg_shadow": {"status": "not_run", "reason": "candidate_lane_result_not_provided"}
      },
      "duration_ms": 412
    }
    """

    /// Same as `realisticFixture` but the second night is a non-object (must be skipped, not fatal).
    private static let twoNightFixtureWithMalformedSecond = """
    {
      "schema_version": 1,
      "algorithm_version": "nara-sleep-features-1",
      "status": "partial",
      "status_reasons": [],
      "nights": [
        {
          "night_id": "night-2026-10-03-main",
          "start_utc": "2026-10-02T21:00:00Z",
          "end_utc": "2026-10-03T05:00:00Z",
          "is_nap": false,
          "stage_source": "sleep-v2",
          "stage_algorithm_version": "sleep-stager-v2"
        },
        "this is not a night object"
      ],
      "regularity": {}
    }
    """
}

import Foundation
import StrandAnalytics

// MeasurementContextWording.swift — plain words and formatting for the physiology context screens
// (contracts.md §9, spec §16).
//
// Copy rules. Use "stable awake measurement", "recent walking", "insufficient context", "persistent change from
// historical reference", "provisional", "unverified". Never infer an illness, a medication effect or a
// psychological state: words like "calm", "stressed" or "recovered" never describe these states
// (`forbiddenTerms`, checked by `PhysiologyContextAppTests`). Machine reason codes stay in Diagnostics; the normal
// flow shows their plain-word meaning.

// MARK: - Which pages carry context

enum MeasurementContextPage {

    /// The context metric behind a metric page, for the pages that carry the card: HRV and resting heart rate
    /// from the strap. Every other page (and another source's HRV / resting HR) has none.
    static func metric(forCatalogKey key: String, source: String) -> PhysiologyContext.MetricKind? {
        guard source == "my-whoop" else { return nil }
        switch key {
        case "hrv": return .hrvRmssd
        case "rhr": return .restingHeartRate
        default: return nil
        }
    }

    /// Series-key families (contracts.md §5) whose episodes belong to a page.
    static func seriesPrefixes(for metric: PhysiologyContext.MetricKind) -> [String] {
        switch metric {
        case .hrvRmssd: return ["hrv_rmssd."]
        case .hrvSdnn: return ["hrv_sdnn."]
        case .restingHeartRate: return ["resting_hr.", "heart_rate."]
        case .heartRate: return ["heart_rate."]
        case .respiratoryRate: return ["resp_rate."]
        case .skinTemperature: return ["skin_temp."]
        case .spo2Candidate: return ["spo2."]
        }
    }

    static func belongs(seriesKey: String, to metric: PhysiologyContext.MetricKind) -> Bool {
        seriesPrefixes(for: metric).contains { seriesKey.hasPrefix($0) }
    }
}

// MARK: - Choosing what the card describes

enum MeasurementContextSelection {

    /// The measurement a page's card describes: the nightly snapshot value for the metric when the document
    /// has one, else the most recent window that qualifies for any comparison, else the most recent window
    /// (which then reads "insufficient context"). Nil when the document has no envelope for the metric.
    static func headline(in envelopes: [PhysiologyContext.MeasurementEnvelope],
                         metric: PhysiologyContext.MetricKind) -> PhysiologyContext.MeasurementEnvelope? {
        let own = envelopes.filter { $0.metric == metric }
        let byEnd: (PhysiologyContext.MeasurementEnvelope, PhysiologyContext.MeasurementEnvelope) -> Bool = {
            ($0.support.end, $0.id) < ($1.support.end, $1.id)
        }
        if let nightly = own.filter(isNightly).max(by: byEnd) { return nightly }
        let windows = own.filter { !isNightly($0) }
        if let eligible = windows.filter({ e in e.eligibility.contains { $0.state == .eligible } }).max(by: byEnd) {
            return eligible
        }
        return windows.max(by: byEnd)
    }

    /// A nightly product: a scoring-snapshot value or a session aggregate.
    static func isNightly(_ e: PhysiologyContext.MeasurementEnvelope) -> Bool {
        e.source.product == .scoringSnapshot || e.method.aggregation == .session
    }

    /// The comparison the card reports eligibility for: sleep for a nightly value or a measurement taken
    /// asleep, stable awake rest otherwise.
    static func selectedComparison(for e: PhysiologyContext.MeasurementEnvelope) -> PhysiologyContext.ComparisonKind {
        if isNightly(e) || e.sleepWear.sleepState == .asleep { return .sleepMeasurement }
        return .stableAwakeRest
    }

    /// The reference the card leads with: a usable comparison first (rolling, recent, frozen, conditioned),
    /// then any with a difference, then the first one (whose status explains why there is no difference).
    static func headlineReference(_ comparisons: [PhysiologyContext.ReferenceComparison])
        -> PhysiologyContext.ReferenceComparison? {
        let order: [PhysiologyContext.ReferenceView] = [.rolling, .recent, .frozen, .conditioned]
        let ranked = comparisons.sorted {
            (order.firstIndex(of: $0.view) ?? order.count) < (order.firstIndex(of: $1.view) ?? order.count)
        }
        return ranked.first { $0.status == .ready && $0.signedDifference != nil }
            ?? ranked.first { $0.signedDifference != nil }
            ?? ranked.first
    }

    /// The day-level stable-awake comparisons for a window that carries none of its own: the engine attaches a
    /// comparison only to the envelope that is its value, so a 5-minute window that fed today's median has none.
    /// Matched by the window's stable-awake series (e.g. `hrv_rmssd.stable_awake_5min`), its own regime first.
    /// Empty for a nightly value, for a window that has its own comparisons, and for metrics without one.
    static func dayStableAwakeComparisons(for e: PhysiologyContext.MeasurementEnvelope,
                                          in comparisons: [PhysiologyContext.ReferenceComparison])
        -> [PhysiologyContext.ReferenceComparison] {
        guard !isNightly(e), e.comparisons.isEmpty, e.method.windowS > 0, e.method.windowS % 60 == 0 else { return [] }
        var config = PhysiologyContext.ReferenceConfig()
        config.stableAwakeWindowS = e.method.windowS
        guard let series = PhysiologyContext.ContextReferences.stableAwakeSeriesKey(metric: e.metric, config: config)
        else { return [] }
        let matching = comparisons.filter { $0.seriesKey == series }
        let sameRegime = matching.filter { $0.regimeKey == e.regimeKey }
        return sameRegime.isEmpty ? matching : sameRegime
    }

    /// Whether a persistent episode was detected against (or confirmed by) the frozen historical reference: the
    /// frozen persistence rule found it, or its reasons say the historical reference agrees or still differs.
    static func isAgainstHistoricalReference(_ e: PhysiologyContext.ChangeEpisode) -> Bool {
        if e.detector == "frozen_persistence" { return true }
        let frozen: Set<PhysiologyContext.ReasonCode> = [
            PhysiologyContext.ChangeDetection.frozenReferenceDeviation,
            PhysiologyContext.ChangeDetection.rollingAdaptedFrozenDeviationPersists,
            PhysiologyContext.ChangeDetection.frozenAndRollingAgree,
        ]
        return e.reasons.contains(where: frozen.contains)
    }

    /// The episode of the headline reference's series (or, without one, of the page's series family), the
    /// most notable first and the newest among equals.
    static func episode(for e: PhysiologyContext.MeasurementEnvelope,
                        reference: PhysiologyContext.ReferenceComparison?,
                        episodes: [PhysiologyContext.ChangeEpisode]) -> PhysiologyContext.ChangeEpisode? {
        let candidates: [PhysiologyContext.ChangeEpisode]
        if let reference {
            let exact = episodes.filter { $0.seriesKey == reference.seriesKey && $0.regimeKey == reference.regimeKey }
            candidates = exact.isEmpty ? episodes.filter { $0.seriesKey == reference.seriesKey } : exact
        } else {
            candidates = episodes.filter { MeasurementContextPage.belongs(seriesKey: $0.seriesKey, to: e.metric) }
        }
        func rank(_ s: PhysiologyContext.EpisodeState) -> Int {
            switch s {
            case .persistentShift: return 4
            case .recurringEpisode: return 3
            case .transientDeviation: return 2
            case .insufficientEvidence: return 1
            case .usualVariation: return 0
            }
        }
        return candidates.max { (rank($0.state), $0.lastDay, $0.id) < (rank($1.state), $1.lastDay, $1.id) }
    }
}

// MARK: - A small badge

struct ContextBadge: Equatable, Hashable {
    enum Tone: Equatable, Hashable { case neutral, accent, warning }
    let text: String
    let tone: Tone
}

// MARK: - Plain words

enum PhysiologyContextWording {

    // MARK: Copy guard

    /// Words that would infer an illness, a medication effect or a psychological state. None may appear in the
    /// app's own copy for these screens (the person's own exposure labels are their words and are not scanned).
    static let forbiddenTerms: [String] = [
        "calm", "calmer", "calmness", "stress", "stressed", "stressful", "recovered", "relaxed", "relaxation",
        "anxious", "anxiety", "tired", "fatigue", "fatigued", "exhausted", "exhaustion", "burnout", "mood",
        "depressed", "illness", "ill", "sick", "sickness", "infection", "infected", "fever", "disease",
        "diagnosis", "diagnosed", "symptomatic", "medication effect", "drug effect", "side effect",
        "overtrained", "overtraining",
    ]

    /// Whether `text` contains a forbidden term as a whole word (so "still" never matches "ill").
    static func containsForbiddenTerm(_ text: String) -> String? {
        let lower = text.lowercased()
        for term in forbiddenTerms {
            let pattern = "\\b" + NSRegularExpression.escapedPattern(for: term) + "\\b"
            if lower.range(of: pattern, options: .regularExpression) != nil { return term }
        }
        return nil
    }

    /// A code turned into words when no plain phrase is known for it. A code that would read as an inference
    /// becomes a neutral phrase instead.
    static func humanized(_ code: String) -> String {
        let words = code.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: ".", with: " ")
            .trimmingCharacters(in: .whitespaces).lowercased()
        guard !words.isEmpty else { return String(localized: "another reason") }
        return containsForbiddenTerm(words) == nil ? words : String(localized: "another reason")
    }

    static func capitalizedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    // MARK: Reasons
    //
    // Every code in the engine's registries (`<System>.reasonCodes`: IntervalAlgebra, Engine,
    // SignalValidityEngine, MotionEvidence, Eligibility, SleepRhythm, ExertionBouts, Exposures, ContextReferences,
    // ChangeDetection, Functional) has exactly one of: a plain phrase in `reasonPhrases`, or a place in
    // `diagnosticsOnlyReasons` (developer detail: shown raw under Diagnostics, never in the normal flow).
    // `PhysiologyContextWordingCoverageTests` fails when a registered code has neither, or when a mapped code is
    // not registered. A code from a newer server that is in neither list reads as humanized words.

    /// Plain meanings, written to follow "…: " in a sentence (lower case, no full stop). No illness, medication
    /// effect, psychological state or recovery is ever claimed.
    static let reasonPhrases: [String: String] = [
        // Join (IntervalAlgebra)
        "invalid_interval": String(localized: "the measurement time is not valid"),
        "no_activity_records": String(localized: "no activity data covers it"),
        "uncovered_time": String(localized: "part of it has no activity data"),
        "mostly_uncovered": String(localized: "most of it has no activity data"),
        "unknown_label_time": String(localized: "activity is unknown for part of it"),
        "mixed_states": String(localized: "activity changed during it"),
        "heart_rate_dependent_source": String(localized: "the activity labels read heart rate"),
        "gap": String(localized: "a gap in the data"),
        "movement": String(localized: "movement"),
        "unknown_label": String(localized: "unknown activity"),
        "lookback_limit": String(localized: "the look-back limit"),
        // Engine
        "no_measurements": String(localized: "no measurements for this day"),
        "no_observations": String(localized: "no sensor data for this day"),
        "activity_evidence_unavailable": String(localized: "no motion data to judge activity"),
        "sleep_evidence_unavailable": String(localized: "no sleep was detected"),
        "shared_beat_intervals": String(localized: "these values come from the same heartbeats"),
        "labels_read_heart_rate": String(localized: "these labels read heart rate"),
        "motion_shared_across_systems": String(localized: "the same motion data feeds several checks"),
        "shared_optical_sensor": String(localized: "these values come from the same optical sensor"),
        // Signal validity: input checks
        "future_timestamp": String(localized: "some samples were dated in the future"),
        "timestamp_spike": String(localized: "some sample times jumped"),
        "conflicting_duplicates_rejected": String(localized: "conflicting duplicate samples were left out"),
        "non_monotonic_timestamps": String(localized: "some sample times were out of order"),
        "clock_reset_detected": String(localized: "the strap's clock was reset"),
        "overlapping_timelines_suspected": String(localized: "two overlapping recordings may be mixed"),
        "disconnection": String(localized: "the strap disconnected"),
        "source_change": String(localized: "the data source changed"),
        "device_clock_ahead": String(localized: "the strap's clock was ahead"),
        // Signal validity: per measurement
        "no_heart_rate_samples": String(localized: "no heart rate samples"),
        "no_beat_intervals": String(localized: "no beat-to-beat data"),
        "no_skin_temperature_samples": String(localized: "no skin temperature samples"),
        "insufficient_coverage": String(localized: "too little signal coverage"),
        "partial_coverage": String(localized: "the signal covers only part of it"),
        "flatline": String(localized: "the signal was flat"),
        "flatline_run": String(localized: "the signal was flat for a stretch"),
        "out_of_band_samples": String(localized: "some values were outside the expected range"),
        "mostly_out_of_band": String(localized: "most values were outside the expected range"),
        "contains_break": String(localized: "the recording has a break"),
        "insufficient_clean_beats": String(localized: "too few clean beats"),
        "insufficient_valid_pairs": String(localized: "too few usable pairs of beats"),
        "insufficient_beat_coverage": String(localized: "too few beats were captured"),
        "partial_beat_coverage": String(localized: "beats were captured for only part of it"),
        "partial_window_coverage": String(localized: "the signal covers only part of the window"),
        "excess_rejected_beats": String(localized: "too many beats were rejected"),
        "elevated_rejected_beats": String(localized: "more beats than usual were rejected"),
        "beats_outside_kernel_range": String(localized: "some beats were outside the range used for HRV"),
        "rr_over_count_same_second": String(localized: "the beat data looks over-counted"),
        "rr_over_count_cross_second": String(localized: "the beat data looks over-counted across seconds"),
        "rr_under_covered": String(localized: "some beats were missed"),
        "rr_coverage_unmeasurable": String(localized: "beat coverage could not be measured"),
        "beat_values_untrustworthy": String(localized: "beat timings may not be accurate"),
        "motion_contaminated": String(localized: "movement affected the signal"),
        "motion_present": String(localized: "there was movement during it"),
        "motion_unobserved": String(localized: "no motion data to check for movement"),
        "heart_rate_dependent_motion_ignored": String(localized: "motion labels that read heart rate were not used"),
        "window_length_dependent": String(localized: "the value depends on the window length"),
        "insufficient_beats": String(localized: "too few beats"),
        "insufficient_breath_intervals": String(localized: "too few breaths detected"),
        "insufficient_run_coverage": String(localized: "too little continuous signal"),
        "partial_run_coverage": String(localized: "continuous signal for only part of it"),
        "rsa_only_estimate": String(localized: "estimated from heartbeat timing only"),
        "no_in_band_samples": String(localized: "no readings in the range seen when worn"),
        "insufficient_in_band_samples": String(localized: "too few readings in the range seen when worn"),
        "partial_in_band": String(localized: "only some readings were in the range seen when worn"),
        "skin_not_core_temperature": String(localized: "skin temperature, not core body temperature"),
        "unverified_strap_estimate": String(localized: "the strap's estimate is unverified"),
        // Signal validity: measurement conditions (regime)
        "placement_changed": String(localized: "where the strap was worn changed"),
        "placement_history_starts": String(localized: "placement records start here"),
        "placement_record_gap": String(localized: "no placement record for part of it"),
        "method_version_changed": String(localized: "the calculation method changed"),
        "vendor_differs": String(localized: "a different device brand"),
        "device_family_differs": String(localized: "a different device model"),
        "device_family_unknown": String(localized: "the device model is unknown"),
        "source_kind_differs": String(localized: "a different kind of data source"),
        "source_kind_unknown": String(localized: "the kind of data source is unknown"),
        "firmware_differs": String(localized: "different strap firmware"),
        "firmware_unknown": String(localized: "the strap firmware is unknown"),
        "placement_differs": String(localized: "the strap was worn in a different place"),
        "placement_unknown": String(localized: "where the strap was worn is unknown"),
        "placement_mixed": String(localized: "the strap was worn in more than one place"),
        "method_differs": String(localized: "a different calculation method"),
        "algorithm_version_differs": String(localized: "a different calculation version"),
        "aggregation_differs": String(localized: "summarized a different way"),
        "window_differs": String(localized: "a different window length"),
        "units_differs": String(localized: "different units"),
        "regime_key_differs": String(localized: "measured under different conditions"),
        // Signal validity: inputs that do not exist or are limited
        "no_qualified_waveform": String(localized: "no validated pulse waveform from this strap"),
        "no_core_temperature_sensor": String(localized: "this strap has no core temperature sensor"),
        "wrist_orientation_likelihood_only":
            String(localized: "arm orientation gives only a likely posture, never a confirmed one"),
        "no_gravity_vector": String(localized: "no orientation data"),
        "heart_rate_independent_source": String(localized: "does not read heart rate"),
        "display_only": String(localized: "shown for reference only"),
        "sleep_detector_uses_heart_rate": String(localized: "sleep detection reads heart rate"),
        "wear_from_heart_rate_signal": String(localized: "wear is judged from the heart rate signal"),
        "awake_evidence_unavailable": String(localized: "no data to tell whether you were awake"),
        "wear_evidence_unavailable": String(localized: "no data to tell whether the strap was worn"),
        "no_source_records": String(localized: "no records from this source"),
        "step_counter_present": String(localized: "step counts are available"),
        "excluded_from_comparisons": String(localized: "not used in comparisons"),
        // Motion evidence
        "motion_magnitude_unavailable": String(localized: "how much you moved could not be measured"),
        "no_motion_samples": String(localized: "no motion data"),
        // Eligibility
        "stable_awake_low_movement": String(localized: "awake with little movement"),
        "inside_supported_sleep": String(localized: "inside detected sleep"),
        "inside_locomotion": String(localized: "during walking or running"),
        "after_exertion_bout": String(localized: "after an activity bout"),
        "signal_invalid": String(localized: "the signal did not pass quality checks"),
        "signal_degraded": String(localized: "the signal is usable with limitations"),
        "signal_validity_missing": String(localized: "no signal"),
        "signal_unverified": String(localized: "the value is unverified"),
        "signal_unsupported": String(localized: "this signal is not supported"),
        "heart_rate_dependent_activity_ignored": String(localized: "activity labels that read heart rate were not used"),
        "insufficient_activity_coverage": String(localized: "too little activity data"),
        "asleep": String(localized: "it was during sleep"),
        "sleep_wake_mixed": String(localized: "it was partly during sleep"),
        "awake_evidence_unknown": String(localized: "it is unclear whether you were awake"),
        "not_worn": String(localized: "the strap may not have been worn"),
        "wear_mixed": String(localized: "the strap was off for part of it"),
        "wear_evidence_unknown": String(localized: "it is unclear whether the strap was worn"),
        "movement_in_support": String(localized: "movement during the measurement"),
        "insufficient_stationary": String(localized: "not still for enough of it"),
        "insufficient_preceding_stillness": String(localized: "not still for long enough beforehand"),
        "preceding_stillness_unobserved": String(localized: "no activity data for the time before it"),
        "recent_locomotion": String(localized: "walking or running shortly before"),
        "recent_locomotion_unobserved": String(localized: "no activity data for the minutes before it"),
        "recent_exertion_bout": String(localized: "an activity bout shortly before"),
        "exertion_history_exceeds_limit": String(localized: "a lot of walking or running in the past day"),
        "not_asleep": String(localized: "it was not during sleep"),
        "sleep_evidence_unknown": String(localized: "it is unclear whether you were asleep"),
        "no_supported_exertion": String(localized: "no activity bout around it"),
        // Sleep, wake and rhythm
        "session_end_clipped_to_cutoff": String(localized: "sleep after the data cut-off is not included yet"),
        "session_reaches_cutoff": String(localized: "the sleep record reaches the data cut-off"),
        "detector_may_extend": String(localized: "the sleep record may still be extended"),
        "owner_day_provisional": String(localized: "the day this sleep belongs to may change"),
        "classification_provisional": String(localized: "whether this is a nap or main sleep may change"),
        "split_sleep": String(localized: "sleep was split into parts"),
        "hr_only_session": String(localized: "sleep was detected from heart rate only"),
        "stages_unverified": String(localized: "sleep stages are unverified"),
        "invalid_support": String(localized: "the time span is not valid"),
        "no_detector_output": String(localized: "no sleep detection for this time"),
        "detector_input_missing": String(localized: "sleep detection had too little data for this time"),
        "detector_lag_window": String(localized: "sleep detection may not have caught up yet"),
        "detector_owner_days_unread": String(localized: "sleep detection has not covered every nearby day yet"),
        "partially_in_detected_sleep": String(localized: "partly inside detected sleep"),
        "overlaps_incomplete_episode": String(localized: "overlaps sleep that was not finished"),
        "inside_split_sleep_gap": String(localized: "between two parts of split sleep"),
        "sleep_sources_disagree": String(localized: "sleep sources disagree"),
        "sleep_evidence_insufficient": String(localized: "too little evidence about sleep"),
        "no_wear_evidence": String(localized: "no data on whether the strap was worn"),
        "wear_evidence_insufficient": String(localized: "too little evidence about wear"),
        "wear_sources_disagree": String(localized: "wear sources disagree"),
        "wear_from_heart_signal": String(localized: "wear is judged from the heart signal"),
        "no_completed_sleep_before": String(localized: "no completed sleep before it"),
        "sleep_in_progress": String(localized: "sleep was still in progress"),
        "inside_sleep_episode": String(localized: "it was inside a sleep period"),
        "reference_beyond_lookback": String(localized: "the last sleep was too long ago"),
        "nap_after_main_wake": String(localized: "counted from the main sleep, not the later nap"),
        "no_main_sleep_reference": String(localized: "no main sleep to count from"),
        "wake_may_be_revised": String(localized: "the wake time may still change"),
        "reference_time_after_cutoff": String(localized: "the wake time is after the data cut-off"),
        "no_sleep_episodes": String(localized: "no sleep periods were detected"),
        "no_main_sleep": String(localized: "no main sleep was detected"),
        "main_sleep_incomplete": String(localized: "the main sleep was not finished"),
        "prior_nights_insufficient": String(localized: "too few earlier nights"),
        "stages_unavailable": String(localized: "no sleep stages"),
        "timezone_history_unknown": String(localized: "earlier time zones are unknown"),
        "prior_zone_assumed_same": String(localized: "earlier days are assumed to be in the same time zone"),
        "utc_offset_changed_in_window": String(localized: "the time zone changed during this period"),
        "rhythm_proxy_only": String(localized: "daily rhythm is estimated from timing only"),
        "rhythm_samples_insufficient": String(localized: "too few days to estimate the daily rhythm"),
        "endogenous_phase_unmeasured": String(localized: "the body clock itself is not measured"),
        "sleep_labels_read_heart_signals": String(localized: "sleep labels read heart signals"),
        "rhythm_proxy_reads_heart_rate": String(localized: "the daily rhythm estimate reads heart rate"),
        // Exertion bouts and follow-up
        "disconnect": String(localized: "the strap disconnected"),
        "continued_movement": String(localized: "movement continued"),
        "next_bout": String(localized: "another bout started"),
        "cutoff_reached": String(localized: "the data ends here for now"),
        "no_follow_up": String(localized: "no data afterwards"),
        "bout_ongoing": String(localized: "it is still going"),
        "ended_at_evidence_gap": String(localized: "it ended at a gap in the data"),
        "overlaps_hr_detected_workout": String(localized: "it overlaps a workout detected from heart rate"),
        "workout_without_locomotion_evidence": String(localized: "a logged workout without walking or running data"),
        "workout_clipped_at_cutoff": String(localized: "the workout continues past the data cut-off"),
        "insufficient_follow_up_samples": String(localized: "too little data afterwards"),
        "pre_bout_hr_insufficient_coverage": String(localized: "too little heart rate data before it"),
        "pre_bout_window_in_prior_recovery": String(localized: "the minutes before it were soon after another bout"),
        "pre_bout_window_overlaps_prior_bout": String(localized: "the minutes before it overlap another bout"),
        "preceding_state_unknown": String(localized: "activity before it is unknown"),
        "hr_insufficient_coverage_during_bout": String(localized: "too little heart rate data during it"),
        "pre_bout_reference_unavailable": String(localized: "no heart rate level from before it"),
        "end_hr_unavailable": String(localized: "no heart rate at its end"),
        "optical_hr_during_movement_unvalidated":
            String(localized: "optical heart rate during movement is not validated"),
        "respiration_unavailable_during_movement": String(localized: "no breathing rate during movement"),
        "no_supported_post_bout_respiratory_estimator": String(localized: "breathing rate after activity is not measured"),
        "hrv_recovery_window_unsupported": String(localized: "HRV after activity is not measured"),
        "insufficient_samples_at_offset": String(localized: "too few readings at this point"),
        "follow_up_motion_unobserved": String(localized: "no motion data afterwards"),
        "rise_too_small_for_fraction": String(localized: "heart rate rose too little to compare"),
        "rise_too_small_for_return": String(localized: "heart rate rose too little to time a return"),
        "not_returned_by_last_observed_offset":
            String(localized: "heart rate was not back near the earlier level by the last reading"),
        "return_undetermined_earlier_offset_unobserved":
            String(localized: "an earlier reading is missing, so the return time is unknown"),
        "post_effort_hr_decline_not_clinical_hrr":
            String(localized: "the drop in heart rate afterwards is not a clinical test"),
        "cadence_unavailable": String(localized: "no step rate"),
        "insufficient_cadence_minutes": String(localized: "too few minutes with a step rate"),
        "uncalibrated_step_counter": String(localized: "the step counter is not calibrated"),
        "wrist_cadence_not_gait_speed": String(localized: "step rate at the wrist is not walking speed"),
        "speed_unavailable": String(localized: "speed is not measured"),
        "grade_unavailable": String(localized: "incline is not measured"),
        "external_load_unavailable": String(localized: "carried load is not measured"),
        "ambient_unavailable": String(localized: "weather and temperature are not measured"),
        "coverage_unknown_for_part_of_window": String(localized: "data coverage is unknown for part of this period"),
        "no_motion_observed_in_window": String(localized: "no motion data in this period"),
        // Exposures
        "association_only": String(localized: "shown side by side only, not as a cause"),
        "concurrent_events": String(localized: "other events happened at the same time"),
        "time_uncertain": String(localized: "the time is uncertain"),
        "insufficient_measurements": String(localized: "too few measurements to compare"),
        "behavior_change": String(localized: "activity also changed"),
        "behavior_unobserved": String(localized: "activity was not observed"),
        "window_partially_searched": String(localized: "only part of the period was checked"),
        "regime_change": String(localized: "measurement conditions changed"),
        "pharmacology_not_modelled": String(localized: "how substances act in the body is not modelled"),
        "late_entries_included": String(localized: "includes entries made later"),
        "aligned_events_limited": String(localized: "only some events are compared"),
        "no_exposure_records": String(localized: "nothing was recorded"),
        "candidate_not_confirmed": String(localized: "suggested, not confirmed"),
        "invalid_dose_dropped": String(localized: "an amount that could not be read was left out"),
        // References
        "time_band_stratum": String(localized: "matched by time of day"),
        "degraded_validity_included": String(localized: "includes a signal usable with limitations"),
        "relative_use_only": String(localized: "for relative comparison only"),
        "no_history": String(localized: "no earlier data"),
        "insufficient_history": String(localized: "not enough comparable days yet"),
        "provisional_support": String(localized: "based on few days so far"),
        "history_in_other_regime_only": String(localized: "earlier data was measured under different conditions"),
        "other_regime_history_not_pooled": String(localized: "data from different conditions is kept separate"),
        "stale_history": String(localized: "the earlier data is old"),
        "history_values_excluded": String(localized: "some earlier values were left out"),
        "scale_floored": String(localized: "the usual range was widened to a minimum"),
        "constant_history": String(localized: "earlier values were all the same"),
        "center_uncertainty_approximate": String(localized: "the \u{00B1} range is approximate"),
        "frozen_reference_is_historical_not_healthy":
            String(localized: "a historical reference is your own past data, not a healthy range"),
        "frozen_not_registered": String(localized: "no historical reference has been set yet"),
        "pooled_toward_parent": String(localized: "partly based on related contexts"),
        "context_unsupported_parent_only": String(localized: "based on related contexts only"),
        "parent_insufficient_child_only": String(localized: "based on this context only"),
        "no_population_prior": String(localized: "no population data is used"),
        // Change episodes
        "coincides_with_regime_boundary": String(localized: "it starts when measurement conditions changed"),
        "split_at_regime_boundary": String(localized: "split where measurement conditions changed"),
        "rolling_adapted_frozen_deviation_persists":
            String(localized: "the recent range has adjusted, but the difference from the historical reference remains"),
        "rolling_adapted_not_proof_of_recovery":
            String(localized: "the recent range adjusted to the new values; that does not mean they went back"),
        "returned_toward_reference": String(localized: "values moved back toward the reference"),
        "frozen_reference_deviation": String(localized: "differs from the historical reference"),
        "gradual_drift": String(localized: "a gradual drift"),
        "frozen_and_rolling_agree": String(localized: "the historical and recent references agree"),
        "frozen_and_rolling_disagree": String(localized: "the historical and recent references disagree"),
        "frozen_unavailable": String(localized: "no historical reference yet"),
        "alternative_detector_agrees": String(localized: "a second check agrees"),
        "alternative_detector_silent": String(localized: "a second check did not flag it"),
        "gap_reset": String(localized: "restarted after a gap in the data"),
        "too_few_supported_days": String(localized: "too few days with data"),
        "no_reference": String(localized: "no reference yet"),
        "isolated_excursion": String(localized: "a single unusual day"),
        "recurring_within_window": String(localized: "it happened more than once in this period"),
        "starts_at_window_start": String(localized: "it may have started before this period"),
        "no_recent_support": String(localized: "no recent days with data"),
        "descriptive_not_diagnostic": String(localized: "a description of your data only, not a medical judgement"),
        "shared_inputs_not_independent": String(localized: "these values share inputs, so they are not independent"),
        "selection_reads_heart_rate": String(localized: "which values were used depends on heart rate"),
        "no_deviating_series": String(localized: "no series differs from its reference"),
        "distinct_groups_not_proven_independent": String(localized: "separate groups are not proven independent"),
        // Functional (daily movement pattern)
        "day_not_started_at_cutoff": String(localized: "the day had not started at the data cut-off"),
        "day_incomplete_at_cutoff": String(localized: "the day was not over at the data cut-off"),
        "insufficient_wear_coverage": String(localized: "the strap was worn too little"),
        "insufficient_worn_time_for_rates": String(localized: "too little worn time to give rates"),
        "wear_missingness_may_be_informative": String(localized: "when the strap was off may itself matter"),
        "sleep_not_excluded_from_waking_time": String(localized: "sleep could not be separated from waking time"),
        "no_waking_time": String(localized: "no waking time"),
        "no_bouts": String(localized: "no activity bouts"),
        "wear_denominator_uses_heart_signal_presence": String(localized: "worn time is judged from the heart signal"),
        "rest_after_bout_right_censored": String(localized: "rest after the last bout was cut short"),
        "transition_denominator_too_small": String(localized: "too few changes of activity to compare"),
        "observed_behaviour_not_diagnosis": String(localized: "observed movement only, not a medical judgement"),
    ]

    /// Developer detail: how inputs were cleaned, which estimator or detector ran, provenance of a daily value.
    /// Never shown in the normal flow; the raw code is listed under Diagnostics.
    static let diagnosticsOnlyReasons: Set<String> = [
        // Join and engine
        "overlapping_records_resolved", "history_from_future_dropped",
        // Signal validity input hygiene
        "out_of_contract_units", "outside_read_window", "exact_duplicates_collapsed",
        "availability_basis_sensor_time", "equal_value_beats_kept",
        // Motion evidence basis
        "motion_basis_dynamic_acceleration", "motion_basis_gravity_delta", "step_counter_stepping",
        // Sleep record resolution
        "session_revision_resolved", "overlapping_session_superseded", "session_availability_basis_end",
        "source_day_differs_from_owner_day", "scorer_nap_flag", "main_night_rule_applied",
        "band_state_inputs_undocumented",
        // Exertion bookkeeping
        "merged_hart_and_strap_evidence", "step_counter_unclassed_legacy", "observed_prorated_partial_day",
        // Exposure bookkeeping
        "invalid_revisions_ignored",
        // Daily value provenance and reference estimators
        "nightly_snapshot", "stable_awake_windows", "multiple_nightly_values_longest_kept",
        "overlapping_windows_not_counted", "duplicate_history_day_resolved", "future_history_ignored",
        "log_transform", "non_positive_value_for_log", "small_sample_scale_correction", "winsorized_mean_estimator",
        "scale_from_rolling_view", "scale_from_recent_window", "frozen_registered_this_run",
        "frozen_registers_in_other_mode", "frozen_scale_floored_by_current_policy",
        // Change detection internals
        "detector_cusum", "detector_persistence", "no_declared_dependence",
    ]

    /// The explicit plain phrase for a code, or nil (diagnostics-only, or a code this app does not know).
    static func phrase(_ code: PhysiologyContext.ReasonCode) -> String? {
        reasonPhrases[code.rawValue]
    }

    static func isDiagnosticsOnly(_ code: PhysiologyContext.ReasonCode) -> Bool {
        diagnosticsOnlyReasons.contains(code.rawValue)
    }

    /// A reason code's plain meaning, written to follow "…: " in a sentence (lower case, no full stop). A code
    /// without a phrase reads as humanized words.
    static func reason(_ code: PhysiologyContext.ReasonCode) -> String {
        phrase(code) ?? humanized(code.rawValue)
    }

    /// The codes the normal flow may show: every code except the diagnostics-only ones, in order.
    static func shownReasons(_ codes: [PhysiologyContext.ReasonCode]) -> [PhysiologyContext.ReasonCode] {
        codes.filter { !isDiagnosticsOnly($0) }
    }

    /// The leading reason in plain words, or nil: the first shown reason. The engine lists the deciding reasons
    /// first (review-contract RC-05), so this is the one that decided the verdict.
    static func topReason(_ codes: [PhysiologyContext.ReasonCode]) -> String? {
        shownReasons(codes).first.map(reason)
    }

    /// Every shown reason in plain words, as one sentence fragment list.
    static func reasonList(_ codes: [PhysiologyContext.ReasonCode]) -> String? {
        let shown = shownReasons(codes)
        guard !shown.isEmpty else { return nil }
        var seen = Set<String>()
        let phrases = shown.map(reason).filter { seen.insert($0).inserted }
        return capitalizedFirst(phrases.joined(separator: "; "))
    }

    // MARK: Activity

    static func activityLabel(_ label: String) -> String {
        switch label {
        case "still": return String(localized: "Still")
        case "stationary": return String(localized: "Stationary")
        case "low_movement": return String(localized: "Low movement")
        case "sleeping": return String(localized: "Sleeping")
        // Posture classes come from arm orientation (and the decoder reads heart rate): a likelihood only,
        // never a confirmed posture.
        case "lying_down": return String(localized: "Likely lying down")
        case "sitting", "sitting_desk": return String(localized: "Likely sitting")
        case "standing": return String(localized: "Likely standing")
        case "walking": return String(localized: "Walking")
        case "brisk_walking": return String(localized: "Brisk walking")
        case "running": return String(localized: "Running")
        case "stepping": return String(localized: "Stepping")
        case "cycling": return String(localized: "Cycling")
        case "other_movement": return String(localized: "Other movement")
        case "fidgeting": return String(localized: "Fidgeting")
        case "light_activity": return String(localized: "Light activity")
        case "vigorous_activity": return String(localized: "Vigorous activity")
        default: return capitalizedFirst(humanized(label))
        }
    }

    /// Posture classes: shown as likelihoods ("Likely standing"), never as a confirmed posture.
    static let postureLabels: Set<String> = ["lying_down", "sitting", "sitting_desk", "standing"]

    /// The decoder's estimate for a label. Every decoder label is an estimate that reads heart rate, so each one
    /// reads as a likelihood: "Likely standing", "Likely walking".
    static func likelyActivity(_ label: String) -> String {
        if postureLabels.contains(label) { return activityLabel(label) }
        let name = activityLabel(label).lowercased()
        return String(localized: "Likely \(name)")
    }

    /// "Recent walking" and friends, for the movement a label names.
    static func recentMovementPhrase(_ label: String?) -> String {
        switch label {
        case "walking", "brisk_walking", "stepping": return String(localized: "Recent walking")
        case "running": return String(localized: "Recent running")
        case "cycling": return String(localized: "Recent cycling")
        default: return String(localized: "Recent movement")
        }
    }

    static func activitySource(_ source: PhysiologyContext.ActivitySource) -> String {
        switch source {
        case .hartEpochs: return String(localized: "Motion classifier (motion only)")
        case .strapMotion: return String(localized: "Strap motion and steps")
        case .decoderIntervals: return String(localized: "Activity decoder (reads heart rate)")
        case .none: return String(localized: "No activity data")
        }
    }

    // MARK: Validity, sleep, wear

    static func validity(_ state: PhysiologyContext.ValidityState) -> String {
        switch state {
        case .valid: return String(localized: "Passed quality checks")
        case .degraded: return String(localized: "Usable with limitations")
        case .invalid: return String(localized: "Did not pass quality checks")
        case .missing: return String(localized: "No signal in this period")
        case .unverified: return String(localized: "Unverified")
        case .unsupported: return String(localized: "Not supported")
        }
    }

    static func sleepState(_ state: PhysiologyContext.SleepWakeState) -> String {
        switch state {
        case .asleep: return String(localized: "Asleep")
        case .awake: return String(localized: "Awake")
        case .mixed: return String(localized: "Partly asleep")
        case .unknown: return String(localized: "Unknown")
        }
    }

    static func wearState(_ state: PhysiologyContext.WearEvidenceState) -> String {
        switch state {
        case .worn: return String(localized: "Worn")
        case .notWorn: return String(localized: "Not worn")
        case .mixed: return String(localized: "Partly worn")
        case .unknown: return String(localized: "Unknown")
        }
    }

    static func evidence(_ source: String) -> String {
        switch source {
        case "detected_sleep_session": return String(localized: "detected sleep")
        case "outside_detected_sleep": return String(localized: "outside detected sleep")
        case "band_sleep_state": return String(localized: "the strap's own sleep state")
        case "wear_events": return String(localized: "wrist on/off events")
        case "heart_rate_signal_present": return String(localized: "a heart rate signal")
        default: return humanized(source)
        }
    }

    // MARK: Comparisons and references

    /// "stable awake comparison", for use inside a sentence.
    static func comparison(_ kind: PhysiologyContext.ComparisonKind) -> String {
        switch kind {
        case .stableAwakeRest: return String(localized: "stable awake comparison")
        case .sleepMeasurement: return String(localized: "sleep comparison")
        case .activityResponse: return String(localized: "activity response comparison")
        }
    }

    /// "Stable awake", as a row title.
    static func comparisonTitle(_ kind: PhysiologyContext.ComparisonKind) -> String {
        switch kind {
        case .stableAwakeRest: return String(localized: "Stable awake")
        case .sleepMeasurement: return String(localized: "Sleep")
        case .activityResponse: return String(localized: "Activity response")
        }
    }

    static func eligibilityState(_ state: PhysiologyContext.EligibilityState) -> String {
        switch state {
        case .eligible: return String(localized: "Qualifies")
        case .ineligible: return String(localized: "Does not qualify")
        case .unknown: return String(localized: "Can't tell")
        }
    }

    /// One line on whether a measurement qualifies for `kind`, with the top reason when it does not.
    static func eligibilityLine(_ verdict: PhysiologyContext.EligibilityVerdict?,
                                kind: PhysiologyContext.ComparisonKind) -> String {
        let name = comparison(kind)
        guard let verdict else { return String(localized: "Not checked for the \(name)") }
        let why = topReason(verdict.reasons)
        switch verdict.state {
        case .eligible:
            return String(localized: "Qualifies for the \(name)")
        case .ineligible:
            return why.map { String(localized: "Does not qualify for the \(name): \($0)") }
                ?? String(localized: "Does not qualify for the \(name)")
        case .unknown:
            return why.map { String(localized: "Can't tell whether it qualifies for the \(name): \($0)") }
                ?? String(localized: "Can't tell whether it qualifies for the \(name)")
        }
    }

    static func referenceTitle(_ view: PhysiologyContext.ReferenceView) -> String {
        switch view {
        case .recent: return String(localized: "Recent reference")
        case .rolling: return String(localized: "Rolling reference")
        case .frozen: return String(localized: "Historical reference")
        case .conditioned: return String(localized: "Context-matched reference")
        }
    }

    static func referenceStatus(_ status: PhysiologyContext.ReferenceStatus) -> String {
        switch status {
        case .ready: return String(localized: "Ready")
        case .provisional: return String(localized: "Provisional")
        case .insufficient: return String(localized: "Not enough comparable days yet")
        case .unavailable: return String(localized: "Unavailable")
        case .regimeMismatch: return String(localized: "Measured under different conditions")
        }
    }

    /// "your 28-day reference" — the window the reference spans, for use after "vs".
    static func referenceName(_ c: PhysiologyContext.ReferenceComparison) -> String {
        switch c.view {
        case .rolling:
            if let from = c.fromDay, let to = c.toDay,
               let days = PhysiologyContextDates.inclusiveDays(from: from, to: to), days > 0 {
                return String(localized: "your \(days)-day reference")
            }
            return String(localized: "your rolling reference")
        case .recent:
            if let from = c.fromDay, let to = c.toDay,
               let days = PhysiologyContextDates.inclusiveDays(from: from, to: to), days > 0 {
                return String(localized: "your recent \(days)-day reference")
            }
            return String(localized: "your recent reference")
        case .frozen: return String(localized: "your historical reference")
        case .conditioned: return String(localized: "your context-matched reference")
        }
    }

    /// "+6 ms vs your 28-day reference", or why there is no difference.
    static func referenceLine(_ c: PhysiologyContext.ReferenceComparison, units: String,
                              locale: Locale = .current) -> String {
        if let diff = c.signedDifference, c.status == .ready || c.status == .provisional {
            return String(localized: "\(signedDifference(diff, units: units, locale: locale)) vs \(referenceName(c))")
        }
        switch c.status {
        case .insufficient: return String(localized: "Not enough comparable days for a reference yet")
        case .regimeMismatch: return String(localized: "Measured under different conditions than the reference")
        case .unavailable: return String(localized: "No reference available")
        case .ready, .provisional:
            return String(localized: "No difference from the reference could be computed")
        }
    }

    /// "Reference 52 ms ± 2 ms (approx.)". The ± is an approximate standard error of the reference centre (it
    /// assumes independent days), so it always says so.
    static func referenceCenter(_ c: PhysiologyContext.ReferenceComparison, units: String,
                                locale: Locale = .current) -> String? {
        guard let center = c.center, center.isFinite else { return nil }
        let centre = value(center, units: units, locale: locale)
        guard let u = c.centerUncertainty, u.isFinite, u > 0 else { return String(localized: "Reference \(centre)") }
        let spread = value(u, units: units, locale: locale)
        return String(localized: "Reference \(centre) \u{00B1} \(spread) (approx.)")
    }

    /// "Today's stable awake median: +6 ms vs your 28-day reference". A day-level comparison shown next to a
    /// single window: the difference is the day's median's, never the window's own.
    static func stableAwakeMedianLine(_ c: PhysiologyContext.ReferenceComparison, units: String,
                                      locale: Locale = .current) -> String {
        if let diff = c.signedDifference, c.status == .ready || c.status == .provisional {
            let delta = signedDifference(diff, units: units, locale: locale)
            return String(localized: "Today's stable awake median: \(delta) vs \(referenceName(c))")
        }
        let why = referenceLine(c, units: units, locale: locale)
        let lowered = why.prefix(1).lowercased() + why.dropFirst()
        return String(localized: "Today's stable awake median: \(lowered)")
    }

    // MARK: Episodes

    /// An episode's state. A persistent shift reads "Persistent change from historical reference" only when it
    /// was detected against, or confirmed by, the frozen historical reference; a shift found against the rolling
    /// view alone (no frozen reference, or one that disagrees) reads "…from your recent usual range".
    static func episodeState(_ e: PhysiologyContext.ChangeEpisode) -> String {
        guard e.state == .persistentShift, MeasurementContextSelection.isAgainstHistoricalReference(e) else {
            return episodeState(e.state)
        }
        return String(localized: "Persistent change from historical reference")
    }

    /// A state without its episode. A persistent shift says nothing about a historical reference here, because
    /// the state alone does not say which reference it was detected against.
    static func episodeState(_ state: PhysiologyContext.EpisodeState) -> String {
        switch state {
        case .usualVariation: return String(localized: "Within usual variation")
        case .transientDeviation: return String(localized: "Transient deviation from reference")
        case .recurringEpisode: return String(localized: "Recurring deviation from reference")
        case .persistentShift: return String(localized: "Persistent change from your recent usual range")
        case .insufficientEvidence: return String(localized: "Insufficient evidence for a change")
        }
    }

    static func direction(_ direction: Int) -> String? {
        switch direction {
        case 1...: return String(localized: "Above reference")
        case ...(-1): return String(localized: "Below reference")
        default: return nil
        }
    }

    static func episodeBadges(_ e: PhysiologyContext.ChangeEpisode) -> [ContextBadge] {
        var out: [ContextBadge] = []
        if e.state == .transientDeviation { out.append(ContextBadge(text: String(localized: "Transient"), tone: .neutral)) }
        if e.ongoing { out.append(ContextBadge(text: String(localized: "Ongoing"), tone: .accent)) }
        out.append(finalityBadge(e.finality))
        return out
    }

    /// A plain name for a series key (contracts.md §5).
    static func series(_ key: String) -> String {
        switch key {
        case "hrv_rmssd.sleep_night": return String(localized: "Nightly HRV")
        case "resting_hr.sleep_night": return String(localized: "Nightly resting heart rate")
        case "resp_rate.sleep_night": return String(localized: "Nightly respiratory rate")
        case "skin_temp.sleep_night": return String(localized: "Nightly skin temperature (relative)")
        case "hrv_rmssd.stable_awake_5min": return String(localized: "HRV, stable awake measurements")
        case "heart_rate.stable_awake_5min": return String(localized: "Heart rate, stable awake measurements")
        case "coverage.motion_observed_s": return String(localized: "Motion data coverage")
        default:
            if key.hasPrefix("hr_response.") { return String(localized: "Heart rate response to activity") }
            if key.hasPrefix("functional.") {
                let rest = humanized(String(key.dropFirst("functional.".count)))
                return String(localized: "Daily movement pattern (\(rest))")
            }
            return capitalizedFirst(humanized(key))
        }
    }

    // MARK: Bouts

    static func boutKind(_ kind: String) -> String {
        switch kind {
        case "walking": return String(localized: "Walking")
        case "running": return String(localized: "Running")
        case "stepping": return String(localized: "Stepping")
        case "workout": return String(localized: "Workout")
        case "mixed_locomotion": return String(localized: "Mixed walking and running")
        default: return capitalizedFirst(humanized(kind))
        }
    }

    /// The censoring vocabulary of System D (what cut a follow-up short).
    static let censoringReasons: [PhysiologyContext.ReasonCode] = [
        PhysiologyContext.ExertionBouts.censorDisconnect, PhysiologyContext.ExertionBouts.censorContinuedMovement,
        PhysiologyContext.ExertionBouts.censorNextBout, PhysiologyContext.ExertionBouts.censorCutoffReached,
        PhysiologyContext.ExertionBouts.censorNoFollowUp,
    ]

    /// Why a censored bout's follow-up stopped: the first censoring event of its recovery (the one that truncated
    /// it), else the censoring code among its reasons, else too few samples afterwards. Never just the first of
    /// the bout's reasons, which are sorted by name.
    static func censoringCause(_ bout: PhysiologyContext.ExertionBout) -> PhysiologyContext.ReasonCode? {
        if let first = bout.recovery?.censoring.first { return first }
        if let code = bout.reasons.first(where: censoringReasons.contains) { return code }
        let sparse = PhysiologyContext.ExertionBouts.insufficientFollowUpSamples
        return bout.reasons.contains(sparse) ? sparse : nil
    }

    /// The follow-up after a bout: complete, still going, or cut short (and why).
    static func boutStatus(_ bout: PhysiologyContext.ExertionBout) -> String {
        switch bout.status {
        case .complete: return String(localized: "Follow-up complete")
        case .ongoing: return String(localized: "Ongoing")
        case .censored:
            return censoringCause(bout).map { String(localized: "Follow-up incomplete: \(reason($0))") }
                ?? String(localized: "Follow-up incomplete")
        }
    }

    /// The measured heart-rate response of a bout in plain words, or nil when nothing was measured. Describes
    /// observations only: the rise against the minutes before, the decline at the first observed offset, and the
    /// time back near the earlier level only when it was actually seen. Never a judgement of fitness or health.
    static func boutResponse(_ bout: PhysiologyContext.ExertionBout, locale: Locale = .current) -> String? {
        var parts: [String] = []
        if let rise = bout.response?.hrRiseBpm, rise.isFinite {
            let delta = signedDifference(rise, units: "bpm", locale: locale)
            if let ref = bout.preBout?.hrReferenceBpm, ref.isFinite {
                let level = Int(ref.rounded())
                parts.append(String(localized: "Heart rate \(delta) vs the minutes before (\(level) bpm)"))
            } else {
                parts.append(String(localized: "Heart rate \(delta) vs the minutes before"))
            }
        } else if let median = bout.response?.hrMedianBpm, median.isFinite {
            parts.append(String(localized: "Heart rate during: \(Int(median.rounded())) bpm"))
        }
        if let first = bout.recovery?.observations.first(where: { $0.state == .observed && $0.declineBpm != nil }),
           let decline = first.declineBpm, decline.isFinite {
            let after = duration(first.offsetS)
            let amount = Int(abs(decline).rounded())
            parts.append(decline >= 0 ? String(localized: "\(after) after: \(amount) bpm lower")
                                      : String(localized: "\(after) after: \(amount) bpm higher"))
        }
        if let back = bout.recovery?.timeToReturnS {
            parts.append(String(localized: "Back near the earlier level after \(duration(back))"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " \u{00B7} ")
    }

    // MARK: Exposures

    static func exposureKind(_ kind: PhysiologyContext.ExposureKind) -> String {
        switch kind {
        case .medication: return String(localized: "Medication")
        case .supplement: return String(localized: "Supplement")
        case .caffeine: return String(localized: "Caffeine")
        case .alcohol: return String(localized: "Alcohol")
        case .meal: return String(localized: "Meal")
        case .heat: return String(localized: "Heat")
        case .travel: return String(localized: "Travel")
        case .symptom: return String(localized: "Symptom")
        case .other: return String(localized: "Other")
        }
    }

    /// Recording status of a category over its window. A denial ("no") that covers only part of the window reads
    /// "Recorded as none for part of this period": the rest is unrecorded, not none. A denial whose coverage was
    /// not reported is treated the same way.
    static func exposureCategoryStatus(_ s: PhysiologyContext.ExposureCategoryStatus) -> String {
        if s.status == PhysiologyContext.Exposures.statusDenied, !deniedWholePeriod(s) {
            return String(localized: "Recorded as none for part of this period")
        }
        return exposureCategoryStatus(s.status)
    }

    /// How much of the window the denial covers, for a partial denial ("33% of this period; the rest is not
    /// recorded"). Nil otherwise.
    static func exposureCategoryNote(_ s: PhysiologyContext.ExposureCategoryStatus,
                                     locale: Locale = .current) -> String? {
        guard s.status == PhysiologyContext.Exposures.statusDenied, !deniedWholePeriod(s),
              let coverage = s.deniedCoverage, coverage.isFinite else { return nil }
        let share = percent(min(0.99, max(0, coverage)), locale: locale)
        return String(localized: "\(share) of this period; the rest is not recorded")
    }

    static func deniedWholePeriod(_ s: PhysiologyContext.ExposureCategoryStatus) -> Bool {
        guard let coverage = s.deniedCoverage, coverage.isFinite else { return false }
        return coverage >= 0.9995
    }

    /// Recording status of a category, by status alone. Not recorded is not "none".
    static func exposureCategoryStatus(_ status: String) -> String {
        switch status {
        case "recorded": return String(localized: "Recorded")
        case "denied": return String(localized: "Recorded as none")
        case "candidate_only": return String(localized: "Suggested, not confirmed")
        case "unrecorded": return String(localized: "Not recorded")
        default: return capitalizedFirst(humanized(status))
        }
    }

    static func exposureConfirmation(_ c: PhysiologyContext.ExposureConfirmation) -> String {
        switch c {
        case .confirmed: return String(localized: "Confirmed")
        case .denied: return String(localized: "Recorded as not happening")
        case .candidate: return String(localized: "Suggested, not confirmed")
        case .retracted: return String(localized: "Withdrawn")
        }
    }

    static func timePrecision(_ p: PhysiologyContext.TimePrecision) -> String? {
        switch p {
        case .exact: return nil
        case .approximate: return String(localized: "approximate time")
        case .dayOnly: return String(localized: "day only, no time")
        }
    }

    // MARK: Availability, metrics, processing

    static func availabilityState(_ s: PhysiologyContext.AvailabilityState) -> String {
        switch s {
        case .supported: return String(localized: "Available")
        case .partial: return String(localized: "Partly available")
        case .unavailable: return String(localized: "Unavailable")
        case .unverified: return String(localized: "Unverified")
        case .unsupported: return String(localized: "Not supported")
        }
    }

    static func assessment(_ name: String) -> String {
        switch name {
        case "ppg_waveform_quality": return String(localized: "PPG waveform quality")
        case "spo2_signal_validity", "spo2_validity", "spo2_candidate", "spo2": return String(localized: "Blood oxygen")
        case "core_temperature": return String(localized: "Core temperature")
        case "posture": return String(localized: "Posture (likelihood only)")
        case "hrv_signal_validity": return String(localized: "HRV signal quality")
        case "respiratory_signal_validity": return String(localized: "Respiratory rate signal quality")
        case "skin_temperature_signal_validity": return String(localized: "Skin temperature signal quality")
        case "activity_composition": return String(localized: "Activity data")
        case "measurement_product": return String(localized: "Measurement")
        case "stable_awake_eligibility": return String(localized: "Stable awake check")
        case "sleep_measurement_eligibility": return String(localized: "Sleep check")
        case "activity_response_eligibility": return String(localized: "Activity response check")
        default: return capitalizedFirst(humanized(name))
        }
    }

    static func metric(_ m: PhysiologyContext.MetricKind) -> String {
        switch m {
        case .heartRate: return String(localized: "Heart rate")
        case .hrvRmssd: return String(localized: "HRV (RMSSD)")
        case .hrvSdnn: return String(localized: "HRV (SDNN)")
        case .restingHeartRate: return String(localized: "Resting heart rate")
        case .respiratoryRate: return String(localized: "Respiratory rate")
        case .skinTemperature: return String(localized: "Skin temperature")
        case .spo2Candidate: return String(localized: "Blood oxygen (unverified)")
        }
    }

    static func mode(_ m: PhysiologyContext.ProcessingMode) -> String {
        switch m {
        case .causalLive: return String(localized: "Live: only what was known at the time")
        case .retrospective: return String(localized: "Revised with later data")
        }
    }

    static func finality(_ f: PhysiologyContext.Finality) -> String {
        switch f {
        case .provisional: return String(localized: "Provisional: can still change")
        case .final: return String(localized: "Final")
        }
    }

    static func finalityBadge(_ f: PhysiologyContext.Finality) -> ContextBadge {
        switch f {
        case .provisional: return ContextBadge(text: String(localized: "Provisional"), tone: .warning)
        case .final: return ContextBadge(text: String(localized: "Final"), tone: .neutral)
        }
    }

    /// Badges for how a product was computed: provisional, revised (retrospective), unverified.
    static func processingBadges(mode: PhysiologyContext.ProcessingMode?, finality: PhysiologyContext.Finality?,
                                 unverified: Bool) -> [ContextBadge] {
        var out: [ContextBadge] = []
        if finality == .provisional { out.append(ContextBadge(text: String(localized: "Provisional"), tone: .warning)) }
        if mode == .retrospective { out.append(ContextBadge(text: String(localized: "Revised"), tone: .neutral)) }
        if unverified { out.append(ContextBadge(text: String(localized: "Unverified"), tone: .warning)) }
        return out
    }

    // MARK: Numbers and times

    static func unitLabel(_ units: String) -> String {
        switch units {
        case "ms": return "ms"
        case "bpm": return "bpm"
        case "breaths_per_min": return String(localized: "br/min")
        case "degC": return "°C"
        case "percent": return "%"
        case "s": return "s"
        default: return units
        }
    }

    static func fractionDigits(_ units: String) -> Int {
        switch units {
        case "breaths_per_min", "percent": return 1
        case "degC": return 2
        default: return 0
        }
    }

    /// A value in its original units ("62 ms").
    static func value(_ v: Double, units: String, locale: Locale = .current) -> String {
        let digits = fractionDigits(units)
        let number = v.formatted(.number.precision(.fractionLength(digits)).locale(locale))
        let unit = unitLabel(units)
        return unit == "%" ? number + unit : "\(number) \(unit)"
    }

    /// A signed difference in original units: "+6 ms", "−3 bpm", "±0 ms".
    static func signedDifference(_ v: Double, units: String, locale: Locale = .current) -> String {
        let digits = fractionDigits(units)
        let scale = pow(10, Double(digits))
        let rounded = (v * scale).rounded() / scale
        let magnitude = abs(rounded).formatted(.number.precision(.fractionLength(digits)).locale(locale))
        let sign = rounded > 0 ? "+" : (rounded < 0 ? "\u{2212}" : "\u{00B1}")
        let unit = unitLabel(units)
        return unit == "%" ? "\(sign)\(magnitude)\(unit)" : "\(sign)\(magnitude) \(unit)"
    }

    static func percent(_ share: Double, locale: Locale = .current) -> String {
        let clamped = min(1, max(0, share.isFinite ? share : 0))
        return clamped.formatted(.percent.precision(.fractionLength(0)).locale(locale))
    }

    /// "45 s", "12 min", "7 h 32 min".
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return String(localized: "\(s) s") }
        let minutes = (s + 30) / 60
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) min")
    }

    static func zone(_ identifier: String?, offsetS: Int? = nil) -> TimeZone {
        if let identifier, let z = TimeZone(identifier: identifier) { return z }
        if let offsetS, let z = TimeZone(secondsFromGMT: offsetS) { return z }
        return .current
    }

    private static func timeFormatter(zone: TimeZone, locale: Locale) -> DateFormatter {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }

    static func time(_ ts: Int, zone: TimeZone, locale: Locale = .current) -> String {
        timeFormatter(zone: zone, locale: locale).string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// "23:10–06:42" in `zone` (the end is exclusive, shown as the instant it ends).
    static func timeRange(_ interval: PhysiologyContext.Interval, zone: TimeZone, locale: Locale = .current) -> String {
        let f = timeFormatter(zone: zone, locale: locale)
        let a = f.string(from: Date(timeIntervalSince1970: TimeInterval(interval.start)))
        let b = f.string(from: Date(timeIntervalSince1970: TimeInterval(interval.end)))
        return "\(a)\u{2013}\(b)"
    }

    /// "Oct 1" for a day key (or the key itself when it is not one).
    static func day(_ key: String, locale: Locale = .current) -> String {
        guard let date = PhysiologyContextDates.date(key) else { return key }
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = PhysiologyContextDates.calendar.timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: date)
    }

    /// "Oct 1" for an instant in `zone`.
    static func date(_ ts: Int, zone: TimeZone, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// "Oct 1, 07:10" for an instant in `zone`.
    static func dayAndTime(_ ts: Int, zone: TimeZone, locale: Locale = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("MMMdjmm")
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    /// "PDT, UTC−7" — the zone the times are shown in.
    static func zoneLabel(_ zone: TimeZone, at ts: Int, utcOffsetS: Int? = nil) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(ts))
        let offset = utcOffsetS ?? zone.secondsFromGMT(for: date)
        let sign = offset < 0 ? "\u{2212}" : "+"
        let h = abs(offset) / 3600, m = (abs(offset) % 3600) / 60
        let utc = m == 0 ? "UTC\(sign)\(h)" : String(format: "UTC%@%d:%02d", sign, h, m)
        if let abbreviation = zone.abbreviation(for: date), !abbreviation.hasPrefix("GMT") {
            return "\(abbreviation), \(utc)"
        }
        return utc
    }

    /// "Measured 23:10–06:42" for a nightly value or anything three hours or longer, else
    /// "5-min window 14:05–14:10".
    static func supportLine(_ e: PhysiologyContext.MeasurementEnvelope, locale: Locale = .current) -> String {
        let zone = zone(e.localTime.timezoneId, offsetS: e.localTime.utcOffsetS)
        let range = timeRange(e.support, zone: zone, locale: locale)
        let length = e.support.duration
        if MeasurementContextSelection.isNightly(e) || length >= 3 * 3600 {
            return String(localized: "Measured \(range)")
        }
        if length < 60 { return String(localized: "\(length)-s window \(range)") }
        let minutes = (length + 30) / 60
        return String(localized: "\(minutes)-min window \(range)")
    }

    /// The share of the measurement with known activity, and what was unknown.
    static func coverageLine(_ e: PhysiologyContext.MeasurementEnvelope, locale: Locale = .current) -> String? {
        let a = e.activity
        guard a.intervalS > 0 else { return nil }
        var parts: [String] = []
        if a.source == .none || a.coveredS <= 0 {
            parts.append(String(localized: "No activity data for this measurement"))
        } else {
            let known = a.labels.reduce(0) { $0 + $1.seconds } / Double(a.intervalS)
            let unknown = (a.unknownS + a.uncoveredS) / Double(a.intervalS)
            parts.append(String(localized: "Activity known for \(percent(known, locale: locale))"))
            if unknown >= 0.005 { parts.append(String(localized: "\(percent(unknown, locale: locale)) unknown")) }
        }
        if let coverage = e.validity.coverage {
            parts.append(String(localized: "signal \(percent(coverage, locale: locale))"))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    /// The short state of a measurement: sleep, stable awake, recent movement, or insufficient context.
    static func statePhrase(_ e: PhysiologyContext.MeasurementEnvelope) -> String {
        if e.verdict(.sleepMeasurement)?.state == .eligible { return String(localized: "Sleep measurement") }
        if e.verdict(.stableAwakeRest)?.state == .eligible { return String(localized: "Stable awake measurement") }
        if let movement = recentMovement(e) { return recentMovementPhrase(movement) }
        if e.verdict(.activityResponse)?.state == .eligible {
            return String(localized: "Measurement during or after activity")
        }
        return String(localized: "Insufficient context")
    }

    /// The movement label behind "recent walking": locomotion during at least a tenth of the measurement, or
    /// supported movement that ended within 15 minutes before it.
    static func recentMovement(_ e: PhysiologyContext.MeasurementEnvelope) -> String? {
        let moving = e.activity.labels
            .filter { PhysiologyContext.MotionVocabulary.isLocomotion($0.label) && $0.share >= 0.10 }
            .max { $0.share < $1.share }
        if let moving { return moving.label }
        if let since = e.preceding.secondsSinceSupportedActivity, since <= 15 * 60 {
            return e.preceding.lastSupportedActivityLabel ?? "movement"
        }
        return nil
    }
}

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

    /// A reason code's plain meaning, written to follow "…: " in a sentence (lower case, no full stop).
    static func reason(_ code: PhysiologyContext.ReasonCode) -> String {
        switch code.rawValue {
        // Join and engine (contracts.md §12)
        case "invalid_interval": return String(localized: "the measurement time is not valid")
        case "no_activity_records": return String(localized: "no activity data covers it")
        case "uncovered_time": return String(localized: "part of it has no activity data")
        case "mostly_uncovered": return String(localized: "most of it has no activity data")
        case "unknown_label_time": return String(localized: "activity is unknown for part of it")
        case "mixed_states": return String(localized: "activity changed during it")
        case "overlapping_records_resolved": return String(localized: "overlapping activity records were reconciled")
        case "heart_rate_dependent_source": return String(localized: "the activity labels read heart rate")
        case "gap": return String(localized: "a gap in the data")
        case "movement": return String(localized: "movement")
        case "unknown_label": return String(localized: "unknown activity")
        case "lookback_limit": return String(localized: "the look-back limit")
        case "history_from_future_dropped": return String(localized: "later data was left out")
        case "measurement_after_cutoff": return String(localized: "a measurement arrived after the cut-off")
        case "no_measurements": return String(localized: "no measurements for this day")
        case "no_observations": return String(localized: "no sensor data for this day")
        case "activity_evidence_unavailable": return String(localized: "no motion data to judge activity")
        case "sleep_evidence_unavailable": return String(localized: "no sleep was detected")
        case "shared_beat_intervals": return String(localized: "these values come from the same heartbeats")
        case "labels_read_heart_rate": return String(localized: "these labels read heart rate")
        case "motion_shared_across_systems": return String(localized: "the same motion data feeds several checks")
        case "not_implemented": return String(localized: "this check is not available yet")
        case "regime_differs": return String(localized: "it was measured under different conditions")
        // Eligibility and validity (the signal workstream's registry; unknown codes fall back to words)
        case "insufficient_stationary_share", "not_stationary", "insufficient_stillness":
            return String(localized: "not still for enough of it")
        case "insufficient_coverage", "low_coverage", "insufficient_qualified_coverage":
            return String(localized: "too little signal coverage")
        case "insufficient_preceding_stillness", "preceding_stillness_short":
            return String(localized: "not still for long enough beforehand")
        case "awake_unknown", "awake_evidence_unknown", "sleep_state_unknown":
            return String(localized: "it is unclear whether you were awake")
        case "wear_unknown", "wear_evidence_unknown":
            return String(localized: "it is unclear whether the strap was worn")
        case "not_worn": return String(localized: "the strap may not have been worn")
        case "asleep", "during_sleep": return String(localized: "it was during sleep")
        case "not_in_sleep", "outside_sleep": return String(localized: "it was outside detected sleep")
        case "recent_exertion": return String(localized: "activity shortly before")
        case "recent_walking", "recent_locomotion": return String(localized: "walking shortly before")
        case "locomotion", "walking_during_support", "locomotion_during_support":
            return String(localized: "walking during the measurement")
        case "signal_invalid", "validity_invalid": return String(localized: "the signal did not pass quality checks")
        case "signal_missing", "validity_missing": return String(localized: "no signal")
        case "unverified": return String(localized: "the value is unverified")
        case "no_bout", "no_supported_bout": return String(localized: "no supported activity bout around it")
        case "insufficient_history", "insufficient_days", "insufficient_support":
            return String(localized: "not enough comparable days yet")
        // Bout censoring (System D)
        case "disconnect": return String(localized: "the strap disconnected")
        case "continued_movement": return String(localized: "movement continued")
        case "next_bout": return String(localized: "another bout started")
        case "cutoff_reached": return String(localized: "the data ends here for now")
        case "no_follow_up": return String(localized: "no data afterwards")
        default: return humanized(code.rawValue)
        }
    }

    /// The first reason in plain words, or nil.
    static func topReason(_ codes: [PhysiologyContext.ReasonCode]) -> String? {
        codes.first.map(reason)
    }

    /// Every reason in plain words, as one sentence fragment list.
    static func reasonList(_ codes: [PhysiologyContext.ReasonCode]) -> String? {
        guard !codes.isEmpty else { return nil }
        var seen = Set<String>()
        let phrases = codes.map(reason).filter { seen.insert($0).inserted }
        return capitalizedFirst(phrases.joined(separator: "; "))
    }

    // MARK: Activity

    static func activityLabel(_ label: String) -> String {
        switch label {
        case "still": return String(localized: "Still")
        case "stationary": return String(localized: "Stationary")
        case "low_movement": return String(localized: "Low movement")
        case "sleeping": return String(localized: "Sleeping")
        case "lying_down": return String(localized: "Lying down")
        case "sitting", "sitting_desk": return String(localized: "Sitting")
        case "standing": return String(localized: "Standing")
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

    // MARK: Episodes

    static func episodeState(_ state: PhysiologyContext.EpisodeState) -> String {
        switch state {
        case .usualVariation: return String(localized: "Within usual variation")
        case .transientDeviation: return String(localized: "Transient deviation from reference")
        case .recurringEpisode: return String(localized: "Recurring deviation from reference")
        case .persistentShift: return String(localized: "Persistent change from historical reference")
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

    /// The follow-up after a bout: complete, still going, or cut short (and why).
    static func boutStatus(_ bout: PhysiologyContext.ExertionBout) -> String {
        switch bout.status {
        case .complete: return String(localized: "Follow-up complete")
        case .ongoing: return String(localized: "Ongoing")
        case .censored:
            return topReason(bout.reasons).map { String(localized: "Follow-up incomplete: \($0)") }
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

    /// Recording status of a category. Not recorded is not "none".
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
        case "spo2_validity", "spo2_candidate", "spo2": return String(localized: "Blood oxygen")
        case "core_temperature": return String(localized: "Core temperature")
        case "posture": return String(localized: "Posture")
        case "hrv_signal_validity": return String(localized: "HRV signal quality")
        case "stable_awake_eligibility": return String(localized: "Stable awake check")
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

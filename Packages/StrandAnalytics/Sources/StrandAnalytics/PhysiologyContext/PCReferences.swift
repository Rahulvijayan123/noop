import Foundation

// PCReferences.swift — System F (part 1): daily context-conditioned values and reference views (spec §12.1-12.2).
//
// OWNER: statistics workstream. Estimators, defaults and their justification: docs/physiology-context/notes/
// statistics.md.
//
// Every comparison scores an observation against references built ONLY from earlier days, before the observation
// can enter any adaptive reference. Frozen references are explicitly versioned and never silently replaced. A
// robust z is a distance in robust-scale units, not a probability.
//
// Units. `center`, `signedDifference` and `centerUncertainty` are in the original units of the series. `scale`,
// `robustZ` and `transformedDifference` are on the transformed scale named by `transform` (`ln` for RMSSD / SDNN,
// so `scale` is in ln units and `transformedDifference` is the ln ratio `ln(value / center)`). `transformedCenter`
// is the center on that scale.

extension PhysiologyContext {

    /// A minimum scale for every series whose key starts with `seriesPrefix` (longest prefix wins), in the series'
    /// transformed units (ln units for log-transformed series). Zero MAD never produces infinite certainty.
    public struct ScaleFloor: Codable, Equatable, Sendable {
        public var seriesPrefix: String
        public var floor: Double
        public init(seriesPrefix: String, floor: Double) { self.seriesPrefix = seriesPrefix; self.floor = floor }
    }

    public struct ReferenceConfig: Codable, Equatable, Sendable {
        public var version = "pc-reference-2"

        // Daily values (contracts §5).
        /// Minimum independent stable-awake windows behind a daily value (and behind a time-band stratum value).
        public var stableAwakeMinWindows = 3
        /// Window length of the stable-awake series (5-minute windows); other lengths are not pooled with them.
        public var stableAwakeWindowS = 300
        /// `.respiratoryRate` enters through its explicit adapter (`respiratoryStableAwakeValues`): its estimates are
        /// 2-minute RSA windows, pooled into the same aligned 5-minute windows before the daily median (spec-02).
        public var stableAwakeMetrics: [MetricKind] = [.hrvRmssd, .hrvSdnn, .heartRate, .respiratoryRate]
        /// Respiratory stable-awake adapter: a local-grid 5-minute window takes a value only when it holds at least
        /// this many non-overlapping eligible, valid respiratory estimates wholly inside it (2 x 120 s covers 240 of
        /// its 300 s).
        public var stableAwakeRespMinEstimatesPerWindow = 2
        /// Nightly snapshot metrics. SpO2 is never a comparison input; nightly SDNN is admitted only as an index
        /// (mean of fixed windows) because whole-session SDNN grows with session length.
        public var nightlyMetrics: [MetricKind] = [.hrvRmssd, .hrvSdnn, .restingHeartRate, .respiratoryRate,
                                                   .skinTemperature, .heartRate]
        /// A nightly value belongs to the local day containing its support end (contracts §2 sleep ownership).
        public var nightlyOwnershipByEnd = true
        /// Local-time band starts (hours) for the stable-awake strata used by the conditioned view.
        public var timeBandStartHours: [Int] = [0, 6, 12, 18]
        public var stratifyStableAwakeByTimeBand = true

        /// Series never compared (coverage bookkeeping is not physiology).
        public var excludedSeriesPrefixes: [String] = ["coverage."]
        /// Series compared on the ln scale (RMSSD and SDNN are right-skewed and vary multiplicatively).
        public var logTransformSeriesPrefixes: [String] = ["hrv_rmssd.", "hrv_sdnn.", "hrv_sdnn_index."]

        // Recent view.
        public var recentWindowDays = 7
        public var recentMinDays = 3

        // Rolling view.
        public var rollingWindowDays = 28
        public var rollingMinDays = 7
        public var rollingReadyDays = 14
        /// `median_mad` (default) or `winsorized_mean_sd` (mean / SD of values winsorized at
        /// median ± `winsorizeK` robust scales; more efficient, less robust).
        public var rollingEstimator = "median_mad"
        public var winsorizeK = 2.5
        /// Apply `RobustStats.madSmallSampleFactor` (unbiased scale at Gaussian data for small n).
        public var smallSampleCorrection = true
        /// The newest supported day is older than this → `stale_history`.
        public var staleAfterDays = 7

        // Frozen view.
        public var frozenVersion = 1
        /// The reference is the first `frozenSelectionDays` supported days of the regime that fit inside
        /// `frozenMaxSpanDays` calendar days.
        public var frozenSelectionDays = 14
        public var frozenMaxSpanDays = 42
        /// Modes allowed to register a frozen reference (frozen references are not keyed by mode in storage).
        public var frozenRegistrationModes: [ProcessingMode] = [.retrospective]

        // Causal (live) partial days.
        /// Parent series whose daily value accumulates over the day (a median of the windows, or a rate over the
        /// waking time, seen so far). In causal mode such a value can describe a partial day (cutoff before the day
        /// end) while its history holds whole days, and nothing records the local-time coverage of either. Its
        /// recent / rolling / frozen comparisons therefore carry no distance (`partial_day_composition`), and the
        /// value does not enter that day's episodes. The like-for-like causal comparison of stable-awake values is
        /// the time-band stratum (conditioned view). Nightly values are complete when published and are not listed.
        public var causalPartialDaySeriesMarkers: [String] = [".stable_awake_", "functional."]

        // Conditioned view (stable-awake time-band strata shrunk toward the all-day parent).
        /// Child (time-band) history window; kept within the 28-day cross-day invalidation horizon (contracts §6).
        public var conditionedWindowDays = 28
        /// Shrinkage constant k in the child weight `n / (n + k)` (days).
        public var conditionedShrinkageDays = 7.0
        public var conditionedMinChildDays = 3
        public var conditionedReadyChildDays = 7

        // Scale floors (engineering choices in native resolution; notes/statistics.md §2.2).
        public var scaleFloors: [ScaleFloor] = [
            ScaleFloor(seriesPrefix: "hrv_rmssd.", floor: 0.05),
            ScaleFloor(seriesPrefix: "hrv_sdnn", floor: 0.05),
            ScaleFloor(seriesPrefix: "resting_hr.", floor: 1.0),
            ScaleFloor(seriesPrefix: "heart_rate.", floor: 1.0),
            // Bout HR rise and post-effort HR decline: differences of integer-bpm readings.
            ScaleFloor(seriesPrefix: "hr_response.", floor: 1.0),
            ScaleFloor(seriesPrefix: "hr_recovery_", floor: 1.0),
            ScaleFloor(seriesPrefix: "resp_rate.", floor: 0.3),
            ScaleFloor(seriesPrefix: "skin_temp.", floor: 0.1),
            // Functional features (System G), by units. Rates per worn waking hour / per active minute: one count
            // (one bout, one 60-s minimum bout of locomotion, one transition) in the minimum denominator that admits
            // the value (4 worn waking hours, 5 active minutes), so a single count on a constant history alone
            // stays within |z| ≤ 1.
            ScaleFloor(seriesPrefix: "functional.bouts_per_worn_hour", floor: 0.25),
            ScaleFloor(seriesPrefix: "functional.locomotion_s_per_worn_hour", floor: 15),
            ScaleFloor(seriesPrefix: "functional.active_to_rest_per_min", floor: 0.2),
            // One pause per 10 minutes of bout time (the middle duration-band edge).
            ScaleFloor(seriesPrefix: "functional.pauses_per_bout_hour", floor: 6),
            // Counts: integer resolution. Seconds totals: one 60-s minimum bout of locomotion. Medians of bout and
            // rest durations: half the 60-s minimum bout.
            ScaleFloor(seriesPrefix: "functional.bout_count", floor: 1),
            ScaleFloor(seriesPrefix: "functional.locomotion_s", floor: 60),
            ScaleFloor(seriesPrefix: "functional.median_bout_s", floor: 30),
            ScaleFloor(seriesPrefix: "functional.rest_after_bout_median_s", floor: 30),
            // Uncalibrated counter steps per minute: integer resolution; within-bout CV: one percentage point.
            ScaleFloor(seriesPrefix: "functional.cadence_steps_per_min", floor: 1),
            ScaleFloor(seriesPrefix: "functional.cadence_within_bout_cv", floor: 0.01),
        ]
        /// Floor for unlisted identity-scale series: the larger of this share of |center| and
        /// `defaultAbsoluteFloor` (reason `scale_floor_default`).
        public var defaultRelativeFloor = 0.02
        /// Absolute floor of unlisted identity-scale series: one native unit. Conservative for series with a
        /// fine resolution (it can only shrink their distances), and it keeps a zero-centred constant history
        /// (e.g. a count that was 0 every day) from turning one count into near-infinite certainty.
        public var defaultAbsoluteFloor = 1.0
        /// Floor for unlisted ln-scale series (ln units; reason `scale_floor_default`).
        public var defaultLogFloor = 0.05
        /// Numerical lower bound of every scale (no series reaches it with the floors above).
        public var minimumScale = 1e-6

        public init() {}
    }

    /// One day's context-conditioned value of one series (the unit references and episodes are built from).
    public struct DailyValue: Codable, Equatable, Sendable {
        public var day: String
        /// Series identity, e.g. `hrv_rmssd.sleep_night`, `hrv_rmssd.stable_awake_5min`,
        /// `functional.locomotion_s_per_worn_hour`. Defines the context condition.
        public var seriesKey: String
        public var regimeKey: String
        public var metric: MetricKind?
        /// Value in original units.
        public var value: Double
        public var units: String
        /// Independent support units behind the value (windows, bouts or nights) and their kind.
        public var supportCount: Int
        public var supportUnit: String
        public var supportS: Int
        public var mode: ProcessingMode
        public var finality: Finality
        /// Envelopes (or bouts) the value was aggregated from.
        public var sourceIds: [String]
        public var reasons: [ReasonCode]
        public init(day: String, seriesKey: String, regimeKey: String, metric: MetricKind?, value: Double,
                    units: String, supportCount: Int, supportUnit: String, supportS: Int, mode: ProcessingMode,
                    finality: Finality, sourceIds: [String] = [], reasons: [ReasonCode] = []) {
            self.day = day; self.seriesKey = seriesKey; self.regimeKey = regimeKey; self.metric = metric
            self.value = value; self.units = units; self.supportCount = supportCount
            self.supportUnit = supportUnit; self.supportS = supportS; self.mode = mode; self.finality = finality
            self.sourceIds = sourceIds; self.reasons = reasons
        }
    }

    public enum ReferenceView: String, Codable, CaseIterable, Sendable {
        case recent, rolling, frozen, conditioned
    }

    public enum ReferenceStatus: String, Codable, CaseIterable, Sendable {
        case ready, provisional, insufficient, unavailable
        case regimeMismatch = "regime_mismatch"
    }

    /// An explicitly versioned historical reference. It is a historical reference, not a healthy baseline.
    public struct FrozenReference: Codable, Equatable, Sendable {
        public var id: String
        public var seriesKey: String
        public var regimeKey: String
        public var version: Int
        public var fromDay: String
        public var toDay: String
        public var supportDays: Int
        /// Median on the `transform` scale.
        public var center: Double
        /// Floored `1.4826 * MAD` (small-sample corrected) on the `transform` scale.
        public var scale: Double
        /// `identity` | `ln`.
        public var transform: String
        /// How the reference interval was selected (recorded verbatim, e.g. `first_14_supported_days_in_regime`).
        public var selectionRule: String
        public var createdForDay: String
        public var policyFingerprint: String
        public init(id: String, seriesKey: String, regimeKey: String, version: Int, fromDay: String, toDay: String,
                    supportDays: Int, center: Double, scale: Double, transform: String, selectionRule: String,
                    createdForDay: String, policyFingerprint: String) {
            self.id = id; self.seriesKey = seriesKey; self.regimeKey = regimeKey; self.version = version
            self.fromDay = fromDay; self.toDay = toDay; self.supportDays = supportDays; self.center = center
            self.scale = scale; self.transform = transform; self.selectionRule = selectionRule
            self.createdForDay = createdForDay; self.policyFingerprint = policyFingerprint
        }
    }

    /// One observation compared with one reference view.
    public struct ReferenceComparison: Codable, Equatable, Sendable, Hashable {
        public var day: String
        public var seriesKey: String
        public var regimeKey: String
        public var view: ReferenceView
        public var referenceId: String?
        public var status: ReferenceStatus
        /// Independent supported days behind the reference (child days for the conditioned view).
        public var supportDays: Int
        public var fromDay: String?
        public var toDay: String?
        public var value: Double
        /// Reference center in original units (for `ln`, `exp` of the ln-scale center).
        public var center: Double?
        /// Reference scale on the `transform` scale.
        public var scale: Double?
        public var scaleFloored: Bool
        /// `value - center` in original units.
        public var signedDifference: Double?
        /// Difference on the transformed scale (e.g. ln ratio for RMSSD), when a transform applies.
        public var transformedDifference: Double?
        /// Robust distance in scale units; never a probability. Nil unless the status is ready or provisional.
        public var robustZ: Double?
        /// Uncertainty of the reference center (same units as `center`), when estimable. Approximate: see
        /// `centerUncertaintyMethod`.
        public var centerUncertainty: Double?
        public var transform: String
        /// Share of the reference contributed by a parent / population level (0 when purely personal).
        public var pooledContribution: Double
        public var reasons: [ReasonCode]

        // Added by the statistics workstream (defaults keep the contract initializer valid).
        /// Center on the `transform` scale.
        public var transformedCenter: Double?
        /// How `centerUncertainty` was approximated, e.g. `median_se_iid_normal_approx`.
        public var centerUncertaintyMethod: String
        /// `median_mad` | `winsorized_mean_sd` | `pooled_median_mad` | `frozen_median_mad`.
        public var estimator: String
        /// Parent-level supported days (conditioned view), else 0.
        public var parentSupportDays: Int

        public init(day: String, seriesKey: String, regimeKey: String, view: ReferenceView, referenceId: String?,
                    status: ReferenceStatus, supportDays: Int, fromDay: String?, toDay: String?, value: Double,
                    center: Double?, scale: Double?, scaleFloored: Bool, signedDifference: Double?,
                    transformedDifference: Double?, robustZ: Double?, centerUncertainty: Double?, transform: String,
                    pooledContribution: Double, reasons: [ReasonCode], transformedCenter: Double? = nil,
                    centerUncertaintyMethod: String = "", estimator: String = "", parentSupportDays: Int = 0) {
            self.day = day; self.seriesKey = seriesKey; self.regimeKey = regimeKey; self.view = view
            self.referenceId = referenceId; self.status = status; self.supportDays = supportDays
            self.fromDay = fromDay; self.toDay = toDay; self.value = value; self.center = center
            self.scale = scale; self.scaleFloored = scaleFloored; self.signedDifference = signedDifference
            self.transformedDifference = transformedDifference; self.robustZ = robustZ
            self.centerUncertainty = centerUncertainty; self.transform = transform
            self.pooledContribution = pooledContribution; self.reasons = reasons
            self.transformedCenter = transformedCenter; self.centerUncertaintyMethod = centerUncertaintyMethod
            self.estimator = estimator; self.parentSupportDays = parentSupportDays
        }

        enum CodingKeys: String, CodingKey {
            case day, seriesKey, regimeKey, view, referenceId, status, supportDays, fromDay, toDay, value, center
            case scale, scaleFloored, signedDifference, transformedDifference, robustZ, centerUncertainty
            case transform, pooledContribution, reasons, transformedCenter, centerUncertaintyMethod, estimator
            case parentSupportDays
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decode(String.self, forKey: .day)
            seriesKey = try c.decode(String.self, forKey: .seriesKey)
            regimeKey = try c.decode(String.self, forKey: .regimeKey)
            view = try c.decode(ReferenceView.self, forKey: .view)
            referenceId = try c.decodeIfPresent(String.self, forKey: .referenceId)
            status = try c.decode(ReferenceStatus.self, forKey: .status)
            supportDays = try c.decode(Int.self, forKey: .supportDays)
            fromDay = try c.decodeIfPresent(String.self, forKey: .fromDay)
            toDay = try c.decodeIfPresent(String.self, forKey: .toDay)
            value = try c.decode(Double.self, forKey: .value)
            center = try c.decodeIfPresent(Double.self, forKey: .center)
            scale = try c.decodeIfPresent(Double.self, forKey: .scale)
            scaleFloored = try c.decode(Bool.self, forKey: .scaleFloored)
            signedDifference = try c.decodeIfPresent(Double.self, forKey: .signedDifference)
            transformedDifference = try c.decodeIfPresent(Double.self, forKey: .transformedDifference)
            robustZ = try c.decodeIfPresent(Double.self, forKey: .robustZ)
            centerUncertainty = try c.decodeIfPresent(Double.self, forKey: .centerUncertainty)
            transform = try c.decode(String.self, forKey: .transform)
            pooledContribution = try c.decode(Double.self, forKey: .pooledContribution)
            reasons = try c.decode([ReasonCode].self, forKey: .reasons)
            transformedCenter = try c.decodeIfPresent(Double.self, forKey: .transformedCenter)
            centerUncertaintyMethod = try c.decodeIfPresent(String.self, forKey: .centerUncertaintyMethod) ?? ""
            estimator = try c.decodeIfPresent(String.self, forKey: .estimator) ?? ""
            parentSupportDays = try c.decodeIfPresent(Int.self, forKey: .parentSupportDays) ?? 0
        }
    }

    public enum ContextReferences {

        public static let version = "pc-reference-2"

        // MARK: Reason codes
        // Daily values.
        public static let nightlySnapshot: ReasonCode = "nightly_snapshot"
        public static let stableAwakeWindows: ReasonCode = "stable_awake_windows"
        public static let timeBandStratum: ReasonCode = "time_band_stratum"
        public static let degradedValidityIncluded: ReasonCode = "degraded_validity_included"
        public static let multipleNightlyValues: ReasonCode = "multiple_nightly_values_longest_kept"
        public static let overlappingWindowsNotCounted: ReasonCode = "overlapping_windows_not_counted"
        public static let relativeUseOnly: ReasonCode = "relative_use_only"
        // Support and history.
        public static let noHistory: ReasonCode = "no_history"
        public static let insufficientHistory: ReasonCode = "insufficient_history"
        public static let provisionalSupport: ReasonCode = "provisional_support"
        public static let historyInOtherRegimeOnly: ReasonCode = "history_in_other_regime_only"
        public static let otherRegimeHistoryNotPooled: ReasonCode = "other_regime_history_not_pooled"
        public static let staleHistory: ReasonCode = "stale_history"
        public static let historyValuesExcluded: ReasonCode = "history_values_excluded"
        public static let duplicateHistoryDayResolved: ReasonCode = "duplicate_history_day_resolved"
        public static let futureHistoryIgnored: ReasonCode = "future_history_ignored"
        // Scale and transform.
        public static let scaleFloored: ReasonCode = "scale_floored"
        public static let constantHistory: ReasonCode = "constant_history"
        public static let logTransform: ReasonCode = "log_transform"
        public static let nonPositiveValueForLog: ReasonCode = "non_positive_value_for_log"
        public static let smallSampleScaleCorrection: ReasonCode = "small_sample_scale_correction"
        public static let centerUncertaintyApproximate: ReasonCode = "center_uncertainty_approximate"
        public static let winsorizedMeanEstimator: ReasonCode = "winsorized_mean_estimator"
        // Views.
        public static let scaleFromRollingView: ReasonCode = "scale_from_rolling_view"
        public static let scaleFromRecentWindow: ReasonCode = "scale_from_recent_window"
        public static let frozenHistoricalNotHealthy: ReasonCode = "frozen_reference_is_historical_not_healthy"
        public static let frozenRegisteredThisRun: ReasonCode = "frozen_registered_this_run"
        public static let frozenNotRegistered: ReasonCode = "frozen_not_registered"
        public static let frozenRegistersInOtherMode: ReasonCode = "frozen_registers_in_other_mode"
        public static let frozenScaleRefloored: ReasonCode = "frozen_scale_floored_by_current_policy"
        /// A frozen reference is registered for (series, regime, version) but its selection window does not end
        /// before the scored day (e.g. a back-filled day inside it). The registered reference is the authority:
        /// no second reference is registered, and this day has no frozen comparison.
        public static let frozenWindowNotCompleteForDay: ReasonCode = "frozen_window_not_complete_for_day"
        /// Causal mode: a frozen reference created for the scored day or later (or whose window ends on or after
        /// it) was passed in and ignored; it was not available to a live decision on that day.
        public static let frozenCreatedAfterDayIgnored: ReasonCode = "frozen_created_after_day_ignored"
        /// No series-specific scale floor is listed; the default floor rule applied.
        public static let scaleFloorDefault: ReasonCode = "scale_floor_default"
        /// Causal partial day: the value accumulates over the day so far while its history holds whole days, so
        /// no distance is given (see `causalPartialDaySeriesMarkers`).
        public static let partialDayComposition: ReasonCode = "partial_day_composition"
        public static let pooledTowardParent: ReasonCode = "pooled_toward_parent"
        public static let contextUnsupportedParentOnly: ReasonCode = "context_unsupported_parent_only"
        public static let parentInsufficientChildOnly: ReasonCode = "parent_insufficient_child_only"
        public static let noPopulationPrior: ReasonCode = "no_population_prior"
        /// The stable-awake respiratory value pools shorter RSA estimates into aligned 5-minute windows
        /// (`respiratoryStableAwakeValues`); see `ReferenceConfig.stableAwakeRespMinEstimatesPerWindow`.
        public static let stableAwakeRespirationWindow: ReasonCode = "stable_awake_respiration_window"

        public static let reasonCodes: [ReasonCode] = [
            nightlySnapshot, stableAwakeWindows, timeBandStratum, degradedValidityIncluded, multipleNightlyValues,
            overlappingWindowsNotCounted, relativeUseOnly, noHistory, insufficientHistory, provisionalSupport,
            historyInOtherRegimeOnly, otherRegimeHistoryNotPooled, staleHistory, historyValuesExcluded,
            duplicateHistoryDayResolved, futureHistoryIgnored, scaleFloored, constantHistory, logTransform,
            nonPositiveValueForLog, smallSampleScaleCorrection, centerUncertaintyApproximate,
            winsorizedMeanEstimator, scaleFromRollingView, scaleFromRecentWindow, frozenHistoricalNotHealthy,
            frozenRegisteredThisRun, frozenNotRegistered, frozenRegistersInOtherMode, frozenScaleRefloored,
            pooledTowardParent, contextUnsupportedParentOnly, parentInsufficientChildOnly, noPopulationPrior,
            frozenWindowNotCompleteForDay, frozenCreatedAfterDayIgnored, scaleFloorDefault, partialDayComposition,
            stableAwakeRespirationWindow,
        ]

        /// Marker between a parent series key and its local-time-band stratum (`<parent>.band_06_12`).
        public static let stratumMarker = ".band_"

        // MARK: - Daily values

        /// Daily context-conditioned values from the day's envelopes (nightly products and eligible windows).
        ///
        /// - Nightly: `snapshot.*` envelopes that are sleep-measurement eligible with validity valid or degraded
        ///   → `<metric>.sleep_night`, one per (series, regime); the night belongs to the day containing its end.
        /// - Stable awake: 5-minute series / context windows that are stable-awake eligible and valid, starting in
        ///   the day → median per (series, regime) when at least `stableAwakeMinWindows` independent windows exist;
        ///   plus the same per local time band (`<series>.band_HH_HH`) for the conditioned view.
        /// Values are never zero-filled: no qualifying envelope → no daily value.
        public static func dailyValues(envelopes: [MeasurementEnvelope], identity: DayIdentity, mode: ProcessingMode,
                                       finality: Finality, config: ReferenceConfig) -> [DailyValue] {
            var out: [DailyValue] = []
            let sep = "\u{1f}"

            // Nightly snapshot values.
            var nightly: [String: [MeasurementEnvelope]] = [:]
            for e in envelopes where e.method.id.hasPrefix("snapshot.") && config.nightlyMetrics.contains(e.metric) {
                guard let series = nightlySeriesKey(metric: e.metric, method: e.method),
                      let v = e.value, v.isFinite,
                      e.validity.state == .valid || e.validity.state == .degraded,
                      e.verdict(.sleepMeasurement)?.state == .eligible else { continue }
                if isLog(series, config: config) && v <= 0 { continue }
                if config.nightlyOwnershipByEnd && !identity.dayWindow.contains(e.support.end) { continue }
                nightly[series + sep + e.regimeKey, default: []].append(e)
            }
            for key in nightly.keys.sorted() {
                let parts = key.components(separatedBy: sep)
                let candidates = nightly[key]!.sorted { a, b in
                    if a.support.duration != b.support.duration { return a.support.duration > b.support.duration }
                    if a.support.end != b.support.end { return a.support.end > b.support.end }
                    return a.id < b.id
                }
                let e = candidates[0]
                var reasons: [ReasonCode] = [nightlySnapshot]
                if e.validity.state == .degraded { reasons.append(degradedValidityIncluded) }
                if candidates.count > 1 { reasons.append(multipleNightlyValues) }
                if e.metric == .skinTemperature { reasons.append(relativeUseOnly) }
                out.append(DailyValue(day: identity.day, seriesKey: parts[0], regimeKey: parts[1], metric: e.metric,
                                      value: e.value!, units: e.method.units, supportCount: 1, supportUnit: "night",
                                      supportS: e.support.duration, mode: mode, finality: finality,
                                      sourceIds: [e.id], reasons: reasons.sorted()))
            }

            // Stable-awake windows.
            var windows: [String: [MeasurementEnvelope]] = [:]
            for e in envelopes where !e.method.id.hasPrefix("snapshot.") && e.metric != .respiratoryRate
                && config.stableAwakeMetrics.contains(e.metric) && e.method.windowS == config.stableAwakeWindowS {
                guard let series = stableAwakeSeriesKey(metric: e.metric, config: config),
                      let v = e.value, v.isFinite, e.validity.state == .valid,
                      e.verdict(.stableAwakeRest)?.state == .eligible,
                      identity.dayWindow.contains(e.support.start) else { continue }
                if isLog(series, config: config) && v <= 0 { continue }
                windows[series + sep + e.regimeKey, default: []].append(e)
            }
            for key in windows.keys.sorted() {
                let parts = key.components(separatedBy: sep)
                let es = windows[key]!.sorted { ($0.support, $0.id) < ($1.support, $1.id) }
                if let dv = windowValue(es, day: identity.day, seriesKey: parts[0], regimeKey: parts[1], mode: mode,
                                        finality: finality, extraReasons: [], config: config) {
                    out.append(dv)
                }
                guard config.stratifyStableAwakeByTimeBand else { continue }
                var bands: [String: [MeasurementEnvelope]] = [:]
                for e in es { bands[timeBand(secondsOfDay: e.localTime.secondsOfDay, config: config), default: []].append(e) }
                for band in bands.keys.sorted() {
                    if let dv = windowValue(bands[band]!, day: identity.day, seriesKey: parts[0] + "." + band,
                                            regimeKey: parts[1], mode: mode, finality: finality,
                                            extraReasons: [timeBandStratum], config: config) {
                        out.append(dv)
                    }
                }
            }
            if config.stableAwakeMetrics.contains(.respiratoryRate) {
                out += respiratoryStableAwakeValues(envelopes, identity: identity, mode: mode, finality: finality,
                                                    config: config)
            }
            return out.sorted { ($0.seriesKey, $0.regimeKey) < ($1.seriesKey, $1.regimeKey) }
        }

        /// The explicit stable-awake respiratory adapter (spec-02 §2, docs/spec-02/CONTRACT.md §6).
        ///
        /// Respiratory estimates are short RSA windows (`series.resp_rate.2min`, one a minute, overlapping), and the
        /// estimator withholds itself whenever the wrist moves, so no exercise rate exists to compare. Each envelope
        /// keeps its own System B verdict (HR-independent motion context; an HR-reading decoder track is never
        /// evidence). Here:
        /// 1. an envelope qualifies when it is a window estimate (not `snapshot.*`, `windowS` below the stable-awake
        ///    window), valid, stable-awake eligible and wholly inside one 5-minute window of the local-midnight grid
        ///    of the day (the grid of the 5-minute HR windows);
        /// 2. a 5-minute window takes the median of its qualifying estimates when it holds at least
        ///    `stableAwakeRespMinEstimatesPerWindow` non-overlapping ones;
        /// 3. the day's `resp_rate.stable_awake_5min` value is the median of the windows' values when at least
        ///    `stableAwakeMinWindows` windows exist (support = windows), with the same time-band strata as the other
        ///    stable-awake series. Nothing is zero-filled: no qualifying window → no value.
        static func respiratoryStableAwakeValues(_ envelopes: [MeasurementEnvelope], identity: DayIdentity,
                                                 mode: ProcessingMode, finality: Finality,
                                                 config: ReferenceConfig) -> [DailyValue] {
            guard let series = stableAwakeSeriesKey(metric: .respiratoryRate, config: config) else { return [] }
            let width = max(1, config.stableAwakeWindowS)
            let dayStart = identity.dayWindow.start
            struct Window { var start: Int; var members: [MeasurementEnvelope] }
            var grouped: [String: [Int: [MeasurementEnvelope]]] = [:]
            for e in envelopes where e.metric == .respiratoryRate && !e.method.id.hasPrefix("snapshot.")
                && e.method.windowS < width {
                guard let v = e.value, v.isFinite, e.validity.state == .valid,
                      e.verdict(.stableAwakeRest)?.state == .eligible,
                      identity.dayWindow.contains(e.support.start), e.support.isValid else { continue }
                let k = (e.support.start - dayStart) / width
                let wEnd = min(dayStart + (k + 1) * width, identity.dayWindow.end)
                guard e.support.end <= wEnd else { continue }
                grouped[e.regimeKey, default: [:]][k, default: []].append(e)
            }
            var out: [DailyValue] = []
            for regime in grouped.keys.sorted() {
                var windows: [Window] = []
                for k in grouped[regime]!.keys.sorted() {
                    let members = grouped[regime]![k]!.sorted { ($0.support, $0.id) < ($1.support, $1.id) }
                    var independent = 0, lastEnd = Int.min
                    for m in members where m.support.start >= lastEnd { independent += 1; lastEnd = m.support.end }
                    guard independent >= max(1, config.stableAwakeRespMinEstimatesPerWindow) else { continue }
                    windows.append(Window(start: dayStart + k * width, members: members))
                }
                func value(_ ws: [Window], key: String, extra: [ReasonCode]) -> DailyValue? {
                    guard ws.count >= max(1, config.stableAwakeMinWindows), let first = ws.first?.members.first,
                          let med = RobustStats.median(ws.compactMap { w in
                              RobustStats.median(w.members.compactMap(\.value))
                          }) else { return nil }
                    let members = ws.flatMap(\.members)
                    let supportS = ws.reduce(0) { acc, w in
                        acc + SignalValidityEngine.mergeIntervals(w.members.map(\.support)).reduce(0) { $0 + $1.duration }
                    }
                    return DailyValue(day: identity.day, seriesKey: key, regimeKey: regime, metric: .respiratoryRate,
                                      value: med, units: first.method.units, supportCount: ws.count,
                                      supportUnit: "window", supportS: supportS, mode: mode, finality: finality,
                                      sourceIds: members.map(\.id).sorted(),
                                      reasons: ([stableAwakeWindows, stableAwakeRespirationWindow] + extra).sorted())
                }
                if let dv = value(windows, key: series, extra: []) { out.append(dv) }
                guard config.stratifyStableAwakeByTimeBand else { continue }
                var bands: [String: [Window]] = [:]
                for w in windows {
                    let m = w.members[0]
                    let secondsOfDay = max(0, m.localTime.secondsOfDay - (m.support.start - w.start))
                    bands[timeBand(secondsOfDay: secondsOfDay, config: config), default: []].append(w)
                }
                for band in bands.keys.sorted() {
                    if let dv = value(bands[band]!, key: series + "." + band, extra: [timeBandStratum]) {
                        out.append(dv)
                    }
                }
            }
            return out
        }

        /// Median of the windows with the number of non-overlapping windows as support; nil below the minimum.
        static func windowValue(_ es: [MeasurementEnvelope], day: String, seriesKey: String, regimeKey: String,
                                mode: ProcessingMode, finality: Finality, extraReasons: [ReasonCode],
                                config: ReferenceConfig) -> DailyValue? {
            guard let first = es.first else { return nil }
            var independent = 0, supportS = 0, lastEnd = Int.min, overlapped = false
            for e in es {
                if e.support.start >= lastEnd {
                    independent += 1; supportS += e.support.duration; lastEnd = e.support.end
                } else {
                    overlapped = true
                }
            }
            guard independent >= max(1, config.stableAwakeMinWindows),
                  let med = RobustStats.median(es.compactMap { $0.value }) else { return nil }
            var reasons: [ReasonCode] = [stableAwakeWindows] + extraReasons
            if overlapped { reasons.append(overlappingWindowsNotCounted) }
            return DailyValue(day: day, seriesKey: seriesKey, regimeKey: regimeKey, metric: first.metric, value: med,
                              units: first.method.units, supportCount: independent, supportUnit: "window",
                              supportS: supportS, mode: mode, finality: finality,
                              sourceIds: es.map(\.id).sorted(), reasons: reasons.sorted())
        }

        /// `<metric>.sleep_night`; nil for metrics that are not comparable night to night.
        public static func nightlySeriesKey(metric: MetricKind, method: MethodRef) -> String? {
            switch metric {
            case .hrvRmssd: return "hrv_rmssd.sleep_night"
            // Whole-session SDNN grows with recording length (Shaffer & Ginsberg 2017); only an index over fixed
            // windows is comparable across nights of different length.
            case .hrvSdnn: return method.aggregation == .meanOverWindows ? "hrv_sdnn_index.sleep_night" : nil
            case .restingHeartRate: return "resting_hr.sleep_night"
            case .respiratoryRate: return "resp_rate.sleep_night"
            case .skinTemperature: return "skin_temp.sleep_night"
            case .heartRate: return "heart_rate.sleep_night"
            case .spo2Candidate: return nil
            }
        }

        public static func stableAwakeSeriesKey(metric: MetricKind, config: ReferenceConfig) -> String? {
            let suffix = "stable_awake_\(config.stableAwakeWindowS / 60)min"
            switch metric {
            case .hrvRmssd: return "hrv_rmssd." + suffix
            case .hrvSdnn: return "hrv_sdnn." + suffix
            case .heartRate: return "heart_rate." + suffix
            // The explicit respiratory adapter (`respiratoryStableAwakeValues`).
            case .respiratoryRate: return "resp_rate." + suffix
            default: return nil
            }
        }

        /// `band_HH_HH` of a local second-of-day; the band before the first start wraps from the last start.
        public static func timeBand(secondsOfDay: Int, config: ReferenceConfig) -> String {
            let starts = Array(Set(config.timeBandStartHours.filter { (0..<24).contains($0) })).sorted()
            guard !starts.isEmpty else { return "band_00_24" }
            let hour = max(0, min(23, secondsOfDay / 3600))
            var idx = starts.lastIndex { $0 <= hour } ?? (starts.count - 1)
            if starts[idx] > hour { idx = starts.count - 1 }
            let lo = starts[idx]
            let hi = idx + 1 < starts.count ? starts[idx + 1] : (starts[0] == 0 ? 24 : starts[0])
            return String(format: "band_%02d_%02d", lo, hi)
        }

        public static func isStratum(_ seriesKey: String) -> Bool { seriesKey.contains(stratumMarker) }

        public static func parentSeries(of seriesKey: String) -> String {
            guard let r = seriesKey.range(of: stratumMarker) else { return seriesKey }
            return String(seriesKey[..<r.lowerBound])
        }

        // MARK: - Compare

        /// Compare today's values with recent / rolling / frozen / conditioned references built from `history`
        /// (strictly earlier days). Returns the comparisons and any frozen reference this run registers.
        ///
        /// Parent series get `recent`, `rolling` and `frozen`; time-band strata get `conditioned`. Only values of the
        /// same series, the same regime key (the documented comparability rule: equality) and the same mode are
        /// pooled; history from `day` or later is ignored even if the caller passes it.
        ///
        /// Frozen: a registered reference for (series, regime, version) is the authority. It scores days after its
        /// window; a day inside or before it gets no frozen comparison, and no second reference is registered
        /// while one exists. Causal mode ignores references created for `day` or later. Causal values of
        /// day-accumulating series (`causalPartialDaySeriesMarkers`) carry no distance.
        public static func compare(_ values: [DailyValue], history: [DailyValue], frozen: [FrozenReference],
                                   day: String, policyFingerprint: String,
                                   config: ReferenceConfig) -> (comparisons: [ReferenceComparison],
                                                                newFrozen: [FrozenReference]) {
            guard let t = dayNumber(day) else { return ([], []) }
            let index = HistoryIndex(history, before: t, config: config)

            // One value per (mode, series, regime); only today's values.
            var todays: [DailyValue] = []
            var seen = Set<String>()
            let ordered = values.filter { $0.day == day && $0.value.isFinite && !isExcluded($0.seriesKey, config) }
                .sorted { a, b in
                    if (a.seriesKey, a.regimeKey, a.mode.rawValue) != (b.seriesKey, b.regimeKey, b.mode.rawValue) {
                        return (a.seriesKey, a.regimeKey, a.mode.rawValue) < (b.seriesKey, b.regimeKey, b.mode.rawValue)
                    }
                    if a.supportCount != b.supportCount { return a.supportCount > b.supportCount }
                    return a.value < b.value
                }
            for v in ordered where seen.insert(HistoryIndex.key(v.mode, v.seriesKey, v.regimeKey)).inserted {
                todays.append(v)
            }

            var comparisons: [ReferenceComparison] = []
            var newFrozen: [FrozenReference] = []
            for v in todays {
                if isStratum(v.seriesKey) {
                    comparisons.append(conditioned(v, t: t, index: index, config: config))
                    continue
                }
                let rolling = rollingComparison(v, t: t, index: index, config: config)
                let f = frozenComparison(v, t: t, day: day, index: index, frozen: frozen,
                                         policyFingerprint: policyFingerprint, config: config)
                var views = [recentComparison(v, t: t, index: index, rolling: rolling.stats, config: config),
                             rolling.comparison, f.comparison]
                if isCausalPartialDay(v.seriesKey, mode: v.mode, config: config) {
                    views = views.map(withoutDistance)
                }
                comparisons += views
                if let n = f.registered { newFrozen.append(n) }
            }
            let order: [ReferenceView: Int] = [.recent: 0, .rolling: 1, .frozen: 2, .conditioned: 3]
            comparisons.sort { a, b in
                if (a.seriesKey, a.regimeKey) != (b.seriesKey, b.regimeKey) {
                    return (a.seriesKey, a.regimeKey) < (b.seriesKey, b.regimeKey)
                }
                return order[a.view]! < order[b.view]!
            }
            return (comparisons, newFrozen.sorted { ($0.seriesKey, $0.regimeKey) < ($1.seriesKey, $1.regimeKey) })
        }

        // MARK: - Reference statistics (shared with ChangeDetection and Evaluation)

        /// One supported day of a series: original value and its transformed value.
        struct RefPoint: Equatable, Sendable {
            var dayNum: Int
            var day: String
            var value: Double
            var x: Double
        }

        /// Center and scale of a set of supported days, on the transformed scale.
        struct RefStats: Equatable, Sendable {
            var n = 0
            var fromDay: String?
            var toDay: String?
            var latestDayNum: Int?
            var center: Double?
            var scale: Double?
            var floored = false
            var constant = false
            var standardError: Double?
            var estimator = "median_mad"
        }

        /// History of earlier days grouped by (mode, series, regime), de-duplicated to one value per day and
        /// sorted by day. Built once per call; order of the input never matters.
        struct HistoryIndex {
            var points: [String: [RefPoint]] = [:]
            var regimesBySeries: [String: Set<String>] = [:]
            var excluded: [String: Int] = [:]
            var duplicates: [String: Int] = [:]
            var futureIgnored = 0

            static func key(_ mode: ProcessingMode, _ series: String, _ regime: String) -> String {
                mode.rawValue + "\u{1f}" + series + "\u{1f}" + regime
            }
            static func seriesKey(_ mode: ProcessingMode, _ series: String) -> String {
                mode.rawValue + "\u{1f}" + series
            }

            init(_ history: [DailyValue], before t: Int, config: ReferenceConfig) {
                var grouped: [String: [DailyValue]] = [:]
                for h in history {
                    guard let n = ContextReferences.dayNumber(h.day) else { continue }
                    guard n < t else { futureIgnored += 1; continue }
                    let k = Self.key(h.mode, h.seriesKey, h.regimeKey)
                    guard h.value.isFinite, !(ContextReferences.isLog(h.seriesKey, config: config) && h.value <= 0)
                    else { excluded[k, default: 0] += 1; continue }
                    grouped[k, default: []].append(h)
                    regimesBySeries[Self.seriesKey(h.mode, h.seriesKey), default: []].insert(h.regimeKey)
                }
                for (k, vs) in grouped {
                    let sorted = vs.sorted { a, b in
                        if a.day != b.day { return a.day < b.day }
                        if a.supportCount != b.supportCount { return a.supportCount > b.supportCount }
                        if a.value != b.value { return a.value < b.value }
                        return a.sourceIds.joined(separator: ",") < b.sourceIds.joined(separator: ",")
                    }
                    var pts: [RefPoint] = []
                    let log = ContextReferences.isLog(sorted[0].seriesKey, config: config)
                    for v in sorted {
                        if let last = pts.last, last.day == v.day { duplicates[k, default: 0] += 1; continue }
                        pts.append(RefPoint(dayNum: ContextReferences.dayNumber(v.day)!, day: v.day, value: v.value,
                                            x: log ? Foundation.log(v.value) : v.value))
                    }
                    points[k] = pts
                }
            }

            func window(_ mode: ProcessingMode, _ series: String, _ regime: String, from lo: Int, to hi: Int) -> [RefPoint] {
                (points[Self.key(mode, series, regime)] ?? []).filter { $0.dayNum >= lo && $0.dayNum <= hi }
            }

            func hasOtherRegime(_ mode: ProcessingMode, _ series: String, _ regime: String) -> Bool {
                guard let rs = regimesBySeries[Self.seriesKey(mode, series)] else { return false }
                return rs.contains { $0 != regime }
            }
        }

        static func isExcluded(_ seriesKey: String, _ config: ReferenceConfig) -> Bool {
            config.excludedSeriesPrefixes.contains { seriesKey.hasPrefix($0) }
        }

        /// A causal parent value of a day-accumulating series (`causalPartialDaySeriesMarkers`): it may describe
        /// the day up to the cutoff only, while its history holds whole days.
        static func isCausalPartialDay(_ seriesKey: String, mode: ProcessingMode, config: ReferenceConfig) -> Bool {
            mode == .causalLive && !isStratum(seriesKey)
                && config.causalPartialDaySeriesMarkers.contains { !$0.isEmpty && seriesKey.contains($0) }
        }

        /// The comparison with its distances removed (`partial_day_composition`): the reference (center, scale,
        /// support) stays visible; z and both differences are dropped and a scoring status becomes provisional.
        static func withoutDistance(_ c: ReferenceComparison) -> ReferenceComparison {
            var c = c
            if c.status == .ready { c.status = .provisional }
            c.robustZ = nil
            c.signedDifference = nil
            c.transformedDifference = nil
            c.reasons = Array(Set(c.reasons + [partialDayComposition])).sorted()
            return c
        }

        static func isLog(_ seriesKey: String, config: ReferenceConfig) -> Bool {
            config.logTransformSeriesPrefixes.contains { seriesKey.hasPrefix($0) }
        }

        static func transformName(_ seriesKey: String, config: ReferenceConfig) -> String {
            isLog(seriesKey, config: config) ? "ln" : "identity"
        }

        /// Forward transform; nil when the value cannot be transformed (non-finite, or ≤ 0 on the ln scale).
        static func forward(_ v: Double, log: Bool) -> Double? {
            guard v.isFinite else { return nil }
            if log { return v > 0 ? Foundation.log(v) : nil }
            return v
        }

        static func inverse(_ x: Double, log: Bool) -> Double { log ? exp(x) : x }

        /// The listed floor of a series (longest matching prefix), if any.
        static func listedFloor(_ seriesKey: String, config: ReferenceConfig) -> ScaleFloor? {
            config.scaleFloors.filter { !$0.seriesPrefix.isEmpty && seriesKey.hasPrefix($0.seriesPrefix) }
                .max { $0.seriesPrefix.count < $1.seriesPrefix.count }
        }

        /// The scale floor of a series on its transformed scale: the listed floor, else the default rule
        /// (`defaultLogFloor` for ln series; the larger of `defaultRelativeFloor·|center|` and
        /// `defaultAbsoluteFloor` for identity series).
        static func scaleFloor(_ seriesKey: String, center: Double?, config: ReferenceConfig) -> Double {
            let f: Double
            if let match = listedFloor(seriesKey, config: config) { f = match.floor }
            else if isLog(seriesKey, config: config) { f = config.defaultLogFloor }
            else { f = max(config.defaultRelativeFloor * abs(center ?? 0), config.defaultAbsoluteFloor) }
            return max(config.minimumScale, f.isFinite ? f : 0)
        }

        /// Center / scale of `pts` (sorted by day) with the configured estimator and an explicit floor.
        static func stats(_ pts: [RefPoint], seriesKey: String, estimator: String,
                          config: ReferenceConfig) -> RefStats {
            var s = RefStats()
            s.estimator = estimator
            s.n = pts.count
            guard let first = pts.first, let last = pts.last else { return s }
            s.fromDay = first.day; s.toDay = last.day; s.latestDayNum = last.dayNum
            let xs = pts.map(\.x)
            guard let med = RobustStats.median(xs) else { return s }
            let lo = xs.min()!, hi = xs.max()!
            s.constant = pts.count > 1 && hi - lo == 0
            var center = med
            var raw = RobustStats.madScale(xs, center: med, smallSampleCorrection: config.smallSampleCorrection) ?? 0
            if estimator == "winsorized_mean_sd" && xs.count >= 2 {
                let guardScale = max(raw, scaleFloor(seriesKey, center: med, config: config))
                let w = RobustStats.winsorized(xs, center: med, scale: guardScale, k: config.winsorizeK)
                center = RobustStats.mean(w) ?? med
                let sd = RobustStats.standardDeviation(w) ?? 0
                raw = sd / RobustStats.winsorizedNormalVariance(k: config.winsorizeK).squareRoot()
            }
            let floor = scaleFloor(seriesKey, center: center, config: config)
            s.center = center
            s.floored = !(raw >= floor)
            let scale = s.floored ? floor : raw
            s.scale = scale
            s.standardError = estimator == "winsorized_mean_sd"
                ? scale / Double(pts.count).squareRoot()
                : RobustStats.medianStandardError(sigma: scale, n: pts.count)
            return s
        }

        /// The frozen selection: the first `frozenSelectionDays` supported days that fit in `frozenMaxSpanDays`.
        static func frozenSelection(_ pts: [RefPoint], config: ReferenceConfig) -> [RefPoint]? {
            let need = max(1, config.frozenSelectionDays)
            guard pts.count >= need else { return nil }
            for i in 0...(pts.count - need) where pts[i + need - 1].dayNum - pts[i].dayNum < config.frozenMaxSpanDays {
                return Array(pts[i..<(i + need)])
            }
            return nil
        }

        static func frozenSelectionRule(_ config: ReferenceConfig) -> String {
            "first_\(config.frozenSelectionDays)_supported_days_within_\(config.frozenMaxSpanDays)_calendar_days_of_loaded_regime_history"
        }

        static func frozenId(seriesKey: String, regimeKey: String, version: Int, fromDay: String) -> String {
            "frz_" + PhysiologyContext.fnv1a("\(seriesKey)|\(regimeKey)|\(version)|\(fromDay)")
        }

        /// Register a frozen reference from the selection (median / floored MAD on the transformed scale).
        static func makeFrozen(_ selection: [RefPoint], seriesKey: String, regimeKey: String, createdForDay: String,
                               policyFingerprint: String, config: ReferenceConfig) -> FrozenReference? {
            let s = stats(selection, seriesKey: seriesKey, estimator: "median_mad", config: config)
            guard let c = s.center, let sc = s.scale, let from = s.fromDay, let to = s.toDay else { return nil }
            return FrozenReference(id: frozenId(seriesKey: seriesKey, regimeKey: regimeKey,
                                                version: config.frozenVersion, fromDay: from),
                                   seriesKey: seriesKey, regimeKey: regimeKey, version: config.frozenVersion,
                                   fromDay: from, toDay: to, supportDays: s.n, center: c, scale: sc,
                                   transform: transformName(seriesKey, config: config),
                                   selectionRule: frozenSelectionRule(config), createdForDay: createdForDay,
                                   policyFingerprint: policyFingerprint)
        }

        /// The registered frozen reference of (series, regime) at the configured version: the authority, whatever
        /// day it was created for. Storage is insert-only on (series, regime, version), so at most one exists; if
        /// several are passed, the earliest selection wins deterministically. Callers use it only for days after
        /// its window (`toDay < t`) and never register a second one while it exists.
        ///
        /// Causal mode first drops references created for day `t` or later or whose window ends on or after `t`
        /// (`ignored` counts them): a live decision on day t could not have used them (the worker also filters by
        /// registration time; this guard does not rely on it).
        static func frozenAuthority(seriesKey: String, regimeKey: String, frozen: [FrozenReference],
                                    mode: ProcessingMode, t: Int,
                                    config: ReferenceConfig) -> (reference: FrozenReference?, ignored: Int) {
            var candidates = frozen.filter {
                $0.seriesKey == seriesKey && $0.regimeKey == regimeKey && $0.version == config.frozenVersion
                    && dayNumber($0.toDay) != nil && $0.center.isFinite && $0.scale.isFinite
            }
            var ignored = 0
            if mode == .causalLive {
                let available = candidates.filter {
                    dayNumber($0.toDay)! < t && (dayNumber($0.createdForDay).map { $0 < t } ?? false)
                }
                ignored = candidates.count - available.count
                candidates = available
            }
            return (candidates.min { ($0.fromDay, $0.id) < ($1.fromDay, $1.id) }, ignored)
        }

        // MARK: - Views

        /// Common shape of a comparison from reference statistics.
        static func build(_ v: DailyValue, view: ReferenceView, stats s: RefStats, status: ReferenceStatus,
                          reasons: [ReasonCode], referenceId: String? = nil, pooled: Double = 0,
                          parentSupportDays: Int = 0, scaleOverride: Double? = nil, flooredOverride: Bool? = nil,
                          config: ReferenceConfig) -> ReferenceComparison {
            let log = isLog(v.seriesKey, config: config)
            var reasons = reasons
            let x = forward(v.value, log: log)
            if log { reasons.append(logTransform) }
            if x == nil { reasons.append(nonPositiveValueForLog) }
            let scale = scaleOverride ?? s.scale
            let floored = flooredOverride ?? s.floored
            let scoring = (status == .ready || status == .provisional) && x != nil
            let centerOrig = s.center.map { inverse($0, log: log) }
            let z: Double? = scoring ? zip3(x, s.center, scale).map { ($0 - $1) / $2 } : nil
            if scoring && floored { reasons.append(scaleFloored) }
            if scoring && listedFloor(v.seriesKey, config: config) == nil { reasons.append(scaleFloorDefault) }
            if s.constant { reasons.append(constantHistory) }
            if scoring && config.smallSampleCorrection && s.estimator.hasSuffix("median_mad") && s.n < 40 {
                reasons.append(smallSampleScaleCorrection)
            }
            var uncertainty: Double?
            if let se = s.standardError, let c = centerOrig, scoring {
                uncertainty = log ? c * se : se
                reasons.append(centerUncertaintyApproximate)
            }
            return ReferenceComparison(
                day: v.day, seriesKey: v.seriesKey, regimeKey: v.regimeKey, view: view, referenceId: referenceId,
                status: status, supportDays: s.n, fromDay: s.fromDay, toDay: s.toDay, value: v.value,
                center: centerOrig, scale: (status == .ready || status == .provisional) ? scale : nil,
                scaleFloored: (status == .ready || status == .provisional) && floored,
                signedDifference: scoring ? centerOrig.map { v.value - $0 } : nil,
                transformedDifference: log && scoring ? zip2(x, s.center).map { $0 - $1 } : nil,
                robustZ: z.flatMap { $0.isFinite ? $0 : nil },
                centerUncertainty: uncertainty.flatMap { $0.isFinite ? $0 : nil },
                transform: log ? "ln" : "identity", pooledContribution: pooled,
                reasons: Array(Set(reasons)).sorted(), transformedCenter: s.center,
                centerUncertaintyMethod: uncertainty == nil ? "" : (s.estimator == "winsorized_mean_sd"
                    ? "mean_se_iid_approx" : "median_se_iid_normal_approx"),
                estimator: s.estimator, parentSupportDays: parentSupportDays)
        }

        static func zip2(_ a: Double?, _ b: Double?) -> (Double, Double)? {
            guard let a, let b else { return nil }; return (a, b)
        }
        static func zip3(_ a: Double?, _ b: Double?, _ c: Double?) -> (Double, Double, Double)? {
            guard let a, let b, let c, c > 0 else { return nil }; return (a, b, c)
        }

        /// Support-dependent status of a trailing window and the matching reasons.
        static func supportStatus(n: Int, min: Int, ready: Int, otherRegime: Bool) -> (ReferenceStatus, [ReasonCode]) {
            if n == 0 {
                return otherRegime ? (.regimeMismatch, [historyInOtherRegimeOnly]) : (.insufficient, [noHistory])
            }
            var reasons: [ReasonCode] = otherRegime ? [otherRegimeHistoryNotPooled] : []
            if n < min { reasons.append(insufficientHistory); return (.insufficient, reasons) }
            if n < ready { reasons.append(provisionalSupport); return (.provisional, reasons) }
            return (.ready, reasons)
        }

        static func historyReasons(_ index: HistoryIndex, _ v: DailyValue) -> [ReasonCode] {
            let k = HistoryIndex.key(v.mode, v.seriesKey, v.regimeKey)
            var r: [ReasonCode] = []
            if (index.excluded[k] ?? 0) > 0 { r.append(historyValuesExcluded) }
            if (index.duplicates[k] ?? 0) > 0 { r.append(duplicateHistoryDayResolved) }
            if index.futureIgnored > 0 { r.append(futureHistoryIgnored) }
            return r
        }

        /// Rolling statistics of `series` for day `t` (days `[t - window, t - 1]`); shared with ChangeDetection.
        static func rollingStats(_ pts: [RefPoint], t: Int, seriesKey: String, config: ReferenceConfig) -> RefStats {
            let w = pts.filter { $0.dayNum >= t - config.rollingWindowDays && $0.dayNum <= t - 1 }
            return stats(w, seriesKey: seriesKey, estimator: config.rollingEstimator, config: config)
        }

        static func rollingStatus(_ s: RefStats, otherRegime: Bool, config: ReferenceConfig) -> (ReferenceStatus, [ReasonCode]) {
            supportStatus(n: s.n, min: config.rollingMinDays, ready: config.rollingReadyDays, otherRegime: otherRegime)
        }

        static func rollingComparison(_ v: DailyValue, t: Int, index: HistoryIndex,
                                      config: ReferenceConfig) -> (comparison: ReferenceComparison, stats: RefStats,
                                                                   status: ReferenceStatus) {
            let pts = index.points[HistoryIndex.key(v.mode, v.seriesKey, v.regimeKey)] ?? []
            let s = rollingStats(pts, t: t, seriesKey: v.seriesKey, config: config)
            let other = index.hasOtherRegime(v.mode, v.seriesKey, v.regimeKey)
            var (status, reasons) = rollingStatus(s, otherRegime: other, config: config)
            reasons += historyReasons(index, v)
            if let latest = s.latestDayNum, t - latest > config.staleAfterDays { reasons.append(staleHistory) }
            if config.rollingEstimator == "winsorized_mean_sd" { reasons.append(winsorizedMeanEstimator) }
            return (build(v, view: .rolling, stats: s, status: status, reasons: reasons, config: config), s, status)
        }

        static func recentComparison(_ v: DailyValue, t: Int, index: HistoryIndex, rolling: RefStats,
                                     config: ReferenceConfig) -> ReferenceComparison {
            let w = index.window(v.mode, v.seriesKey, v.regimeKey, from: t - config.recentWindowDays, to: t - 1)
            var s = stats(w, seriesKey: v.seriesKey, estimator: "median_mad", config: config)
            let other = index.hasOtherRegime(v.mode, v.seriesKey, v.regimeKey)
            var (status, reasons) = supportStatus(n: s.n, min: config.recentMinDays, ready: config.recentMinDays,
                                                  otherRegime: other)
            reasons += historyReasons(index, v)
            var scaleOverride: Double?, flooredOverride: Bool?
            if status == .ready {
                // The short window describes the trajectory (its center); 3-7 days cannot estimate a spread, so the
                // rolling view's scale is borrowed when that view has its minimum support.
                let rollingUsable = rolling.n >= config.rollingMinDays
                if rollingUsable, let rs = rolling.scale {
                    scaleOverride = rs; flooredOverride = rolling.floored
                    reasons.append(scaleFromRollingView)
                    if rolling.n < config.rollingReadyDays { status = .provisional }
                } else {
                    reasons.append(scaleFromRecentWindow)
                    status = .provisional
                }
                if let se = (scaleOverride ?? s.scale).flatMap({ RobustStats.medianStandardError(sigma: $0, n: s.n) }) {
                    s.standardError = se
                }
            }
            return build(v, view: .recent, stats: s, status: status, reasons: reasons, scaleOverride: scaleOverride,
                         flooredOverride: flooredOverride, config: config)
        }

        static func frozenComparison(_ v: DailyValue, t: Int, day: String, index: HistoryIndex,
                                     frozen: [FrozenReference], policyFingerprint: String,
                                     config: ReferenceConfig) -> (comparison: ReferenceComparison,
                                                                  registered: FrozenReference?) {
            var reasons: [ReasonCode] = [frozenHistoricalNotHealthy] + historyReasons(index, v)
            let authority = frozenAuthority(seriesKey: v.seriesKey, regimeKey: v.regimeKey, frozen: frozen,
                                            mode: v.mode, t: t, config: config)
            if authority.ignored > 0 { reasons.append(frozenCreatedAfterDayIgnored) }
            var ref = authority.reference
            if let f = ref, let to = dayNumber(f.toDay), to >= t {
                // The registered reference is the authority (R-F7): a day inside or before its selection window
                // neither registers another "version 1" nor gets a frozen comparison.
                reasons.append(frozenWindowNotCompleteForDay)
                var s = RefStats(); s.estimator = "frozen_median_mad"
                s.n = f.supportDays; s.fromDay = f.fromDay; s.toDay = f.toDay
                return (build(v, view: .frozen, stats: s, status: .unavailable, reasons: reasons, referenceId: f.id,
                              config: config), nil)
            }
            var registered: FrozenReference?
            if ref == nil {
                let pts = index.points[HistoryIndex.key(v.mode, v.seriesKey, v.regimeKey)] ?? []
                if !config.frozenRegistrationModes.contains(v.mode) {
                    reasons += [frozenNotRegistered, frozenRegistersInOtherMode]
                } else if let sel = frozenSelection(pts, config: config),
                          let f = makeFrozen(sel, seriesKey: v.seriesKey, regimeKey: v.regimeKey, createdForDay: day,
                                             policyFingerprint: policyFingerprint, config: config) {
                    ref = f; registered = f
                    reasons.append(frozenRegisteredThisRun)
                } else {
                    reasons.append(frozenNotRegistered)
                    let other = index.hasOtherRegime(v.mode, v.seriesKey, v.regimeKey)
                    let status: ReferenceStatus = pts.isEmpty && other ? .regimeMismatch : .insufficient
                    if status == .regimeMismatch { reasons.append(historyInOtherRegimeOnly) }
                    else { reasons.append(pts.isEmpty ? noHistory : insufficientHistory) }
                    var s = RefStats(); s.n = pts.count; s.estimator = "frozen_median_mad"
                    return (build(v, view: .frozen, stats: s, status: status, reasons: reasons, config: config), nil)
                }
            }
            guard let f = ref else {
                var s = RefStats(); s.estimator = "frozen_median_mad"
                return (build(v, view: .frozen, stats: s, status: .unavailable, reasons: reasons, config: config), nil)
            }
            let s = frozenStats(f, config: config)
            if f.scale < scaleFloor(v.seriesKey, center: f.center, config: config) {
                reasons.append(frozenScaleRefloored)
            }
            let status: ReferenceStatus = transformName(v.seriesKey, config: config) == f.transform ? .ready : .unavailable
            return (build(v, view: .frozen, stats: s, status: status, reasons: reasons, referenceId: f.id,
                          config: config), registered)
        }

        /// A frozen reference as statistics; the current policy's floor still applies (the stored scale is never
        /// rewritten).
        static func frozenStats(_ f: FrozenReference, config: ReferenceConfig) -> RefStats {
            var s = RefStats()
            s.n = f.supportDays; s.fromDay = f.fromDay; s.toDay = f.toDay; s.latestDayNum = dayNumber(f.toDay)
            s.center = f.center
            let floor = scaleFloor(f.seriesKey, center: f.center, config: config)
            s.floored = f.scale <= floor
            s.scale = max(f.scale, floor)
            s.standardError = RobustStats.medianStandardError(sigma: s.scale!, n: max(1, f.supportDays))
            s.estimator = "frozen_median_mad"
            return s
        }

        /// Conditioned view of a time-band stratum: the band's own earlier days (child) shrunk toward the all-day
        /// parent rolling reference with child weight `n / (n + k)`. No population level exists (contribution 0).
        static func conditioned(_ v: DailyValue, t: Int, index: HistoryIndex, config: ReferenceConfig) -> ReferenceComparison {
            let parentKey = parentSeries(of: v.seriesKey)
            let child = index.window(v.mode, v.seriesKey, v.regimeKey, from: t - config.conditionedWindowDays, to: t - 1)
            let parentPts = index.points[HistoryIndex.key(v.mode, parentKey, v.regimeKey)] ?? []
            let cs = stats(child, seriesKey: v.seriesKey, estimator: "median_mad", config: config)
            let ps = rollingStats(parentPts, t: t, seriesKey: parentKey, config: config)
            let nc = cs.n, np = ps.n
            var reasons: [ReasonCode] = [noPopulationPrior] + historyReasons(index, v)
            let other = index.hasOtherRegime(v.mode, v.seriesKey, v.regimeKey)
                || index.hasOtherRegime(v.mode, parentKey, v.regimeKey)
            if nc == 0 && np == 0 {
                var s = RefStats(); s.estimator = "pooled_median_mad"
                reasons.append(other ? historyInOtherRegimeOnly : noHistory)
                return build(v, view: .conditioned, stats: s, status: other ? .regimeMismatch : .insufficient,
                             reasons: reasons, config: config)
            }
            let k = max(0, config.conditionedShrinkageDays)
            var w = (nc + Int(k) == 0) ? 0 : Double(nc) / (Double(nc) + k)
            var s = RefStats()
            s.estimator = "pooled_median_mad"
            s.n = nc; s.fromDay = cs.fromDay ?? ps.fromDay; s.toDay = cs.toDay ?? ps.toDay
            var status: ReferenceStatus
            let floor = { (c: Double?) in scaleFloor(v.seriesKey, center: c, config: config) }
            if np >= config.rollingMinDays, let pc = ps.center, let sp = ps.scale {
                let cc = cs.center ?? pc
                if nc == 0 { w = 0; reasons.append(contextUnsupportedParentOnly) }
                else { reasons.append(pooledTowardParent) }
                let center = w * cc + (1 - w) * pc
                let childScale = nc >= config.conditionedMinChildDays ? cs.scale : nil
                let raw = childScale.map { (w * $0 * $0 + (1 - w) * sp * sp).squareRoot() } ?? sp
                let fl = floor(center)
                s.center = center; s.scale = max(raw, fl); s.floored = !(raw > fl) || (childScale == nil && ps.floored)
                let sec = cs.standardError ?? 0, sep = ps.standardError ?? 0
                s.standardError = ((w * sec) * (w * sec) + ((1 - w) * sep) * ((1 - w) * sep)).squareRoot()
                status = nc >= config.conditionedReadyChildDays && np >= config.rollingReadyDays ? .ready : .provisional
                if status == .provisional { reasons.append(provisionalSupport) }
            } else if nc >= config.conditionedReadyChildDays, let cc = cs.center, let sc = cs.scale {
                w = 1
                s.center = cc; s.scale = sc; s.floored = cs.floored; s.standardError = cs.standardError
                status = .provisional
                reasons += [parentInsufficientChildOnly, provisionalSupport]
            } else {
                s.center = cs.center ?? ps.center
                reasons.append(insufficientHistory)
                status = .insufficient
                w = 0
            }
            s.constant = cs.constant && (nc > 1)
            return build(v, view: .conditioned, stats: s, status: status, reasons: reasons, pooled: 1 - w,
                         parentSupportDays: np, config: config)
        }

        // MARK: - Calendar days (pure, zone-free arithmetic on `yyyy-MM-dd` keys)

        /// Days since 1970-01-01 of a `yyyy-MM-dd` key (proleptic Gregorian); nil when malformed or not a real date.
        public static func dayNumber(_ day: String) -> Int? {
            let parts = day.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                  let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
                  (1...12).contains(m), (1...31).contains(d) else { return nil }
            let yy = m <= 2 ? y - 1 : y
            let era = (yy >= 0 ? yy : yy - 399) / 400
            let yoe = yy - era * 400
            let mp = (m + 9) % 12
            let doy = (153 * mp + 2) / 5 + d - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            let n = era * 146097 + doe - 719468
            return dayKey(n) == day ? n : nil
        }

        /// `yyyy-MM-dd` of a day number (inverse of `dayNumber`).
        public static func dayKey(_ n: Int) -> String {
            let z = n + 719468
            let era = (z >= 0 ? z : z - 146096) / 146097
            let doe = z - era * 146097
            let yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
            let y = yoe + era * 400
            let doy = doe - (365 * yoe + yoe / 4 - yoe / 100)
            let mp = (5 * doy + 2) / 153
            let d = doy - (153 * mp + 2) / 5 + 1
            let m = mp < 10 ? mp + 3 : mp - 9
            return String(format: "%04d-%02d-%02d", m <= 2 ? y + 1 : y, m, d)
        }
    }
}

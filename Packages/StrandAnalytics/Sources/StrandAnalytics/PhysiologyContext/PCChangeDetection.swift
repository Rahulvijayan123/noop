import Foundation

// PCChangeDetection.swift — System F (part 2): transient, recurring and persistent change (spec §12.3).
//
// OWNER: statistics workstream. Method, defaults and the evaluation behind them: docs/physiology-context/notes/
// statistics.md (synthetic arithmetic checks, not physiological accuracy).
//
// Episodes are descriptive. A known regime boundary is reported separately from an unexplained change; neither is
// called disease progression. Derived signals that share inputs are not counted as independent corroboration. No
// alert or notification policy lives here.
//
// Sequential, no look-ahead: each day d is scored against the rolling reference of days strictly before d (the same
// estimator as the `rolling` comparison view) and against the series' frozen reference (days after its selection
// window only). A two-sided CUSUM runs on the daily robust z — never on rolling means, whose autocorrelation would
// multiply false episodes (research note 8). Missing days are skipped, never zero-filled; a long gap resets the
// statistic.

extension PhysiologyContext {

    public struct ChangeConfig: Codable, Equatable, Sendable {
        public var version = "pc-change-2"
        /// Trailing days of history scored together with today.
        public var windowDays = 90
        /// Burn-in. A scored day enters the detectors (CUSUM, persistence rule, transient / recurring excursions)
        /// only when the loaded history of its (series, regime, mode) began at least this many calendar days
        /// earlier, i.e. when its whole rolling window lies inside the loaded history. Earlier days are scored for
        /// display only (`detector_burn_in`). This is the regime the evaluation measures (it discards the first 35
        /// days of every synthetic series). With the worker's 160-day history load, every day of a long-running
        /// series' 90-day window has this lookback and its φ̂ window as well.
        public var detectorMinLookbackDays = 28
        /// Default persistent-shift detector: `cusum` (two-sided CUSUM on daily robust z) or `persistence`
        /// (`persistenceCount` of the last `persistenceWindow` supported days beyond `persistenceZ`, same sign).
        public var detector = "cusum"
        /// Reference value and decision interval in long-run SD units (see notes/statistics.md for the calibration:
        /// ≈ 0.03 false persistent episodes per series-week at φ = 0, 0.3 and 0.5 on synthetic AR(1) series).
        public var cusumK = 0.25
        public var cusumH = 7.0
        /// Daily z is clamped to ±this before entering the CUSUM, so one extreme day contributes at most
        /// `(clamp - k) / h` ≈ 25 % of the evidence an alarm needs.
        public var cusumClampZ = 2.0
        /// The statistic is capped at `cusumCapFactor * cusumH` so an episode ends soon after the evidence stops.
        public var cusumCapFactor = 1.25
        /// Divide the CUSUM input by the AR(1) long-run SD factor `sqrt((1 + φ) / (1 - φ))`, with φ the lag-1
        /// autocorrelation of earlier days in the trailing `autocorrelationWindowDays`, so positively
        /// autocorrelated days are not counted as independent evidence (research note 8). φ̂ pairs consecutive
        /// supported days at most `maxGapDays` apart: it is the autocorrelation of the sequence the CUSUM runs on
        /// (with days missing at random, AR(1) days observed with gaps are again AR(1)-correlated, with
        /// coefficient E[φ^gap]), so a sparse series is neither left unadjusted nor over-corrected.
        public var cusumAutocorrelationAdjustment = true
        public var autocorrelationWindowDays = 56
        /// The most recent days are left out of the autocorrelation estimate, so a fresh change does not inflate
        /// its own φ (which would shrink the evidence for it).
        public var autocorrelationGuardDays = 14
        public var autocorrelationMinPairs = 20
        public var autocorrelationMax = 0.8
        /// φ used when φ̂ cannot be estimated (fewer than `autocorrelationMinPairs` consecutive-day pairs: sparse
        /// series, or the start of a series): the largest φ the evaluation covers. It over-corrects for any
        /// smaller true φ (fewer false episodes, later detection) and is reported as
        /// `autocorrelation_assumed_conservative`. Never "no adjustment", which is the most liberal choice.
        public var autocorrelationFallback = 0.5
        /// A gap of more than this many calendar days between supported days resets the detectors.
        public var maxGapDays = 7
        public var persistenceZ = 2.0
        public var persistenceCount = 3
        public var persistenceWindow = 5
        /// |z| at or above this marks a deviating day (transient / recurring episodes, multi-signal).
        public var deviationZ = 2.5
        /// Supported non-deviating days allowed inside one transient excursion.
        public var transientMergeGapDays = 1
        public var recurrenceWindowDays = 28
        public var recurrenceMinCount = 2
        /// Frozen-reference persistence: `frozenPersistenceCount` of the last `frozenPersistenceWindow` frozen-scored
        /// days beyond `frozenPersistenceZ` in one direction (keeps a fixed-reference deviation visible).
        public var frozenPersistenceZ = 2.0
        public var frozenPersistenceCount = 5
        public var frozenPersistenceWindow = 7
        /// Fewer scored days than this in the window → `insufficient_evidence`.
        public var minScoredDays = 7
        /// An episode is ongoing only if the series has a supported day within this many days of `day`.
        public var ongoingMaxGapDays = 3
        public var boundaryToleranceDays = 1
        public var trendMinDays = 10
        /// |z| below this after an episode counts as back near the earlier reference.
        public var returnedZ = 1.0
        public var multiSignalZ = 2.5
        public var multiSignalView: ReferenceView = .rolling
        /// Run episodes on time-band strata too (off: strata feed the conditioned view only).
        public var episodesForStrata = false
        public init() {}
    }

    public enum EpisodeState: String, Codable, CaseIterable, Sendable {
        case usualVariation = "usual_variation"
        case transientDeviation = "transient_deviation"
        case recurringEpisode = "recurring_episode"
        case persistentShift = "persistent_shift"
        case insufficientEvidence = "insufficient_evidence"
    }

    /// One descriptive change episode of one series.
    public struct ChangeEpisode: Codable, Equatable, Sendable {
        /// Deterministic from (series, regime, start day, direction, policy) so retries never duplicate it.
        public var id: String
        public var seriesKey: String
        public var regimeKey: String
        public var state: EpisodeState
        /// +1 above the reference, -1 below, 0 when not applicable.
        public var direction: Int
        public var startDay: String
        public var lastDay: String
        public var ongoing: Bool
        public var durationDays: Int
        public var finality: Finality
        public var reasons: [ReasonCode]

        // Added by the statistics workstream (defaults keep the contract initializer valid).
        /// `cusum` | `persistence` | `frozen_persistence` | `deviation` | `` (status entries).
        public var detector: String
        /// Day the detector first fired; nil for transient / status entries.
        public var alarmDay: String?
        /// Calendar days from `startDay` (the detector's change-point estimate: the first day of the CUSUM run, or
        /// the first qualifying day of a rule) to `alarmDay`. NOT a detection delay: the true change day is
        /// unknown, and `startDay` can precede it. The evaluation's delay is alarm − true step (notes/statistics.md
        /// §6 reports both). Decodes the former key `detection_delay_days`.
        public var alarmAfterStartDays: Int?
        /// Supported (scored) days inside the episode.
        public var supportDays: Int
        /// Number of excursions (recurring episodes), else 1.
        public var occurrences: Int
        /// Median of `value - rolling center` over the episode's days, original units.
        public var rollingMagnitude: Double?
        /// Median of `value - frozen center` over the episode's frozen-scored days, original units.
        public var frozenMagnitude: Double?
        public var medianRollingZ: Double?
        public var medianFrozenZ: Double?
        public var frozenReferenceId: String?
        /// Theil–Sen slope of the raw values over the scored window, original units per week (drift stays visible).
        public var trendPerWeek: Double?
        public var trendDays: Int
        /// Peak detector statistic (CUSUM S) inside the episode.
        public var peakStatistic: Double?
        public var units: String
        public var transform: String

        public init(id: String, seriesKey: String, regimeKey: String, state: EpisodeState, direction: Int,
                    startDay: String, lastDay: String, ongoing: Bool, durationDays: Int, finality: Finality,
                    reasons: [ReasonCode], detector: String = "", alarmDay: String? = nil,
                    alarmAfterStartDays: Int? = nil, supportDays: Int = 0, occurrences: Int = 1,
                    rollingMagnitude: Double? = nil, frozenMagnitude: Double? = nil, medianRollingZ: Double? = nil,
                    medianFrozenZ: Double? = nil, frozenReferenceId: String? = nil, trendPerWeek: Double? = nil,
                    trendDays: Int = 0, peakStatistic: Double? = nil, units: String = "", transform: String = "") {
            self.id = id; self.seriesKey = seriesKey; self.regimeKey = regimeKey; self.state = state
            self.direction = direction; self.startDay = startDay; self.lastDay = lastDay; self.ongoing = ongoing
            self.durationDays = durationDays; self.finality = finality; self.reasons = reasons
            self.detector = detector; self.alarmDay = alarmDay; self.alarmAfterStartDays = alarmAfterStartDays
            self.supportDays = supportDays; self.occurrences = occurrences; self.rollingMagnitude = rollingMagnitude
            self.frozenMagnitude = frozenMagnitude; self.medianRollingZ = medianRollingZ
            self.medianFrozenZ = medianFrozenZ; self.frozenReferenceId = frozenReferenceId
            self.trendPerWeek = trendPerWeek; self.trendDays = trendDays; self.peakStatistic = peakStatistic
            self.units = units; self.transform = transform
        }

        enum CodingKeys: String, CodingKey {
            case id, seriesKey, regimeKey, state, direction, startDay, lastDay, ongoing, durationDays, finality
            case reasons, detector, alarmDay, alarmAfterStartDays, supportDays, occurrences, rollingMagnitude
            case frozenMagnitude, medianRollingZ, medianFrozenZ, frozenReferenceId, trendPerWeek, trendDays
            case peakStatistic, units, transform
        }

        /// Keys of earlier document versions, read when the current key is absent.
        enum LegacyKeys: String, CodingKey { case detectionDelayDays }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            seriesKey = try c.decode(String.self, forKey: .seriesKey)
            regimeKey = try c.decode(String.self, forKey: .regimeKey)
            state = try c.decode(EpisodeState.self, forKey: .state)
            direction = try c.decode(Int.self, forKey: .direction)
            startDay = try c.decode(String.self, forKey: .startDay)
            lastDay = try c.decode(String.self, forKey: .lastDay)
            ongoing = try c.decode(Bool.self, forKey: .ongoing)
            durationDays = try c.decode(Int.self, forKey: .durationDays)
            finality = try c.decode(Finality.self, forKey: .finality)
            reasons = try c.decode([ReasonCode].self, forKey: .reasons)
            detector = try c.decodeIfPresent(String.self, forKey: .detector) ?? ""
            alarmDay = try c.decodeIfPresent(String.self, forKey: .alarmDay)
            alarmAfterStartDays = try c.decodeIfPresent(Int.self, forKey: .alarmAfterStartDays)
                ?? decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(Int.self, forKey: .detectionDelayDays)
            supportDays = try c.decodeIfPresent(Int.self, forKey: .supportDays) ?? 0
            occurrences = try c.decodeIfPresent(Int.self, forKey: .occurrences) ?? 1
            rollingMagnitude = try c.decodeIfPresent(Double.self, forKey: .rollingMagnitude)
            frozenMagnitude = try c.decodeIfPresent(Double.self, forKey: .frozenMagnitude)
            medianRollingZ = try c.decodeIfPresent(Double.self, forKey: .medianRollingZ)
            medianFrozenZ = try c.decodeIfPresent(Double.self, forKey: .medianFrozenZ)
            frozenReferenceId = try c.decodeIfPresent(String.self, forKey: .frozenReferenceId)
            trendPerWeek = try c.decodeIfPresent(Double.self, forKey: .trendPerWeek)
            trendDays = try c.decodeIfPresent(Int.self, forKey: .trendDays) ?? 0
            peakStatistic = try c.decodeIfPresent(Double.self, forKey: .peakStatistic)
            units = try c.decodeIfPresent(String.self, forKey: .units) ?? ""
            transform = try c.decodeIfPresent(String.self, forKey: .transform) ?? ""
        }
    }

    /// Deviating series that share at least one declared input group (connected through shared groups).
    public struct DependenceComponent: Codable, Equatable, Sendable {
        public var series: [String]
        public var groups: [String]
        public init(series: [String], groups: [String]) { self.series = series; self.groups = groups }
    }

    /// Multi-signal summary for one day that counts dependence groups, not metrics.
    public struct MultiSignalSummary: Codable, Equatable, Sendable {
        public var day: String
        public var deviatingSeries: [String]
        public var dependenceGroups: [String]
        /// Number of connected components of deviating series under shared declared inputs — an upper bound on
        /// independent lines of evidence, not proof of independence.
        public var independentGroupCount: Int
        public var reasons: [ReasonCode]
        public var components: [DependenceComponent]
        public init(day: String, deviatingSeries: [String], dependenceGroups: [String], independentGroupCount: Int,
                    reasons: [ReasonCode], components: [DependenceComponent] = []) {
            self.day = day; self.deviatingSeries = deviatingSeries; self.dependenceGroups = dependenceGroups
            self.independentGroupCount = independentGroupCount; self.reasons = reasons; self.components = components
        }

        enum CodingKeys: String, CodingKey {
            case day, deviatingSeries, dependenceGroups, independentGroupCount, reasons, components
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decode(String.self, forKey: .day)
            deviatingSeries = try c.decode([String].self, forKey: .deviatingSeries)
            dependenceGroups = try c.decode([String].self, forKey: .dependenceGroups)
            independentGroupCount = try c.decode(Int.self, forKey: .independentGroupCount)
            reasons = try c.decode([ReasonCode].self, forKey: .reasons)
            components = try c.decodeIfPresent([DependenceComponent].self, forKey: .components) ?? []
        }
    }

    public enum ChangeDetection {

        public static let version = "pc-change-2"

        // MARK: Reason codes
        public static let coincidesWithRegimeBoundary: ReasonCode = "coincides_with_regime_boundary"
        public static let splitAtRegimeBoundary: ReasonCode = "split_at_regime_boundary"
        public static let rollingAdaptedFrozenDeviationPersists: ReasonCode = "rolling_adapted_frozen_deviation_persists"
        public static let rollingAdapted: ReasonCode = "rolling_adapted_not_proof_of_recovery"
        public static let returnedTowardReference: ReasonCode = "returned_toward_reference"
        public static let frozenReferenceDeviation: ReasonCode = "frozen_reference_deviation"
        public static let gradualDrift: ReasonCode = "gradual_drift"
        public static let frozenAndRollingAgree: ReasonCode = "frozen_and_rolling_agree"
        public static let frozenAndRollingDisagree: ReasonCode = "frozen_and_rolling_disagree"
        public static let frozenUnavailable: ReasonCode = "frozen_unavailable"
        public static let alternativeDetectorAgrees: ReasonCode = "alternative_detector_agrees"
        public static let alternativeDetectorSilent: ReasonCode = "alternative_detector_silent"
        public static let gapReset: ReasonCode = "gap_reset"
        public static let tooFewSupportedDays: ReasonCode = "too_few_supported_days"
        public static let noReference: ReasonCode = "no_reference"
        public static let isolatedExcursion: ReasonCode = "isolated_excursion"
        public static let recurringWithinWindow: ReasonCode = "recurring_within_window"
        public static let startsAtWindowStart: ReasonCode = "starts_at_window_start"
        public static let noRecentSupport: ReasonCode = "no_recent_support"
        public static let detectorCusum: ReasonCode = "detector_cusum"
        public static let detectorPersistence: ReasonCode = "detector_persistence"
        public static let descriptiveOnly: ReasonCode = "descriptive_not_diagnostic"
        /// Some days of the window were scored for display only: the series' loaded history did not yet cover
        /// their rolling window (`detectorMinLookbackDays`), so they did not enter the detectors.
        public static let detectorBurnIn: ReasonCode = "detector_burn_in"
        /// At least one detector day of the CUSUM run (or of the window, on the status entry) had no φ̂ (too few
        /// consecutive-day pairs) and used the conservative `autocorrelationFallback`.
        public static let autocorrelationAssumedConservative: ReasonCode = "autocorrelation_assumed_conservative"
        /// Causal mode: today's value of a day-accumulating series may describe a partial day, so it was left out
        /// of the episodes, which therefore end with the previous supported day.
        public static let partialDayValueExcluded: ReasonCode = "partial_day_value_excluded"
        // Multi-signal.
        public static let sharedInputsNotIndependent: ReasonCode = "shared_inputs_not_independent"
        public static let selectionReadsHeartRate: ReasonCode = "selection_reads_heart_rate"
        public static let noDeclaredDependence: ReasonCode = "no_declared_dependence"
        public static let noDeviatingSeries: ReasonCode = "no_deviating_series"
        public static let groupsNotProvenIndependent: ReasonCode = "distinct_groups_not_proven_independent"

        public static let reasonCodes: [ReasonCode] = [
            coincidesWithRegimeBoundary, splitAtRegimeBoundary, rollingAdaptedFrozenDeviationPersists,
            rollingAdapted, returnedTowardReference, frozenReferenceDeviation, gradualDrift, frozenAndRollingAgree,
            frozenAndRollingDisagree, frozenUnavailable, alternativeDetectorAgrees, alternativeDetectorSilent,
            gapReset, tooFewSupportedDays, noReference, isolatedExcursion, recurringWithinWindow,
            startsAtWindowStart, noRecentSupport, detectorCusum, detectorPersistence, descriptiveOnly,
            sharedInputsNotIndependent, selectionReadsHeartRate, noDeclaredDependence, noDeviatingSeries,
            groupsNotProvenIndependent, detectorBurnIn, autocorrelationAssumedConservative, partialDayValueExcluded,
        ]

        typealias Ref = ContextReferences

        // MARK: - Episodes

        /// Episodes over the trailing history plus today, each day scored against references built from strictly
        /// earlier days; regime boundaries split series.
        ///
        /// Every (series, regime) with a supported day in `[day - windowDays, day]` is analysed: the closed and
        /// ongoing transient / recurring / persistent episodes of the window, plus one status entry
        /// (`usual_variation` / `insufficient_evidence`) when nothing non-usual is ongoing. History from `day` or
        /// later is ignored.
        public static func episodes(today: [DailyValue], history: [DailyValue], frozen: [FrozenReference],
                                    boundaries: [RegimeBoundary], day: String, mode: ProcessingMode,
                                    finality: Finality, policyFingerprint: String, change: ChangeConfig,
                                    reference: ReferenceConfig) -> [ChangeEpisode] {
            guard let t = Ref.dayNumber(day) else { return [] }
            let windowStart = t - max(1, change.windowDays)
            // Causal partial day (P2): today's value of a day-accumulating series is not like for like with the
            // whole-day history, so it stays out of the episodes (its comparison carries no distance either).
            let todays = today.filter { $0.day == day }
            let partial = Set(todays.filter { Ref.isCausalPartialDay($0.seriesKey, mode: $0.mode, config: reference) }
                .map { $0.seriesKey + "\u{1f}" + $0.regimeKey })
            let pool = history.filter { $0.day < day }
                + todays.filter { !partial.contains($0.seriesKey + "\u{1f}" + $0.regimeKey) }
            let eligible = pool.filter {
                $0.mode == mode && !Ref.isExcluded($0.seriesKey, reference)
                    && (change.episodesForStrata || !Ref.isStratum($0.seriesKey))
            }
            let index = Ref.HistoryIndex(eligible, before: t + 1, config: reference)

            // Regime-key changes per series (day of the first value in the new regime) and the provided boundaries
            // (UTC day of the boundary instant; the tolerance covers the zone offset).
            var regimeChangeDays: [String: [Int]] = [:]
            var bySeries: [String: [(Int, String)]] = [:]
            for v in eligible { if let n = Ref.dayNumber(v.day) { bySeries[v.seriesKey, default: []].append((n, v.regimeKey)) } }
            for (s, list) in bySeries {
                let sorted = list.sorted { $0.0 != $1.0 ? $0.0 < $1.0 : $0.1 < $1.1 }
                var days: [Int] = []
                for i in 1..<max(1, sorted.count) where sorted[i].1 != sorted[i - 1].1 && sorted[i].0 != sorted[i - 1].0 {
                    days.append(sorted[i].0)
                }
                regimeChangeDays[s] = days
            }
            let providedBoundaryDays = boundaries.map { Int((Double($0.at) / 86_400).rounded(.down)) }

            var out: [ChangeEpisode] = []
            let prefix = mode.rawValue + "\u{1f}"
            for key in index.points.keys.sorted() where key.hasPrefix(prefix) {
                let parts = key.components(separatedBy: "\u{1f}")
                guard parts.count == 3 else { continue }
                let series = parts[1], regime = parts[2]
                let pts = index.points[key]!
                guard pts.contains(where: { $0.dayNum >= windowStart && $0.dayNum <= t }) else { continue }
                // The registered reference is the authority (same rule as the frozen comparison); it scores only
                // days after its window.
                let f = Ref.frozenAuthority(seriesKey: series, regimeKey: regime, frozen: frozen, mode: mode, t: t,
                                            config: reference).reference
                    .flatMap { (Ref.dayNumber($0.toDay) ?? .max) < t ? $0 : nil }
                    .flatMap { $0.transform == Ref.transformName(series, config: reference) ? $0 : nil }
                let boundaryDays = (providedBoundaryDays + (regimeChangeDays[series] ?? [])).sorted()
                let analysis = analyze(points: pts, windowStart: windowStart, todayNum: t, frozen: f,
                                       boundaryDays: boundaryDays, seriesKey: series, change: change,
                                       reference: reference)
                let units = eligible.first { $0.seriesKey == series && $0.regimeKey == regime }?.units ?? ""
                var entries = assemble(analysis, seriesKey: series, regimeKey: regime, todayNum: t, frozen: f,
                                       finality: finality, policyFingerprint: policyFingerprint, units: units,
                                       change: change, reference: reference)
                if partial.contains(series + "\u{1f}" + regime) {
                    for i in entries.indices {
                        entries[i].reasons = Array(Set(entries[i].reasons + [partialDayValueExcluded])).sorted()
                    }
                }
                out += entries
            }
            return out.sorted { a, b in
                if (a.seriesKey, a.regimeKey) != (b.seriesKey, b.regimeKey) {
                    return (a.seriesKey, a.regimeKey) < (b.seriesKey, b.regimeKey)
                }
                if a.startDay != b.startDay { return a.startDay < b.startDay }
                if a.direction != b.direction { return a.direction < b.direction }
                return a.state.rawValue < b.state.rawValue
            }
        }

        // MARK: - Sequential analysis of one (series, regime)

        /// One supported day of the analysed window with its sequential scores.
        struct DayScore: Equatable, Sendable {
            var dayNum: Int
            var day: String
            var value: Double
            var x: Double
            /// Robust z against the rolling reference of strictly earlier days (nil below its minimum support).
            var rollingZ: Double?
            var rollingCenterX: Double?
            var rollingScale: Double?
            /// Robust z against the frozen reference (days after its selection window only).
            var frozenZ: Double?
            /// Lag-1 autocorrelation of earlier days (clamped to [0, autocorrelationMax]); nil when too few pairs.
            var phi: Double?
            /// Detector state resets before this day (gap or regime boundary).
            var resetBefore: ReasonCode?
            /// The day enters the detectors (past the burn-in, `detectorMinLookbackDays`); otherwise it is scored
            /// for display only.
            var detectorDay = true
            /// φ̂ was not estimable and the CUSUM used `autocorrelationFallback` for this day.
            var phiAssumed = false
        }

        struct Draft: Equatable, Sendable {
            var state: EpisodeState
            var direction: Int
            var startIdx: Int
            var lastIdx: Int
            var alarmIdx: Int?
            var ongoing: Bool
            var detector: String
            var reasons: [ReasonCode]
            var peak: Double?
            var occurrences = 1
        }

        struct SegmentAnalysis: Equatable, Sendable {
            var scores: [DayScore]
            /// Persistent episodes of the configured detector, then transients / recurring and frozen persistence.
            var drafts: [Draft]
            /// Persistent episodes of the other detector (for agreement reasons and the evaluation).
            var alternative: [Draft]
            var trendPerWeek: Double?
            var trendDays: Int
            var scoredCount: Int
            /// Regime boundary days (provided boundaries and regime-key changes of the series).
            var boundaryDays: [Int]
        }

        /// Score every supported day in `[windowStart, todayNum]` sequentially and derive episode drafts.
        /// `points` must be sorted by day, one per day, same series / regime / mode.
        static func analyze(points: [Ref.RefPoint], windowStart: Int, todayNum: Int, frozen: FrozenReference?,
                            boundaryDays: [Int], seriesKey: String, change: ChangeConfig,
                            reference: ReferenceConfig) -> SegmentAnalysis {
            let scores = score(points: points, windowStart: windowStart, todayNum: todayNum, frozen: frozen,
                               boundaryDays: boundaryDays, seriesKey: seriesKey, change: change,
                               reference: reference)
            return detect(scores, todayNum: todayNum, boundaryDays: boundaryDays, change: change)
        }

        static func score(points: [Ref.RefPoint], windowStart: Int, todayNum: Int, frozen: FrozenReference?,
                          boundaryDays: [Int], seriesKey: String, change: ChangeConfig,
                          reference: ReferenceConfig) -> [DayScore] {
            var scores: [DayScore] = []
            let frozenTo = frozen.flatMap { Ref.dayNumber($0.toDay) }
            let frozenStats = frozen.map { Ref.frozenStats($0, config: reference) }
            // First loaded day of the series: the burn-in is measured from it (cold start of a new series, of a
            // new regime, or of a truncated history load alike).
            let firstLoaded = points.first?.dayNum ?? todayNum
            var lo = 0, aLo = 0, aHi = 0
            var prevDay: Int?
            for i in points.indices {
                let p = points[i]
                guard p.dayNum <= todayNum else { break }
                while lo < i && points[lo].dayNum < p.dayNum - reference.rollingWindowDays { lo += 1 }
                guard p.dayNum >= windowStart else { continue }
                var s = DayScore(dayNum: p.dayNum, day: p.day, value: p.value, x: p.x)
                let st = Ref.stats(Array(points[lo..<i]), seriesKey: seriesKey, estimator: reference.rollingEstimator,
                                   config: reference)
                if st.n >= reference.rollingMinDays, let c = st.center, let sc = st.scale, sc > 0 {
                    let z = (p.x - c) / sc
                    if z.isFinite { s.rollingZ = z; s.rollingCenterX = c; s.rollingScale = sc }
                }
                s.detectorDay = p.dayNum - firstLoaded >= max(0, change.detectorMinLookbackDays)
                if change.cusumAutocorrelationAdjustment {
                    let hiDay = p.dayNum - max(1, change.autocorrelationGuardDays)
                    let loDay = hiDay - change.autocorrelationWindowDays
                    while aHi < i && points[aHi].dayNum <= hiDay { aHi += 1 }
                    while aLo < aHi && points[aLo].dayNum <= loDay { aLo += 1 }
                    s.phi = lagOneAutocorrelation(points[aLo..<aHi], change: change)
                    s.phiAssumed = s.phi == nil
                }
                if let fs = frozenStats, let to = frozenTo, p.dayNum > to, let c = fs.center, let sc = fs.scale, sc > 0 {
                    let z = (p.x - c) / sc
                    if z.isFinite { s.frozenZ = z }
                }
                if let prev = prevDay {
                    if boundaryDays.contains(where: { $0 > prev && $0 <= p.dayNum }) {
                        s.resetBefore = splitAtRegimeBoundary
                    } else if p.dayNum - prev > change.maxGapDays {
                        s.resetBefore = gapReset
                    }
                }
                prevDay = p.dayNum
                scores.append(s)
            }
            return scores
        }

        /// Robust lag-1 autocorrelation of consecutive supported days (pairs at most `maxGapDays` apart, the steps
        /// the CUSUM takes without a reset): deviations from the median in MAD-scale units, winsorized at ±3,
        /// `mean over pairs(d_t d_{t+1}) / mean over days(d_t²)` (missing days are never zero-filled); clamped to
        /// [0, autocorrelationMax]; nil below the minimum pairs (the CUSUM then uses `autocorrelationFallback`).
        static func lagOneAutocorrelation(_ pts: ArraySlice<Ref.RefPoint>, change: ChangeConfig) -> Double? {
            guard pts.count > change.autocorrelationMinPairs else { return nil }
            let xs = pts.map(\.x)
            guard let med = RobustStats.median(xs),
                  let sc = RobustStats.madScale(xs, center: med, smallSampleCorrection: true), sc > 0 else { return nil }
            let arr = Array(pts)
            var num = 0.0, den = 0.0, pairs = 0
            for j in arr.indices {
                let d = min(3, max(-3, (arr[j].x - med) / sc))
                den += d * d
                if j + 1 < arr.count && arr[j + 1].dayNum - arr[j].dayNum <= max(1, change.maxGapDays) {
                    num += d * min(3, max(-3, (arr[j + 1].x - med) / sc)); pairs += 1
                }
            }
            guard pairs >= change.autocorrelationMinPairs, den > 0 else { return nil }
            let r = (num / Double(pairs)) / (den / Double(arr.count))
            return r.isFinite ? min(change.autocorrelationMax, max(0, r)) : nil
        }

        static func detect(_ input: [DayScore], todayNum: Int, boundaryDays: [Int],
                           change: ChangeConfig) -> SegmentAnalysis {
            // Detector days: past the burn-in and scored against a rolling reference.
            var scores = input
            let scored = scores.indices.filter { scores[$0].rollingZ != nil && scores[$0].detectorDay }
            // A reset (gap, regime boundary) on a day that is not a detector day carries to the next detector day,
            // so the detectors never bridge it.
            var pending: ReasonCode?
            var next = 0
            for i in scores.indices {
                let isScored = next < scored.count && scored[next] == i
                if let r = scores[i].resetBefore, pending == nil || r == splitAtRegimeBoundary { pending = r }
                if isScored {
                    scores[i].resetBefore = pending
                    pending = nil
                    next += 1
                }
            }
            let cusum = cusumDrafts(scores, scored: scored, change: change)
            let persistence = persistenceDrafts(scores, scored: scored, change: change)
            let primaryIsCusum = change.detector != "persistence"
            var primary = primaryIsCusum ? cusum : persistence
            let alternative = primaryIsCusum ? persistence : cusum

            for i in primary.indices {
                let p = primary[i]
                let overlaps = alternative.contains {
                    $0.direction == p.direction && $0.startIdx <= p.lastIdx && $0.lastIdx >= p.startIdx
                }
                primary[i].reasons.append(overlaps ? alternativeDetectorAgrees : alternativeDetectorSilent)
            }

            var drafts = primary
            drafts += excursions(scores, scored: scored, persistent: primary, change: change)
            drafts = frozenPersistence(scores, drafts: drafts, change: change)

            // Closed persistent episodes: did the series come back, or did the rolling reference absorb it?
            for i in drafts.indices where drafts[i].state == .persistentShift && !drafts[i].ongoing
                && drafts[i].detector != "frozen_persistence" {
                let d = drafts[i]
                let after = scored.filter { $0 > d.lastIdx }.prefix(change.frozenPersistenceWindow)
                guard !after.isEmpty, let c = scores[d.startIdx].rollingCenterX,
                      let s = scores[d.startIdx].rollingScale, s > 0,
                      let m = RobustStats.median(after.map { scores[$0].x }) else { continue }
                drafts[i].reasons.append(abs((m - c) / s) < change.returnedZ ? returnedTowardReference : rollingAdapted)
            }

            // Raw trend over the scored window (Theil–Sen, original units per week).
            var trend: Double?
            let trendIdx = scores.indices
            if scores.count >= max(2, change.trendMinDays) {
                trend = RobustStats.theilSenSlope(x: trendIdx.map { Double(scores[$0].dayNum) },
                                                  y: trendIdx.map { scores[$0].value }).map { $0 * 7 }
            }
            let span = scores.isEmpty ? 0 : scores.last!.dayNum - scores.first!.dayNum + 1
            return SegmentAnalysis(scores: scores, drafts: drafts, alternative: alternative, trendPerWeek: trend,
                                   trendDays: span, scoredCount: scored.count, boundaryDays: boundaryDays)
        }

        /// Two-sided CUSUM on clamped daily robust z: `S_t = min(cap, max(0, S_{t-1} + dir * z_t - k))`. A run is
        /// the stretch with S > 0; it is a persistent shift once S exceeds h, and the alarm is sustained while S stays
        /// above h. Start = first day of the run (the CUSUM change-point estimate); last = the last day that pushed S
        /// up while the alarm held; ongoing = S above h on the latest scored day.
        static func cusumDrafts(_ scores: [DayScore], scored: [Int], change: ChangeConfig) -> [Draft] {
            var out: [Draft] = []
            let k = change.cusumK, h = change.cusumH
            let cap = max(h, change.cusumCapFactor * h)
            let clamp = max(0, change.cusumClampZ)
            for dir in [1, -1] {
                var s = 0.0
                var run: Draft?
                var lastContrib = 0
                func close(_ reason: ReasonCode?, ongoing: Bool) {
                    if var r = run, r.alarmIdx != nil {
                        r.ongoing = ongoing
                        if let reason { r.reasons.append(reason) }
                        out.append(r)
                    }
                    run = nil
                }
                for i in scored {
                    let sc = scores[i]
                    if let reset = sc.resetBefore { close(reset, ongoing: false); s = 0 }
                    var z = min(clamp, max(-clamp, sc.rollingZ!))
                    if change.cusumAutocorrelationAdjustment {
                        // No estimate → the conservative fallback, never "no adjustment" (R-F9).
                        let phi = min(0.99, change.autocorrelationMax,
                                      max(0, sc.phi ?? change.autocorrelationFallback))
                        z /= ((1 + phi) / (1 - phi)).squareRoot()
                    }
                    let next = min(cap, max(0, s + Double(dir) * z - k))
                    if next > 0 {
                        if run == nil {
                            run = Draft(state: .persistentShift, direction: dir, startIdx: i, lastIdx: i,
                                        alarmIdx: nil, ongoing: false, detector: "cusum", reasons: [detectorCusum],
                                        peak: 0)
                        }
                        if Double(dir) * z > k { lastContrib = i }
                        run!.peak = max(run!.peak ?? 0, next)
                        if next > h {
                            if run!.alarmIdx == nil { run!.alarmIdx = i }
                            run!.lastIdx = lastContrib
                        }
                    } else if run != nil {
                        close(nil, ongoing: false)
                    }
                    s = next
                }
                close(nil, ongoing: s > h)
            }
            return out
        }

        /// Persistence rule: fires on a day when at least `persistenceCount` of the last `persistenceWindow` scored
        /// days (not crossing a reset) have `dir * z ≥ persistenceZ`.
        static func persistenceDrafts(_ scores: [DayScore], scored: [Int], change: ChangeConfig) -> [Draft] {
            var out: [Draft] = []
            let w = max(1, change.persistenceWindow), need = max(1, change.persistenceCount)
            for dir in [1, -1] {
                var segmentStart = 0
                var run: Draft?
                for pos in scored.indices {
                    if scores[scored[pos]].resetBefore != nil {
                        if var r = run { r.ongoing = false; r.reasons.append(scores[scored[pos]].resetBefore!); out.append(r) }
                        run = nil
                        segmentStart = pos
                    }
                    let from = max(segmentStart, pos - w + 1)
                    let window = scored[from...pos]
                    let hits = window.filter { Double(dir) * scores[$0].rollingZ! >= change.persistenceZ }
                    if hits.count >= need {
                        if run == nil {
                            run = Draft(state: .persistentShift, direction: dir, startIdx: hits.first!,
                                        lastIdx: hits.last!, alarmIdx: scored[pos], ongoing: false,
                                        detector: "persistence", reasons: [detectorPersistence],
                                        peak: Double(hits.count))
                        }
                        run!.lastIdx = hits.last!
                        run!.peak = max(run!.peak ?? 0, Double(hits.count))
                    } else if var r = run {
                        r.ongoing = false; out.append(r); run = nil
                    }
                }
                if var r = run { r.ongoing = true; out.append(r) }
            }
            return out
        }

        /// Deviating days (|z| ≥ deviationZ) outside same-direction persistent episodes, grouped into transient
        /// excursions; same-direction excursions within `recurrenceWindowDays` of each other form one recurring
        /// episode.
        static func excursions(_ scores: [DayScore], scored: [Int], persistent: [Draft],
                               change: ChangeConfig) -> [Draft] {
            var transients: [Draft] = []
            for dir in [1, -1] {
                var current: Draft?
                var gap = 0
                for (pos, i) in scored.enumerated() {
                    let z = scores[i].rollingZ!
                    if scores[i].resetBefore != nil, let c = current { transients.append(c); current = nil }
                    let inPersistent = persistent.contains { $0.direction == dir && i >= $0.startIdx && i <= $0.lastIdx }
                    let deviating = !inPersistent && Double(dir) * z >= change.deviationZ
                    if deviating {
                        if current != nil && gap <= change.transientMergeGapDays {
                            current!.lastIdx = i
                        } else {
                            if let c = current { transients.append(c) }
                            current = Draft(state: .transientDeviation, direction: dir, startIdx: i, lastIdx: i,
                                            alarmIdx: nil, ongoing: false, detector: "deviation",
                                            reasons: [isolatedExcursion], peak: nil)
                        }
                        gap = 0
                    } else if current != nil {
                        gap += 1
                        if gap > change.transientMergeGapDays { transients.append(current!); current = nil }
                    }
                    if pos == scored.count - 1, var c = current {
                        c.ongoing = c.lastIdx == i
                        transients.append(c); current = nil
                    }
                }
            }
            // Recurrence clusters (same direction, chained by `recurrenceWindowDays`).
            var out: [Draft] = []
            for dir in [1, -1] {
                let ts = transients.filter { $0.direction == dir }.sorted { $0.startIdx < $1.startIdx }
                var cluster: [Draft] = []
                func flush() {
                    if cluster.count >= max(2, change.recurrenceMinCount) {
                        var r = Draft(state: .recurringEpisode, direction: dir, startIdx: cluster.first!.startIdx,
                                      lastIdx: cluster.last!.lastIdx, alarmIdx: cluster[max(2, change.recurrenceMinCount) - 1].startIdx,
                                      ongoing: cluster.last!.ongoing, detector: "deviation",
                                      reasons: [recurringWithinWindow], peak: nil)
                        r.occurrences = cluster.count
                        out.append(r)
                    } else {
                        out += cluster
                    }
                    cluster = []
                }
                for t in ts {
                    if let last = cluster.last,
                       scores[t.startIdx].dayNum - scores[last.lastIdx].dayNum > change.recurrenceWindowDays {
                        flush()
                    }
                    cluster.append(t)
                }
                flush()
            }
            return out
        }

        /// One stretch of days on which the frozen persistence rule fires (score indices).
        struct FrozenRun: Equatable, Sendable {
            var direction: Int
            /// First qualifying day of the first firing window (the episode start).
            var firstHit: Int
            /// First day the rule fired.
            var alarmIdx: Int
            /// Last day the rule fired.
            var lastIdx: Int
        }

        /// Every stretch where at least `frozenPersistenceCount` of the last `frozenPersistenceWindow` frozen-scored
        /// days have `dir * frozenZ ≥ frozenPersistenceZ`.
        static func frozenRuns(_ scores: [DayScore], change: ChangeConfig) -> [FrozenRun] {
            let fIdx = scores.indices.filter { scores[$0].frozenZ != nil }
            guard !fIdx.isEmpty else { return [] }
            let w = max(1, change.frozenPersistenceWindow), need = max(1, change.frozenPersistenceCount)
            var out: [FrozenRun] = []
            for dir in [1, -1] {
                var run: FrozenRun?
                for pos in fIdx.indices {
                    let hits = fIdx[max(0, pos - w + 1)...pos].filter {
                        Double(dir) * scores[$0].frozenZ! >= change.frozenPersistenceZ
                    }
                    if hits.count >= need {
                        if run == nil {
                            run = FrozenRun(direction: dir, firstHit: hits.first!, alarmIdx: fIdx[pos], lastIdx: fIdx[pos])
                        }
                        run!.lastIdx = fIdx[pos]
                    } else if let r = run {
                        out.append(r); run = nil
                    }
                }
                if let r = run { out.append(r) }
            }
            return out
        }

        /// Keep a fixed-reference deviation visible: when the frozen persistence rule fires at the latest frozen-
        /// scored day, extend a same-direction persistent episode the rolling detector closed (the rolling reference
        /// adapted) or open a frozen-reference persistent episode (e.g. gradual drift).
        static func frozenPersistence(_ scores: [DayScore], drafts: [Draft], change: ChangeConfig) -> [Draft] {
            var drafts = drafts
            guard let lastFrozen = scores.lastIndex(where: { $0.frozenZ != nil }) else {
                for i in drafts.indices where drafts[i].state == .persistentShift { drafts[i].reasons.append(frozenUnavailable) }
                return drafts
            }
            for run in frozenRuns(scores, change: change) where run.lastIdx == lastFrozen {
                let dir = run.direction
                let lastIdx = scores.count - 1
                if drafts.contains(where: { $0.state == .persistentShift && $0.direction == dir && $0.ongoing }) {
                    continue  // the rolling detector still holds the alarm; agreement is recorded below
                }
                if let j = drafts.indices.last(where: {
                    drafts[$0].state == .persistentShift && drafts[$0].direction == dir && !drafts[$0].ongoing
                        && drafts[$0].lastIdx >= run.firstHit - 1
                }) {
                    drafts[j].lastIdx = lastIdx
                    drafts[j].ongoing = true
                    drafts[j].reasons.append(rollingAdaptedFrozenDeviationPersists)
                } else {
                    var reasons: [ReasonCode] = [frozenReferenceDeviation]
                    let rollingAlarm = drafts.contains {
                        $0.state == .persistentShift && $0.direction == dir && $0.lastIdx >= run.firstHit
                    }
                    if !rollingAlarm { reasons.append(gradualDrift) }
                    drafts.append(Draft(state: .persistentShift, direction: dir, startIdx: run.firstHit,
                                        lastIdx: lastIdx, alarmIdx: run.alarmIdx, ongoing: true,
                                        detector: "frozen_persistence", reasons: reasons, peak: nil))
                }
            }
            for i in drafts.indices where drafts[i].state == .persistentShift && drafts[i].detector != "frozen_persistence" {
                let zs = (drafts[i].startIdx...drafts[i].lastIdx).compactMap { scores[$0].frozenZ }
                if let m = RobustStats.median(zs) {
                    drafts[i].reasons.append(Double(drafts[i].direction) * m >= change.returnedZ
                                             ? frozenAndRollingAgree : frozenAndRollingDisagree)
                } else {
                    drafts[i].reasons.append(frozenUnavailable)
                }
            }
            return drafts
        }

        /// Turn drafts into episodes (ids, magnitudes, boundary / ongoing reasons) plus the status entry.
        static func assemble(_ a: SegmentAnalysis, seriesKey: String, regimeKey: String, todayNum: Int,
                             frozen: FrozenReference?, finality: Finality, policyFingerprint: String, units: String,
                             change: ChangeConfig, reference: ReferenceConfig) -> [ChangeEpisode] {
            let scores = a.scores
            guard !scores.isEmpty else { return [] }
            let log = Ref.isLog(seriesKey, config: reference)
            let transform = log ? "ln" : "identity"
            let recent = scores.last!.dayNum >= todayNum - change.ongoingMaxGapDays
            // First and last detector days (the detectors' own window, after the burn-in).
            let firstScored = scores.firstIndex { $0.rollingZ != nil && $0.detectorDay }
            let burnIn = scores.contains { $0.rollingZ != nil && !$0.detectorDay }
            let fCenter = frozen.map { Ref.inverse($0.center, log: log) }

            // One draft per (start day, direction): keep the strongest state.
            let rank: [EpisodeState: Int] = [.persistentShift: 3, .recurringEpisode: 2, .transientDeviation: 1]
            var byKey: [String: Draft] = [:]
            for d in a.drafts {
                let k = "\(scores[d.startIdx].dayNum)|\(d.direction)"
                if let e = byKey[k] {
                    if rank[d.state, default: 0] > rank[e.state, default: 0] {
                        var m = d; m.reasons += e.reasons; byKey[k] = m
                    } else {
                        byKey[k]!.reasons += d.reasons
                    }
                } else {
                    byKey[k] = d
                }
            }

            func make(_ state: EpisodeState, direction: Int, startIdx: Int, lastIdx: Int, alarmIdx: Int?,
                      ongoing: Bool, detector: String, reasons: [ReasonCode], peak: Double?,
                      occurrences: Int) -> ChangeEpisode {
                let start = scores[startIdx], last = scores[lastIdx]
                var reasons = reasons + [descriptiveOnly]
                var ongoing = ongoing
                if ongoing && !recent { ongoing = false; reasons.append(noRecentSupport) }
                if direction != 0 {
                    let tol = change.boundaryToleranceDays
                    if a.boundaryDays.contains(where: { abs($0 - start.dayNum) <= tol }) {
                        reasons.append(coincidesWithRegimeBoundary)
                    }
                    if let f = firstScored, startIdx == f { reasons.append(startsAtWindowStart) }
                }
                let span = Array(startIdx...lastIdx)
                if detector == "cusum" || direction == 0,
                   span.contains(where: { scores[$0].phiAssumed && scores[$0].detectorDay && scores[$0].rollingZ != nil }) {
                    reasons.append(autocorrelationAssumedConservative)
                }
                if burnIn { reasons.append(detectorBurnIn) }
                let rollingDiffs = span.compactMap { i in scores[i].rollingCenterX.map { scores[i].value - Ref.inverse($0, log: log) } }
                let frozenDiffs = fCenter.map { c in span.filter { scores[$0].frozenZ != nil }.map { scores[$0].value - c } } ?? []
                let id = "ep_" + PhysiologyContext.fnv1a("\(seriesKey)|\(regimeKey)|\(start.day)|\(direction)|\(policyFingerprint)")
                return ChangeEpisode(
                    id: id, seriesKey: seriesKey, regimeKey: regimeKey, state: state, direction: direction,
                    startDay: start.day, lastDay: last.day, ongoing: ongoing,
                    durationDays: last.dayNum - start.dayNum + 1, finality: finality,
                    reasons: Array(Set(reasons)).sorted(), detector: detector,
                    alarmDay: alarmIdx.map { scores[$0].day },
                    alarmAfterStartDays: alarmIdx.map { scores[$0].dayNum - start.dayNum },
                    supportDays: span.filter { scores[$0].rollingZ != nil && scores[$0].detectorDay }.count,
                    occurrences: occurrences,
                    rollingMagnitude: finite(RobustStats.median(rollingDiffs)),
                    frozenMagnitude: finite(RobustStats.median(frozenDiffs)),
                    medianRollingZ: finite(RobustStats.median(span.compactMap { scores[$0].rollingZ })),
                    medianFrozenZ: finite(RobustStats.median(span.compactMap { scores[$0].frozenZ })),
                    frozenReferenceId: frozen?.id, trendPerWeek: finite(a.trendPerWeek), trendDays: a.trendDays,
                    peakStatistic: finite(peak), units: units, transform: transform)
            }

            var out: [ChangeEpisode] = []
            for d in byKey.values {
                out.append(make(d.state, direction: d.direction, startIdx: d.startIdx, lastIdx: d.lastIdx,
                                alarmIdx: d.alarmIdx, ongoing: d.ongoing, detector: d.detector, reasons: d.reasons,
                                peak: d.peak, occurrences: d.occurrences))
            }
            let anyOngoing = out.contains { $0.ongoing && $0.state != .usualVariation }
            if !anyOngoing {
                if a.scoredCount < change.minScoredDays || firstScored == nil {
                    var reasons: [ReasonCode] = [tooFewSupportedDays]
                    if !scores.contains(where: { $0.rollingZ != nil }) { reasons.append(noReference) }
                    out.append(make(.insufficientEvidence, direction: 0, startIdx: 0, lastIdx: scores.count - 1,
                                    alarmIdx: nil, ongoing: true, detector: "", reasons: reasons, peak: nil,
                                    occurrences: 1))
                } else {
                    let lastScored = scores.lastIndex { $0.rollingZ != nil && $0.detectorDay }!
                    out.append(make(.usualVariation, direction: 0, startIdx: firstScored!, lastIdx: lastScored,
                                    alarmIdx: nil, ongoing: true, detector: "", reasons: [], peak: nil,
                                    occurrences: 1))
                }
            }
            return out
        }

        static func finite(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }

        // MARK: - Multi-signal

        /// Multi-signal summary that accounts for shared inputs (`dependence`).
        ///
        /// Deviating series (|robustZ| ≥ `multiSignalZ` in `multiSignalView`, ready or provisional) are mapped to
        /// dependence members (`dependenceMembers`: the metric, plus the selection they share) and connected through
        /// every declared group they share. `independentGroupCount` is the number of connected components.
        public static func multiSignal(comparisons: [ReferenceComparison], dependence: [DependenceNote],
                                       day: String, config: ChangeConfig) -> [MultiSignalSummary] {
            let relevant = comparisons.filter {
                $0.day == day && $0.view == config.multiSignalView && !Ref.isStratum($0.seriesKey)
                    && ($0.status == .ready || $0.status == .provisional) && $0.robustZ != nil
            }
            guard !relevant.isEmpty else { return [] }
            let deviating = Array(Set(relevant.filter { abs($0.robustZ!) >= config.multiSignalZ }.map(\.seriesKey))).sorted()
            guard !deviating.isEmpty else {
                return [MultiSignalSummary(day: day, deviatingSeries: [], dependenceGroups: [], independentGroupCount: 0,
                                           reasons: [noDeviatingSeries])]
            }
            var reasons: Set<ReasonCode> = []
            var groupsOf: [String: [String]] = [:]
            for s in deviating {
                let members = dependenceMembers(s)
                var gs = dependence.filter { !Set($0.members).isDisjoint(with: members) }.map(\.group)
                if gs.isEmpty { gs = ["undeclared:" + s]; reasons.insert(noDeclaredDependence) }
                groupsOf[s] = Array(Set(gs)).sorted()
                if selectionUsesHeartRate(s) { reasons.insert(selectionReadsHeartRate) }
            }
            // Union-find over series sharing a group.
            var parent = Dictionary(uniqueKeysWithValues: deviating.map { ($0, $0) })
            func find(_ x: String) -> String { var x = x; while parent[x]! != x { x = parent[x]! }; return x }
            for (i, a) in deviating.enumerated() {
                for b in deviating[(i + 1)...] where !Set(groupsOf[a]!).isDisjoint(with: groupsOf[b]!) {
                    let ra = find(a), rb = find(b)
                    if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
                }
            }
            var comps: [String: [String]] = [:]
            for s in deviating { comps[find(s), default: []].append(s) }
            let components = comps.values.map { series in
                DependenceComponent(series: series.sorted(),
                                    groups: Array(Set(series.flatMap { groupsOf[$0]! })).sorted())
            }.sorted { $0.series.first! < $1.series.first! }
            if components.contains(where: { $0.series.count > 1 }) { reasons.insert(sharedInputsNotIndependent) }
            if components.count > 1 { reasons.insert(groupsNotProvenIndependent) }
            return [MultiSignalSummary(day: day, deviatingSeries: deviating,
                                       dependenceGroups: Array(Set(groupsOf.values.flatMap { $0 })).sorted(),
                                       independentGroupCount: components.count, reasons: reasons.sorted(),
                                       components: components)]
        }

        /// Selection members shared by every series whose existence or denominator depends on the sleep / wake
        /// detector (gravity stillness confirmed by heart rate) and on wear (heart-signal presence).
        static let sleepWearSelection = ["sleep_detector", "sleep_wake", "wear_state"]

        /// Whether the series' selection reads heart rate (sleep / wake confirmation, heart-signal wear).
        static func selectionUsesHeartRate(_ seriesKey: String) -> Bool {
            dependenceMembers(seriesKey).contains("sleep_detector")
        }

        /// Dependence members of a series key: its metric (the input it is computed from) plus the selection it
        /// shares with other series. Members are matched against `DependenceNote.members`.
        ///
        /// - Nightly (`*.sleep_night`): the sleep detector selects the night (it reads heart rate).
        /// - Stable awake (`*.stable_awake*`): strap-motion stillness, plus the awake-and-worn gate (sleep / wake
        ///   detector, heart-signal wear).
        /// - Bout responses (`hr_response.*`) and post-effort declines (`hr_recovery_<s>s.*`): heart rate (so the
        ///   `heart_rate` and `optical_pulse` groups) and the strap-motion bouts.
        /// - Functional (`functional.*`): strap-motion features. Every functional value exists only with ≥ 4 worn
        ///   waking hours, and the per-worn-hour / waking-time rates divide by that time: waking time subtracts
        ///   the HR-confirmed sleep episodes and wear reads heart-signal presence (R-F4).
        public static func dependenceMembers(_ seriesKey: String) -> [String] {
            let head = String(seriesKey.split(separator: ".").first ?? "")
            var m: [String]
            switch head {
            case "hrv_rmssd": m = [MetricKind.hrvRmssd.rawValue]
            case "hrv_sdnn", "hrv_sdnn_index": m = [MetricKind.hrvSdnn.rawValue]
            case "resting_hr": m = [MetricKind.restingHeartRate.rawValue]
            case "resp_rate": m = [MetricKind.respiratoryRate.rawValue]
            case "heart_rate": m = [MetricKind.heartRate.rawValue]
            case "skin_temp": m = [MetricKind.skinTemperature.rawValue]
            case "hr_response": m = [MetricKind.heartRate.rawValue, "exertion_bouts"]
            case "functional": m = ["functional_features"] + sleepWearSelection
            default:
                // `hr_recovery_60s.<kind>` (ExertionBouts.recoverySeriesKey): HR declines after strap-motion bouts.
                m = head.hasPrefix("hr_recovery_") ? [MetricKind.heartRate.rawValue, "exertion_bouts"] : [head]
            }
            if seriesKey.contains(".sleep_night") { m += ["sleep_detector", "sleep_wake"] }
            if seriesKey.contains(".stable_awake") { m += ["eligibility_stillness"] + sleepWearSelection }
            return Array(Set(m)).sorted()
        }
    }
}

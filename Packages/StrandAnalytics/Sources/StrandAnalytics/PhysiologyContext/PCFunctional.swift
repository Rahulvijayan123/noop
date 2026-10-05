import Foundation

// PCFunctional.swift — System G: functional behaviour features and the versioned feature registry (spec §13).
//
// OWNER: responses & function workstream. Notes: docs/physiology-context/notes/responses.md.
//
// Observable behaviour is a product of its own, kept beside context-matched physiology; it is not adjusted away as a
// confounder. Lower captured activity under lower wear coverage is missingness, not decline.
//
// Denominators. The evaluated interval is the day window up to the cutoff. Sleep episodes are removed from it to
// give waking time (when no episode is known, waking time includes sleep and says so). A minute is worn when no
// wrist-off event holds and it has heart-signal presence (≥ 30 HR samples), locomotion evidence, or an on-wrist
// event with motion samples. Heart-signal presence is heart-derived, which is acceptable for a wear denominator
// (it never enters a physiological value here). Totals compare across days only when worn waking time is at least
// 70 % of waking time and the day is complete; wear-normalized values need at least 4 worn waking hours.
//
// Movement features come from the same heart-rate independent evidence as System D (HART first, else strap
// motion). Wrist cadence is uncalibrated counter steps per minute: it is not gait speed or stride length.

extension PhysiologyContext {

    public struct FunctionalConfig: Codable, Equatable, Sendable {
        public var version = "pc-functional-1"
        /// Day totals compare across days only when worn waking time is at least this share of waking time.
        public var minWearShareForTotals = 0.7
        /// Wear-normalized values need at least this much worn waking time.
        public var minWornWakingSForRates = 4 * 3600
        /// A minute is worn by heart-signal presence with at least this many HR samples (1 Hz stream).
        public var wearMinHrSamplesPerMinute = 30
        /// Other-movement seconds allowed between a stationary and a locomotion run for a direct transition.
        public var transitionMaxBridgeS = 30
        /// Rest after a bout is followed for at most this long.
        public var restAfterCapS = 3600
        /// Transition rates need at least this many active / rest minutes in the denominator.
        public var minActiveMinutesForTransitionRate = 5
        public var minRestMinutesForTransitionRate = 30
        /// Abstention share at or above which a span is unknown (System D uses the same default).
        public var maxUnknownFraction = 0.5
        public init() {}
    }

    /// The day's general functional features.
    public struct FunctionalDaySummary: Codable, Equatable, Sendable {
        public var day: String
        /// Seconds of the day with wear evidence, and the evidence basis.
        public var observedWearS: Int?
        public var wearBasis: String
        public var dayS: Int
        /// True when wear coverage is sufficient for day totals to be compared across days.
        public var totalsComparable: Bool
        public var reasons: [ReasonCode]

        /// `[day start, min(day end, cutoff))`.
        public var evaluated: Interval? = nil
        /// Evaluated seconds outside sleep episodes (all evaluated seconds when sleep is unknown).
        public var wakingS: Int? = nil
        public var sleepExcludedS: Int = 0
        public var wornWakingS: Int? = nil
        /// `wornWakingS / wakingS`.
        public var wearShare: Double? = nil
        /// True when worn waking time meets the floor for wear-normalized values.
        public var ratesSupported: Bool = false
        public var boutIds: [String] = []
        public var boutCount: Int = 0
        public var boutDurationMedianS: Double? = nil
        public var boutDurationP90: Double? = nil
        public var boutDurationMaxS: Int? = nil
        public var boutSecondsTotal: Int = 0
        /// Locomotion seconds of the HR-independent evidence in waking time (bouts and shorter walks).
        public var locomotionS: Int? = nil
        public var locomotionSecondsPerWornHour: Double? = nil
        public var boutsPerWornHour: Double? = nil
        /// Minute-weighted mean of the bouts' counter cadence; uncalibrated, not gait speed.
        public var cadenceMeanStepsPerMin: Double? = nil
        /// Median of the bouts' within-bout cadence coefficients of variation.
        public var cadenceWithinBoutCvMedian: Double? = nil
        public var cadenceMinutes: Int = 0
        public var cadenceBouts: Int = 0
        public var pauseCount: Int = 0
        public var pauseMedianS: Double? = nil
        public var pausesPerBoutHour: Double? = nil
        /// Stationary → locomotion and locomotion → stationary transitions on the HR-independent evidence.
        public var restToActiveTransitions: Int? = nil
        public var activeToRestTransitions: Int? = nil
        /// Active-to-rest transitions per active minute (a fragmentation index; higher = shorter active runs).
        public var activeToRestPerActiveMin: Double? = nil
        public var restToActivePerRestMin: Double? = nil
        /// Median still seconds after a bout before the next movement (observed ends only).
        public var restAfterBoutMedianS: Double? = nil
        public var restAfterBoutCount: Int = 0
        /// Method limitations that always apply to these features.
        public var limitations: [ReasonCode] = []

        public init(day: String, observedWearS: Int?, wearBasis: String, dayS: Int, totalsComparable: Bool,
                    reasons: [ReasonCode]) {
            self.day = day; self.observedWearS = observedWearS; self.wearBasis = wearBasis; self.dayS = dayS
            self.totalsComparable = totalsComparable; self.reasons = reasons
        }
        public static func unavailable(day: String, dayS: Int, reasons: [ReasonCode]) -> FunctionalDaySummary {
            FunctionalDaySummary(day: day, observedWearS: nil, wearBasis: "none", dayS: dayS,
                                 totalsComparable: false, reasons: reasons)
        }

        enum CodingKeys: String, CodingKey {
            case day, observedWearS, wearBasis, dayS, totalsComparable, reasons, evaluated, wakingS, sleepExcludedS,
                 wornWakingS, wearShare, ratesSupported, boutIds, boutCount, boutDurationMedianS, boutDurationP90,
                 boutDurationMaxS, boutSecondsTotal, locomotionS, locomotionSecondsPerWornHour, boutsPerWornHour,
                 cadenceMeanStepsPerMin, cadenceWithinBoutCvMedian, cadenceMinutes, cadenceBouts, pauseCount,
                 pauseMedianS, pausesPerBoutHour, restToActiveTransitions, activeToRestTransitions,
                 activeToRestPerActiveMin, restToActivePerRestMin, restAfterBoutMedianS, restAfterBoutCount,
                 limitations
        }

        /// Fields added after the contract skeleton decode to their defaults when absent.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            day = try c.decode(String.self, forKey: .day)
            observedWearS = try c.decodeIfPresent(Int.self, forKey: .observedWearS)
            wearBasis = try c.decode(String.self, forKey: .wearBasis)
            dayS = try c.decode(Int.self, forKey: .dayS)
            totalsComparable = try c.decode(Bool.self, forKey: .totalsComparable)
            reasons = try c.decodeIfPresent([ReasonCode].self, forKey: .reasons) ?? []
            evaluated = try c.decodeIfPresent(Interval.self, forKey: .evaluated)
            wakingS = try c.decodeIfPresent(Int.self, forKey: .wakingS)
            sleepExcludedS = try c.decodeIfPresent(Int.self, forKey: .sleepExcludedS) ?? 0
            wornWakingS = try c.decodeIfPresent(Int.self, forKey: .wornWakingS)
            wearShare = try c.decodeIfPresent(Double.self, forKey: .wearShare)
            ratesSupported = try c.decodeIfPresent(Bool.self, forKey: .ratesSupported) ?? false
            boutIds = try c.decodeIfPresent([String].self, forKey: .boutIds) ?? []
            boutCount = try c.decodeIfPresent(Int.self, forKey: .boutCount) ?? 0
            boutDurationMedianS = try c.decodeIfPresent(Double.self, forKey: .boutDurationMedianS)
            boutDurationP90 = try c.decodeIfPresent(Double.self, forKey: .boutDurationP90)
            boutDurationMaxS = try c.decodeIfPresent(Int.self, forKey: .boutDurationMaxS)
            boutSecondsTotal = try c.decodeIfPresent(Int.self, forKey: .boutSecondsTotal) ?? 0
            locomotionS = try c.decodeIfPresent(Int.self, forKey: .locomotionS)
            locomotionSecondsPerWornHour = try c.decodeIfPresent(Double.self, forKey: .locomotionSecondsPerWornHour)
            boutsPerWornHour = try c.decodeIfPresent(Double.self, forKey: .boutsPerWornHour)
            cadenceMeanStepsPerMin = try c.decodeIfPresent(Double.self, forKey: .cadenceMeanStepsPerMin)
            cadenceWithinBoutCvMedian = try c.decodeIfPresent(Double.self, forKey: .cadenceWithinBoutCvMedian)
            cadenceMinutes = try c.decodeIfPresent(Int.self, forKey: .cadenceMinutes) ?? 0
            cadenceBouts = try c.decodeIfPresent(Int.self, forKey: .cadenceBouts) ?? 0
            pauseCount = try c.decodeIfPresent(Int.self, forKey: .pauseCount) ?? 0
            pauseMedianS = try c.decodeIfPresent(Double.self, forKey: .pauseMedianS)
            pausesPerBoutHour = try c.decodeIfPresent(Double.self, forKey: .pausesPerBoutHour)
            restToActiveTransitions = try c.decodeIfPresent(Int.self, forKey: .restToActiveTransitions)
            activeToRestTransitions = try c.decodeIfPresent(Int.self, forKey: .activeToRestTransitions)
            activeToRestPerActiveMin = try c.decodeIfPresent(Double.self, forKey: .activeToRestPerActiveMin)
            restToActivePerRestMin = try c.decodeIfPresent(Double.self, forKey: .restToActivePerRestMin)
            restAfterBoutMedianS = try c.decodeIfPresent(Double.self, forKey: .restAfterBoutMedianS)
            restAfterBoutCount = try c.decodeIfPresent(Int.self, forKey: .restAfterBoutCount) ?? 0
            limitations = try c.decodeIfPresent([ReasonCode].self, forKey: .limitations) ?? []
        }
    }

    public enum Functional {

        public static let version = "pc-functional-1"

        // MARK: Reason codes
        public static let dayNotStarted: ReasonCode = "day_not_started_at_cutoff"
        public static let dayIncompleteAtCutoff: ReasonCode = "day_incomplete_at_cutoff"
        public static let wearEvidenceUnavailable: ReasonCode = "wear_evidence_unavailable"
        public static let insufficientWearCoverage: ReasonCode = "insufficient_wear_coverage"
        public static let insufficientWornTimeForRates: ReasonCode = "insufficient_worn_time_for_rates"
        public static let wearMissingnessMayBeInformative: ReasonCode = "wear_missingness_may_be_informative"
        public static let sleepNotExcluded: ReasonCode = "sleep_not_excluded_from_waking_time"
        public static let noWakingTime: ReasonCode = "no_waking_time"
        public static let activityEvidenceUnavailable: ReasonCode = "activity_evidence_unavailable"
        public static let noBouts: ReasonCode = "no_bouts"
        public static let wearFromHeartSignal: ReasonCode = "wear_denominator_uses_heart_signal_presence"
        public static let restAfterBoutRightCensored: ReasonCode = "rest_after_bout_right_censored"
        public static let transitionDenominatorTooSmall: ReasonCode = "transition_denominator_too_small"
        public static let observedBehaviourNotDiagnosis: ReasonCode = "observed_behaviour_not_diagnosis"

        public static let reasonCodes: [ReasonCode] = [
            dayNotStarted, dayIncompleteAtCutoff, wearEvidenceUnavailable, insufficientWearCoverage,
            insufficientWornTimeForRates, wearMissingnessMayBeInformative, sleepNotExcluded, noWakingTime,
            activityEvidenceUnavailable, noBouts, wearFromHeartSignal, restAfterBoutRightCensored,
            transitionDenominatorTooSmall, observedBehaviourNotDiagnosis,
            ExertionBouts.cadenceUnavailable, ExertionBouts.wristCadenceNotGaitSpeed,
            ExertionBouts.uncalibratedStepCounter,
        ]

        // MARK: Series keys
        public static let seriesLocomotionPerWornHour = "functional.locomotion_s_per_worn_hour"
        public static let seriesBoutsPerWornHour = "functional.bouts_per_worn_hour"
        public static let seriesMedianBout = "functional.median_bout_s"
        public static let seriesPausesPerBoutHour = "functional.pauses_per_bout_hour"
        public static let seriesCadenceMean = "functional.cadence_steps_per_min"
        public static let seriesCadenceCv = "functional.cadence_within_bout_cv"
        public static let seriesActiveToRest = "functional.active_to_rest_per_min"
        public static let seriesRestAfterBout = "functional.rest_after_bout_median_s"
        public static let seriesLocomotionTotal = "functional.locomotion_s"
        public static let seriesBoutCount = "functional.bout_count"

        public static func daySummary(identity: DayIdentity, bouts: [ExertionBout], hart: ResolvedTrack,
                                      strap: ResolvedTrack, observations: SanitizedObservations,
                                      sleep: SleepRhythmSummary, mode: ProcessingMode, cutoff: Int,
                                      config: FunctionalConfig) -> FunctionalDaySummary {
            let dayWindow = identity.dayWindow
            let evaluated = Interval(dayWindow.start, max(dayWindow.start, min(dayWindow.end, cutoff)))
            guard evaluated.isValid else {
                return .unavailable(day: identity.day, dayS: dayWindow.duration, reasons: [dayNotStarted])
            }
            var reasons: [ReasonCode] = []
            if evaluated.end < dayWindow.end { reasons.append(dayIncompleteAtCutoff) }
            let limitations: [ReasonCode] = [ExertionBouts.wristCadenceNotGaitSpeed,
                                             ExertionBouts.uncalibratedStepCounter, wearFromHeartSignal,
                                             observedBehaviourNotDiagnosis]

            // Waking time: evaluated seconds minus sleep episodes.
            let sleepSpans = ExertionBouts.merged(sleep.episodes.compactMap { $0.interval.intersection(evaluated) })
            if sleep.episodes.isEmpty { reasons.append(sleepNotExcluded) }
            let sleepS = ExertionBouts.totalDuration(sleepSpans)
            let wakingS = evaluated.duration - sleepS
            let waking = subtract(sleepSpans, from: evaluated)

            let evidence = BoutEvidence(hart: hart, strap: strap, maxUnknown: config.maxUnknownFraction)
            if evidence.coveredSeconds(in: evaluated) == 0 { reasons.append(activityEvidenceUnavailable) }

            // Wear per minute bin.
            let hrTs = observations.heartRate.filter { (30...250).contains($0.bpm) }.map(\.ts).sorted()
            let motionTs = observations.motion.map(\.ts).sorted()
            let events = observations.wearEvents.sorted { ($0.ts, $0.state.rawValue) < ($1.ts, $1.state.rawValue) }
            let eventTs = events.map(\.ts)
            let hasHeart = countIn(hrTs, evaluated) > 0
            let hasEvents = !events.filter { $0.ts < evaluated.end }.isEmpty
            var wornS = 0, wornWakingS = 0
            var locomotionWear = false
            for b in stride(from: evaluated.start, to: evaluated.end, by: 60) {
                let bin = Interval(b, min(b + 60, evaluated.end))
                let mid = bin.start + bin.duration / 2
                let k = upperBound(eventTs, mid)
                let state: WearEventState? = k > 0 ? events[k - 1].state : nil
                guard state != .offWrist else { continue }
                let needHr = Int((Double(config.wearMinHrSamplesPerMinute) * Double(bin.duration) / 60).rounded(.up))
                let heartPresent = countIn(hrTs, bin) >= max(1, needHr)
                let locomotion = evidence.locomotionSeconds(in: bin) > 0
                let onWithMotion = state == .onWrist && countIn(motionTs, bin) > 0
                guard heartPresent || locomotion || onWithMotion else { continue }
                if !heartPresent && !onWithMotion { locomotionWear = true }
                wornS += bin.duration
                wornWakingS += bin.duration - sleepSpans.reduce(0) { $0 + $1.overlapSeconds(with: bin) }
            }
            var basis: [String] = []
            if hasHeart { basis.append("heart_rate_signal") }
            if hasEvents { basis.append("wear_events") }
            let wearKnown = hasHeart || hasEvents
            if wearKnown && locomotionWear { basis.append("locomotion_evidence") }

            var summary = FunctionalDaySummary(day: identity.day, observedWearS: wearKnown ? wornS : nil,
                                               wearBasis: wearKnown ? basis.joined(separator: "+") : "none",
                                               dayS: dayWindow.duration, totalsComparable: false, reasons: [])
            summary.evaluated = evaluated
            summary.wakingS = wakingS
            summary.sleepExcludedS = sleepS
            summary.limitations = limitations
            var share: Double?
            if !wearKnown {
                reasons.append(wearEvidenceUnavailable)
            } else {
                summary.wornWakingS = wornWakingS
                if wakingS > 0 {
                    share = Double(wornWakingS) / Double(wakingS)
                } else {
                    reasons.append(noWakingTime)
                }
            }
            summary.wearShare = share
            let wearEnough = (share ?? 0) >= config.minWearShareForTotals
            if wearKnown && wakingS > 0 && !wearEnough {
                reasons.append(insufficientWearCoverage)
                reasons.append(wearMissingnessMayBeInformative)
            }
            summary.totalsComparable = wearKnown && wearEnough && evaluated.end == dayWindow.end
            let rates = wearKnown && wornWakingS >= config.minWornWakingSForRates && wornWakingS > 0
            if wearKnown && !rates { reasons.append(insufficientWornTimeForRates) }
            summary.ratesSupported = rates
            let wornHours = Double(wornWakingS) / 3600

            // Bouts owned by the day.
            let dayBouts = ExertionBouts.unique(bouts).filter { $0.day == identity.day }
                .sorted { $0.interval < $1.interval }
            summary.boutIds = dayBouts.map(\.id)
            summary.boutCount = dayBouts.count
            if dayBouts.isEmpty { reasons.append(noBouts) }
            let durations = dayBouts.map { Double($0.durationS) }
            summary.boutDurationMedianS = RobustStats.median(durations)
            summary.boutDurationP90 = RobustStats.quantile(durations, 0.9)
            summary.boutDurationMaxS = dayBouts.map(\.durationS).max()
            summary.boutSecondsTotal = dayBouts.reduce(0) { $0 + $1.durationS }
            let pauses = dayBouts.flatMap(\.pauses)
            summary.pauseCount = pauses.count
            summary.pauseMedianS = RobustStats.median(pauses.map { Double($0.duration) })
            if summary.boutSecondsTotal > 0 {
                summary.pausesPerBoutHour = Double(pauses.count) / (Double(summary.boutSecondsTotal) / 3600)
            }
            var cadenceWeighted = 0.0
            var cadenceMinutes = 0
            var cvs: [Double] = []
            var cadenceBouts = 0
            for b in dayBouts {
                guard let c = b.cadence, let mean = c.stepsPerMinMean, c.minutes > 0 else { continue }
                cadenceWeighted += mean * Double(c.minutes)
                cadenceMinutes += c.minutes
                cadenceBouts += 1
                if let cv = c.stepsPerMinCv { cvs.append(cv) }
            }
            summary.cadenceMinutes = cadenceMinutes
            summary.cadenceBouts = cadenceBouts
            if cadenceMinutes > 0 {
                summary.cadenceMeanStepsPerMin = cadenceWeighted / Double(cadenceMinutes)
            } else if !dayBouts.isEmpty {
                reasons.append(ExertionBouts.cadenceUnavailable)
            }
            summary.cadenceWithinBoutCvMedian = RobustStats.median(cvs)

            // Locomotion and transitions over waking evidence.
            let walk = walkWaking(evidence: evidence, waking: waking, config: config)
            summary.locomotionS = Int(walk.activeS.rounded())
            summary.restToActiveTransitions = walk.restToActive
            summary.activeToRestTransitions = walk.activeToRest
            if walk.activeS / 60 >= Double(config.minActiveMinutesForTransitionRate) {
                summary.activeToRestPerActiveMin = Double(walk.activeToRest) / (walk.activeS / 60)
            }
            if walk.restS / 60 >= Double(config.minRestMinutesForTransitionRate) {
                summary.restToActivePerRestMin = Double(walk.restToActive) / (walk.restS / 60)
            }
            if summary.activeToRestPerActiveMin == nil || summary.restToActivePerRestMin == nil {
                reasons.append(transitionDenominatorTooSmall)
            }
            if rates {
                summary.locomotionSecondsPerWornHour = walk.activeS / wornHours
                summary.boutsPerWornHour = Double(dayBouts.count) / wornHours
            }

            // Rest following activity: still seconds after each ended bout until the next movement.
            var rests: [Double] = []
            var rightCensored = 0
            for b in dayBouts where b.status != .ongoing {
                let limit = min(evaluated.end, b.interval.end + config.restAfterCapS)
                switch restAfter(b.interval.end, limit: limit, capped: b.interval.end + config.restAfterCapS <= limit,
                                 evidence: evidence) {
                case .some(let s): rests.append(Double(s))
                case .none: rightCensored += 1
                }
            }
            summary.restAfterBoutMedianS = RobustStats.median(rests)
            summary.restAfterBoutCount = rests.count
            if rightCensored > 0 { reasons.append(restAfterBoutRightCensored) }

            summary.reasons = Array(Set(reasons)).sorted()
            return summary
        }

        /// Daily values contributed by the functional product (only when `totalsComparable` or wear-normalized).
        public static func dailyValues(_ summary: FunctionalDaySummary, regimeKey: String, mode: ProcessingMode,
                                       finality: Finality, config: FunctionalConfig) -> [DailyValue] {
            guard summary.observedWearS != nil, let worn = summary.wornWakingS else { return [] }
            var out: [DailyValue] = []
            func add(_ key: String, _ value: Double?, units: String, count: Int, unit: String, supportS: Int,
                     reasons: [ReasonCode] = []) {
                guard let v = value, v.isFinite else { return }
                out.append(DailyValue(day: summary.day, seriesKey: key, regimeKey: regimeKey, metric: nil, value: v,
                                      units: units, supportCount: count, supportUnit: unit, supportS: supportS,
                                      mode: mode, finality: finality, sourceIds: summary.boutIds,
                                      reasons: (reasons + [observedBehaviourNotDiagnosis]).sorted()))
            }
            if summary.ratesSupported {
                add(seriesLocomotionPerWornHour, summary.locomotionSecondsPerWornHour, units: "s_per_h", count: 1,
                    unit: "day", supportS: worn)
                add(seriesBoutsPerWornHour, summary.boutsPerWornHour, units: "per_h", count: 1, unit: "day",
                    supportS: worn)
                if summary.boutCount > 0 {
                    add(seriesMedianBout, summary.boutDurationMedianS, units: "s", count: summary.boutCount,
                        unit: "bout", supportS: summary.boutSecondsTotal)
                    add(seriesPausesPerBoutHour, summary.pausesPerBoutHour, units: "per_h", count: summary.boutCount,
                        unit: "bout", supportS: summary.boutSecondsTotal)
                }
                let cadenceReasons = [ExertionBouts.wristCadenceNotGaitSpeed, ExertionBouts.uncalibratedStepCounter]
                add(seriesCadenceMean, summary.cadenceMeanStepsPerMin, units: "counter_steps_per_min",
                    count: summary.cadenceBouts, unit: "bout", supportS: summary.cadenceMinutes * 60,
                    reasons: cadenceReasons)
                add(seriesCadenceCv, summary.cadenceWithinBoutCvMedian, units: "ratio", count: summary.cadenceBouts,
                    unit: "bout", supportS: summary.cadenceMinutes * 60, reasons: cadenceReasons)
                add(seriesActiveToRest, summary.activeToRestPerActiveMin, units: "per_min", count: 1, unit: "day",
                    supportS: summary.locomotionS ?? 0)
                add(seriesRestAfterBout, summary.restAfterBoutMedianS, units: "s", count: summary.restAfterBoutCount,
                    unit: "bout", supportS: summary.boutSecondsTotal)
            }
            if summary.totalsComparable {
                add(seriesLocomotionTotal, summary.locomotionS.map(Double.init), units: "s", count: 1, unit: "day",
                    supportS: worn)
                add(seriesBoutCount, Double(summary.boutCount), units: "count", count: 1, unit: "day", supportS: worn)
            }
            return out.sorted { $0.seriesKey < $1.seriesKey }
        }

        // MARK: - Helpers

        enum Category { case stationary, locomotion, other, unknown }

        static func category(_ s: EvidenceSpan, _ evidence: BoutEvidence) -> Category {
            if evidence.isLocomotion(s) { return .locomotion }
            if evidence.isStationary(s) { return .stationary }
            if evidence.isMovement(s) { return .other }
            return .unknown
        }

        /// Locomotion / stationary seconds and direct transitions over the waking pieces of the evidence. A gap,
        /// an unknown span, a sleep boundary or more than `transitionMaxBridgeS` of other movement breaks the chain.
        static func walkWaking(evidence: BoutEvidence, waking: [Interval],
                               config: FunctionalConfig) -> (activeS: Double, restS: Double, restToActive: Int,
                                                             activeToRest: Int) {
            var activeS = 0.0, restS = 0.0
            var restToActive = 0, activeToRest = 0
            var lastKnown: Category?
            var bridge = 0
            var previousEnd: Int?
            for w in waking {
                for s in evidence.overlapping(w) {
                    guard let piece = s.interval.intersection(w) else { continue }
                    if previousEnd != piece.start { lastKnown = nil; bridge = 0 }
                    previousEnd = piece.end
                    let c = category(s, evidence)
                    let weight = Double(piece.duration) * (1 - s.unknownFraction)
                    switch c {
                    case .unknown:
                        lastKnown = nil; bridge = 0
                    case .other:
                        if lastKnown != nil {
                            bridge += piece.duration
                            if bridge > config.transitionMaxBridgeS { lastKnown = nil; bridge = 0 }
                        }
                    case .stationary, .locomotion:
                        if c == .locomotion { activeS += weight } else { restS += weight }
                        if let k = lastKnown, k != c {
                            if c == .locomotion { restToActive += 1 } else { activeToRest += 1 }
                        }
                        lastKnown = c
                        bridge = 0
                    }
                }
            }
            return (activeS, restS, restToActive, activeToRest)
        }

        /// Contiguous stationary seconds from `start`; nil when the run's end was not observed (gap, unknown
        /// label, or the evaluated interval ended first). Reaching the cap counts as observed.
        static func restAfter(_ start: Int, limit: Int, capped: Bool, evidence: BoutEvidence) -> Int? {
            var t = start
            var i = evidence.firstIndex(endingAfter: start)
            while i < evidence.spans.count {
                let s = evidence.spans[i]
                if s.interval.start > t { return nil }
                if evidence.isStationary(s) {
                    t = min(s.interval.end, limit)
                    if t >= limit { return capped ? t - start : nil }
                } else {
                    return evidence.isMovement(s) ? t - start : nil
                }
                i += 1
            }
            return nil
        }

        /// `interval` minus the sorted, merged `holes`.
        static func subtract(_ holes: [Interval], from interval: Interval) -> [Interval] {
            var out: [Interval] = []
            var cursor = interval.start
            for h in holes where h.end > cursor && h.start < interval.end {
                if h.start > cursor { out.append(Interval(cursor, h.start)) }
                cursor = max(cursor, h.end)
            }
            if cursor < interval.end { out.append(Interval(cursor, interval.end)) }
            return out
        }

        static func countIn(_ sorted: [Int], _ w: Interval) -> Int {
            guard w.isValid else { return 0 }
            return lowerBound(sorted, w.end) - lowerBound(sorted, w.start)
        }

        static func lowerBound(_ a: [Int], _ x: Int) -> Int {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if a[mid] < x { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }

        /// Index of the first element greater than `x`.
        static func upperBound(_ a: [Int], _ x: Int) -> Int {
            var lo = 0, hi = a.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if a[mid] <= x { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    // MARK: - Feature registry

    public enum FeatureValidationStatus: String, Codable, CaseIterable, Sendable {
        /// Arithmetic / integration verified only; no accuracy or clinical validation.
        case technicalVerificationOnly = "technical_verification_only"
        /// Defined but not computable without inputs or labels that do not exist yet.
        case notValidated = "not_validated"
    }

    /// A versioned feature definition. Specialized (disease-specific) definitions declare their requirements and
    /// stay unavailable until those inputs and independent labels exist; no coefficients are invented.
    public struct FeatureDefinition: Codable, Equatable, Sendable {
        public var id: String
        public var version: Int
        /// `general` | `specialized`.
        public var tier: String
        public var requiredSensors: [String]
        public var requiredPlacement: [String]
        public var requiredLabels: [String]
        public var referenceAssessments: [String]
        public var timing: String
        public var intendedPopulation: String
        public var units: String
        public var validationStatus: FeatureValidationStatus
        /// Method limitations that apply whenever the feature is read.
        public var limitations: [ReasonCode] = []
        public init(id: String, version: Int, tier: String, requiredSensors: [String], requiredPlacement: [String],
                    requiredLabels: [String], referenceAssessments: [String], timing: String,
                    intendedPopulation: String, units: String, validationStatus: FeatureValidationStatus) {
            self.id = id; self.version = version; self.tier = tier; self.requiredSensors = requiredSensors
            self.requiredPlacement = requiredPlacement; self.requiredLabels = requiredLabels
            self.referenceAssessments = referenceAssessments; self.timing = timing
            self.intendedPopulation = intendedPopulation; self.units = units
            self.validationStatus = validationStatus
        }

        enum CodingKeys: String, CodingKey {
            case id, version, tier, requiredSensors, requiredPlacement, requiredLabels, referenceAssessments,
                 timing, intendedPopulation, units, validationStatus, limitations
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            version = try c.decode(Int.self, forKey: .version)
            tier = try c.decode(String.self, forKey: .tier)
            requiredSensors = try c.decode([String].self, forKey: .requiredSensors)
            requiredPlacement = try c.decode([String].self, forKey: .requiredPlacement)
            requiredLabels = try c.decode([String].self, forKey: .requiredLabels)
            referenceAssessments = try c.decode([String].self, forKey: .referenceAssessments)
            timing = try c.decode(String.self, forKey: .timing)
            intendedPopulation = try c.decode(String.self, forKey: .intendedPopulation)
            units = try c.decode(String.self, forKey: .units)
            validationStatus = try c.decode(FeatureValidationStatus.self, forKey: .validationStatus)
            limitations = try c.decodeIfPresent([ReasonCode].self, forKey: .limitations) ?? []
        }

        func with(limitations: [ReasonCode]) -> FeatureDefinition {
            var d = self
            d.limitations = limitations
            return d
        }
    }

    public struct FeatureEvaluation: Codable, Equatable, Sendable {
        public var featureId: String
        public var version: Int
        /// `computed` | `unavailable`.
        public var state: String
        public var value: Double?
        public var units: String
        /// What is missing when unavailable (sensor, placement, label, reference assessment).
        public var missing: [ReasonCode]
        public var validationStatus: FeatureValidationStatus
        public init(featureId: String, version: Int, state: String, value: Double?, units: String,
                    missing: [ReasonCode], validationStatus: FeatureValidationStatus) {
            self.featureId = featureId; self.version = version; self.state = state; self.value = value
            self.units = units; self.missing = missing; self.validationStatus = validationStatus
        }
    }

    public enum FeatureRegistry {
        public static let version = "pc-features-1"

        public static let stateComputed = "computed"
        public static let stateUnavailable = "unavailable"
        public static let noValidatedDefinition: ReasonCode = "no_validated_definition"

        static let generalSensors = ["imu_motion_or_hart_epochs", "wear_evidence"]
        static let generalPopulation = "adult_wearers_within_person_description"

        static func general(_ id: String, units: String, sensors: [String] = generalSensors,
                            timing: String = "local_day_waking_time") -> FeatureDefinition {
            FeatureDefinition(id: id, version: 1, tier: "general", requiredSensors: sensors, requiredPlacement: [],
                              requiredLabels: [], referenceAssessments: [], timing: timing,
                              intendedPopulation: generalPopulation, units: units,
                              validationStatus: .technicalVerificationOnly)
                .with(limitations: [Functional.observedBehaviourNotDiagnosis])
        }

        static func specialized(_ id: String, sensors: [String], placement: [String], labels: [String],
                                assessments: [String], timing: String, population: String, units: String,
                                limitations: [ReasonCode] = []) -> FeatureDefinition {
            FeatureDefinition(id: id, version: 1, tier: "specialized", requiredSensors: sensors,
                              requiredPlacement: placement, requiredLabels: labels,
                              referenceAssessments: assessments, timing: timing, intendedPopulation: population,
                              units: units, validationStatus: .notValidated)
                .with(limitations: limitations)
        }

        /// General features are computed from the functional summary; specialized definitions are registered so
        /// their requirements are explicit, and evaluate to `unavailable` until those inputs and labels exist.
        public static let definitions: [FeatureDefinition] = [
            general(Functional.seriesLocomotionPerWornHour, units: "s_per_h"),
            general(Functional.seriesBoutsPerWornHour, units: "per_h"),
            general(Functional.seriesMedianBout, units: "s"),
            general("functional.bout_duration_p90_s", units: "s"),
            general(Functional.seriesPausesPerBoutHour, units: "per_h"),
            general(Functional.seriesCadenceMean, units: "counter_steps_per_min", sensors: ["step_counter"],
                    timing: "locomotion_minutes_in_bouts")
                .with(limitations: [ExertionBouts.wristCadenceNotGaitSpeed, ExertionBouts.uncalibratedStepCounter]),
            general(Functional.seriesCadenceCv, units: "ratio", sensors: ["step_counter"],
                    timing: "locomotion_minutes_in_bouts")
                .with(limitations: [ExertionBouts.wristCadenceNotGaitSpeed, ExertionBouts.uncalibratedStepCounter]),
            general(Functional.seriesActiveToRest, units: "per_min"),
            general(Functional.seriesRestAfterBout, units: "s"),
            general(Functional.seriesLocomotionTotal, units: "s"),
            general(Functional.seriesBoutCount, units: "count"),
            specialized("specialized.gait_speed", sensors: ["ankle_or_hip_imu", "gps"], placement: ["ankle_or_hip"],
                        labels: ["reference_gait_speed"], assessments: ["timed_10m_walk_test"],
                        timing: "per_walking_bout", population: "disease_population_to_be_defined",
                        units: "m_per_s", limitations: [ExertionBouts.wristCadenceNotGaitSpeed]),
            specialized("specialized.stride_length", sensors: ["ankle_or_hip_imu"], placement: ["ankle_or_hip"],
                        labels: ["reference_stride_length"], assessments: ["instrumented_walkway"],
                        timing: "per_walking_bout", population: "disease_population_to_be_defined", units: "m",
                        limitations: [ExertionBouts.wristCadenceNotGaitSpeed]),
            specialized("specialized.tremor_index", sensors: ["imu_raw_high_rate_continuous"], placement: ["wrist"],
                        labels: ["clinician_rated_tremor"], assessments: ["mds_updrs_part_iii_tremor_items"],
                        timing: "rest_and_postural_windows", population: "disease_population_to_be_defined",
                        units: "unitless"),
            specialized("specialized.respiratory_event_index", sensors: ["ppg_waveform", "spo2_validated"],
                        placement: ["wrist"], labels: ["polysomnography_scored_respiratory_events"],
                        assessments: ["polysomnography"], timing: "per_sleep_episode",
                        population: "disease_population_to_be_defined", units: "events_per_h"),
            specialized("specialized.autonomic_index", sensors: ["ppg_waveform_or_ecg", "blood_pressure"],
                        placement: [], labels: ["autonomic_reflex_test_results"],
                        assessments: ["autonomic_reflex_screen", "head_up_tilt_test"],
                        timing: "standardized_protocol_windows", population: "disease_population_to_be_defined",
                        units: "unitless"),
            specialized("specialized.symptom_classifier", sensors: ["imu_raw_high_rate_continuous", "ppg_waveform"],
                        placement: ["wrist"], labels: ["clinician_confirmed_symptom_episodes"],
                        assessments: ["clinician_confirmed_symptom_diary"], timing: "event_aligned",
                        population: "disease_population_to_be_defined", units: "class_label",
                        limitations: ["user_reported_symptom_is_observed_report_not_diagnosis"]),
        ]

        /// Evaluate every registered definition against what the day actually has.
        public static func evaluate(functional: FunctionalDaySummary, regimes: RegimeTimeline,
                                    availability: [AvailabilityEntry]) -> [FeatureEvaluation] {
            definitions.map { d in
                if d.tier == "general" {
                    let (value, missing) = generalValue(d.id, functional)
                    if let v = value, v.isFinite {
                        return FeatureEvaluation(featureId: d.id, version: d.version, state: stateComputed, value: v,
                                                 units: d.units, missing: [], validationStatus: d.validationStatus)
                    }
                    return FeatureEvaluation(featureId: d.id, version: d.version, state: stateUnavailable, value: nil,
                                             units: d.units, missing: missing.isEmpty ? ["value_unavailable"] : missing,
                                             validationStatus: d.validationStatus)
                }
                var missing: [ReasonCode] = []
                for s in d.requiredSensors where !sensorAvailable(s, availability) {
                    missing.append(ReasonCode("missing_sensor:\(s)"))
                }
                let placements = Set(regimes.placements.map(\.placement))
                for p in d.requiredPlacement where !placements.contains(p) {
                    missing.append(ReasonCode("missing_placement:\(p)"))
                }
                // No label or reference-assessment input exists in this layer, so these are always missing.
                for l in d.requiredLabels { missing.append(ReasonCode("missing_label:\(l)")) }
                for a in d.referenceAssessments { missing.append(ReasonCode("missing_reference_assessment:\(a)")) }
                missing.append(noValidatedDefinition)
                return FeatureEvaluation(featureId: d.id, version: d.version, state: stateUnavailable, value: nil,
                                         units: d.units, missing: missing, validationStatus: d.validationStatus)
            }
        }

        /// Only sensors the availability matrix can report as supported can ever be present; nothing in the
        /// contract carries GPS, a non-wrist IMU, ECG, blood pressure or a continuous high-rate raw IMU stream.
        static func sensorAvailable(_ sensor: String, _ availability: [AvailabilityEntry]) -> Bool {
            switch sensor {
            case "ppg_waveform":
                return availability.contains { $0.assessment == "ppg_waveform_quality" && $0.state == .supported }
            case "spo2_validated":
                return availability.contains { $0.metric == .spo2Candidate && $0.state == .supported }
            default:
                return false
            }
        }

        static func generalValue(_ id: String, _ f: FunctionalDaySummary) -> (Double?, [ReasonCode]) {
            var missing: [ReasonCode] = []
            if f.observedWearS == nil { missing.append(Functional.wearEvidenceUnavailable) }
            let rateMissing: [ReasonCode] = f.ratesSupported ? [] : [Functional.insufficientWornTimeForRates]
            let totalBlockers: Set<ReasonCode> = [Functional.insufficientWearCoverage, Functional.dayIncompleteAtCutoff,
                                                  Functional.noWakingTime, Functional.wearEvidenceUnavailable]
            let blockers = f.reasons.filter { totalBlockers.contains($0) }
            let totalMissing: [ReasonCode] = f.totalsComparable ? []
                : (blockers.isEmpty ? [Functional.insufficientWearCoverage] : blockers)
            let noBouts: [ReasonCode] = f.boutCount == 0 ? [Functional.noBouts] : []
            func rate(_ v: Double?, extra: [ReasonCode] = []) -> (Double?, [ReasonCode]) {
                f.ratesSupported ? (v, missing + extra) : (nil, missing + rateMissing)
            }
            switch id {
            case Functional.seriesLocomotionPerWornHour: return rate(f.locomotionSecondsPerWornHour)
            case Functional.seriesBoutsPerWornHour: return rate(f.boutsPerWornHour)
            case Functional.seriesMedianBout: return rate(f.boutDurationMedianS, extra: noBouts)
            case "functional.bout_duration_p90_s": return rate(f.boutDurationP90, extra: noBouts)
            case Functional.seriesPausesPerBoutHour: return rate(f.pausesPerBoutHour, extra: noBouts)
            case Functional.seriesCadenceMean:
                return rate(f.cadenceMeanStepsPerMin, extra: noBouts + [ExertionBouts.cadenceUnavailable])
            case Functional.seriesCadenceCv:
                return rate(f.cadenceWithinBoutCvMedian, extra: noBouts + [ExertionBouts.cadenceUnavailable])
            case Functional.seriesActiveToRest:
                return rate(f.activeToRestPerActiveMin, extra: [Functional.transitionDenominatorTooSmall])
            case Functional.seriesRestAfterBout:
                return rate(f.restAfterBoutMedianS, extra: noBouts + [Functional.restAfterBoutRightCensored])
            case Functional.seriesLocomotionTotal:
                return f.totalsComparable ? (f.locomotionS.map(Double.init), missing)
                    : (nil, Array(Set(missing + totalMissing)).sorted())
            case Functional.seriesBoutCount:
                return f.totalsComparable ? (Double(f.boutCount), missing)
                    : (nil, Array(Set(missing + totalMissing)).sorted())
            default:
                return (nil, ["unknown_feature"])
            }
        }
    }
}

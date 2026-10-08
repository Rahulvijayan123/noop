import Foundation

// PCPulseEpisodes.swift — sustained high / low pulse episodes over QUALIFIED INACTIVE heart rate, and
// heart-rate accelerations that coincide with movement, on one descriptive timeline (docs/spec-02/CONTRACT.md §6).
//
// OWNER: cardiac/PRV workstream (spec-02). Contract types are lead-owned; the detector body is the owner's.
//
// Descriptive only. A sustained high or low pulse is not a diagnosis, and none of this is a rhythm classification
// (AF/PAC/PVC stay with the rhythm models). An acceleration with movement carries no cause: it is not attributed to
// respiration, arousal or any disease. Qualification is heart-rate independent: the HR-independent motion evidence
// (HART epochs where confident, strap motion elsewhere — the same merged evidence bout detection uses) decides
// "inactive", never a decoder label that reads HR.
//
// Definitions (pc-pulse-1; notes: docs/spec-02/notes/pc-cardiac.md):
//   * A second is QUALIFIED when it has exactly one HR value inside [hrPlausibleMinBpm, hrPlausibleMaxBpm] (two
//     different values in one second disqualify it), the sample is not part of a constant-value run of at least
//     `flatlineMaxS` (the signal-validity stuck-signal bar), the motion evidence at that second is stationary and
//     has been continuously stationary for at least `settleStillS` (the stable-awake settle rule), and it is not
//     inside an exertion bout or within `postBoutExclusionS` after one.
//   * Qualified samples form SEGMENTS: consecutive qualified samples at most `maxGapS` apart with no break between
//     them. Nothing is ever bridged across a longer gap, a break or an unqualified sample.
//   * Inside one segment a hysteresis state machine finds episodes: a high episode starts at the first sample at or
//     above `highEnterBpm` and ends at the first sample of a run below `highExitBpm` that lasts `exitHoldS`; a dip
//     shorter than the hold does not end it. Low episodes mirror this (`<= lowEnterBpm`, `> lowExitBpm`). An episode
//     needs `minDurationS` qualified seconds. An episode that reaches its segment's edge is CENSORED with why the
//     segment began or ended (`episode_censored_gap`, `episode_censored_qualification`, `episode_censored_window`,
//     `cutoff_reached`); its start / end are then observation limits, not physiology.
//   * Episodes belong to the local day containing their start. The machine runs over the day plus `lookbackS` and
//     (retrospectively) `lookaheadS`; a live document stops at its cutoff. So an episode that began before midnight is
//     the previous day's, and one that runs past midnight keeps its true length.
//   * An ACCELERATION WITH MOVEMENT: at an HR-independent movement onset `m` (movement evidence directly after
//     stationary evidence), the baseline is the median of the qualified HR in `[m - W - baselineS, m - W)` (needs
//     `accelerationBaselineMinS` samples); the first sample in `[m - W, m + W + riseWithinS]` at or above
//     baseline + `accelerationRiseBpm` is the crossing `p`; the rise onset `r` is the last sample at or below the
//     baseline before `p`, with `r` in `[m - W, m + W]` and `p - r <= riseWithinS`; HR must be continuous (no gap
//     over `maxGapS`, no break) from the baseline to `p`. Peak = highest HR in `[r, r + riseWithinS]`.
//   * Fixed, configurable bpm thresholds: the context layer has no stable second-level personal HR reference to
//     anchor them to (its references compare daily values), so the thresholds are descriptive and reported in
//     `thresholds`. They are not clinical cut-offs.
extension PhysiologyContext {

    /// Thresholds of the pulse-episode detector. Every field changes the output, and every field enters
    /// `Policy.fingerprint` (the whole struct is encoded into it).
    public struct PulseEpisodeConfig: Codable, Equatable, Sendable {
        public var version = "pc-pulse-1"
        /// A high episode enters at or above this HR and exits below `highExitBpm` (hysteresis).
        public var highEnterBpm = 100.0
        public var highExitBpm = 95.0
        /// A low episode enters at or below this HR and exits above `lowExitBpm`.
        public var lowEnterBpm = 40.0
        public var lowExitBpm = 43.0
        /// Shortest episode reported (qualified seconds inside the episode).
        public var minDurationS = 600
        /// The exit condition must hold this long before an episode ends.
        public var exitHoldS = 60
        /// A longer gap between HR samples ends (censors) an episode; it is never bridged
        /// (`ExertionConfig.hrGapMaxS`).
        public var maxGapS = 10
        /// Acceleration: rise of at least this much over the preceding still baseline …
        public var accelerationRiseBpm = 10.0
        /// … whose baseline is the median HR of the qualified still seconds in a window this long …
        public var accelerationBaselineS = 60
        /// … reached within this many seconds of the rise onset …
        public var accelerationRiseWithinS = 15
        /// … with an HR-independent movement onset within this many seconds of the rise onset.
        public var accelerationMovementWindowS = 15
        /// Rates per hour need at least this much qualified exposure in the context.
        public var minQualifiedExposureS = 3600
        /// Plausible single-sample band (`ValidityConfig.hrPlausibleMinBpm/MaxBpm`).
        public var hrPlausibleMinBpm = 30
        public var hrPlausibleMaxBpm = 220
        /// Equal consecutive samples at most this far apart continue a constant run
        /// (`ValidityConfig.hrFlatlineMaxStepS`).
        public var flatlineMaxStepS = 2
        /// A constant run at least this long is a stuck signal and is not qualified
        /// (`ValidityConfig.hrFlatlineInvalidS`).
        public var flatlineMaxS = 900
        /// Continuous stationary evidence needed before a second is "inactive"
        /// (`EligibilityConfig.minPrecedingStillS`).
        public var settleStillS = 300
        /// Seconds after a supported exertion bout that are never inactive (`EligibilityConfig.postBoutExclusionS`).
        public var postBoutExclusionS = 600
        /// Evidence spans abstaining at or above this share are not stationary (`ExertionConfig.maxUnknownFraction`).
        public var maxUnknownFraction = 0.5
        /// Qualified baseline samples an acceleration needs.
        public var accelerationBaselineMinS = 45
        /// The state machine also reads this far before the day (ownership) and, retrospectively, after it.
        public var lookbackS = 6 * 3600
        public var lookaheadS = 6 * 3600
        public init() {}

        /// Every numeric parameter, reported in the summary's `thresholds`.
        var diagnostics: [Diagnostic] {
            [Diagnostic("high_enter_bpm", highEnterBpm), Diagnostic("high_exit_bpm", highExitBpm),
             Diagnostic("low_enter_bpm", lowEnterBpm), Diagnostic("low_exit_bpm", lowExitBpm),
             Diagnostic("min_duration_s", Double(minDurationS)), Diagnostic("exit_hold_s", Double(exitHoldS)),
             Diagnostic("max_gap_s", Double(maxGapS)),
             Diagnostic("acceleration_rise_bpm", accelerationRiseBpm),
             Diagnostic("acceleration_baseline_s", Double(accelerationBaselineS)),
             Diagnostic("acceleration_baseline_min_s", Double(accelerationBaselineMinS)),
             Diagnostic("acceleration_rise_within_s", Double(accelerationRiseWithinS)),
             Diagnostic("acceleration_movement_window_s", Double(accelerationMovementWindowS)),
             Diagnostic("min_qualified_exposure_s", Double(minQualifiedExposureS)),
             Diagnostic("hr_plausible_min_bpm", Double(hrPlausibleMinBpm)),
             Diagnostic("hr_plausible_max_bpm", Double(hrPlausibleMaxBpm)),
             Diagnostic("flatline_max_step_s", Double(flatlineMaxStepS)),
             Diagnostic("flatline_max_s", Double(flatlineMaxS)),
             Diagnostic("settle_still_s", Double(settleStillS)),
             Diagnostic("post_bout_exclusion_s", Double(postBoutExclusionS)),
             Diagnostic("max_unknown_fraction", maxUnknownFraction),
             Diagnostic("lookback_s", Double(lookbackS)), Diagnostic("lookahead_s", Double(lookaheadS))]
        }
    }

    /// One sustained high or low pulse episode.
    public struct PulseEpisode: Codable, Equatable, Sendable {
        /// Deterministic from (kind, start).
        public var id: String
        /// `sustained_high` | `sustained_low`.
        public var kind: String
        public var interval: Interval
        public var durationS: Int
        public var medianBpm: Double?
        /// Highest HR of a high episode, lowest of a low one.
        public var extremeBpm: Double?
        /// Qualified inactive seconds with HR inside the episode.
        public var qualifiedS: Int
        /// `asleep` | `awake` | `mixed` | `unknown` (sleep evidence is HR-dependent; see `reasons`).
        public var context: String
        /// Why the start or end is not a complete observation (`episode_censored_gap`,
        /// `episode_censored_qualification`, `episode_censored_window`, `cutoff_reached`).
        public var censoring: [ReasonCode]
        public var reasons: [ReasonCode]
        /// `qualifiedS / durationS` (sample support of the episode); nil in older documents.
        public var coverage: Double? = nil
        /// Motion evidence the qualification relied on: `hart_epochs`, `strap_motion` or `mixed`.
        public var evidenceSource: String? = nil
        public init(id: String, kind: String, interval: Interval, durationS: Int, medianBpm: Double?,
                    extremeBpm: Double?, qualifiedS: Int, context: String, censoring: [ReasonCode],
                    reasons: [ReasonCode], coverage: Double? = nil, evidenceSource: String? = nil) {
            self.id = id; self.kind = kind; self.interval = interval; self.durationS = durationS
            self.medianBpm = medianBpm; self.extremeBpm = extremeBpm; self.qualifiedS = qualifiedS
            self.context = context; self.censoring = censoring; self.reasons = reasons
            self.coverage = coverage; self.evidenceSource = evidenceSource
        }
    }

    /// A heart-rate acceleration from a still baseline that coincides with HR-independent movement.
    public struct HeartRateAccelerationEvent: Codable, Equatable, Sendable {
        /// Rise onset (unix seconds).
        public var ts: Int
        public var baselineBpm: Double
        public var peakBpm: Double
        public var riseBpm: Double
        /// Seconds from the rise onset to the peak.
        public var riseS: Int
        /// Movement onset relative to the rise onset (signed seconds).
        public var movementOffsetS: Int
        /// `asleep` | `awake` | `unknown`.
        public var context: String
        /// Qualified samples behind the baseline median; nil in older documents.
        public var baselineSamples: Int? = nil
        public init(ts: Int, baselineBpm: Double, peakBpm: Double, riseBpm: Double, riseS: Int,
                    movementOffsetS: Int, context: String, baselineSamples: Int? = nil) {
            self.ts = ts; self.baselineBpm = baselineBpm; self.peakBpm = peakBpm; self.riseBpm = riseBpm
            self.riseS = riseS; self.movementOffsetS = movementOffsetS; self.context = context
            self.baselineSamples = baselineSamples
        }
    }

    /// The day's pulse-episode timeline with its exposure. Counts are only meaningful with exposure:
    /// `nil` counts mean "not evaluated", `0` means "evaluated, none found".
    public struct PulseEpisodeSummary: Codable, Equatable, Sendable {
        public var version: String
        public var state: AvailabilityState
        /// The thresholds the run used (`high_enter_bpm`, `min_duration_s`, …).
        public var thresholds: [Diagnostic]
        /// Qualified inactive seconds with HR (the exposure every count divides by), split by context.
        public var qualifiedInactiveS: Int
        public var qualifiedAsleepS: Int
        public var qualifiedAwakeS: Int
        public var episodes: [PulseEpisode]
        public var highEpisodeCount: Int?
        public var lowEpisodeCount: Int?
        public var highEpisodeS: Int?
        public var lowEpisodeS: Int?
        public var accelerationEvents: [HeartRateAccelerationEvent]
        public var accelerationEventsPerAsleepHour: Double?
        public var accelerationEventsPerAwakeHour: Double?
        /// Always carries `not_rhythm_classification` and `cause_not_attributed`.
        public var reasons: [ReasonCode]
        /// `bpm` (episode and event values). nil in older documents.
        public var units: String? = nil
        /// The day's observation window the exposure counts: `[day start, day end)`, up to the cutoff when live.
        public var window: Interval? = nil
        /// What the state machine read: the window plus `lookback_s` before and (retrospectively) `lookahead_s`
        /// after, so episodes crossing midnight keep their true extent.
        public var evaluatedSpan: Interval? = nil
        /// Qualified seconds of the window per motion-evidence source (`qualified_s.hart_epochs`,
        /// `qualified_s.strap_motion`).
        public var evidenceSeconds: [Diagnostic]? = nil
        public init(version: String, state: AvailabilityState, thresholds: [Diagnostic], qualifiedInactiveS: Int,
                    qualifiedAsleepS: Int, qualifiedAwakeS: Int, episodes: [PulseEpisode],
                    highEpisodeCount: Int?, lowEpisodeCount: Int?, highEpisodeS: Int?, lowEpisodeS: Int?,
                    accelerationEvents: [HeartRateAccelerationEvent], accelerationEventsPerAsleepHour: Double?,
                    accelerationEventsPerAwakeHour: Double?, reasons: [ReasonCode], units: String? = nil,
                    window: Interval? = nil, evaluatedSpan: Interval? = nil, evidenceSeconds: [Diagnostic]? = nil) {
            self.version = version; self.state = state; self.thresholds = thresholds
            self.qualifiedInactiveS = qualifiedInactiveS; self.qualifiedAsleepS = qualifiedAsleepS
            self.qualifiedAwakeS = qualifiedAwakeS; self.episodes = episodes
            self.highEpisodeCount = highEpisodeCount; self.lowEpisodeCount = lowEpisodeCount
            self.highEpisodeS = highEpisodeS; self.lowEpisodeS = lowEpisodeS
            self.accelerationEvents = accelerationEvents
            self.accelerationEventsPerAsleepHour = accelerationEventsPerAsleepHour
            self.accelerationEventsPerAwakeHour = accelerationEventsPerAwakeHour
            self.reasons = reasons; self.units = units; self.window = window; self.evaluatedSpan = evaluatedSpan
            self.evidenceSeconds = evidenceSeconds
        }
    }

    public enum PulseEpisodes {
        public static let version = "pc-pulse-1"

        public static let kindHigh = "sustained_high"
        public static let kindLow = "sustained_low"

        // Reason codes (docs/spec-02/CONTRACT.md §6). The app maps every one (PhysiologyContextWordingCoverageTests).
        public static let pulseEpisodeHigh: ReasonCode = "pulse_episode_high"
        public static let pulseEpisodeLow: ReasonCode = "pulse_episode_low"
        public static let hrAccelerationWithMovement: ReasonCode = "hr_acceleration_with_movement"
        public static let episodeCensoredGap: ReasonCode = "episode_censored_gap"
        public static let episodeCensoredQualification: ReasonCode = "episode_censored_qualification"
        public static let qualifiedInactiveHrInsufficient: ReasonCode = "qualified_inactive_hr_insufficient"
        public static let causeNotAttributed: ReasonCode = "cause_not_attributed"
        public static let notRhythmClassification: ReasonCode = "not_rhythm_classification"
        /// The episode reaches the edge of what the detector read (the lookback / retrospective lookahead limit).
        public static let episodeCensoredWindow: ReasonCode = "episode_censored_window"

        public static let reasonCodes: [ReasonCode] = [
            pulseEpisodeHigh, pulseEpisodeLow, hrAccelerationWithMovement, episodeCensoredGap,
            episodeCensoredQualification, qualifiedInactiveHrInsufficient, causeNotAttributed,
            notRhythmClassification, episodeCensoredWindow,
        ]
        // Also emitted, declared (and worded) by their owners: `cutoff_reached` (ExertionBouts),
        // `labels_read_heart_rate` (SleepRhythm), `activity_evidence_unavailable` (Engine).

        /// The day's pulse-episode summary over qualified inactive HR. Never nil once evaluated: a day without
        /// qualified inactive HR is `unavailable` with `qualified_inactive_hr_insufficient`.
        static func summarize(identity: DayIdentity, observations: SanitizedObservations, hart: ResolvedTrack,
                              strap: ResolvedTrack, episodes: [SleepEpisode], bouts: [ExertionBout],
                              mode: ProcessingMode, cutoff: Int, config: PulseEpisodeConfig) -> PulseEpisodeSummary? {
            let causal = mode == .causalLive
            let day = identity.dayWindow
            let dayEnd = causal ? min(day.end, cutoff) : day.end
            let spanStart = day.start - max(0, config.lookbackS)
            let lookaheadEnd = day.end + max(0, config.lookaheadS)
            let spanEnd = causal ? min(lookaheadEnd, cutoff) : lookaheadEnd
            let alwaysReasons: [ReasonCode] = [notRhythmClassification, causeNotAttributed,
                                               SleepRhythm.labelsReadHeartRate]
            func unavailable(_ extra: [ReasonCode], window: Interval?) -> PulseEpisodeSummary {
                PulseEpisodeSummary(version: config.version, state: .unavailable, thresholds: config.diagnostics,
                                    qualifiedInactiveS: 0, qualifiedAsleepS: 0, qualifiedAwakeS: 0, episodes: [],
                                    highEpisodeCount: nil, lowEpisodeCount: nil, highEpisodeS: nil, lowEpisodeS: nil,
                                    accelerationEvents: [], accelerationEventsPerAsleepHour: nil,
                                    accelerationEventsPerAwakeHour: nil,
                                    reasons: Array(Set(alwaysReasons + extra)).sorted(), units: "bpm",
                                    window: window, evaluatedSpan: nil, evidenceSeconds: nil)
            }
            guard dayEnd > day.start, spanEnd > spanStart else {
                return unavailable([qualifiedInactiveHrInsufficient], window: nil)
            }
            let window = Interval(day.start, dayEnd)
            let timeline = Timeline(observations: observations, hart: hart, strap: strap, episodes: episodes,
                                    bouts: bouts, span: Interval(spanStart, spanEnd),
                                    endsAtCutoff: causal && spanEnd == cutoff, config: config)
            var extra: [ReasonCode] = []
            if hart.spans.isEmpty && strap.spans.isEmpty { extra.append(Engine.activityUnavailable) }

            // Exposure inside the day's window.
            var qualifiedS = 0, asleepS = 0, awakeS = 0, hartS = 0, strapS = 0
            for t in window.start..<window.end {
                let i = t - timeline.origin
                guard timeline.qualified[i] else { continue }
                qualifiedS += 1
                switch timeline.context(i) {
                case "asleep": asleepS += 1
                case "awake": awakeS += 1
                default: break
                }
                if timeline.source[i] == 1 { hartS += 1 } else if timeline.source[i] == 2 { strapS += 1 }
            }
            guard qualifiedS > 0 else {
                return unavailable(extra + [qualifiedInactiveHrInsufficient], window: window)
            }

            var found: [PulseEpisode] = []
            for segment in timeline.segments() {
                found += timeline.episodes(in: segment, high: true, owner: window)
                found += timeline.episodes(in: segment, high: false, owner: window)
            }
            found.sort { ($0.interval, $0.kind) < ($1.interval, $1.kind) }
            let events = timeline.accelerations(owner: window)

            let highs = found.filter { $0.kind == kindHigh }, lows = found.filter { $0.kind == kindLow }
            if !highs.isEmpty { extra.append(pulseEpisodeHigh) }
            if !lows.isEmpty { extra.append(pulseEpisodeLow) }
            if !events.isEmpty { extra.append(hrAccelerationWithMovement) }
            let enough = qualifiedS >= config.minQualifiedExposureS
            if !enough { extra.append(qualifiedInactiveHrInsufficient) }
            func rate(_ count: Int, _ exposure: Int) -> Double? {
                exposure >= config.minQualifiedExposureS && exposure > 0
                    ? Double(count) / (Double(exposure) / 3600) : nil
            }
            return PulseEpisodeSummary(
                version: config.version, state: enough ? .supported : .partial, thresholds: config.diagnostics,
                qualifiedInactiveS: qualifiedS, qualifiedAsleepS: asleepS, qualifiedAwakeS: awakeS, episodes: found,
                highEpisodeCount: highs.count, lowEpisodeCount: lows.count,
                highEpisodeS: highs.reduce(0) { $0 + $1.durationS }, lowEpisodeS: lows.reduce(0) { $0 + $1.durationS },
                accelerationEvents: events,
                accelerationEventsPerAsleepHour: rate(events.filter { $0.context == "asleep" }.count, asleepS),
                accelerationEventsPerAwakeHour: rate(events.filter { $0.context == "awake" }.count, awakeS),
                reasons: Array(Set(alwaysReasons + extra)).sorted(), units: "bpm", window: window,
                evaluatedSpan: Interval(spanStart, spanEnd),
                evidenceSeconds: [Diagnostic("qualified_s.hart_epochs", Double(hartS)),
                                  Diagnostic("qualified_s.strap_motion", Double(strapS))])
        }

        /// Per-second view of the evaluated span. Index `i` is the second `origin + i`; the arrays start
        /// `settleStillS` before the span so a stillness run can settle by the time the span starts.
        struct Timeline {
            let origin: Int
            let span: Interval
            /// The span ends at a live document's cutoff (an episode reaching it is `cutoff_reached`).
            let endsAtCutoff: Bool
            let config: PulseEpisodeConfig
            let observations: SanitizedObservations
            /// HR per second: -1 no sample, -2 conflicting samples, else bpm.
            let hr: [Int]
            /// Motion evidence: 0 uncovered / unknown, 1 stationary, 2 movement.
            let motion: [UInt8]
            /// Evidence source: 0 none, 1 HART epochs, 2 strap motion.
            let source: [UInt8]
            let qualified: [Bool]
            let asleep: [Bool]
            let hasSleepEvidence: Bool
            /// Second indices inside the span with any HR sample (qualified or not), ascending.
            let observed: [Int]

            init(observations: SanitizedObservations, hart: ResolvedTrack, strap: ResolvedTrack,
                 episodes: [SleepEpisode], bouts: [ExertionBout], span: Interval, endsAtCutoff: Bool,
                 config: PulseEpisodeConfig) {
                self.config = config
                self.span = span
                self.observations = observations
                self.endsAtCutoff = endsAtCutoff
                let origin = span.start - max(0, config.settleStillS) - 1
                self.origin = origin
                let n = span.end - origin
                var hr = [Int](repeating: -1, count: n)
                for s in observations.heartRate where span.contains(s.ts) {
                    let i = s.ts - origin
                    if hr[i] == -1 { hr[i] = s.bpm } else if hr[i] != s.bpm { hr[i] = -2 }
                }
                // Evidence: HART where confident, strap elsewhere (the bout detector's merge).
                var motion = [UInt8](repeating: 0, count: n)
                var source = [UInt8](repeating: 0, count: n)
                let evidence = BoutEvidence(hart: hart, strap: strap, maxUnknown: config.maxUnknownFraction)
                for e in evidence.overlapping(Interval(origin, span.end)) {
                    let status: UInt8 = evidence.isStationary(e) ? 1 : (evidence.isMovement(e) ? 2 : 0)
                    let src: UInt8 = e.source == .hartEpochs ? 1 : 2
                    let lo = max(origin, e.interval.start), hi = min(span.end, e.interval.end)
                    guard hi > lo else { continue }
                    for t in lo..<hi { motion[t - origin] = status; source[t - origin] = src }
                }
                // Settled stillness: continuously stationary for at least `settleStillS` before the second.
                var settled = [Bool](repeating: false, count: n)
                var runStart = 0
                for i in 0..<n where motion[i] == 1 {
                    if i == 0 || motion[i - 1] != 1 { runStart = i }
                    settled[i] = i - runStart >= config.settleStillS
                }
                // Bouts and their follow-up exclusion.
                var excluded = [Bool](repeating: false, count: n)
                for b in bouts {
                    let lo = max(origin, b.interval.start)
                    let hi = min(span.end, b.interval.end + max(0, config.postBoutExclusionS))
                    if hi > lo { for t in lo..<hi { excluded[t - origin] = true } }
                }
                var observed: [Int] = []
                for i in 0..<n where hr[i] != -1 { observed.append(i) }
                // Stuck signal: constant runs (steps of at most `flatlineMaxStepS`) lasting `flatlineMaxS` or more.
                var stuck = [Bool](repeating: false, count: n)
                var k = 0
                while k < observed.count {
                    var j = k
                    let v = hr[observed[k]]
                    while v >= 0, j + 1 < observed.count, hr[observed[j + 1]] == v,
                          observed[j + 1] - observed[j] <= config.flatlineMaxStepS {
                        j += 1
                    }
                    if v >= 0, observed[j] - observed[k] >= config.flatlineMaxS {
                        for m in k...j { stuck[observed[m]] = true }
                    }
                    k = j + 1
                }
                let band = config.hrPlausibleMinBpm...config.hrPlausibleMaxBpm
                var qualified = [Bool](repeating: false, count: n)
                for i in observed where hr[i] >= 0 && band.contains(hr[i]) && !stuck[i] && settled[i] && !excluded[i] {
                    qualified[i] = true
                }
                var asleep = [Bool](repeating: false, count: n)
                for e in episodes {
                    let lo = max(origin, e.interval.start), hi = min(span.end, e.interval.end)
                    if hi > lo { for t in lo..<hi { asleep[t - origin] = true } }
                }
                self.hr = hr; self.motion = motion; self.source = source; self.qualified = qualified
                self.asleep = asleep; self.hasSleepEvidence = !episodes.isEmpty; self.observed = observed
            }

            /// `asleep` inside a detected sleep episode, `awake` outside one, `unknown` without any episode.
            func context(_ i: Int) -> String {
                guard hasSleepEvidence else { return "unknown" }
                return asleep[i] ? "asleep" : "awake"
            }

            /// True when samples at second indices `a < b` are adjacent: at most `maxGapS` apart, no break between.
            func adjacent(_ a: Int, _ b: Int) -> Bool {
                b - a <= config.maxGapS && !observations.breakSeparates(origin + a, origin + b)
            }

            /// A run of consecutive qualified samples, with why it began and ended.
            struct Segment {
                var samples: [Int]
                var startReason: ReasonCode
                var endReason: ReasonCode
            }

            /// Why a segment's edge is an observation limit. `neighbour` is the nearest observed sample beyond the
            /// edge (nil when there is none inside the span): adjacent and unqualified → qualification loss,
            /// otherwise a gap. With no neighbour, an edge within `maxGapS` of the span boundary is the boundary
            /// (the cutoff for a live document's end, else the read window), anything farther a gap.
            func edgeReason(at i: Int, neighbour: Int?, spanEdge: Int, isEnd: Bool) -> ReasonCode {
                if let q = neighbour {
                    let (a, b) = isEnd ? (i, q) : (q, i)
                    return adjacent(a, b) ? episodeCensoredQualification : episodeCensoredGap
                }
                let distance = isEnd ? spanEdge - 1 - i : i - spanEdge
                guard distance <= config.maxGapS else { return episodeCensoredGap }
                return isEnd && endsAtCutoff ? ExertionBouts.censorCutoffReached : episodeCensoredWindow
            }

            func segments() -> [Segment] {
                var out: [Segment] = []
                var current: [Int] = []
                var startReason: ReasonCode = episodeCensoredWindow
                let first = span.start - origin, last = span.end - origin
                for (k, i) in observed.enumerated() {
                    if qualified[i], let p = current.last, adjacent(p, i) {
                        current.append(i)
                        continue
                    }
                    if let p = current.last {
                        out.append(Segment(samples: current, startReason: startReason,
                                           endReason: edgeReason(at: p, neighbour: i, spanEdge: last, isEnd: true)))
                        current = []
                    }
                    if qualified[i] {
                        current = [i]
                        startReason = edgeReason(at: i, neighbour: k > 0 ? observed[k - 1] : nil, spanEdge: first,
                                                 isEnd: false)
                    }
                }
                if let p = current.last {
                    out.append(Segment(samples: current, startReason: startReason,
                                       endReason: edgeReason(at: p, neighbour: nil, spanEdge: last, isEnd: true)))
                }
                return out
            }

            /// Hysteresis state machine over one segment.
            func episodes(in segment: Segment, high: Bool, owner: Interval) -> [PulseEpisode] {
                let s = segment.samples
                let enter = high ? config.highEnterBpm : config.lowEnterBpm
                let exit = high ? config.highExitBpm : config.lowExitBpm
                func enters(_ v: Int) -> Bool { high ? Double(v) >= enter : Double(v) <= enter }
                func exits(_ v: Int) -> Bool { high ? Double(v) < exit : Double(v) > exit }
                var out: [PulseEpisode] = []
                var startJ: Int? = nil
                var exitJ: Int? = nil
                for j in s.indices {
                    let v = hr[s[j]]
                    guard let st = startJ else {
                        if enters(v) { startJ = j; exitJ = nil }
                        continue
                    }
                    if exits(v) {
                        if exitJ == nil { exitJ = j }
                        if let e = exitJ, s[j] - s[e] >= config.exitHoldS {
                            if let ep = make(s, from: st, to: e, endIndex: s[e], high: high,
                                             startCensor: st == 0 ? segment.startReason : nil, endCensor: nil,
                                             owner: owner) {
                                out.append(ep)
                            }
                            startJ = nil; exitJ = nil
                        }
                    } else {
                        exitJ = nil
                    }
                }
                if let st = startJ {
                    // The segment ended inside the episode (or inside an unfinished exit hold): censored.
                    let to = exitJ ?? s.count
                    let endIndex = exitJ.map { s[$0] } ?? (s[s.count - 1] + 1)
                    if let ep = make(s, from: st, to: to, endIndex: endIndex, high: high,
                                     startCensor: st == 0 ? segment.startReason : nil,
                                     endCensor: segment.endReason, owner: owner) {
                        out.append(ep)
                    }
                }
                return out
            }

            func make(_ s: [Int], from: Int, to: Int, endIndex: Int, high: Bool, startCensor: ReasonCode?,
                      endCensor: ReasonCode?, owner: Interval) -> PulseEpisode? {
                guard to > from else { return nil }
                let members = Array(s[from..<to])
                guard members.count >= config.minDurationS else { return nil }
                let start = origin + s[from], end = origin + endIndex
                guard owner.contains(start) else { return nil }
                let values = members.map { Double(hr[$0]) }
                var contexts = Set<String>()
                var hartN = 0, strapN = 0
                for i in members {
                    contexts.insert(context(i))
                    if source[i] == 1 { hartN += 1 } else if source[i] == 2 { strapN += 1 }
                }
                let ctx = contexts.count == 1 ? contexts.first! : (contexts.contains("unknown") ? "unknown" : "mixed")
                let kind = high ? kindHigh : kindLow
                let evidence = hartN > 0 && strapN > 0 ? "mixed" : (hartN > 0 ? "hart_epochs" : "strap_motion")
                let duration = end - start
                return PulseEpisode(
                    id: "pulse_" + PhysiologyContext.fnv1a("\(kind)|\(start)"), kind: kind,
                    interval: Interval(start, end), durationS: duration, medianBpm: RobustStats.median(values),
                    extremeBpm: high ? values.max() : values.min(), qualifiedS: members.count, context: ctx,
                    censoring: Array(Set([startCensor, endCensor].compactMap { $0 })).sorted(),
                    reasons: [high ? pulseEpisodeHigh : pulseEpisodeLow],
                    coverage: duration > 0 ? min(1, Double(members.count) / Double(duration)) : nil,
                    evidenceSource: evidence)
            }

            /// HR accelerations at HR-independent movement onsets whose rise onset lies in `owner`.
            func accelerations(owner: Interval) -> [HeartRateAccelerationEvent] {
                let w = max(0, config.accelerationMovementWindowS)
                let within = max(0, config.accelerationRiseWithinS)
                let band = config.hrPlausibleMinBpm...config.hrPlausibleMaxBpm
                func valid(_ i: Int) -> Bool { i >= 0 && i < hr.count && hr[i] >= 0 && band.contains(hr[i]) }
                var out: [HeartRateAccelerationEvent] = []
                var seen = Set<Int>()
                let lo = max(1, span.start - origin), hi = span.end - origin
                guard hi > lo else { return [] }
                for m in lo..<hi where motion[m] == 2 && motion[m - 1] == 1 {
                    // Baseline: qualified still HR before the association window.
                    let bEnd = m - w, bStart = bEnd - max(1, config.accelerationBaselineS)
                    guard bStart >= 0 else { continue }
                    var base: [Double] = []
                    var lastValid: Int? = nil
                    for i in bStart..<bEnd where qualified[i] { base.append(Double(hr[i])); lastValid = i }
                    guard base.count >= config.accelerationBaselineMinS, let baseline = RobustStats.median(base),
                          var prev = lastValid else { continue }
                    // Continuous HR from the baseline to the first crossing.
                    var crossing: Int? = nil
                    var continuous = true
                    let searchEnd = min(hi, m + w + within + 1)
                    if searchEnd > bEnd {
                        for i in bEnd..<searchEnd where valid(i) {
                            if !adjacent(prev, i) { continuous = false; break }
                            prev = i
                            if Double(hr[i]) >= baseline + config.accelerationRiseBpm { crossing = i; break }
                        }
                    }
                    guard continuous, let p = crossing else { continue }
                    // Rise onset: the last sample at or below the baseline before the crossing.
                    var onset: Int? = nil
                    var i = p - 1
                    while i >= bEnd {
                        if valid(i) && Double(hr[i]) <= baseline { onset = i; break }
                        i -= 1
                    }
                    guard let r = onset, r <= m + w, p - r <= within, !seen.contains(r),
                          owner.contains(origin + r) else { continue }
                    // Peak inside [r, r + within], stopping at a gap or break.
                    var peak = hr[r], peakAt = r, last = r
                    for k in r...min(hi - 1, r + within) where valid(k) {
                        if !adjacent(last, k) { break }
                        last = k
                        if hr[k] > peak { peak = hr[k]; peakAt = k }
                    }
                    seen.insert(r)
                    out.append(HeartRateAccelerationEvent(
                        ts: origin + r, baselineBpm: baseline, peakBpm: Double(peak), riseBpm: Double(peak) - baseline,
                        riseS: peakAt - r, movementOffsetS: m - r, context: context(r), baselineSamples: base.count))
                }
                return out.sorted { $0.ts < $1.ts }
            }
        }
    }
}

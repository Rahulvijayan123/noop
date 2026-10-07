import Foundation

// PCPostureTransitions.swift — heart-rate free posture strata, decoder transition events and per-epoch wear-signal
// quality, joined to a measurement's whole support interval (spec §6.2 join semantics).
//
// OWNER: lead (join). Three context records the activity composition does not carry:
//
//   1. `PostureContext` — a RECUMBENCY likelihood, never sitting vs standing. The wrist cannot separate sitting
//      from standing (measured: free-living balanced accuracy ≈ 0.6 from wrist orientation, standing claims no
//      better than base rate), but lying differs: the forearm axis lies flat (|g_x| / |g| < 0.35) in 64 % of
//      night seconds against 7 % of day seconds (production, owner, 7 days), and an in-bed window is recumbent by
//      construction. A desk or lap forearm is also flat, so the stratum is a likelihood
//      (`posture_likelihood_not_confirmed`), used only to keep materially different measurement regimes apart
//      in the stable-awake references (`ContextReferences` posture strata, shrunk toward the pooled parent).
//      Gravity is heart-rate free; the in-bed window comes from the heart-rate confirmed sleep detector and is
//      flagged (`heartRateDependent`, `in_bed_from_sleep_detector`) whenever it decided the stratum.
//   2. `TransitionEventSummary` — the decoder's typed transition events (sit-to-stand-like, walk start, ...)
//      counted from the events, not from adjacent label changes. Only "a postural change happened" is used: the
//      decoder's direction is unreliable. The decoder reads heart rate, so the events are heart-rate dependent.
//      nil when no decoder document covers the window (unobserved is not "no transition").
//   3. `WearSignalSummary` — the HART lane's six-state wear-signal quality per epoch (loose strap, motion artifact,
//      sensor dropout, ...). Fused from optical signal quality: a target-dependent gate where it decides.

extension PhysiologyContext {

    // MARK: - Posture

    public enum PostureStratum: String, Codable, CaseIterable, Sendable {
        case recumbentLikely = "recumbent_likely"
        /// Seated or standing; the two are never separated.
        case uprightLikely = "upright_likely"
        case unknown
    }

    public struct PostureConfig: Codable, Equatable, Sendable {
        public var version = "pc-posture-1"
        /// A gravity sample is forearm-flat when `|x| / |g|` is below this (x is the strap's forearm axis).
        public var forearmFlatMaxAbsX = 0.35
        /// Gravity samples whose norm is outside this range (g) are not orientation evidence.
        public var gravityNormMin = 0.6
        public var gravityNormMax = 1.4
        /// Gravity evidence decides only when usable samples cover at least this share of the support.
        public var minGravityCoverageShare = 0.8
        /// Recumbent likely: forearm flat for at least this share of the usable gravity seconds.
        public var recumbentMinFlatShare = 0.9
        /// Upright likely: forearm flat for at most this share of the usable gravity seconds.
        public var uprightMaxFlatShare = 0.1
        /// The in-bed window decides recumbent when it covers at least this share of the support.
        public var inBedRecumbentMinShare = 0.9
        /// Upright likely needs the in-bed window to cover at most this share of the support.
        public var uprightMaxInBedShare = 0.0
        /// Use the decoder runs' in-bed window (heart-rate confirmed sleep detector) as recumbency evidence.
        public var useInBedWindow = true
        public init() {}
    }

    /// Heart-rate free recumbency likelihood over a measurement's whole support.
    public struct PostureContext: Codable, Equatable, Sendable, Hashable {
        public var version: String
        public var stratum: PostureStratum
        /// Evidence that decided the stratum: `forearm_gravity`, `in_bed_window` (empty when unknown).
        public var basis: [String]
        /// Support seconds with a usable gravity sample.
        public var gravityS: Int
        /// Share of `gravityS` with the forearm flat; nil without gravity.
        public var forearmFlatShare: Double?
        /// Support seconds inside the decoder's in-bed window; nil when no decoder run covers the support.
        public var inBedS: Int?
        /// True when the in-bed window (heart-rate confirmed sleep detector) decided the stratum.
        public var heartRateDependent: Bool
        public var reasons: [ReasonCode]
        public init(version: String, stratum: PostureStratum, basis: [String], gravityS: Int,
                    forearmFlatShare: Double?, inBedS: Int?, heartRateDependent: Bool, reasons: [ReasonCode]) {
            self.version = version; self.stratum = stratum; self.basis = basis; self.gravityS = gravityS
            self.forearmFlatShare = forearmFlatShare; self.inBedS = inBedS
            self.heartRateDependent = heartRateDependent; self.reasons = reasons
        }
    }

    public enum PostureEvidence {

        public static let version = "pc-posture-1"
        public static let basisForearmGravity = "forearm_gravity"
        public static let basisInBedWindow = "in_bed_window"
        static let inBedLabel = "in_bed"
        static let outOfBedLabel = "not_in_bed"

        // MARK: Reason codes
        /// Every non-unknown stratum: arm orientation and the in-bed window make recumbency likely, not confirmed.
        public static let likelihoodNotConfirmed: ReasonCode = "posture_likelihood_not_confirmed"
        /// Upright stratum: seated and standing are one stratum (the wrist cannot separate them).
        public static let sittingStandingNotSeparated: ReasonCode = "sitting_standing_not_separated"
        public static let inBedFromSleepDetector: ReasonCode = "in_bed_from_sleep_detector"
        public static let insufficientGravity: ReasonCode = "posture_gravity_insufficient"
        public static let ambiguous: ReasonCode = "posture_evidence_ambiguous"
        public static let partlyInBed: ReasonCode = "posture_partly_in_bed"

        public static let reasonCodes: [ReasonCode] = [
            likelihoodNotConfirmed, sittingStandingNotSeparated, inBedFromSleepDetector, insufficientGravity,
            ambiguous, partlyInBed,
        ]

        /// The in-bed track of the decoder runs (`in_bed` / `not_in_bed`, resolved by revision); runs that did not
        /// say are left out (uncovered).
        public static func inBedTrack(_ intervals: [ActivityIntervalInput], availableBy: Int? = nil) -> ResolvedTrack {
            let records = intervals.compactMap { r -> LabelRecord? in
                guard let inBed = r.inBed else { return nil }
                return LabelRecord(interval: r.interval, label: inBed ? inBedLabel : outOfBedLabel, revision: r.revision,
                                   availableAt: r.availableAt,
                                   tieBreak: "in_bed:\(r.revision):\(r.interval.start):\(r.interval.end):\(inBed)")
            }
            return IntervalAlgebra.resolve(records, source: .decoderIntervals, heartRateDependent: true,
                                           availableBy: availableBy)
        }

        /// Posture likelihood over `support` from `motion` (sorted by ts, one sample per second) and the in-bed
        /// track.
        public static func context(over support: Interval, motion: [MotionObservation], inBed: ResolvedTrack,
                                   config: PostureConfig) -> PostureContext {
            guard support.isValid else {
                return PostureContext(version: config.version, stratum: .unknown, basis: [], gravityS: 0,
                                      forearmFlatShare: nil, inBedS: nil, heartRateDependent: false,
                                      reasons: [insufficientGravity])
            }
            let duration = Double(support.duration)
            var gravityS = 0, flatS = 0
            var i = lowerBound(motion, support.start)
            while i < motion.count, motion[i].ts < support.end {
                let m = motion[i]
                i += 1
                guard let x = m.x, let y = m.y, let z = m.z, x.isFinite, y.isFinite, z.isFinite else { continue }
                let norm = (x * x + y * y + z * z).squareRoot()
                guard norm >= config.gravityNormMin, norm <= config.gravityNormMax else { continue }
                gravityS += 1
                if abs(x) / norm < config.forearmFlatMaxAbsX { flatS += 1 }
            }
            let flatShare: Double? = gravityS > 0 ? Double(flatS) / Double(gravityS) : nil
            var inBedS: Int? = nil
            if config.useInBedWindow {
                var covered = 0, inside = 0
                for s in IntervalAlgebra.overlapping(inBed.spans, support) {
                    let w = s.interval.overlapSeconds(with: support)
                    covered += w
                    if s.label == inBedLabel { inside += w }
                }
                if covered > 0 { inBedS = inside }
            }
            let inBedShare = Double(inBedS ?? 0) / duration
            let gravityOK = Double(gravityS) / duration >= config.minGravityCoverageShare

            var stratum = PostureStratum.unknown
            var basis: [String] = []
            var reasons: [ReasonCode] = []
            var hrDependent = false
            if config.useInBedWindow && inBedShare >= config.inBedRecumbentMinShare {
                stratum = .recumbentLikely
                basis = [basisInBedWindow]
                hrDependent = true
                reasons.append(inBedFromSleepDetector)
                if gravityOK, let f = flatShare, f >= config.recumbentMinFlatShare { basis.append(basisForearmGravity) }
            } else if !gravityOK {
                reasons.append(insufficientGravity)
            } else if let f = flatShare, f >= config.recumbentMinFlatShare {
                stratum = .recumbentLikely
                basis = [basisForearmGravity]
            } else if let f = flatShare, f <= config.uprightMaxFlatShare {
                if inBedShare <= config.uprightMaxInBedShare {
                    stratum = .uprightLikely
                    basis = [basisForearmGravity]
                    reasons.append(sittingStandingNotSeparated)
                } else {
                    reasons.append(partlyInBed)
                }
            } else {
                reasons.append(ambiguous)
            }
            if stratum != .unknown { reasons.append(likelihoodNotConfirmed) }
            return PostureContext(version: config.version, stratum: stratum, basis: basis.sorted(), gravityS: gravityS,
                                  forearmFlatShare: flatShare.map { ($0 * 10_000).rounded() / 10_000 },
                                  inBedS: inBedS, heartRateDependent: hrDependent, reasons: reasons.sorted())
        }

        /// First index whose ts is at or after `ts` (motion sorted by ts).
        static func lowerBound(_ motion: [MotionObservation], _ ts: Int) -> Int {
            var lo = 0, hi = motion.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if motion[mid].ts < ts { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    // MARK: - Transition events

    /// Decoder transition events inside one window, counted from the events.
    public struct TransitionEventSummary: Codable, Equatable, Sendable, Hashable {
        public var interval: Interval
        /// Always `decoder_events`.
        public var source: String
        /// The decoder reads heart rate (always true today).
        public var heartRateDependent: Bool
        /// Seconds of the window covered by the decoder documents the events come from.
        public var coveredS: Int
        /// Sit-to-stand / stand-to-sit / lying-down / getting-up like events.
        public var postural: Int
        /// Walk / run start and stop events.
        public var locomotion: Int
        /// Events of a kind this layer does not know.
        public var other: Int
        /// Highest decoder probability among the postural events (nil without one).
        public var maxPosturalProbability: Double?
        /// Count per event kind, sorted by kind.
        public var kinds: [Diagnostic]
        public init(interval: Interval, source: String, heartRateDependent: Bool, coveredS: Int, postural: Int,
                    locomotion: Int, other: Int, maxPosturalProbability: Double?, kinds: [Diagnostic]) {
            self.interval = interval; self.source = source; self.heartRateDependent = heartRateDependent
            self.coveredS = coveredS; self.postural = postural; self.locomotion = locomotion; self.other = other
            self.maxPosturalProbability = maxPosturalProbability; self.kinds = kinds
        }
        public var total: Int { postural + locomotion + other }
    }

    public enum TransitionEvents {

        public static let source = "decoder_events"
        public static let posturalKinds: Set<String> = [
            ActivityTransitionKind.sitToStandLike.rawValue, ActivityTransitionKind.standToSitLike.rawValue,
            ActivityTransitionKind.lyingDownLike.rawValue, ActivityTransitionKind.gettingUpLike.rawValue,
        ]
        public static let locomotionKinds: Set<String> = [
            ActivityTransitionKind.walkStart.rawValue, ActivityTransitionKind.walkStop.rawValue,
            ActivityTransitionKind.runStart.rawValue, ActivityTransitionKind.runStop.rawValue,
        ]

        public static func isPostural(_ kind: String) -> Bool { posturalKinds.contains(kind) }
        public static func isLocomotion(_ kind: String) -> Bool { locomotionKinds.contains(kind) }

        /// Events usable by a document: valid kind text, inside the read window, available at the cutoff (causal),
        /// de-duplicated on (ts, kind) keeping the highest revision, sorted by (ts, kind).
        public static func prepare(_ events: [TransitionEventInput], causalCutoff: Int?) -> [TransitionEventInput] {
            var best: [String: TransitionEventInput] = [:]
            for e in events where !e.kind.isEmpty {
                if let c = causalCutoff {
                    guard e.ts < c, (e.availableAt.map { $0 <= c } ?? true) else { continue }
                }
                let key = "\(e.ts)\u{1f}\(e.kind)"
                if let cur = best[key], (cur.revision, cur.probability) >= (e.revision, e.probability) { continue }
                best[key] = e
            }
            return best.values.sorted { ($0.ts, $0.kind) < ($1.ts, $1.kind) }
        }

        /// Events inside `interval`; nil when no decoder document covers it and no event falls in it.
        public static func summary(_ events: [TransitionEventInput], over interval: Interval,
                                   coverage: ResolvedTrack) -> TransitionEventSummary? {
            guard interval.isValid else { return nil }
            let covered = IntervalAlgebra.overlapping(coverage.spans, interval)
                .reduce(0) { $0 + $1.interval.overlapSeconds(with: interval) }
            var counts: [String: Int] = [:]
            var postural = 0, locomotion = 0, other = 0
            var maxP: Double? = nil
            var i = lowerBound(events, interval.start)
            while i < events.count, events[i].ts < interval.end {
                let e = events[i]
                i += 1
                counts[e.kind, default: 0] += 1
                if isPostural(e.kind) {
                    postural += 1
                    maxP = max(maxP ?? 0, e.probability)
                } else if isLocomotion(e.kind) {
                    locomotion += 1
                } else {
                    other += 1
                }
            }
            if covered == 0 && counts.isEmpty { return nil }
            return TransitionEventSummary(
                interval: interval, source: source, heartRateDependent: true, coveredS: covered, postural: postural,
                locomotion: locomotion, other: other, maxPosturalProbability: maxP.map { ($0 * 10_000).rounded() / 10_000 },
                kinds: counts.keys.sorted().map { Diagnostic($0, Double(counts[$0]!)) })
        }

        /// The last postural and locomotion events strictly before `ts`.
        public static func last(before ts: Int, in events: [TransitionEventInput])
            -> (postural: TransitionEventInput?, locomotion: TransitionEventInput?) {
            var postural: TransitionEventInput? = nil, locomotion: TransitionEventInput? = nil
            var i = lowerBound(events, ts) - 1
            while i >= 0, postural == nil || locomotion == nil {
                let e = events[i]
                if postural == nil && isPostural(e.kind) { postural = e }
                if locomotion == nil && isLocomotion(e.kind) { locomotion = e }
                i -= 1
            }
            return (postural, locomotion)
        }

        /// Attach the transition events of `interval` and the preceding window to a composition and a history.
        public static func annotate(_ activity: inout ActivityComposition, _ preceding: inout PrecedingHistory,
                                    support: Interval, events: [TransitionEventInput], coverage: ResolvedTrack) {
            activity.transitionEvents = summary(events, over: support, coverage: coverage)
            preceding.transitionEvents = summary(events, over: preceding.lookback, coverage: coverage)
            let (p, l) = last(before: support.start, in: events)
            preceding.secondsSinceLastPosturalTransition = p.map { support.start - $0.ts }
            preceding.lastPosturalTransitionKind = p?.kind
            preceding.secondsSinceLastLocomotionTransition = l.map { support.start - $0.ts }
        }

        static func lowerBound(_ events: [TransitionEventInput], _ ts: Int) -> Int {
            var lo = 0, hi = events.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if events[mid].ts < ts { lo = mid + 1 } else { hi = mid }
            }
            return lo
        }
    }

    // MARK: - Wear-signal quality

    /// The HART lane's per-epoch wear-signal quality over a support (`WearSignalState` raw values).
    public struct WearSignalSummary: Codable, Equatable, Sendable, Hashable {
        public var interval: Interval
        /// Seconds of the support covered by an epoch that carried a wear signal.
        public var coveredS: Int
        public var labels: [LabelShare]
        /// Seconds whose signal makes the optical contact unusable or unknown: `on_wrist_loose`, `motion_artifact`,
        /// `sensor_dropout`, `off_wrist`.
        public var poorS: Int
        public init(interval: Interval, coveredS: Int, labels: [LabelShare], poorS: Int) {
            self.interval = interval; self.coveredS = coveredS; self.labels = labels; self.poorS = poorS
        }
    }

    public enum WearSignal {
        public static let poorStates: Set<String> = [
            WearSignalState.onWristLoose.rawValue, WearSignalState.motionArtifact.rawValue,
            WearSignalState.sensorDropout.rawValue, WearSignalState.offWrist.rawValue,
        ]

        /// The wear-signal track of the epochs that carry one (resolved by revision, like the motion track).
        public static func track(_ epochs: [ActivityEpochInput], availableBy: Int? = nil) -> ResolvedTrack {
            let records = epochs.compactMap { e -> LabelRecord? in
                guard let w = e.wearSignal, !w.isEmpty else { return nil }
                return LabelRecord(interval: Interval(e.epoch.startTs, e.epoch.endTs), label: w, revision: e.revision,
                                   availableAt: e.availableAt,
                                   tieBreak: "wear_signal:\(e.revision):\(e.epoch.startTs):\(e.epoch.endTs):\(w)")
            }
            return IntervalAlgebra.resolve(records, source: .hartEpochs, heartRateDependent: false,
                                           availableBy: availableBy)
        }

        /// Summary over `support`; nil when no epoch with a wear signal overlaps it.
        public static func summary(over support: Interval, track: ResolvedTrack) -> WearSignalSummary? {
            guard support.isValid else { return nil }
            var seconds: [String: Int] = [:]
            var covered = 0, poor = 0
            for s in IntervalAlgebra.overlapping(track.spans, support) {
                let w = s.interval.overlapSeconds(with: support)
                guard w > 0, let label = s.label else { continue }
                covered += w
                seconds[label, default: 0] += w
                if poorStates.contains(label) { poor += w }
            }
            guard covered > 0 else { return nil }
            let d = Double(support.duration)
            return WearSignalSummary(interval: support, coveredS: covered,
                                     labels: seconds.keys.sorted().map {
                                         LabelShare(label: $0, seconds: Double(seconds[$0]!),
                                                    share: Double(seconds[$0]!) / d)
                                     }, poorS: poor)
        }
    }
}

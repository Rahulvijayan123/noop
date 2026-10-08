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

    /// The posture context of a stable-awake measurement, finer than the recumbency likelihood (D4-09): seated,
    /// lying awake or standing still. Decided only by posture evidence the decoder stands behind (class confidence
    /// at least `PostureConfig.contextMinConfidence`, a decoder whose posture head reads no heart rate, outside the
    /// heart-rate confirmed in-bed window) and never against the forearm's own gravity reading. Everything else is
    /// `unknown` and stays in the pooled parent reference.
    public enum ContextStratum: String, Codable, CaseIterable, Sendable {
        case seated
        case recumbentAwake = "recumbent_awake"
        case uprightStationary = "upright_stationary"
        case unknown
    }

    public struct PostureConfig: Codable, Equatable, Sendable {
        /// pc-posture-2: adds the context stratum (`ContextStratum`); the recumbency stratum is unchanged.
        public var version = "pc-posture-2"
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

        // Context stratum (D4-09).
        /// tau: the least class confidence a decoder posture claim needs to key a context stratum. Above the
        /// wrist-only sit / stand cap (`ActivityClassifier.wristOnlyPostureConfidenceCap`, 0.75), so a sitting or
        /// standing claim qualifies only when a learned posture source backed it; a lying claim needs a strong one.
        public var contextMinConfidence = 0.8
        /// Share of the support one qualifying posture must cover (the rest: another posture, a claim below tau,
        /// in bed, movement or nothing decoded).
        public var contextMinShare = 0.9
        /// Oldest decoder whose posture head reads no heart rate: from hsmm-1.8 heart rate has one level across bed
        /// rest, seated and upright and separates stationary from exertion only (posture comes from posture
        /// evidence). Older decoders' posture claims leaned on heart rate and never key a stratum.
        public var contextMinDecoderVersion = "hsmm-1.8"
        public init() {}

        enum CodingKeys: String, CodingKey {
            case version, forearmFlatMaxAbsX, gravityNormMin, gravityNormMax, minGravityCoverageShare
            case recumbentMinFlatShare, uprightMaxFlatShare, inBedRecumbentMinShare, uprightMaxInBedShare
            case useInBedWindow, contextMinConfidence, contextMinShare, contextMinDecoderVersion
        }

        /// Configs written before the context stratum existed decode with its defaults.
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let d = PostureConfig()
            version = try c.decodeIfPresent(String.self, forKey: .version) ?? d.version
            forearmFlatMaxAbsX = try c.decodeIfPresent(Double.self, forKey: .forearmFlatMaxAbsX) ?? d.forearmFlatMaxAbsX
            gravityNormMin = try c.decodeIfPresent(Double.self, forKey: .gravityNormMin) ?? d.gravityNormMin
            gravityNormMax = try c.decodeIfPresent(Double.self, forKey: .gravityNormMax) ?? d.gravityNormMax
            minGravityCoverageShare = try c.decodeIfPresent(Double.self, forKey: .minGravityCoverageShare)
                ?? d.minGravityCoverageShare
            recumbentMinFlatShare = try c.decodeIfPresent(Double.self, forKey: .recumbentMinFlatShare)
                ?? d.recumbentMinFlatShare
            uprightMaxFlatShare = try c.decodeIfPresent(Double.self, forKey: .uprightMaxFlatShare) ?? d.uprightMaxFlatShare
            inBedRecumbentMinShare = try c.decodeIfPresent(Double.self, forKey: .inBedRecumbentMinShare)
                ?? d.inBedRecumbentMinShare
            uprightMaxInBedShare = try c.decodeIfPresent(Double.self, forKey: .uprightMaxInBedShare)
                ?? d.uprightMaxInBedShare
            useInBedWindow = try c.decodeIfPresent(Bool.self, forKey: .useInBedWindow) ?? d.useInBedWindow
            contextMinConfidence = try c.decodeIfPresent(Double.self, forKey: .contextMinConfidence)
                ?? d.contextMinConfidence
            contextMinShare = try c.decodeIfPresent(Double.self, forKey: .contextMinShare) ?? d.contextMinShare
            contextMinDecoderVersion = try c.decodeIfPresent(String.self, forKey: .contextMinDecoderVersion)
                ?? d.contextMinDecoderVersion
        }
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
        /// The context stratum (pc-posture-2); nil on envelopes written before it existed. Never heart-rate
        /// dependent: the evidence that would make it so is refused (`contextReasons` says why it is unknown).
        public var context: ContextStratum? = nil
        /// What decided `context`: `decoder_posture`, plus `forearm_gravity` when the forearm agrees.
        public var contextBasis: [String]? = nil
        /// Seconds-weighted class confidence behind `context` (nil when unknown).
        public var contextConfidence: Double? = nil
        public var contextReasons: [ReasonCode]? = nil
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
        /// A heart-rate or HRV measurement: the in-bed window (heart-rate confirmed) was not read; gravity decided.
        public static let inBedNotUsedForHeartRateTarget: ReasonCode = "in_bed_window_not_used_heart_rate_target"
        /// A reference stratum value left out a window whose stratum was decided by heart-rate dependent evidence
        /// (it stays in the parent).
        public static let heartRateDependentStratumNotUsed: ReasonCode = "posture_stratum_heart_rate_dependent_not_used"

        // Context stratum (D4-09).
        public static let basisDecoderPosture = "decoder_posture"
        /// No decoder record covers enough of the support with a posture claim.
        public static let contextNoPostureClaim: ReasonCode = "context_no_posture_claim"
        /// The posture claims are below tau (`contextMinConfidence`).
        public static let contextBelowConfidenceFloor: ReasonCode = "context_confidence_below_floor"
        /// The claims come from a decoder whose posture head read heart rate (older than `contextMinDecoderVersion`).
        public static let contextDecoderReadsHeartRate: ReasonCode = "context_decoder_posture_reads_heart_rate"
        /// Seconds inside the heart-rate confirmed in-bed window are not context evidence.
        public static let contextInBedNotUsed: ReasonCode = "context_in_bed_window_not_used"
        /// Qualifying claims of more than one posture, none covering `contextMinShare`.
        public static let contextMixed: ReasonCode = "context_postures_mixed"
        /// The decoder's posture and the forearm's gravity disagree (lying vs upright).
        public static let contextConflictsWithGravity: ReasonCode = "context_conflicts_with_forearm_gravity"

        public static let reasonCodes: [ReasonCode] = [
            likelihoodNotConfirmed, sittingStandingNotSeparated, inBedFromSleepDetector, insufficientGravity,
            ambiguous, partlyInBed, inBedNotUsedForHeartRateTarget, heartRateDependentStratumNotUsed,
            contextNoPostureClaim, contextBelowConfidenceFloor, contextDecoderReadsHeartRate, contextInBedNotUsed,
            contextMixed, contextConflictsWithGravity,
        ]

        /// The context stratum a decoder class names (nil: not a posture claim).
        public static func contextStratum(forClass c: String?) -> ContextStratum? {
            switch c {
            case "sitting", "sitting_desk": return .seated
            case "standing": return .uprightStationary
            case "lying_down": return .recumbentAwake
            default: return nil
            }
        }

        /// The decoder version of a resolved span's provenance (`algorithm/decoder` or `decoder`).
        static func decoderVersion(of provenance: String?) -> String? {
            guard let p = provenance, !p.isEmpty else { return nil }
            return p.split(separator: "/").last.map(String.init)
        }

        /// `version >= minimum` for `<name>-<major>.<minor>[...]` codes of the same name; false otherwise.
        static func atLeast(_ version: String?, _ minimum: String) -> Bool {
            func parts(_ v: String) -> (String, [Int])? {
                guard let dash = v.lastIndex(of: "-") else { return nil }
                let nums = v[v.index(after: dash)...].split(separator: ".").map { Int($0) }
                guard !nums.isEmpty, nums.allSatisfy({ $0 != nil }) else { return nil }
                return (String(v[..<dash]), nums.map { $0! })
            }
            guard let v = version, let a = parts(v), let b = parts(minimum), a.0 == b.0 else { return false }
            for i in 0..<max(a.1.count, b.1.count) {
                let x = i < a.1.count ? a.1[i] : 0, y = i < b.1.count ? b.1[i] : 0
                if x != y { return x > y }
            }
            return true
        }

        /// The context stratum of `support` (D4-09), written onto `posture`.
        ///
        /// `decoder` is the resolved decoder track (class, confidence, provenance per span), `inBed` the in-bed
        /// track. A second counts for a posture only when a span claims it at confidence >= tau, from a decoder
        /// whose posture head reads no heart rate, outside the in-bed window. One posture must cover
        /// `contextMinShare` of the support, and the forearm's gravity reading (`posture.stratum`) must not say
        /// the opposite (recumbent vs upright).
        public static func withContext(_ posture: PostureContext, over support: Interval, decoder: ResolvedTrack,
                                       inBed: ResolvedTrack, config: PostureConfig) -> PostureContext {
            var out = posture
            var reasons: [ReasonCode] = []
            func finish(_ s: ContextStratum, basis: [String] = [], confidence: Double? = nil) -> PostureContext {
                out.context = s
                out.contextBasis = basis.sorted()
                out.contextConfidence = confidence.map { ($0 * 10_000).rounded() / 10_000 }
                out.contextReasons = Array(Set(reasons + (s == .unknown ? [] : [likelihoodNotConfirmed]))).sorted()
                return out
            }
            guard support.isValid else { reasons.append(contextNoPostureClaim); return finish(.unknown) }
            let bed = IntervalAlgebra.overlapping(inBed.spans, support).filter { $0.label == inBedLabel }.map(\.interval)
            var seconds: [ContextStratum: Int] = [:]
            var confidenceSum: [ContextStratum: Double] = [:]
            var claimed = 0
            for span in IntervalAlgebra.overlapping(decoder.spans, support) {
                guard let stratum = contextStratum(forClass: span.label) else { continue }
                let piece = span.interval.intersection(support)
                guard let piece, piece.duration > 0 else { continue }
                let inBedS = bed.reduce(0) { $0 + $1.overlapSeconds(with: piece) }
                let usable = piece.duration - inBedS
                claimed += piece.duration
                if inBedS > 0 { reasons.append(contextInBedNotUsed) }
                guard usable > 0 else { continue }
                guard atLeast(decoderVersion(of: span.provenance), config.contextMinDecoderVersion) else {
                    reasons.append(contextDecoderReadsHeartRate); continue
                }
                guard let c = span.confidence, c >= config.contextMinConfidence else {
                    reasons.append(contextBelowConfidenceFloor); continue
                }
                seconds[stratum, default: 0] += usable
                confidenceSum[stratum, default: 0] += c * Double(usable)
            }
            if claimed == 0 { reasons.append(contextNoPostureClaim) }
            let need = config.contextMinShare * Double(support.duration)
            guard let best = ContextStratum.allCases.compactMap({ s in seconds[s].map { (s, $0) } })
                    .max(by: { $0.1 < $1.1 }), Double(best.1) >= need else {
                if seconds.count > 1 { reasons.append(contextMixed) }
                return finish(.unknown)
            }
            let (stratum, s) = best
            switch (stratum, posture.stratum) {
            case (.recumbentAwake, .uprightLikely), (.seated, .recumbentLikely), (.uprightStationary, .recumbentLikely):
                reasons.append(contextConflictsWithGravity)
                return finish(.unknown)
            default: break
            }
            var basis = [basisDecoderPosture]
            let gravityAgrees = posture.basis.contains(basisForearmGravity)
                && ((stratum == .recumbentAwake && posture.stratum == .recumbentLikely)
                    || (stratum != .recumbentAwake && posture.stratum == .uprightLikely))
            if gravityAgrees { basis.append(basisForearmGravity) }
            if stratum != .recumbentAwake { reasons.append(sittingStandingNotSeparatedByWrist) }
            return finish(stratum, basis: basis, confidence: (confidenceSum[stratum] ?? 0) / Double(max(1, s)))
        }

        /// A seated / standing context stratum: the claim is a learned-source-backed likelihood (tau is above the
        /// wrist-only cap), still not a measurement of body height.
        public static let sittingStandingNotSeparatedByWrist: ReasonCode = "sit_stand_from_learned_posture_claim"

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
        ///
        /// `heartRateTarget`: the measurement is heart-rate or beat-interval derived. The in-bed window (heart-rate
        /// confirmed sleep detector) is then never read, so the stratum is decided by gravity alone and is
        /// heart-rate free (`in_bed_window_not_used_heart_rate_target`).
        public static func context(over support: Interval, motion: [MotionObservation], inBed: ResolvedTrack,
                                   config: PostureConfig, heartRateTarget: Bool = false) -> PostureContext {
            if heartRateTarget && config.useInBedWindow {
                var gravityOnly = config
                gravityOnly.useInBedWindow = false
                var c = context(over: support, motion: motion, inBed: inBed, config: gravityOnly)
                c.reasons = (c.reasons + [inBedNotUsedForHeartRateTarget]).sorted()
                return c
            }
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

        /// Events usable by a document: valid kind text, inside the read window, available at the cutoff (causal,
        /// on the detection second `ts`), de-duplicated on (ts, kind) keeping the highest revision, sorted by
        /// (ts, kind).
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

        /// Events whose span `[changeTs, ts]` (onset to detection) overlaps `interval`; nil when no decoder document
        /// covers it and no event falls in it. A span, not one point, so both window edges stay conservative: a
        /// change that began inside the window but was flagged after it counts, and so does one flagged inside it
        /// whose onset was earlier (settling runs from when the change finished, at or after detection).
        public static func summary(_ events: [TransitionEventInput], over interval: Interval,
                                   coverage: ResolvedTrack) -> TransitionEventSummary? {
            guard interval.isValid else { return nil }
            let covered = IntervalAlgebra.overlapping(coverage.spans, interval)
                .reduce(0) { $0 + $1.interval.overlapSeconds(with: interval) }
            var counts: [String: Int] = [:]
            var postural = 0, locomotion = 0, other = 0
            var maxP: Double? = nil
            var i = lowerBound(events, interval.start)
            // changeTs >= ts - maxOnsetLeadS, so no later event can begin before the window ends.
            while i < events.count, events[i].ts - ActivityTransitionEvent.maxOnsetLeadS < interval.end {
                let e = events[i]
                i += 1
                guard e.changeTs < interval.end else { continue }
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

        /// The last postural and locomotion events detected strictly before `ts`.
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
            // Measured from detection, not onset: the change had finished no earlier than it was flagged, so the
            // onset would overstate the time since it.
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
                guard let w = e.epoch.wearSignal?.rawValue else { return nil }
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

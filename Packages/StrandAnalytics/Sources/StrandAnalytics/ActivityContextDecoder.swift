import Foundation

// ActivityContextDecoder.swift — temporal decoder: per-second evidence → stable probabilistic state.
//
// Design (see ActivityContextModel.swift for the tables):
//
//   evidence ──► ActivityFeatureWindow ──► ActivityContextModel.score ──┐
//                                                                        ▼
//   body chain  : hidden semi-Markov model over 15 body modes, Erlang-expanded duration priors,
//                 forward (filtering) recursion at 1 s internal resolution
//   arm chain   : small sticky HMM, emissions = movement-pattern likelihoods × body-context prior
//   heads       : posture / locomotion = fixed soft mappings of the body posterior;
//                 arm behaviour = arm posterior; intensity = smoothed log acceleration
//   publisher   : a state every `publishIntervalS` (5 s), display label behind hysteresis
//
// Properties the design relies on:
//   • Causal: a state at time t uses evidence ≤ t only (nothing is revised retroactively).
//   • Evidence is tempered (`evidenceTemperature`) because consecutive 1-s features overlap heavily;
//     without it one weak repeated cue would compound into false certainty.
//   • A flat `unknown` mode absorbs conflicting or missing evidence instead of forcing a class.
//   • Wear is a gate: off-wrist suspends inference and resets the belief, it is not a posterior class.
//   • All state is value-typed and Codable (`snapshot()` / `init(restoring:)`), so a restart resumes
//     with its context rather than relearning it.

public struct ActivityDecoderConfig: Codable, Equatable, Sendable {
    public var restingHeartRate: Double = 60
    public var maxHeartRate: Double = 190
    /// Seconds between published states.
    public var publishIntervalS: Int = 5
    /// Exponent applied to every channel's log-likelihood (see file header).
    public var evidenceTemperature: Double = 0.35
    /// Same, for the arm chain (its states are shorter-lived).
    public var armTemperature: Double = 0.5
    /// A gap this long (seconds) resets the belief and the feature window.
    public var gapResetS: Int = 120
    /// Seconds a new display label must lead before it replaces the current one.
    public var displayHoldS: Int = 10
    /// Same, when only the wording changes inside one kind of label (Desk sitting ↔ Sitting quietly).
    public var displayRefineHoldS: Int = 30
    /// Time constant (seconds) of the arm-behaviour average the display wording is derived from.
    public var armDisplaySmoothS: Int = 45
    /// Seconds an event stays visible in the `transition` field.
    public var eventHoldS: Int = 15
    /// Seconds of event history kept for consumers.
    public var historyWindowS: Int = 900
    /// Inertia-1 motion-head evidence. nil (the default) is OFF: states, snapshots, `cacheTag` and version
    /// stamps are exactly what they were before Inertia existed. A config that refuses its bundle (shadow
    /// mode, a stand-in encoder, a tier below `candidate`, out-of-bounds weights) also leaves the decoder
    /// untouched; `ActivityContextDecoder.motionHeadsRefusal` says why.
    public var motionHeads: MotionHeadsEvidenceConfig? = nil
    /// ElderNet gait evidence. nil (the default) is OFF: states, snapshots, `cacheTag` and version stamps are
    /// exactly what they were before ElderNet existed. A config that refuses its model (shadow mode, a pin
    /// mismatch, out-of-bounds weights) also leaves the decoder untouched; `ActivityContextDecoder.
    /// gaitQualityRefusal` says why.
    public var gaitQuality: GaitQualityEvidenceConfig? = nil
    /// This wearer's adapted observation profiles, fitted from their guided calibration labels and adopted
    /// only after beating the defaults on held-out runs (`ActivityPersonalProfileFitter`). nil (the default)
    /// scores with the population profiles exactly as before.
    public var personalProfile: ActivityPersonalProfile? = nil

    public init() {}
}

public enum ActivityRestoreOutcome: Equatable, Sendable {
    case fresh
    case resumed
    case discarded(String)
}

/// Serializable decoder state: enough to continue a stream after a restart with identical behaviour.
public struct ActivityDecoderSnapshot: Codable, Equatable, Sendable {
    public var versions: ActivityStateVersions
    public var lastTs: Int?
    var body: [Double]
    var arm: [Double]
    var window: ActivityFeatureWindow
    var tracking: DecoderTracking
}

struct PosturalEventTrack: Codable, Equatable {
    var kind: ActivityTransitionKind
    var ts: Int
    var probability: Double
}

struct DisplayState: Codable, Equatable {
    var label: String = ActivityDisplay.unclear
    var candidate: String?
    var candidateGroup: String?
    var candidateSince: Int?
}

struct DecoderTracking: Codable, Equatable {
    var moving = false
    var running = false
    var lastMovingTs: Int?
    var stationarySinceTs: Int?
    var activePostural: PosturalEventTrack?
    var events: [ActivityTransitionEvent] = []
    var offWristSinceTs: Int?
    var lastAgreement: Double = 1
    var lastEvidence: ActivityEvidenceSummary?
    var lastWindowFill: Int = 0
    var lastIntensity: Double?
    var lastSleep: SleepEvidence = .unknown
    var lastInBed = false
    var lastWear: WearEvidence = .unknown
    var lastHasMotion = false
    var encoderId: String?
    var encoderVersion: String?
    var display = DisplayState()
    var lastPublishTs: Int?
    /// Slow average of the arm posterior: display wording follows it, the published head does not.
    var armDisplay: [Double]?
    /// ElderNet's current walking stretch (the reported `gait` block). Only ever set while the gait channel is
    /// active, so a snapshot without it encodes exactly the keys it always did.
    var gaitStretch: GaitTotals?
}

// MARK: - Layout of the Erlang-expanded state space

private struct BodyLayout {
    let start: [Int]
    let phases: [Int]
    let advance: [Double]
    let exits: [[(Int, Double)]]
    /// Exit tables with entry into recumbent modes scaled, keyed by `SleepEvidence`.
    let exitsAwake: [[(Int, Double)]]
    let exitsUnknownSleep: [[(Int, Double)]]
    let total: Int

    private static func scaled(_ exits: [[(Int, Double)]], by k: Double) -> [[(Int, Double)]] {
        let bed = BodyMode.bedRest.rawValue, lying = BodyMode.lyingDown.rawValue
        return exits.map { row in
            let w = row.map { ($0.0, ($0.0 == bed || $0.0 == lying) ? $0.1 * k : $0.1) }
            let t = w.reduce(0) { $0 + $1.1 }
            return w.map { ($0.0, $0.1 / t) }
        }
    }

    func exits(for sleep: SleepEvidence) -> [[(Int, Double)]] {
        switch sleep {
        case .asleep: return exits
        case .awake: return exitsAwake
        case .unknown: return exitsUnknownSleep
        }
    }

    init() {
        var start: [Int] = [], phases: [Int] = [], advance: [Double] = []
        var exits: [[(Int, Double)]] = []
        var cursor = 0
        for m in 0..<BodyMode.count {
            let p = ActivityContextModel.profiles[m]
            start.append(cursor)
            phases.append(p.phases)
            advance.append(min(0.9, Double(p.phases) / p.meanDwellS))
            cursor += p.phases
            let w = p.exits.filter { $0.1 > 0 }
            let t = w.reduce(0) { $0 + $1.1 }
            exits.append(w.map { ($0.0.rawValue, $0.1 / t) })
        }
        self.start = start; self.phases = phases; self.advance = advance
        self.exits = exits; self.total = cursor
        self.exitsAwake = Self.scaled(exits, by: ActivityContextModel.bedEntryScale(.awake))
        self.exitsUnknownSleep = Self.scaled(exits, by: ActivityContextModel.bedEntryScale(.unknown))
    }

    func expand(_ modeMass: [Double]) -> [Double] {
        var s = [Double](repeating: 0, count: total)
        for m in 0..<BodyMode.count { s[start[m]] = modeMass[m] }
        return s
    }
}

private let bodyLayout = BodyLayout()

// MARK: - Decoder

public struct ActivityContextDecoder: Sendable {

    public let config: ActivityDecoderConfig
    public private(set) var restoreOutcome: ActivityRestoreOutcome = .fresh

    private var body: [Double]
    private var arm: [Double]
    private var window = ActivityFeatureWindow()
    private var tracking = DecoderTracking()
    private var lastTs: Int?
    /// The Inertia channels when `config.motionHeads` is accepted; nil keeps every code path as it was.
    private let motionHeads: PreparedMotionHeads?
    /// Why `config.motionHeads` was not used as evidence (nil when it was, or when there is none).
    public let motionHeadsRefusal: String?
    /// What Inertia did in this decoder's lifetime (nil without a motion-heads config). Not part of the
    /// snapshot: it describes a decode, not the belief.
    public private(set) var motionHeadsReport: MotionHeadsTrackReport?
    /// The ElderNet channel when `config.gaitQuality` is accepted; nil keeps every code path as it was.
    private let gaitQuality: PreparedGaitQuality?
    /// Why `config.gaitQuality` was not used as evidence (nil when it was, or when there is none).
    public let gaitQualityRefusal: String?
    /// What ElderNet did in this decoder's lifetime (nil without a gait config). Not part of the snapshot.
    public private(set) var gaitQualityReport: GaitQualityTrackReport?
    /// Observation profiles this decoder scores with: the static table, or the wearer's adapted copy.
    private let observationProfiles: [ModeProfile]
    /// When set, `ingest` keeps the scored second's features and body posterior in `lastScored` (the
    /// personal-profile fitter reads them; ordinary decodes never pay for the copy).
    var recordsScoredSeconds = false
    private(set) var lastScored: (features: ActivityFeatures, posterior: [Double])?

    /// A transition mode needs at least this much posterior mass to be flagged as an event.
    private static let posturalEventFloor = 0.20

    /// Fixed-share floor mixed into the belief each step: no mode can be driven to zero, and the odds
    /// between any two modes stay bounded, so a feature that repeats for minutes cannot lock one in.
    private static let leak = 2e-3

    public init(config: ActivityDecoderConfig = ActivityDecoderConfig()) {
        self.config = config
        self.observationProfiles = ActivityContextModel.profiles(for: config.personalProfile)
        self.body = bodyLayout.expand(ActivityContextModel.prior)
        self.arm = ActivityContextModel.armPrior
        let prepared = PreparedMotionHeads.prepare(config.motionHeads)
        self.motionHeads = prepared.prepared
        self.motionHeadsRefusal = prepared.refusal
        if config.motionHeads != nil {
            self.motionHeadsReport = MotionHeadsTrackReport(stamp: prepared.prepared?.stamp, refusal: prepared.refusal)
        }
        let gait = PreparedGaitQuality.prepare(config.gaitQuality)
        self.gaitQuality = gait.prepared
        self.gaitQualityRefusal = gait.refusal
        if config.gaitQuality != nil {
            self.gaitQualityReport = GaitQualityTrackReport(stamp: gait.prepared?.stamp, refusal: gait.refusal)
        }
    }

    /// The provenance stamp of the active Inertia evidence (`ActivityStateVersions.motionHeads`), or nil.
    public var motionHeadsStamp: String? { motionHeads?.stamp }

    /// The provenance stamp of the active ElderNet evidence (`ActivityStateVersions.gaitQuality`), or nil.
    public var gaitQualityStamp: String? { gaitQuality?.stamp }

    /// Resume from a snapshot. A snapshot written by a different ontology / decoder / feature schema, or
    /// with a mismatched state layout, is discarded and the decoder starts fresh (never a silent mix).
    public init(config: ActivityDecoderConfig = ActivityDecoderConfig(), restoring snapshot: ActivityDecoderSnapshot?) {
        self.init(config: config)
        guard let s = snapshot else { return }
        let v = s.versions
        if v.ontology != ActivityContextVersions.ontology || v.decoder != ActivityContextVersions.decoder
            || v.featureSchema != ActivityContextVersions.featureSchema {
            restoreOutcome = .discarded("version_mismatch")
            return
        }
        // A belief built with Inertia evidence (or with another bundle / config) is never continued without
        // it, and vice versa. Both nil without Inertia, so older snapshots resume as before.
        if v.motionHeads != motionHeads?.stamp {
            restoreOutcome = .discarded("motion_heads_mismatch")
            return
        }
        // The same for ElderNet: a belief shaped by another model / config (or by none) is never continued.
        if v.gaitQuality != gaitQuality?.stamp {
            restoreOutcome = .discarded("gait_quality_mismatch")
            return
        }
        guard s.body.count == bodyLayout.total, s.arm.count == ArmState.count,
              s.body.allSatisfy({ $0.isFinite && $0 >= 0 }), s.arm.allSatisfy({ $0.isFinite && $0 >= 0 }),
              s.body.reduce(0, +) > 0, s.arm.reduce(0, +) > 0 else {
            restoreOutcome = .discarded("layout_mismatch")
            return
        }
        body = s.body; arm = s.arm; window = s.window; tracking = s.tracking; lastTs = s.lastTs
        restoreOutcome = .resumed
    }

    public func snapshot() -> ActivityDecoderSnapshot {
        ActivityDecoderSnapshot(
            versions: ActivityStateVersions(encoderId: tracking.encoderId, encoderVersion: tracking.encoderVersion,
                                            motionHeads: motionHeads?.stamp, gaitQuality: gaitQuality?.stamp),
            lastTs: lastTs, body: body, arm: arm, window: window, tracking: tracking)
    }

    public var lastObservationTs: Int? { lastTs }

    // MARK: Ingest

    /// Feed one second of evidence. Returns a published state when one is due (every
    /// `publishIntervalS` seconds, on the grid of multiples of the interval), otherwise nil.
    /// Out-of-order or duplicate timestamps are ignored.
    @discardableResult
    public mutating func ingest(_ obs: ActivityObservation) -> ActivityContextState? {
        if let last = lastTs, obs.ts <= last { return nil }
        if recordsScoredSeconds { lastScored = nil }

        if let enc = obs.encoder {
            tracking.encoderId = enc.encoderId
            tracking.encoderVersion = enc.encoderVersion
        }

        let firstEver = lastTs == nil
        if let last = lastTs {
            let gap = obs.ts - last
            if gap > config.gapResetS {
                resetBelief()
            } else if gap > 1 {
                // Time passed with no evidence: let the belief diffuse by the elapsed seconds.
                for _ in 1..<gap { predictBody(shift: 0); predictArm() }
            }
        }

        tracking.lastSleep = obs.sleep
        tracking.lastInBed = obs.inBed
        tracking.lastWear = obs.wear

        if obs.wear == .offWrist {
            if tracking.offWristSinceTs == nil {
                tracking.offWristSinceTs = obs.ts
                resetBelief()
            }
            lastTs = obs.ts
            return publishIfDue(obs.ts)
        }
        if tracking.offWristSinceTs != nil {
            tracking.offWristSinceTs = nil
            resetBelief()
        }

        // Without accepted Inertia evidence the hold is 0: a window on the observation is neither kept in the
        // feature window (so the snapshot is unchanged) nor scored.
        let f = window.push(obs, restingHR: config.restingHeartRate, maxHR: config.maxHeartRate,
                            motionHeadsHoldS: motionHeads?.holdS ?? 0, gaitQualityHoldS: gaitQuality?.holdS ?? 0)

        if !firstEver { predictBody(shift: ActivityContextModel.shiftStrength(f)); predictArm() }
        let score = ActivityContextModel.score(f, temperature: config.evidenceTemperature, motionHeads: motionHeads,
                                               gaitQuality: gaitQuality, table: observationProfiles)
        applyBody(score)
        applyArm(f, motionHeads: score.arm)
        smoothArmForDisplay()
        if motionHeads != nil, motionHeadsReport != nil {
            if let w = obs.motionHeads {
                motionHeadsReport!.windowsIngested += 1
                if w.isOOD { motionHeadsReport!.oodWindows += 1 }
            }
            if score.motionHeadsApplied { motionHeadsReport!.evidenceSeconds += 1 }
            if score.specialistOpenedByMotionHeads { motionHeadsReport!.specialistOpenings += 1 }
            if score.motionHeadsPostureOmitted { motionHeadsReport!.postureOmittedSleep += 1 }
        }
        if gaitQuality != nil, gaitQualityReport != nil {
            if let w = obs.gaitQuality {
                gaitQualityReport!.windowsIngested += 1
                if w.isGait { gaitQualityReport!.gaitWindows += 1 }
                if w.prefiltered { gaitQualityReport!.prefilteredWindows += 1 }
            }
            if score.gaitQualityApplied { gaitQualityReport!.evidenceSeconds += 1 }
            if score.gaitBudgetLimited { gaitQualityReport!.budgetLimitedSeconds += 1 }
            if let brisk = score.gaitFavoursBrisk {
                if brisk { gaitQualityReport!.briskFavouredSeconds += 1 } else { gaitQualityReport!.walkFavouredSeconds += 1 }
            }
            if score.briskShift != nil { gaitQualityReport!.briskAppliedSeconds += 1 }
        }

        let post = bodyPosterior()
        if recordsScoredSeconds { lastScored = (f, post) }
        var agreement = 0.0
        for m in 0..<BodyMode.count { agreement += post[m] * exp(score.disagreement[m]) }
        tracking.lastAgreement = min(1, max(0, agreement))
        tracking.lastEvidence = f.evidence
        tracking.lastWindowFill = f.windowFill
        tracking.lastHasMotion = score.hasMotion
        tracking.lastIntensity = f.m10
        updateTracking(post, ts: obs.ts)
        if let gaitQuality { updateGaitStretch(post, arrived: obs.gaitQuality, held: f.gaitQuality, gait: gaitQuality) }
        lastTs = obs.ts
        return publishIfDue(obs.ts)
    }

    /// The reported gait block: the current walking stretch is ElderNet's consecutive gait windows while the
    /// posterior is on the gait modes. It ends when the posterior leaves them, when ElderNet says non-gait, or
    /// when no window is held any more. A window is counted once, on the second it arrives.
    private mutating func updateGaitStretch(_ post: [Double], arrived: GaitQualityWindow?, held: GaitQualityWindow?,
                                            gait: PreparedGaitQuality) {
        let pGait = PreparedGaitQuality.gaitModes.reduce(0.0) { $0 + post[$1.rawValue] }
        guard pGait >= PreparedGaitQuality.posteriorGaitFloor, let held, held.isGait else {
            tracking.gaitStretch = nil
            return
        }
        guard let w = arrived, w.isGait else { return }
        var stretch = tracking.gaitStretch ?? GaitTotals(since: nil, provenance: gait.stamp)
        stretch.add(w, stepShare: gait.stepShare)
        tracking.gaitStretch = stretch
    }

    // MARK: Belief updates

    private mutating func resetBelief() {
        body = bodyLayout.expand(ActivityContextModel.prior)
        arm = ActivityContextModel.armPrior
        window.reset()
        tracking.moving = false
        tracking.running = false
        tracking.stationarySinceTs = nil
        tracking.activePostural = nil
        tracking.lastWindowFill = 0
        tracking.armDisplay = nil
        // The display label is carried state too: after a data gap or an off-wrist return the new
        // context must not keep publishing the stale pre-gap wording or its hysteresis candidate
        // (WS-05-F03). Resetting to the default ("Unclear", no candidate) lets the first fresh
        // observation adopt its own label immediately.
        tracking.display = DisplayState()
        tracking.gaitStretch = nil
    }

    private mutating func predictBody(shift: Double) {
        var next = [Double](repeating: 0, count: bodyLayout.total)
        let exitTable = bodyLayout.exits(for: tracking.lastSleep)
        for m in 0..<BodyMode.count {
            let start = bodyLayout.start[m], k = bodyLayout.phases[m], p = bodyLayout.advance[m]
            for j in 0..<k {
                let a = body[start + j]
                if a == 0 { continue }
                let moved = a * p
                next[start + j] += a - moved
                if j < k - 1 {
                    next[start + j + 1] += moved
                } else {
                    for (to, w) in exitTable[m] { next[bodyLayout.start[to]] += moved * w }
                }
            }
        }

        // A clear posture-shift burst raises the hazard of the matching transition: diverts a slice of
        // the stationary mass into the transition mode (the direction comes from where the mass is).
        if shift > 0.05 {
            let h = ActivityContextModel.shiftHazard * shift
            func divert(_ from: BodyMode, _ to: BodyMode, _ weight: Double) {
                let fraction = min(0.5, h * weight)
                let s0 = bodyLayout.start[from.rawValue]
                var moved = 0.0
                for j in 0..<bodyLayout.phases[from.rawValue] {
                    let d = next[s0 + j] * fraction
                    next[s0 + j] -= d
                    moved += d
                }
                next[bodyLayout.start[to.rawValue]] += moved
            }
            divert(.seated, .sitToStand, 1.0)
            divert(.upright, .standToSit, 1.0)
            divert(.seated, .lyingDown, 0.25)
            divert(.upright, .lyingDown, 0.15)
            // Turning over in bed looks the same from the wrist, so while the band says asleep a burst is
            // much more likely a roll than a get-up.
            divert(.bedRest, .gettingUp, tracking.lastSleep == .asleep ? 0.35 : 1.0)
        }
        body = next
    }

    private mutating func applyBody(_ score: ActivityContextModel.Score) {
        let mx = score.logL.max() ?? 0
        var total = 0.0
        if score.postureShift != nil || score.briskShift != nil {
            applyBodyWithPosture(score, shift: score.postureShift, brisk: score.briskShift, mx: mx, total: &total)
        } else {
            for m in 0..<BodyMode.count {
                let l = exp(score.logL[m] - mx)
                let start = bodyLayout.start[m]
                for j in 0..<bodyLayout.phases[m] {
                    body[start + j] *= l
                    total += body[start + j]
                }
            }
        }
        if !(total > 1e-300) || !total.isFinite {
            body = bodyLayout.expand(ActivityContextModel.prior)
            return
        }
        let prior = bodyLayout.expand(ActivityContextModel.prior)
        let eps = Self.leak
        for s in 0..<body.count { body[s] = (1 - eps) * (body[s] / total) + eps * prior[s] }
    }

    /// The body update with the Inertia posture term. The term is renormalised inside the stationary /
    /// transition set S against the belief after every other channel, so the set's total mass is exactly
    /// what it would have been without it: the wrist's posture evidence can say "seated rather than upright",
    /// never "stationary rather than moving". (Renormalising against the static mode prior instead would only
    /// preserve P(S) when the current belief inside S happened to equal that prior.)
    ///
    /// The ElderNet walk-vs-brisk term (`brisk`) is applied the same way inside {walk, briskWalk}: it can say
    /// "brisk rather than easy walking", never "walking rather than not". The two sets are disjoint.
    private mutating func applyBodyWithPosture(_ score: ActivityContextModel.Score, shift: [Double]?,
                                               brisk: [Double]? = nil, mx: Double, total: inout Double) {
        var l = [Double](repeating: 0, count: BodyMode.count)
        for m in 0..<BodyMode.count { l[m] = exp(score.logL[m] - mx) }
        if let shift { renormalise(&l, inside: PreparedMotionHeads.postureSet, shift: shift) }
        if let brisk { renormalise(&l, inside: PreparedGaitQuality.briskPair, shift: brisk) }
        for m in 0..<BodyMode.count {
            let start = bodyLayout.start[m]
            for j in 0..<bodyLayout.phases[m] {
                body[start + j] *= l[m]
                total += body[start + j]
            }
        }
    }

    /// Multiply `l` by `exp(shift)` inside `set`, rescaled so the set's total mass under the current belief is
    /// what it would have been without the shift.
    private func renormalise(_ l: inout [Double], inside set: [BodyMode], shift: [Double]) {
        var before = 0.0, after = 0.0
        for mode in set {
            let m = mode.rawValue
            let start = bodyLayout.start[m]
            var mass = 0.0
            for j in 0..<bodyLayout.phases[m] { mass += body[start + j] }
            before += mass * l[m]
            after += mass * l[m] * exp(shift[m])
        }
        if before > 0, after > 0, before.isFinite, after.isFinite {
            let k = before / after
            for mode in set { l[mode.rawValue] *= exp(shift[mode.rawValue]) * k }
        }
    }

    /// Arm chain time update. The body posterior is used as a PRIOR over where the arm state goes when it
    /// changes (desk-like after seated, gesturing after upright …), not as repeated per-second evidence:
    /// a context that is merely likely must not keep pushing the arm state the same way every second.
    private mutating func predictArm() {
        let a = ArmState.count
        let ctx = ActivityContextModel.armContext(bodyPosterior: bodyPosterior())
        var next = [Double](repeating: 0, count: a)
        for i in 0..<a {
            let stay = ActivityContextModel.armStay[i]
            next[i] += arm[i] * stay
            let out = arm[i] * (1 - stay)
            var denom = 0.0
            for j in 0..<a where j != i { denom += ctx[j] }
            for j in 0..<a where j != i { next[j] += out * ctx[j] / denom }
        }
        arm = next
    }

    /// Arm chain measurement update. `motionHeads` is the Inertia arm head (likelihood per arm state and its
    /// weight): arm[i] *= L(i)^(armTemperature · weight). It reaches the arm chain only, never the body chain.
    private mutating func applyArm(_ f: ActivityFeatures, motionHeads: (L: [Double], weight: Double)? = nil) {
        let q = ActivityContextModel.armPattern(f)
        let tau = config.armTemperature
        var total = 0.0
        for i in 0..<ArmState.count {
            arm[i] *= pow(max(1e-6, q[i]), tau)
            if let mh = motionHeads { arm[i] *= pow(max(1e-6, mh.L[i]), tau * mh.weight) }
            total += arm[i]
        }
        if !(total > 1e-300) || !total.isFinite {
            arm = ActivityContextModel.armPrior
            return
        }
        let prior = ActivityContextModel.armPrior
        for i in 0..<ArmState.count { arm[i] = (1 - Self.leak) * (arm[i] / total) + Self.leak * prior[i] }
    }

    private mutating func smoothArmForDisplay() {
        let alpha = 1 / Double(max(1, config.armDisplaySmoothS))
        if var e = tracking.armDisplay, e.count == arm.count {
            for i in 0..<arm.count { e[i] += alpha * (arm[i] - e[i]) }
            tracking.armDisplay = e
        } else {
            tracking.armDisplay = arm
        }
    }

    private func bodyPosterior() -> [Double] {
        var b = [Double](repeating: 0, count: BodyMode.count)
        for m in 0..<BodyMode.count {
            let start = bodyLayout.start[m]
            for j in 0..<bodyLayout.phases[m] { b[m] += body[start + j] }
        }
        return b
    }

    // MARK: Tracking (events, history)

    private mutating func updateTracking(_ post: [Double], ts: Int) {
        let pMoving = post[BodyMode.walk.rawValue] + post[BodyMode.briskWalk.rawValue]
            + post[BodyMode.run.rawValue] + post[BodyMode.stairs.rawValue]
        let pRun = post[BodyMode.run.rawValue]
        let pStationary = post[BodyMode.bedRest.rawValue] + post[BodyMode.seated.rawValue] + post[BodyMode.upright.rawValue]

        if pMoving >= 0.5 { tracking.lastMovingTs = ts }

        if !tracking.moving, pMoving >= 0.6 {
            tracking.moving = true
            record(.walkStart, p: pMoving, ts: ts)
        } else if tracking.moving, pMoving <= 0.3 {
            tracking.moving = false
            record(.walkStop, p: 1 - pMoving, ts: ts)
        }
        if !tracking.running, pRun >= 0.55 {
            tracking.running = true
            record(.runStart, p: pRun, ts: ts)
        } else if tracking.running, pRun <= 0.25 {
            tracking.running = false
            record(.runStop, p: 1 - pRun, ts: ts)
        }

        // Stationary run length.
        if pStationary >= 0.6 { if tracking.stationarySinceTs == nil { tracking.stationarySinceTs = ts } }
        else if pStationary <= 0.4 { tracking.stationarySinceTs = nil }

        // Posture-change events: one event per excursion of a transition mode above 0.30.
        let kinds: [(BodyMode, ActivityTransitionKind)] = [
            (.sitToStand, .sitToStandLike), (.standToSit, .standToSitLike),
            (.lyingDown, .lyingDownLike), (.gettingUp, .gettingUpLike),
        ]
        if var active = tracking.activePostural {
            let mass = post[kinds.first { $0.1 == active.kind }!.0.rawValue]
            if mass > active.probability {
                active.probability = mass
                tracking.activePostural = active
                if let i = tracking.events.lastIndex(where: { $0.kind == active.kind && $0.ts == active.ts }) {
                    tracking.events[i].probability = mass
                }
            }
            if mass < Self.posturalEventFloor / 2 { tracking.activePostural = nil }
        } else if let hit = kinds.max(by: { post[$0.0.rawValue] < post[$1.0.rawValue] }),
                  post[hit.0.rawValue] >= Self.posturalEventFloor {
            tracking.activePostural = PosturalEventTrack(kind: hit.1, ts: ts, probability: post[hit.0.rawValue])
            record(hit.1, p: post[hit.0.rawValue], ts: ts)
        }

        let cutoff = ts - config.historyWindowS
        tracking.events.removeAll { $0.ts < cutoff }
    }

    private mutating func record(_ kind: ActivityTransitionKind, p: Double, ts: Int) {
        tracking.events.append(ActivityTransitionEvent(kind: kind, probability: min(1, max(0, p)), ts: ts))
        if tracking.events.count > 24 { tracking.events.removeFirst(tracking.events.count - 24) }
    }

    // MARK: Publishing

    private mutating func publishIfDue(_ ts: Int) -> ActivityContextState? {
        let interval = max(1, config.publishIntervalS)
        let due: Bool
        if let last = tracking.lastPublishTs {
            // On the interval grid, or late because the grid second had no observation.
            due = (ts - last >= interval && ts % interval == 0) || ts - last >= 2 * interval
        } else {
            due = ts % interval == 0
        }
        guard due else { return nil }
        tracking.lastPublishTs = ts
        let state = buildState(ts)
        if state.gait != nil, gaitQualityReport != nil { gaitQualityReport!.gaitBlockStates += 1 }
        return state
    }

    /// The state for the most recent observation, computed on demand (does not advance the 5-s grid).
    public mutating func currentState() -> ActivityContextState? {
        guard let ts = lastTs else { return nil }
        return buildState(ts)
    }

    private mutating func buildState(_ ts: Int) -> ActivityContextState {
        let versions = ActivityStateVersions(encoderId: tracking.encoderId, encoderVersion: tracking.encoderVersion,
                                             motionHeads: motionHeads?.stamp, gaitQuality: gaitQuality?.stamp)
        let wearState: WearContextState
        switch tracking.lastWear {
        case .onWrist: wearState = .onWrist
        case .offWrist: wearState = .offWrist
        case .unknown: wearState = .unknown
        }
        let sleepState: SleepContextState
        switch tracking.lastSleep {
        case .asleep: sleepState = .asleep
        case .awake: sleepState = .awake
        case .unknown: sleepState = .unknown
        }
        let sleep = SleepContext(state: sleepState, probability: nil, inBed: tracking.lastInBed)
        let evidence = tracking.lastEvidence ?? ActivityEvidenceSummary(
            imu: false, encoder: false, dynAccel: false, gravity: false, steps: false,
            heartRate: false, sleep: false, coverage: 0)

        let sinceLoco = tracking.lastMovingTs.map { max(0, ts - $0) }
        let stationaryFor = tracking.stationarySinceTs.map { max(0, ts - $0) } ?? 0
        let history = ActivityHistorySummary(sinceLocomotionS: sinceLoco, stationaryForS: stationaryFor,
                                             recentEvents: tracking.events)

        if tracking.offWristSinceTs != nil {
            tracking.display = DisplayState(label: ActivityDisplay.offWrist, candidate: nil, candidateSince: nil)
            return ActivityContextState(
                ts: ts,
                posture: HeadProbabilities([.unknown: 1]),
                locomotion: HeadProbabilities([.unknown: 1]),
                armBehavior: HeadProbabilities([.unknown: 1]),
                intensity: nil, transition: nil, sleep: sleep,
                wear: WearContext(state: .offWrist, validity: 0),
                overallConfidence: 0, overallUncertainty: 1,
                headConfidence: ActivityHeadConfidence(posture: 0, locomotion: 0, armBehavior: 0),
                displayContext: ActivityDisplay.offWrist,
                history: ActivityHistorySummary(sinceLocomotionS: nil, stationaryForS: 0, recentEvents: []),
                evidence: evidence, versions: versions)
        }

        let post = bodyPosterior()
        var posture: [PostureClass: Double] = [:]
        var loco: [LocomotionClass: Double] = [:]
        for m in 0..<BodyMode.count where post[m] > 0 {
            let p = ActivityContextModel.profiles[m]
            for (c, w) in p.posture { posture[c, default: 0] += post[m] * w }
            for (c, w) in p.locomotion { loco[c, default: 0] += post[m] * w }
        }
        var armDist: [ArmBehaviorClass: Double] = [:]
        for (i, c) in ArmState.classes.enumerated() { armDist[c] = arm[i] }

        let postureHead = HeadProbabilities(posture).normalized()
        let locoHead = HeadProbabilities(loco).normalized()
        let armHead = HeadProbabilities(armDist).normalized()

        let headConf = ActivityHeadConfidence(
            posture: postureHead.top(excluding: .unknown)?.1 ?? 0,
            locomotion: locoHead.top(excluding: .unknown)?.1 ?? 0,
            armBehavior: armHead.top(excluding: .unknown)?.1 ?? 0)

        // Overall confidence / uncertainty.
        let unknownMass = post[BodyMode.unknown.rawValue]
        var h = 0.0
        for p in post where p > 0 { h -= p * log(p) }
        let entropy = min(1, h / log(Double(BodyMode.count)))
        let coverage = evidence.coverage
        let warm = min(1, Double(tracking.lastWindowFill) / 10)
        var confidence = (1 - unknownMass) * (1 - 0.5 * entropy) * tracking.lastAgreement
        confidence *= 0.45 + 0.55 * coverage
        confidence *= 0.5 + 0.5 * warm
        if !tracking.lastHasMotion { confidence *= 0.5 }
        if tracking.lastWear == .unknown { confidence *= 0.95 }
        confidence = min(1, max(0, confidence))
        let uncertainty = min(1, max(0, 0.5 * entropy + 0.5 * min(1, unknownMass + (1 - tracking.lastAgreement) * 0.5)))

        // Display label behind hysteresis.
        var armShown: [ArmBehaviorClass: Double] = [:]
        let armSource = tracking.armDisplay ?? arm
        for (i, c) in ArmState.classes.enumerated() { armShown[c] = armSource[i] }
        let raw = ActivityDisplay.derive(posture: postureHead, locomotion: locoHead,
                                         arm: HeadProbabilities(armShown).normalized(),
                                         sleep: sleepState, inBed: tracking.lastInBed,
                                         confidence: confidence)
        let label = applyHysteresis(raw: raw, ts: ts)

        // The event field shows only fresh events.
        let fresh = tracking.events.last { ts - $0.ts <= config.eventHoldS && ts >= $0.ts }

        let wearValidity: Double
        switch tracking.lastWear {
        case .onWrist: wearValidity = 1
        case .offWrist: wearValidity = 0
        case .unknown: wearValidity = evidence.heartRate ? 0.9 : 0.5
        }

        return ActivityContextState(
            ts: ts, posture: postureHead, locomotion: locoHead, armBehavior: armHead,
            intensity: tracking.lastIntensity, transition: fresh, sleep: sleep,
            wear: WearContext(state: wearState, validity: wearValidity),
            overallConfidence: confidence, overallUncertainty: uncertainty,
            headConfidence: headConf,
            displayContext: label == ActivityDisplay.unclear ? nil : label,
            history: history, evidence: evidence, versions: versions,
            gait: gaitQuality == nil ? nil : tracking.gaitStretch.map(\.summary))
    }

    /// Display hysteresis. A change of *kind* (moving ↔ stationary ↔ lying …) must hold for the group's
    /// dwell time, counting any label of the new kind (so a flicker between two stationary wordings does
    /// not restart the clock); a refinement inside the same kind must hold the exact new label.
    private mutating func applyHysteresis(raw: String, ts: Int) -> String {
        var d = tracking.display
        defer { tracking.display = d }
        func clear() { d.candidate = nil; d.candidateGroup = nil; d.candidateSince = nil }
        if raw == d.label { clear(); return d.label }
        // Wear is a hard gate, not an estimate: leaving "Off wrist" needs no confirmation period.
        // Likewise there is nothing to protect while the label is still "Unclear": a first confident
        // label can be adopted immediately.
        if d.label == ActivityDisplay.offWrist || d.label == ActivityDisplay.unclear {
            d.label = raw; clear(); return d.label
        }

        let hold = ActivityDisplay.holdSeconds(to: raw, default: config.displayHoldS)
        if hold <= 0 { d.label = raw; clear(); return d.label }

        let crossKind = ActivityDisplay.group(raw) != ActivityDisplay.group(d.label)
        if crossKind, confirmedByEvent(group: ActivityDisplay.group(raw), ts: ts) {
            d.label = raw; clear(); return d.label
        }
        if crossKind {
            if d.candidateGroup == ActivityDisplay.group(raw), let since = d.candidateSince {
                if ts - since >= hold { d.label = raw; clear() }
            } else {
                d.candidate = raw; d.candidateGroup = ActivityDisplay.group(raw); d.candidateSince = ts
            }
        } else {
            if d.candidate == raw, d.candidateGroup == nil, let since = d.candidateSince {
                if ts - since >= max(hold, config.displayRefineHoldS) { d.label = raw; clear() }
            } else {
                d.candidate = raw; d.candidateGroup = nil; d.candidateSince = ts
            }
        }
        return d.label
    }

    /// How long after a change of position the label may follow it without a hold. Longer than the event's own
    /// visibility: the posture settles some seconds after the burst that flagged it.
    static let eventConfirmsS = 30

    /// The hold guards against flicker, which a flagged change of position is the evidence against: a fresh,
    /// confident event that ends in `group` lets the label follow at once, so a short stand still shows.
    private func confirmedByEvent(group: String, ts: Int) -> Bool {
        tracking.events.contains { event in
            ts >= event.ts && ts - event.ts <= Self.eventConfirmsS
                && event.probability >= PositionChanges.minimumProbability
                && ActivityDisplay.groups(after: event.kind).contains(group)
        }
    }
}

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
    /// hsmm-1.8: a published state has shown this event. Until then its kind may still follow whichever
    /// direction comes to lead (older snapshots never have the key).
    var shown: Bool?
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
    /// The in-process ElderNet window behind the last second, and its age then (for `gaitReading`).
    var lastGait: GaitExpertEvidence?
    var lastGaitAgeS: Int?
    /// Posture-evidence memory (hsmm-1.8): per source, decaying, capped tempered log-odds in
    /// `ActivityContextModel.PostureEvidence.values` order. nil (= none yet), so a snapshot without it still decodes.
    var postureEvidence: [Double]?
    /// Consecutive seconds of a pulseless, implausibly still strap (see `ActivityContextModel.implausiblyStill`).
    var noPulseStillS: Int?
    /// The last second inside the night's in-bed window: a burst just after it is getting up.
    var lastInBedTs: Int?
    /// A postural event whose excursion ended before any published state showed it: shown next.
    var showNext: ActivityTransitionEvent?
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

    static func scaled(_ exits: [[(Int, Double)]], by k: Double) -> [[(Int, Double)]] {
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
    /// Seconds a postural event may settle its direction before a published state shows it (hsmm-1.8).
    static let posturalEventSettleS = 3

    /// Gaps longer than this (and up to `gapResetS`) flatten the belief toward the re-acquisition prior in
    /// proportion to their length: a posture is not carried with confidence across a 30–120 s dropout (D2-13).
    static let gapFlattenOnsetS = 20
    static let gapFlattenScaleS = 40.0
    /// Seconds after the night's in-bed window ends during which a burst from sitting is getting up.
    static let afterBedS = 120

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
        var gapS = 0
        if let last = lastTs {
            let gap = obs.ts - last
            if gap > config.gapResetS {
                resetBelief()
            } else if gap > 1 {
                // Time passed with no evidence: let the belief diffuse by the elapsed seconds.
                for _ in 1..<gap { predictBody(shift: 0, ts: last); predictArm() }
                gapS = gap
                decayPostureEvidence(seconds: gap - 1)
            }
        }

        tracking.lastSleep = obs.sleep
        tracking.lastInBed = obs.inBed
        tracking.lastWear = obs.wear
        if obs.inBed { tracking.lastInBedTs = obs.ts }

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
        var f = window.push(obs, restingHR: config.restingHeartRate, maxHR: config.maxHeartRate,
                            motionHeadsHoldS: motionHeads?.holdS ?? 0, gaitQualityHoldS: gaitQuality?.holdS ?? 0)
        if gapS > Self.gapFlattenOnsetS { flattenAfterGap(gapS) }
        // No pulse, no wear evidence, stiller than a resting wrist: count it (D1-05).
        if obs.wear == .unknown, f.hr == nil, ActivityContextModel.implausiblyStill(f) {
            tracking.noPulseStillS = (tracking.noPulseStillS ?? 0) + 1
        } else {
            tracking.noPulseStillS = nil
        }
        f.noPulseStillS = tracking.noPulseStillS ?? 0

        if !firstEver {
            predictBody(shift: ActivityContextModel.shiftStrength(f), ts: obs.ts,
                        expert: ActivityContextModel.expertTransition(f))
            predictArm()
        }
        let score = ActivityContextModel.score(f, temperature: config.evidenceTemperature, motionHeads: motionHeads,
                                               gaitQuality: gaitQuality, table: observationProfiles)
        applyBody(score)
        boundPosture(score, f, sleep: obs.sleep, inBed: obs.inBed)
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
        tracking.lastGait = f.gait
        tracking.lastGaitAgeS = f.gaitAgeS
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
        tracking.lastGait = nil
        tracking.lastGaitAgeS = nil
        tracking.lastWindowFill = 0
        tracking.armDisplay = nil
        // The display label is carried state too: after a data gap or an off-wrist return the new
        // context must not keep publishing the stale pre-gap wording or its hysteresis candidate
        // (WS-05-F03). Resetting to the default ("Unclear", no candidate) lets the first fresh
        // observation adopt its own label immediately.
        tracking.display = DisplayState()
        tracking.gaitStretch = nil
        tracking.postureEvidence = nil
        tracking.noPulseStillS = nil
    }

    // MARK: Posture honesty (hsmm-1.8)

    /// Seated-vs-upright evidence cap: an adopted personal profile that adapts a stationary mode was validated on
    /// the wearer's own held-out runs, so it may carry more.
    private var postureCapSU: Double {
        let personal = config.personalProfile?.modes.keys.contains { ["bedRest", "seated", "upright"].contains($0) } ?? false
        return personal ? ActivityContextModel.postureEvidenceCapSUPersonal : ActivityContextModel.postureEvidenceCapSU
    }

    private typealias Evidence = ActivityContextModel.PostureEvidence

    private mutating func decayPostureEvidence(seconds: Int) {
        guard seconds > 0, var e = tracking.postureEvidence else { return }
        for i in e.indices { e[i] *= exp(-Double(seconds) / Evidence.taus[i]) }
        tracking.postureEvidence = e
    }

    /// The memory's seated-over-upright total and recumbent total (0 without a memory).
    private var postureEvidenceTotals: (seated: Double, recumbent: Double) {
        guard let e = tracking.postureEvidence else { return (0, 0) }
        let k = Evidence.recumbentStart
        let su = e[0..<k].reduce(0, +), rec = e[k...].reduce(0, +)
        let capRec = ActivityContextModel.postureEvidenceCapRecumbent
        return (min(postureCapSU, max(-postureCapSU, su)), min(capRec, max(-capRec, rec)))
    }

    /// The posture split inside the stationary modes may lean only as far as real posture evidence supports.
    ///
    /// The dwell priors (seated 900 s, upright 100 s, bed rest 1800 s) are about how long a posture lasts once
    /// it is known. On a wrist that cannot see the posture they used to decide it: quiet standing decayed into
    /// confident sitting within two minutes, any stillness slid toward recumbent after half an hour, and the
    /// lean tracked the time since walking identically for people sitting and standing (D7: AUC 0.52-0.6).
    /// So each second the evidence that does tell postures apart (arm pattern, encoder, held forearm
    /// orientation, a shift's direction, an adopted personal profile; sleep and the in-bed window for
    /// recumbent) is folded into a decaying memory, capped because consecutive seconds are not independent,
    /// and the belief is clamped to it: ln(seated / upright) within a small slack of the evidence, and
    /// recumbent at most `recumbentShareFloor` × e^E of sitting + standing. The total stationary mass, and so
    /// every moving / stationary claim, is untouched; with no posture evidence the heads stay hedged and the
    /// published class is `stationary`.
    private mutating func boundPosture(_ score: ActivityContextModel.Score, _ f: ActivityFeatures,
                                       sleep: SleepEvidence, inBed: Bool) {
        var memory = tracking.postureEvidence ?? [Double](repeating: 0, count: Evidence.caps.count)
        let fresh = score.postureEvidence.values
        // Moving about makes what was known about the posture before obsolete: the memory fades fast while the
        // body is in a moving mode (about 3 s at full belief), so a walk resets it.
        let post = bodyPosterior()
        var moving = 0.0
        for m in 0..<BodyMode.count where !(BodyMode(rawValue: m)!.isStationary || BodyMode(rawValue: m)!.isTransition
                                            || m == BodyMode.unknown.rawValue) { moving += post[m] }
        // So does a movement burst the shift heuristic did not resolve (a transition it missed must not leave the
        // old posture asserted for minutes): a burst well above the wearer's own background (desk work and
        // fidgets are not bursts here) that left the wrist somewhere else over the last 30 s.
        let burstBar = max(0.5, (f.mMed30 ?? 0) + 0.2)
        let burst = acSigmoid(((f.mBurst10 ?? 0) - burstBar) / 0.05) * (1 - min(1, f.gaitPresence ?? 0))
            * acSigmoid(((f.net30 ?? 0) - 25) / 5)
        let shift = ActivityContextModel.shiftStrength(f)
        // A posture shift whose direction the forearm axis cannot tell (a roll about the forearm) may have
        // changed the posture either way: what was known before it fades too, and the transition modes decide.
        var clarity = 0.0
        if let a = f.shiftFromUx, let b = f.shiftToUx {
            let v = ActivityContextModel.shiftDirection(from: a, to: b)
            clarity = min(1, abs(log(v[BodyMode.standToSit.rawValue] / v[BodyMode.sitToStand.rawValue])) / log(4))
        }
        let movingFade = 1 - 0.3 * min(1, max(0, moving))
        let burstFade = 1 - 0.15 * burst * (1 - shift)
        let direction = 2  // index of the direction source in `Evidence.values`
        for i in memory.indices {
            // Bursts fade the sitting / standing memory only: turning over or getting out of bed is the
            // transition modes' call, and the night stays recumbent evidence until then. A shift makes what the
            // arm, the orientation and the learned heads said before it stale whichever way it went; the
            // direction memory itself fades only when the shift's own direction is unclear. Getting up ends
            // the recumbent evidence (the night included) as fast as it is believed.
            let shiftFade = i == direction ? 1 - 0.25 * shift * (1 - clarity) : 1 - 0.25 * shift
            let fade = i < Evidence.recumbentStart ? movingFade * burstFade * shiftFade
                : movingFade * (1 - 0.5 * min(1, post[BodyMode.gettingUp.rawValue] / 0.3))
            memory[i] = min(Evidence.caps[i], max(-Evidence.lowerCaps[i], memory[i] * exp(-1 / Evidence.taus[i]) * fade + fresh[i]))
        }
        // The staged night (asleep, or awake inside its in-bed window) is recumbent evidence in full.
        let night = sleep == .asleep || inBed
        if night { memory[Evidence.night] = Evidence.caps[Evidence.night] }
        tracking.postureEvidence = memory
        let (eSU, eRec) = postureEvidenceTotals

        func mass(_ m: BodyMode) -> Double {
            let start = bodyLayout.start[m.rawValue]
            var t = 0.0
            for j in 0..<bodyLayout.phases[m.rawValue] { t += body[start + j] }
            return t
        }
        func scale(_ m: BodyMode, _ k: Double) {
            let start = bodyLayout.start[m.rawValue]
            for j in 0..<bodyLayout.phases[m.rawValue] { body[start + j] *= k }
        }
        var seated = mass(.seated), upright = mass(.upright)
        let slack = ActivityContextModel.postureNeutralSlack, c0 = ActivityContextModel.postureNeutralLean
        if seated > 0, upright > 0 {
            let lean = log(seated / upright) - c0
            // The split follows the evidence: never past it (or past the slack when there is none), and the
            // dwell prior may pull it back toward neutral only by the slack.
            let hi = eSU >= 0 ? max(eSU, slack) : eSU + slack
            let lo = eSU <= 0 ? min(eSU, -slack) : eSU - slack
            let target = min(hi, max(lo, lean))
            if target != lean {
                let total = seated + upright
                let s = total / (1 + exp(-(target + c0)))
                scale(.seated, s / seated); scale(.upright, (total - s) / upright)
                seated = s; upright = total - s
            }
        }
        guard !night else { return }
        let bed = mass(.bedRest), su = seated + upright
        let ratio = ActivityContextModel.recumbentShareFloor * exp(max(0, eRec))
        let ceiling = (bed + su) * ratio / (1 + ratio)
        if bed > ceiling {
            let excess = bed - ceiling
            scale(.bedRest, ceiling / bed)
            // The excess goes to sitting / standing in their current split (an even posture head when there
            // is none yet, e.g. straight out of a night spent in bed rest).
            let share = su > 1e-9 ? seated / su : 1 / (1 + exp(-ActivityContextModel.postureNeutralLean))
            func add(_ m: BodyMode, _ amount: Double) {
                let start = bodyLayout.start[m.rawValue]
                let k = bodyLayout.phases[m.rawValue]
                var t = 0.0
                for j in 0..<k { t += body[start + j] }
                if t > 1e-12 { for j in 0..<k { body[start + j] += amount * body[start + j] / t } }
                else { body[start] += amount }
            }
            add(.seated, excess * share); add(.upright, excess * (1 - share))
        }
    }

    /// Mix the belief toward the re-acquisition prior after a data gap, by its length.
    private mutating func flattenAfterGap(_ gap: Int) {
        let alpha = 1 - exp(-Double(gap - Self.gapFlattenOnsetS) / Self.gapFlattenScaleS)
        let prior = bodyLayout.expand(ActivityContextModel.prior)
        for i in body.indices { body[i] = (1 - alpha) * body[i] + alpha * prior[i] }
        if let e = tracking.postureEvidence { tracking.postureEvidence = e.map { $0 * (1 - alpha) } }
    }

    private mutating func predictBody(shift: Double, ts: Int,
                                      expert: (q: Double, p: [BodyMode: Double])? = nil) {
        var next = [Double](repeating: 0, count: bodyLayout.total)
        // Entry into recumbent modes: free in the night's in-bed window (lying awake in bed is still lying,
        // D1-04), otherwise damped by the sleep evidence and opened again by held recumbent evidence (a
        // forearm held flat or a hand raised for minutes: a daytime lie-down, D2-06).
        let support = max(0, min(1, postureEvidenceTotals.recumbent / ActivityContextModel.postureEvidenceCapRecumbent))
        let exitTable: [[(Int, Double)]]
        if tracking.lastInBed {
            exitTable = bodyLayout.exits(for: .asleep)
        } else if support > 0 {
            let base = ActivityContextModel.bedEntryScale(tracking.lastSleep)
            let k = base + (1 - base) * 0.8 * support
            exitTable = k >= 1 ? bodyLayout.exits(for: .asleep) : BodyLayout.scaled(bodyLayout.exits(for: .asleep), by: k)
        } else {
            exitTable = bodyLayout.exits(for: tracking.lastSleep)
        }
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
            // Just out of the night's bed, a burst from sitting is getting up, not standing up from a chair.
            let afterBed = !tracking.lastInBed && (tracking.lastInBedTs.map { ts - $0 <= Self.afterBedS } ?? false)
            divert(.seated, afterBed ? .gettingUp : .sitToStand, 1.0)
            divert(.upright, .standToSit, 1.0)
            // hsmm-1.8: the direction a burst went is decided by its evidence (the forearm axis at both ends),
            // not only by where the belief's mass was: a share also goes the "other" way, so a stand-up the
            // decoder missed does not make the next sit-down invisible (D7: direction right 15 of 35).
            divert(.seated, .standToSit, 0.3)
            divert(.upright, .sitToStand, 0.3)
            // hsmm-1.8: lying down has its own direction evidence now (it ends with the forearm flat or the hand
            // raised), so its share of the burst no longer has to be held far below sitting down.
            divert(.seated, .lyingDown, 0.4)
            divert(.upright, .lyingDown, 0.3)
            // Turning over in bed looks the same from the wrist, so while the band says asleep a burst is
            // much more likely a roll than a get-up.
            divert(.bedRest, .gettingUp, tracking.lastSleep == .asleep ? 0.35 : 1.0)
        }
        // A confident, non-abstained transition-expert window raises the hazard too, and its direction comes
        // from its own class probabilities, not from where the belief's mass is (D2V-01, D2-12): the
        // expert can see a return or a bob-up the gravity heuristic cannot.
        if let expert {
            let h = min(0.5, ActivityContextModel.shiftHazard * expert.q)
            let kinds: [BodyMode] = [.sitToStand, .standToSit, .lyingDown, .gettingUp]
            for from in [BodyMode.seated, .upright, .bedRest] {
                let s0 = bodyLayout.start[from.rawValue]
                var pool = 0.0
                for j in 0..<bodyLayout.phases[from.rawValue] {
                    let d = next[s0 + j] * h
                    next[s0 + j] -= d
                    pool += d
                }
                for k in kinds { next[bodyLayout.start[k.rawValue]] += pool * (expert.p[k] ?? 0) }
            }
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
        // HART's fine head names what the hand is doing (typing, eating, clapping, a ball sport) where the
        // movement pattern only sees its shape; both are likelihoods of the same arm state.
        let hart = ActivityContextModel.armEncoder(f)
        var total = 0.0
        for i in 0..<ArmState.count {
            arm[i] *= pow(max(1e-6, q[i]), tau)
            if let hart { arm[i] *= pow(hart.likelihood[i], tau * hart.weight) }
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
        let transitionTotal = kinds.reduce(0.0) { $0 + post[$1.0.rawValue] }
        if var active = tracking.activePostural {
            let i = tracking.events.lastIndex(where: { $0.kind == active.kind && $0.ts == active.ts })
            var mass = post[kinds.first { $0.1 == active.kind }!.0.rawValue]
            // Until a published state has shown it, the event follows the direction that comes to lead
            // (hsmm-1.8: a burst is no longer assigned a direction up front, so it may resolve a second or two
            // after the excursion began). Once shown it keeps its kind, so no reader ever sees two.
            // (A kind takes over only by exceeding the current kind's PEAK, so the event names the direction
            // whose mass rose highest, not whichever lingers last.)
            if active.shown != true, let best = kinds.max(by: { post[$0.0.rawValue] < post[$1.0.rawValue] }),
               best.1 != active.kind, post[best.0.rawValue] > active.probability {
                active.kind = best.1
                mass = post[best.0.rawValue]
                active.probability = mass
                tracking.activePostural = active
                if let i { tracking.events[i].kind = best.1; tracking.events[i].probability = mass }
            }
            if mass > active.probability {
                active.probability = mass
                tracking.activePostural = active
                if let i { tracking.events[i].probability = mass }
            }
            if transitionTotal < Self.posturalEventFloor / 2 {
                if active.shown != true, let i = tracking.events.lastIndex(where: { $0.kind == active.kind && $0.ts == active.ts }) {
                    tracking.showNext = tracking.events[i]
                }
                tracking.activePostural = nil
            }
        } else if let hit = kinds.max(by: { post[$0.0.rawValue] < post[$1.0.rawValue] }),
                  // hsmm-1.8: the floor is on the transition modes' summed mass. A burst whose direction is
                  // still open now spreads over the kinds, and a change of position must not vanish because no
                  // single direction reached the floor; the event names the leading kind at its own mass.
                  transitionTotal >= Self.posturalEventFloor {
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

        // The event field shows only fresh events. hsmm-1.8: a postural event is held back for its first
        // `posturalEventSettleS` seconds (its direction may still resolve), and then shown even if a later event
        // arrived meanwhile, so the one-event-per-state field never drops a change of position.
        let hold = config.eventHoldS
        let isFresh = { (e: ActivityTransitionEvent) in ts - e.ts <= hold && ts >= e.ts }
        var fresh: ActivityTransitionEvent?
        var decided = false
        if let next = tracking.showNext {
            tracking.showNext = nil
            if isFresh(next) { fresh = next; decided = true }
        }
        if !decided, let active = tracking.activePostural, active.shown != true {
            let isActive = { (e: ActivityTransitionEvent) in e.kind == active.kind && e.ts == active.ts }
            if ts - active.ts >= Self.posturalEventSettleS, let event = tracking.events.last(where: isActive) {
                fresh = event
                tracking.activePostural?.shown = true
            } else {
                fresh = tracking.events.last { isFresh($0) && !isActive($0) }
            }
            decided = true
        }
        if !decided { fresh = tracking.events.last(where: isFresh) }

        let wearValidity: Double
        switch tracking.lastWear {
        case .onWrist: wearValidity = 1
        case .offWrist: wearValidity = 0
        case .unknown: wearValidity = evidence.heartRate ? 0.9 : 0.5
        }

        let gaitReading = tracking.lastGait.map {
            ActivityGaitReading(probability: $0.gaitProb, isGait: $0.isGait,
                                cadenceSpm: $0.isGait ? $0.cadenceSpm : nil, speedMps: $0.isGait ? $0.speedMps : nil,
                                ageS: tracking.lastGaitAgeS ?? 0, model: $0.modelVersion)
        }

        return ActivityContextState(
            ts: ts, posture: postureHead, locomotion: locoHead, armBehavior: armHead,
            intensity: tracking.lastIntensity, transition: fresh, sleep: sleep,
            wear: WearContext(state: wearState, validity: wearValidity),
            overallConfidence: confidence, overallUncertainty: uncertainty,
            headConfidence: headConf,
            displayContext: label == ActivityDisplay.unclear ? nil : label,
            history: history, evidence: evidence, versions: versions,
            gait: gaitQuality == nil ? nil : tracking.gaitStretch.map(\.summary),
            gaitReading: gaitReading)
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
        // "Asleep" is the stager's call, already smoothed: once the staged sleep says awake the label follows at
        // once rather than waiting out the 30 s refinement hold inside the lying kind (D2-17).
        if d.label == "Asleep", tracking.lastSleep != .asleep { d.label = raw; clear(); return d.label }

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

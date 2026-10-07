import Foundation
import WhoopProtocol

// HRVWindow.swift — canonical, fixed-duration HRV observations, standardized for comparison.
//
// `ActivityContextInterval` answers "what did HR/HRV look like while the wearer was doing X" over a
// behavioural stretch whose length varies with how long X lasted (60 s to 15 min). That is the right
// granularity for a behavioural label, but it means two RMSSD numbers from two different intervals are
// not directly comparable to each other: a 90 s RMSSD and a 12 min RMSSD are not the same kind of
// measurement, because the length of the window a successive-difference statistic is computed over
// changes its own noise floor. `HRVWindow` is the other granularity: a FIXED, canonical duration — 5
// minutes by default, with a 2-minute secondary and a 1-minute exploratory population available for
// callers that want finer time resolution — so RMSSD_5m always compares against RMSSD_5m, never against
// RMSSD_90s. The three durations are deliberately never mixed into one population; a caller that needs
// several must keep them in separate series.
//
// A `HRVWindow` carries the activity label as METADATA (`activityContext`/`activityConfidence`), not as
// the thing that decides whether the window is trustworthy. Eligibility is decided from signal quality —
// RR validity, artifact fraction, motion magnitude, proximity to a behavioural transition, wear state —
// so a quiet stretch inside a nominally "light activity" label is not refused on sight, and a bursty
// stretch inside a nominally "sitting" label is not waved through. The semantic label is for a reader (or
// a downstream query) to filter or group by; it never gates physiological trust here. What the lookup
// DOES gate is regime and settling: a window that is asleep, of unknown wear, contains a transition, has
// no transition-event data at all, or starts too soon after locomotion/exercise is never a resting
// awake baseline observation.
//
// RMSSD and SDNN are computed independently from the SAME cleaned beats and are never derived from one
// another or compared to each other's raw values (see `ActivityContextAggregate.swift`'s header for why
// RMSSD specifically does not average). `rrDiffSqSumMs2`/`rrDiffCount` are retained so a caller that
// deliberately wants to recombine RMSSD across CONTIGUOUS, COMPATIBLE windows (same kind, no gap) can do
// so correctly; `meanNN`/`nnM2` are retained as the Chan's-parallel-variance components for a caller that
// deliberately wants to recombine variance — but this file does not do either recombination itself, and
// generally recombining SDNN across windows is something to avoid: SDNN is sensitive to recording
// duration, so a merged SDNN is not comparable to either window's own SDNN.

// MARK: - Window kind

/// A canonical HRV window duration. The three are deliberately never mixed into one comparison population.
public enum HRVWindowKind: String, Equatable, Sendable, CaseIterable {
    /// The comparison population: use this unless a caller has a specific reason not to.
    case canonical5m = "canonical_5m"
    case secondary2m = "secondary_2m"
    case exploratory1m = "exploratory_1m"

    public var durationSeconds: Int {
        switch self {
        case .canonical5m: return 300
        case .secondary2m: return 120
        case .exploratory1m: return 60
        }
    }
}

// MARK: - Signal quality

/// What a window's own R-R coverage and beat-accuracy say about whether its beat-to-beat statistics can
/// be trusted at all, independent of how many of its beats survived cleaning. Mirrors the gates
/// `ActivityContextIntervalBuilder.rmssd` already applies per interval, surfaced here as data rather than
/// a pass/fail so a caller can see WHY a window withheld its RMSSD/SDNN.
public struct HRVSignalQuality: Equatable, Sendable {
    public var coverageVerdict: HRVAnalyzer.RrCoverageVerdict?
    public var beatAccurateFraction: Double?
    /// True when BOTH the successive-difference gate and the beat-value gate pass. RMSSD/SDNN are nil
    /// whenever this is false — withheld, never shown approximately.
    public var trustworthy: Bool

    public init(coverageVerdict: HRVAnalyzer.RrCoverageVerdict?, beatAccurateFraction: Double?, trustworthy: Bool) {
        self.coverageVerdict = coverageVerdict
        self.beatAccurateFraction = beatAccurateFraction
        self.trustworthy = trustworthy
    }
}

// MARK: - Window

/// One canonical-duration HRV observation.
public struct HRVWindow: Equatable, Sendable {
    public var kind: HRVWindowKind
    /// Unix seconds, inclusive.
    public var start: Int
    /// Unix seconds, exclusive.
    public var end: Int
    public var durationSeconds: Int { end - start }

    // Beat-to-beat, each computed independently from the same cleaned NN series.
    /// RMSSD in ms; nil unless enough clean, trustworthy beats exist.
    public var rmssd: Double?
    /// SDNN (sample SD, ddof=1) in ms; nil under the same conditions as `rmssd`. Never derived from it.
    public var sdnn: Double?
    public var meanNN: Double?
    public var medianNN: Double?
    /// Sum of squared successive NN differences behind `rmssd` (ms²), UNROUNDED; 0 when `rmssd` is nil.
    public var rrDiffSqSumMs2: Double
    /// Successive-difference pairs behind `rrDiffSqSumMs2`; 0 when `rmssd` is nil.
    public var rrDiffCount: Int
    /// Sum of squared deviations from `meanNN` over the clean NN series (Chan's `M2`); nil when `meanNN`
    /// is nil. `sdnn == sqrt(nnM2 / (validRRCount - 1))` when both are present — retained for a caller that
    /// deliberately wants to recombine variance across windows via Chan's parallel formula; this file
    /// never does that recombination itself.
    public var nnM2: Double?

    /// Clean NN intervals the beat-to-beat statistics were computed from (0 when none).
    public var validRRCount: Int
    /// Fraction of this window's input beats dropped by range/ectopic cleaning; nil when the window had no
    /// R-R data to measure at all (absence of evidence, not a clean window).
    public var artifactFraction: Double?
    public var signalQuality: HRVSignalQuality

    // Motion. nil, never 0, when no motion stream overlapped the window — absence of a reading is not
    // evidence of stillness.
    /// RMS of gravity-removed acceleration magnitude over the window, g.
    public var motionRmsG: Double?
    /// RMS gyroscope magnitude over the window, deg/s; nil until a caller supplies IMU window features
    /// (there is no always-on 1 Hz gyro stream to fall back to the way `motionRmsG` falls back to
    /// `GravitySample.dynAccel`).
    public var gyroRmsDps: Double?

    // Context — describes the window, never gates it (see file header).
    public var activityContext: ActivityClass?
    /// Share of the window's classified time spent in `activityContext`; nil when nothing was classified.
    public var activityConfidence: Double?
    /// Six-state wear-signal interpretation context (feat/wear-signal-quality V1), optional and additive:
    /// nil (no wear signal resolved), `.onWristGood` and `.unknown` leave the existing eligibility rules
    /// exactly unchanged (unknown never upgrades confidence); `.onWristLoose`, `.motionArtifact`,
    /// `.offWrist` and `.sensorDropout` make the window ineligible for a resting baseline (spec §10 —
    /// loose/artifact and off-wrist/optical-corrupted stretches feed garbage into HRV/RHR baselines).
    /// Unlike the SEMANTIC `activityContext` label above, this is signal quality, so it does gate trust.
    public var wearSignal: WearSignalState?

    // Lookback. Every "seconds since" is measured from the window START (a transition or a walk inside
    // the window must not be invisible just because the window ran on long enough after it) and is 0
    // when the thing falls inside the window.
    /// Seconds from the most recent transition event of ANY kind to the window start; 0 when one falls
    /// inside the window; nil when none is known.
    public var secondsSinceTransition: Int?
    /// Seconds since the wearer last walked/ran/cycled (from the activity lookup); 0 when that overlaps
    /// the window; nil when nothing in the lookup matches or there is no lookup.
    public var secondsSinceLocomotion: Int?
    /// Seconds since the last vigorous-activity stretch (from the activity lookup), same convention.
    public var secondsSinceExercise: Int?
    /// `secondsSinceTransition` restricted to POSTURAL events (sit/stand/lie down/get up).
    public var secondsSincePosturalTransition: Int?
    /// `secondsSinceTransition` restricted to LOCOMOTION events (walk/run start/stop).
    public var secondsSinceLocomotionTransition: Int?
    /// Transition events (any kind) whose onset falls inside the window. Any > 0 makes `phase`
    /// `.transition` and the window ineligible.
    public var transitionsInWindow: Int
    /// Whether the caller had decoded transition-event data for this span at all. False means "no event
    /// data", not "no events": `phase` is then `.unknown` and the window is never baseline-eligible.
    public var transitionEventsAvailable: Bool
    /// Where this window sits relative to the nearest known transition, measured from its start.
    public var phase: ActivityPhysiologyPhase
    /// Whether any part of the window was asleep (decoder sleep state or a `sleeping` stretch); nil when
    /// no activity lookup was supplied, so sleep is unknown.
    public var asleep: Bool?
    /// Wear over the window from the activity lookup: `.offWrist` if any stretch was off-wrist,
    /// `.onWrist` if on-wrist stretches cover at least half of it, otherwise `.unknown`; nil without a
    /// lookup.
    public var wear: WearContextState?

    /// Whether this window should be folded into a resting physiological baseline. False whenever
    /// `rmssd` is nil, whenever `phase != .steadyState` (a transition, recovery or unknown-phase window
    /// is real physiology but not resting physiology), whenever the window is asleep or its wear is not
    /// known on-wrist, whenever it is too soon after locomotion/exercise, and whenever motion/wear data
    /// say the wrist was not actually still. See `HRVWindowBuilder.isEligibleForBaseline`.
    public var eligibleForBaseline: Bool

    public init(kind: HRVWindowKind, start: Int, end: Int, rmssd: Double?, sdnn: Double?, meanNN: Double?,
               medianNN: Double?, rrDiffSqSumMs2: Double, rrDiffCount: Int, nnM2: Double?, validRRCount: Int,
               artifactFraction: Double?, signalQuality: HRVSignalQuality, motionRmsG: Double?,
               gyroRmsDps: Double?, activityContext: ActivityClass?, activityConfidence: Double?,
               secondsSinceTransition: Int?, secondsSinceLocomotion: Int?, secondsSinceExercise: Int?,
               phase: ActivityPhysiologyPhase, eligibleForBaseline: Bool,
               wearSignal: WearSignalState? = nil,
               secondsSincePosturalTransition: Int? = nil, secondsSinceLocomotionTransition: Int? = nil,
               transitionsInWindow: Int = 0, transitionEventsAvailable: Bool = true,
               asleep: Bool? = false, wear: WearContextState? = .onWrist) {
        self.kind = kind; self.start = start; self.end = end
        self.rmssd = rmssd; self.sdnn = sdnn; self.meanNN = meanNN; self.medianNN = medianNN
        self.rrDiffSqSumMs2 = rrDiffSqSumMs2; self.rrDiffCount = rrDiffCount; self.nnM2 = nnM2
        self.validRRCount = validRRCount; self.artifactFraction = artifactFraction
        self.signalQuality = signalQuality
        self.motionRmsG = motionRmsG; self.gyroRmsDps = gyroRmsDps
        self.activityContext = activityContext; self.activityConfidence = activityConfidence
        self.secondsSinceTransition = secondsSinceTransition
        self.secondsSinceLocomotion = secondsSinceLocomotion
        self.secondsSinceExercise = secondsSinceExercise
        self.phase = phase
        self.eligibleForBaseline = eligibleForBaseline
        self.wearSignal = wearSignal
        self.secondsSincePosturalTransition = secondsSincePosturalTransition
        self.secondsSinceLocomotionTransition = secondsSinceLocomotionTransition
        self.transitionsInWindow = transitionsInWindow
        self.transitionEventsAvailable = transitionEventsAvailable
        self.asleep = asleep; self.wear = wear
    }
}

// MARK: - Builder

public enum HRVWindowBuilder {

    public struct Config: Equatable, Sendable {
        /// Clean beats a window needs before RMSSD/SDNN are reported at all (same floor as the nightly
        /// path, `HRVAnalyzer.minBeats`).
        public var minBeats = HRVAnalyzer.minBeats
        /// A window whose cleaning rejected more than this fraction of its input beats is never eligible
        /// for a baseline, even if `minBeats` clean beats survived — too much of it was noise.
        public var maxArtifactFraction = 0.3
        /// Motion ceiling for baseline eligibility, g RMS. 0.03 ≈ `ActivityIntensity.scale` intensity 0.31
        /// — a touch above this strap's resting-wrist anchor (≈0.007 g), comfortably under a committed
        /// walk (≈0.135 g median).
        public var maxMotionRmsG = 0.03
        /// Gyroscope ceiling for baseline eligibility, deg/s RMS. A provisional figure (no gyro-RMS
        /// corpus exists yet for this strap): wide enough not to reject on an untuned number while the
        /// on-device IMU pipeline that would populate `gyroRmsDps` is still being wired up (nil here is far
        /// more common today than a real measurement, and nil never penalizes — see `HRVWindow.gyroRmsDps`).
        public var maxGyroRmsDps = 15.0
        /// Seconds after a transition during which a window is excluded outright.
        public var transitionGuardS = ActivityTransitionProximity.defaultTransitionS
        /// Seconds after a transition during which a window is included but not baseline-eligible.
        public var recoveryGuardS = ActivityTransitionProximity.defaultRecoveryS
        /// Minimum seconds between the end of walking/running/cycling and the window start. Postural
        /// settling takes 1-2 min (Bourdillon 2017); HR/HRV after even light locomotion settles more
        /// slowly, so this is longer than `recoveryGuardS`.
        public var minSinceLocomotionS = 300
        /// Minimum seconds between the end of vigorous activity and the window start. Matches the
        /// policy's and the PC engine's 600 s post-bout exclusion; vagal recovery after hard effort is
        /// far longer (Stanley 2013), so this is a floor, not a recovery model.
        public var minSinceExerciseS = 600
        /// Transition events are stamped when the causal decoder FLAGGED them, a few seconds after the
        /// onset (≈2-7 s). An event flagged up to this long after a window's end is treated as having
        /// started inside it.
        public var eventDetectionLagS = 7
        public init() {}
    }

    /// Per-window wear-signal resolution: the worst NON-NIL epoch state covering each window,
    /// in authority order (off_wrist / sensor_dropout beat artifact beat loose; `nil` epochs
    /// never fabricate a downgrade — a window whose covering epochs are all nil/unknown-good
    /// keeps `wearSignal` nil and the pre-existing gates alone). Additive V1: callers that do
    /// not pass epochs get the unchanged `wearSignal`-parameter behavior.
    public static func resolveWearSignal(epochs: [ActivityEpoch], windowStart: Int, windowEnd: Int) -> WearSignalState? {
        let order: [WearSignalState] = [.offWrist, .sensorDropout, .motionArtifact, .onWristLoose]
        var seen: Set<WearSignalState> = []
        for e in epochs where e.endTs > windowStart && e.startTs < windowEnd {
            if let s = e.wearSignal { seen.insert(s) }
        }
        return order.first { seen.contains($0) }
    }

    /// Build every full `kind`-duration window inside `[dayStart, dayEnd)`, aligned to `dayStart`. A
    /// trailing stretch shorter than a full window is dropped: a canonical population is only canonical
    /// if every member is actually `kind.durationSeconds` long. A window with no R-R data at all is
    /// skipped rather than emitted empty — this never invents an observation.
    ///
    /// - Parameters:
    ///   - rr: raw R-R intervals for the whole span; sliced per window, so each window's cleaning and
    ///     successive differences are computed from ITS OWN beats only. No successive difference is ever
    ///     formed across a window boundary (each slice is cleaned independently) or across a real gap
    ///     inside a window (`HRVAnalyzer.cleanRRGapAware` tracks that).
    ///   - imuWindows: short-window IMU features (`accelRmsG`/`gyroRmsDps`) overlapping the span, if any.
    ///   - gravity: 1 Hz gravity/dynAccel samples, the fallback `motionRmsG` source when no `imuWindows`
    ///     overlap a given window.
    ///   - activity: a lookup over the span's behavioural intervals, for `activityContext` and the
    ///     locomotion/exercise lookback. nil leaves those fields nil rather than guessing.
    ///   - transitionEvents: flagged transitions for the span (and some lookback before it — a caller
    ///     should pass at least `recoveryGuardS` seconds of history, or `secondsSinceTransition` reads
    ///     `nil` for a window that is really still inside a transition's wake). nil means NO event data
    ///     (no decoder ran): every window's phase is then `.unknown` and none is baseline-eligible. An
    ///     empty array means the decoder ran and found no transitions.
    ///   - wearSignal: the window's six-state wear-signal interpretation context
    ///     (feat/wear-signal-quality V1), if a caller has resolved one. nil leaves the eligibility rules
    ///     untouched; `.onWristLoose`, `.motionArtifact`, `.offWrist` and `.sensorDropout` make the
    ///     window ineligible for a resting baseline (spec §10).
    public static func build(kind: HRVWindowKind, dayStart: Int, dayEnd: Int, rr: [RRInterval],
                             imuWindows: [ImuWindowFeatures] = [], gravity: [GravitySample] = [],
                             activity: ActivityContextLookup? = nil,
                             transitionEvents: [ActivityTransitionEvent]? = nil,
                             wearSignal: WearSignalState? = nil,
                             config: Config = Config()) -> [HRVWindow] {
        guard dayEnd > dayStart else { return [] }
        let duration = kind.durationSeconds
        let sortedRR = rr.sortedByTsStable()
        var windows: [HRVWindow] = []
        var t = dayStart
        while t + duration <= dayEnd {
            let we = t + duration
            if let w = buildOne(kind: kind, start: t, end: we, rr: sortedRR, imuWindows: imuWindows,
                                gravity: gravity, activity: activity, transitionEvents: transitionEvents,
                                wearSignal: wearSignal, config: config) {
                windows.append(w)
            }
            t = we
        }
        return windows
    }

    /// Epoch-resolved variant: each 5-min window gets the worst non-nil `ActivityEpoch.wearSignal`
    /// covering it (see `resolveWearSignal`), instead of one value for the whole day. Additive.
    public static func build(kind: HRVWindowKind, dayStart: Int, dayEnd: Int, rr: [RRInterval],
                             imuWindows: [ImuWindowFeatures] = [], gravity: [GravitySample] = [],
                             activity: ActivityContextLookup? = nil,
                             transitionEvents: [ActivityTransitionEvent]? = nil,
                             epochWearSignal: [ActivityEpoch],
                             config: Config = Config()) -> [HRVWindow] {
        guard dayEnd > dayStart else { return [] }
        let duration = kind.durationSeconds
        let sortedRR = rr.sortedByTsStable()
        var windows: [HRVWindow] = []
        var t = dayStart
        while t + duration <= dayEnd {
            let we = t + duration
            let resolved = resolveWearSignal(epochs: epochWearSignal, windowStart: t, windowEnd: we)
            if let w = buildOne(kind: kind, start: t, end: we, rr: sortedRR, imuWindows: imuWindows,
                                gravity: gravity, activity: activity, transitionEvents: transitionEvents,
                                wearSignal: resolved, config: config) {
                windows.append(w)
            }
            t = we
        }
        return windows
    }

    private static func buildOne(kind: HRVWindowKind, start: Int, end: Int, rr: [RRInterval],
                                 imuWindows: [ImuWindowFeatures], gravity: [GravitySample],
                                 activity: ActivityContextLookup?, transitionEvents: [ActivityTransitionEvent]?,
                                 wearSignal: WearSignalState?, config: Config) -> HRVWindow? {
        let slice = rr.filter { $0.ts >= start && $0.ts < end }
        guard !slice.isEmpty else { return nil }

        let tsSec = slice.map(\.ts)
        let rawMs = slice.map { Double($0.rrMs) }
        let coverage = HRVAnalyzer.rrCoverage(tsSec: tsSec, rrMs: rawMs)
        let collapsed = HRVAnalyzer.collapsedCoverage(tsSec: tsSec, rrMs: rawMs)
        let verdict = HRVAnalyzer.classifyCoverage(coverage: coverage, collapsed: collapsed)
        let beatAcc = HRVAnalyzer.beatAccurateFraction(tsSec: tsSec, rrMs: rawMs)
        let trustworthy = HRVAnalyzer.successiveDiffIsTrustworthy(verdict)
            && HRVAnalyzer.beatValuesAreTrustworthy(beatAccurateFraction: beatAcc)
        let quality = HRVSignalQuality(coverageVerdict: verdict, beatAccurateFraction: beatAcc, trustworthy: trustworthy)

        let clean = HRVAnalyzer.cleanRRGapAware(rawMs)
        let artifactFraction = 1.0 - Double(clean.nn.count) / Double(slice.count)

        var rmssd: Double?, sdnn: Double?, meanNN: Double?, medianNN: Double?, nnM2: Double?
        var sumSq = 0.0, diffCount = 0
        if trustworthy, clean.nn.count >= config.minBeats {
            let components = HRVAnalyzer.rmssdSumSquaresGapAware(clean.nn, clean.contiguous)
            if components.count >= 1 {
                sumSq = components.sumSq; diffCount = components.count
                rmssd = (sumSq / Double(diffCount)).squareRoot()
            }
            sdnn = HRVAnalyzer.sdnnRaw(clean.nn)
            let m = clean.nn.reduce(0, +) / Double(clean.nn.count)
            meanNN = m
            medianNN = HRVAnalyzer.median(clean.nn)
            nnM2 = clean.nn.reduce(0) { $0 + ($1 - m) * ($1 - m) }
        }

        let motion = motionRms(start: start, end: end, imuWindows: imuWindows, gravity: gravity)
        let gyro = gyroRms(start: start, end: end, imuWindows: imuWindows)

        var activityContext: ActivityClass?, activityConfidence: Double?
        var sinceLocomotion: Int?, sinceExercise: Int?
        var asleep: Bool?, wear: WearContextState?
        if let activity {
            let composition = activity.composition(from: start, to: end)
            if let dominant = composition.dominant {
                activityContext = dominant
                activityConfidence = composition.share(of: dominant)
            }
            sinceLocomotion = secondsSince(start: start, end: end, in: activity) {
                $0.activityClass.isGait || $0.activityClass == .cycling
            }
            sinceExercise = secondsSince(start: start, end: end, in: activity) { $0.activityClass == .vigorousActivity }
            let overlapping = activity.intervals(from: start, to: end)
            asleep = overlapping.contains { $0.sleep == .asleep || $0.activityClass == .sleeping }
            if overlapping.contains(where: { $0.wear == .offWrist || $0.activityClass == .offWrist }) {
                wear = .offWrist
            } else {
                let onWristS = overlapping.filter { $0.wear == .onWrist }
                    .reduce(0) { $0 + max(0, min($1.end, end) - max($1.start, start)) }
                wear = 2 * onWristS >= end - start ? .onWrist : .unknown
            }
        }
        let events = transitionEvents ?? []
        let lag = config.eventDetectionLagS
        let inWindow = events.filter { $0.ts >= start && $0.ts < end + lag }.count
        let sinceTransition = secondsSinceTransition(start: start, end: end, lag: lag, events: events)
        let sincePostural = secondsSinceTransition(start: start, end: end, lag: lag,
                                                   events: events.filter { ActivityTransitionProximity.isPostural($0.kind) })
        let sinceLocoEvent = secondsSinceTransition(start: start, end: end, lag: lag,
                                                    events: events.filter { !ActivityTransitionProximity.isPostural($0.kind) })
        let phase = ActivityTransitionProximity.windowPhase(secondsSinceTransitionAtStart: sinceTransition,
                                                            transitionsInWindow: inWindow,
                                                            eventsAvailable: transitionEvents != nil,
                                                            transitionS: config.transitionGuardS,
                                                            recoveryS: config.recoveryGuardS)

        var window = HRVWindow(
            kind: kind, start: start, end: end, rmssd: rmssd, sdnn: sdnn, meanNN: meanNN, medianNN: medianNN,
            rrDiffSqSumMs2: sumSq, rrDiffCount: diffCount, nnM2: nnM2, validRRCount: clean.nn.count,
            artifactFraction: artifactFraction, signalQuality: quality, motionRmsG: motion, gyroRmsDps: gyro,
            activityContext: activityContext, activityConfidence: activityConfidence,
            secondsSinceTransition: sinceTransition, secondsSinceLocomotion: sinceLocomotion,
            secondsSinceExercise: sinceExercise, phase: phase, eligibleForBaseline: false,
            wearSignal: wearSignal, secondsSincePosturalTransition: sincePostural,
            secondsSinceLocomotionTransition: sinceLocoEvent, transitionsInWindow: inWindow,
            transitionEventsAvailable: transitionEvents != nil, asleep: asleep, wear: wear)
        window.eligibleForBaseline = isEligibleForBaseline(window, config: config)
        return window
    }

    /// The baseline-eligibility predicate, exposed standalone so a caller (or a test) can re-evaluate it
    /// against a window built, or hand-constructed, independently of `build`. Deliberately never looks at
    /// `activityContext`'s SEMANTIC value except as a hard off-wrist check — see the file header. The
    /// lookup is read for REGIME, not label: asleep vs awake, known wear, and how long ago the wearer last
    /// moved, because a resting awake baseline must not mix in sleep or an unsettled post-walk recovery.
    public static func isEligibleForBaseline(_ w: HRVWindow, config: Config = Config()) -> Bool {
        guard w.rmssd != nil else { return false }
        // Context gates (D3-03 / D6-03): a window with any transition inside it, with no event data to
        // tell, asleep or of unknown sleep, of unknown wear, or too soon after locomotion/exercise is
        // real physiology but not a resting AWAKE baseline observation.
        guard w.transitionEventsAvailable, w.transitionsInWindow == 0 else { return false }
        guard w.phase == .steadyState else { return false }
        guard w.asleep == false else { return false }
        guard w.wear == .onWrist || w.wearSignal == .onWristGood, w.wear != .offWrist else { return false }
        if let s = w.secondsSinceLocomotion, s < config.minSinceLocomotionS { return false }
        if let s = w.secondsSinceExercise, s < config.minSinceExerciseS { return false }
        guard (w.artifactFraction ?? 1) <= config.maxArtifactFraction else { return false }
        guard w.signalQuality.trustworthy else { return false }
        guard w.activityContext != .offWrist else { return false }
        // Spec §10 minimum V1 physiology gate (additive): a window carrying a wear-signal state whose
        // `opticalMeasurementQuality` is non-nil — `.onWristLoose` → `.uncertain`, `.motionArtifact` →
        // `.poor`, `.offWrist`/`.sensorDropout` → `.unavailable` — must never feed a resting baseline.
        // nil (no wear signal), `.onWristGood` and `.unknown` keep the pre-existing rules exactly.
        guard w.wearSignal?.opticalMeasurementQuality == nil else { return false }
        if let motion = w.motionRmsG, motion > config.maxMotionRmsG { return false }
        if let gyro = w.gyroRmsDps, gyro > config.maxGyroRmsDps { return false }
        return true
    }

    // MARK: Motion

    /// Quadratic mean (RMS-of-RMS) of `accelRmsG` over every `imuWindows` entry overlapping `[start, end)`,
    /// weighted by its overlap with the window — the correct way to combine several RMS figures over
    /// sub-spans into one RMS over their union. Falls back to the 1 Hz `GravitySample.dynAccel` stream
    /// (plain RMS of the samples inside the window) when no IMU window overlaps. nil when neither source
    /// has anything in range: absence of a motion reading, not zero motion.
    private static func motionRms(start: Int, end: Int, imuWindows: [ImuWindowFeatures], gravity: [GravitySample]) -> Double? {
        var weighted = 0.0, weight = 0.0
        for f in imuWindows {
            let lo = max(start, f.startTs), hi = min(end, f.endTs)
            guard hi > lo else { continue }
            let w = Double(hi - lo)
            weighted += f.accelRmsG * f.accelRmsG * w
            weight += w
        }
        if weight > 0 { return (weighted / weight).squareRoot() }

        let dyn = gravity.compactMap { s -> Double? in
            guard s.ts >= start, s.ts < end, let d = s.dynAccel else { return nil }
            return d
        }
        guard !dyn.isEmpty else { return nil }
        let meanSq = dyn.reduce(0) { $0 + $1 * $1 } / Double(dyn.count)
        return meanSq.squareRoot()
    }

    /// `gyroRmsDps` over `[start, end)`, the gyro twin of `motionRms`'s IMU-window branch. No 1 Hz gyro
    /// stream exists to fall back to, so this is nil whenever no `imuWindows` overlap the window.
    private static func gyroRms(start: Int, end: Int, imuWindows: [ImuWindowFeatures]) -> Double? {
        var weighted = 0.0, weight = 0.0
        for f in imuWindows {
            let lo = max(start, f.startTs), hi = min(end, f.endTs)
            guard hi > lo else { continue }
            let w = Double(hi - lo)
            weighted += f.gyroRmsDps * f.gyroRmsDps * w
            weight += w
        }
        guard weight > 0 else { return nil }
        return (weighted / weight).squareRoot()
    }

    // MARK: Lookback

    /// Seconds from the latest event (flagged before `end + lag`) to the window START; 0 when that event
    /// falls inside the window. nil when there is none.
    private static func secondsSinceTransition(start: Int, end: Int, lag: Int,
                                               events: [ActivityTransitionEvent]) -> Int? {
        let latest = events.filter { $0.ts < end + lag }.map(\.ts).max()
        return latest.map { max(0, start - $0) }
    }

    /// Seconds from the end of the most recent interval matching `predicate` to the window START; 0 when
    /// one overlaps the window. nil when nothing in `activity` before `end` matches.
    private static func secondsSince(start: Int, end: Int, in activity: ActivityContextLookup,
                                     matching predicate: (ActivityContextInterval) -> Bool) -> Int? {
        var best: Int?
        for iv in activity.intervals where predicate(iv) && iv.start < end {
            let since = max(0, start - iv.end)
            if best == nil || since < best! { best = since }
        }
        return best
    }
}

// MARK: - Diagnostics

/// A one-line, human-readable summary of a day's windows for an always-on log — so a caller that wires
/// `HRVWindowBuilder` into a real pipeline has something observable to confirm it ran against live data,
/// without needing a UI or a persisted history. Named plainly (not `hrv diag`): that token is already the
/// nightly sleep-scoring pipeline's own always-on trace line (see `AnalyticsEngine`/`CaptureCompleteness`),
/// a different subsystem with its own parsers; this is the daytime ActivityContext coordinator's line.
public enum HRVWindowSummary {
    public static func diagLine(_ windows: [HRVWindow], kind: HRVWindowKind, day: String) -> String {
        guard !windows.isEmpty else { return "HRV windows for \(day): no \(kind.rawValue) windows (no R-R data)" }
        let eligible = windows.filter(\.eligibleForBaseline)
        let withMotion = windows.filter { $0.motionRmsG != nil }.count
        let withGyro = windows.filter { $0.gyroRmsDps != nil }.count
        func mean(_ xs: [Double]) -> Double? { xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count) }
        var line = "HRV windows for \(day): \(windows.count) \(kind.rawValue) windows, \(eligible.count) eligible for baseline"
        if let r = mean(eligible.compactMap(\.rmssd)), let s = mean(eligible.compactMap(\.sdnn)) {
            line += " (mean rmssd \(oneDecimal(r)) ms, mean sdnn \(oneDecimal(s)) ms)"
        }
        line += ", motion data \(withMotion)/\(windows.count), gyro data \(withGyro)/\(windows.count)"
        return line
    }

    private static func oneDecimal(_ x: Double) -> String { String(format: "%.1f", x) }
}

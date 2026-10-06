import Foundation

// ActivityLabelCandidates.swift — which stretches to ask the wearer about, and why.
//
// The "Help improve activity detection" queue turns a stretch into a question when one of three things is
// true: the model is unsure about it (uncertainty), the two decoders read it differently (disagreement), or
// the day barely saw its class (coverage). This file is the pure selection rule. It takes one minimal,
// decoupled description per stretch (`ActivityCandidateStretchInput`), applies the three triggers
// independently, and returns the ranked queue. No I/O and no clock: the same inputs always give the same
// candidates, so the rule is unit-testable and the UI just calls it with what the timeline already decoded.
//
// Priority is a weighted sum of the triggers that fired:
//     priority = 0.1 (baseline) + 0.5 if uncertain + 0.3 if disagreed + 0.2 if under-covered.
// The weights are the constants below, documented here so the product trade-off is a named decision:
// a confused model is worth asking about most, a model-vs-model clash next, and a rare class least —
// rare classes are still valuable, but a question the wearer can confidently answer comes first.

/// One stretch the queue may ask about. `id` is the same stretch key the answer and the weak label are
/// stored under, so "already answered" tracking and the ground-truth label key share one identity.
public struct ActivityLabelCandidate: Codable, Equatable, Identifiable, Sendable {
    /// Stable key: `"activity_context:<startTs>"` (see `ActivityLabelCandidateSelector.stretchKey`).
    public var id: String
    public var startTs: Int
    public var endTs: Int
    /// Which triggers fired, in the stable order uncertainty → disagreement → coverage.
    public var reasons: [String]
    /// Weighted sum of the fired triggers (see the selector's weight constants). Larger = worth asking first.
    public var priority: Double
    /// The model's display name for the stretch, if any ("Desk sitting", "Unclear").
    public var predictedLabel: String?
    public var deviceId: String?

    public init(id: String, startTs: Int, endTs: Int, reasons: [String], priority: Double,
                predictedLabel: String?, deviceId: String?) {
        self.id = id
        self.startTs = startTs; self.endTs = endTs
        self.reasons = reasons; self.priority = priority
        self.predictedLabel = predictedLabel; self.deviceId = deviceId
    }
}

/// One decoupled description of a stretch the queue may ask about. The UI assembles these from whatever the
/// timeline decoded (episodes, HART windows); the selector never touches the larger model types, so its
/// logic stays plain to reason about and test. Every head field is optional — a missing reading is "no
/// claim", which the uncertainty trigger treats as an abstention.
public struct ActivityCandidateStretchInput: Equatable, Sendable {
    public var startTs: Int
    public var endTs: Int
    public var deviceId: String?
    /// The model's display name for the stretch, if any.
    public var predictedLabel: String?
    /// Canonical class code behind the label, if any (an `ActivityClass` raw value).
    public var predictedClass: String?
    /// The decoder's overall uncertainty in [0, 1]; nil when the source did not report one.
    public var overallUncertainty: Double?
    /// Per-head confidence in [0, 1] (each head's best non-unknown probability); nil per head when absent.
    public var headConfidence: (posture: Double?, locomotion: Double?, armBehavior: Double?)?
    /// Labels of the overlapping HART windows: coarse locomotion codes ("walking", "stationary", …).
    public var hartWindowLabels: [String]
    /// The decoder's locomotion head reading (raw code); nil/unknown when it abstained.
    public var decodedLocomotion: String?
    /// The decoder's posture head reading (raw code); nil/unknown when it abstained.
    public var decodedPosture: String?
    /// The strongest overlapping HART window's top-2 with its probabilities, when the window carried them.
    /// Kept as an explicit small pair instead of a head dictionary so the trigger can be tested plainly.
    public var hartWindowTop2: (first: String, p1: Double, second: String?, p2: Double?)?

    public init(startTs: Int, endTs: Int, deviceId: String? = nil,
                predictedLabel: String? = nil, predictedClass: String? = nil,
                overallUncertainty: Double? = nil,
                headConfidence: (posture: Double?, locomotion: Double?, armBehavior: Double?)? = nil,
                hartWindowLabels: [String] = [],
                decodedLocomotion: String? = nil, decodedPosture: String? = nil,
                hartWindowTop2: (first: String, p1: Double, second: String?, p2: Double?)? = nil) {
        self.startTs = startTs; self.endTs = endTs
        self.deviceId = deviceId
        self.predictedLabel = predictedLabel; self.predictedClass = predictedClass
        self.overallUncertainty = overallUncertainty
        self.headConfidence = headConfidence
        self.hartWindowLabels = hartWindowLabels
        self.decodedLocomotion = decodedLocomotion; self.decodedPosture = decodedPosture
        self.hartWindowTop2 = hartWindowTop2
    }

    /// Manual `==` because the two small helper fields are tuples, and tuple types cannot synthesize
    /// `Equatable` conformance; the comparison itself is field-by-field and total.
    public static func == (lhs: ActivityCandidateStretchInput, rhs: ActivityCandidateStretchInput) -> Bool {
        lhs.startTs == rhs.startTs && lhs.endTs == rhs.endTs && lhs.deviceId == rhs.deviceId
            && lhs.predictedLabel == rhs.predictedLabel && lhs.predictedClass == rhs.predictedClass
            && lhs.overallUncertainty == rhs.overallUncertainty
            && lhs.headConfidence?.posture == rhs.headConfidence?.posture
            && lhs.headConfidence?.locomotion == rhs.headConfidence?.locomotion
            && lhs.headConfidence?.armBehavior == rhs.headConfidence?.armBehavior
            && lhs.hartWindowLabels == rhs.hartWindowLabels
            && lhs.decodedLocomotion == rhs.decodedLocomotion && lhs.decodedPosture == rhs.decodedPosture
            && lhs.hartWindowTop2?.first == rhs.hartWindowTop2?.first
            && lhs.hartWindowTop2?.p1 == rhs.hartWindowTop2?.p1
            && lhs.hartWindowTop2?.second == rhs.hartWindowTop2?.second
            && lhs.hartWindowTop2?.p2 == rhs.hartWindowTop2?.p2
    }
}

public enum ActivityLabelCandidateSelector {

    // MARK: Reason vocabulary — stable strings stored on candidates and matched by the UI queue.

    public static let reasonUncertainty = "uncertainty"
    public static let reasonDisagreement = "disagreement"
    public static let reasonCoverage = "coverage"

    // MARK: Priority weights (documented in the file header).

    public static let baselinePriority = 0.1
    public static let uncertaintyWeight = 0.5
    public static let disagreementWeight = 0.3
    public static let coverageWeight = 0.2

    // MARK: Trigger thresholds.

    /// `overallUncertainty` at or above this fires the uncertainty trigger.
    public static let uncertaintyThreshold = 0.5
    /// Any head confidence below this fires the uncertainty trigger.
    public static let lowHeadConfidenceThreshold = 0.4
    /// A top-2 margin below this fires the uncertainty trigger (the top class barely beat the next).
    public static let top2MarginThreshold = 0.15
    /// At least this share of the comparable overlapping windows must disagree to fire the disagreement trigger.
    public static let disagreementMajority = 0.5
    /// The smallest class share must be at or below this for coverage to fire (a class the day barely saw).
    public static let coverageMaxClassShare = 0.25

    /// The queue never suggests more than this; the UI keeps its own per-day budget on top.
    public static let defaultLimit = 5

    // MARK: Selection

    /// Rank the candidate stretches worth asking about. `answeredKeys` are stretch keys already answered
    /// today (or ever), and are excluded. `now` is reserved for future staleness gating: selection is pure
    /// and deliberately does not depend on the clock. Returns at most `limit` candidates, deterministic:
    /// the same inputs always produce the same queue.
    public static func select(from inputs: [ActivityCandidateStretchInput], answeredKeys: Set<String> = [],
                              limit: Int = defaultLimit, now: Int? = nil) -> [ActivityLabelCandidate] {
        let cap = max(0, limit)
        let shares = coverageShareByClass(inputs)
        var candidates: [ActivityLabelCandidate] = []
        for input in inputs {
            let id = stretchKey(start: input.startTs)
            guard !answeredKeys.contains(id) else { continue }
            var reasons: [String] = []
            if firesUncertainty(input) { reasons.append(reasonUncertainty) }
            if firesDisagreement(input) { reasons.append(reasonDisagreement) }
            if firesCoverage(input, shares: shares) { reasons.append(reasonCoverage) }
            // A stretch with no reason is not a candidate: the queue never asks "for fun".
            guard !reasons.isEmpty else { continue }
            // Rounded to 3 decimals so sums like 0.1 + 0.2 stay exactly the documented weights
            // (0.30000000000000004 would otherwise leak into ordering and exact-equality tests).
            let priority = ((baselinePriority
                + (reasons.contains(reasonUncertainty) ? uncertaintyWeight : 0)
                + (reasons.contains(reasonDisagreement) ? disagreementWeight : 0)
                + (reasons.contains(reasonCoverage) ? coverageWeight : 0)) * 1000).rounded() / 1000
            candidates.append(ActivityLabelCandidate(id: id, startTs: input.startTs, endTs: input.endTs,
                                                     reasons: reasons, priority: priority,
                                                     predictedLabel: input.predictedLabel,
                                                     deviceId: input.deviceId))
        }
        // Deterministic order: highest priority first; ties newest stretch first, then longer, then the key.
        let ordered = candidates.sorted { a, b in
            if a.priority != b.priority { return a.priority > b.priority }
            if a.startTs != b.startTs { return a.startTs > b.startTs }
            if a.endTs != b.endTs { return a.endTs > b.endTs }
            return a.id < b.id
        }
        return cap >= ordered.count ? ordered : Array(ordered.prefix(cap))
    }

    /// The stretch key a candidate and its answer share: the same key `StretchFeedback.key` derives for an
    /// activity-context stretch, so answered tracking and the weak ground-truth label key line up.
    public static func stretchKey(start: Int) -> String {
        StretchFeedback.key(kind: .activityContext, start: start)
    }

    // MARK: Uncertainty

    /// True when the model was unsure: high overall uncertainty, any thin head, a decoder head that
    /// abstained (nil or "unknown"), or a top-2 class margin too small to trust.
    public static func firesUncertainty(_ input: ActivityCandidateStretchInput) -> Bool {
        if let u = input.overallUncertainty, u >= uncertaintyThreshold { return true }
        if let heads = input.headConfidence {
            for value in [heads.posture, heads.locomotion, heads.armBehavior] {
                if let value, value < lowHeadConfidenceThreshold { return true }
            }
        }
        // Moving body modes carry no posture belief by design, so an absent posture only counts as an
        // abstention when the decoded locomotion is still.
        let moving = !isUnknown(input.decodedLocomotion) && input.decodedLocomotion != "stationary"
        if isUnknown(input.decodedLocomotion) || (!moving && isUnknown(input.decodedPosture)) { return true }
        if let top2 = input.hartWindowTop2, let second = top2.second, let p2 = top2.p2,
           top2.p1.isFinite, p2.isFinite, second != "unknown" {
            if top2.p1 - p2 < top2MarginThreshold { return true }
        }
        return false
    }

    /// A head code that is missing or `unknown` is an abstention, never a claim.
    public static func isUnknown(_ raw: String?) -> Bool {
        raw == nil || raw == "unknown"
    }

    // MARK: Disagreement

    /// True when at least half of the overlapping HART windows make a locomotion claim that does not match
    /// the decoder's locomotion head. Windows that abstain (unknown) or say nothing comparable are ignored:
    /// an abstention cannot disagree, and a lone unknown window must not dilute a real clash.
    public static func firesDisagreement(_ input: ActivityCandidateStretchInput) -> Bool {
        guard let decoded = locomotionFamily(input.decodedLocomotion), decoded != "unknown" else { return false }
        var comparable = 0
        var disagreeing = 0
        for label in input.hartWindowLabels {
            guard let family = locomotionFamily(label), family != "unknown" else { continue }
            comparable += 1
            if family != decoded { disagreeing += 1 }
        }
        guard comparable > 0 else { return false }
        return Double(disagreeing) / Double(comparable) >= disagreementMajority
    }

    /// The coarse locomotion family of a raw code. `other_movement` (the HART v1 label) folds into `other`
    /// so the two vocabularies compare; anything else that is not locomotion (or is unknown) is nil.
    public static func locomotionFamily(_ raw: String?) -> String? {
        guard let raw else { return nil }
        switch raw {
        case "stationary", "walking", "brisk_walking", "running", "stairs", "cycling", "vehicle_motion":
            return raw
        case "other", "other_movement":
            return "other"
        case "unknown":
            return "unknown"
        default:
            return nil
        }
    }

    // MARK: Coverage

    /// Share of the classified time each class holds across the whole input set, in [0, 1]. Inputs without
    /// a predicted class contribute nothing (there is no class to rank). Empty input gives an empty map.
    public static func coverageShareByClass(_ inputs: [ActivityCandidateStretchInput]) -> [String: Double] {
        var seconds: [String: Int] = [:]
        var total = 0
        for input in inputs {
            guard let cls = input.predictedClass else { continue }
            let duration = max(0, input.endTs - input.startTs)
            seconds[cls, default: 0] += duration
            total += duration
        }
        guard total > 0 else { return [:] }
        return seconds.mapValues { Double($0) / Double(total) }
    }

    /// True when the stretch's class is the one the input set barely saw: it holds the SMALLEST share of
    /// the classified time, and that share is at or below a quarter. Those are exactly the classes a fresh
    /// label helps most (stairs, brisk walking, cycling…). Inputs with no class never fire (nothing to rank).
    public static func firesCoverage(_ input: ActivityCandidateStretchInput,
                                     shares: [String: Double]) -> Bool {
        guard let cls = input.predictedClass, let share = shares[cls] else { return false }
        guard share <= coverageMaxClassShare else { return false }
        guard let smallest = shares.values.min() else { return false }
        return abs(share - smallest) < 1e-9
    }
}

/// Assembly helpers that turn what the timeline already decoded into candidate inputs. Pure and testable,
/// so the UI stays a thin shell over the selection rule.
public enum ActivityLabelCandidateInputs {

    /// One input per decoded episode. Head confidence is each head's best non-unknown probability (0 when
    /// the head abstained), matching the decoder's published `ActivityHeadConfidence`. HART windows are not
    /// part of the episode shape, so they are left empty here and the queue relies on the decoder's own
    /// uncertainty; callers that hold window data fill `hartWindowLabels` / `hartWindowTop2` afterwards.
    public static func fromEpisodes(_ episodes: [ActivityEpisode], deviceId: String? = nil)
        -> [ActivityCandidateStretchInput] {
        episodes.map { ep in
            let classification = ActivityClassifier.classify(posture: ep.posture, locomotion: ep.locomotion,
                                                             armBehavior: ep.armBehavior, sleep: ep.sleep,
                                                             inBed: ep.inBed, wear: ep.wear,
                                                             evidenceQuality: ep.confidence)
            let still = ep.locomotion.top(excluding: .unknown)?.0 == .stationary
            return ActivityCandidateStretchInput(
                startTs: ep.start, endTs: ep.end, deviceId: deviceId,
                predictedLabel: ep.label,
                predictedClass: classification.activityClass.rawValue,
                overallUncertainty: ep.uncertainty,
                headConfidence: (posture: still ? ep.posture.top(excluding: .unknown)?.1 ?? 0 : nil,
                                 locomotion: ep.locomotion.top(excluding: .unknown)?.1 ?? 0,
                                 armBehavior: ep.armBehavior.top(excluding: .unknown)?.1 ?? 0),
                hartWindowLabels: [],
                decodedLocomotion: ep.locomotion.top(excluding: .unknown)?.0.rawValue,
                decodedPosture: ep.posture.top(excluding: .unknown)?.0.rawValue)
        }
    }
}

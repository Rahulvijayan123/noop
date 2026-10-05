import Foundation

// StretchTarget.swift — one stretch of the day the wearer can open and judge.
//
// The Heart rate page lists two kinds of stretch: episodes from the ActivityContext decoder and segments from
// the strap's own signals. Opening either one needs the same few facts (when it was, what the model called it,
// what it based that on), and a verdict needs them stored next to it. This type is that common shape.

public enum StretchTarget: Equatable, Sendable, Identifiable {
    case activity(ActivityEpisode)
    case strap(DayStateSegment)

    public var kind: StretchKind {
        switch self {
        case .activity: return .activityContext
        case .strap: return .strapState
        }
    }

    public var start: Int {
        switch self {
        case .activity(let e): return e.start
        case .strap(let s): return s.start
        }
    }

    public var end: Int {
        switch self {
        case .activity(let e): return e.end
        case .strap(let s): return s.end
        }
    }

    public var durationSeconds: Int { end - start }

    public var id: String { StretchFeedback.key(kind: kind, start: start) }

    /// The model's name for the stretch, in English and stable across app languages, because it is stored.
    public var predictedLabel: String {
        switch self {
        case .activity(let e): return e.label
        case .strap(let s): return Self.strapLabel(s)
        }
    }

    /// The canonical class code behind the label: an `ActivityClass` for decoder stretches, a `DayState` for
    /// the strap's.
    public var predictedClass: String {
        switch self {
        case .activity(let e):
            return ActivityClassifier.classify(posture: e.posture, locomotion: e.locomotion,
                                               armBehavior: e.armBehavior, sleep: e.sleep, wear: e.wear,
                                               evidenceQuality: e.confidence).activityClass.rawValue
        case .strap(let s): return s.state.rawValue
        }
    }

    /// How sure the model said it was. The strap's own labels carry no confidence.
    public var predictedConfidence: Double? {
        switch self {
        case .activity(let e): return e.confidence
        case .strap: return nil
        }
    }

    static func strapLabel(_ s: DayStateSegment) -> String {
        switch s.state {
        case .sleeping: return "Sleeping"
        case .offWrist: return "Off wrist"
        case .running: return "Running"
        case .walking: return "Walking"
        case .workout: return "Workout"
        case .active: return "Moving"
        case .still: return "Still"
        case .wornUnknown: return "Worn, motion unknown"
        case .noData: return "No data"
        }
    }

    /// The model's reading and its evidence, in the form stored with a verdict. `overlapping` is what the
    /// other source said over the same time, so a label can be judged against both.
    public func modelContext(overlapping: [StretchModelContext.Overlap] = [], runCount: Int? = nil)
        -> StretchModelContext {
        var c = StretchModelContext()
        c.displayLabel = predictedLabel
        c.overlapping = overlapping.isEmpty ? nil : overlapping
        c.runCount = runCount
        switch self {
        case .activity(let e):
            c.confidence = e.confidence
            c.uncertainty = e.uncertainty
            c.posture = Self.thin(e.posture.values)
            c.locomotion = Self.thin(e.locomotion.values)
            c.armBehavior = Self.thin(e.armBehavior.values)
            c.intensity = e.intensity
            c.sleepState = e.sleep.rawValue
            c.wearState = e.wear.rawValue
            c.modelVersions = [
                "ontology": ActivityContextVersions.ontology,
                "decoder": ActivityContextVersions.decoder,
                "feature_schema": ActivityContextVersions.featureSchema,
                "taxonomy": ActivityClassVersions.taxonomy,
            ]
        case .strap(let s):
            c.basis = s.basis.rawValue
            c.avgHr = s.avgHr; c.minHr = s.minHr; c.maxHr = s.maxHr
            c.motionG = s.motionG
            c.stepTicks = s.stepTicks
            c.locomotionShare = s.locomotionShare
            c.workoutSport = s.workoutSport
            c.modelVersions = ["day_state": "ds-1"]
        }
        return c
    }

    private static func thin<C: RawRepresentable>(_ values: [C: Double]) -> [String: Double]?
        where C.RawValue == String {
        let kept = values.filter { $0.value >= 0.02 }
        guard !kept.isEmpty else { return nil }
        return Dictionary(uniqueKeysWithValues: kept.map { ($0.key.rawValue, (($0.value * 1000).rounded()) / 1000) })
    }
}

// MARK: - What the other source said

public enum StretchOverlap {
    /// Seconds of `[start, end)` that each label of the other source covers, longest first, thin slivers dropped.
    public static func activityLabels(over start: Int, _ end: Int, runs: [ActivityContextRun],
                                      minSeconds: Int = 20) -> [StretchModelContext.Overlap] {
        var seconds: [String: Int] = [:]
        for r in runs {
            let s = min(end, r.end) - max(start, r.start)
            guard s > 0 else { continue }
            seconds[r.displayContext ?? ActivityContextEpisodes.unclear, default: 0] += s
        }
        return ranked(seconds, source: StretchKind.activityContext.rawValue, minSeconds: minSeconds)
    }

    public static func strapStates(over start: Int, _ end: Int, segments: [DayStateSegment],
                                   minSeconds: Int = 20) -> [StretchModelContext.Overlap] {
        var seconds: [String: Int] = [:]
        for g in segments {
            let s = min(end, g.end) - max(start, g.start)
            guard s > 0 else { continue }
            seconds[StretchTarget.strapLabel(g), default: 0] += s
        }
        return ranked(seconds, source: StretchKind.strapState.rawValue, minSeconds: minSeconds)
    }

    private static func ranked(_ seconds: [String: Int], source: String, minSeconds: Int)
        -> [StretchModelContext.Overlap] {
        seconds.filter { $0.value >= minSeconds }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(6)
            .map { StretchModelContext.Overlap(source: source, label: $0.key, seconds: $0.value) }
    }
}

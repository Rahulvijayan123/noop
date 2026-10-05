import Foundation

// StretchFeedback.swift — a wearer's verdict on one stretch of the day.
//
// The Heart rate page lists stretches from two sources: the ActivityContext decoder ("Walking", "Sitting at
// a desk") and the strap's own signals ("Still", "Sleeping"). Each can be wrong, and the wearer is the only
// one who knows. A `StretchFeedback` records "this was right" or "this was wrong, it was actually X" together
// with what the model said and the evidence it had, so the labels can later be used to tune the model.

public enum StretchKind: String, Codable, CaseIterable, Sendable {
    case activityContext = "activity_context"
    case strapState = "strap_state"
}

public enum StretchVerdict: String, Codable, Sendable {
    case correct
    case incorrect
}

/// What the wearer says the stretch actually was, when the model got it wrong. Raw values are the wire codes.
public enum StretchCorrection: String, Codable, CaseIterable, Sendable {
    case sitting
    case standing
    case lyingDown = "lying_down"
    case asleep
    case walking
    case running
    case cycling
    case inVehicle = "in_vehicle"
    case exercise
    case otherMovement = "other_movement"
    case notWearing = "not_wearing"
    case other

    public var title: String {
        switch self {
        case .sitting: return "Sitting"
        case .standing: return "Standing"
        case .lyingDown: return "Lying down"
        case .asleep: return "Asleep"
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .inVehicle: return "In a vehicle"
        case .exercise: return "Exercising"
        case .otherMovement: return "Moving about"
        case .notWearing: return "Not wearing the strap"
        case .other: return "Something else"
        }
    }
}

/// The model's output and the evidence behind it for one stretch, kept with the verdict so a label can be
/// joined to what the model believed when it was given. Every field is optional: each source fills its own.
public struct StretchModelContext: Codable, Equatable, Sendable {
    public struct Overlap: Codable, Equatable, Sendable {
        public var source: String
        public var label: String
        public var seconds: Int
        public init(source: String, label: String, seconds: Int) {
            self.source = source; self.label = label; self.seconds = seconds
        }
    }

    public var displayLabel: String?
    public var confidence: Double?
    public var uncertainty: Double?
    /// Head probabilities, thin classes dropped.
    public var posture: [String: Double]?
    public var locomotion: [String: Double]?
    public var armBehavior: [String: Double]?
    public var intensity: Double?
    public var sleepState: String?
    public var wearState: String?
    /// For strap-derived stretches: which signal decided the label.
    public var basis: String?
    public var avgHr: Int?
    public var minHr: Int?
    public var maxHr: Int?
    public var motionG: Double?
    public var stepTicks: Int?
    public var locomotionShare: Double?
    public var workoutSport: String?
    /// How many decoder runs the stretch is made of (1 means there is nothing finer to see in the labels).
    public var runCount: Int?
    /// What the other source said over the same time.
    public var overlapping: [Overlap]?
    public var modelVersions: [String: String]?

    enum CodingKeys: String, CodingKey {
        case displayLabel = "display_label", confidence, uncertainty, posture, locomotion
        case armBehavior = "arm_behavior", intensity
        case sleepState = "sleep_state", wearState = "wear_state", basis
        case avgHr = "avg_hr", minHr = "min_hr", maxHr = "max_hr", motionG = "motion_g"
        case stepTicks = "step_ticks", locomotionShare = "locomotion_share", workoutSport = "workout_sport"
        case runCount = "run_count", overlapping, modelVersions = "model_versions"
    }

    public init() {}
}

public struct StretchFeedback: Codable, Equatable, Identifiable, Sendable {
    public static let maxNoteLength = 280
    public static let maxLabelLength = 64

    /// Client record id, stable across edits of the same stretch.
    public var id: UUID
    /// `"<kind>:<start>"`: re-validating the same stretch replaces the earlier verdict instead of adding one.
    public var stretchKey: String
    public var kind: StretchKind
    /// The app's id for the strap the stretch was recorded on, so the server can join the label to its streams.
    public var deviceId: String?
    public var startTs: Int
    public var endTs: Int
    public var predictedLabel: String
    /// The canonical class code behind `predictedLabel` (an `ActivityClass` raw value or a `DayState` raw value).
    public var predictedClass: String?
    public var predictedConfidence: Double?
    public var verdict: StretchVerdict
    public var correctedLabel: StretchCorrection?
    public var note: String?
    public var context: StretchModelContext
    public var appVersion: String?
    public var appBuild: String?
    public var tzOffsetS: Int?
    public var createdAt: Date
    public var updatedAt: Date
    /// When the server last accepted this record. Compared with `updatedAt` to know whether it still needs sending.
    public var syncedAt: Date?

    public var needsSync: Bool {
        guard let syncedAt else { return true }
        return syncedAt < updatedAt
    }

    public var durationSeconds: Int { endTs - startTs }

    public static func key(kind: StretchKind, start: Int) -> String { "\(kind.rawValue):\(start)" }

    public init(kind: StretchKind, startTs: Int, endTs: Int, deviceId: String?,
                predictedLabel: String, predictedClass: String?, predictedConfidence: Double?,
                verdict: StretchVerdict, correctedLabel: StretchCorrection? = nil, note: String? = nil,
                context: StretchModelContext = StretchModelContext(),
                appVersion: String? = nil, appBuild: String? = nil, tzOffsetS: Int? = nil,
                now: Date = Date(), id: UUID = UUID()) {
        self.id = id
        self.stretchKey = Self.key(kind: kind, start: startTs)
        self.kind = kind
        self.deviceId = deviceId
        self.startTs = startTs; self.endTs = endTs
        self.predictedLabel = String(predictedLabel.prefix(Self.maxLabelLength))
        self.predictedClass = predictedClass.map { String($0.prefix(Self.maxLabelLength)) }
        self.predictedConfidence = predictedConfidence.map { min(1, max(0, $0)) }
        self.verdict = verdict
        // A correction only means something next to a "wrong" verdict.
        self.correctedLabel = verdict == .incorrect ? correctedLabel : nil
        self.note = Self.cleaned(note)
        self.context = context
        self.appVersion = appVersion; self.appBuild = appBuild; self.tzOffsetS = tzOffsetS
        self.createdAt = now; self.updatedAt = now
        self.syncedAt = nil
    }

    /// A new verdict for the same stretch: keeps the record id and first-answered time so the server upserts
    /// one row, takes everything else from `self`'s replacement.
    public func revised(verdict: StretchVerdict, correctedLabel: StretchCorrection?, note: String?,
                        now: Date = Date()) -> StretchFeedback {
        var next = self
        next.verdict = verdict
        next.correctedLabel = verdict == .incorrect ? correctedLabel : nil
        next.note = Self.cleaned(note)
        next.updatedAt = max(now, updatedAt.addingTimeInterval(0.001))
        return next
    }

    /// This record, re-issued as the next answer for the stretch `earlier` already covers: it keeps that
    /// record's id, key and first-answered time so the server updates one row, and is never dated before it.
    /// Everything else (what the model said now, the verdict, the note) comes from `self`.
    public func continuing(_ earlier: StretchFeedback) -> StretchFeedback {
        var next = self
        next.id = earlier.id
        next.stretchKey = earlier.stretchKey
        next.createdAt = earlier.createdAt
        next.updatedAt = max(updatedAt, earlier.updatedAt.addingTimeInterval(0.001))
        next.syncedAt = nil
        return next
    }

    static func cleaned(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNoteLength))
    }
}

// MARK: - Wire form

/// The JSON the `scores` edge function's `POST /stretch-feedback` route takes, one per record.
public struct StretchFeedbackWire: Encodable, Sendable {
    let id: String
    let stretchKey: String
    let kind: String
    let deviceId: String?
    let startTs: Int
    let endTs: Int
    let predictedLabel: String
    let predictedClass: String?
    let predictedConfidence: Double?
    let verdict: String
    let correctedLabel: String?
    let note: String?
    let modelContext: StretchModelContext
    let appVersion: String?
    let appBuild: String?
    let tzOffsetS: Int?
    let clientCreatedAt: String
    let clientUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case id, kind, verdict, note
        case stretchKey = "stretch_key", deviceId = "device_id", startTs = "start_ts", endTs = "end_ts"
        case predictedLabel = "predicted_label", predictedClass = "predicted_class"
        case predictedConfidence = "predicted_confidence", correctedLabel = "corrected_label"
        case modelContext = "model_context", appVersion = "app_version", appBuild = "app_build"
        case tzOffsetS = "tz_offset_s", clientCreatedAt = "client_created_at", clientUpdatedAt = "client_updated_at"
    }

    public init(_ f: StretchFeedback) {
        id = f.id.uuidString.lowercased()
        stretchKey = f.stretchKey
        kind = f.kind.rawValue
        deviceId = f.deviceId
        startTs = f.startTs; endTs = f.endTs
        predictedLabel = f.predictedLabel
        predictedClass = f.predictedClass
        predictedConfidence = f.predictedConfidence
        verdict = f.verdict.rawValue
        correctedLabel = f.correctedLabel?.rawValue
        note = f.note
        modelContext = f.context
        appVersion = f.appVersion; appBuild = f.appBuild; tzOffsetS = f.tzOffsetS
        clientCreatedAt = Self.iso(f.createdAt)
        clientUpdatedAt = Self.iso(f.updatedAt)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

// MARK: - Matching a stretch on screen to a stored verdict

public enum StretchFeedbackMatch {
    /// The stored verdict for the stretch `[start, end)` of `kind`: the one saved under the same key, else the
    /// one of the same kind that covers most of it (a stretch's edges can move by a few seconds when the day
    /// is decoded again). `nil` when none overlaps by at least half of the longer of the two.
    public static func best(kind: StretchKind, start: Int, end: Int,
                            in all: [StretchFeedback]) -> StretchFeedback? {
        let key = StretchFeedback.key(kind: kind, start: start)
        if let exact = all.first(where: { $0.stretchKey == key }) { return exact }
        var best: (StretchFeedback, Double)?
        for f in all where f.kind == kind {
            let overlap = min(end, f.endTs) - max(start, f.startTs)
            guard overlap > 0 else { continue }
            let longer = max(end - start, f.endTs - f.startTs)
            let share = Double(overlap) / Double(max(1, longer))
            if share >= 0.5, share > (best?.1 ?? 0) { best = (f, share) }
        }
        return best?.0
    }
}

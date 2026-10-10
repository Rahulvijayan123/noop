import Foundation

// ActivityGroundTruth.swift — canonical ground-truth labels for the activity system.
//
// The activity stack already produces *predictions*: `ActivityContextState` heads ("seated_likely",
// "walking") and `_like` transition kinds. This file is the *label* side of the same ontology — what the
// wearer (or a guided session) actually did, with definitive (non-`_like`) transition kinds. Labels are
// kept deliberately independent from predictions so an evaluation joins a label to whatever the models
// believed at the time, never the other way around (spec §3.1).
//
// Everything here is a plain value type with no I/O so the whole label surface runs in a unit test. The
// canonical head codes come from ActivityContextOntology.swift in this module; the definitive transition
// kinds and semantic tags are separate vocabularies defined below.

// MARK: - Source

/// Where a ground-truth label came from. The raw values are the wire/DB codes.
public enum ActivityGroundTruthSource: String, Codable, CaseIterable, Sendable {
    /// A deliberate, in-session label from the guided calibration flow (spec §7).
    case guided
    /// A stretch-feedback verdict turned into a weak/free-living label (spec §9.4).
    case stretchFeedback = "stretch_feedback"
    /// A label imported from an external tool/export.
    case imported
    /// An in-the-moment answer to "Right now: sitting / standing / neither?" (`ActivitySitStand.swift`). It
    /// covers a short window around the answer (`ActivitySitStandConfirmations.window`), is weak (`isStrong`
    /// stays guided-only) and never feeds the HSMM personal-profile fitter (`staticMode` is guided-only); the
    /// personal sit / stand head fits on it and its verification gate scores it.
    case confirmation
}

// MARK: - Definitive transition kinds and semantic tags

/// Definitive (non-`_like`) transition kinds a ground-truth label may carry. Model predictions keep the
/// `_like` semantics of `ActivityTransitionKind` (a movement *signature*); a label states what actually
/// happened, so `sit_to_stand` here is not `sit_to_stand_like`. The four gait kinds are identical to the
/// prediction vocabulary, which is why `walk_start`/`walk_stop`/`run_start`/`run_stop` read the same in
/// both worlds. Internal: the public surface only ever carries these as raw strings.
enum ActivityGroundTruthTransitionKind: String, CaseIterable, Sendable {
    case sitToStand = "sit_to_stand"
    case standToSit = "stand_to_sit"
    case lyingDown = "lying_down"
    case gettingUp = "getting_up"
    case walkStart = "walk_start"
    case walkStop = "walk_stop"
    case runStart = "run_start"
    case runStop = "run_stop"
}

/// The finer semantic tags guided capture can attach on top of the arm-behavior head (spec §6.3). These
/// are evaluation/research labels and must not expand the production ontology immediately. Internal: the
/// public surface only ever carries these as raw strings.
enum ActivityGroundTruthSemanticTag: String, CaseIterable, Sendable {
    case typing
    case mouseWork = "mouse_work"
    case phoneUse = "phone_use"
    case writing
    case eating
    case reading
    case fidgeting
    case deskWork = "desk_work"
}

// MARK: - Cue timing and raw-evidence context

/// The precise cue timestamps of one guided bout (spec §7.3). The canonical label interval
/// `[intervalStartTs, intervalEndTs)` is deliberately inside the raw cue boundaries by `guardSeconds`
/// on each edge, but the cue times are kept here so reaction-time trimming is never lost.
public struct ActivityGroundTruthCueContext: Codable, Equatable, Sendable {
    public var instructionTs: Int?
    public var countdownStartTs: Int?
    public var cueStartTs: Int?
    public var cueStopTs: Int?
    public var intervalStartTs: Int?
    public var intervalEndTs: Int?

    public init(instructionTs: Int? = nil, countdownStartTs: Int? = nil, cueStartTs: Int? = nil,
                cueStopTs: Int? = nil, intervalStartTs: Int? = nil, intervalEndTs: Int? = nil) {
        self.instructionTs = instructionTs
        self.countdownStartTs = countdownStartTs
        self.cueStartTs = cueStartTs
        self.cueStopTs = cueStopTs
        self.intervalStartTs = intervalStartTs
        self.intervalEndTs = intervalEndTs
    }

    enum CodingKeys: String, CodingKey {
        case instructionTs = "instruction_ts"
        case countdownStartTs = "countdown_start_ts"
        case cueStartTs = "cue_start_ts"
        case cueStopTs = "cue_stop_ts"
        case intervalStartTs = "interval_start_ts"
        case intervalEndTs = "interval_end_ts"
    }
}

/// One gap in raw coverage: the half-open missing span `[startTs, endTs)` in seconds.
public struct ActivityGroundTruthGap: Codable, Equatable, Sendable {
    public var startTs: Int
    public var endTs: Int

    public init(startTs: Int, endTs: Int) {
        self.startTs = startTs
        self.endTs = endTs
    }

    enum CodingKeys: String, CodingKey {
        case startTs = "start_ts"
        case endTs = "end_ts"
    }
}

/// How much of the expected raw IMU evidence a label interval actually has. Filled by the store at save
/// time; `coverageRatio` and `evaluationReady` are derived at construction so a freshly built value is
/// never internally inconsistent.
public struct ActivityGroundTruthSensorQuality: Codable, Equatable, Sendable {
    public var expectedSeconds: Int
    public var coveredSeconds: Int
    public var sampleRateHz: Int
    public var firstTs: Int?
    public var lastTs: Int?
    public var gaps: [ActivityGroundTruthGap]
    /// coveredSeconds / expectedSeconds. 0 when nothing is expected (a label with no expected evidence
    /// is not evaluation-ready).
    public var coverageRatio: Double
    /// coveredSeconds == expectedSeconds (no gaps): the raw evidence completely covers the interval.
    public var evaluationReady: Bool

    public init(expectedSeconds: Int, coveredSeconds: Int, sampleRateHz: Int,
                firstTs: Int? = nil, lastTs: Int? = nil, gaps: [ActivityGroundTruthGap] = []) {
        self.expectedSeconds = expectedSeconds
        self.coveredSeconds = coveredSeconds
        self.sampleRateHz = sampleRateHz
        self.firstTs = firstTs
        self.lastTs = lastTs
        self.gaps = gaps
        self.coverageRatio = expectedSeconds > 0 ? Double(coveredSeconds) / Double(expectedSeconds) : 0
        self.evaluationReady = expectedSeconds > 0 && coveredSeconds == expectedSeconds
    }

    enum CodingKeys: String, CodingKey {
        case expectedSeconds = "expected_seconds"
        case coveredSeconds = "covered_seconds"
        case sampleRateHz = "sample_rate_hz"
        case firstTs = "first_ts"
        case lastTs = "last_ts"
        case gaps
        case coverageRatio = "coverage_ratio"
        case evaluationReady = "evaluation_ready"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expectedSeconds = try c.decode(Int.self, forKey: .expectedSeconds)
        coveredSeconds = try c.decode(Int.self, forKey: .coveredSeconds)
        sampleRateHz = try c.decode(Int.self, forKey: .sampleRateHz)
        firstTs = try c.decodeIfPresent(Int.self, forKey: .firstTs)
        lastTs = try c.decodeIfPresent(Int.self, forKey: .lastTs)
        gaps = try c.decodeIfPresent([ActivityGroundTruthGap].self, forKey: .gaps) ?? []
        // Older persisted documents may lack the derived fields; recompute them instead of failing.
        coverageRatio = try c.decodeIfPresent(Double.self, forKey: .coverageRatio)
            ?? (expectedSeconds > 0 ? Double(coveredSeconds) / Double(expectedSeconds) : 0)
        evaluationReady = try c.decodeIfPresent(Bool.self, forKey: .evaluationReady)
            ?? (expectedSeconds > 0 && coveredSeconds == expectedSeconds)
    }
}

/// A phone-side reference to the raw IMU evidence a label is bound to (spec §8.2). The server enriches
/// labels with object-manifest identity at save time; the phone records what it knows locally.
public struct ActivityGroundTruthRawRef: Codable, Equatable, Sendable {
    /// The IMU store session id the raw seconds live in, e.g. "activity-<deviceId>".
    public var storeSessionId: String
    public var startTs: Int
    public var endTs: Int
    public var sampleRateHz: Int
    public var coveredSeconds: Int

    public init(storeSessionId: String, startTs: Int, endTs: Int, sampleRateHz: Int, coveredSeconds: Int) {
        self.storeSessionId = storeSessionId
        self.startTs = startTs
        self.endTs = endTs
        self.sampleRateHz = sampleRateHz
        self.coveredSeconds = coveredSeconds
    }

    enum CodingKeys: String, CodingKey {
        case storeSessionId = "store_session_id"
        case startTs = "start_ts"
        case endTs = "end_ts"
        case sampleRateHz = "sample_rate_hz"
        case coveredSeconds = "covered_seconds"
    }
}

// MARK: - The label

/// One canonical ground-truth label over `[startTs, endTs)`.
///
/// Heads are `String?` on purpose: `nil` means "unknown / not given", and a label is valid with any
/// subset of heads set (spec §3.3). Raw values are the canonical ontology codes (or the definitive
/// transition/semantic vocabularies above) — the wire/DB never sees display wording.
public struct ActivityGroundTruthLabel: Codable, Equatable, Identifiable, Sendable {
    public static let maxNoteLength = 280

    /// Client record id, stable across edits of the same label.
    public var id: UUID
    /// `"<source>:<session-or-stretch>:<startTs>[:<rep>]"` — the stable upsert identity. The charset
    /// (`^[A-Za-z0-9:_.-]{1,96}$`) matches the server's `label_key` column.
    public var labelKey: String
    public var source: ActivityGroundTruthSource
    /// Guided-session uuid string. Stretch-feedback labels leave this nil (their stretch key lives in
    /// `labelKey`).
    public var sessionId: String?
    public var protocolVersion: String?
    public var repetition: Int?
    /// Local BLE device id; the server resolves and stores the owning `devices` row.
    public var deviceId: String?
    /// Cloud strap id ("whoop-<serial>") when known.
    public var externalDeviceId: String?
    public var startTs: Int
    public var endTs: Int
    public var posture: String?
    public var locomotion: String?
    public var armBehavior: String?
    /// Definitive (non-`_like`) transition kind; nil when the label is not a transition label.
    public var transitionKind: String?
    public var transitionTs: Int?
    public var semanticTag: String?
    public var labelConfidence: Double? {
        didSet {
            // JSON cannot hold NaN/±infinity; dropping a non-finite value keeps the whole record savable.
            if let value = labelConfidence, !value.isFinite { labelConfidence = nil }
        }
    }
    public var userUnsure: Bool
    public var note: String?
    public var cueContext: ActivityGroundTruthCueContext?
    /// Filled by the store at save time from raw-IMU coverage.
    public var sensorQuality: ActivityGroundTruthSensorQuality?
    /// Phone-side raw-evidence facts; the server enriches with object manifests.
    public var rawRefs: [ActivityGroundTruthRawRef]?
    /// What the app believed at label time, e.g. ["decoder": "hsmm-1.3", "display": "Desk sitting"].
    public var modelContextAtLabelTime: [String: String]?
    public var appVersion: String?
    public var appBuild: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var syncedAt: Date?

    /// Whether the server has accepted this record at or after the last edit.
    public var needsSync: Bool {
        guard let syncedAt else { return true }
        return syncedAt < updatedAt
    }

    /// A strong label: a deliberate guided answer the wearer did not flag as unsure. Everything else
    /// (unsure guided, stretch feedback, imported) is weak and evaluated separately (spec §9.4).
    public var isStrong: Bool { source == .guided && !userUnsure }

    // MARK: Vocabulary (canonical codes)

    private static let postureCodes = Set(PostureClass.allCases.map(\.rawValue))
    private static let locomotionCodes = Set(LocomotionClass.allCases.map(\.rawValue))
    private static let armBehaviorCodes = Set(ArmBehaviorClass.allCases.map(\.rawValue))
    private static let transitionCodes = Set(ActivityGroundTruthTransitionKind.allCases.map(\.rawValue))
    private static let semanticTagCodes = Set(ActivityGroundTruthSemanticTag.allCases.map(\.rawValue))

    /// True when every non-nil head uses a canonical ground-truth code. Throws `CodingError.badVocabulary`
    /// naming the offending head — this is the shared gate the wire/DB and `validated()` both use.
    public static func vocabularyCheck(posture: String?, locomotion: String?, armBehavior: String?,
                                       transitionKind: String?, semanticTag: String?) throws {
        func check(_ value: String?, in vocabulary: Set<String>, _ head: String) throws {
            if let value, !vocabulary.contains(value) {
                throw CodingError.badVocabulary("\(head): '\(value)' is not a canonical ground-truth code")
            }
        }
        try check(posture, in: postureCodes, "posture")
        try check(locomotion, in: locomotionCodes, "locomotion")
        try check(armBehavior, in: armBehaviorCodes, "arm_behavior")
        try check(transitionKind, in: transitionCodes, "transition_kind")
        try check(semanticTag, in: semanticTagCodes, "semantic_tag")
    }

    static func isValidLabelKey(_ key: String) -> Bool {
        guard (1...96).contains(key.utf8.count) else { return false }
        for scalar in key.unicodeScalars {
            let v = scalar.value
            let alphanumeric = (v >= 0x30 && v <= 0x39) || (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A)
            let punctuation = v == 0x3A || v == 0x5F || v == 0x2E || v == 0x2D   // : _ . -
            guard alphanumeric || punctuation else { return false }
        }
        return true
    }

    /// Builds the stable upsert key for a label: `"<source>:<session-or-stretch>:<startTs>[:<rep>]"`.
    /// Guided labels carry the session uuid; stretch-feedback labels carry the stretch key (their
    /// `sessionId` is nil, per §6). `repetition` is appended only when present so rep-0 labels stay
    /// distinguishable from single-shot labels.
    public static func labelKey(source: ActivityGroundTruthSource, sessionId: String?,
                                stretchKey: String?, startTs: Int, repetition: Int?) -> String {
        let middle = sessionId ?? stretchKey ?? ""
        var key = "\(source.rawValue):\(middle):\(startTs)"
        if let repetition { key += ":\(repetition)" }
        return key
    }

    // MARK: Init

    /// Full memberwise init. `note` is cleaned exactly like `StretchFeedback.cleaned` (trimmed, nil when
    /// blank, truncated to `maxNoteLength`); `updatedAt` defaults to `createdAt`.
    public init(id: UUID = UUID(),
                labelKey: String,
                source: ActivityGroundTruthSource,
                sessionId: String? = nil,
                protocolVersion: String? = nil,
                repetition: Int? = nil,
                deviceId: String? = nil,
                externalDeviceId: String? = nil,
                startTs: Int,
                endTs: Int,
                posture: String? = nil,
                locomotion: String? = nil,
                armBehavior: String? = nil,
                transitionKind: String? = nil,
                transitionTs: Int? = nil,
                semanticTag: String? = nil,
                labelConfidence: Double? = nil,
                userUnsure: Bool = false,
                note: String? = nil,
                cueContext: ActivityGroundTruthCueContext? = nil,
                sensorQuality: ActivityGroundTruthSensorQuality? = nil,
                rawRefs: [ActivityGroundTruthRawRef]? = nil,
                modelContextAtLabelTime: [String: String]? = nil,
                appVersion: String? = nil,
                appBuild: String? = nil,
                createdAt: Date = Date(),
                updatedAt: Date? = nil,
                syncedAt: Date? = nil) {
        self.id = id
        self.labelKey = labelKey
        self.source = source
        self.sessionId = sessionId
        self.protocolVersion = protocolVersion
        self.repetition = repetition
        self.deviceId = deviceId
        self.externalDeviceId = externalDeviceId
        self.startTs = startTs
        self.endTs = endTs
        self.posture = posture
        self.locomotion = locomotion
        self.armBehavior = armBehavior
        self.transitionKind = transitionKind
        self.transitionTs = transitionTs
        self.semanticTag = semanticTag
        self.labelConfidence = labelConfidence
        self.userUnsure = userUnsure
        self.note = Self.cleaned(note)
        self.cueContext = cueContext
        self.sensorQuality = sensorQuality
        self.rawRefs = rawRefs
        self.modelContextAtLabelTime = modelContextAtLabelTime
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.syncedAt = syncedAt
    }

    /// Convenience init that derives `labelKey` from source/session/stretch/start so a caller cannot
    /// accidentally desync the key from the fields it names.
    public init(source: ActivityGroundTruthSource,
                sessionId: String? = nil,
                stretchKey: String? = nil,
                startTs: Int,
                endTs: Int,
                repetition: Int? = nil,
                id: UUID = UUID(),
                protocolVersion: String? = nil,
                deviceId: String? = nil,
                externalDeviceId: String? = nil,
                posture: String? = nil,
                locomotion: String? = nil,
                armBehavior: String? = nil,
                transitionKind: String? = nil,
                transitionTs: Int? = nil,
                semanticTag: String? = nil,
                labelConfidence: Double? = nil,
                userUnsure: Bool = false,
                note: String? = nil,
                cueContext: ActivityGroundTruthCueContext? = nil,
                sensorQuality: ActivityGroundTruthSensorQuality? = nil,
                rawRefs: [ActivityGroundTruthRawRef]? = nil,
                modelContextAtLabelTime: [String: String]? = nil,
                appVersion: String? = nil,
                appBuild: String? = nil,
                createdAt: Date = Date(),
                updatedAt: Date? = nil,
                syncedAt: Date? = nil) {
        self.init(id: id,
                  labelKey: Self.labelKey(source: source, sessionId: sessionId, stretchKey: stretchKey,
                                          startTs: startTs, repetition: repetition),
                  source: source, sessionId: sessionId, protocolVersion: protocolVersion,
                  repetition: repetition, deviceId: deviceId, externalDeviceId: externalDeviceId,
                  startTs: startTs, endTs: endTs, posture: posture, locomotion: locomotion,
                  armBehavior: armBehavior, transitionKind: transitionKind, transitionTs: transitionTs,
                  semanticTag: semanticTag, labelConfidence: labelConfidence, userUnsure: userUnsure,
                  note: note, cueContext: cueContext, sensorQuality: sensorQuality, rawRefs: rawRefs,
                  modelContextAtLabelTime: modelContextAtLabelTime, appVersion: appVersion,
                  appBuild: appBuild, createdAt: createdAt, updatedAt: updatedAt, syncedAt: syncedAt)
    }

    /// Note cleaning mirrors `StretchFeedback.cleaned`: trim whitespace, nil when blank, cap the length.
    static func cleaned(_ note: String?) -> String? {
        guard let trimmed = note?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxNoteLength))
    }

    // MARK: Validation

    /// The label, re-issued only when it is structurally valid, or `nil`. Validity rules (mirroring the
    /// server CHECKs and the wire validator): canonical head vocabulary, `endTs > startTs`, interval at
    /// most 86,400 s, `startTs` after the 2000 epoch, a `labelKey` matching `^[A-Za-z0-9:_.-]{1,96}$`, a
    /// note no longer than `maxNoteLength`, a `labelConfidence` in [0, 1] when present, and a
    /// `transitionTs` inside `[startTs, endTs]` when present. An unsure guided label is deliberately
    /// valid: it is a *weak* guided label (`isStrong == false`) that evaluation keeps separate instead
    /// of dropping (spec §9.4).
    public func validated() -> ActivityGroundTruthLabel? {
        guard (try? Self.vocabularyCheck(posture: posture, locomotion: locomotion, armBehavior: armBehavior,
                                         transitionKind: transitionKind, semanticTag: semanticTag)) != nil else { return nil }
        guard endTs > startTs else { return nil }
        guard endTs - startTs <= 86_400 else { return nil }
        guard startTs > 946_684_800 else { return nil }
        guard Self.isValidLabelKey(labelKey) else { return nil }
        if let note, note.count > Self.maxNoteLength { return nil }
        if let labelConfidence, !(0...1).contains(labelConfidence) { return nil }
        if let transitionTs, !(startTs...endTs).contains(transitionTs) { return nil }
        return self
    }

    public enum CodingError: Error {
        case badVocabulary(String)
        case badTimestamps
        case badKey
        case badNote
    }

    // MARK: Codable

    enum CodingKeys: String, CodingKey {
        case id, source, posture, locomotion, repetition, note
        case labelKey = "label_key", sessionId = "session_id", protocolVersion = "protocol_version"
        case deviceId = "device_id", externalDeviceId = "external_device_id"
        case startTs = "start_ts", endTs = "end_ts", armBehavior = "arm_behavior"
        case transitionKind = "transition_kind", transitionTs = "transition_ts"
        case semanticTag = "semantic_tag", labelConfidence = "label_confidence"
        case userUnsure = "user_unsure", cueContext = "cue_context", sensorQuality = "sensor_quality"
        case rawRefs = "raw_refs", modelContextAtLabelTime = "model_context_at_label_time"
        case appVersion = "app_version", appBuild = "app_build"
        case createdAt = "created_at", updatedAt = "updated_at", syncedAt = "synced_at"
    }

    /// Dates are ISO-8601 with fractional seconds, the repo's wire pattern (`StretchFeedbackWire.iso`);
    /// decoding also accepts the same instant without fractional seconds for older records.
    static func isoString(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func dateFromISO(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }

    static func requireDate(_ string: String) throws -> Date {
        guard let date = dateFromISO(string) else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: [], debugDescription: "invalid ISO-8601 date: \(string)"))
        }
        return date
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        labelKey = try c.decode(String.self, forKey: .labelKey)
        source = try c.decode(ActivityGroundTruthSource.self, forKey: .source)
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId)
        protocolVersion = try c.decodeIfPresent(String.self, forKey: .protocolVersion)
        repetition = try c.decodeIfPresent(Int.self, forKey: .repetition)
        deviceId = try c.decodeIfPresent(String.self, forKey: .deviceId)
        externalDeviceId = try c.decodeIfPresent(String.self, forKey: .externalDeviceId)
        startTs = try c.decode(Int.self, forKey: .startTs)
        endTs = try c.decode(Int.self, forKey: .endTs)
        posture = try c.decodeIfPresent(String.self, forKey: .posture)
        locomotion = try c.decodeIfPresent(String.self, forKey: .locomotion)
        armBehavior = try c.decodeIfPresent(String.self, forKey: .armBehavior)
        transitionKind = try c.decodeIfPresent(String.self, forKey: .transitionKind)
        transitionTs = try c.decodeIfPresent(Int.self, forKey: .transitionTs)
        semanticTag = try c.decodeIfPresent(String.self, forKey: .semanticTag)
        labelConfidence = try c.decodeIfPresent(Double.self, forKey: .labelConfidence)
        userUnsure = try c.decodeIfPresent(Bool.self, forKey: .userUnsure) ?? false
        note = try c.decodeIfPresent(String.self, forKey: .note)
        cueContext = try c.decodeIfPresent(ActivityGroundTruthCueContext.self, forKey: .cueContext)
        sensorQuality = try c.decodeIfPresent(ActivityGroundTruthSensorQuality.self, forKey: .sensorQuality)
        rawRefs = try c.decodeIfPresent([ActivityGroundTruthRawRef].self, forKey: .rawRefs)
        modelContextAtLabelTime = try c.decodeIfPresent([String: String].self, forKey: .modelContextAtLabelTime)
        appVersion = try c.decodeIfPresent(String.self, forKey: .appVersion)
        appBuild = try c.decodeIfPresent(String.self, forKey: .appBuild)
        createdAt = try Self.requireDate(c.decode(String.self, forKey: .createdAt))
        updatedAt = try Self.requireDate(c.decode(String.self, forKey: .updatedAt))
        syncedAt = try c.decodeIfPresent(String.self, forKey: .syncedAt).flatMap(Self.dateFromISO)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(labelKey, forKey: .labelKey)
        try c.encode(source, forKey: .source)
        try c.encodeIfPresent(sessionId, forKey: .sessionId)
        try c.encodeIfPresent(protocolVersion, forKey: .protocolVersion)
        try c.encodeIfPresent(repetition, forKey: .repetition)
        try c.encodeIfPresent(deviceId, forKey: .deviceId)
        try c.encodeIfPresent(externalDeviceId, forKey: .externalDeviceId)
        try c.encode(startTs, forKey: .startTs)
        try c.encode(endTs, forKey: .endTs)
        try c.encodeIfPresent(posture, forKey: .posture)
        try c.encodeIfPresent(locomotion, forKey: .locomotion)
        try c.encodeIfPresent(armBehavior, forKey: .armBehavior)
        try c.encodeIfPresent(transitionKind, forKey: .transitionKind)
        try c.encodeIfPresent(transitionTs, forKey: .transitionTs)
        try c.encodeIfPresent(semanticTag, forKey: .semanticTag)
        try c.encodeIfPresent(labelConfidence, forKey: .labelConfidence)
        try c.encode(userUnsure, forKey: .userUnsure)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encodeIfPresent(cueContext, forKey: .cueContext)
        try c.encodeIfPresent(sensorQuality, forKey: .sensorQuality)
        try c.encodeIfPresent(rawRefs, forKey: .rawRefs)
        try c.encodeIfPresent(modelContextAtLabelTime, forKey: .modelContextAtLabelTime)
        try c.encodeIfPresent(appVersion, forKey: .appVersion)
        try c.encodeIfPresent(appBuild, forKey: .appBuild)
        try c.encode(Self.isoString(createdAt), forKey: .createdAt)
        try c.encode(Self.isoString(updatedAt), forKey: .updatedAt)
        try c.encodeIfPresent(syncedAt.map(Self.isoString), forKey: .syncedAt)
    }
}

// MARK: - Guided calibration protocol

/// One guided step: a hold (the wearer stays in `posture`) or a move (the wearer changes posture once,
/// on the buzz at `cueSeconds`). Steps inside an activity run back to back, so a move's pre-cue seconds
/// are the tail of the previous hold and its post-cue seconds settle into the next one.
///
/// The label interval is `[start + guardSeconds, end - guardSeconds)`, so reaction time at either edge
/// never reaches the label (spec §7.3). A move's label claims no posture (the interval holds both
/// states); `endPosture` only tells the screen what to say after the buzz.
public struct ActivityCalibrationTask: Equatable, Identifiable, Sendable {
    public var id: String
    /// Short imperative shown large on screen ("Sit", "Stand up").
    public var title: String
    public var instructions: String
    public var posture: String?
    public var transitionKind: String?
    public var endPosture: String?
    public var durationSeconds: Int
    /// Seconds after the step starts at which a move's "move now" buzz fires; nil for holds. With
    /// `cueSecondsRange` set this is the nominal cue (the range's lower bound), kept for runners that do not jitter.
    public var cueSeconds: Int?
    /// When set (calibration-v4 moves), the buzz fires at a seconds offset drawn uniformly from this range each
    /// time the step runs (`resolvedCueSeconds(using:)`), so the wearer cannot anticipate it and pre-move.
    public var cueSecondsRange: ClosedRange<Int>?
    /// Which repetition of its activity this step belongs to (1, 2 …): the saved label's `repetition`. nil for
    /// protocols that do not number repetitions (calibration-v3).
    public var repetition: Int?
    public var guardSeconds: Int

    public init(id: String, title: String, instructions: String, posture: String? = nil,
                transitionKind: String? = nil, endPosture: String? = nil,
                durationSeconds: Int, cueSeconds: Int? = nil, cueSecondsRange: ClosedRange<Int>? = nil,
                repetition: Int? = nil, guardSeconds: Int = 2) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.posture = posture
        self.transitionKind = transitionKind
        self.endPosture = endPosture
        self.durationSeconds = durationSeconds
        self.cueSeconds = cueSeconds ?? cueSecondsRange?.lowerBound
        self.cueSecondsRange = cueSecondsRange
        self.repetition = repetition
        self.guardSeconds = guardSeconds
    }

    public var isMove: Bool { transitionKind != nil }

    /// The latest the buzz can fire: the range's upper bound, else `cueSeconds`; nil for holds.
    public var latestCueSeconds: Int? { cueSecondsRange?.upperBound ?? cueSeconds }

    /// The cue offset for one run of this step: a uniform draw from `cueSecondsRange` with the injected generator
    /// (seed it in tests for a deterministic schedule), else the fixed `cueSeconds`; nil for holds. The runner
    /// records the buzz time it actually used as the label's `cue_start_ts` / `transition_ts`.
    public func resolvedCueSeconds<G: RandomNumberGenerator>(using generator: inout G) -> Int? {
        if let range = cueSecondsRange { return Int.random(in: range, using: &generator) }
        return cueSeconds
    }

    /// `resolvedCueSeconds(using:)` with the system generator.
    public func resolvedCueSeconds() -> Int? {
        var g = SystemRandomNumberGenerator()
        return resolvedCueSeconds(using: &g)
    }
}

/// A skippable block of steps that needs one setup (a chair, a bed or sofa). The wearer starts it with a
/// tap once in position; skipping it never touches the labels other activities saved.
public struct ActivityCalibrationActivity: Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// Where to be before tapping Start.
    public var setup: String
    public var tasks: [ActivityCalibrationTask]

    public init(id: String, title: String, setup: String, tasks: [ActivityCalibrationTask]) {
        self.id = id
        self.title = title
        self.setup = setup
        self.tasks = tasks
    }

    public var seconds: Int { tasks.reduce(0) { $0 + $1.durationSeconds } }
}

/// A versioned guided-capture protocol.
public struct ActivityCalibrationProtocolModel: Equatable, Sendable {
    public var version: String
    public var activities: [ActivityCalibrationActivity]

    public init(version: String, activities: [ActivityCalibrationActivity]) {
        self.version = version
        self.activities = activities
    }

    public var tasks: [ActivityCalibrationTask] { activities.flatMap(\.tasks) }

    /// Wall-clock length of one run with nothing skipped: each activity's start countdown plus its steps.
    public func estimatedSeconds(startCountdownSeconds: Int = ActivityCalibrationProtocols.startCountdownSeconds) -> Int {
        activities.reduce(0) { $0 + startCountdownSeconds + $1.seconds }
    }
}

/// The shipped guided-capture protocol. Earlier versions (`calibration-v1`, the hour-long drill, and
/// `calibration-v2`, a 9-minute day-in-miniature with desk and walking steps) are not kept: every label
/// carries its own heads, timestamps and `protocol_version`, so nothing reads an old definition back.
public enum ActivityCalibrationProtocols {
    /// The protocol the guided session runs.
    public static var current: ActivityCalibrationProtocolModel { v5 }

    /// Every protocol a stored label may name in `protocol_version`, newest first. Labels carry their own heads
    /// and timestamps, so an old version is listed only to read its definition back (e.g. for display).
    public static var all: [ActivityCalibrationProtocolModel] { [v5, v4, v3] }

    /// The protocol a label's `protocol_version` names, if known.
    public static func model(forVersion version: String?) -> ActivityCalibrationProtocolModel? {
        all.first { $0.version == version }
    }

    /// Seconds between tapping Start and an activity's first step: time to put the phone hand down and
    /// let the decoder's trailing windows clear the tap.
    public static let startCountdownSeconds = 5

    /// Short runs it takes before a personal profile can be fit and tested: leave-one-run-out trains on
    /// all runs but one, so each posture needs `ActivityPersonalProfileFitter.minModeSeconds` across two runs.
    /// calibration-v5's 75 s holds leave 67 s per hold after the guards and trims, 134 s per posture per run, so two
    /// runs clear it (v3 / v4's 30 s holds needed three).
    public static let runsToPersonalise = 2

    /// About 5 minutes, posture and posture changes only: the distinctions the decoder gets wrong (sitting vs
    /// standing vs lying) and the moves between them. Walking, desk work, typing and fidgeting are gone:
    /// ElderNet and the gait chain already call walking well, and the fitter never learns from arm tags.
    ///
    /// Two activities, each skippable. Sit and stand holds are 30 s: after the 2 s cue guards, the fitter's 3 s settle and
    /// 1 s end trims, that leaves 22 s per hold, 44 s per posture, so leave-one-run-out folds of
    /// two runs clear the 60 s per-mode minimum (`runsToPersonalise`). Moves buzz 3 s in, after the screen's
    /// 3-2-1, and run 7–9 s past the buzz so the next hold starts after the decoder's 10 s change-settle.
    /// Each run carries eight position changes, every one with a known `transition_ts`.
    public static let v3: ActivityCalibrationProtocolModel = {
        let seated = PostureClass.seatedLikely.rawValue
        let upright = PostureClass.uprightStationary.rawValue
        let lying = PostureClass.recumbent.rawValue

        func hold(_ id: String, _ title: String, _ posture: String, _ seconds: Int,
                  _ instructions: String) -> ActivityCalibrationTask {
            ActivityCalibrationTask(id: id, title: title, instructions: instructions, posture: posture,
                                    durationSeconds: seconds)
        }
        func move(_ id: String, _ title: String, _ kind: ActivityGroundTruthTransitionKind, to end: String,
                  _ seconds: Int, _ instructions: String) -> ActivityCalibrationTask {
            ActivityCalibrationTask(id: id, title: title, instructions: instructions, transitionKind: kind.rawValue,
                                    endPosture: end, durationSeconds: seconds, cueSeconds: 3)
        }

        let sitStand = ActivityCalibrationActivity(
            id: "sit-stand", title: "Sit and stand",
            setup: "Sit on a chair, or on the edge of a bed or sofa. Hold the phone in the hand without the strap.",
            tasks: [
                hold("sit-stand.sit-1", "Sit", seated, 30, "Sit relaxed, the way you normally do. Hands wherever is natural."),
                move("sit-stand.stand-up-1", "Stand up", .sitToStand, to: upright, 10, "Stand up at your normal speed, then stay standing."),
                hold("sit-stand.stand-1", "Stand", upright, 30, "Stand relaxed, as if waiting in a queue. Shifting your weight is fine."),
                move("sit-stand.sit-down-1", "Sit down", .standToSit, to: seated, 10, "Sit back down, then stay seated."),
                hold("sit-stand.sit-2", "Sit", seated, 30, "Sit relaxed. Try a different hand position from last time."),
                move("sit-stand.stand-up-2", "Stand up", .sitToStand, to: upright, 10, "Stand up at your normal speed, then stay standing."),
                hold("sit-stand.stand-2", "Stand", upright, 30, "Stand relaxed. Arms however you normally hold them."),
                move("sit-stand.sit-down-2", "Sit down", .standToSit, to: seated, 10, "Sit back down and stay seated."),
            ])

        let lieDown = ActivityCalibrationActivity(
            id: "lie-down", title: "Lie down and get up",
            setup: "Sit on the edge of a bed or sofa you can lie down on.",
            tasks: [
                hold("lie-down.sit-1", "Sit", seated, 12, "Sit on the edge, relaxed."),
                move("lie-down.lie-down-1", "Lie down", .lyingDown, to: lying, 12, "Lie down on your back, then stay still."),
                hold("lie-down.lie-1", "Lie still", lying, 25, "Lie relaxed, as if resting. Arms wherever is comfortable."),
                move("lie-down.sit-up-1", "Sit up", .gettingUp, to: seated, 12, "Sit up on the edge, then stay seated."),
                hold("lie-down.sit-2", "Sit", seated, 12, "Sit on the edge, relaxed."),
                move("lie-down.lie-down-2", "Lie down", .lyingDown, to: lying, 12, "Lie down again, on your back or side."),
                hold("lie-down.lie-2", "Lie still", lying, 25, "Lie relaxed. A different arm position from last time."),
                move("lie-down.get-up-2", "Get up and stand", .gettingUp, to: upright, 12, "Get up and stand next to the bed or sofa."),
                hold("lie-down.stand-1", "Stand", upright, 12, "Stand still next to it. That's the last step."),
            ])

        return ActivityCalibrationProtocolModel(version: "calibration-v3", activities: [sitStand, lieDown])
    }()

    /// The range a calibration-v4 move's buzz is drawn from, seconds into the move step.
    public static let v4CueSecondsRange: ClosedRange<Int> = 2...5

    /// calibration-v4 (docs/sit-stand-calibration-findings.md): the sit / stand activity redesigned for the personal
    /// sit / stand head (`ActivitySitStandModel`). Free-living accuracy comes from how the wearer NATURALLY holds
    /// their arm, and cued "hold still" data is anti-predictive there, so the holds ask for hands busy as usual
    /// (phone, gestures), not stillness. Two repetitions of sit 30 s → stand up → stand 30 s → sit down, each step
    /// carrying its repetition number; each move's buzz fires at a random 2–5 s into the step (`cueSecondsRange`)
    /// so it cannot be anticipated. Moves last 12 s, so even the latest buzz leaves 7 s to move and settle. The
    /// lie-down activity is v3's, unchanged.
    public static let v4: ActivityCalibrationProtocolModel = {
        let seated = PostureClass.seatedLikely.rawValue
        let upright = PostureClass.uprightStationary.rawValue

        func hold(_ id: String, _ title: String, _ posture: String, rep: Int,
                  _ instructions: String) -> ActivityCalibrationTask {
            ActivityCalibrationTask(id: id, title: title, instructions: instructions, posture: posture,
                                    durationSeconds: 30, repetition: rep)
        }
        func move(_ id: String, _ title: String, _ kind: ActivityGroundTruthTransitionKind, to end: String, rep: Int,
                  _ instructions: String) -> ActivityCalibrationTask {
            ActivityCalibrationTask(id: id, title: title, instructions: instructions, transitionKind: kind.rawValue,
                                    endPosture: end, durationSeconds: 12, cueSecondsRange: v4CueSecondsRange,
                                    repetition: rep)
        }

        var tasks: [ActivityCalibrationTask] = []
        for rep in 1...2 {
            tasks += [
                hold("sit-stand.sit-\(rep)", "Sit", seated, rep: rep,
                     "Sit the way you normally do. Keep your hands busy as usual: use your phone, gesture, rest them. No need to hold still."),
                move("sit-stand.stand-up-\(rep)", "Stand up", .sitToStand, to: upright, rep: rep,
                     "When it buzzes, stand up at your normal speed, then stay standing."),
                hold("sit-stand.stand-\(rep)", "Stand", upright, rep: rep,
                     "Stand the way you normally do, as if waiting or chatting. Use your phone or gesture as usual. No need to hold still."),
                move("sit-stand.sit-down-\(rep)", "Sit down", .standToSit, to: seated, rep: rep,
                     "When it buzzes, sit back down, then stay seated."),
            ]
        }
        let sitStand = ActivityCalibrationActivity(
            id: "sit-stand", title: "Sit and stand",
            setup: "Sit on a chair, or on the edge of a bed or sofa. Keep the phone with you and use it as you normally would.",
            tasks: tasks)
        let lieDown = v3.activities.first { $0.id == "lie-down" }!
        return ActivityCalibrationProtocolModel(version: "calibration-v4", activities: [sitStand, lieDown])
    }()

    /// Hold length in calibration-v5 (s): long enough for the heart rate to settle after a change of posture
    /// (orthostatic response, ~45 s) and leave one 30 s block (`ActivityPostureHeartRateFitter`).
    public static let v5HoldSeconds = 75

    /// calibration-v5 (hsmm-2.0): v4's sit / stand activity with
    ///   • 75 s holds, so each hold gives the heart-rate-by-posture fit a settled block and the profile fit 134 s per
    ///     posture per run (two runs personalise instead of three);
    ///   • the second repetition held the way an upper-arm strap cannot tell apart: seated with the arms hanging at the
    ///     sides or resting on the lap, and standing with the arms hanging. The owner sat for 90 minutes on 2026-10-09
    ///     with their upper arm hanging and was read as standing; a run that never shows that pose cannot teach it.
    /// The stand-ups and sit-downs carry `transition_ts`, so they also check the measured change of height
    /// (`ActivityVerticalShift`). The lie-down activity is v3's, unchanged.
    public static let v5: ActivityCalibrationProtocolModel = {
        let seated = PostureClass.seatedLikely.rawValue
        let upright = PostureClass.uprightStationary.rawValue

        func hold(_ id: String, _ title: String, _ posture: String, rep: Int,
                  _ instructions: String) -> ActivityCalibrationTask {
            ActivityCalibrationTask(id: id, title: title, instructions: instructions, posture: posture,
                                    durationSeconds: v5HoldSeconds, repetition: rep)
        }
        func move(_ id: String, _ title: String, _ kind: ActivityGroundTruthTransitionKind, to end: String, rep: Int,
                  _ instructions: String) -> ActivityCalibrationTask {
            ActivityCalibrationTask(id: id, title: title, instructions: instructions, transitionKind: kind.rawValue,
                                    endPosture: end, durationSeconds: 12, cueSecondsRange: v4CueSecondsRange,
                                    repetition: rep)
        }

        let tasks: [ActivityCalibrationTask] = [
            hold("sit-stand.sit-1", "Sit", seated, rep: 1,
                 "Sit the way you normally do. Keep your hands busy as usual: use your phone, gesture, rest them. No need to hold still."),
            move("sit-stand.stand-up-1", "Stand up", .sitToStand, to: upright, rep: 1,
                 "When it buzzes, stand up at your normal speed, then stay standing."),
            hold("sit-stand.stand-1", "Stand", upright, rep: 1,
                 "Stand the way you normally do, as if waiting or chatting. Use your phone or gesture as usual."),
            move("sit-stand.sit-down-1", "Sit down", .standToSit, to: seated, rep: 1,
                 "When it buzzes, sit back down, then stay seated."),
            hold("sit-stand.sit-2", "Sit, arms down", seated, rep: 2,
                 "Stay seated with your arms hanging at your sides or resting on your lap, not on a desk. Relax."),
            move("sit-stand.stand-up-2", "Stand up", .sitToStand, to: upright, rep: 2,
                 "When it buzzes, stand up at your normal speed, then stay standing."),
            hold("sit-stand.stand-2", "Stand, arms down", upright, rep: 2,
                 "Stand with your arms hanging relaxed at your sides."),
            move("sit-stand.sit-down-2", "Sit down", .standToSit, to: seated, rep: 2,
                 "When it buzzes, sit back down. That's the end of this part."),
        ]
        let sitStand = ActivityCalibrationActivity(
            id: "sit-stand", title: "Sit and stand",
            setup: "Sit on a chair, or on the edge of a bed or sofa. Keep the phone with you; the screen tells you each step.",
            tasks: tasks)
        // v3's lie-down activity with 40 s lying holds (v3: 25 s): after the guards and trims that is 32 s per hold,
        // 64 s per run, so two runs personalise lying too.
        let v3LieDown = v3.activities.first { $0.id == "lie-down" }!
        let lieDown = ActivityCalibrationActivity(
            id: v3LieDown.id, title: v3LieDown.title, setup: v3LieDown.setup,
            tasks: v3LieDown.tasks.map { t in
                guard !t.isMove, t.posture == PostureClass.recumbent.rawValue else { return t }
                var t = t
                t.durationSeconds = 40
                return t
            })
        return ActivityCalibrationProtocolModel(version: "calibration-v5", activities: [sitStand, lieDown])
    }()
}

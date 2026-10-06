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

/// The group a calibration task belongs to. Raw values are the wire codes; `title` is the UI wording.
public enum ActivityCalibrationTaskCategory: String, Codable, CaseIterable, Sendable {
    case posture
    case desk
    case locomotion
    case transition

    public var title: String {
        switch self {
        case .posture: return "Posture"
        case .desk: return "Desk / arm"
        case .locomotion: return "Locomotion"
        case .transition: return "Transitions"
        }
    }
}

/// One guided-capture task: what to do, for how long, how many times, and what the resulting label
/// should claim. `guardSeconds` (default 2) trims each cue edge so the label interval is never
/// reaction-time contaminated (spec §7.3); transition tasks keep `preStateSeconds`/`postStateSeconds`
/// of guaranteed stable state around the event so evaluation never judges a transition from one
/// timestamp (spec §7.4).
public struct ActivityCalibrationTask: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var instructions: String
    /// Raw value of `ActivityCalibrationTaskCategory`; kept a plain String so Codable stays simple.
    public var category: String
    public var posture: String?
    public var locomotion: String?
    public var armBehavior: String?
    public var semanticTag: String?
    public var transitionKind: String?
    public var durationSeconds: Int
    public var repetitions: Int
    public var restSeconds: Int
    public var preStateSeconds: Int?
    public var postStateSeconds: Int?
    public var guardSeconds: Int

    public init(id: String, title: String, instructions: String, category: String,
                posture: String? = nil, locomotion: String? = nil, armBehavior: String? = nil,
                semanticTag: String? = nil, transitionKind: String? = nil,
                durationSeconds: Int, repetitions: Int, restSeconds: Int = 5,
                preStateSeconds: Int? = nil, postStateSeconds: Int? = nil,
                guardSeconds: Int = 2) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.category = category
        self.posture = posture
        self.locomotion = locomotion
        self.armBehavior = armBehavior
        self.semanticTag = semanticTag
        self.transitionKind = transitionKind
        self.durationSeconds = durationSeconds
        self.repetitions = repetitions
        self.restSeconds = restSeconds
        self.preStateSeconds = preStateSeconds
        self.postStateSeconds = postStateSeconds
        self.guardSeconds = guardSeconds
    }

    enum CodingKeys: String, CodingKey {
        case id, title, instructions, category, posture, locomotion, repetitions
        case armBehavior = "arm_behavior", semanticTag = "semantic_tag", transitionKind = "transition_kind"
        case durationSeconds = "duration_seconds", restSeconds = "rest_seconds"
        case preStateSeconds = "pre_state_seconds", postStateSeconds = "post_state_seconds"
        case guardSeconds = "guard_seconds"
    }
}

/// An editable, versioned guided-capture protocol.
public struct ActivityCalibrationProtocolModel: Codable, Sendable {
    public var version: String
    public var tasks: [ActivityCalibrationTask]

    public init(version: String, tasks: [ActivityCalibrationTask]) {
        self.version = version
        self.tasks = tasks
    }
}

/// The shipped guided-capture protocols. Editable copies are made from these; the statics stay pristine
/// so the protocol can be re-derived after a user edits it (spec §7.4 "editable and versioned").
public enum ActivityCalibrationProtocols {
    /// The default protocol: spec §7.4 groups (posture 45 s×3, desk 60/45/45/30/45 s, locomotion
    /// 90/90/60/60/120 s, six transition kinds at 10 reps each). Every instruction string embeds the
    /// natural-variation guidance from spec §7.5 (vary arm position, hand dominance, wrist placement,
    /// desk posture, gait speed) so the protocol never teaches one scripted wrist pose.
    public static let v1: ActivityCalibrationProtocolModel = {
        let cat = ActivityCalibrationTaskCategory.self

        func task(_ id: String, _ title: String, _ category: String, _ instructions: String,
                  duration: Int, repetitions: Int, restSeconds: Int = 5,
                  posture: String? = nil, locomotion: String? = nil, armBehavior: String? = nil,
                  semanticTag: String? = nil, transitionKind: String? = nil,
                  preState: Int? = nil, postState: Int? = nil) -> ActivityCalibrationTask {
            ActivityCalibrationTask(id: id, title: title, instructions: instructions, category: category,
                                    posture: posture, locomotion: locomotion, armBehavior: armBehavior,
                                    semanticTag: semanticTag, transitionKind: transitionKind,
                                    durationSeconds: duration, repetitions: repetitions,
                                    restSeconds: restSeconds, preStateSeconds: preState,
                                    postStateSeconds: postState)
        }

        // Spec §7.4 static/posture: 45 s × 3 each. Heads claim only posture — the arm can be anything
        // while sitting/standing/lying quietly.
        let postureGroup = [
            task("posture.sitting-quietly", "Sitting quietly", cat.posture.rawValue,
                 "Sit in a chair with your feet flat and hands relaxed. Stay as still as you comfortably can for the whole interval. Between repetitions, vary your arm position (hands in your lap, resting on the table, hanging at your side) and keep a relaxed, natural wrist.",
                 duration: 45, repetitions: 3, posture: PostureClass.seatedLikely.rawValue),
            task("posture.standing-quietly", "Standing quietly", cat.posture.rawValue,
                 "Stand still with your weight on both feet. Stay as still as you comfortably can. Between repetitions, vary your arm position (arms at your sides, hands clasped in front or behind) and stand naturally, not frozen.",
                 duration: 45, repetitions: 3, posture: PostureClass.uprightStationary.rawValue),
            task("posture.lying-down", "Lying down", cat.posture.rawValue,
                 "Lie down on a bed or sofa on your back, relaxed. Stay as still as you comfortably can. Between repetitions, vary your arm position (at your sides, on your chest or abdomen) and keep your wrist relaxed.",
                 duration: 45, repetitions: 3, posture: PostureClass.recumbent.rawValue),
        ]

        // Spec §7.4 desk/arm: seated, with a fine semantic tag on top of the arm head.
        let deskGroup = [
            task("desk.desk-work", "Desk work", cat.desk.rawValue,
                 "Work at a desk as you normally would (computer, reading, writing). Between repetitions, vary your desk posture, arm position and wrist placement (relaxed vs active), and switch which hand leads.",
                 duration: 60, repetitions: 3, posture: PostureClass.seatedLikely.rawValue,
                 armBehavior: ArmBehaviorClass.deskLike.rawValue, semanticTag: ActivityGroundTruthSemanticTag.deskWork.rawValue),
            task("desk.typing", "Typing", cat.desk.rawValue,
                 "Type at a keyboard at your natural pace. Between repetitions, alternate which hand carries the rhythm, adjust your wrist height and how relaxed your wrists are, and keep a natural typing speed.",
                 duration: 45, repetitions: 3, posture: PostureClass.seatedLikely.rawValue,
                 armBehavior: ArmBehaviorClass.repetitiveHandMotion.rawValue, semanticTag: ActivityGroundTruthSemanticTag.typing.rawValue),
            task("desk.writing-mouse", "Writing or mouse use", cat.desk.rawValue,
                 "Write by hand or use a mouse at your natural pace. Between repetitions, alternate dominant and non-dominant hand use, change your grip and wrist placement, and keep a natural rhythm.",
                 duration: 45, repetitions: 3, posture: PostureClass.seatedLikely.rawValue,
                 armBehavior: ArmBehaviorClass.deskLike.rawValue, semanticTag: ActivityGroundTruthSemanticTag.writing.rawValue),
            task("desk.fidgeting-seated", "Fidgeting while seated", cat.desk.rawValue,
                 "Stay seated and fidget naturally as you might during a long meeting: shift in your seat, tap, stretch, adjust. Between repetitions, vary the fidget movements, your arm position and which hand is involved.",
                 duration: 30, repetitions: 3, posture: PostureClass.seatedLikely.rawValue,
                 armBehavior: ArmBehaviorClass.fidgeting.rawValue, semanticTag: ActivityGroundTruthSemanticTag.fidgeting.rawValue),
            task("desk.phone-use", "Quiet phone use", cat.desk.rawValue,
                 "Sit quietly and use your phone as you normally would (scroll or read). Between repetitions, hold the phone in your dominant vs non-dominant hand, change how your arm rests, and relax your wrist.",
                 duration: 45, repetitions: 2, posture: PostureClass.seatedLikely.rawValue,
                 armBehavior: ArmBehaviorClass.quiet.rawValue, semanticTag: ActivityGroundTruthSemanticTag.phoneUse.rawValue),
        ]

        // Spec §7.4 locomotion. Running/stairs/cycling are optional (safety/availability); the wording
        // says so because the task type has no separate "optional" flag.
        let locomotionGroup = [
            task("locomotion.walking", "Normal walking", cat.locomotion.rawValue,
                 "Walk at your normal, comfortable pace. Between repetitions, keep a natural stride and arm swing, and don't force a scripted gait — walk as you naturally would.",
                 duration: 90, repetitions: 2, locomotion: LocomotionClass.walking.rawValue),
            task("locomotion.brisk-walking", "Brisk walking", cat.locomotion.rawValue,
                 "Walk briskly, as if you're slightly late. Between repetitions, pick a comfortably brisk pace and keep a natural arm swing; don't force the speed.",
                 duration: 90, repetitions: 2, locomotion: LocomotionClass.briskWalking.rawValue),
            task("locomotion.running", "Running", cat.locomotion.rawValue,
                 "Run at a comfortable jogging pace — only if it is safe and available to you. Between repetitions, run at your natural pace with relaxed arms and a natural wrist.",
                 duration: 60, repetitions: 2, locomotion: LocomotionClass.running.rawValue),
            task("locomotion.stairs", "Stairs", cat.locomotion.rawValue,
                 "Walk up and down stairs at a normal pace — only if stairs are available to you. Between repetitions, vary using a railing vs not, and keep a natural arm swing.",
                 duration: 60, repetitions: 2, locomotion: LocomotionClass.stairs.rawValue),
            task("locomotion.cycling", "Cycling", cat.locomotion.rawValue,
                 "Cycle at a comfortable, steady pace (a stationary bike is fine) — optional, when available. Keep a natural grip and relaxed wrist, and vary your effort slightly between repetitions.",
                 duration: 120, repetitions: 1, locomotion: LocomotionClass.cycling.rawValue),
        ]

        // Spec §7.4 transitions: 10 reps each, ~8 s stable pre-state + the event + ~8 s stable post-state
        // (durationSeconds 20 models the whole labeled interval). Heads stay nil — the interval contains
        // both pre- and post-state, so no single head value is true over all of it; evaluation uses the
        // definitive transition_kind/transition_ts and the surrounding raw seconds.
        let transitionGroup = [
            task("transition.sit-to-stand", "Sit → stand", cat.transition.rawValue,
                 "Sit in a chair, relaxed. On the cue, stand up naturally and stay still. Each repetition is ~8 s sitting, the stand-up, then ~8 s standing. Between repetitions, vary your arm position and hand use, and move at your natural speed.",
                 duration: 20, repetitions: 10, restSeconds: 8,
                 transitionKind: ActivityGroundTruthTransitionKind.sitToStand.rawValue, preState: 8, postState: 8),
            task("transition.stand-to-sit", "Stand → sit", cat.transition.rawValue,
                 "Stand still, relaxed. On the cue, sit down naturally and stay still. Each repetition is ~8 s standing, the sit-down, then ~8 s sitting. Between repetitions, vary your arm position and hand use, and move at your natural speed.",
                 duration: 20, repetitions: 10, restSeconds: 8,
                 transitionKind: ActivityGroundTruthTransitionKind.standToSit.rawValue, preState: 8, postState: 8),
            task("transition.lying-down", "Lying down", cat.transition.rawValue,
                 "Stand next to a bed or sofa. On the cue, lie down naturally and stay still. Each repetition is ~8 s standing, the lie-down, then ~8 s lying. Between repetitions, vary which side you use, your arm position, and your natural speed.",
                 duration: 20, repetitions: 10, restSeconds: 8,
                 transitionKind: ActivityGroundTruthTransitionKind.lyingDown.rawValue, preState: 8, postState: 8),
            task("transition.getting-up", "Getting up", cat.transition.rawValue,
                 "Lie down, relaxed. On the cue, get up and stand naturally, then stay still. Each repetition is ~8 s lying, the get-up, then ~8 s standing. Between repetitions, vary your arm use and your natural speed.",
                 duration: 20, repetitions: 10, restSeconds: 8,
                 transitionKind: ActivityGroundTruthTransitionKind.gettingUp.rawValue, preState: 8, postState: 8),
            task("transition.walk-start", "Walk start", cat.transition.rawValue,
                 "Stand still, relaxed. On the cue, start walking at your natural pace. Each repetition is ~8 s standing, the start, then ~8 s walking. Between repetitions, vary which foot leads, your arm swing, and your natural speed.",
                 duration: 20, repetitions: 10, restSeconds: 8,
                 transitionKind: ActivityGroundTruthTransitionKind.walkStart.rawValue, preState: 8, postState: 8),
            task("transition.walk-stop", "Walk stop", cat.transition.rawValue,
                 "Walk at your natural pace. On the cue, stop and stand still. Each repetition is ~8 s walking, the stop, then ~8 s standing. Between repetitions, vary your deceleration, arm position, and your natural speed.",
                 duration: 20, repetitions: 10, restSeconds: 8,
                 transitionKind: ActivityGroundTruthTransitionKind.walkStop.rawValue, preState: 8, postState: 8),
        ]

        return ActivityCalibrationProtocolModel(
            version: "calibration-v1",
            tasks: postureGroup + deskGroup + locomotionGroup + transitionGroup)
    }()
}

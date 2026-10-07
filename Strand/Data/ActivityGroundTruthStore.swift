import Foundation
import StrandAnalytics

// ActivityGroundTruthStore.swift — the phone's copy of the wearer's ground-truth activity labels.
//
// Guided calibration bouts and weak stretch-feedback corrections are the user's own data and cannot be
// rebuilt, so they live in Application Support (and in device backups) rather than in a cache folder, and
// are only dropped once the server has confirmed them. Each label is enriched at save time with the
// raw-IMU coverage that backs it (`sensorQuality` + `rawRefs`), read from the phone's own IMU store, so
// an evaluation row is judged "ready" or "gap-ridden" on disk without a second lookup — and a label with
// no evidence at all is recorded as explicitly missing (never as a silent nil).

final class ActivityGroundTruthStore: @unchecked Sendable {
    static let shared = ActivityGroundTruthStore()

    /// Older labels are dropped from the phone once the server has them, so the file stays small.
    static let keepSyncedDays = 120
    /// A file that cannot be read in full is copied aside before it is replaced; this many copies are kept.
    static let keepUnreadableCopies = 5
    static let unreadablePrefix = "ground-truth-labels.unreadable-"
    /// The raw-IMU store records one row per second at this rate. It mirrors
    /// `ImuSessionFileStore.sampleRate` (100 Hz), but is a constant here because that static is
    /// main-actor-isolated and coverage runs off the actor.
    static let sampleRateHz = 100

    /// How the store learns which raw-IMU seconds exist for a label: `(deviceId, startTs, endTs)` → the
    /// distinct second timestamps found, or nil when no lookup is possible (unknown device). Production
    /// hops to `ImuSessionFileStore` on the main actor; tests inject a fake.
    typealias CoverageReader = @Sendable (String, Int, Int) -> [Int64]?

    private let fileURL: URL
    private let lock = NSLock()
    private var cache: [ActivityGroundTruthLabel]?
    private let coverageReader: CoverageReader
    private let currentBuild: @Sendable () -> String?

    init(fileURL: URL? = nil, coverageReader: @escaping CoverageReader = ActivityGroundTruthStore.readCoverageSeconds,
         currentBuild: @escaping @Sendable () -> String? = {
             Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
         }) {
        self.currentBuild = currentBuild
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let fm = FileManager.default
            let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
            let dir = base.appendingPathComponent("OpenWhoop/ActivityGroundTruth", isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            #if os(iOS)
            try? fm.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                  ofItemAtPath: dir.path)
            #endif
            self.fileURL = dir.appendingPathComponent("ground-truth-labels.json")
        }
        self.coverageReader = coverageReader
    }

    func all() -> [ActivityGroundTruthLabel] {
        lock.lock(); defer { lock.unlock() }
        return loadLocked()
    }

    /// Insert or replace the label stored under the same `labelKey`, filling `sensorQuality` + `rawRefs`
    /// from the phone's own raw-IMU store first when the label does not carry them yet. Returns the
    /// enriched copy that was persisted.
    ///
    /// Enrichment runs OUTSIDE the lock: the production reader hops to the main actor, and holding the
    /// store lock across a hop would let a main-thread reader deadlock against it. Enrichment depends
    /// only on the label and the reader, never on store state, so computing it before locking is safe.
    @discardableResult
    func upsert(_ label: ActivityGroundTruthLabel) -> ActivityGroundTruthLabel {
        let enriched = enrich(label)
        lock.lock(); defer { lock.unlock() }
        var rows = loadLocked()
        if let i = rows.firstIndex(where: { $0.labelKey == enriched.labelKey }) {
            rows[i] = enriched
        } else {
            rows.append(enriched)
        }
        saveLocked(rows)
        return enriched
    }

    func pending() -> [ActivityGroundTruthLabel] {
        all().filter(\.needsSync).sorted { $0.updatedAt < $1.updatedAt }
    }

    /// Record that the server holds each `(id, updatedAt)`. A label edited after it was sent keeps its
    /// newer `updatedAt`, so it stays pending and goes out again.
    func markSynced(_ sent: [(id: UUID, updatedAt: Date)], at when: Date = Date()) {
        lock.lock(); defer { lock.unlock() }
        var rows = loadLocked()
        for s in sent {
            guard let i = rows.firstIndex(where: { $0.id == s.id }) else { continue }
            if rows[i].updatedAt <= s.updatedAt { rows[i].syncedAt = max(when, rows[i].updatedAt) }
        }
        let cutoff = when.addingTimeInterval(-Double(Self.keepSyncedDays) * 86_400)
        rows.removeAll { !$0.needsSync && $0.updatedAt < cutoff }
        saveLocked(rows)
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        cache = []
        try? FileManager.default.removeItem(at: fileURL)
        try? FileManager.default.removeItem(at: quarantineURL)
    }

    // MARK: - Quarantine

    /// One label the server refused as malformed, parked out of the upload queue.
    struct QuarantinedLabel: Codable, Equatable {
        var label: ActivityGroundTruthLabel
        var reason: String
        /// The app build that was running when the server refused it.
        var build: String?
    }

    private var quarantineURL: URL {
        fileURL.deletingLastPathComponent()
            .appendingPathComponent(fileURL.deletingPathExtension().lastPathComponent + ".quarantine.json")
    }

    /// Move labels the server refused as structurally invalid (`invalid_*`) out of the upload queue, so one
    /// malformed label does not get re-sent on every scene activation. They are kept, not deleted: an
    /// `invalid_*` refusal can also mean the server is older than the app (a vocabulary value it does not know
    /// yet), and these are the user's own labels. A label edited after the refused copy was sent stays queued.
    @discardableResult
    func quarantine(_ refused: [(labelKey: String, updatedAt: Date, reason: String)]) -> Int {
        guard !refused.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var rows = loadLocked()
        var parked = loadQuarantineLocked()
        let build = currentBuild()
        var moved = 0
        for r in refused {
            guard let i = rows.firstIndex(where: { $0.labelKey == r.labelKey }),
                  rows[i].updatedAt <= r.updatedAt else { continue }
            parked.removeAll { $0.label.labelKey == r.labelKey }
            parked.append(QuarantinedLabel(label: rows[i], reason: r.reason, build: build))
            rows.remove(at: i)
            moved += 1
        }
        guard moved > 0 else { return 0 }
        saveQuarantineLocked(parked)
        saveLocked(rows)
        return moved
    }

    func quarantined() -> [QuarantinedLabel] {
        lock.lock(); defer { lock.unlock() }
        return loadQuarantineLocked()
    }

    /// Put quarantined labels back in the queue once a different app build is running — the build that
    /// built them wrong, or the server that did not know their values yet, may have been fixed since. A
    /// label re-saved meanwhile under the same key keeps its newer copy.
    func releaseQuarantined() {
        lock.lock(); defer { lock.unlock() }
        let parked = loadQuarantineLocked()
        guard !parked.isEmpty else { return }
        let build = currentBuild()
        let (release, keep) = (parked.filter { $0.build != build }, parked.filter { $0.build == build })
        guard !release.isEmpty else { return }
        var rows = loadLocked()
        let present = Set(rows.map(\.labelKey))
        rows.append(contentsOf: release.map(\.label).filter { !present.contains($0.labelKey) })
        saveLocked(rows)
        saveQuarantineLocked(keep)
    }

    private func loadQuarantineLocked() -> [QuarantinedLabel] {
        guard let data = try? Data(contentsOf: quarantineURL), !data.isEmpty else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
        if let parked = try? decoder.decode([QuarantinedLabel].self, from: data) { return parked }
        setAside(data)
        return []
    }

    private func saveQuarantineLocked(_ parked: [QuarantinedLabel]) {
        if parked.isEmpty { try? FileManager.default.removeItem(at: quarantineURL); return }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(parked) else { return }
        try? data.write(to: quarantineURL, options: [.atomic])
    }

    /// Pure coverage over a flat second list. A second counts when it lies in the half-open interval
    /// [from, to) — `to` is exclusive, matching the store's window convention, so a record exactly at the
    /// label's end does not count and a gap never extends past the interval. A maximal run of missing
    /// seconds is ONE `Gap(startTs, endTs)` (half-open, `endTs` exclusive), never split at file-bucket
    /// boundaries: the reader already merged every record into one flat list, so the 30-minute segment
    /// files cannot leak artificial splits into a label's quality.
    static func coverage(seconds: [Int64], from: Int, to: Int, sampleRateHz: Int) -> ActivityGroundTruthSensorQuality {
        let expected = max(0, to - from)
        guard expected > 0 else {
            // A zero-length interval has nothing to evaluate; the derived init reports it as explicitly
            // not evaluation-ready (its `evaluationReady` requires expectedSeconds > 0).
            return ActivityGroundTruthSensorQuality(expectedSeconds: 0, coveredSeconds: 0, sampleRateHz: sampleRateHz)
        }
        let from64 = Int64(from), to64 = Int64(to)
        var covered = Set<Int64>()
        for s in seconds where s >= from64 && s < to64 { covered.insert(s) }
        let sorted = covered.sorted()
        var gaps: [ActivityGroundTruthGap] = []
        var scan = from64
        for s in sorted {
            if s > scan { gaps.append(ActivityGroundTruthGap(startTs: Int(scan), endTs: Int(s))) }
            scan = s + 1
        }
        if scan < to64 { gaps.append(ActivityGroundTruthGap(startTs: Int(scan), endTs: to)) }
        // coverageRatio and evaluationReady are derived inside the value type from the two counts.
        return ActivityGroundTruthSensorQuality(
            expectedSeconds: expected, coveredSeconds: sorted.count, sampleRateHz: sampleRateHz,
            firstTs: sorted.first.map { Int($0) }, lastTs: sorted.last.map { Int($0) }, gaps: gaps)
    }

    /// The explicit "no evidence" quality: covered 0, the whole interval reported as one gap. Never nil —
    /// a label the phone cannot back with raw seconds must still record that it is not evaluation-ready.
    static func missingQuality(from: Int, to: Int) -> ActivityGroundTruthSensorQuality {
        let expected = max(0, to - from)
        let gaps = expected > 0 ? [ActivityGroundTruthGap(startTs: from, endTs: to)] : []
        return ActivityGroundTruthSensorQuality(expectedSeconds: expected, coveredSeconds: 0,
                                                sampleRateHz: Self.sampleRateHz, gaps: gaps)
    }

    // MARK: - Enrichment

    /// Fill `sensorQuality` + `rawRefs` from the raw-IMU store when the label does not already carry them.
    /// The phone's IMU is keyed by the open-ended activity window `"activity-<deviceId>"` — the same id the
    /// object lane uploads — so the fact names exactly what the server can re-join.
    private func enrich(_ label: ActivityGroundTruthLabel) -> ActivityGroundTruthLabel {
        guard label.sensorQuality == nil else { return label }
        var enriched = label
        let from = label.startTs, to = label.endTs
        if let deviceId = label.deviceId,
           let seconds = coverageReader(deviceId, from, to) {
            let quality = Self.coverage(seconds: seconds, from: from, to: to, sampleRateHz: Self.sampleRateHz)
            enriched.sensorQuality = quality
            enriched.rawRefs = [ActivityGroundTruthRawRef(
                storeSessionId: ActivityImuCapture.windowId(deviceId: deviceId),
                startTs: from, endTs: to, sampleRateHz: Self.sampleRateHz, coveredSeconds: quality.coveredSeconds)]
        } else {
            enriched.sensorQuality = Self.missingQuality(from: from, to: to)
            enriched.rawRefs = []
        }
        return enriched
    }

    /// Production coverage reader. The IMU store is `@MainActor`, so the read runs on the main actor
    /// synchronously: in place when already on main, otherwise by a main-queue hop. The caller (upsert's
    /// enrichment) holds no store lock, so the hop can never deadlock a main-thread reader against this
    /// store's lock.
    private static func readCoverageSeconds(deviceId: String, from: Int, to: Int) -> [Int64]? {
        let read: @MainActor () -> [Int64] = {
            ImuSessionFileStore.shared.readRecords(deviceId: deviceId, fromTs: Int64(from), toTs: Int64(to)).map(\.ts)
        }
        if Thread.isMainThread { return MainActor.assumeIsolated(read) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(read) }
    }

    // MARK: - Durability

    private func loadLocked() -> [ActivityGroundTruthLabel] {
        if let cache { return cache }
        var rows: [ActivityGroundTruthLabel] = []
        if FileManager.default.fileExists(atPath: fileURL.path) {
            // A file that is there but cannot be opened right now (iOS keeps it sealed until the phone has been
            // unlocked once after a restart) reads as empty for this call only. Remembering "empty" would let the
            // next save replace the labels that are really in it.
            guard let data = try? Data(contentsOf: fileURL) else { return [] }
            if !data.isEmpty {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601WithFractionalSeconds
                if let entries = try? decoder.decode([Readable].self, from: data) {
                    rows = entries.compactMap(\.record)
                    if rows.count != entries.count { setAside(data) }
                } else {
                    setAside(data)
                }
            }
        }
        cache = rows
        return rows
    }

    /// One entry of the stored array. An entry that cannot be read comes back empty instead of failing the
    /// whole file, so the labels next to it are kept.
    private struct Readable: Decodable {
        let record: ActivityGroundTruthLabel?
        init(from decoder: Decoder) throws { record = try? ActivityGroundTruthLabel(from: decoder) }
    }

    /// Copy what was on disk aside before the next save replaces it. A label cannot be rebuilt, so a file
    /// this build could not fully read must not be destroyed by the save that follows.
    private func setAside(_ data: Data) {
        let fm = FileManager.default
        let dir = fileURL.deletingLastPathComponent()
        let stamp = Int(Date().timeIntervalSince1970)
        try? data.write(to: dir.appendingPathComponent("\(Self.unreadablePrefix)\(stamp).json"), options: [.atomic])
        let copies = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(Self.unreadablePrefix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in copies.dropLast(Self.keepUnreadableCopies) { try? fm.removeItem(at: old) }
    }

    private func saveLocked(_ rows: [ActivityGroundTruthLabel]) {
        cache = rows
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601WithFractionalSeconds
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(rows) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}

private extension JSONDecoder.DateDecodingStrategy {
    static let iso8601WithFractionalSeconds = JSONDecoder.DateDecodingStrategy.custom { decoder in
        let text = try decoder.singleValueContainer().decode(String.self)
        if let date = ActivityGroundTruthDates.fractional.date(from: text) ?? ActivityGroundTruthDates.plain.date(from: text) {
            return date
        }
        throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
    }
}

private extension JSONEncoder.DateEncodingStrategy {
    static let iso8601WithFractionalSeconds = JSONEncoder.DateEncodingStrategy.custom { date, encoder in
        var container = encoder.singleValueContainer()
        try container.encode(ActivityGroundTruthDates.fractional.string(from: date))
    }
}

private enum ActivityGroundTruthDates {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    static let plain = ISO8601DateFormatter()
}

// MARK: - Upload

/// Sends ground-truth labels to the `scores` edge function (`POST /ground-truth-labels`), where they are
/// stored with the raw evidence they reference so they can be used to tune the activity classifier. Best
/// effort: anything that does not get through stays on the phone and goes out on the next attempt, and a
/// label is never dropped for failing to upload.
final class ActivityGroundTruthCloudSync: Sendable {
    static let batchSize = 25

    private let session: URLSession
    private let endpoint: @Sendable () -> URL?
    private let identity: @Sendable () -> CloudPushIdentity?
    private let store: ActivityGroundTruthStore

    init(store: ActivityGroundTruthStore = .shared,
         session: URLSession = .shared,
         endpoint: @escaping @Sendable () -> URL? = { PlacementCloudSync.derivedEndpoint() },
         identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() }) {
        self.store = store
        self.session = session
        self.endpoint = endpoint
        self.identity = identity
    }

    /// Why nothing could be sent at all.
    enum Blocked: Equatable {
        /// Nobody is signed in on this phone, or the server did not accept the credential it holds.
        case signedOut
        /// This build has no cloud address to send to.
        case noServer
    }

    struct Outcome: Equatable {
        var uploaded = 0
        var rejected = 0
        var blocked: Blocked?
        /// Labels refused as structurally invalid and moved out of the queue (see `quarantine`).
        var quarantined = 0
        /// The server's reason for each label it did not take, by label key.
        var refusals: [String: String] = [:]
    }

    /// Upload every label that still needs it, oldest first, in batches. Throws on a transport or server
    /// error after recording whatever was accepted before it.
    @discardableResult
    func pushPending() async throws -> Outcome {
        var outcome = Outcome()
        store.releaseQuarantined()
        let pending = store.pending()
        guard !pending.isEmpty else { return outcome }
        guard let id = identity() else { outcome.blocked = .signedOut; return outcome }
        guard let base = endpoint() else { outcome.blocked = .noServer; return outcome }

        for start in stride(from: 0, to: pending.count, by: Self.batchSize) {
            let batch = Array(pending[start..<min(pending.count, start + Self.batchSize)])
            var request = URLRequest(url: base.appendingPathComponent("ground-truth-labels"), timeoutInterval: 30)
            request.httpMethod = "POST"
            CloudReceiverAuth.apply(id, to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONEncoder().encode(Body(labels: batch.map(GroundTruthLabelWire.init)))

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ActivityGroundTruthSyncError.serverRejected }
            if http.statusCode == 401 || http.statusCode == 403 {
                outcome.blocked = .signedOut
                return outcome
            }
            guard (200..<300).contains(http.statusCode), Self.isReadable(data) else {
                throw ActivityGroundTruthSyncError.serverRejected
            }
            let result = Self.accepted(in: data, batch: batch)
            store.markSynced(result.accepted.map { (id: $0.id, updatedAt: $0.updatedAt) })
            outcome.uploaded += result.accepted.count
            outcome.rejected += result.rejected

            var reasons = Self.refusals(in: data)
            let took = Set(result.accepted.map(\.labelKey))
            for f in batch where !took.contains(f.labelKey) && reasons[f.labelKey] == nil {
                reasons[f.labelKey] = "not_confirmed"
            }
            let structural = batch.compactMap { label -> (labelKey: String, updatedAt: Date, reason: String)? in
                guard let reason = reasons[label.labelKey], reason.hasPrefix("invalid_") else { return nil }
                return (label.labelKey, label.updatedAt, reason)
            }
            outcome.quarantined += store.quarantine(structural)
            outcome.refusals.merge(reasons) { _, new in new }
        }
        return outcome
    }

    private struct Body: Encodable { let labels: [GroundTruthLabelWire] }

    /// Whether a 2xx reply is the JSON object the route sends. Anything else (a captive portal's page, a proxy's
    /// error body) says nothing about what was stored, so the batch is tried again rather than guessed at.
    static func isReadable(_ data: Data) -> Bool {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) != nil
    }

    /// The server's reason code for each label in `rejected`, by label key.
    static func refusals(in data: Data) -> [String: String] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["rejected"] as? [[String: Any]] else { return [:] }
        var out: [String: String] = [:]
        for row in rows {
            if let key = row["label_key"] as? String { out[key] = (row["reason"] as? String) ?? "rejected" }
        }
        return out
    }

    /// Which labels of `batch` the server took. `saved` and `ignored` (an older copy of something it already
    /// holds) are both done; `rejected` ones, and anything the reply does not name, stay queued. A reply that
    /// cannot be read takes nothing, so an unexpected body never loses a label.
    static func accepted(in data: Data, batch: [ActivityGroundTruthLabel])
        -> (accepted: [ActivityGroundTruthLabel], rejected: Int) {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return ([], 0) }
        func keys(_ name: String) -> Set<String> {
            Set(((json[name] as? [[String: Any]]) ?? []).compactMap { $0["label_key"] as? String })
        }
        let done = keys("saved").union(keys("ignored"))
        let rejectedKeys = keys("rejected")
        return (batch.filter { done.contains($0.labelKey) && !rejectedKeys.contains($0.labelKey) },
                rejectedKeys.count)
    }
}

enum ActivityGroundTruthSyncError: Error {
    case serverRejected
}

// MARK: - Wire form

/// The JSON the `scores` edge function's `POST /ground-truth-labels` route takes, one per label, with the
/// exact snake_case field names of the route validator and the `activity_ground_truth_labels` table. The
/// nested `cue_context` / `sensor_quality` / `raw_refs` values encode through the StrandAnalytics types'
/// own snake_case `CodingKeys` — the wire reuses their shapes, never re-defines them.
struct GroundTruthLabelWire: Encodable, Sendable {
    let id: String
    let labelKey: String
    let source: String
    let sessionId: String?
    let protocolVersion: String?
    let repetition: Int?
    let deviceId: String?
    let externalDeviceId: String?
    let startTs: Int
    let endTs: Int
    let posture: String?
    let locomotion: String?
    let armBehavior: String?
    let transitionKind: String?
    let transitionTs: Int?
    let semanticTag: String?
    let labelConfidence: Double?
    let userUnsure: Bool
    let note: String?
    let cueContext: ActivityGroundTruthCueContext?
    let sensorQuality: ActivityGroundTruthSensorQuality?
    let rawRefs: [ActivityGroundTruthRawRef]?
    let modelContextAtLabelTime: [String: String]?
    let appVersion: String?
    let appBuild: String?
    let tzOffsetS: Int
    let clientCreatedAt: String
    let clientUpdatedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case labelKey = "label_key", source
        case sessionId = "session_id", protocolVersion = "protocol_version"
        case repetition, deviceId = "device_id", externalDeviceId = "external_device_id"
        case startTs = "start_ts", endTs = "end_ts"
        case posture, locomotion, armBehavior = "arm_behavior"
        case transitionKind = "transition_kind", transitionTs = "transition_ts"
        case semanticTag = "semantic_tag"
        case labelConfidence = "label_confidence", userUnsure = "user_unsure", note
        case cueContext = "cue_context", sensorQuality = "sensor_quality", rawRefs = "raw_refs"
        case modelContextAtLabelTime = "model_context_at_label_time"
        case appVersion = "app_version", appBuild = "app_build"
        case tzOffsetS = "tz_offset_s", clientCreatedAt = "client_created_at", clientUpdatedAt = "client_updated_at"
    }

    init(_ label: ActivityGroundTruthLabel) {
        id = label.id.uuidString.lowercased()
        labelKey = label.labelKey
        source = label.source.rawValue
        sessionId = label.sessionId
        protocolVersion = label.protocolVersion
        repetition = label.repetition
        deviceId = label.deviceId
        externalDeviceId = label.externalDeviceId
        startTs = label.startTs; endTs = label.endTs
        posture = label.posture; locomotion = label.locomotion; armBehavior = label.armBehavior
        transitionKind = label.transitionKind; transitionTs = label.transitionTs
        semanticTag = label.semanticTag
        labelConfidence = label.labelConfidence.flatMap { $0.isFinite ? $0 : nil }
        userUnsure = label.userUnsure
        note = label.note
        cueContext = label.cueContext
        sensorQuality = label.sensorQuality
        rawRefs = label.rawRefs
        modelContextAtLabelTime = label.modelContextAtLabelTime
        appVersion = label.appVersion; appBuild = label.appBuild
        tzOffsetS = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(label.startTs)))
        clientCreatedAt = Self.iso(label.createdAt)
        clientUpdatedAt = Self.iso(label.updatedAt)
    }

    static func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

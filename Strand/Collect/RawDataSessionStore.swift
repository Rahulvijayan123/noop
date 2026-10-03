import Combine
import Foundation
import WhoopStore

/// Persistent, user-controlled 5/MG capture sessions. This is the iOS/macOS twin of Android's
/// GroundTruthCollector: it records bounded raw-data windows with optional comments.
@MainActor
final class RawDataSessionStore: ObservableObject {
    struct Event: Codable, Identifiable, Equatable {
        var id = UUID()
        var atMs: Int64
        let kind: String
        var markerId: String?
        var markerType: String?
        var text: String?
        // C8 Fix F: duration-bearing activity intervals (kind == "activityInterval"). `endAtMs` is
        // the interval end (ms), `label` the activity label, `provenance` its source. Optional, so
        // persisted instant markers and sessions decode unchanged.
        var endAtMs: Int64?
        var label: String?
        var provenance: String?
    }

    struct Session: Codable, Identifiable, Equatable {
        let id: String
        let deviceId: String
        let startedAtMs: Int64
        var endedAtMs: Int64?
        var capturedStartedAtMs: Int64?
        var capturedEndedAtMs: Int64?
        var comment: String
        var exported: Bool
        var lastExportedAtMs: Int64?
        var events: [Event]

        var active: Bool { endedAtMs == nil }
    }

    @Published private(set) var sessions: [Session] = []
    var active: Session? { sessions.first(where: \.active) }

    private let directory: URL
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    init(directory override: URL? = nil, fileManager: FileManager = .default) {
        let base = (try? fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                         appropriateFor: nil, create: true)) ?? fileManager.temporaryDirectory
        directory = override ?? base.appendingPathComponent("OpenWhoop/RawDataSessions", isDirectory: true)
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory,
                    includingPropertiesForKeys: nil)) ?? []
        sessions = urls.filter { $0.pathExtension == "json" }
            .compactMap { try? Data(contentsOf: $0) }
            .compactMap { try? decoder.decode(Session.self, from: $0) }
            .sorted { $0.startedAtMs > $1.startedAtMs }
    }

    @discardableResult
    func start(deviceId: String, now: Date = Date()) -> Session? {
        guard active == nil else { return nil }
        let millis = Int64(now.timeIntervalSince1970 * 1_000)
        let started = Event(atMs: millis, kind: "start")
        let session = Session(id: String(millis), deviceId: deviceId, startedAtMs: millis,
                              endedAtMs: nil, capturedStartedAtMs: millis, capturedEndedAtMs: nil,
                              comment: "", exported: false, lastExportedAtMs: nil, events: [started])
        sessions.insert(session, at: 0)
        persist(session)
        ImuSessionFileStore.shared.start(id: session.id, deviceId: deviceId, fromMs: millis)
        // C8 Fix D: persist the capture WANT so a reconnect/restore re-arms the BLE transport even
        // when this view is gone (previously the view's `.task`/`onChange` was the only re-arm).
        // Cleared by `stop`, `removeMetadata` and device delete (see `clearPersistedCaptureIntentIfDevice`).
        Self.persistedCaptureIntent = CaptureIntent(sessionId: session.id, deviceId: deviceId)
        return session
    }

    func stop(now: Date = Date()) {
        let activeId = active?.id
        mutateActive { session in
            let millis = Int64(now.timeIntervalSince1970 * 1_000)
            session.endedAtMs = millis
            session.capturedEndedAtMs = millis
            session.events.append(Event(atMs: millis, kind: "stop"))
        }
        if let activeId { ImuSessionFileStore.shared.complete(id: activeId, toMs: Int64(now.timeIntervalSince1970 * 1_000)) }
        // C8 Fix D: the user ended the session — the durable want is gone, so the BLE layer must
        // not re-arm it on the next connect.
        Self.persistedCaptureIntent = nil
    }

    @discardableResult
    func createHistorical(deviceId: String, from: Date, to: Date) -> Session? {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        guard validRange(fromMs, toMs) else { return nil }
        let id = String(Int64(Date().timeIntervalSince1970 * 1_000))
        let events = [Event(atMs: fromMs, kind: "start"), Event(atMs: toMs, kind: "stop")]
        let session = Session(id: id, deviceId: deviceId, startedAtMs: fromMs, endedAtMs: toMs,
                              capturedStartedAtMs: nil, capturedEndedAtMs: nil, comment: "",
                              exported: false, lastExportedAtMs: nil, events: events)
        sessions.insert(session, at: 0); persist(session)
        ImuSessionFileStore.shared.register(id: id, deviceId: deviceId, fromMs: fromMs, toMs: toMs)
        return session
    }

    func setRange(sessionId: String, from: Date, to: Date) {
        let fromMs = Int64(from.timeIntervalSince1970 * 1_000)
        let toMs = Int64(to.timeIntervalSince1970 * 1_000)
        guard validRange(fromMs, toMs) else { return }
        mutate(sessionId) { session in
            guard !session.active else { return }
            session = Session(id: session.id, deviceId: session.deviceId, startedAtMs: fromMs,
                              endedAtMs: toMs, capturedStartedAtMs: session.capturedStartedAtMs,
                              capturedEndedAtMs: session.capturedEndedAtMs, comment: session.comment,
                              exported: false, lastExportedAtMs: nil, events: session.events)
        }
        if let session = sessions.first(where: { $0.id == sessionId }) {
            ImuSessionFileStore.shared.register(id: sessionId, deviceId: session.deviceId, fromMs: fromMs, toMs: toMs)
        }
    }

    func setComment(_ comment: String, sessionId: String) {
        mutate(sessionId) { $0.comment = String(comment.prefix(4_000)) }
    }

    @discardableResult
    func addMarker(sessionId: String, at: Date, type: String, text: String) -> Event? {
        guard Self.markerTypes.contains(type) else { return nil }
        var added: Event?
        mutate(sessionId) { session in
            let atMs = Self.clamp(Int64(at.timeIntervalSince1970 * 1_000), to: session)
            let marker = Event(atMs: atMs, kind: "marker", markerId: UUID().uuidString,
                               markerType: type, text: String(text.prefix(500)))
            session.events.append(marker)
            added = marker
        }
        return added
    }

    /// C8 Fix F: add a duration-bearing activity interval (kind == "activityInterval") beside the
    /// instant markers. Labels are the ontology-v1 motion vocabulary; the interval is stored as a
    /// LOCAL OVERLAY with provenance "user_confirmed" and never overwrites any predicted label
    /// (predicted labels are produced server-side and are not written here).
    @discardableResult
    func addIntervalLabel(sessionId: String, from: Date, to: Date, label: String) -> Event? {
        guard Self.intervalLabels.contains(label) else { return nil }
        var added: Event?
        mutate(sessionId) { session in
            let fromMs = Self.clamp(Int64(from.timeIntervalSince1970 * 1_000), to: session)
            let toMs = Self.clamp(Int64(to.timeIntervalSince1970 * 1_000), to: session)
            guard fromMs < toMs else { return }
            let interval = Event(atMs: fromMs, kind: "activityInterval", markerId: UUID().uuidString,
                                 markerType: label, text: nil, endAtMs: toMs, label: label,
                                 provenance: Self.intervalProvenance)
            session.events.append(interval)
            added = interval
        }
        return added
    }

    /// C8 Fix F: edit a user-confirmed interval's range/label. Provenance is preserved untouched —
    /// a local overlay stays "user_confirmed" and is never mutated toward "predicted".
    func updateIntervalLabel(sessionId: String, intervalId: String, from: Date, to: Date, label: String) {
        guard Self.intervalLabels.contains(label) else { return }
        mutate(sessionId) { session in
            guard let index = session.events.firstIndex(where: {
                $0.kind == "activityInterval" && $0.markerId == intervalId }) else { return }
            let fromMs = Self.clamp(Int64(from.timeIntervalSince1970 * 1_000), to: session)
            let toMs = Self.clamp(Int64(to.timeIntervalSince1970 * 1_000), to: session)
            guard fromMs < toMs else { return }
            session.events[index].atMs = fromMs
            session.events[index].endAtMs = toMs
            session.events[index].label = label
            session.events[index].markerType = label
        }
    }

    func updateMarker(sessionId: String, markerId: String, at: Date, type: String, text: String) {
        guard Self.markerTypes.contains(type) else { return }
        mutate(sessionId) { session in
            guard let index = session.events.firstIndex(where: { $0.markerId == markerId }) else { return }
            session.events[index].atMs = Self.clamp(Int64(at.timeIntervalSince1970 * 1_000), to: session)
            session.events[index].markerType = type
            session.events[index].text = String(text.prefix(500))
        }
    }

    func deleteMarker(sessionId: String, markerId: String) {
        // Any user record (instant marker or interval label) is removed by its id.
        mutate(sessionId) { $0.events.removeAll { $0.markerId == markerId } }
    }

    func markExported(_ sessionId: String, now: Date = Date()) {
        mutate(sessionId) {
            $0.exported = true
            $0.lastExportedAtMs = Int64(now.timeIntervalSince1970 * 1_000)
        }
    }

    @discardableResult
    func removeMetadata(_ sessionId: String,
                        removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Bool {
        guard sessions.first(where: { $0.id == sessionId })?.active == false else { return false }
        guard ImuSessionFileStore.shared.deleteFiles(sessionId, removeItem: removeItem) else { return false }
        ImuSessionFileStore.shared.remove(id: sessionId)
        do {
            let metadata = file(sessionId)
            if FileManager.default.fileExists(atPath: metadata.path) { try removeItem(metadata) }
        } catch { return false }
        sessions.removeAll { $0.id == sessionId }
        // C8 Fix D: deleting the session also drops its capture want (defensive — `stop` already
        // cleared it, but a session can be removed without a stop on some flows).
        if Self.persistedCaptureIntent?.sessionId == sessionId { Self.persistedCaptureIntent = nil }
        return true
    }

    private func mutateActive(_ body: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: \.active) else { return }
        body(&sessions[index])
        persist(sessions[index])
    }

    private func mutate(_ id: String, _ body: (inout Session) -> Void) {
        guard let index = sessions.firstIndex(where: { $0.id == id }) else { return }
        body(&sessions[index])
        persist(sessions[index])
    }

    private func persist(_ session: Session) {
        guard let data = try? encoder.encode(session) else { return }
        try? data.write(to: file(session.id), options: .atomic)
    }

    private func file(_ id: String) -> URL { directory.appendingPathComponent("session-\(id).json") }

    private func validRange(_ from: Int64, _ to: Int64) -> Bool {
        from > 0 && from <= to && to - from <= 7 * 24 * 60 * 60 * 1_000
    }

    static let markerTypes = ["moment", "start", "end", "issue"]

    /// C8 Fix F: ontology-v1 motion labels a user can confirm locally as duration-bearing
    /// intervals (kind "activityInterval"), distinct from the instant marker types above.
    static let intervalLabels = ["walking", "running", "sitting", "standing", "other_movement"]
    /// Provenance stamped on every locally-added interval. Predicted labels are server-produced
    /// and never written here, so a correction is always a "user_confirmed" local overlay.
    static let intervalProvenance = "user_confirmed"

    private static func clamp(_ atMs: Int64, to session: Session) -> Int64 {
        min(max(atMs, session.startedAtMs), session.endedAtMs ?? Int64(Date().timeIntervalSince1970 * 1_000))
    }

    /// The persisted capture-intent payload (C8 Fix D): which session on which device wants
    /// raw IMU, so the BLE layer can re-arm START_RAW_DATA + TOGGLE_IMU_MODE after a relaunch,
    /// reconnect or state restoration without a live collector view.
    struct CaptureIntent: Codable, Equatable, Sendable {
        var sessionId: String
        var deviceId: String
    }

    // MARK: - C8 Fix D: persisted capture intent

    static let captureIntentKey = "raw-data-session-capture-intent-v1"

    /// The durable "want raw IMU" marker, readable from the BLE layer without a live view.
    /// `start` sets it; `stop`, `removeMetadata` and device delete clear it.
    static var persistedCaptureIntent: CaptureIntent? {
        get {
            guard let data = UserDefaults.standard.data(forKey: Self.captureIntentKey) else { return nil }
            return try? JSONDecoder().decode(CaptureIntent.self, from: data)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: Self.captureIntentKey)
            } else {
                UserDefaults.standard.removeObject(forKey: Self.captureIntentKey)
            }
        }
    }

    /// True when the persisted intent still refers to an ACTIVE session on disk. The BLE re-arm
    /// requires this, so a stale intent (session file removed out from under it) never re-opens
    /// capture. Reads the real session directory (cheap: one small directory listing per connect).
    static var persistedCaptureIntentIsActive: Bool {
        guard let intent = persistedCaptureIntent else { return false }
        return RawDataSessionStore().sessions.contains { $0.id == intent.sessionId && $0.active }
    }

    /// Clear the persisted intent when it belongs to a deleted/unpaired device (C8 Fix D: a
    /// forgotten strap must not re-arm its capture on the next connect; its IMU files are already
    /// deleted by the device wipe).
    static func clearPersistedCaptureIntentIfDevice(_ deviceId: String) {
        if persistedCaptureIntent?.deviceId == deviceId { persistedCaptureIntent = nil }
    }

    /// Clear the persisted intent unconditionally (explicit stop, or the sign-out hook — the app
    /// should call this from `CloudPushIdentity.signOutCurrentOwner` so a signed-out install never
    /// re-arms capture on the next connect).
    static func clearPersistedCaptureIntent() {
        persistedCaptureIntent = nil
    }

    func exportEntries(for session: Session, sensorAvailable: Bool = false) -> [FileExport.BundleEntry] {
        var meta: [String: Any] = [
            "schema_version": 3, "capture_kind": "whoop_5mg_raw_data",
            "session_id": session.id, "device_id": session.deviceId,
            "started_at_ms": session.startedAtMs, "ended_at_ms": session.endedAtMs ?? session.startedAtMs,
            "comment": session.comment,
            "sensor_export_available": sensorAvailable,
            "device_family": "iOS",
            "app_version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
            "markers": session.events.filter {
                $0.kind == "marker" && $0.atMs >= session.startedAtMs
                    && $0.atMs <= (session.endedAtMs ?? session.startedAtMs)
            }.map { marker in
                ["id": marker.markerId ?? "", "at_ms": marker.atMs,
                 "type": marker.markerType ?? "moment", "text": marker.text ?? ""] as [String: Any]
            },
            // C8 Fix F: duration-bearing activity intervals exported beside the markers, each with
            // its provenance ("user_confirmed" for every local overlay today).
            "activity_intervals": session.events.filter {
                $0.kind == "activityInterval" && $0.atMs >= session.startedAtMs
                    && $0.atMs <= (session.endedAtMs ?? session.startedAtMs)
            }.map { interval in
                ["id": interval.markerId ?? "", "start_ms": interval.atMs,
                 "end_ms": interval.endAtMs ?? interval.atMs,
                 "label": interval.label ?? "unknown",
                 "provenance": interval.provenance ?? RawDataSessionStore.intervalProvenance] as [String: Any]
            },
        ]
        if let value = session.capturedStartedAtMs { meta["captured_started_at_ms"] = value }
        if let value = session.capturedEndedAtMs { meta["captured_ended_at_ms"] = value }
        let metaData = (try? JSONSerialization.data(withJSONObject: meta, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let endMs = session.endedAtMs ?? session.startedAtMs
        let publicEvents = [Event(atMs: session.startedAtMs, kind: "start")]
            + session.events.filter {
                ($0.kind == "marker" || $0.kind == "activityInterval")
                    && $0.atMs >= session.startedAtMs && $0.atMs <= endMs
            }.sorted { $0.atMs < $1.atMs }
            + [Event(atMs: endMs, kind: "stop")]
        let eventData = publicEvents.compactMap { event -> Data? in
            var row: [String: Any] = ["at_ms": event.atMs, "kind": event.kind]
            if event.kind == "marker" {
                if let value = event.markerId { row["marker_id"] = value }
                if let value = event.markerType { row["marker_type"] = value }
                if let value = event.text { row["text"] = value }
            } else if event.kind == "activityInterval" {
                if let value = event.markerId { row["interval_id"] = value }
                if let value = event.label { row["label"] = value }
                if let value = event.endAtMs { row["end_ms"] = value }
                row["provenance"] = event.provenance ?? RawDataSessionStore.intervalProvenance
            }
            return try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        }.reduce(into: Data()) { $0.append($1); $0.append(0x0A) }
        return [
            .init(name: "meta.json", data: metaData),
            .init(name: "events.jsonl", data: eventData),
        ]
    }
}

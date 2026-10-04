import Foundation
import GRDB
import WhoopStore

// MARK: - PlacementStore (G4 local persistence)

/// On-device persistence for the effective-dated placement history, in the SAME SQLite database as
/// the app store (the `WhoopStore` `DatabaseWriter`, exposed as `store.registryWriter`). Follows the
/// `DeviceRegistryStore` house pattern: a synchronous, `Sendable` GRDB wrapper over the writer.
///
/// Two tables live here:
///   - `placementInterval` — the folded read model (half-open `[effectiveStart, effectiveEnd)`),
///     used by the settings screen and the five-minute eligibility flags.
///   - `placementChange` — the offline journal of "set current placement" declarations, replayed to
///     the server in recorded order so an offline change keeps its original effective time.
///
/// The table DDL is created idempotently on first use (`CREATE TABLE IF NOT EXISTS`, same shape as
/// the store's own v15 migration), because the WhoopStore migrator lives in the WhoopStore package
/// and this table is app-scoped. A change works fully offline: it is folded into the local intervals
/// and journaled immediately; sync is a separate best-effort pass.
public struct PlacementStore: Sendable {
    let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) throws {
        self.dbQueue = dbQueue
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS placementInterval (
                    id TEXT PRIMARY KEY NOT NULL,
                    deviceId TEXT,
                    placement TEXT NOT NULL,
                    effectiveStart INTEGER NOT NULL,
                    effectiveEnd INTEGER,
                    recordedAt INTEGER NOT NULL,
                    source TEXT NOT NULL,
                    revision INTEGER NOT NULL
                );
                CREATE TABLE IF NOT EXISTS placementChange (
                    id TEXT PRIMARY KEY NOT NULL,
                    deviceId TEXT,
                    placement TEXT NOT NULL,
                    effectiveStart INTEGER NOT NULL,
                    recordedAt INTEGER NOT NULL,
                    synced INTEGER NOT NULL DEFAULT 0
                );
                CREATE INDEX IF NOT EXISTS placementInterval_device_start
                    ON placementInterval (deviceId, effectiveStart);
                """)
        }
    }

    // MARK: Reads

    public func intervals(deviceId: String? = nil) throws -> [PlacementInterval] {
        try dbQueue.read { db in
            return try Row.fetchAll(db, sql: """
                SELECT id, deviceId, placement, effectiveStart, effectiveEnd, recordedAt, source, revision
                FROM placementInterval WHERE deviceId IS ? ORDER BY effectiveStart ASC, recordedAt ASC
                """, arguments: [deviceId])
                .map(Self.decode)
        }
    }

    /// The interval covering `at` (half-open), or nil when history is unannotated.
    public func activePlacement(at: Date, deviceId: String? = nil) throws -> PlacementInterval? {
        try intervals(deviceId: deviceId).first { $0.contains(at) }
    }

    public func allChanges() throws -> [PlacementChange] {
        try dbQueue.read { db in
            // Replay order is recorded order; equal recordedAt (same-microsecond offline burst) is
            // broken by effective time, then id, so the server replay is deterministic.
            try Row.fetchAll(db, sql: """
                SELECT id, deviceId, placement, effectiveStart, recordedAt, synced
                FROM placementChange ORDER BY recordedAt ASC, effectiveStart ASC, id ASC
                """).map(Self.decodeChange)
        }
    }

    public func pendingChanges() throws -> [PlacementChange] {
        try allChanges().filter { !$0.synced }
    }

    // MARK: Write

    /// Declare the current placement for `deviceId` (nil = user-level), effective at `at`
    /// (defaults to now — an offline change keeps its original effective time). Folds the
    /// declaration into the local interval model and journals a replay row in one transaction.
    /// Returns the journaled change (always) and the folded interval it produced.
    @discardableResult
    public func setCurrent(_ placement: StrapPlacement, deviceId: String?,
                           at: Date = Date(), recordedAt: Date = Date()) throws -> (PlacementChange, PlacementInterval?) {
        let change = PlacementChange(deviceId: deviceId, placement: placement,
                                     effectiveStart: at, recordedAt: recordedAt, synced: false)
        var folded: PlacementInterval?
        try dbQueue.write { db in
            let existing = try Self.readIntervals(db, scope: deviceId)
            let nextRev = PlacementIntervals.nextRevision(of: existing)
            let result = PlacementIntervals.applying(existing,
                                                     set: placement, at: at,
                                                     deviceId: deviceId,
                                                     recordedAt: recordedAt,
                                                     nextRevision: nextRev)
            // Persist the whole new set (delete + insert keeps the folded model exact and
            // deterministic; local history for one device is small).
            try db.execute(sql: "DELETE FROM placementInterval WHERE deviceId IS ?", arguments: [deviceId])
            for interval in result.intervals where (interval.deviceId ?? "") == (deviceId ?? "") {
                try db.execute(sql: """
                    INSERT INTO placementInterval (id, deviceId, placement, effectiveStart, effectiveEnd, recordedAt, source, revision)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [interval.id.uuidString, interval.deviceId, interval.placement.rawValue,
                                     Int(interval.effectiveStart.timeIntervalSince1970),
                                     interval.effectiveEnd.map { Int($0.timeIntervalSince1970) },
                                     Int(interval.recordedAt.timeIntervalSince1970),
                                     interval.source, interval.revision])
            }
            try db.execute(sql: """
                INSERT INTO placementChange (id, deviceId, placement, effectiveStart, recordedAt, synced)
                VALUES (?, ?, ?, ?, ?, 0)
                """, arguments: [change.id.uuidString, change.deviceId, change.placement.rawValue,
                                 Int(change.effectiveStart.timeIntervalSince1970),
                                 Int(change.recordedAt.timeIntervalSince1970)])
            folded = result.changed
        }
        return (change, folded)
    }

    /// Mark journal rows as synced after the server accepted them. Never retags another owner's
    /// rows — ids are locally minted UUIDs and the caller only passes ids it just uploaded.
    public func markSynced(ids: [UUID]) throws {
        guard !ids.isEmpty else { return }
        try dbQueue.write { db in
            for id in ids {
                try db.execute(sql: "UPDATE placementChange SET synced = 1 WHERE id = ?",
                               arguments: [id.uuidString])
            }
        }
    }

    /// Reconcile from a server pull: replace the local interval model for `deviceId` with the
    /// server's intervals. Only called when there are NO pending local changes (last-write-wins per
    /// owner, same posture as ProfileCloudSync), so a pending offline declaration is never lost.
    public func replaceIntervals(_ serverIntervals: [PlacementInterval], deviceId: String?) throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM placementInterval WHERE deviceId IS ?", arguments: [deviceId])
            for interval in serverIntervals {
                try db.execute(sql: """
                    INSERT INTO placementInterval (id, deviceId, placement, effectiveStart, effectiveEnd, recordedAt, source, revision)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                    """, arguments: [interval.id.uuidString, interval.deviceId, interval.placement.rawValue,
                                     Int(interval.effectiveStart.timeIntervalSince1970),
                                     interval.effectiveEnd.map { Int($0.timeIntervalSince1970) },
                                     Int(interval.recordedAt.timeIntervalSince1970),
                                     interval.source, interval.revision])
            }
        }
    }

    // MARK: Row decoding

    private static func decode(_ row: Row) -> PlacementInterval {
        PlacementInterval(
            id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
            deviceId: row["deviceId"] as String?,
            placement: StrapPlacement(rawValue: row["placement"] as String? ?? "unknown") ?? .unknown,
            effectiveStart: Date(timeIntervalSince1970: TimeInterval(row["effectiveStart"] as Int? ?? 0)),
            effectiveEnd: (row["effectiveEnd"] as Int?).map { Date(timeIntervalSince1970: TimeInterval($0)) },
            recordedAt: Date(timeIntervalSince1970: TimeInterval(row["recordedAt"] as Int? ?? 0)),
            source: row["source"] as String? ?? "user",
            revision: Int64(row["revision"] as Int? ?? 1))
    }

    private static func decodeChange(_ row: Row) -> PlacementChange {
        PlacementChange(
            id: UUID(uuidString: row["id"] as String? ?? "") ?? UUID(),
            deviceId: row["deviceId"] as String?,
            placement: StrapPlacement(rawValue: row["placement"] as String? ?? "unknown") ?? .unknown,
            effectiveStart: Date(timeIntervalSince1970: TimeInterval(row["effectiveStart"] as Int? ?? 0)),
            recordedAt: Date(timeIntervalSince1970: TimeInterval(row["recordedAt"] as Int? ?? 0)),
            synced: (row["synced"] as Int? ?? 0) != 0)
    }

    private static func readIntervals(_ db: Database, scope: String?) throws -> [PlacementInterval] {
        try Row.fetchAll(db, sql: """
            SELECT id, deviceId, placement, effectiveStart, effectiveEnd, recordedAt, source, revision
            FROM placementInterval WHERE deviceId IS ?
            """, arguments: [scope])
            .map(decode)
    }
}


// MARK: - PlacementCloudSync (G4 sync, same authenticated route pattern)

/// Uploads journaled placement declarations to the server and reconciles the interval model back,
/// using the SAME authenticated route pattern as the profile/scores routes: `Authorization: Bearer
/// <installation uploadToken>` plus `x-noop-fleet-token`, against the `scores` edge function host
/// derived from the push receiver URL (single source of truth, `ServerScoreRepository`/`CoachAPI`
/// trick).
///
/// Wire contract (the edge route is a parent integration point — see
/// docs/core-plumbing/findings/g34-wear-placement.md repair notes):
///   - `POST <host>/placement` body `{ placement, effective_start, device_id? }` → the edge function
///     resolves the installation identity and calls `set_placement_interval(p_owner, p_placement,
///     p_effective_start, p_device)`; 2xx = accepted.
///   - `GET  <host>/placement` → `{ intervals: [{ id?, device_id?, placement, effective_start,
///     effective_end?, source, revision }] }` for reconciliation.
/// Changes are replayed in recorded order so an offline declaration keeps its original effective
/// time. A failed upload leaves the rows unsynced (retried next time), never dropped.
public final class PlacementCloudSync: Sendable {
    private let session: URLSession
    private let endpoint: @Sendable () -> URL?
    private let fleetToken: @Sendable () -> String
    private let identity: @Sendable () -> CloudPushIdentity?
    private let store: @Sendable () -> PlacementStore?

    public init(session: URLSession = .shared,
                endpoint: @escaping @Sendable () -> URL? = { PlacementCloudSync.derivedEndpoint() },
                fleetToken: @escaping @Sendable () -> String = { CloudPushSettings.fleetToken },
                identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() },
                store: @escaping @Sendable () -> PlacementStore? = { nil }) {
        self.session = session
        self.endpoint = endpoint
        self.fleetToken = fleetToken
        self.identity = identity
        self.store = store
    }

    /// The `scores` edge host, derived from the configured push receiver by swapping the function
    /// name — the same single-source-of-truth trick `ServerScoreRepository.derivedEndpoint` uses.
    public static func derivedEndpoint() -> URL? {
        guard let push = CloudPushSettings.receiverURL,
              var components = URLComponents(url: push, resolvingAgainstBaseURL: false) else { return nil }
        var parts = components.path.split(separator: "/").map(String.init)
        guard parts.last == "push" else { return nil }
        parts[parts.count - 1] = "scores"
        components.path = "/" + parts.joined(separator: "/")
        return components.url
    }

    /// Push every unsynced declaration in recorded order; clear `synced` on each accepted change.
    /// Returns the number of rows uploaded. Best-effort: a failure leaves rows unsynced.
    public func pushPending() async throws -> Int {
        guard let store = store(), let id = identity() else { return 0 }
        let pending = try store.pendingChanges()
        guard !pending.isEmpty else { return 0 }
        let fleet = fleetToken()
        guard let base = endpoint(), !fleet.isEmpty else { return 0 }
        var uploaded = 0
        for change in pending {
            var body: [String: Any] = [
                "placement": change.placement.rawValue,
                "effective_start": Self.isoUTC(change.effectiveStart),
            ]
            if let device = change.deviceId { body["device_id"] = device }
            var req = URLRequest(url: base.appendingPathComponent("placement"),
                                 timeoutInterval: 30)
            req.httpMethod = "POST"
            req.setValue("Bearer \(id.uploadToken)", forHTTPHeaderField: "Authorization")
            req.setValue(fleet, forHTTPHeaderField: "x-noop-fleet-token")
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (_, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw PlacementSyncError.serverRejected
            }
            try store.markSynced(ids: [change.id])
            uploaded += 1
        }
        return uploaded
    }

    /// Pull the server's interval model and reconcile locally when there are NO pending local
    /// changes (so an offline declaration is never overwritten). Returns the reconciled interval
    /// count, or 0 when skipped.
    public func reconcile() async throws -> Int {
        guard let store = store(), let id = identity() else { return 0 }
        let fleet = fleetToken()
        guard let base = endpoint(), !fleet.isEmpty else { return 0 }
        guard try store.pendingChanges().isEmpty else { return 0 }
        var req = URLRequest(url: base.appendingPathComponent("placement"), timeoutInterval: 30)
        req.setValue("Bearer \(id.uploadToken)", forHTTPHeaderField: "Authorization")
        req.setValue(fleet, forHTTPHeaderField: "x-noop-fleet-token")
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw PlacementSyncError.serverRejected
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = obj["intervals"] as? [[String: Any]] else { return 0 }
        let parsed = raw.compactMap(Self.decodeServerInterval)
        // Replace per-device groups so a multi-device pull reconciles every device, and a
        // device absent from the server pull gets its local model left alone.
        let byDevice = Dictionary(grouping: parsed, by: { $0.deviceId ?? "" })
        for (device, intervals) in byDevice {
            try store.replaceIntervals(intervals, deviceId: device.isEmpty ? nil : device)
        }
        return parsed.count
    }

    private static func decodeServerInterval(_ row: [String: Any]) -> PlacementInterval? {
        guard let placementRaw = row["placement"] as? String,
              let placement = StrapPlacement(rawValue: placementRaw),
              let startRaw = row["effective_start"] as? String,
              let start = isoDate(startRaw) else { return nil }
        let end = (row["effective_end"] as? String).flatMap(isoDate)
        let device = row["device_id"] as? String
        let source = row["source"] as? String ?? "user"
        let revision = (row["revision"] as? NSNumber)?.int64Value ?? 1
        return PlacementInterval(deviceId: device, placement: placement,
                                 effectiveStart: start, effectiveEnd: end,
                                 recordedAt: start, source: source, revision: revision)
    }

    private static func isoDate(_ s: String) -> Date? {
        ISO8601DateFormatter().date(from: s) ?? ISO8601DateFormatter().date(from: s + "Z")
    }

    static func isoUTC(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

public enum PlacementSyncError: Error {
    case serverRejected
}

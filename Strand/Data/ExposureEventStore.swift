import Foundation
import CryptoKit
import GRDB
import StrandAnalytics
import WhoopStore

// MARK: - ExposureEventStore (physiology context System E, phone side)

/// On-device history of exposure events (medication, supplement, caffeine, alcohol, meal, heat, travel, symptom,
/// other) as IMMUTABLE revisions, in the same SQLite database as the app store (`store.registryWriter`), following
/// the `PlacementStore` house pattern: a synchronous, `Sendable` GRDB wrapper that creates its own table with
/// `CREATE TABLE IF NOT EXISTS`.
///
/// One row per `(owner, eventId, revision)`. An edit is a new revision of the same event and a delete is a
/// `retracted` revision; nothing is overwritten (an update trigger rejects content changes). Rows are scoped to the
/// account that recorded them; revisions recorded before any account claimed the phone are kept under
/// `unclaimedOwner`, are never uploaded, and are adopted by the local-data owner (`adoptUnclaimed`).
///
/// This table is the durable record for caffeine intakes too: `CaffeineLogStore` prunes intakes after 48 h, the
/// revisions recorded here are kept.
public struct ExposureEventStore: Sendable {
    public typealias Revision = PhysiologyContext.ExposureEventRevision

    let dbQueue: any DatabaseWriter

    /// Owner of revisions recorded while no account had claimed the on-device data.
    public static let unclaimedOwner = "unclaimed"
    /// Pull/upload status values written to `serverStatus`.
    public enum ServerStatus: String, Sendable { case saved, ignored, rejected }

    public struct Key: Hashable, Sendable {
        public let eventId: String
        public let revision: Int
        public init(eventId: String, revision: Int) { self.eventId = eventId; self.revision = revision }
    }

    /// A stored row with its local sync state (diagnostics and tests).
    public struct Stored: Equatable, Sendable {
        public var owner: String
        public var revision: Revision
        public var synced: Bool
        public var serverStatus: String?
        public var serverReason: String?
        /// Local provenance (e.g. `journal|<day>|<canonical question>`); never uploaded.
        public var sourceKey: String?
    }

    public enum StoreError: Error, Equatable {
        /// A different revision already holds this `(owner, eventId, revision)`.
        case revisionConflict(eventId: String, revision: Int)
        case invalidRevision(String)
    }

    public struct ReconcileOutcome: Equatable, Sendable {
        /// Server revisions inserted locally.
        public var inserted = 0
        /// Local revisions the server confirmed holding.
        public var confirmed = 0
        /// Local unsynced revisions renumbered after the server's history (they never left the phone).
        public var rebased = 0
        public init() {}
    }

    public init(dbQueue: any DatabaseWriter) throws {
        self.dbQueue = dbQueue
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS exposureEventRevision (
                    owner TEXT NOT NULL,
                    eventId TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    kind TEXT NOT NULL,
                    label TEXT NOT NULL,
                    occurredStart INTEGER NOT NULL,
                    occurredEnd INTEGER NOT NULL,
                    timePrecision TEXT NOT NULL,
                    recordedAt INTEGER NOT NULL,
                    receivedAt INTEGER,
                    source TEXT NOT NULL,
                    confirmation TEXT NOT NULL,
                    doseAmount REAL,
                    doseUnit TEXT,
                    doseProvenance TEXT,
                    sourceKey TEXT,
                    synced INTEGER NOT NULL DEFAULT 0,
                    serverStatus TEXT,
                    serverReason TEXT,
                    PRIMARY KEY (owner, eventId, revision)
                );
                CREATE INDEX IF NOT EXISTS exposureEventRevision_owner_time
                    ON exposureEventRevision (owner, occurredStart, occurredEnd);
                CREATE INDEX IF NOT EXISTS exposureEventRevision_owner_pending
                    ON exposureEventRevision (owner, synced, recordedAt);
                CREATE TRIGGER IF NOT EXISTS exposureEventRevision_immutable
                BEFORE UPDATE OF owner, eventId, revision, kind, label, occurredStart, occurredEnd, timePrecision,
                    recordedAt, source, confirmation, doseAmount, doseUnit, doseProvenance, sourceKey
                ON exposureEventRevision
                BEGIN SELECT RAISE(ABORT, 'exposure event revisions are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS exposureEventRevision_received_once
                BEFORE UPDATE OF receivedAt ON exposureEventRevision
                WHEN OLD.receivedAt IS NOT NULL AND NEW.receivedAt IS NOT OLD.receivedAt
                BEGIN SELECT RAISE(ABORT, 'receivedAt is set once'); END;
                """)
        }
    }

    // MARK: Write

    /// Store one revision for `owner`. Returns false when the identical revision is already stored (idempotent);
    /// throws `revisionConflict` when a different revision already holds the same number.
    @discardableResult
    public func record(_ revision: Revision, owner: String, sourceKey: String? = nil) throws -> Bool {
        try Self.validate(revision)
        let owner = Self.normalized(owner)
        return try dbQueue.write { db in
            if let existing = try Self.row(db, owner: owner, eventId: revision.eventId, revision: revision.revision) {
                guard Self.sameContent(existing.revision, revision) else {
                    throw StoreError.revisionConflict(eventId: revision.eventId, revision: revision.revision)
                }
                return false
            }
            try Self.insert(db, revision, owner: owner, sourceKey: sourceKey, synced: false, status: nil)
            return true
        }
    }

    /// Append a `retracted` revision for the event's latest revision. Returns the retraction, or nil when the
    /// event is unknown or already retracted.
    @discardableResult
    public func retract(owner: String, eventId: String, recordedAt: Int) throws -> Revision? {
        guard let latest = try latest(owner: owner, eventId: eventId), latest.confirmation != .retracted else {
            return nil
        }
        var r = latest
        r.revision = latest.revision + 1
        r.confirmation = .retracted
        r.recordedAt = recordedAt
        r.receivedAt = nil
        try record(r, owner: owner)
        return r
    }

    // MARK: Reads

    /// Every revision of one event, oldest first.
    public func revisions(owner: String, eventId: String) throws -> [Revision] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM exposureEventRevision WHERE owner = ? AND eventId = ? ORDER BY revision",
                             arguments: [Self.normalized(owner), eventId]).map { Self.decode($0).revision }
        }
    }

    public func latest(owner: String, eventId: String) throws -> Revision? {
        try revisions(owner: owner, eventId: eventId).last
    }

    /// Current events (latest revision, retracted ones left out) whose occurrence overlaps `[from, to)`. Uses the
    /// shared core rule (`PhysiologyContext.Exposures.current`, retrospective: every stored revision).
    public func current(owner: String, from: Int, to: Int) throws -> [PhysiologyContext.ExposureEvent] {
        let owner = Self.normalized(owner)
        let rows: [Revision] = try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM exposureEventRevision WHERE owner = ? AND eventId IN (
                    SELECT DISTINCT eventId FROM exposureEventRevision
                    WHERE owner = ? AND occurredEnd > ? AND occurredStart < ?)
                """, arguments: [owner, owner, from, to]).map { Self.decode($0).revision }
        }
        let window = PhysiologyContext.Interval(from, to)
        return PhysiologyContext.Exposures.current(rows, mode: .retrospective, cutoff: Int.max)
            .filter { $0.occurred.overlapSeconds(with: window) > 0 }
    }

    /// Revisions waiting for upload, in the order they must be sent (entry time, then event, then revision).
    /// Rejected revisions are not retried until a reconcile renumbers them.
    public func pending(owner: String, limit: Int = 25) throws -> [Revision] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: """
                SELECT * FROM exposureEventRevision
                WHERE owner = ? AND synced = 0 AND (serverStatus IS NULL OR serverStatus != 'rejected')
                ORDER BY recordedAt, eventId, revision LIMIT ?
                """, arguments: [Self.normalized(owner), max(0, limit)]).map { Self.decode($0).revision }
        }
    }

    public func pendingCount(owner: String) throws -> Int {
        try dbQueue.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM exposureEventRevision
                WHERE owner = ? AND synced = 0 AND (serverStatus IS NULL OR serverStatus != 'rejected')
                """, arguments: [Self.normalized(owner)]) ?? 0
        }
    }

    /// Every stored row of `owner` (diagnostics and tests), by event then revision.
    public func stored(owner: String) throws -> [Stored] {
        try dbQueue.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM exposureEventRevision WHERE owner = ? ORDER BY eventId, revision",
                             arguments: [Self.normalized(owner)]).map(Self.decode)
        }
    }

    // MARK: Sync bookkeeping

    /// Record the server's verdict on uploaded revisions. `saved` / `ignored` mean the server holds them;
    /// `rejected` keeps them unsynced with the reason and stops retrying them.
    public func markSynced(owner: String, keys: [Key], status: ServerStatus, reason: String? = nil) throws {
        guard !keys.isEmpty else { return }
        let owner = Self.normalized(owner)
        try dbQueue.write { db in
            for k in keys {
                try db.execute(sql: """
                    UPDATE exposureEventRevision SET synced = ?, serverStatus = ?, serverReason = ?
                    WHERE owner = ? AND eventId = ? AND revision = ?
                    """, arguments: [status == .rejected ? 0 : 1, status.rawValue, reason, owner, k.eventId,
                                     k.revision])
            }
        }
    }

    /// Reconcile with revisions read from the server for `owner`. Server revisions are inserted (as synced) or
    /// confirm the identical local row. A local unsynced revision whose number the server already used (another
    /// phone of the same account wrote it) is renumbered after the server's history, in its original order: it
    /// never left the phone, so its content is kept and it uploads on the next flush. Nothing local is deleted
    /// for being absent from the server (it may be pending or outside the pulled window).
    @discardableResult
    public func replaceFromServer(owner: String, revisions: [Revision]) throws -> ReconcileOutcome {
        let owner = Self.normalized(owner)
        guard owner != Self.unclaimedOwner else { return ReconcileOutcome() }
        let valid = revisions.filter { (try? Self.validate($0)) != nil }
        let byEvent = Dictionary(grouping: valid, by: \.eventId)
        var outcome = ReconcileOutcome()
        try dbQueue.write { db in
            for eventId in byEvent.keys.sorted() {
                let server = byEvent[eventId]!.sorted { $0.revision < $1.revision }
                let serverByRevision = Dictionary(server.map { ($0.revision, $0) }, uniquingKeysWith: { a, _ in a })
                let serverMax = server.last!.revision
                let local = try Self.rows(db, owner: owner, eventId: eventId)
                func matchesServer(_ row: Stored) -> Bool {
                    serverByRevision[row.revision.revision].map { Self.sameContent($0, row.revision) } ?? false
                }
                // Renumber only when a pending revision collides with the server's history; then every pending
                // revision of the event moves (in order), so the later ones stay after the renumbered ones.
                let unsynced = local.filter { !$0.synced && !matchesServer($0) }
                let collides = unsynced.contains { $0.revision.revision <= serverMax }
                let moving = collides ? unsynced : []
                for m in moving {
                    try Self.delete(db, owner: owner, eventId: eventId, revision: m.revision.revision)
                }
                let movingRevisions = Set(moving.map(\.revision.revision))
                for s in server {
                    let existing = local.first { $0.revision.revision == s.revision && !movingRevisions.contains(s.revision) }
                    if let existing {
                        if Self.sameContent(existing.revision, s) {
                            try db.execute(sql: """
                                UPDATE exposureEventRevision SET synced = 1, serverStatus = 'saved', serverReason = NULL
                                WHERE owner = ? AND eventId = ? AND revision = ?
                                """, arguments: [owner, eventId, s.revision])
                            if existing.revision.receivedAt == nil, let received = s.receivedAt {
                                try db.execute(sql: """
                                    UPDATE exposureEventRevision SET receivedAt = ?
                                    WHERE owner = ? AND eventId = ? AND revision = ?
                                    """, arguments: [received, owner, eventId, s.revision])
                            }
                            if !existing.synced { outcome.confirmed += 1 }
                        } else {
                            // A synced local copy that differs from the server: the server's history is authoritative.
                            try Self.delete(db, owner: owner, eventId: eventId, revision: s.revision)
                            try Self.insert(db, s, owner: owner, sourceKey: existing.sourceKey, synced: true,
                                            status: ServerStatus.saved.rawValue)
                            outcome.inserted += 1
                        }
                    } else {
                        try Self.insert(db, s, owner: owner, sourceKey: nil, synced: true,
                                        status: ServerStatus.saved.rawValue)
                        outcome.inserted += 1
                    }
                }
                if !moving.isEmpty {
                    let localMax = try Self.rows(db, owner: owner, eventId: eventId).map(\.revision.revision).max() ?? 0
                    var next = max(serverMax, localMax) + 1
                    for m in moving.sorted(by: Self.entryOrder) {
                        var r = m.revision
                        r.revision = next
                        r.receivedAt = nil
                        try Self.insert(db, r, owner: owner, sourceKey: m.sourceKey, synced: false, status: nil)
                        next += 1
                        outcome.rebased += 1
                    }
                }
            }
        }
        return outcome
    }

    /// Move every unclaimed revision to `owner` (the account that now owns the on-device data). Journal events are
    /// re-keyed to the owner's deterministic id; the adopted revisions and the owner's own unsynced revisions of
    /// the same event are renumbered together in entry order after the owner's synced history. Returns the
    /// number of revisions adopted. Unclaimed rows never left the phone, so renumbering them is safe.
    @discardableResult
    public func adoptUnclaimed(owner: String) throws -> Int {
        let owner = Self.normalized(owner)
        guard owner != Self.unclaimedOwner, !owner.isEmpty else { return 0 }
        return try dbQueue.write { db in
            let orphans = try Row.fetchAll(db, sql: "SELECT * FROM exposureEventRevision WHERE owner = ?",
                                           arguments: [Self.unclaimedOwner]).map(Self.decode)
            guard !orphans.isEmpty else { return 0 }
            try db.execute(sql: "DELETE FROM exposureEventRevision WHERE owner = ?", arguments: [Self.unclaimedOwner])
            var byTarget: [String: [Stored]] = [:]
            for o in orphans {
                byTarget[Self.adoptedEventId(o, owner: owner), default: []].append(o)
            }
            for eventId in byTarget.keys.sorted() {
                let own = try Self.rows(db, owner: owner, eventId: eventId)
                let syncedMax = own.filter(\.synced).map(\.revision.revision).max() ?? 0
                let unsynced = own.filter { !$0.synced }
                for u in unsynced { try Self.delete(db, owner: owner, eventId: eventId, revision: u.revision.revision) }
                var next = syncedMax + 1
                for m in (unsynced + byTarget[eventId]!).sorted(by: Self.entryOrder) {
                    var r = m.revision
                    r.eventId = eventId
                    r.revision = next
                    r.receivedAt = nil
                    try Self.insert(db, r, owner: owner, sourceKey: m.sourceKey, synced: false, status: nil)
                    next += 1
                }
            }
            return orphans.count
        }
    }

    #if DEBUG
    /// Raw SQL against this database (tests: proves the immutability triggers hold below the Swift API).
    func executeForTesting(_ sql: String) throws {
        try dbQueue.write { db in try db.execute(sql: sql) }
    }
    #endif

    // MARK: - Helpers

    static func normalized(_ owner: String) -> String {
        let t = owner.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return t.isEmpty ? unclaimedOwner : t
    }

    static func validate(_ r: Revision) throws {
        guard !r.eventId.isEmpty else { throw StoreError.invalidRevision("empty event id") }
        guard r.revision >= 1 else { throw StoreError.invalidRevision("revision below 1") }
        guard r.confirmation == .retracted || r.occurred.isValid else {
            throw StoreError.invalidRevision("empty occurrence range")
        }
        if let d = r.doseAmount, !d.isFinite { throw StoreError.invalidRevision("non-finite dose") }
    }

    /// Equal in everything the person or the importer stated; `receivedAt` is the server's and is not content.
    static func sameContent(_ a: Revision, _ b: Revision) -> Bool {
        var x = a, y = b
        x.receivedAt = nil; y.receivedAt = nil
        return x == y
    }

    static func entryOrder(_ a: Stored, _ b: Stored) -> Bool {
        (a.revision.recordedAt, a.revision.revision, a.revision.eventId)
            < (b.revision.recordedAt, b.revision.revision, b.revision.eventId)
    }

    static func adoptedEventId(_ row: Stored, owner: String) -> String {
        guard let key = row.sourceKey, key.hasPrefix("journal|") else { return row.revision.eventId }
        let parts = key.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3 else { return row.revision.eventId }
        return ExposureEventIds.journal(owner: owner, day: String(parts[1]), canonicalQuestion: String(parts[2]))
    }

    private static func row(_ db: Database, owner: String, eventId: String, revision: Int) throws -> Stored? {
        try Row.fetchOne(db, sql: "SELECT * FROM exposureEventRevision WHERE owner = ? AND eventId = ? AND revision = ?",
                         arguments: [owner, eventId, revision]).map(decode)
    }

    private static func rows(_ db: Database, owner: String, eventId: String) throws -> [Stored] {
        try Row.fetchAll(db, sql: "SELECT * FROM exposureEventRevision WHERE owner = ? AND eventId = ? ORDER BY revision",
                         arguments: [owner, eventId]).map(decode)
    }

    private static func delete(_ db: Database, owner: String, eventId: String, revision: Int) throws {
        try db.execute(sql: "DELETE FROM exposureEventRevision WHERE owner = ? AND eventId = ? AND revision = ?",
                       arguments: [owner, eventId, revision])
    }

    private static func insert(_ db: Database, _ r: Revision, owner: String, sourceKey: String?, synced: Bool,
                               status: String?) throws {
        try db.execute(sql: """
            INSERT INTO exposureEventRevision (owner, eventId, revision, kind, label, occurredStart, occurredEnd,
                timePrecision, recordedAt, receivedAt, source, confirmation, doseAmount, doseUnit, doseProvenance,
                sourceKey, synced, serverStatus)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """, arguments: [owner, r.eventId, r.revision, r.kind.rawValue, r.label, r.occurred.start, r.occurred.end,
                             r.timePrecision.rawValue, r.recordedAt, r.receivedAt, r.source.rawValue,
                             r.confirmation.rawValue, r.doseAmount, r.doseUnit, r.doseProvenance, sourceKey,
                             synced ? 1 : 0, status])
    }

    private static func decode(_ row: Row) -> Stored {
        let revision = Revision(
            eventId: row["eventId"] as String? ?? "",
            revision: row["revision"] as Int? ?? 0,
            kind: PhysiologyContext.ExposureKind(rawValue: row["kind"] as String? ?? "") ?? .other,
            label: row["label"] as String? ?? "",
            occurred: PhysiologyContext.Interval(row["occurredStart"] as Int? ?? 0, row["occurredEnd"] as Int? ?? 0),
            timePrecision: PhysiologyContext.TimePrecision(rawValue: row["timePrecision"] as String? ?? "") ?? .approximate,
            recordedAt: row["recordedAt"] as Int? ?? 0,
            receivedAt: row["receivedAt"] as Int?,
            source: PhysiologyContext.ExposureSource(rawValue: row["source"] as String? ?? "") ?? .userEntered,
            confirmation: PhysiologyContext.ExposureConfirmation(rawValue: row["confirmation"] as String? ?? "")
                ?? .confirmed,
            doseAmount: row["doseAmount"] as Double?,
            doseUnit: row["doseUnit"] as String?,
            doseProvenance: row["doseProvenance"] as String?)
        return Stored(owner: row["owner"] as String? ?? "", revision: revision,
                      synced: (row["synced"] as Int? ?? 0) != 0, serverStatus: row["serverStatus"] as String?,
                      serverReason: row["serverReason"] as String?, sourceKey: row["sourceKey"] as String?)
    }
}

// MARK: - Deterministic event ids

/// Event ids are UUID strings. Journal answers get a name-based id so the same (owner, day, question) is always the
/// same event across edits, reinstalls and phones: the first 16 bytes of SHA-256 over
/// `journal|<owner lowercased>|<yyyy-MM-dd>|<JournalCatalogStore.norm(question)>` (UTF-8), with the RFC 9562
/// version nibble set to 8 and the variant bits to `10`, formatted lowercase.
public enum ExposureEventIds {
    public static func journal(owner: String, day: String, canonicalQuestion: String) -> String {
        nameBased("journal|\(owner.lowercased())|\(day)|\(canonicalQuestion)")
    }

    public static func nameBased(_ name: String) -> String {
        var b = Array(SHA256.hash(data: Data(name.utf8)).prefix(16))
        b[6] = (b[6] & 0x0F) | 0x80
        b[8] = (b[8] & 0x3F) | 0x80
        let uuid = UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                               b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
        return uuid.uuidString.lowercased()
    }

    /// A fresh id for a timed event entered in the editor.
    public static func fresh() -> String { UUID().uuidString.lowercased() }
}

// MARK: - Locating the app's store

/// Finds the app's exposure store for code that has no store handle (the caffeine log, the sync, the event screens).
/// The journal hooks hand over the database they wrote to, so later callers find it without asking the repository
/// again. The store is opened off the main thread (opening runs `CREATE TABLE IF NOT EXISTS`). Tests set `override`.
@MainActor
public enum ExposureEventStoreLocator {
    public static var override: (() async -> ExposureEventStore?)?
    private static var writer: (any DatabaseWriter)?
    private static var cached: ExposureEventStore?

    /// Remember the app database (first one wins). No database work happens here.
    public static func remember(_ databaseWriter: any DatabaseWriter) {
        if writer == nil { writer = databaseWriter }
    }

    public static func resolve() async -> ExposureEventStore? {
        if let override { return await override() }
        if let cached { return cached }
        if writer == nil { writer = await AppModel.shared?.repo.storeHandle()?.registryWriter }
        guard let w = writer else { return nil }
        let store = await Task.detached(priority: .utility) { () -> ExposureEventStore? in
            do { return try ExposureEventStore(dbQueue: w) } catch {
                NSLog("ExposureEventStore: open failed: \(error)")
                return nil
            }
        }.value
        if cached == nil { cached = store }
        return cached
    }
}

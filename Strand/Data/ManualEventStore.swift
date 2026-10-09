import Foundation
import GRDB

/// A full snapshot. Labels in recorded events stay fixed when an event type is renamed.
struct ManualEventEntry: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case event, eventType = "event_type", preset }
    var id: UUID
    var kind: Kind
    var label: String
    var symbol: String = "tag.fill"
    var typeId: UUID?
    var favorite = false
    var durationMinutes: Int?
    var startUnixSeconds: Double?
    var endUnixSeconds: Double?
    var note: String?
    var deviceId: String?
    var timeZoneIdentifier = TimeZone.current.identifier
    var archived = false
    var archivedAt: Double?
    /// What the event was in the activity classifier's terms (`ActivityKind`). A type carries it; an event
    /// copies its type's kind when logged, like its label. The server maps it to the classifier's classes
    /// and projects definitive kinds into the activity ground-truth labels.
    var activityKind: String?

    var start: Date? { startUnixSeconds.map(Date.init(timeIntervalSince1970:)) }
    var end: Date? { endUnixSeconds.map(Date.init(timeIntervalSince1970:)) }
    var isRunning: Bool { kind == .event && !archived && endUnixSeconds == nil }
    /// The kind this entry counts as: its own, else the fixed default for a factory type (whose seed
    /// revisions predate the field and must stay byte-identical).
    var effectiveActivityKind: ActivityKind? {
        activityKind.flatMap(ActivityKind.init(rawValue:)) ?? ActivityKind.factoryDefault(for: kind == .eventType ? id : typeId)
    }

    /// The activity classifier's vocabulary for a logged event (MANUAL_EVENT_ACTIVITY_KINDS on the server).
    enum ActivityKind: String, CaseIterable, Identifiable, Sendable {
        case rest, walking, running, cycling, stairs, exercise, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .rest: "Rest"
            case .walking: "Walking"
            case .running: "Running"
            case .cycling: "Cycling"
            case .stairs: "Stairs"
            case .exercise: "Exercise"
            case .other: "Not an activity"
            }
        }
        /// Rest, Walking and Exercise are the factory types; their UUIDs are fixed across accounts.
        static func factoryDefault(for typeId: UUID?) -> Self? {
            switch typeId?.uuidString.lowercased() {
            case "00000000-0000-4000-8000-000000000001": .rest
            case "00000000-0000-4000-8000-000000000002": .walking
            case "00000000-0000-4000-8000-000000000011": .exercise
            default: nil
            }
        }
    }

    private static let originalDefaultTypes: [Self] = zip([
        "Rest", "Walking", "Wrist movement", "Sleeve warming", "Off wrist", "Posture change",
        "Mental arithmetic", "Medication", "Meal", "Caffeine", "Exercise", "Symptoms", "Shower",
    ], ["leaf.fill", "figure.walk", "hand.wave.fill", "thermometer.medium", "applewatch.slash",
        "figure.stand", "brain.head.profile", "pills.fill", "fork.knife", "cup.and.saucer.fill",
        "figure.run", "heart.text.clipboard.fill", "drop.fill"]).enumerated().map { index, value in
            Self(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", index + 1))!,
                 kind: .eventType, label: value.0, symbol: value.1, favorite: index < 2)
        }
    // Keep the original UUIDs so trimming the catalog cannot relabel existing data.
    static let defaultTypes = originalDefaultTypes.filter { ["Rest", "Walking", "Exercise"].contains($0.label) }
    static let retiredDefaultTypes = originalDefaultTypes.filter { !defaultTypes.map(\.id).contains($0.id) }
    static let defaultPresets: [Self] = [1, 5, 10, 15, 30, 60].map { minutes in
        Self(id: UUID(uuidString: String(format: "00000000-0000-4000-9000-%012d", minutes))!,
             kind: .preset, label: "\(minutes) min", symbol: "timer", durationMinutes: minutes)
    }

    /// The same rules as the server's `manualEventRevisionProblem`, so nothing the app saves is refused later.
    func validate() throws {
        guard !label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, label.unicodeScalars.count <= 100,
              !label.contains("\0"), !symbol.isEmpty, symbol.unicodeScalars.count <= 80, !symbol.contains("\0"),
              !timeZoneIdentifier.isEmpty, timeZoneIdentifier.unicodeScalars.count <= 100, !timeZoneIdentifier.contains("\0"),
              (note?.unicodeScalars.count ?? 0) <= 2000, !(note?.contains("\0") ?? false),
              (deviceId?.unicodeScalars.count ?? 0) <= 128, !(deviceId?.contains("\0") ?? false),
              archived == (archivedAt != nil),
              archivedAt.map({ $0.isFinite && $0 >= 0 && $0 <= 32_503_680_000 }) ?? true,
              durationMinutes.map({ (1...1440).contains($0) }) ?? true,
              activityKind.map({ ActivityKind(rawValue: $0) != nil }) ?? true else {
            throw ManualEventStore.Error.invalidEntry
        }
        switch kind {
        case .event:
            guard typeId != nil, let start = startUnixSeconds, start.isFinite, start >= 946_684_800,
                  start <= 32_503_680_000,
                  endUnixSeconds.map({ $0.isFinite && $0 >= start && $0 <= 32_503_680_000 }) ?? true else {
                throw ManualEventStore.Error.invalidEntry
            }
        case .preset:
            guard let minutes = durationMinutes, (1...1440).contains(minutes) else {
                throw ManualEventStore.Error.invalidEntry
            }
        case .eventType: break
        }
    }
}

/// A UUID makes concurrent edits from two devices distinct. Every revision is retained.
struct ManualEventRevision: Codable, Equatable, Sendable {
    let revisionId: UUID
    let updatedAtMs: Int64
    let entry: ManualEventEntry
    enum CodingKeys: String, CodingKey {
        case revisionId = "revision_id", updatedAtMs = "updated_at_ms", entry
    }
}

/// Separate account keys protect labels even when accounts share the same phone. No deletion API.
/// `synced` is 0 while a revision waits for the cloud, 1 once the server stored it and 2 when the server
/// refused it (`rejectReason`): a refused revision stays in the history but no longer blocks the queue.
final class ManualEventStore: @unchecked Sendable {
    enum Error: Swift.Error { case invalidEntry, revisionConflict }
    /// The server refuses a revision whose JSON exceeds 16 KiB.
    static let maxRevisionBytes = 16_384
    let db: DatabaseQueue

    init(path: String? = nil) throws {
        if let path { db = try DatabaseQueue(path: path) }
        else {
            let base = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
            let dir = base.appendingPathComponent("OpenWhoop/ManualEvents", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            #if os(iOS)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: dir.path)
            #endif
            db = try DatabaseQueue(path: dir.appendingPathComponent("events.sqlite").path)
        }
        try db.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS manualEventRevision (
                    owner TEXT NOT NULL, revisionId TEXT NOT NULL, entityId TEXT NOT NULL,
                    updatedAtMs INTEGER NOT NULL, body BLOB NOT NULL, synced INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY(owner, revisionId));
                CREATE INDEX IF NOT EXISTS manualEventRevision_owner_entity
                    ON manualEventRevision(owner, entityId, updatedAtMs);
                CREATE TABLE IF NOT EXISTS manualEventCursor(owner TEXT PRIMARY KEY, cursor TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS manualEventRetiredDefault (
                    owner TEXT NOT NULL, entityId TEXT NOT NULL, PRIMARY KEY(owner, entityId));
                CREATE TRIGGER IF NOT EXISTS manualEventRevision_no_update
                    BEFORE UPDATE OF owner, revisionId, entityId, updatedAtMs, body ON manualEventRevision
                    BEGIN SELECT RAISE(ABORT, 'event revisions are immutable'); END;
                CREATE TRIGGER IF NOT EXISTS manualEventRevision_no_delete BEFORE DELETE ON manualEventRevision
                    BEGIN SELECT RAISE(ABORT, 'archive events instead'); END;
                CREATE TABLE IF NOT EXISTS manualEventContext (
                    owner TEXT NOT NULL, entityId TEXT NOT NULL, revisionId TEXT NOT NULL,
                    body BLOB NOT NULL, fetchedAt REAL NOT NULL, PRIMARY KEY(owner, entityId));
                """)
            // Stores created before refusals were recorded: the column is additive and content stays immutable.
            if try !db.columns(in: "manualEventRevision").contains(where: { $0.name == "rejectReason" }) {
                try db.execute(sql: "ALTER TABLE manualEventRevision ADD COLUMN rejectReason TEXT")
            }
        }
    }

    func history(owner: String) throws -> [ManualEventRevision] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT body FROM manualEventRevision WHERE owner = ? ORDER BY updatedAtMs, revisionId",
                              arguments: [owner.lowercased()]).map { try JSONDecoder().decode(ManualEventRevision.self, from: $0) }
        }
    }

    func latest(owner: String) throws -> [ManualEventEntry] {
        // Both clients use (client timestamp, revision UUID) to resolve simultaneous edits.
        let entries = try db.read { db in
            try Data.fetchAll(db, sql: """
                SELECT body FROM (
                    SELECT body, ROW_NUMBER() OVER (PARTITION BY entityId ORDER BY updatedAtMs DESC, revisionId DESC) AS position
                    FROM manualEventRevision WHERE owner = ?
                ) WHERE position = 1
                """, arguments: [owner.lowercased()]).map { try JSONDecoder().decode(ManualEventRevision.self, from: $0).entry }
        }
        return entries.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }

    @discardableResult
    func save(_ entry: ManualEventEntry, owner: String, now: Date = Date()) throws -> ManualEventRevision {
        let last = try db.read { try Int64.fetchOne($0, sql: "SELECT MAX(updatedAtMs) FROM manualEventRevision WHERE owner = ?",
                                                  arguments: [owner.lowercased()]) ?? 0 }
        let revision = ManualEventRevision(revisionId: UUID(),
            updatedAtMs: max(Int64(now.timeIntervalSince1970 * 1000), last + 1), entry: entry)
        try insert(revision, owner: owner, synced: false)
        return revision
    }

    /// Trim the old factory catalog once per type and account. Earlier events and revisions stay intact.
    /// Renamed, favorited, or customized types stay available. A restored type stays restored.
    func retireLegacyDefaults(owner: String, now: Date = Date()) throws {
        let owner = owner.lowercased()
        try db.write { db in
            let migrated = Set(try String.fetchAll(db,
                sql: "SELECT entityId FROM manualEventRetiredDefault WHERE owner = ?", arguments: [owner]))
            let current = try Data.fetchAll(db, sql: """
                SELECT body FROM (
                    SELECT body, ROW_NUMBER() OVER (PARTITION BY entityId ORDER BY updatedAtMs DESC, revisionId DESC) AS position
                    FROM manualEventRevision WHERE owner = ?
                ) WHERE position = 1
                """, arguments: [owner]).map { try JSONDecoder().decode(ManualEventRevision.self, from: $0) }
            var timestamp = max(Int64(now.timeIntervalSince1970 * 1000),
                (try Int64.fetchOne(db, sql: "SELECT MAX(updatedAtMs) FROM manualEventRevision WHERE owner = ?",
                                   arguments: [owner]) ?? 0) + 1)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            for old in ManualEventEntry.retiredDefaultTypes {
                let key = old.id.uuidString.lowercased()
                guard !migrated.contains(key), let previous = current.first(where: { $0.entry.id == old.id }) else { continue }
                var entry = previous.entry
                if previous.revisionId == old.id && previous.updatedAtMs == 1
                    && !entry.archived && entry.kind == .eventType && entry.label == old.label
                    && entry.symbol == old.symbol && !entry.favorite {
                    entry.archived = true
                    entry.archivedAt = now.timeIntervalSince1970
                    let revision = ManualEventRevision(revisionId: UUID(), updatedAtMs: timestamp, entry: entry)
                    try db.execute(sql: "INSERT INTO manualEventRevision(owner, revisionId, entityId, updatedAtMs, body, synced) VALUES(?, ?, ?, ?, ?, 0)",
                        arguments: [owner, revision.revisionId.uuidString.lowercased(), key, timestamp, try encoder.encode(revision)])
                    timestamp += 1
                }
                try db.execute(sql: "INSERT INTO manualEventRetiredDefault(owner, entityId) VALUES(?, ?)", arguments: [owner, key])
            }
        }
    }

    func insert(_ revision: ManualEventRevision, owner: String, synced: Bool) throws {
        try revision.entry.validate()
        guard !owner.isEmpty, revision.updatedAtMs > 0 else { throw Error.invalidEntry }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(revision)
        guard body.count <= Self.maxRevisionBytes else { throw Error.invalidEntry }
        try db.write { db in
            if let old = try Data.fetchOne(db, sql: "SELECT body FROM manualEventRevision WHERE owner = ? AND revisionId = ?",
                                          arguments: [owner.lowercased(), revision.revisionId.uuidString.lowercased()]) {
                guard old == body else { throw Error.revisionConflict }
                if synced { try markSynced(db: db, owner: owner, ids: [revision.revisionId]) }
                return
            }
            try db.execute(sql: "INSERT INTO manualEventRevision(owner, revisionId, entityId, updatedAtMs, body, synced) VALUES(?, ?, ?, ?, ?, ?)",
                arguments: [owner.lowercased(), revision.revisionId.uuidString.lowercased(),
                            revision.entry.id.uuidString.lowercased(), revision.updatedAtMs, body, synced])
        }
    }

    func pending(owner: String, limit: Int = 25) throws -> [ManualEventRevision] {
        try db.read { db in
            try Data.fetchAll(db, sql: "SELECT body FROM manualEventRevision WHERE owner = ? AND synced = 0 ORDER BY updatedAtMs, revisionId LIMIT ?",
                              arguments: [owner.lowercased(), limit]).map { try JSONDecoder().decode(ManualEventRevision.self, from: $0) }
        }
    }

    func markSynced(owner: String, ids: [UUID]) throws {
        try db.write { try markSynced(db: $0, owner: owner, ids: ids) }
    }

    /// The server refused these revisions for good: keep them, stop sending them, remember why.
    func markRejected(owner: String, reasons: [UUID: String]) throws {
        try db.write { db in
            for (id, reason) in reasons {
                try db.execute(sql: "UPDATE manualEventRevision SET synced = 2, rejectReason = ? WHERE owner = ? AND revisionId = ? AND synced = 0",
                               arguments: [String(reason.prefix(64)), owner.lowercased(), id.uuidString.lowercased()])
            }
        }
    }

    /// Entities whose latest revision the server refused, with the reason.
    func rejected(owner: String) throws -> [UUID: String] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entityId, rejectReason FROM (
                    SELECT entityId, synced, rejectReason, ROW_NUMBER() OVER (
                        PARTITION BY entityId ORDER BY updatedAtMs DESC, revisionId DESC) AS position
                    FROM manualEventRevision WHERE owner = ?
                ) WHERE position = 1 AND synced = 2
                """, arguments: [owner.lowercased()])
            return Dictionary(rows.compactMap { row -> (UUID, String)? in
                guard let id = UUID(uuidString: row["entityId"]) else { return nil }
                return (id, row["rejectReason"] ?? "refused")
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// The current revision of every entity, by the same rule as `latest` (and the server).
    func latestRevisionIds(owner: String) throws -> [UUID: UUID] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT entityId, revisionId FROM (
                    SELECT entityId, revisionId, ROW_NUMBER() OVER (
                        PARTITION BY entityId ORDER BY updatedAtMs DESC, revisionId DESC) AS position
                    FROM manualEventRevision WHERE owner = ?
                ) WHERE position = 1
                """, arguments: [owner.lowercased()])
            return Dictionary(rows.compactMap { row -> (UUID, UUID)? in
                guard let entity = UUID(uuidString: row["entityId"]), let revision = UUID(uuidString: row["revisionId"]) else { return nil }
                return (entity, revision)
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// The latest context document the server built for each event, as received.
    func contexts(owner: String) throws -> [UUID: (revisionId: String, body: Data, fetchedAt: Date)] {
        try db.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT entityId, revisionId, body, fetchedAt FROM manualEventContext WHERE owner = ?",
                                        arguments: [owner.lowercased()])
            return Dictionary(rows.compactMap { row in
                UUID(uuidString: row["entityId"]).map { ($0, (revisionId: row["revisionId"] as String,
                    body: row["body"] as Data, fetchedAt: Date(timeIntervalSince1970: row["fetchedAt"]))) }
            }, uniquingKeysWith: { a, _ in a })
        }
    }

    /// A context is derived data, replaced whenever the server rebuilds it (unlike event revisions).
    func saveContext(owner: String, entityId: UUID, revisionId: UUID, body: Data, fetchedAt: Date = Date()) throws {
        try db.write { try $0.execute(sql: """
            INSERT INTO manualEventContext(owner, entityId, revisionId, body, fetchedAt) VALUES(?, ?, ?, ?, ?)
            ON CONFLICT(owner, entityId) DO UPDATE SET revisionId = excluded.revisionId, body = excluded.body,
                fetchedAt = excluded.fetchedAt
            """, arguments: [owner.lowercased(), entityId.uuidString.lowercased(), revisionId.uuidString.lowercased(),
                              body, fetchedAt.timeIntervalSince1970]) }
    }

    func cursor(owner: String) throws -> String {
        try db.read { try String.fetchOne($0, sql: "SELECT cursor FROM manualEventCursor WHERE owner = ?",
                                         arguments: [owner.lowercased()]) ?? "0" }
    }

    func setCursor(_ cursor: String, owner: String) throws {
        try db.write { try $0.execute(sql: "INSERT INTO manualEventCursor(owner, cursor) VALUES(?, ?) ON CONFLICT(owner) DO UPDATE SET cursor = excluded.cursor",
                                     arguments: [owner.lowercased(), cursor]) }
    }

    #if DEBUG
    func executeForTesting(_ sql: String) throws {
        try db.write { try $0.execute(sql: sql) }
    }
    #endif

    private func markSynced(db: Database, owner: String, ids: [UUID]) throws {
        for id in ids {
            try db.execute(sql: "UPDATE manualEventRevision SET synced = 1 WHERE owner = ? AND revisionId = ?",
                           arguments: [owner.lowercased(), id.uuidString.lowercased()])
        }
    }
}

/// The preset window moves as a unit. Endpoint edits can then change its duration independently.
struct ManualEventWindow: Equatable {
    var start: Date
    var end: Date
    init(anchor: Date, durationMinutes: Int, offsetMinutes: Double = 0) {
        start = anchor.addingTimeInterval(offsetMinutes * 60)
        end = start.addingTimeInterval(Double(durationMinutes) * 60)
    }
    /// A window that has just happened: it ends at `end` (usually now). Logging is mostly retrospective, and
    /// a window that ends in the future has no measurements behind it yet.
    init(endingAt end: Date, durationMinutes: Int) {
        self.end = end
        start = end.addingTimeInterval(-Double(durationMinutes) * 60)
    }
    var durationMinutes: Double { end.timeIntervalSince(start) / 60 }
    mutating func shift(minutes: Double) {
        start = start.addingTimeInterval(minutes * 60)
        end = end.addingTimeInterval(minutes * 60)
    }
}

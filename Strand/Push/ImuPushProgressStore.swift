import Foundation
import NoopPush
import SQLite3

/// Durable object-lane progress for the `rawImuSession` binary table (CONTRACTS C1, upload-verify
/// report §4 item 3): the binary cursor (advanced ONLY after a verified receipt) and the
/// in-flight object that lets a relaunch resume an interrupted upload onto the same objectKey.
///
/// A dedicated SQLite file (`object-lane.sqlite`) beside the NDJSON journal rather than new tables
/// inside `journal.sqlite`: the journal's schema and migration belong to the NDJSON sealer, and
/// the object lane is a separate state machine with its own durability rules. A dedicated file
/// keeps the two decoupled and never alters the existing journal schema.
///
/// Durability mirrors the journal store (CloudJournal.swift:397-403): WAL + `synchronous=FULL`,
/// so a committed cursor survives a process kill. Survives relaunch by construction — the file
/// lives in the cloud directory (`CloudJournalPaths.defaultDirectory()`).
public final class ImuPushProgressStore: PushProgressStore, @unchecked Sendable {
    private let lock = NSLock()
    private var db: OpaquePointer?
    let fileURL: URL

    public init(directory: URL) throws {
        self.fileURL = directory.appendingPathComponent("object-lane.sqlite")
        try open()
    }

    deinit {
        lock.lock(); let db = self.db; self.db = nil; lock.unlock()
        if let db { sqlite3_close_v2(db) }
    }

    private func open() throws {
        lock.lock()
        defer { lock.unlock() }
        if sqlite3_open_v2(fileURL.path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close_v2(db) }
            db = nil
            throw ImuPushProgressError.sqlite("open: \(message)")
        }
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=FULL;")
        try exec("PRAGMA busy_timeout=4000;")
        try exec("""
        CREATE TABLE IF NOT EXISTS imu_push_cursor (
            stream      TEXT    NOT NULL,
            device_id   TEXT    NOT NULL,
            row_id      INTEGER NOT NULL,
            fingerprint TEXT    NOT NULL,
            PRIMARY KEY (stream, device_id)
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS imu_push_inflight (
            stream          TEXT    NOT NULL,
            device_id       TEXT    NOT NULL,
            object_id       TEXT    NOT NULL,
            object_key      TEXT    NOT NULL,
            content_sha256  TEXT    NOT NULL,
            uploaded        INTEGER NOT NULL,
            PRIMARY KEY (stream, device_id)
        );
        """)
        try exec("""
        CREATE TABLE IF NOT EXISTS imu_push_device (
            device_id TEXT PRIMARY KEY
        );
        """)
    }

    // MARK: - PushProgressStore

    public func knownDeviceIds() async throws -> Set<String> {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw ImuPushProgressError.notOpen }
        var ids = Set<String>()
        if let stmt = try? prepare(db, "SELECT device_id FROM imu_push_device") {
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let value = text(stmt, 0) { ids.insert(value) }
            }
            sqlite3_finalize(stmt)
        }
        return ids
    }

    public func rememberDeviceId(_ deviceId: String) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw ImuPushProgressError.notOpen }
        let stmt = try prepare(db, "INSERT OR IGNORE INTO imu_push_device(device_id) VALUES(?)")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, deviceId, -1, imuSQLiteTransient)
        try step(stmt)
    }

    public func binaryCursor(table: PushBinaryTable, deviceId: String) async throws -> PushCursor? {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw ImuPushProgressError.notOpen }
        let stmt = try prepare(db, """
        SELECT row_id, fingerprint FROM imu_push_cursor
        WHERE stream = ? AND device_id = ?
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table.wireName, -1, imuSQLiteTransient)
        sqlite3_bind_text(stmt, 2, deviceId, -1, imuSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let fingerprint = text(stmt, 1) else { return nil }
        return PushCursor(rowId: sqlite3_column_int64(stmt, 0), naturalKeyFingerprint: fingerprint)
    }

    /// Advance the durable cursor after a verified receipt. The object for this (stream, device)
    /// is complete at that point, so its in-flight record is released in the same transaction.
    public func saveBinaryCursor(table: PushBinaryTable, deviceId: String, cursor: PushCursor) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw ImuPushProgressError.notOpen }
        try exec("BEGIN IMMEDIATE;")
        do {
            let upsert = try prepare(db, """
            INSERT INTO imu_push_cursor(stream, device_id, row_id, fingerprint) VALUES(?, ?, ?, ?)
            ON CONFLICT(stream, device_id) DO UPDATE SET row_id = excluded.row_id, fingerprint = excluded.fingerprint
            """)
            defer { sqlite3_finalize(upsert) }
            sqlite3_bind_text(upsert, 1, table.wireName, -1, imuSQLiteTransient)
            sqlite3_bind_text(upsert, 2, deviceId, -1, imuSQLiteTransient)
            sqlite3_bind_int64(upsert, 3, cursor.rowId)
            sqlite3_bind_text(upsert, 4, cursor.naturalKeyFingerprint, -1, imuSQLiteTransient)
            try step(upsert)

            let clear = try prepare(db, "DELETE FROM imu_push_inflight WHERE stream = ? AND device_id = ?")
            defer { sqlite3_finalize(clear) }
            sqlite3_bind_text(clear, 1, table.wireName, -1, imuSQLiteTransient)
            sqlite3_bind_text(clear, 2, deviceId, -1, imuSQLiteTransient)
            try step(clear)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    public func inFlightObject(table: PushBinaryTable, deviceId: String) async throws -> PushInFlightObject? {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw ImuPushProgressError.notOpen }
        let stmt = try prepare(db, """
        SELECT object_id, object_key, content_sha256, uploaded FROM imu_push_inflight
        WHERE stream = ? AND device_id = ?
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, table.wireName, -1, imuSQLiteTransient)
        sqlite3_bind_text(stmt, 2, deviceId, -1, imuSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              let objectId = text(stmt, 0), let objectKey = text(stmt, 1),
              let digest = text(stmt, 2) else { return nil }
        return PushInFlightObject(objectId: objectId, objectKey: objectKey,
                                  contentSha256: digest, uploaded: sqlite3_column_int64(stmt, 3) != 0)
    }

    public func saveInFlightObject(table: PushBinaryTable, deviceId: String, object: PushInFlightObject?) async throws {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw ImuPushProgressError.notOpen }
        if let object {
            let stmt = try prepare(db, """
            INSERT INTO imu_push_inflight(stream, device_id, object_id, object_key, content_sha256, uploaded)
            VALUES(?, ?, ?, ?, ?, ?)
            ON CONFLICT(stream, device_id) DO UPDATE SET object_id = excluded.object_id,
                object_key = excluded.object_key, content_sha256 = excluded.content_sha256,
                uploaded = excluded.uploaded
            """)
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, table.wireName, -1, imuSQLiteTransient)
            sqlite3_bind_text(stmt, 2, deviceId, -1, imuSQLiteTransient)
            sqlite3_bind_text(stmt, 3, object.objectId, -1, imuSQLiteTransient)
            sqlite3_bind_text(stmt, 4, object.objectKey, -1, imuSQLiteTransient)
            sqlite3_bind_text(stmt, 5, object.contentSha256, -1, imuSQLiteTransient)
            sqlite3_bind_int64(stmt, 6, object.uploaded ? 1 : 0)
            try step(stmt)
        } else {
            let stmt = try prepare(db, "DELETE FROM imu_push_inflight WHERE stream = ? AND device_id = ?")
            defer { sqlite3_finalize(stmt) }
            sqlite3_bind_text(stmt, 1, table.wireName, -1, imuSQLiteTransient)
            sqlite3_bind_text(stmt, 2, deviceId, -1, imuSQLiteTransient)
            try step(stmt)
        }
    }

    // Append-lane and mutable-window progress are owned by the NDJSON journal; the object lane
    // never touches them, so they stay inert here.

    public func cursor(table: PushAppendTable, deviceId: String) async throws -> PushCursor? { nil }
    public func saveCursor(table: PushAppendTable, deviceId: String, cursor: PushCursor) async throws {}
    public func window(table: PushMutableTable, deviceId: String) async throws -> PushWindowProgress? { nil }
    public func saveWindow(table: PushMutableTable, deviceId: String, progress: PushWindowProgress) async throws {}

    // MARK: - SQLite helpers

    private func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw ImuPushProgressError.sqlite(sql.prefix(40) + ": " + String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw ImuPushProgressError.sqlite("step: " + String(cString: sqlite3_errmsg(db)))
        }
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw ImuPushProgressError.notOpen }
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(error)
            throw ImuPushProgressError.sqlite("\(sql.prefix(40)): \(message)")
        }
    }

    private func text(_ stmt: OpaquePointer, _ index: Int32) -> String? {
        guard let raw = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: raw)
    }
}

public enum ImuPushProgressError: Error, CustomStringConvertible {
    case notOpen
    case sqlite(String)

    public var description: String {
        switch self {
        case .notOpen: return "imu object-lane progress store is not open"
        case .sqlite(let message): return "imu object-lane progress store: \(message)"
        }
    }
}

private let imuSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

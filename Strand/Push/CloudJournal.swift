import Foundation
import SQLite3

// MARK: - Typed stream registry
//
// The receiving registry is stream-typed (see the pinned `_shared/registry.ts` and the deployed
// `noop_apply_projection_rows` switch): each stream has its own SQL projection, its own natural
// identity and its own delivery mode. The journal therefore never carries a free-form "stream"
// string invented at the call site — it carries one of these cases, and the case name IS the wire
// name. Adding a stream here without adding it to the receiver's registry is a server-side 400, so
// the list is deliberately explicit.
public enum CloudStreamKind: String, CaseIterable, Sendable {
    // Scalar / provenance streams: append delivery, keyed by (deviceId, ts, …). The case names are
    // the RECEIVER'S wire names (`_shared/registry.ts`, `PushRegistryV1/V1_1`), not the local table
    // names — `event` is singular on the wire even though the app's table is `events`, and a
    // mismatch here is a server-side rejection, not a local error.
    case hrSample
    case rrInterval
    case event
    case battery
    case spo2Sample
    case skinTempSample
    case respSample
    case gravitySample
    case stepSample
    /// The standard 0x2A37 measurement, receipted separately from the proprietary realtime lane.
    case standardHRReceipt
    // Replace-window streams: the receiver assembles every part of a window before it supersedes
    // the previous rows, so a partial window can never delete rows it does not replace.
    case journal
    case sleepSession
    case workout
    case dailyMetric
    /// Immutable raw archive lane (protobuf/binary objects). Never feeds the scorer on its own.
    case rawBatch

    /// Streams whose delivery mode is replace-window rather than append. The sealer uses this to
    /// decide whether a batch must carry its full window identity.
    public var isReplaceWindow: Bool {
        switch self {
        case .journal, .sleepSession, .workout, .dailyMetric: return true
        default: return false
        }
    }

    /// The archive lane carries original bytes rather than a projected scalar row.
    public var isArchive: Bool { self == .rawBatch }
}

/// Where a record came from, which the receiver keeps as provenance evidence. Live notifications
/// and historical offload are distinct paths on the strap and must stay distinguishable server-side.
public enum CloudProvenance: String, Sendable {
    case live
    case history
}

/// How a journal record's payload is encoded.
public enum CloudPayloadEncoding: String, Sendable {
    /// A projected scalar row, already encoded as the registry's canonical JSON object.
    case jsonRow
    /// Original notification bytes, retained for the archive lane and for later reprojection.
    case rawBytes
}

// MARK: - Records

/// One durable capture, taken at the notification boundary.
///
/// Identity: `receivedAtMs` + `monotonicSeq` are assigned by the journal (not the caller) so that a
/// relaunch cannot restart the sequence, and so that two legitimate readings with identical bytes
/// and identical timestamps still get distinct identities. A payload hash is NOT used as identity.
public struct CloudJournalRecord: Sendable, Equatable {
    public var stream: CloudStreamKind
    public var encoding: CloudPayloadEncoding
    public var provenance: CloudProvenance
    /// BLE characteristic the bytes arrived on (or the synthetic source for a derived row).
    public var characteristic: String?
    /// Strap family / firmware, when known, for server-side decoder selection.
    public var family: String?
    public var firmware: String?
    /// Host receive time (unix seconds).
    public var receivedAtMs: Int
    /// Strap event time when the record carries one. Standard 0x2A37 usually does NOT: it carries
    /// phone receive time, which is why `receivedAtMs` is mandatory and this is optional.
    public var strapTs: Int?
    /// Clock correlation in force when the record was captured, when one existed.
    public var wallClockRef: Int?
    public var deviceClockRef: Int?
    public var payload: Data
    /// Replace-window identity for `.isReplaceWindow` streams (e.g. `day|question` for journal).
    public var windowIdentity: String?
    /// The strap this record came from, as the app's own device id (e.g. `my-whoop`). The receiver
    /// treats it as an EXTERNAL device id and resolves it to an owned device server-side, so it must
    /// be the same id the local store uses. nil falls back to the owner's active device, which is what
    /// a single-strap install wants; a WHOOP-to-WHOOP switch sets it per record so the two straps'
    /// rows are never merged under one device.
    public var deviceId: String?

    public init(stream: CloudStreamKind,
                encoding: CloudPayloadEncoding = .jsonRow,
                provenance: CloudProvenance,
                characteristic: String? = nil,
                family: String? = nil,
                firmware: String? = nil,
                receivedAtMs: Int,
                strapTs: Int? = nil,
                wallClockRef: Int? = nil,
                deviceClockRef: Int? = nil,
                windowIdentity: String? = nil,
                deviceId: String? = nil,
                payload: Data) {
        self.stream = stream
        self.encoding = encoding
        self.provenance = provenance
        self.characteristic = characteristic
        self.family = family
        self.firmware = firmware
        self.receivedAtMs = receivedAtMs
        self.strapTs = strapTs
        self.wallClockRef = wallClockRef
        self.deviceClockRef = deviceClockRef
        self.windowIdentity = windowIdentity
        self.deviceId = deviceId
        self.payload = payload
    }
}

/// A stored record with its durable identity attached.
public struct CloudJournalEntry: Sendable, Equatable {
    public let seq: Int64
    public let record: CloudJournalRecord
    public let ownerId: String
    public let deviceId: String
    public let sourceId: String
}

// MARK: - Sealing / receipts

/// A group of pending records that belong to one stream and one device and can be sealed into one
/// immutable payload file.
public struct CloudSealCandidate: Sendable, Equatable {
    public let ownerId: String
    public let sourceId: String
    public let deviceId: String
    public let stream: CloudStreamKind
    /// Inclusive durable identity range of the membership.
    public let firstSeq: Int64
    public let lastSeq: Int64
    public let recordCount: Int
    public let oldestReceivedAtMs: Int
    public let byteSize: Int
    public let windowIdentity: String?
}

/// An immutable payload file that has been committed to disk and registered as a durable job.
public struct CloudSealedBatch: Sendable, Equatable {
    public let batchId: String
    public let ownerId: String
    public let sourceId: String
    public let deviceId: String
    public let stream: CloudStreamKind
    public let firstSeq: Int64
    public let lastSeq: Int64
    public let recordCount: Int
    public let filePath: String
    public let contentSha256: String
    public let contentLength: Int
    public let createdAtMs: Int
    public let windowIdentity: String?
    /// Upload attempts so far, so backoff is bounded and observable rather than unbounded.
    public let attempts: Int
}

/// Durable job state of a sealed batch. `uploaded` is NOT deletion authority: only a checksum-
/// matching receipt from the receiver is (see `CloudJournal.applyReceipt`).
public enum CloudBatchState: String, Sendable {
    case sealed
    case reserved
    case uploaded
    case acked
    /// A retryable failure: the batch keeps its backoff time and is re-sent when it is due.
    case failed
    /// A terminal failure the receiver will not accept as-is (a malformed or rejected batch). The
    /// bytes and their records are KEPT — an unacknowledged input is never pruned — but the batch is
    /// not retried automatically, and the condition is surfaced instead of being retried forever.
    case blocked
}

/// What happened when a receipt was applied.
public enum CloudReceiptOutcome: Sendable, Equatable {
    /// The batch was still pending; its exact membership is now acknowledged and releasable.
    case acknowledged(records: Int)
    /// The receipt was for a batch already acknowledged (a duplicate / replayed ack). Harmless.
    case duplicate
    /// The receipt named a different content hash than the file we sealed. The file is KEPT.
    case checksumMismatch(expected: String, received: String)
    /// No such batch (already pruned, or never ours).
    case unknownBatch
    /// The receipt could not be parsed into the durability contract.
    case malformed
}

/// Journal health, surfaced to the UI so "pending uploads" is honest and disk pressure is visible.
public struct CloudJournalStats: Sendable, Equatable {
    public var pendingRecords: Int
    public var pendingBytes: Int
    public var sealedBatches: Int
    public var uploadedBatches: Int
    public var oldestPendingAgeSeconds: Int
    /// Records that were lost because the bounded startup buffer overflowed before the store was
    /// ready. Non-zero means a real capture gap: the history cursor is held, not advanced.
    public var overflowRecords: Int
    /// True while the history cursor must NOT advance (buffer overflow or a failed persistence).
    public var historyCursorHeld: Bool
    /// True when the pending footprint crossed the pressure threshold.
    public var diskPressure: Bool
    public var lastError: String?

    public static let empty = CloudJournalStats(pendingRecords: 0, pendingBytes: 0, sealedBatches: 0,
                                                uploadedBatches: 0, oldestPendingAgeSeconds: 0,
                                                overflowRecords: 0, historyCursorHeld: false,
                                                diskPressure: false, lastError: nil)
}

public enum CloudJournalError: Error, CustomStringConvertible {
    case notOpen(String)
    case sqlite(String)
    case protectedDataUnavailable(String)
    case stagingOverflow(Int)

    public var description: String {
        switch self {
        case .notOpen(let why): return "cloud journal not open: \(why)"
        case .sqlite(let msg): return "cloud journal sqlite error: \(msg)"
        case .protectedDataUnavailable(let why): return "cloud journal protected data unavailable: \(why)"
        case .stagingOverflow(let n): return "cloud journal staging overflow: \(n) record(s) lost"
        }
    }
}

// MARK: - Bounded ordered startup staging

/// The bounded ordered buffer that carries records from the notification boundary to the durable
/// store.
///
/// It exists for two real cases, not for tidiness:
///  1. iOS relaunches the app for a Bluetooth state-restoration event and the strap's earliest
///     notifications arrive BEFORE the store can be opened (and, on a locked phone before the first
///     unlock, before the protected file is readable at all).
///  2. The short write-coalescing window (≤ ~1 s) that keeps a per-notification SQLite commit off
///     the BLE path.
///
/// It is ordered (FIFO), lock-protected (so a `nonisolated` call from the BLE path preserves arrival
/// order), and BOUNDED. Overflow is never silent: the dropped count is recorded and the history
/// cursor is held, so the receiver sees a gap instead of a lie.
final class CloudJournalStaging: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CloudJournalRecord] = []
    private var overflow = 0
    private var lastError: String?
    private let maxRecords: Int
    private let maxBytes: Int
    private var bytes = 0

    init(maxRecords: Int = 8192, maxBytes: Int = 8 << 20) {
        self.maxRecords = maxRecords
        self.maxBytes = maxBytes
    }

    /// Append in arrival order. Returns true when the record was retained.
    ///
    /// On overflow the NEWEST record is dropped and counted, not the oldest: the oldest records are
    /// the ones that were hardest to obtain (they are the earliest restored notifications), and the
    /// gap is surfaced either way.
    @discardableResult
    func append(_ record: CloudJournalRecord) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard items.count < maxRecords, bytes + record.payload.count <= maxBytes else {
            overflow += 1
            lastError = "staging buffer full (records=\(items.count), bytes=\(bytes))"
            return false
        }
        items.append(record)
        bytes += record.payload.count
        return true
    }

    /// Take everything currently staged, preserving order. The writer owns them until it commits or
    /// puts them back.
    func takeAll() -> [CloudJournalRecord] {
        lock.lock(); defer { lock.unlock() }
        let out = items
        items.removeAll(keepingCapacity: true)
        bytes = 0
        return out
    }

    /// Put records back at the FRONT, preserving order, after a failed commit. Returns the number
    /// that did not fit (they are counted as overflow — the caller must hold the history cursor).
    @discardableResult
    func requeueFront(_ records: [CloudJournalRecord]) -> Int {
        guard !records.isEmpty else { return 0 }
        lock.lock(); defer { lock.unlock() }
        var kept: [CloudJournalRecord] = []
        var dropped = 0
        var keptBytes = 0
        for r in records {
            if kept.count + items.count < maxRecords, keptBytes + bytes + r.payload.count <= maxBytes {
                kept.append(r)
                keptBytes += r.payload.count
            } else {
                dropped += 1
            }
        }
        items.insert(contentsOf: kept, at: 0)
        bytes += keptBytes
        overflow += dropped
        return dropped
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return items.count }
    var pendingBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var overflowCount: Int { lock.lock(); defer { lock.unlock() }; return overflow }
    var error: String? { lock.lock(); defer { lock.unlock() }; return lastError }

    func clearError() { lock.lock(); defer { lock.unlock() }; lastError = nil }
    func resetOverflow() { lock.lock(); defer { lock.unlock() }; overflow = 0 }

    private var drainInFlight = false

    /// Claim the single coalescing-drain slot. False when a drain is already scheduled.
    func beginDrain() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if drainInFlight { return false }
        drainInFlight = true
        return true
    }

    func endDrain() { lock.lock(); defer { lock.unlock() }; drainInFlight = false }
}

// MARK: - Paths

public enum CloudJournalPaths {
    /// `<AppSupport>/OpenWhoop/cloud/journal.sqlite`, beside the main store and inside the same
    /// container, so a single directory policy covers both.
    public static func defaultDirectory() throws -> URL {
        let fm = FileManager.default
        let appSupport = try fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                    appropriateFor: nil, create: true)
        let base = appSupport.appendingPathComponent("OpenWhoop", isDirectory: true)
            .appendingPathComponent("cloud", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        #if os(iOS)
        // Same reasoning as StorePaths: iOS defaults new files to NSFileProtectionComplete, which
        // makes the journal unreadable while the phone is locked — exactly when a background BLE
        // relaunch must persist a notification. completeUntilFirstUserAuthentication is readable
        // after the first unlock since boot and still encrypted at rest. Set on the DIRECTORY so
        // SQLite's freshly created -wal/-shm sidecars inherit it, and on existing files so an
        // install created before this code converges.
        let protection: [FileAttributeKey: Any] =
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try? fm.setAttributes(protection, ofItemAtPath: base.path)
        let dbURL = base.appendingPathComponent("journal.sqlite")
        for suffix in ["", "-wal", "-shm"] {
            let p = dbURL.path + suffix
            if fm.fileExists(atPath: p) { try? fm.setAttributes(protection, ofItemAtPath: p) }
        }
        #endif
        return base
    }

    /// True when the journal's own files are currently readable. On a locked phone before the first
    /// unlock this is false, and persistence must be reported as deferred rather than successful.
    public static func isDataAvailable(at directory: URL) -> Bool {
        let path = directory.appendingPathComponent("journal.sqlite").path
        guard FileManager.default.fileExists(atPath: path) else { return true }
        return FileManager.default.isReadableFile(atPath: path)
    }
}

// MARK: - Durable store

private let cloudSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// The journal's SQLite file.
///
/// Why a dedicated file rather than the existing `WhoopStore` schema: the cloud journal has
/// different durability requirements from the decoded-stream store. A journal record must be
/// committed and become transport-eligible in the SAME transaction, must never be pruned while
/// unacknowledged, and must keep its own dense receive sequence across relaunch and pruning. Keeping
/// it in its own file means the cloud path can neither slow down nor be pruned by the existing
/// decoded-store retention policy, and the fork's offline behaviour is untouched.
///
/// Durability settings: WAL + `synchronous=FULL`. A committed record therefore survives a process
/// kill (the WAL is fsynced at commit). This is deliberate — an unacknowledged input that vanished
/// in a crash is exactly the loss the spec forbids — and it is affordable because records are
/// committed in ≤ ~1 s coalesced batches, not per notification.
/// Single-owner by construction: only `CloudJournal` (an actor) touches this type, so its methods
/// are deliberately not internally synchronized and are called synchronously from the actor's
/// executor. That keeps a commit atomic with respect to every other journal operation without a
/// second lock, and keeps the SQLite handle off any other thread.
final class CloudJournalStore: @unchecked Sendable {
    private var db: OpaquePointer?
    let directory: URL
    let fileURL: URL

    init(directory: URL) throws {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("journal.sqlite")
        try open()
    }

    deinit {
        if let db { sqlite3_close_v2(db) }
    }

    private func open() throws {
        if sqlite3_open_v2(fileURL.path, &db,
                           SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                           nil) != SQLITE_OK {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if let db { sqlite3_close_v2(db) }
            db = nil
            throw CloudJournalError.sqlite("open: \(msg)")
        }
        // A background BLE relaunch can reach here while the phone is locked but after the first
        // unlock; if the file protection still denies access, SQLite reports IOERR and we surface a
        // protected-data failure instead of pretending the write landed.
        try exec("PRAGMA journal_mode=WAL;")
        try exec("PRAGMA synchronous=FULL;")
        try exec("PRAGMA busy_timeout=4000;")
        try migrate()
    }

    private func exec(_ sql: String) throws {
        guard let db else { throw CloudJournalError.notOpen("exec") }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(err)
            if msg.lowercased().contains("i/o error") || msg.lowercased().contains("authorization denied") {
                throw CloudJournalError.protectedDataUnavailable(msg)
            }
            throw CloudJournalError.sqlite("\(sql.prefix(40)): \(msg)")
        }
    }

    private func migrate() throws {
        try exec("""
        CREATE TABLE IF NOT EXISTS journal_record (
            seq             INTEGER PRIMARY KEY AUTOINCREMENT,
            owner_id        TEXT    NOT NULL,
            source_id       TEXT    NOT NULL,
            device_id       TEXT    NOT NULL,
            stream          TEXT    NOT NULL,
            encoding        TEXT    NOT NULL,
            provenance      TEXT    NOT NULL,
            characteristic  TEXT,
            family          TEXT,
            firmware        TEXT,
            received_at_ms  INTEGER NOT NULL,
            monotonic_seq   INTEGER NOT NULL,
            strap_ts        INTEGER,
            wall_ref        INTEGER,
            device_ref      INTEGER,
            window_identity TEXT,
            payload         BLOB    NOT NULL,
            batch_id        TEXT,
            state           INTEGER NOT NULL DEFAULT 0,
            created_at_ms   INTEGER NOT NULL
        );
        """)
        // The transport-eligibility index: `state = 0` IS eligibility, so a record becomes
        // transport-eligible in the same transaction that makes it durable.
        try exec("CREATE INDEX IF NOT EXISTS journal_pending ON journal_record(state, device_id, stream, seq);")
        try exec("CREATE INDEX IF NOT EXISTS journal_batch ON journal_record(batch_id, seq);")
        try exec("""
        CREATE TABLE IF NOT EXISTS sealed_batch (
            batch_id           TEXT PRIMARY KEY,
            owner_id           TEXT    NOT NULL,
            source_id          TEXT    NOT NULL,
            device_id          TEXT    NOT NULL,
            stream             TEXT    NOT NULL,
            first_seq          INTEGER NOT NULL,
            last_seq           INTEGER NOT NULL,
            record_count       INTEGER NOT NULL,
            window_identity    TEXT,
            file_path          TEXT    NOT NULL,
            content_sha256     TEXT    NOT NULL,
            content_length     INTEGER NOT NULL,
            created_at_ms      INTEGER NOT NULL,
            state              TEXT    NOT NULL,
            reservation_id     TEXT,
            task_id            TEXT,
            task_kind          TEXT,
            auth_expires_at_ms INTEGER,
            attempts           INTEGER NOT NULL DEFAULT 0,
            next_attempt_at_ms INTEGER,
            last_error         TEXT,
            receipt_json       TEXT,
            protocol_version   TEXT,
            end_cursor_json    TEXT
        );
        """)
        try exec("CREATE INDEX IF NOT EXISTS sealed_eligible ON sealed_batch(state, next_attempt_at_ms, created_at_ms);")
        try exec("""
        CREATE TABLE IF NOT EXISTS journal_meta (
            key   TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """)
    }

    // MARK: low-level helpers

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw CloudJournalError.notOpen("prepare") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw CloudJournalError.sqlite("prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        return stmt
    }

    private func step(_ stmt: OpaquePointer) throws {
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            if msg.lowercased().contains("i/o error") { throw CloudJournalError.protectedDataUnavailable(msg) }
            throw CloudJournalError.sqlite("step(\(rc)): \(msg)")
        }
    }

    private func text(_ stmt: OpaquePointer, _ idx: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, idx) else { return nil }
        return String(cString: c)
    }

    private func metaInt(_ key: String) throws -> Int {
        let stmt = try prepare("SELECT value FROM journal_meta WHERE key = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, cloudSQLiteTransient)
        if sqlite3_step(stmt) == SQLITE_ROW, let t = text(stmt, 0) { return Int(t) ?? 0 }
        return 0
    }

    func setMeta(_ key: String, _ value: String) throws {
        let stmt = try prepare("INSERT INTO journal_meta(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, cloudSQLiteTransient)
        sqlite3_bind_text(stmt, 2, value, -1, cloudSQLiteTransient)
        try step(stmt)
    }

    func metaValue(_ key: String) throws -> String? {
        let stmt = try prepare("SELECT value FROM journal_meta WHERE key = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, cloudSQLiteTransient)
        if sqlite3_step(stmt) == SQLITE_ROW { return text(stmt, 0) }
        return nil
    }

    // MARK: append (durable + eligible, one transaction)

    /// Commit records in arrival order. The dense `monotonic_seq` continues across relaunch, so a
    /// receiver can see a gap even after pruning removed the rows around it.
    @discardableResult
    func append(_ records: [CloudJournalRecord], ownerId: String, sourceId: String, deviceId: String,
                nowMs: Int) throws -> Int {
        guard !records.isEmpty else { return 0 }
        var nextSeq = try metaInt("records_received")
        try exec("BEGIN IMMEDIATE;")
        do {
            let stmt = try prepare("""
            INSERT INTO journal_record(owner_id, source_id, device_id, stream, encoding, provenance,
                                       characteristic, family, firmware, received_at_ms, monotonic_seq,
                                       strap_ts, wall_ref, device_ref, window_identity, payload,
                                       batch_id, state, created_at_ms)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,NULL,0,?)
            """)
            defer { sqlite3_finalize(stmt) }
            for r in records {
                nextSeq += 1
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                sqlite3_bind_text(stmt, 1, ownerId, -1, cloudSQLiteTransient)
                sqlite3_bind_text(stmt, 2, sourceId, -1, cloudSQLiteTransient)
                sqlite3_bind_text(stmt, 3, r.deviceId ?? deviceId, -1, cloudSQLiteTransient)
                sqlite3_bind_text(stmt, 4, r.stream.rawValue, -1, cloudSQLiteTransient)
                sqlite3_bind_text(stmt, 5, r.encoding.rawValue, -1, cloudSQLiteTransient)
                sqlite3_bind_text(stmt, 6, r.provenance.rawValue, -1, cloudSQLiteTransient)
                if let v = r.characteristic { sqlite3_bind_text(stmt, 7, v, -1, cloudSQLiteTransient) } else { sqlite3_bind_null(stmt, 7) }
                if let v = r.family { sqlite3_bind_text(stmt, 8, v, -1, cloudSQLiteTransient) } else { sqlite3_bind_null(stmt, 8) }
                if let v = r.firmware { sqlite3_bind_text(stmt, 9, v, -1, cloudSQLiteTransient) } else { sqlite3_bind_null(stmt, 9) }
                sqlite3_bind_int64(stmt, 10, Int64(r.receivedAtMs))
                sqlite3_bind_int64(stmt, 11, Int64(nextSeq))
                if let v = r.strapTs { sqlite3_bind_int64(stmt, 12, Int64(v)) } else { sqlite3_bind_null(stmt, 12) }
                if let v = r.wallClockRef { sqlite3_bind_int64(stmt, 13, Int64(v)) } else { sqlite3_bind_null(stmt, 13) }
                if let v = r.deviceClockRef { sqlite3_bind_int64(stmt, 14, Int64(v)) } else { sqlite3_bind_null(stmt, 14) }
                if let v = r.windowIdentity { sqlite3_bind_text(stmt, 15, v, -1, cloudSQLiteTransient) } else { sqlite3_bind_null(stmt, 15) }
                _ = r.payload.withUnsafeBytes { buf in
                    sqlite3_bind_blob(stmt, 16, buf.baseAddress, Int32(buf.count), cloudSQLiteTransient)
                }
                sqlite3_bind_int64(stmt, 17, Int64(nowMs))
                try step(stmt)
            }
            try setMeta("records_received", String(nextSeq))
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        return records.count
    }

    // MARK: sealing

    /// Pending groups eligible to be sealed, oldest first, one per (device, stream).
    func pendingGroups(maxRecords: Int, maxBytes: Int, minAgeSeconds: Double, nowMs: Int,
                       limit: Int) throws -> [CloudSealCandidate] {
        let stmt = try prepare("""
        SELECT device_id, stream, MIN(seq), MAX(seq), COUNT(*), MIN(received_at_ms), SUM(LENGTH(payload)),
               MIN(created_at_ms), MIN(window_identity)
        FROM journal_record
        WHERE state = 0 AND stream != ?
        GROUP BY device_id, stream
        ORDER BY MIN(seq) ASC
        LIMIT ?
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, CloudStreamKind.rawBatch.rawValue, -1, cloudSQLiteTransient)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        var out: [CloudSealCandidate] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let deviceId = text(stmt, 0) ?? ""
            let streamRaw = text(stmt, 1) ?? ""
            guard let stream = CloudStreamKind(rawValue: streamRaw) else { continue }
            let count = Int(sqlite3_column_int64(stmt, 4))
            let bytes = Int(sqlite3_column_int64(stmt, 6))
            let oldestCreated = Int(sqlite3_column_int64(stmt, 7))
            let ageSeconds = Double(nowMs - oldestCreated) / 1000.0
            // Seal when the group is big enough, OR old enough. Both bounds are inputs: the active-use
            // target is ~2 s, the record/byte caps keep one file bounded.
            let bigEnough = count >= maxRecords || bytes >= maxBytes
            let oldEnough = ageSeconds >= minAgeSeconds
            guard bigEnough || oldEnough else { continue }
            out.append(CloudSealCandidate(ownerId: "", sourceId: "", deviceId: deviceId, stream: stream,
                                          firstSeq: sqlite3_column_int64(stmt, 2),
                                          lastSeq: sqlite3_column_int64(stmt, 3),
                                          recordCount: count,
                                          oldestReceivedAtMs: Int(sqlite3_column_int64(stmt, 5)),
                                          byteSize: bytes,
                                          windowIdentity: text(stmt, 8)))
        }
        return out
    }

    /// Every pending record of one (device, stream) up to the group's last committed sequence.
    func pendingEntries(deviceId: String, stream: CloudStreamKind, upTo lastSeq: Int64) throws -> [CloudJournalEntry] {
        let stmt = try prepare("""
        SELECT seq, owner_id, source_id, device_id, stream, encoding, provenance, characteristic,
               family, firmware, received_at_ms, strap_ts, wall_ref, device_ref, window_identity, payload
        FROM journal_record
        WHERE state = 0 AND device_id = ? AND stream = ? AND seq <= ?
        ORDER BY seq ASC
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, deviceId, -1, cloudSQLiteTransient)
        sqlite3_bind_text(stmt, 2, stream.rawValue, -1, cloudSQLiteTransient)
        sqlite3_bind_int64(stmt, 3, lastSeq)
        var out: [CloudJournalEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let streamRaw = text(stmt, 4), let kind = CloudStreamKind(rawValue: streamRaw),
                  let encodingRaw = text(stmt, 5), let encoding = CloudPayloadEncoding(rawValue: encodingRaw),
                  let provRaw = text(stmt, 6), let provenance = CloudProvenance(rawValue: provRaw) else { continue }
            let payloadLen = Int(sqlite3_column_bytes(stmt, 15))
            var payload = Data()
            if let blob = sqlite3_column_blob(stmt, 15), payloadLen > 0 {
                payload = Data(bytes: blob, count: payloadLen)
            }
            let record = CloudJournalRecord(
                stream: kind, encoding: encoding, provenance: provenance,
                characteristic: text(stmt, 7), family: text(stmt, 8), firmware: text(stmt, 9),
                receivedAtMs: Int(sqlite3_column_int64(stmt, 10)),
                strapTs: sqlite3_column_type(stmt, 11) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 11)),
                wallClockRef: sqlite3_column_type(stmt, 12) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 12)),
                deviceClockRef: sqlite3_column_type(stmt, 13) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(stmt, 13)),
                windowIdentity: text(stmt, 14), payload: payload)
            out.append(CloudJournalEntry(seq: sqlite3_column_int64(stmt, 0), record: record,
                                         ownerId: text(stmt, 1) ?? "", deviceId: text(stmt, 3) ?? "",
                                         sourceId: text(stmt, 2) ?? ""))
        }
        return out
    }

    /// Register an immutable, already-written payload file as a durable job, and mark EXACTLY its
    /// membership sealed in the same transaction.
    func registerSeal(_ candidate: CloudSealCandidate, batchId: String, filePath: String,
                      contentSha256: String, contentLength: Int, ownerId: String, sourceId: String,
                      protocolVersion: String?, endCursorJSON: String?, nowMs: Int) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            let insert = try prepare("""
            INSERT INTO sealed_batch(batch_id, owner_id, source_id, device_id, stream, first_seq, last_seq,
                                     record_count, window_identity, file_path, content_sha256, content_length,
                                     created_at_ms, state, attempts, protocol_version, end_cursor_json)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,'sealed',0,?,?)
            """)
            defer { sqlite3_finalize(insert) }
            sqlite3_bind_text(insert, 1, batchId, -1, cloudSQLiteTransient)
            sqlite3_bind_text(insert, 2, ownerId, -1, cloudSQLiteTransient)
            sqlite3_bind_text(insert, 3, sourceId, -1, cloudSQLiteTransient)
            sqlite3_bind_text(insert, 4, candidate.deviceId, -1, cloudSQLiteTransient)
            sqlite3_bind_text(insert, 5, candidate.stream.rawValue, -1, cloudSQLiteTransient)
            sqlite3_bind_int64(insert, 6, candidate.firstSeq)
            sqlite3_bind_int64(insert, 7, candidate.lastSeq)
            sqlite3_bind_int(insert, 8, Int32(candidate.recordCount))
            if let w = candidate.windowIdentity { sqlite3_bind_text(insert, 9, w, -1, cloudSQLiteTransient) } else { sqlite3_bind_null(insert, 9) }
            sqlite3_bind_text(insert, 10, filePath, -1, cloudSQLiteTransient)
            sqlite3_bind_text(insert, 11, contentSha256, -1, cloudSQLiteTransient)
            sqlite3_bind_int(insert, 12, Int32(contentLength))
            sqlite3_bind_int64(insert, 13, Int64(nowMs))
            if let pv = protocolVersion { sqlite3_bind_text(insert, 14, pv, -1, cloudSQLiteTransient) } else { sqlite3_bind_null(insert, 14) }
            if let ec = endCursorJSON { sqlite3_bind_text(insert, 15, ec, -1, cloudSQLiteTransient) } else { sqlite3_bind_null(insert, 15) }
            try step(insert)

            // Membership + eligibility in the SAME transaction as the job row: there is no window in
            // which a file exists that no record points at, or records point at a file that is not
            // registered yet.
            let mark = try prepare("""
            UPDATE journal_record SET batch_id = ?, state = 1
            WHERE state = 0 AND device_id = ? AND stream = ? AND seq BETWEEN ? AND ?
            """)
            defer { sqlite3_finalize(mark) }
            sqlite3_bind_text(mark, 1, batchId, -1, cloudSQLiteTransient)
            sqlite3_bind_text(mark, 2, candidate.deviceId, -1, cloudSQLiteTransient)
            sqlite3_bind_text(mark, 3, candidate.stream.rawValue, -1, cloudSQLiteTransient)
            sqlite3_bind_int64(mark, 4, candidate.firstSeq)
            sqlite3_bind_int64(mark, 5, candidate.lastSeq)
            try step(mark)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    /// A seal whose file write failed after the records were read: release them so the next pass
    /// re-seals. Nothing was registered, so nothing is lost.
    func releaseSeal(_ candidate: CloudSealCandidate) throws {
        // No state change is needed (records were never marked), but the call keeps the intent
        // explicit at the call site and gives the retry path one place to count attempts later.
    }

    // MARK: job state

    func markReserved(batchId: String, taskId: String, taskKind: String, authExpiresAtMs: Int?) throws {
        let stmt = try prepare("""
        UPDATE sealed_batch SET state = 'reserved', task_id = ?, task_kind = ?, auth_expires_at_ms = ?,
                                attempts = attempts + 1
        WHERE batch_id = ? AND state IN ('sealed','failed','uploaded')
        """)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, taskId, -1, cloudSQLiteTransient)
        sqlite3_bind_text(stmt, 2, taskKind, -1, cloudSQLiteTransient)
        if let e = authExpiresAtMs { sqlite3_bind_int64(stmt, 3, Int64(e)) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_text(stmt, 4, batchId, -1, cloudSQLiteTransient)
        try step(stmt)
    }

    func markUploaded(batchId: String) throws {
        let stmt = try prepare("UPDATE sealed_batch SET state = 'uploaded', task_id = NULL WHERE batch_id = ? AND state != 'acked'")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, batchId, -1, cloudSQLiteTransient)
        try step(stmt)
    }

    func markFailed(batchId: String, error: String, nextAttemptAtMs: Int?, blocked: Bool = false) throws {
        let stmt = try prepare("""
        UPDATE sealed_batch SET state = ?, task_id = NULL, last_error = ?, next_attempt_at_ms = ?,
                                attempts = attempts + 1
        WHERE batch_id = ? AND state != 'acked'
        """)
        sqlite3_bind_text(stmt, 1, (blocked ? CloudBatchState.blocked : CloudBatchState.failed).rawValue, -1, cloudSQLiteTransient)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 2, error, -1, cloudSQLiteTransient)
        if let n = nextAttemptAtMs { sqlite3_bind_int64(stmt, 3, Int64(n)) } else { sqlite3_bind_null(stmt, 3) }
        sqlite3_bind_text(stmt, 4, batchId, -1, cloudSQLiteTransient)
        try step(stmt)
    }

    /// Return a blocked batch's records to the pending pool so the builder can
    /// re-seal them. Used when a previously non-retryable rejection was fixed
    /// builder-side (e.g. duplicate conflict keys inside one batch): the
    /// records were never acknowledged, so they must not be lost — they go
    /// back to `state = 0`, the sealed job row is removed, and the next seal
    /// pass rebuilds the batch with the corrected rules. The payload file is
    /// not referenced by any live job after this and will be pruned with the
    /// other unreferenced files.
    func resealBlocked(batchId: String) throws {
        try exec("BEGIN IMMEDIATE;")
        do {
            let free = try prepare("""
            UPDATE journal_record SET batch_id = NULL, state = 0
            WHERE batch_id = ? AND state = 1
            """)
            defer { sqlite3_finalize(free) }
            sqlite3_bind_text(free, 1, batchId, -1, cloudSQLiteTransient)
            try step(free)
            let drop = try prepare("DELETE FROM sealed_batch WHERE batch_id = ? AND state = 'blocked'")
            defer { sqlite3_finalize(drop) }
            sqlite3_bind_text(drop, 1, batchId, -1, cloudSQLiteTransient)
            try step(drop)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func sealedBatches(states: [CloudBatchState], dueBeforeMs: Int?, limit: Int) throws -> [CloudSealedBatch] {
        let placeholders = states.map { _ in "?" }.joined(separator: ",")
        var sql = """
        SELECT batch_id, owner_id, source_id, device_id, stream, first_seq, last_seq, record_count,
               file_path, content_sha256, content_length, created_at_ms, window_identity, attempts
        FROM sealed_batch WHERE state IN (\(placeholders))
        """
        if dueBeforeMs != nil { sql += " AND (next_attempt_at_ms IS NULL OR next_attempt_at_ms <= ?)" }
        sql += " ORDER BY created_at_ms ASC, batch_id ASC LIMIT ?"
        let stmt = try prepare(sql)
        defer { sqlite3_finalize(stmt) }
        var idx: Int32 = 1
        for s in states { sqlite3_bind_text(stmt, idx, s.rawValue, -1, cloudSQLiteTransient); idx += 1 }
        if let due = dueBeforeMs { sqlite3_bind_int64(stmt, idx, Int64(due)); idx += 1 }
        sqlite3_bind_int(stmt, idx, Int32(limit))
        var out: [CloudSealedBatch] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let streamRaw = text(stmt, 4), let stream = CloudStreamKind(rawValue: streamRaw) else { continue }
            out.append(CloudSealedBatch(batchId: text(stmt, 0) ?? "",
                                        ownerId: text(stmt, 1) ?? "", sourceId: text(stmt, 2) ?? "",
                                        deviceId: text(stmt, 3) ?? "", stream: stream,
                                        firstSeq: sqlite3_column_int64(stmt, 5),
                                        lastSeq: sqlite3_column_int64(stmt, 6),
                                        recordCount: Int(sqlite3_column_int64(stmt, 7)),
                                        filePath: text(stmt, 8) ?? "", contentSha256: text(stmt, 9) ?? "",
                                        contentLength: Int(sqlite3_column_int64(stmt, 10)),
                                        createdAtMs: Int(sqlite3_column_int64(stmt, 11)),
                                        windowIdentity: text(stmt, 12),
                                        attempts: Int(sqlite3_column_int64(stmt, 13))))
        }
        return out
    }

    func batchState(_ batchId: String) throws -> CloudBatchState? {
        let stmt = try prepare("SELECT state FROM sealed_batch WHERE batch_id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, batchId, -1, cloudSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = text(stmt, 0) else { return nil }
        return CloudBatchState(rawValue: raw)
    }

    /// Apply a checksum-matching receipt: acknowledge EXACTLY this batch's membership and record the
    /// receipt. Records are released one batch at a time, so an out-of-order acknowledgement cannot
    /// release (or delete) an earlier batch that is still in flight — the earlier hole stays.
    func applyReceipt(batchId: String, contentSha256: String, receiptJSON: String) throws -> CloudReceiptOutcome {
        let stmt = try prepare("SELECT state, content_sha256 FROM sealed_batch WHERE batch_id = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, batchId, -1, cloudSQLiteTransient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return .unknownBatch }
        let state = text(stmt, 0).flatMap(CloudBatchState.init(rawValue:))
        let sealedSha = text(stmt, 1) ?? ""
        if state == .acked { return .duplicate }
        guard !contentSha256.isEmpty else { return .malformed }
        guard contentSha256.lowercased() == sealedSha.lowercased() else {
            return .checksumMismatch(expected: sealedSha, received: contentSha256)
        }
        try exec("BEGIN IMMEDIATE;")
        do {
            let upd = try prepare("UPDATE sealed_batch SET state = 'acked', receipt_json = ?, task_id = NULL WHERE batch_id = ?")
            defer { sqlite3_finalize(upd) }
            sqlite3_bind_text(upd, 1, receiptJSON, -1, cloudSQLiteTransient)
            sqlite3_bind_text(upd, 2, batchId, -1, cloudSQLiteTransient)
            try step(upd)
            let rel = try prepare("UPDATE journal_record SET state = 2 WHERE batch_id = ? AND state = 1")
            defer { sqlite3_finalize(rel) }
            sqlite3_bind_text(rel, 1, batchId, -1, cloudSQLiteTransient)
            try step(rel)
            try exec("COMMIT;")
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
        return .acknowledged(records: changes())
    }

    private func changes() -> Int {
        guard let db else { return 0 }
        return Int(sqlite3_changes(db))
    }

    /// Reap acknowledged batches only. Unacknowledged entries are never removed — not under disk
    /// pressure, not on a retention sweep. `keepSeconds` only delays the removal of ACKED rows.
    @discardableResult
    func pruneAcknowledged(nowMs: Int, keepSeconds: Int) throws -> (records: Int, batches: Int, bytes: Int) {
        let cutoff = nowMs - keepSeconds * 1000
        try exec("BEGIN IMMEDIATE;")
        do {
            let bytesStmt = try prepare("SELECT COALESCE(SUM(LENGTH(payload)),0), COUNT(*) FROM journal_record WHERE state = 2 AND created_at_ms < ?")
            sqlite3_bind_int64(bytesStmt, 1, Int64(cutoff))
            var bytes = 0, records = 0
            if sqlite3_step(bytesStmt) == SQLITE_ROW {
                bytes = Int(sqlite3_column_int64(bytesStmt, 0))
                records = Int(sqlite3_column_int64(bytesStmt, 1))
            }
            sqlite3_finalize(bytesStmt)
            try exec("DELETE FROM journal_record WHERE state = 2 AND created_at_ms < \(cutoff);")
            try exec("DELETE FROM sealed_batch WHERE state = 'acked' AND created_at_ms < \(cutoff);")
            let batches = changes()
            try exec("COMMIT;")
            return (records, batches, bytes)
        } catch {
            try? exec("ROLLBACK;")
            throw error
        }
    }

    func stats(nowMs: Int, diskPressureBytes: Int) throws -> CloudJournalStats {
        var out = CloudJournalStats.empty
        let stmt = try prepare("""
        SELECT COUNT(*), COALESCE(SUM(LENGTH(payload)),0), COALESCE(MIN(received_at_ms), 0)
        FROM journal_record WHERE state != 2
        """)
        defer { sqlite3_finalize(stmt) }
        if sqlite3_step(stmt) == SQLITE_ROW {
            out.pendingRecords = Int(sqlite3_column_int64(stmt, 0))
            out.pendingBytes = Int(sqlite3_column_int64(stmt, 1))
            let oldest = Int(sqlite3_column_int64(stmt, 2))
            out.oldestPendingAgeSeconds = oldest > 0 ? max(0, (nowMs - oldest) / 1000) : 0
        }
        out.sealedBatches = try countBatches(state: .sealed) + countBatches(state: .reserved)
        out.uploadedBatches = try countBatches(state: .uploaded)
        out.diskPressure = out.pendingBytes >= diskPressureBytes
        out.historyCursorHeld = (try metaValue("history_cursor_held")).map { $0 == "1" } ?? false
        out.overflowRecords = Int(try metaValue("staging_overflow") ?? "0") ?? 0
        out.lastError = try metaValue("last_error")
        return out
    }

    private func countBatches(state: CloudBatchState) throws -> Int {
        let stmt = try prepare("SELECT COUNT(*) FROM sealed_batch WHERE state = ?")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, state.rawValue, -1, cloudSQLiteTransient)
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    func setFlag(_ key: String, _ on: Bool) throws { try setMeta(key, on ? "1" : "0") }
    func setError(_ message: String?) throws { try setMeta("last_error", message ?? "") }
    func addOverflow(_ n: Int) throws {
        guard n > 0 else { return }
        let current = Int(try metaValue("staging_overflow") ?? "0") ?? 0
        try setMeta("staging_overflow", String(current + n))
        // An overflow is a real capture gap. The history cursor must not advance past it until the
        // caller has recorded the gap, so the hold is set here rather than left to the caller.
        try setMeta("history_cursor_held", "1")
    }

    func checkpoint() { try? exec("PRAGMA wal_checkpoint(PASSIVE);") }
    func close() { if let db { sqlite3_close_v2(db) }; db = nil }
}

// MARK: - Journal

/// The durable, owner-scoped journal at the notification boundary.
///
/// Contract (spec F2):
///  - `submit` is `nonisolated`, non-throwing and non-blocking: it appends to an ordered staging
///    buffer and returns. The BLE path never waits for SQLite, and a cloud failure can never stop or
///    block collection.
///  - Records become durable AND transport-eligible in one transaction (`state = 0` IS eligibility),
///    so there is no window in which a record is visible to the sealer but not yet committed.
///  - The dense receive sequence is persisted, so a relaunch continues it instead of restarting it.
///  - Unacknowledged records are never pruned.
public actor CloudJournal {
    public struct Configuration: Sendable, Equatable {
        public var ownerId: String
        public var sourceId: String
        public var deviceId: String
        public init(ownerId: String, sourceId: String, deviceId: String) {
            self.ownerId = ownerId.lowercased()
            self.sourceId = sourceId.lowercased()
            self.deviceId = deviceId.lowercased()
        }
    }

    /// Sealing bounds. `activeTargetSeconds` is the active-use seal target (the spec's ~2 s); the
    /// record/byte caps bound one file regardless of age.
    public struct SealPolicy: Sendable, Equatable {
        public var activeTargetSeconds: Double = 2
        public var maxRecords: Int = 2_000
        public var maxBytes: Int = 1 << 20
        public var diskPressureBytes: Int = 256 << 20
        public var ackedRetentionSeconds: Int = 7 * 24 * 3600
        public init() {}
    }

    /// The process-wide journal. Unconfigured (`activate` not called) means every `submit` is a
    /// no-op, which is what keeps cloud mode off from changing anything.
    public static let shared = CloudJournal()

    private let staging = CloudJournalStaging()
    private var store: CloudJournalStore?
    private var configuration: Configuration?
    private var policy = SealPolicy()
    private var drainScheduled = false
    private var drainTask: Task<Void, Never>?
    private var lastError: String?
    private var consecutiveFailures = 0

    public init() {}

    // MARK: notification boundary (nonisolated, never throws, never blocks)

    /// Queue one record for durable commit. Safe to call from the BLE notification path.
    public nonisolated func submit(_ record: CloudJournalRecord) {
        guard isActive else { return }
        if !staging.append(record) {
            Task { await self.noteStagingOverflow() }
        }
        scheduleDrain()
    }

    public nonisolated func submit(_ records: [CloudJournalRecord]) {
        guard isActive, !records.isEmpty else { return }
        var dropped = 0
        for r in records where !staging.append(r) { dropped += 1 }
        if dropped > 0 { Task { await self.noteOverflow(dropped) } }
        scheduleDrain()
    }

    /// Read without hopping actors.
    ///
    /// Set by `enableStaging()` BEFORE the store is opened, so records that arrive while the journal is
    /// still activating (the earliest restored notifications of a Bluetooth relaunch, which are exactly
    /// the ones that are hardest to obtain) are STAGED rather than dropped. They are committed as soon
    /// as activation finishes. A stale read here costs at most one submit during teardown.
    private nonisolated(unsafe) static var activeFlag = false
    private nonisolated var isActive: Bool { CloudJournal.activeFlag }

    /// Start accepting records. Synchronous on purpose: it must be callable from a launch path that
    /// cannot await (the app delegate's `didFinishLaunching`), before the SQLite file is open.
    public nonisolated static func enableStaging() { CloudJournal.activeFlag = true }

    /// Stop accepting records (cloud mode disabled). Staged records are kept, not dropped.
    public nonisolated static func disableStaging() { CloudJournal.activeFlag = false }

    /// At most one coalescing drain is in flight. A `Task` per notification would be a task storm at
    /// notification rates; the periodic `drainLoop` is the backstop, so a submit that lands during a
    /// commit is picked up within ~1 s rather than spawning another task.
    private nonisolated func scheduleDrain() {
        guard staging.beginDrain() else { return }
        Task { await self.drainSoon() }
    }

    // MARK: lifecycle

    /// Open the journal for an owner and start committing. Idempotent for the same configuration.
    public func activate(configuration: Configuration, policy: SealPolicy = SealPolicy(),
                         directory: URL? = nil) throws {
        self.policy = policy
        self.configuration = configuration
        if store == nil {
            // `directory` is an override for tests, which must never touch the real App Support
            // container; production callers pass nil and get the protected default location.
            let dir = try directory ?? CloudJournalPaths.defaultDirectory()
            guard CloudJournalPaths.isDataAvailable(at: dir) else {
                lastError = "protected data unavailable at launch"
                throw CloudJournalError.protectedDataUnavailable(dir.path)
            }
            store = try CloudJournalStore(directory: dir)
        }
        CloudJournal.enableStaging()
        drainTask?.cancel()
        drainTask = Task { [weak self] in
            await self?.drainLoop()
        }
    }

    /// Stop committing (cloud mode disabled, or sign-out). Staged records are kept, not dropped.
    public func deactivate(flushFirst: Bool = true) async {
        CloudJournal.disableStaging()
        if flushFirst { _ = await commitStaged() }
        drainTask?.cancel()
        drainTask = nil
    }

    // MARK: commit path

    /// Commit everything staged, in order. Returns the number of records committed.
    @discardableResult
    public func flush() async -> Int {
        await commitStaged()
    }

    private func drainSoon() async {
        // Short coalescing window: at most ~1 s of records are ever un-committed while the app is
        // executing, which is the bounded pre-commit window the spec allows. Lifecycle transitions
        // call `flush()` directly so they do not wait for it.
        try? await Task.sleep(nanoseconds: 700_000_000)
        await commitStaged()
        staging.endDrain()
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { return }
            await commitStaged()
        }
    }

    @discardableResult
    private func commitStaged() async -> Int {
        guard let store, let config = configuration else { return 0 }
        let staged = staging.takeAll()
        guard !staged.isEmpty else { return 0 }
        let nowMs = Int(Date().timeIntervalSince1970 * 1000)
        do {
            let n = try store.append(staged, ownerId: config.ownerId, sourceId: config.sourceId,
                                           deviceId: config.deviceId, nowMs: nowMs)
            consecutiveFailures = 0
            lastError = nil
            staging.clearError()
            return n
        } catch {
            // Put them back at the front, in order, so a retry preserves arrival order. Anything that
            // no longer fits is counted as overflow (and holds the history cursor) rather than being
            // dropped quietly.
            let dropped = staging.requeueFront(staged)
            consecutiveFailures += 1
            lastError = String(describing: error)
            try? store.setError(lastError)
            if dropped > 0 { try? store.addOverflow(dropped) }
            return 0
        }
    }

    private func noteStagingOverflow() async {
        await noteOverflow(1)
    }

    private func noteOverflow(_ n: Int) async {
        lastError = "staging overflow: \(n) record(s)"
        if let store { try? store.addOverflow(n) }
    }

    // MARK: sealing support

    public func sealCandidates(limit: Int = 8, nowMs: Int? = nil) async throws -> [CloudSealCandidate] {
        guard let store else { return [] }
        let now = nowMs ?? Int(Date().timeIntervalSince1970 * 1000)
        let groups = try store.pendingGroups(maxRecords: policy.maxRecords, maxBytes: policy.maxBytes,
                                                   minAgeSeconds: policy.activeTargetSeconds,
                                                   nowMs: now, limit: limit)
        guard let config = configuration else { return groups }
        return groups.map { g in
            CloudSealCandidate(ownerId: config.ownerId, sourceId: config.sourceId, deviceId: g.deviceId,
                               stream: g.stream, firstSeq: g.firstSeq, lastSeq: g.lastSeq,
                               recordCount: g.recordCount, oldestReceivedAtMs: g.oldestReceivedAtMs,
                               byteSize: g.byteSize, windowIdentity: g.windowIdentity)
        }
    }

    public func entries(for candidate: CloudSealCandidate) async throws -> [CloudJournalEntry] {
        guard let store else { return [] }
        return try store.pendingEntries(deviceId: candidate.deviceId, stream: candidate.stream,
                                              upTo: candidate.lastSeq)
    }

    /// Register an immutable payload file as a durable job and mark exactly its membership sealed.
    public func registerSeal(_ candidate: CloudSealCandidate, batchId: String, filePath: String,
                             contentSha256: String, contentLength: Int, protocolVersion: String? = nil,
                             endCursorJSON: String? = nil, nowMs: Int? = nil) async throws {
        guard let store, let config = configuration else { throw CloudJournalError.notOpen("registerSeal") }
        try store.registerSeal(candidate, batchId: batchId, filePath: filePath,
                               contentSha256: contentSha256, contentLength: contentLength,
                               ownerId: config.ownerId, sourceId: config.sourceId,
                               protocolVersion: protocolVersion, endCursorJSON: endCursorJSON,
                               nowMs: nowMs ?? Int(Date().timeIntervalSince1970 * 1000))
    }

    /// The append cursor to resume from for one (device, stream): the end cursor of the last
    /// ACKNOWLEDGED batch. Persisted, so a relaunch continues the append sequence instead of
    /// restarting it.
    public func appendCursorJSON(deviceId: String, stream: CloudStreamKind) async -> String? {
        try? store?.metaValue("cursor.\(deviceId.lowercased()).\(stream.rawValue)")
    }

    /// Persist the end cursor echoed by an accepted batch. Called only after a durable receipt, so a
    /// lost response can never advance the cursor past an unacknowledged batch.
    public func saveAppendCursor(deviceId: String, stream: CloudStreamKind, endCursorJSON: String) async throws {
        try store?.setMeta("cursor.\(deviceId.lowercased()).\(stream.rawValue)", endCursorJSON)
    }

    public func markReserved(batchId: String, taskId: String, taskKind: String, authExpiresAtMs: Int?) async throws {
        try store?.markReserved(batchId: batchId, taskId: taskId, taskKind: taskKind,
                                      authExpiresAtMs: authExpiresAtMs)
    }

    public func markUploaded(batchId: String) async throws { try store?.markUploaded(batchId: batchId) }

    public func markFailed(batchId: String, error: String, nextAttemptAtMs: Int?, blocked: Bool = false) async throws {
        try store?.markFailed(batchId: batchId, error: error, nextAttemptAtMs: nextAttemptAtMs, blocked: blocked)
    }

    /// Return a blocked batch's records to the pending pool for re-sealing
    /// (see `CloudJournalStore.resealBlocked`).
    public func resealBlocked(batchId: String) async throws {
        try store?.resealBlocked(batchId: batchId)
    }

    /// Sealed batches in the given states (async facade over the store).
    public func sealedBatches(states: [CloudBatchState], dueBeforeMs: Int?, limit: Int) async throws -> [CloudSealedBatch] {
        return try store?.sealedBatches(states: states, dueBeforeMs: dueBeforeMs, limit: limit) ?? []
    }

    public func batches(states: [CloudBatchState], dueBeforeMs: Int? = nil, limit: Int = 16) async throws -> [CloudSealedBatch] {
        guard let store else { return [] }
        return try store.sealedBatches(states: states, dueBeforeMs: dueBeforeMs, limit: limit)
    }

    public func batchState(_ batchId: String) async throws -> CloudBatchState? {
        try store?.batchState(batchId)
    }

    /// Apply a receipt. Only an exact checksum match releases the batch's membership.
    public func applyReceipt(batchId: String, contentSha256: String, receiptJSON: String) async throws -> CloudReceiptOutcome {
        guard let store else { return .unknownBatch }
        return try store.applyReceipt(batchId: batchId, contentSha256: contentSha256, receiptJSON: receiptJSON)
    }

    /// Remove ACKNOWLEDGED entries only. Unacknowledged work is kept under every circumstance.
    @discardableResult
    public func pruneAcknowledged(nowMs: Int? = nil) async throws -> (records: Int, batches: Int, bytes: Int) {
        guard let store else { return (0, 0, 0) }
        return try store.pruneAcknowledged(nowMs: nowMs ?? Int(Date().timeIntervalSince1970 * 1000),
                                                 keepSeconds: policy.ackedRetentionSeconds)
    }

    public func stats() async -> CloudJournalStats {
        guard let store else {
            var empty = CloudJournalStats.empty
            empty.overflowRecords = staging.overflowCount
            empty.lastError = lastError
            return empty
        }
        var s = (try? store.stats(nowMs: Int(Date().timeIntervalSince1970 * 1000),
                                       diskPressureBytes: policy.diskPressureBytes)) ?? .empty
        s.overflowRecords += staging.overflowCount
        if let lastError { s.lastError = lastError }
        s.historyCursorHeld = s.historyCursorHeld || staging.overflowCount > 0
        return s
    }

    /// Whether the history cursor may advance. False while a real capture gap is outstanding: the
    /// caller must keep the strap cursor where it is and let the receiver see the gap.
    public func historyCursorMayAdvance() async -> Bool {
        let s = await stats()
        return !s.historyCursorHeld
    }

    /// Clear the hold once the gap has been reported to the receiver (or the operator accepts it).
    public func clearHistoryHold() async throws {
        staging.resetOverflow()
        try store?.setFlag("history_cursor_held", false)
    }

    /// The persisted dense receive sequence, for diagnostics and for the readback freshness label.
    public func recordsReceived() async -> Int {
        guard let store else { return 0 }
        return Int((try? store.metaValue("records_received")) ?? "0") ?? 0
    }
}

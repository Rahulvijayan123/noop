import Foundation
import NoopPush

// MARK: - Read API (CONTRACT C10)

/// One decoded IMU second exactly as `ImuSessionFileStore.readRecords` returns it. Mirrors the
/// C10 `ImuStoredRecord` shape so the object-lane source does not depend on the store's type:
/// the concrete reader maps one to the other.
public struct ImuSourceRecord: Sendable, Equatable {
    public let ts: Int64
    public let receivedAtMs: Int64
    /// 600 i16 axis-major columns (100 Hz × 6 axes), exactly as the store wrote them.
    public let columns: [Int16]

    public init(ts: Int64, receivedAtMs: Int64, columns: [Int16]) {
        self.ts = ts
        self.receivedAtMs = receivedAtMs
        self.columns = columns
    }
}

/// The read seam the source pages through. The app's production reader wraps
/// `ImuSessionFileStore.readRecords(deviceId:fromTs:toTs:)` (C10); tests supply a fake.
public protocol ImuObjectReading: Sendable {
    /// Reads ALL windows for the device whose records fall in `[fromTs, toTs]`, flushed + disk,
    /// sorted and deduped by ts (the C10 read contract).
    func readImuRecords(deviceId: String, fromTs: Int64, toTs: Int64) async throws -> [ImuSourceRecord]
    /// P2-5: flush the device's RAM-only pending tail to disk, then return the earliest second
    /// that is STILL not durable (its flush failed and it remains buffered), or nil when every
    /// buffered record reached disk. The pager must never let the cursor advance at or past a
    /// returned frontier — that second has no durable bytes to re-read, so it would be skipped
    /// forever.
    func flushPendingFor(deviceId: String) async throws -> Int64?
}

/// Production reader: the C10 read API on the shared file store. The store is `@MainActor`; the
/// object lane runs on its own task, so reads hop to the main actor here — never to the BLE
/// delegate thread. This is the ONLY place the source touches `ImuSessionFileStore` / the
/// `ImuStoredRecord` type.
public struct ImuSessionFileStoreReader: ImuObjectReading {
    public init() {}

    public func readImuRecords(deviceId: String, fromTs: Int64, toTs: Int64) async throws -> [ImuSourceRecord] {
        let records = await MainActor.run {
            ImuSessionFileStore.shared.readRecords(deviceId: deviceId, fromTs: fromTs, toTs: toTs)
        }
        return records.map { ImuSourceRecord(ts: $0.ts, receivedAtMs: $0.receivedAtMs, columns: $0.columns) }
    }

    /// P2-5: hop to the MainActor (the store is `@MainActor`; the lane runs on its own task — never
    /// the BLE delegate thread) and surface the store's earliest still-buffered second so the
    /// pager can fence the cursor below it.
    public func flushPendingFor(deviceId: String) async throws -> Int64? {
        await MainActor.run {
            ImuSessionFileStore.shared.flushPendingFor(deviceId: deviceId)
        }
    }
}

// MARK: - PushSnapshotSource for the rawImuSession object lane

/// Pages `PushRawImuRecord` rows out of the IMU file store for the NoopPush object lane.
///
/// Contract (CONTRACTS C1 + C10, upload-verify report §4 item 1):
///  - One record per second: `rowId == ts` (the file store keys records by timestamp), so the
///    durable cursor is `PushCursor(rowId: ts, fingerprint: sha256("rawImuSession\n{deviceId}\n{ts}"))`
///    exactly as `PushProtocol.binaryKeyFingerprint` computes it.
///  - `binaryPage` pages strictly AFTER the cursor and bounds every object to a ~300 s target
///    window within the 1 h hard cap / 5000 records / 64 MiB decoded limits that the coordinator
///    and `PushProtocol.binaryObjectBatch` enforce.
///  - `acknowledgeBinary` is a no-op: the source never deletes store data. The durable cursor
///    lives in the progress store and is advanced by the coordinator only after a verified
///    receipt (`PushCoordinator.pushObjects` → `progress.saveBinaryCursor`).
///  - Reads never run on the BLE delegate thread; the lane loop drives this from its own task.
public final class ImuObjectSource: PushSnapshotSource, @unchecked Sendable {
    /// Target object duration. ~300 s keeps one object ≈ 360 KB decoded (≈ 24 objects per 2-hour
    /// capture), well inside the negotiated ceilings while staying bounded per upload.
    public static let targetObjectWindowSeconds: Int64 = 300
    /// Hard window: one hour, the receiver's rawImuSession ceiling (`PushProtocolLimits.maxImuObjectWindowSeconds`).
    public static let hardWindowSeconds: Int64 = PushProtocolLimits.maxImuObjectWindowSeconds
    /// Bounded probes per `binaryPage` call: one hard window each, so a single call can span up
    /// to 24 hours of gap without an unbounded read. The scan resumes across calls via the
    /// in-memory frontier below.
    static let maxProbesPerCall = 24
    /// Probes never look further ahead than the later of the phone clock and the cursor, plus this
    /// much for a strap whose clock runs ahead of the phone's. Records are keyed by the strap's
    /// clock, and every probe decodes the device's whole store, so reading windows that cannot
    /// hold data yet is pure cost.
    static let futureSlackSeconds: Int64 = 1_800
    /// The remembered gap position trails the phone clock by this much. A second captured now
    /// (strap clock no more than this far behind the phone's) therefore always lies at or above
    /// it and is found by the next scan.
    static let frontierLagSeconds: Int64 = 1_200

    private let store: any ImuObjectReading
    private let deviceIdProvider: @Sendable () -> String?
    private let now: @Sendable () -> Int64
    /// Asked on every page. Raw motion is the most sensitive thing this app uploads, and switching
    /// Cloud off does not stop the runtime, so the source itself refuses to hand anything out while
    /// the switch is off. Nothing is consumed: the cursor and the scan position stay where they were.
    private let uploadAllowed: @Sendable () -> Bool
    /// How far back the first-ever (cursor-less) scan looks for the store's oldest records.
    /// Continuous capture is bounded by the NOOPIMU retention policy; this horizon only needs to
    /// cover that retention. Scanning older data would require a per-call scan state.
    private let lookbackSeconds: Int64

    private let lock = NSLock()
    /// Where a gap scan stopped, so the next cycle resumes instead of re-reading the same window.
    /// In-memory on purpose: a relaunch simply re-scans a few empty windows (each is a cheap,
    /// bucket-bounded read) and the cursor itself is the durable state.
    private var scanFrontier: Int64?

    public init(store: any ImuObjectReading,
                deviceId: @escaping @Sendable () -> String?,
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                lookbackSeconds: Int64 = 14 * 24 * 3600,
                uploadAllowed: @escaping @Sendable () -> Bool = { true }) {
        self.store = store
        self.deviceIdProvider = deviceId
        self.now = now
        self.lookbackSeconds = lookbackSeconds
        self.uploadAllowed = uploadAllowed
    }

    // MARK: PushSnapshotSource

    public func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] {
        deviceIdProvider().map { [$0] } ?? []
    }

    public func binaryPage(table: PushBinaryTable, deviceId: String, afterRowId: Int64,
                           limit: Int, limits: PushSourceReadLimits) async throws -> PushBinaryPage {
        guard table == .rawImuSession, uploadAllowed() else { return .init(rows: [], hasMore: false) }
        guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
        let window = try await nextWindow(deviceId: deviceId, afterRowId: afterRowId, limits: limits)
        guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
        guard let anchor = window.first?.ts, !window.isEmpty else { return .init(rows: [], hasMore: false) }

        // Select the ~300 s target object from the (bounded) hard window. The coordinator's own
        // selection (`PushProtocol.binaryObjectBatch`) re-enforces the 1 h / 5000 / 64 MiB caps.
        var selected: [PushRawImuRecord] = []
        var bytes = PushBinaryCodec.packedHeaderSize(for: .rawImuSession)
        for record in window {
            guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
            guard selected.count < limit, record.ts - anchor < Self.targetObjectWindowSeconds else { break }
            let data = Self.columnsData(record.columns)
            // A malformed row is skipped rather than allowed to wedge the whole object.
            guard data.count == PushBinaryCodec.imuRecordPayloadBytes else { continue }
            let row = PushRawImuRecord(rowId: record.ts, ts: record.ts, columns: data)
            let rowBytes = try PushBinaryCodec.packedRowSize(.rawImuSession(row))
            guard rowBytes <= limits.maximumDecodedBytes - bytes else { break }
            bytes += rowBytes
            selected.append(row)
        }
        guard !selected.isEmpty else { throw PushSourceReadError.requiresCompatibleEncoding }
        let hasMore = window.count > selected.count
        return .init(rows: selected.map { .rawImuSession($0) }, hasMore: hasMore)
    }

    public func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? {
        guard table == .rawImuSession else { return nil }
        let records = try await store.readImuRecords(deviceId: deviceId, fromTs: rowId, toTs: rowId)
        guard let record = records.first(where: { $0.ts == rowId }) else { return nil }
        let data = Self.columnsData(record.columns)
        guard data.count == PushBinaryCodec.imuRecordPayloadBytes else { return nil }
        return .rawImuSession(PushRawImuRecord(rowId: record.ts, ts: record.ts, columns: data))
    }

    /// Legacy `binaryRows` fallback; the coordinator pages through `binaryPage` for object lanes.
    public func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] {
        guard table == .rawImuSession else { return [] }
        let fromTs = afterRowId + 1
        // P2-5: same flush-before-read + frontier fence as binaryPage — a still-buffered second
        // must never be skipped by the cursor.
        let frontier = try await store.flushPendingFor(deviceId: deviceId)
        let toTs = frontier.map { min(afterRowId + Self.hardWindowSeconds, $0 - 1) }
            ?? afterRowId + Self.hardWindowSeconds
        guard toTs >= fromTs else { return [] }
        let records = try await store.readImuRecords(deviceId: deviceId, fromTs: fromTs, toTs: toTs)
        return records.prefix(limit).compactMap { record in
            let data = Self.columnsData(record.columns)
            guard data.count == PushBinaryCodec.imuRecordPayloadBytes else { return nil }
            return .rawImuSession(PushRawImuRecord(rowId: record.ts, ts: record.ts, columns: data))
        }
    }

    /// The source never mutates the store: local rows are released only by the coordinator
    /// advancing the durable cursor after a verified receipt. Nothing to do here.
    public func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {}

    public func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? { nil }
    public func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] { [] }
    public func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] { [] }

    // MARK: - Paging

    /// Returns the bounded hard window that starts at the oldest record at or after the cursor,
    /// or `[]` when there is nothing to send. Gaps are handled by bounded forward probing: each
    /// probe reads one hard window, and the probe position is remembered across calls so a long
    /// gap costs a few cheap reads per cycle instead of one unbounded read.
    private func nextWindow(deviceId: String, afterRowId: Int64,
                            limits: PushSourceReadLimits) async throws -> [ImuSourceRecord] {
        let fromTs = afterRowId + 1
        // P2-5 flush-before-read: every page starts by flushing the device's RAM-only pending tail
        // so `readRecords` sees durable data. The returned flush frontier is the earliest second
        // whose flush FAILED (still buffered): the cursor must never advance at or past it, or
        // that second would be stranded below the cursor forever. Probes are fenced below the
        // frontier and the scan pauses once it blocks.
        let flushFrontier = try await store.flushPendingFor(deviceId: deviceId)
        lock.lock()
        if let flushFrontier, flushFrontier <= fromTs {
            // The next second to read is not durable yet — pause this cycle. It is still buffered
            // and will be retried on the next flush; advancing would strand it permanently.
            lock.unlock()
            return []
        }
        let present = now()
        let trailingEdge = present - Self.frontierLagSeconds
        var probeStart: Int64
        // A marker ahead of the trailing edge (the phone clock moved backwards) is not trusted.
        if let scan = scanFrontier, scan >= fromTs, scan <= trailingEdge {
            probeStart = scan
        } else if afterRowId == 0 {
            // First-ever page for this device: the store's data lives at real epoch seconds, far
            // above an empty cursor, so anchor the scan in a recent, bounded horizon instead of
            // scanning across years of empty space.
            probeStart = max(0, present - lookbackSeconds)
        } else {
            probeStart = fromTs
        }
        // Defensive: a stale gap marker at/behind the blocked second must not skip durable seconds
        // below it — restart the scan at the cursor and let the fence below bound the probes.
        if let flushFrontier, probeStart >= flushFrontier { probeStart = fromTs }
        lock.unlock()

        let reach = max(present, fromTs) + Self.futureSlackSeconds
        var probes = 0
        while probes < Self.maxProbesPerCall, probeStart < reach {
            guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
            var probeEnd = min(probeStart + Self.hardWindowSeconds, Int64.max)
            // Never read (and thus never return) a second at or past the first non-durable second.
            if let flushFrontier, flushFrontier > probeStart { probeEnd = min(probeEnd, flushFrontier) }
            let records = try await store.readImuRecords(deviceId: deviceId, fromTs: probeStart, toTs: probeEnd - 1)
            if let first = records.min(by: { $0.ts < $1.ts }) {
                lock.lock(); scanFrontier = nil; lock.unlock()
                // All returned records are inside [first, first + hardWindow); sort + dedupe to
                // satisfy the codec's strict rowid ordering even for a defensive adapter.
                let sorted = records.filter { $0.ts >= first.ts }.sorted { $0.ts < $1.ts }
                var seen = Set<Int64>()
                let distinct = sorted.filter { seen.insert($0.ts).inserted }
                return distinct
            }
            probeStart += Self.hardWindowSeconds
            probes += 1
            if let flushFrontier, probeStart >= flushFrontier { break }   // a blocked second fences the scan
        }
        lock.lock()
        // Remember the gap position only while it stays BELOW any blocked second — a frontier must
        // fence future scans so the marker never points past data that is not durable yet. It also
        // never passes the trailing edge: windows nearer the present can still fill.
        let remembered = min(probeStart, trailingEdge)
        let mayAdvance = flushFrontier.map { remembered < $0 } ?? true
        if remembered > fromTs && mayAdvance { scanFrontier = remembered }
        lock.unlock()
        return []
    }

    /// 600 i16 little-endian columns → the 1200-byte record payload the NPB1 codec requires.
    static func columnsData(_ columns: [Int16]) -> Data {
        var data = Data(capacity: columns.count * 2)
        for value in columns {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }
}

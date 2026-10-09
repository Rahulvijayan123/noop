import Compression
import Foundation
import os
import WhoopProtocol

/// Canonical decoded 100 Hz IMU storage: UTC half-hour files with appendable 30-second zlib blocks.
///
/// Durability contract (spec §6 / C8 Fix E): a record is only ever considered HANDLED after its
/// block is flushed to disk. The in-RAM `pending` tail is bounded by an append cadence flush
/// (~10 s), and `seen` (the dedupe set) is extended ONLY after a successful `flushKey` write —
/// a failed write stays in `pending` and is retried on the next cadence, never marked seen.
@MainActor
public final class ImuSessionFileStore {
    struct Stats { let bytes: Int64; let diskSeconds: Int; let pendingSeconds: Int; let firstTs: Int64?
        var coveredSeconds: Int { diskSeconds + pendingSeconds } }
    struct ExportSegment { let name: String; let data: Data; let startTs, endTs: Int; let sampleCount: Int }
    private struct Window: Codable { let id, deviceId: String; let from: Int64; var to: Int64? }
    private struct Record { let ts, receivedAtMs: Int64; let columns: [Int16] }
    public static let shared = ImuSessionFileStore()
    static let sampleRate = 100, axes = 6, blockSeconds = 30
    static let segmentSeconds: Int64 = 30 * 60
    private static let payloadBytes = sampleRate * axes * 2
    private static let magic = Data("NOOPIMU2".utf8)
    /// C8 Fix E: append-cadence flush so the in-RAM tail reaches disk at most this long after the
    /// last frame, instead of only at 30-record block boundaries.
    private static let flushCadenceMs: Int64 = 10_000
    /// P2-4: bounded eviction cadence during continuous capture. `evictExpired` used to run only on
    /// session start/register, so an always-active session never triggered retention and could grow
    /// to the disk limit. During an active capture it now runs on this cadence (5 min, far below
    /// the 30-day age floor) so the active session's expired segments are still reaped.
    private static let evictionCadenceMs: Int64 = 5 * 60_000
    private let defaults: UserDefaults
    private let key = "imu-session-windows-v1"
    private let directory: URL
    /// Timestamps DURABLE on disk per segment file (seeded by a scan on first touch, extended only
    /// after a successful block write). Records still in `pending` are deliberately NOT here.
    private var seen: [String: Set<Int64>] = [:]
    private var pending: [String: [Record]] = [:]
    private var lastFlushCheckMs: Int64 = 0
    private var lastEvictionCheckMs: Int64 = 0

    private init() {
        let fm = FileManager.default
        let base = (try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                appropriateFor: nil, create: true)) ?? fm.temporaryDirectory
        directory = base.appendingPathComponent("OpenWhoop/RawImuSessions", isDirectory: true)
        defaults = .standard
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// A store over its own directory and window list. For tests: `shared` is the app's real capture, and a
    /// retention test must not be able to reach it.
    init(directory: URL, defaults: UserDefaults) {
        self.directory = directory
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func start(id: String, deviceId: String, fromMs: Int64) {
        evictExpired()
        var value = windows().filter { $0.id != id }
        value.append(Window(id: id, deviceId: deviceId, from: fromMs / 1_000, to: nil)); save(value)
        try? FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
    }
    /// Keep the open-ended activity-capture window for `deviceId` open (`ActivityImuCapture`): creates it
    /// when missing or closed, and closes the activity window of any other device id (the strap was swapped
    /// or re-identified). Idempotent and cheap: an already-open window is left exactly as it is, so the
    /// keep-alive can call this on every tick.
    func ensureActivityWindow(deviceId: String, nowMs: Int64) {
        let id = ActivityImuCapture.windowId(deviceId: deviceId)
        let all = windows()
        for other in all where ActivityImuCapture.isActivityWindow(other.id) && other.id != id && other.to == nil {
            complete(id: other.id, toMs: nowMs)
        }
        if all.contains(where: { $0.id == id && $0.deviceId == deviceId && $0.to == nil }) { return }
        start(id: id, deviceId: deviceId, fromMs: nowMs)
    }

    /// Close every open activity-capture window (the capture was switched off), so retention can reap them.
    func closeActivityWindows(nowMs: Int64) {
        for window in windows() where ActivityImuCapture.isActivityWindow(window.id) && window.to == nil {
            complete(id: window.id, toMs: nowMs)
        }
    }

    func complete(id: String, toMs: Int64) {
        flushSession(id); var value = windows()
        if let index = value.firstIndex(where: { $0.id == id }) { value[index].to = toMs / 1_000; save(value) }
    }
    func register(id: String, deviceId: String, fromMs: Int64, toMs: Int64) {
        evictExpired()
        var value = windows().filter { $0.id != id }
        value.append(Window(id: id, deviceId: deviceId, from: fromMs / 1_000, to: toMs / 1_000)); save(value)
        try? FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
    }
    func remove(id: String) {
        pending.keys.filter { $0.hasPrefix("\(id)/") }.forEach { pending[$0] = nil }
        seen.keys.filter { $0.hasPrefix(sessionDirectory(id).path) }.forEach { seen[$0] = nil }
        segmentBuckets.keys.filter { $0.hasPrefix(sessionDirectory(id).path) }.forEach { segmentBuckets[$0] = nil }
        save(windows().filter { $0.id != id })
    }
    func prepareForRead(_ id: String) { flushSession(id) }

    /// Every device id that has an IMU window (open or closed), sorted: the straps the object lane uploads for.
    func deviceIds() -> [String] { Array(Set(windows().map(\.deviceId))).sorted() }

    /// C8 Fix E: flush EVERY session's RAM-only pending tail to disk now. Idempotent and bounded —
    /// the durable tail never grows past `flushCadenceMs` of live capture, so this is a safe
    /// explicit flush for lifecycle points (background/termination; the app should call it from
    /// its scene-phase handler so a killed process loses at most the last ~10 s).
    func flushPending() {
        let keys = pending.keys.map { $0 }   // snapshot: flushKey mutates `pending`
        for key in keys { flushKey(key) }
    }

    func deleteFiles(_ id: String, removeItem: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }) -> Bool {
        flushSession(id); let dir = sessionDirectory(id)
        guard FileManager.default.fileExists(atPath: dir.path) else { return true }
        do { try removeItem(dir); return true } catch { return false }
    }

    func deleteDevice(_ deviceId: String) -> Bool {
        let owned = windows().filter { $0.deviceId == deviceId }.map(\.id)
        guard owned.allSatisfy({ deleteFiles($0) }) else { return false }
        owned.forEach { remove(id: $0) }
        // C8 Fix D: an unpaired/forgotten strap must not re-arm its capture intent on the next
        // connect. The device's IMU files are already gone (device unpair deletes them); clear the
        // durable 'want' marker that rides along with the device id.
        RawDataSessionStore.clearPersistedCaptureIntentIfDevice(deviceId)
        return true
    }

    /// WS-02-F01/F02 (spec §6): per-reason counts of shape-valid IMU frames the durable store
    /// dropped — payload-CRC failure, zero/constant/rail-saturated payloads. `.none`/`.malformed`
    /// never appear here: non-IMU frames return 0 from `append` before reaching the tally. A frame
    /// counted here is NEVER stored, so upstream can see the rejection rate and no corrupt/stuck
    /// payload can become a stationary window.
    public private(set) var rawImuRejections: [Whoop5RawImu.RawImuRejectReason: Int] = [:]

    /// Test seam: clear the rejection tally. The store is a process-wide singleton, so tests reset
    /// here (or snapshot deltas) between cases.
    public func resetRawImuRejections() { rawImuRejections = [:] }

    /// C8 Fix B: append one complete 1244-byte 5/MG IMU frame (or no-op for any other frame).
    /// The store gates on `Whoop5RawImu`'s exact shape, so the transport packet type is NOT
    /// trusted — decode is authoritative (mirrors Android `ImuSessionFileStore.append`).
    @discardableResult
    func append(deviceId: String, frame: [UInt8], receivedAtMs: Int64) -> Int {
        guard let ts = Whoop5RawImu.baseTs(frame), let columns = Whoop5RawImu.rawColumns(frame) else { return 0 }
        // WS-02-F01/F02: the durable IMU gate lives HERE, at the store boundary — the live seam
        // (BLEManager → Collector.recordGroundTruthImu) and both Backfiller routes all land on this
        // method. A shape-valid frame that fails the payload CRC32 or the conservative plausibility
        // check is counted with an explicit reason and never stored: a corrupt or stuck payload
        // must not become a valid stationary window (spec §6). `rawColumns` already proved shape,
        // so `storeAcceptance` can only reject on CRC/plausibility here.
        let rejection = Whoop5RawImu.storeAcceptance(of: frame)
        guard rejection == .none else {
            rawImuRejections[rejection, default: 0] += 1
            return 0
        }
        var count = 0
        for window in windows() where window.deviceId == deviceId && Int64(ts) >= window.from
            && (window.to == nil || Int64(ts) <= window.to!) {
            let bucket = Self.bucketStart(Int64(ts)), url = segmentFile(window.id, bucket)
            let pendingKey = "\(window.id)/\(bucket)"
            // Dedupe is split: `seen` (durable on disk) and `pending` (buffered in RAM). A record
            // is only moved into `seen` by a successful flush — so a frame that never reached disk
            // is NOT marked handled (spec §6: "do not mark failed writes as seen permanently").
            let onDisk = seen[url.path] ?? scan(url)
            seen[url.path] = onDisk   // cache the scan; every ts here is durable
            guard !onDisk.contains(Int64(ts)) else { continue }
            guard pending[pendingKey]?.contains(where: { $0.ts == Int64(ts) }) != true else { continue }
            pending[pendingKey, default: []].append(Record(ts: Int64(ts), receivedAtMs: receivedAtMs, columns: columns))
            if pending[pendingKey]!.count >= Self.blockSeconds { flushKey(pendingKey) }
            count += 1
        }
        flushIfDue(nowMs: receivedAtMs)
        // P2-4: retention must run DURING continuous capture, not only at start/register — an
        // always-active session otherwise never evicts and grows unbounded. Bounded cadence keeps
        // it out of the hot append path.
        evictIfDue(nowMs: receivedAtMs)
        return count
    }

    func stats(_ id: String, from: Int, to: Int) -> Stats {
        // Durability-honest split (C8 Fix E): `diskSeconds` counts only seconds whose records are
        // actually on disk; `pendingSeconds` counts the RAM-only tail separately, so the UI can
        // never report "ready" for data that only exists in memory.
        let disk = readRecords(id, from: from, to: to, includePending: false)
        let pendingRows = pending.filter { $0.key.hasPrefix("\(id)/") }.values.flatMap { $0 }
            .filter { $0.ts >= from && $0.ts <= to }
        let diskBytes = segmentFiles(id).reduce(Int64(0)) { value, url in
            value + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        let pendingBytes = pendingRows.reduce(Int64(0)) { $0 + Int64($1.columns.count * 2 + 20) }
        return Stats(bytes: diskBytes + pendingBytes,
                     diskSeconds: Set(disk.map(\.ts)).count,
                     pendingSeconds: Set(pendingRows.map(\.ts)).count,
                     firstTs: (disk + pendingRows).map(\.ts).min())
    }

    func exportSegments(_ id: String, from: Int, to: Int) -> [ExportSegment] {
        flushSession(id)
        let records = Dictionary(grouping: readRecords(id, from: from, to: to, includePending: false), by: \.ts)
            .compactMap { $0.value.first }.sorted { $0.ts < $1.ts }
        return Dictionary(grouping: records) { Self.bucketStart($0.ts) }.sorted { $0.key < $1.key }.compactMap { element in
            let (bucket, rows) = element
            guard let first = rows.first, let last = rows.last else { return nil }
            return ExportSegment(name: "imu-\(Self.utcName(bucket)).imus", data: encode(bucket: bucket, records: rows),
                startTs: Int(first.ts), endTs: Int(last.ts), sampleCount: rows.count * Self.sampleRate)
        }
    }

    /// C10 public read API (ios-upload consumes): ALL windows for a device, flushed + disk,
    /// sorted ascending, deduped by ts. Conflicting duplicates (same ts, different columns) are
    /// dropped BOTH — never silently one — and reported in `lastReadQuality` so upstream can
    /// treat them as error-rejected rows. Flushes the device's pending tail first so the read
    /// reflects durable state; a record whose flush is failing is simply absent this round and is
    /// retried on the next read (the upload cursor must not advance past it).
    public func readRecords(deviceId: String, fromTs: Int64, toTs: Int64) -> [ImuStoredRecord] {
        lastReadQuality = []
        let windows = windows().filter { $0.deviceId == deviceId }
        for window in windows { flushSession(window.id) }
        var rows: [Record] = []
        for window in windows {
            for url in segmentFiles(window.id, overlapping: fromTs, toTs) {
                rows += decodedSegment(url)
                    .filter { Int64($0.ts) >= fromTs && Int64($0.ts) <= toTs }
            }
        }
        let grouped = Dictionary(grouping: rows) { $0.ts }
        var notes: [ImuReadQualityNote] = []
        var kept: [Record] = []
        for (ts, group) in grouped {
            let first = group[0]
            if group.allSatisfy({ $0.columns == first.columns }) {
                kept.append(first)
            } else {
                notes.append(ImuReadQualityNote(ts: ts,
                    reason: "conflicting_duplicate: \(group.count) records share ts with different columns; all dropped"))
            }
        }
        lastReadQuality = notes.sorted { $0.ts < $1.ts }
        return kept.sorted { $0.ts < $1.ts }
            .map { ImuStoredRecord(ts: $0.ts, receivedAtMs: $0.receivedAtMs, columns: $0.columns) }
    }

    /// P2-5: flush EVERY window's RAM-only pending tail for a device — the upload read seam calls
    /// this before every page so `readRecords` sees durable data — then return the earliest second
    /// that is STILL not durable: its flush failed and it remains buffered (nil means the whole
    /// tail reached disk). A non-nil result is an upload-blocking condition: the object source must
    /// never let its cursor advance at or past that second, or the record would be stranded below
    /// the cursor forever (it has no durable bytes to re-read). Runs on the MainActor like every
    /// other store API — callers on other threads hop (see ImuSessionFileStoreReader).
    @discardableResult
    public func flushPendingFor(deviceId: String) -> Int64? {
        let windows = windows().filter { $0.deviceId == deviceId }
        for window in windows { flushSession(window.id) }
        let owned = Set(windows.map(\.id))
        return pending.filter { key, _ in
            guard let id = key.split(separator: "/").first else { return false }
            return owned.contains(String(id))
        }.values.flatMap { $0 }.map(\.ts).min()
    }

    /// How far the object lane has uploaded a strap's raw IMU, by local device id. Replaceable in tests.
    var uploadedThrough: (String) -> Int64? = { ImuUploadWatermarks.shared.uploadedThrough(localDeviceId: $0) }
    /// Whether this build uploads raw IMU at all. Without a cloud, nothing would ever be uploaded and data is
    /// evicted by age and size alone, as before. Replaceable in tests.
    var uploadProtectionEnabled: () -> Bool = { CloudPushSettings.isConfigured }
    /// Told whenever the hard ceiling evicted data that was not uploaded (besides the fault log).
    var onUnuploadedEviction: ((String) -> Void)?
    private static let log = Logger(subsystem: "com.noopapp.noop", category: "imu-retention")

    /// C8 Fix G + P2-4: apply the bounded NOOPIMU2 retention policy (age + size cap, conservative
    /// constants) plus the P2-4 active-session SEGMENT rule. Completed sessions are evicted whole;
    /// an active (open-ended) session is never evicted whole, but its expired segments that are
    /// fully before the active window ARE reaped (on the capture cadence) so continuous capture
    /// cannot grow without bound. Returns the evicted session ids.
    ///
    /// Age and size only ever take data the object lane has uploaded (`ImuRetentionPolicy.isUploaded` against
    /// the lane's watermark for the strap). Raw IMU that has not reached the server is kept, however old,
    /// until the footprint passes `hardCeilingBytes`; then the oldest is evicted anyway, uploaded or not, and
    /// that is logged as a fault.
    @discardableResult
    func evictExpired(now: Int64 = Int64(Date().timeIntervalSince1970),
                      policy: ImuRetentionPolicy = .default) -> [String] {
        let all = windows()
        let activeIds = Set(all.filter { $0.to == nil }.map(\.id))
        let protects = uploadProtectionEnabled()
        func uploaded(_ deviceId: String, through endTs: Int64?) -> Bool {
            !protects || ImuRetentionPolicy.isUploaded(endTs: endTs, uploadedThrough: uploadedThrough(deviceId))
        }
        var evicted: [String] = []
        for window in all where !activeIds.contains(window.id) {
            let rule = ActivityImuCapture.isActivityWindow(window.id) ? policy.activityCapture : policy
            if case .evict = rule.decision(active: false, endTs: window.to, now: now),
               uploaded(window.deviceId, through: lastSegmentEnd(window.id)) {
                evicted.append(window.id)
                deleteFiles(window.id)
                remove(id: window.id)
            }
        }
        // P2-4: continuous capture keeps ONE active session open-ended, so the whole-session rules
        // above never touch it. Reap only segments that are fully expired AND fully before the
        // active window (the bucket currently being written) — never the active window, never
        // seconds newer than the retention floor, never a segment not yet uploaded.
        let deviceOf = Dictionary(all.map { ($0.id, $0.deviceId) }, uniquingKeysWith: { first, _ in first })
        for id in activeIds {
            let device = deviceOf[id] ?? ""
            evictActiveSessionSegments(id, now: now,
                                       policy: ActivityImuCapture.isActivityWindow(id) ? policy.activityCapture : policy,
                                       isUploaded: { uploaded(device, through: $0) })
        }
        let survivors = windows()
        let totalBytes = survivors.reduce(Int64(0)) { $0 + sessionBytes($1.id) }
        let completed = survivors.filter { !activeIds.contains($0.id) }
            .filter { uploaded($0.deviceId, through: lastSegmentEnd($0.id)) }
            .map { (id: $0.id, endTs: $0.to, bytes: sessionBytes($0.id)) }
        var remainingBytes = totalBytes
        let completedBytes = Dictionary(completed.map { ($0.id, $0.bytes) }, uniquingKeysWith: { first, _ in first })
        for id in policy.evictionsForSizeCap(totalBytes: totalBytes, completed: completed)
            where !evicted.contains(id) {
            evicted.append(id)
            remainingBytes -= completedBytes[id] ?? 0
            deleteFiles(id)
            remove(id: id)
        }
        if remainingBytes > policy.hardCeilingBytes {
            evicted += evictOverHardCeiling(policy: policy, activeIds: activeIds, isUploaded: uploaded)
        }
        return evicted
    }

    /// The last resort: over `hardCeilingBytes`, evict the oldest completed sessions and the oldest segments of
    /// active sessions (never the bucket being written), uploaded or not, until the footprint is back under.
    /// Anything evicted that was not uploaded is logged as a fault. Returns the completed sessions evicted.
    private func evictOverHardCeiling(policy: ImuRetentionPolicy, activeIds: Set<String>,
                                      isUploaded: (String, Int64?) -> Bool) -> [String] {
        let survivors = windows()
        let totalBytes = survivors.reduce(Int64(0)) { $0 + sessionBytes($1.id) }
        guard totalBytes > policy.hardCeilingBytes else { return [] }
        struct Unit { let id: String; let session: String; let device: String; let endTs: Int64?; let bytes: Int64; let file: URL? }
        var units: [Unit] = []
        for window in survivors {
            if activeIds.contains(window.id) {
                let files = segmentFiles(window.id)
                let newest = files.compactMap(segmentBucket).max()
                for url in files {
                    guard let bucket = segmentBucket(url), bucket != newest,
                          pending["\(window.id)/\(bucket)"]?.isEmpty != false else { continue }
                    let bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    units.append(Unit(id: url.path, session: window.id, device: window.deviceId,
                                      endTs: bucket + Self.segmentSeconds - 1, bytes: bytes, file: url))
                }
            } else {
                units.append(Unit(id: window.id, session: window.id, device: window.deviceId,
                                  endTs: lastSegmentEnd(window.id) ?? window.to, bytes: sessionBytes(window.id), file: nil))
            }
        }
        let chosen = Set(policy.evictionsForHardCeiling(totalBytes: totalBytes,
                                                        candidates: units.map { ($0.id, $0.endTs, $0.bytes) }))
        var evictedSessions: [String] = []
        var unuploadedBytes: Int64 = 0
        for unit in units where chosen.contains(unit.id) {
            if !isUploaded(unit.device, unit.endTs) { unuploadedBytes += unit.bytes }
            if let file = unit.file {
                deleteSegmentFile(file, sessionId: unit.session)
            } else {
                _ = deleteFiles(unit.session)
                remove(id: unit.session)
                evictedSessions.append(unit.session)
            }
        }
        if unuploadedBytes > 0 {
            let message = "IMU retention: over the \(policy.hardCeilingBytes)-byte hard ceiling (\(totalBytes) bytes); "
                + "evicted \(unuploadedBytes) bytes of raw IMU that had NOT been uploaded"
            Self.log.fault("\(message, privacy: .public)")
            onUnuploadedEviction?(message)
        }
        return evictedSessions
    }

    /// The nominal last second of a session's newest segment file (conservative: a partial file ends earlier),
    /// or nil when it has no segment files, i.e. no data.
    private func lastSegmentEnd(_ id: String) -> Int64? {
        segmentFiles(id).compactMap(segmentBucket).max().map { $0 + Self.segmentSeconds - 1 }
    }

    /// Quality notes from the most recent `readRecords(deviceId:fromTs:toTs:)` call — every
    /// conflicting-duplicate timestamp that was dropped. Cleared at the start of each read.
    public private(set) var lastReadQuality: [ImuReadQualityNote] = []

    private func readRecords(_ id: String, from: Int, to: Int, includePending: Bool) -> [Record] {
        var rows = segmentFiles(id, overlapping: Int64(from), Int64(to))
            .flatMap { decodedSegment($0) }
            .filter { $0.ts >= from && $0.ts <= to }
        if includePending { rows += pending.filter { $0.key.hasPrefix("\(id)/") }.values.flatMap { $0 }
            .filter { $0.ts >= from && $0.ts <= to } }
        return rows
    }

    private func encode(bucket: Int64, records: [Record]) -> Data {
        var result = header(bucket)
        for start in stride(from: 0, to: records.count, by: Self.blockSeconds) {
            result.append(block(Array(records[start..<min(start + Self.blockSeconds, records.count)])))
        }
        return result
    }
    private func decode(_ data: Data) -> [Record] {
        guard data.count >= 24, data.prefix(8) == Self.magic else { return [] }
        let bytes = [UInt8](data); var offset = 8
        _ = Int64(bigEndianBytes: bytes, at: offset); offset += 8
        guard int32(bytes, offset) == Self.sampleRate, int32(bytes, offset + 4) == Self.axes else { return [] }
        offset += 8; var result: [Record] = []
        while offset + 12 <= bytes.count {
            let count = int32(bytes, offset), rawSize = int32(bytes, offset + 4), compressedSize = int32(bytes, offset + 8)
            offset += 12
            guard count > 0, count <= Self.blockSeconds, rawSize > 0, compressedSize > 0,
                  offset + compressedSize <= bytes.count,
                  let raw = inflate(Data(bytes[offset..<offset + compressedSize]), size: rawSize) else { break }
            offset += compressedSize; let rawBytes = [UInt8](raw); var rawOffset = 0
            for _ in 0..<count {
                guard rawOffset + 20 + Self.payloadBytes <= rawBytes.count else { break }
                let ts = Int64(bigEndianBytes: rawBytes, at: rawOffset)
                let received = Int64(bigEndianBytes: rawBytes, at: rawOffset + 8)
                let length = int32(rawBytes, rawOffset + 16); rawOffset += 20
                guard length == Self.payloadBytes, rawOffset + length <= rawBytes.count else { break }
                var columns: [Int16] = []; columns.reserveCapacity(Self.sampleRate * Self.axes)
                for index in stride(from: rawOffset, to: rawOffset + length, by: 2) {
                    columns.append(Int16(bitPattern: UInt16(rawBytes[index]) | UInt16(rawBytes[index + 1]) << 8))
                }
                rawOffset += length; result.append(Record(ts: ts, receivedAtMs: received, columns: columns))
            }
        }
        return result
    }

    /// C8 Fix E: bounded flush cadence. Called from `append`; flushes the whole RAM tail at most
    /// every `flushCadenceMs`, so a crash loses at most ~10 s of IMU instead of up to 29 s.
    private func flushIfDue(nowMs: Int64) {
        guard nowMs - lastFlushCheckMs >= Self.flushCadenceMs, !pending.isEmpty else { return }
        lastFlushCheckMs = nowMs
        let keys = pending.keys.map { $0 }   // snapshot: flushKey mutates `pending`
        for key in keys { flushKey(key) }
    }

    /// P2-4: bounded eviction cadence, called from `append` beside the flush cadence so an
    /// always-active session still runs retention. Cheap when there is nothing to reap (a few
    /// 24-byte header reads); the 5-minute cadence keeps it out of the hot append path.
    private func evictIfDue(nowMs: Int64) {
        guard nowMs - lastEvictionCheckMs >= Self.evictionCadenceMs else { return }
        lastEvictionCheckMs = nowMs
        evictExpired()
    }

    /// P2-4: reap the ACTIVE session's expired segments (one active window can span weeks). A
    /// segment is a 30-minute bucket file; it is deleted only when it is fully expired (older than
    /// the retention floor) AND fully before the active window — the bucket currently being
    /// written — and has no still-buffered rows (a failing flush keeps the bucket, so its retry
    /// can land before any eviction). The live capture window and anything newer than the floor
    /// always survive.
    private func evictActiveSessionSegments(_ id: String, now: Int64, policy: ImuRetentionPolicy,
                                            isUploaded: (Int64) -> Bool) {
        let files = segmentFiles(id)
        guard !files.isEmpty else { return }
        // Active window = the newest bucket among durable files and the RAM pending tail (bucket
        // headers are 24 bytes to read; pending ts need no decode). Frames arrive in ts order, so
        // the newest ts is the bucket still being appended.
        var newestBucket: Int64 = 0
        for url in files {
            if let bucket = segmentBucket(url) { newestBucket = max(newestBucket, bucket) }
        }
        if let newestPendingTs = pending.filter({ $0.key.hasPrefix("\(id)/") }).values
            .flatMap({ $0 }).map(\.ts).max() {
            newestBucket = max(newestBucket, Self.bucketStart(newestPendingTs))
        }
        for url in files {
            guard let bucket = segmentBucket(url) else { continue }
            // A bucket with still-buffered rows is not fully durable — keep it for the flush retry.
            if pending["\(id)/\(bucket)"]?.isEmpty == false { continue }
            // Nominal segment end (conservative: a partial file's real end is earlier).
            let segmentEnd = bucket + Self.segmentSeconds - 1
            guard case .evict = policy.activeSessionSegmentDecision(segmentEndTs: segmentEnd,
                                                                    activeWindowStartTs: newestBucket,
                                                                    now: now),
                  isUploaded(segmentEnd) else { continue }
            deleteSegmentFile(url, sessionId: id)
        }
    }

    /// Delete one 30-minute segment file of a session, dropping its durable-dedupe cache and any
    /// still-buffered rows for that bucket (both belong to the same evicted data).
    private func deleteSegmentFile(_ url: URL, sessionId: String) {
        seen[url.path] = nil
        if let bucket = segmentBucket(url) { pending["\(sessionId)/\(bucket)"] = nil }
        segmentBuckets[url.path] = nil
        try? FileManager.default.removeItem(at: url)
    }

    private func flushSession(_ id: String) { pending.keys.filter { $0.hasPrefix("\(id)/") }.forEach(flushKey) }
    private func flushKey(_ key: String) {
        guard let records = pending.removeValue(forKey: key), !records.isEmpty,
              let tail = key.split(separator: "/").last,
              let bucket = Int64(String(tail)) else { return }
        let id = String(key.split(separator: "/")[0]), url = segmentFile(id, bucket)
        try? FileManager.default.createDirectory(at: sessionDirectory(id), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: header(bucket)) }
        guard let handle = try? FileHandle(forWritingTo: url) else { pending[key] = records; return }
        // A block never holds more than `blockSeconds` records: `decode` stops at the first one that
        // does, which would hide it and everything after it in the file. A run of failed flushes
        // leaves a backlog bigger than that, so it goes out in pieces.
        var written = 0, failed = false
        do {
            try handle.seekToEnd()
            while written < records.count {
                let end = min(written + Self.blockSeconds, records.count)
                try handle.write(contentsOf: block(Array(records[written..<end])))
                written = end
            }
            try handle.close()
        } catch {
            try? handle.close(); failed = true
        }
        // Durable now: only here do the records count as seen. What a failed write left behind stays
        // in `pending` and OUT of `seen`, so the next cadence retries it (never marked handled before
        // durable — spec §6).
        if written > 0 {
            var onDisk = seen[url.path] ?? scan(url)
            for record in records[..<written] { onDisk.insert(record.ts) }
            seen[url.path] = onDisk
        }
        if failed { pending[key] = Array(records[written...]) }
    }
    private func header(_ bucket: Int64) -> Data {
        var data = Self.magic; data.appendBigEndian(bucket); data.appendBigEndian(Int32(Self.sampleRate)); data.appendBigEndian(Int32(Self.axes)); return data
    }
    private func block(_ records: [Record]) -> Data {
        var raw = Data()
        for record in records {
            raw.appendBigEndian(record.ts); raw.appendBigEndian(record.receivedAtMs); raw.appendBigEndian(Int32(Self.payloadBytes))
            for value in record.columns { raw.append(UInt8(truncatingIfNeeded: value)); raw.append(UInt8(truncatingIfNeeded: value >> 8)) }
        }
        guard let compressed = deflate(raw) else { return Data() }
        var data = Data(); data.appendBigEndian(Int32(records.count)); data.appendBigEndian(Int32(raw.count))
        data.appendBigEndian(Int32(compressed.count)); data.append(compressed); return data
    }

    /// The decoded window list, kept with the bytes it was decoded from. `append` asks for the list on every
    /// 100 Hz frame and the Watchdog on every tick; the stored bytes are compared instead of decoded again, so a
    /// write that bypasses `save` (a test restoring the key) is still picked up.
    private var windowsCache: (data: Data, value: [Window])?
    private func windows() -> [Window] {
        guard let data = defaults.data(forKey: key) else { return [] }
        if let cached = windowsCache, cached.data == data { return cached.value }
        let value = (try? JSONDecoder().decode([Window].self, from: data)) ?? []
        windowsCache = (data, value)
        return value
    }
    private func save(_ value: [Window]) { defaults.set(try? JSONEncoder().encode(value), forKey: key) }

    /// Decoded segment files, checked against the file's size and modification date. The Watchdog reads the
    /// last half hour every 20 s, which inflated the same one or two files (about 1,800 one-second records of
    /// 600 samples) on the main actor each time; only the file still being appended to changes between reads.
    private var decodedSegments: [String: (size: Int, modified: Date, records: [Record])] = [:]
    private var decodedSegmentOrder: [String] = []
    /// Two: the Watchdog's half hour spans at most two 30-minute segments, and each holds about 2 MB decoded for
    /// as long as the app runs, in the background too.
    private static let decodedSegmentLimit = 2

    private func decodedSegment(_ url: URL) -> [Record] {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes?[.size] as? NSNumber)?.intValue,
              let modified = attributes?[.modificationDate] as? Date else {
            return decode((try? Data(contentsOf: url)) ?? Data())
        }
        if let cached = decodedSegments[url.path], cached.size == size, cached.modified == modified {
            return cached.records
        }
        let records = decode((try? Data(contentsOf: url)) ?? Data())
        decodedSegments[url.path] = (size, modified, records)
        decodedSegmentOrder.removeAll { $0 == url.path }
        decodedSegmentOrder.append(url.path)
        while decodedSegmentOrder.count > Self.decodedSegmentLimit {
            decodedSegments[decodedSegmentOrder.removeFirst()] = nil
        }
        return records
    }
    private func sessionDirectory(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }
    private func segmentFile(_ id: String, _ bucket: Int64) -> URL { sessionDirectory(id).appendingPathComponent("imu-\(Self.utcName(bucket)).imus") }
    private func segmentFiles(_ id: String) -> [URL] { ((try? FileManager.default.contentsOfDirectory(at: sessionDirectory(id), includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "imus" }.sorted { $0.lastPathComponent < $1.lastPathComponent } }
    /// The segment files of a session that can hold a second inside `[from, to]`. A file's 30-minute
    /// bucket is in its 24-byte header, so a file outside the range costs a header read instead of a
    /// decode of every record in it. These reads run on the main actor, once per upload pass, so
    /// decoding the whole store each time is what makes the app stutter after a few hours of capture.
    /// A file whose header cannot be read is kept: better a wasted decode than a lost second.
    private func segmentFiles(_ id: String, overlapping from: Int64, _ to: Int64) -> [URL] {
        segmentFiles(id).filter { url in
            guard let bucket = segmentBucket(url) else { return true }
            return bucket + Self.segmentSeconds > from && bucket <= to
        }
    }
    /// The 30-minute bucket start a segment file belongs to, read from its 24-byte NOOPIMU2 header
    /// (magic 8 + bucket 8 + rate 4 + axes 4) — a cheap constant-time probe for eviction.
    ///
    /// A segment's bucket is written once, when the file is created, so it is remembered per path: the eviction
    /// sweep (every 5 minutes, on the BLE callback) and every upload pass's overlap filter used to open and read
    /// the header of every file in the session each time, which on a phone holding a month of capture was
    /// over a thousand opens on the main thread (a 0.6 s and a 2 s hang in Sentry on 2026-10-08).
    private var segmentBuckets: [String: Int64] = [:]
    private func segmentBucket(_ url: URL) -> Int64? {
        if let known = segmentBuckets[url.path] { return known }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 16) else { return nil }
        try? handle.close()
        let bytes = [UInt8](data)
        guard bytes.count >= 16 else { return nil }
        let bucket = Int64(bigEndianBytes: bytes, at: 8)
        segmentBuckets[url.path] = bucket
        return bucket
    }
    private func sessionBytes(_ id: String) -> Int64 {
        segmentFiles(id).reduce(Int64(0)) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
    private func scan(_ url: URL) -> Set<Int64> { Set(decode((try? Data(contentsOf: url)) ?? Data()).map(\.ts)) }
    private static func bucketStart(_ ts: Int64) -> Int64 { ts >= 0 ? ts / segmentSeconds * segmentSeconds : ((ts - segmentSeconds + 1) / segmentSeconds) * segmentSeconds }
    /// One formatter for the process: `segmentFile` runs for every appended frame, and building a DateFormatter
    /// (ICU pattern + locale setup) each time is a visible cost on the main thread in Sentry's hang traces.
    private static let utcNameFormatter: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"; return f
    }()
    private static func utcName(_ ts: Int64) -> String { utcNameFormatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts))) }
    private func int32(_ bytes: [UInt8], _ offset: Int) -> Int { Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3]) }
    private func deflate(_ input: Data) -> Data? { let capacity = input.count + 128; var output = Data(count: capacity); let written = output.withUnsafeMutableBytes { dst in input.withUnsafeBytes { src in compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, capacity, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB) } }; guard written > 0 else { return nil }; output.count = written; return output }
    private func inflate(_ input: Data, size: Int) -> Data? { var output = Data(count: size); let written = output.withUnsafeMutableBytes { dst in input.withUnsafeBytes { src in compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size, src.bindMemory(to: UInt8.self).baseAddress!, input.count, nil, COMPRESSION_ZLIB) } }; return written == size ? output : nil }
}

/// C10 public read record: one raw-IMU second (600 i16 axis-major columns) as returned by
/// `ImuSessionFileStore.readRecords(deviceId:fromTs:toTs:)`.
public struct ImuStoredRecord: Equatable {
    public let ts: Int64
    public let receivedAtMs: Int64
    public let columns: [Int16]
    public init(ts: Int64, receivedAtMs: Int64, columns: [Int16]) {
        self.ts = ts; self.receivedAtMs = receivedAtMs; self.columns = columns
    }
}

/// C10 quality note for a `readRecords` call: a timestamp dropped because two records with the
/// same ts carried different columns (both dropped — never silently one).
public struct ImuReadQualityNote: Equatable {
    public let ts: Int64
    public let reason: String
    public init(ts: Int64, reason: String) {
        self.ts = ts; self.reason = reason
    }
}

private extension Int64 { init(bigEndianBytes bytes: [UInt8], at offset: Int) { self = bytes[offset..<(offset + 8)].reduce(0) { ($0 << 8) | Int64($1) } } }
private extension Data { mutating func appendBigEndian<T: FixedWidthInteger>(_ value: T) { var value = value.bigEndian; Swift.withUnsafeBytes(of: &value) { append(contentsOf: $0) } } }

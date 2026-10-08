import Foundation
import NoopPush
import WhoopProtocol
import WhoopStore

// MARK: - Feature flag

/// The default-off gate for uploading the banked v26 optical waveform with its anchor
/// (protocol 1.5 / NPB1 format 3; docs/model-integration/ppg-transport.md).
///
/// iOS has never uploaded `ppgWaveformSample`. Turning this on adds roughly 80 bytes per optical second to
/// the phone's uploads, which is an owner decision, and still sends nothing until the receiver advertises
/// 1.5 (`NOOP_PUSH_ADVERTISE_PPG_ANCHOR`). While it is off the object lane does not even offer 1.5, so it
/// negotiates and uploads exactly what it did before. The key follows the app's `noop.` preference convention.
public enum PpgObjectUploadFeature {
    /// The exact UserDefaults key: `noop.cloud.ppgAnchorUpload` (default OFF).
    public static let enabledKey = "noop.cloud.ppgAnchorUpload"

    public static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }

    /// Absent is identical to false, so turning it off removes the key.
    public static func setEnabled(_ enabled: Bool) {
        if enabled {
            UserDefaults.standard.set(true, forKey: enabledKey)
        } else {
            UserDefaults.standard.removeObject(forKey: enabledKey)
        }
    }

    /// Both gates: this phone's flag, and a receiver that negotiated 1.5 and lists the stream on its object
    /// lane. 1.4 and older have no format that carries the anchor, so they get nothing rather than deltas.
    public static func laneOpen(featureEnabled: Bool, capabilities: PushCapabilities) -> Bool {
        featureEnabled && PushProtocol.hasPPGAnchor(capabilities.protocolVersion)
            && capabilities.objectLane?.streams.contains(.ppgWaveformSample) == true
    }
}

// MARK: - Read seam

/// What the source pages through. Production reads `WhoopStore.ppgWaveformSamples`; tests supply a fake.
public protocol PpgObjectReading: Sendable {
    /// The banked rows of one local device with `fromTs <= ts <= toTs`, ascending by ts, at most `limit`:
    /// the stored deltas verbatim and the stored base code (nil on a row banked before it was read).
    func readPpgRecords(deviceId: String, fromTs: Int64, toTs: Int64, limit: Int) async throws -> [PpgWaveformSample]
}

/// The production reader over the app's own store handle. The only place the source touches `WhoopStore`.
public struct WhoopStorePpgReader: PpgObjectReading {
    private let store: @Sendable () async -> WhoopStore?

    public init(store: @escaping @Sendable () async -> WhoopStore?) {
        self.store = store
    }

    public func readPpgRecords(deviceId: String, fromTs: Int64, toTs: Int64, limit: Int) async throws -> [PpgWaveformSample] {
        // No store yet (launch, or a locked phone before first unlock): try again later, never "empty".
        guard let store = await store() else { throw PushSourceReadError.deferred }
        return try await store.ppgWaveformSamples(deviceId: deviceId, from: Int(clamping: fromTs),
                                                  to: Int(clamping: toTs), limit: limit)
    }
}

// MARK: - PushSnapshotSource for the ppgWaveformSample object lane

/// Pages anchored v26 records out of the history store for the NoopPush object lane, beside `ImuObjectSource`
/// and through the same transport, progress store and coordinator.
///
///  - One record per banked second: `rowId == ts` (the table's key is `(deviceId, ts)`), the strap's burst
///    counter, the stored `baseCode` as the anchor and the record-second clock. The store keeps neither the
///    header phase nor its flags byte, nor a record index, so those stay absent; nothing is inferred.
///  - A row without a base code is never sent: deltas alone cannot recover the level, and a row never gains
///    one later (the insert keeps the first copy of a second). It is skipped, not sent anchor-less.
///  - Pages only while the negotiated object version is 1.5, the only format that carries the anchor.
///  - Bounded: never older than `lookbackSeconds`, never at or below the durable cursor (even when the row
///    it names has been pruned and the coordinator restarts from an empty cursor), at most one hour per
///    object, and bounded reads per call. A second therefore goes up once; the receiver's content-addressed
///    object identity turns a resent identical object into a duplicate, not a second copy.
///  - `acknowledgeBinary` is a no-op: the source never deletes store data.
public final class PpgObjectSource: PushSnapshotSource, @unchecked Sendable {
    /// Target object duration. An optical hour is at most 3,600 records (~290 KB decoded), under the 5,000-record
    /// cap, and every object makes the server rebuild that day's inputs, so slivers are avoided.
    public static let targetObjectWindowSeconds: Int64 = 3_600
    /// v26 rows arrive with the history offload after the strap reconnects, not live. An hour with no newer row
    /// yet goes out only once the phone clock is this far past its end.
    static let settleSeconds: Int64 = 900
    /// Rows past the later of the phone clock and the cursor are not looked for beyond this (a strap clock ahead).
    static let futureSlackSeconds: Int64 = 1_800
    /// Rows per read while looking for the next anchored row, and reads per call. Anchor-less legacy rows are
    /// skipped in these bounded steps, and where the skip stopped is remembered in memory.
    static let scanChunkRows = 2_000
    static let maxScanChunksPerCall = 8
    /// The remembered skip position trails the phone clock by this much, as `ImuObjectSource`'s does.
    static let frontierLagSeconds: Int64 = 1_200

    /// Set by the app layer to its single store handle. Nil means no PPG history is reachable: nothing uploads.
    public static var historyStore: (@Sendable () async -> WhoopStore?)?

    private let store: any PpgObjectReading
    private let deviceIdProvider: @Sendable () -> String?
    private let storeDeviceId: @Sendable (String) -> String
    private let now: @Sendable () -> Int64
    private let lookbackSeconds: Int64
    /// The durable cursor's second for a cloud device id (the progress store), read on every page.
    private let sentThrough: @Sendable (String) async throws -> Int64?
    private let uploadAllowed: @Sendable () -> Bool

    private let lock = NSLock()
    private var scanFrontiers: [String: Int64] = [:]

    public init(store: any PpgObjectReading,
                deviceId: @escaping @Sendable () -> String?,
                storeDeviceId: @escaping @Sendable (String) -> String = { $0 },
                now: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
                lookbackSeconds: Int64 = 14 * 24 * 3600,
                sentThrough: @escaping @Sendable (String) async throws -> Int64? = { _ in nil },
                uploadAllowed: @escaping @Sendable () -> Bool = { true }) {
        self.store = store
        self.deviceIdProvider = deviceId
        self.storeDeviceId = storeDeviceId
        self.now = now
        self.lookbackSeconds = lookbackSeconds
        self.sentThrough = sentThrough
        self.uploadAllowed = uploadAllowed
    }

    /// The format 3 record for one banked row, or nil when the row cannot be sent as anchored: no base code,
    /// a base or burst outside its wire width, or deltas that are not the i16 values the strap sent.
    /// The deltas are packed back exactly as the store packed them; nothing is filled in.
    static func anchoredRecord(_ sample: PpgWaveformSample) -> PushPpgWaveformRecord? {
        guard let base = sample.baseCode, let anchor = UInt32(exactly: base), sample.ts > 0,
              !sample.samples.isEmpty, sample.samples.allSatisfy({ Int16(exactly: $0) != nil }) else { return nil }
        var burst: Int32?
        if let raw = sample.burstIndex {
            guard let value = Int32(exactly: raw) else { return nil }
            burst = value
        }
        var data = Data(capacity: sample.samples.count * 2)
        for value in sample.samples {
            let bits = UInt16(bitPattern: Int16(value))
            data.append(UInt8(bits & 0xFF))
            data.append(UInt8(bits >> 8))
        }
        let ts = Int64(sample.ts)
        return PushPpgWaveformRecord(rowId: ts, ts: ts, burstIndex: burst, samples: data,
                                     anchor: anchor, clockSource: .strapRecordSecond)
    }

    /// The active strap's local id and the cloud id its rows go out under (`CloudStrapSerialStore`, the mapping
    /// the raw-IMU lane uses). Only the active strap, and none once a different strap has taken its slot: the
    /// rows banked under that id before the swap belong to the earlier strap and carry no strap identity of
    /// their own, so they are withheld rather than filed under the new one.
    static func laneDevices(store: WhoopStore) -> [(localId: String, cloudId: String)] {
        guard let local = try? DeviceRegistryStore(dbQueue: store.registryWriter).activeDeviceId(),
              !CloudStrapSerialStore.shared.hasReplacedStrap(forLocalId: local) else { return [] }
        return [(localId: local, cloudId: CloudStrapSerialStore.shared.cloudId(forLocalId: local))]
    }

    // MARK: PushSnapshotSource

    public func knownDeviceIds(capabilities: PushCapabilities) async throws -> [String] {
        deviceIdProvider().map { [$0] } ?? []
    }

    public func binaryPage(table: PushBinaryTable, deviceId: String, afterRowId: Int64,
                           limit: Int, limits: PushSourceReadLimits) async throws -> PushBinaryPage {
        let empty = PushBinaryPage(rows: [], hasMore: false)
        guard table == .ppgWaveformSample, PushProtocol.hasPPGAnchor(limits.protocolVersion),
              uploadAllowed() else { return empty }
        guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
        let local = storeDeviceId(deviceId)
        let present = now()
        var floor = max(afterRowId, present - lookbackSeconds)
        if let sent = try await sentThrough(deviceId) { floor = max(floor, sent) }
        let reach = max(present, floor) + Self.futureSlackSeconds
        guard let first = try await firstAnchoredSecond(local: local, deviceId: deviceId, after: floor,
                                                         reach: reach, present: present, limits: limits)
        else { return empty }

        let windowEnd = first + Self.targetObjectWindowSeconds
        let window = try await store.readPpgRecords(deviceId: local, fromTs: first, toTs: windowEnd - 1,
                                                    limit: PushProtocolLimits.maxRecords)
        var selected: [PushBinaryRow] = []
        var bytes = PushBinaryCodec.packedHeaderSize(for: .ppgWaveformSample)
        var truncated = false
        var lastTs = floor
        for sample in window {
            guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
            // Strictly ascending and above the floor: a defensive reader can never make a second go up twice.
            guard let record = Self.anchoredRecord(sample), record.ts > lastTs else { continue }
            guard selected.count < limit else { truncated = true; break }
            let row = PushBinaryRow.ppgWaveform(record)
            let rowBytes = try PushBinaryCodec.packedRowSize(row, ppgIdentityV2: true, ppgAnchorV3: true)
            guard rowBytes <= limits.maximumDecodedBytes - bytes else { truncated = true; break }
            bytes += rowBytes
            selected.append(row)
            lastTs = record.ts
        }
        guard !selected.isEmpty else { throw PushSourceReadError.requiresCompatibleEncoding }
        let newer = truncated ? [] : try await store.readPpgRecords(deviceId: local, fromTs: windowEnd,
                                                                    toTs: max(windowEnd, reach), limit: 1)
        let hasMore = truncated || !newer.isEmpty
        // Still filling: the offload may not have delivered the rest of this hour yet.
        if !hasMore, present < windowEnd + Self.settleSeconds { return empty }
        return .init(rows: selected, hasMore: hasMore)
    }

    public func binaryRecordAt(table: PushBinaryTable, deviceId: String, rowId: Int64) async throws -> PushBinaryRow? {
        guard table == .ppgWaveformSample else { return nil }
        let rows = try await store.readPpgRecords(deviceId: storeDeviceId(deviceId), fromTs: rowId, toTs: rowId, limit: 1)
        guard let sample = rows.first(where: { Int64($0.ts) == rowId }),
              let record = Self.anchoredRecord(sample) else { return nil }
        return .ppgWaveform(record)
    }

    /// The legacy fallback carries no negotiated version, and only 1.5 carries the anchor: it gets nothing.
    public func binaryRows(table: PushBinaryTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushBinaryRow] {
        []
    }

    public func acknowledgeBinary(table: PushBinaryTable, deviceId: String, rows: [PushBinaryRow]) async throws {}

    public func appendRecordAt(table: PushAppendTable, deviceId: String, rowId: Int64) async throws -> PushAppendRecord? { nil }
    public func appendRows(table: PushAppendTable, deviceId: String, afterRowId: Int64, limit: Int) async throws -> [PushAppendRecord] { [] }
    public func mutableRows(table: PushMutableTable, deviceId: String, window: PushWindow, limit: Int) async throws -> [PushMutableRecord] { [] }

    // MARK: - Paging

    /// The first second above `floor` that can be sent anchored, or nil. Anchor-less rows in between are read in
    /// bounded chunks; where a run of them ends is remembered (trailing the clock) so the next call resumes there.
    private func firstAnchoredSecond(local: String, deviceId: String, after floor: Int64, reach: Int64,
                                     present: Int64, limits: PushSourceReadLimits) async throws -> Int64? {
        var from = floor + 1
        lock.lock()
        if let remembered = scanFrontiers[deviceId], remembered > from { from = remembered }
        lock.unlock()
        for _ in 0..<Self.maxScanChunksPerCall {
            guard from <= reach else { break }
            guard limits.shouldContinue() else { throw PushSourceReadError.deferred }
            let chunk = try await store.readPpgRecords(deviceId: local, fromTs: from, toTs: reach, limit: Self.scanChunkRows)
            if let hit = chunk.first(where: { Self.anchoredRecord($0) != nil }) { return Int64(hit.ts) }
            guard let last = chunk.last else { break }
            from = Int64(last.ts) + 1
            let remembered = min(from, present - Self.frontierLagSeconds)
            lock.lock()
            if remembered > floor + 1 { scanFrontiers[deviceId] = remembered }
            lock.unlock()
        }
        return nil
    }
}

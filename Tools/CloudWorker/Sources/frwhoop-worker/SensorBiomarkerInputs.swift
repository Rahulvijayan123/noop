import Foundation
import CZstd
import WhoopProtocol

/// W1: the typed raw-input layer for the sensor-biomarker lane
/// (docs/sensor-biomarkers/CONTRACTS.md §4–5, spec-31 §3/§5).
///
/// The lane reads a (user, device, UTC day), resolves the VERIFIED raw input
/// objects (`object_manifests` rows whose `durability_receipt->>'state'` is
/// `verified_indexed` and `status` is `ready`, exactly like `ActivityLane`),
/// decompresses each object, verifies the DECODED sha256 against the manifest
/// digest BEFORE anything is decoded, and produces typed physical inputs:
///
///   - NPB1 `rawImuSession` objects (zstd)  → 100 Hz six-axis IMU in g and
///     deg/s with absolute timestamps `ts + i/100`;
///   - NPB1 `ppgWaveformSample` objects (gzip) → per-second v26 windows of 24
///     signed i16 deltas, with the absolute optical anchor when the object is
///     NPB1 format 3 (push protocol 1.5; formats 1 and 2 never carried it).
///
/// PPG reconstruction is explicit: absolute = baseCode + cumulative deltas,
/// via the shared `WhoopProtocol.ppgWaveformAbsolute`, ONLY when the anchor is
/// present. A record without an anchor is a WITHHELD second
/// (`missing_ppg_anchor`) and is never sent as amplitudes. Reconstructed
/// windows saturate or leave the signed 20-bit optical domain and are withheld
/// (`saturated_delta`); a record whose delta count is not 24 is withheld
/// (`unsupported_native_rate`) and the DETECTED rate is reported, never
/// assumed; empty slots and dark blocks (drive == 0 when an optical config is
/// carried) are withheld (`artifact_unavailable`). Emitted seconds use the one
/// grid `ppgGrid` names (docs/model-integration/ppg-transport.md).
///
/// This module also builds the sidecar request input (CONTRACTS §4): for a
/// given run set it produces time-ordered, non-overlapping, endpoint-owned
/// segments (<= 5-minute chunks) that carry their run, configuration and clock
/// identity, the `input_revision` (sha256 over the sorted verified object
/// digests in a documented canonical string form), the families whose input a
/// request actually carries, its measured input coverage and recorded
/// placement, and the measured serialized size (every request is kept under
/// the sidecar `MAX_BODY_BYTES`, 8 MiB).
///
/// Everything here is pure and unit-testable: the lane owns the DB query, B2
/// download and the sidecar HTTP call, and feeds this module its inputs.
enum SensorBiomarkerInputs {

    // MARK: - Constants

    /// The sensor-biomarker analysis revision (CONTRACTS §1/§3).
    static let analysisVersion = "sensor-biomarkers/1.0.0"
    /// NPB1 rawImuSession native rate: 100 samples per 1-second record.
    static let imuNativeRateHz = 100
    /// Accelerometer scale, g per i16 LSB (Whoop5RawImu / the golden fixtures
    /// `golden_imu_expected.json`: 1/4096).
    static let accelScale = 1.0 / 4096.0
    /// Gyroscope scale, deg/s per i16 LSB (Whoop5RawImu: 2000/32768).
    static let gyroScale = 2000.0 / 32768.0
    /// A v26 record carries exactly 24 signed i16 deltas plus one absolute anchor.
    static let ppgDeltasPerRecord = 24
    /// Signed 20-bit optical ADC rails (Whoop5RawOptical.sampleMin/sampleMax).
    static let opticalSampleMin = -524_288    // -2^19
    static let opticalSampleMax = 524_287     // 2^19 - 1
    /// Sidecar `MAX_BODY_BYTES` (CONTRACTS §4).
    static let maxBodyBytes = 8 * 1024 * 1024
    /// The module packs requests below this budget so the request plus its
    /// envelope never threatens the 8 MiB cap.
    static let bodyBudgetBytes = 7_500_000
    /// Segment cap: CONTRACTS §4 "<= 5-minute chunks".
    static let maxSegmentDurationSeconds = 300

    // MARK: - Withheld reasons (CONTRACTS §3 vocabulary)

    static let reasonMissingPpgAnchor = "missing_ppg_anchor"
    static let reasonUnsupportedNativeRate = "unsupported_native_rate"
    static let reasonSaturatedDelta = "saturated_delta"
    static let reasonArtifactUnavailable = "artifact_unavailable"

    // MARK: - Object kinds

    static let kindRawImuSession = "rawImuSession"
    static let kindPpgWaveformSample = "ppgWaveformSample"
    static let supportedKinds: [String] = [kindRawImuSession, kindPpgWaveformSample]

    /// The device-day object-resolution SQL. Parameters ($1..$5):
    ///   $1 user uuid, $2 device uuid, $3 object kinds as a text[] literal,
    ///   $4 day-end ISO (exclusive upper bound), $5 day-start ISO (inclusive lower bound).
    /// The gates are byte-for-byte the ActivityLane resolution semantics: the
    /// same `object_manifests` table, `status = 'ready'` and
    /// `durability_receipt->>'state' = 'verified_indexed'`; objects overlap the
    /// UTC day when `start_at < dayEnd AND end_at > dayStart`.
    static let objectResolutionSQL = """
        select m.id::text as id,
               m.object_key as object_key,
               m.object_kind as object_kind,
               m.status as status,
               m.durability_receipt->>'state' as receipt_state,
               m.sha256 as sha256,
               m.user_id::text as user_id,
               m.device_id::text as device_id,
               extract(epoch from m.start_at)::bigint as start_ts,
               extract(epoch from m.end_at)::bigint as end_ts,
               m.push_protocol_version as push_protocol_version,
               m.schema_version::text as schema_version
          from public.object_manifests m
         where m.user_id = $1::uuid
           and m.device_id = $2::uuid
           and m.object_kind = any($3::text[])
           and m.status = 'ready'
           and m.durability_receipt->>'state' = 'verified_indexed'
           and m.start_at < $4::timestamptz
           and m.end_at > $5::timestamptz
         order by m.object_kind, m.start_at, m.id
        """

    // MARK: - Resolved objects

    /// One verified raw input object for the sensor-biomarker lane.
    struct InputObject: Equatable, Hashable {
        let id: String
        let objectKind: String
        let objectKey: String
        /// Decoded-content sha256 (lowercase 64-hex) from the manifest. For
        /// binary objects the digest scope is `decoded` (the direct lane's
        /// contentSha256); the worker verifies `sha256Hex(decompressed)` against it
        /// before any decode.
        let digest: String
        let startTs: Int64?
        let endTs: Int64?
        /// The push protocol and stream schema the receiver recorded for the object (provenance, and
        /// the PPG format the bytes must decode as). nil on rows predating those columns.
        var protocolVersion: String? = nil
        var schemaVersion: Int? = nil
    }

    /// The verified objects of a (user, device, UTC day), partitioned by kind
    /// and deterministically ordered.
    struct ResolvedObjects: Equatable {
        let userId: String
        let deviceId: String
        let day: String
        let imu: [InputObject]
        let ppg: [InputObject]

        var all: [InputObject] { imu + ppg }
        var isEmpty: Bool { imu.isEmpty && ppg.isEmpty }
    }

    enum ResolutionError: Error, Equatable, CustomStringConvertible {
        case missingField(String)
        case unknownKind(String)
        case notReady(String)
        case notVerifiedIndexed(String)
        case missingDigest(String)
        case mixedOwner(String)
        case mixedDevice(String)

        var description: String {
            switch self {
            case .missingField(let f): return "object row missing \(f)"
            case .unknownKind(let k): return "unsupported object kind \(k)"
            case .notReady(let id): return "object \(id) not status=ready"
            case .notVerifiedIndexed(let id): return "object \(id) not verified_indexed"
            case .missingDigest(let id): return "object \(id) missing decoded digest"
            case .mixedOwner(let id): return "object \(id) belongs to another owner"
            case .mixedDevice(let id): return "object \(id) belongs to another device"
            }
        }
    }

    /// The `$3::text[]` parameter for `objectResolutionSQL`, built from the
    /// supported kinds.
    static func objectKindsParam(_ kinds: [String] = supportedKinds) -> String {
        "{" + kinds.map { "\"\($0)\"" }.joined(separator: ",") + "}"
    }

    /// The `$1..$5` parameters for `objectResolutionSQL`. Returns nil for a
    /// malformed day (the lane then settles the job deterministically).
    static func objectResolutionParams(userId: String, deviceId: String, day: String,
                                       kinds: [String] = supportedKinds) -> [String]? {
        guard let bounds = ActivityLane.utcDayBounds(day) else { return nil }
        return [userId, deviceId, objectKindsParam(kinds),
                ActivityLane.isoUTC(bounds.end), ActivityLane.isoUTC(bounds.start)]
    }

    private static func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.allSatisfy { $0.isHexDigit }
    }

    /// Pure: `object_manifests` query rows (as `PostgresClient.query` returns
    /// them) → typed inputs. Rejects mixed-owner and mixed-device rows and any
    /// row that is not verified/ready, so a bad row can never become data.
    static func parseObjectRows(_ rows: [[String: String]], userId: String, deviceId: String)
        throws -> ResolvedObjects {
        var imu: [InputObject] = []
        var ppg: [InputObject] = []
        for row in rows {
            guard let rowUser = row["user_id"], !rowUser.isEmpty else {
                throw ResolutionError.missingField("user_id")
            }
            guard let rowDevice = row["device_id"], !rowDevice.isEmpty else {
                throw ResolutionError.missingField("device_id")
            }
            guard rowUser == userId else {
                throw ResolutionError.mixedOwner(row["id"] ?? "?")
            }
            guard rowDevice == deviceId else {
                throw ResolutionError.mixedDevice(row["id"] ?? "?")
            }
            guard let id = row["id"], !id.isEmpty else {
                throw ResolutionError.missingField("id")
            }
            guard let kind = row["object_kind"], !kind.isEmpty else {
                throw ResolutionError.missingField("object_kind")
            }
            guard supportedKinds.contains(kind) else {
                throw ResolutionError.unknownKind(kind)
            }
            guard let key = row["object_key"], !key.isEmpty else {
                throw ResolutionError.missingField("object_key")
            }
            guard row["status"] == "ready" else {
                throw ResolutionError.notReady(id)
            }
            guard row["receipt_state"] == "verified_indexed" else {
                throw ResolutionError.notVerifiedIndexed(id)
            }
            guard let digest = row["sha256"], isHex64(digest) else {
                throw ResolutionError.missingDigest(id)
            }
            let startTs = Int64(row["start_ts"] ?? "")
            let endTs = Int64(row["end_ts"] ?? "")
            let object = InputObject(id: id, objectKind: kind, objectKey: key,
                                     digest: digest, startTs: startTs, endTs: endTs,
                                     protocolVersion: row["push_protocol_version"].flatMap { $0.isEmpty ? nil : $0 },
                                     schemaVersion: Int(row["schema_version"] ?? ""))
            if kind == kindRawImuSession { imu.append(object) } else { ppg.append(object) }
        }
        imu.sort { ($0.startTs ?? Int64.max, $0.id) < ($1.startTs ?? Int64.max, $1.id) }
        ppg.sort { ($0.startTs ?? Int64.max, $0.id) < ($1.startTs ?? Int64.max, $1.id) }
        return ResolvedObjects(userId: userId, deviceId: deviceId, day: "", imu: imu, ppg: ppg)
    }

    // MARK: - Verified object loading

    enum LoadError: Error, Equatable, CustomStringConvertible {
        case unsupportedKind(String)
        case digestMismatch(objectId: String, expected: String, actual: String)
        case decodeFailure(objectId: String, kind: String, detail: String)
        case formatMismatch(objectId: String, schema: Int, format: UInt8)

        var description: String {
            switch self {
            case .unsupportedKind(let k): return "unsupported object kind \(k)"
            case .digestMismatch(let id, let e, let a):
                return "digest_mismatch: object \(id) expected \(e) got \(a)"
            case .decodeFailure(let id, let k, let d):
                return "decode_failure: object \(id) (\(k)): \(d)"
            case .formatMismatch(let id, let schema, let format):
                return "format_mismatch: object \(id) schema \(schema) carries NPB1 format \(format)"
            }
        }
    }

    /// Decompress + digest-verify one downloaded object (the ActivityLane
    /// pattern: zstd for rawImuSession, gzip for ppgWaveformSample). A failed
    /// digest never becomes data.
    static func verifiedDecodedData(wire: Data, object: InputObject) throws -> Data {
        let decoded: Data
        switch object.objectKind {
        case kindRawImuSession:
            decoded = try VerificationLane.zstdDecompress(wire)
        case kindPpgWaveformSample:
            decoded = try Inflator.gunzip(wire)
        default:
            throw LoadError.unsupportedKind(object.objectKind)
        }
        let actual = sha256Hex(decoded)
        guard actual == object.digest else {
            throw LoadError.digestMismatch(objectId: object.id, expected: object.digest, actual: actual)
        }
        return decoded
    }

    /// Verify + decode one rawImuSession object into NPB1 records.
    static func decodeImuObject(wire: Data, object: InputObject) throws -> [Npb1ImuDecoder.Record] {
        let decoded = try verifiedDecodedData(wire: wire, object: object)
        do {
            return try Npb1ImuDecoder.decode(decoded)
        } catch {
            throw LoadError.decodeFailure(objectId: object.id, kind: object.objectKind, detail: "\(error)")
        }
    }

    /// Verify + decode one ppgWaveformSample object into per-second PPG records. The NPB1 format must
    /// be the one the receiver's recorded schema names (schema 1/2/3 = format 1/2/3), so bytes can
    /// never be read under a contract they were not admitted with.
    static func decodePpgObject(wire: Data, object: InputObject) throws -> [PpgCodec.Record] {
        let decoded = try verifiedDecodedData(wire: wire, object: object)
        let records: [PpgCodec.Record]
        do {
            records = try PpgCodec.unpack(decoded)
        } catch {
            throw LoadError.decodeFailure(objectId: object.id, kind: object.objectKind, detail: "\(error)")
        }
        if let schema = object.schemaVersion, let format = records.first?.format, Int(format) != schema {
            throw LoadError.formatMismatch(objectId: object.id, schema: schema, format: format)
        }
        return records
    }

    /// `input_revision` (CONTRACTS §4): `sha256:` over the SORTED verified
    /// object digests. Canonical string form (documented, pinned by tests):
    /// the digests (lowercase 64-hex, the decoded-content sha256) sorted
    /// lexicographically and joined by a single `\n`, hashed as UTF-8 bytes.
    /// This is the same "sorted object digests" input the DB fingerprint
    /// function folds (CONTRACTS §5), minus the UTC-range and analysis-version
    /// members the lane adds.
    static func inputRevision(objects: [InputObject]) -> String {
        let canonical = objects.map { $0.digest }.sorted().joined(separator: "\n")
        return "sha256:" + sha256Hex(Data(canonical.utf8))
    }

    // MARK: - IMU decode (physical samples)

    /// One physical 100 Hz IMU sample with its absolute wall-clock timestamp.
    struct ImuSample: Equatable {
        let t: Double
        let ax, ay, az: Double   // g
        let gx, gy, gz: Double   // deg/s
    }

    /// Convert one NPB1 record's 600 i16 axis-major columns to 100 physical
    /// samples. Sample i sits at `ts + i/100` (resample-invariant baseTs
    /// semantics, pinned by the golden fixtures) and the physical scales are
    /// the decoder's own: accel 1/4096 g/LSB, gyro 2000/32768 (deg/s)/LSB.
    static func imuSamples(record: Npb1ImuDecoder.Record) -> [ImuSample] {
        let c = record.columns
        var out: [ImuSample] = []
        out.reserveCapacity(imuNativeRateHz)
        for i in 0..<imuNativeRateHz {
            out.append(ImuSample(
                t: Double(record.ts) + Double(i) / Double(imuNativeRateHz),
                ax: Double(c[i]) * accelScale,
                ay: Double(c[imuNativeRateHz + i]) * accelScale,
                az: Double(c[2 * imuNativeRateHz + i]) * accelScale,
                gx: Double(c[3 * imuNativeRateHz + i]) * gyroScale,
                gy: Double(c[4 * imuNativeRateHz + i]) * gyroScale,
                gz: Double(c[5 * imuNativeRateHz + i]) * gyroScale))
        }
        return out
    }

    /// Merged per-second IMU timeline with the ActivityLane semantics exactly:
    /// identical duplicate seconds collapse, a conflicting duplicate second is a
    /// deterministic error, and gaps/clock resets are never filled.
    static func imuTimeline(_ records: [Npb1ImuDecoder.Record]) throws -> ActivityLane.ImuTimeline {
        try ActivityLane.buildTimeline(records: records)
    }

    /// Contiguous IMU runs over existing seconds (ActivityLane.splitRuns): a
    /// run breaks at a >1 s gap or a clock reset. Never fills.
    static func imuRuns(_ timeline: ActivityLane.ImuTimeline) -> [ActivityLane.Run] {
        ActivityLane.splitRuns(seconds: timeline.seconds)
    }

    // MARK: - IMU segments

    /// One endpoint-owned IMU segment (CONTRACTS §4): `accelG`/`gyroDps` hold
    /// `durationS * 100` three-value samples; sample i is at
    /// `startUnix + i/100`. Consecutive segments share no endpoint sample.
    struct ImuSegment: Equatable {
        let startUnix: Int64
        let durationS: Int
        let accelG: [[Double]]
        let gyroDps: [[Double]]
    }

    /// Split an IMU run into non-overlapping segments of at most `maxDuration`
    /// seconds at whole-second boundaries. Each segment owns exactly the
    /// samples in `[start, end)`; no sample belongs to two segments.
    static func imuSegments(run: ActivityLane.Run,
                            timeline: ActivityLane.ImuTimeline,
                            maxDuration: Int = maxSegmentDurationSeconds) -> [ImuSegment] {
        guard maxDuration > 0 else { return [] }
        var segments: [ImuSegment] = []
        var chunkStart = run.start
        while chunkStart < run.end {
            let chunkEnd = segmentEnd(start: chunkStart, maxDuration: maxDuration, runEnd: run.end)
            segments.append(imuSegment(from: chunkStart, to: chunkEnd, timeline: timeline))
            chunkStart = chunkEnd
        }
        return segments
    }

    /// Segment (and therefore request) seams inside a run fall on UTC multiples of this many
    /// seconds, a common multiple of the 5 s movement epoch and the 4 s oscillation window, so no
    /// analysis window ever straddles two sidecar requests.
    static let seamAlignmentSeconds: Int64 = 20

    static func segmentEnd(start: Int64, maxDuration: Int, runEnd: Int64) -> Int64 {
        let limit = start + Int64(maxDuration)
        let aligned = limit - ((limit % seamAlignmentSeconds) + seamAlignmentSeconds) % seamAlignmentSeconds
        return min(aligned > start ? aligned : limit, runEnd)
    }

    /// Runs clipped to `[from, to)`; the lane feeds the sidecar one UTC hour at a time so a full
    /// day's decoded samples are never resident at once.
    static func clip(_ runs: [ActivityLane.Run], from: Int64, to: Int64) -> [ActivityLane.Run] {
        runs.compactMap { run in
            let start = max(run.start, from), end = min(run.end, to)
            return start < end ? ActivityLane.Run(start: start, end: end) : nil
        }
    }

    /// Clipped pieces keep the run's id, configuration and clock: a run split across requests is
    /// still one run.
    static func clip(_ runs: [PpgRun], from: Int64, to: Int64) -> [PpgRun] {
        runs.compactMap { run in
            let start = max(run.start, from), end = min(run.end, to)
            return start < end ? PpgRun(start: start, end: end, runId: run.runId, config: run.config,
                                        clock: run.clock) : nil
        }
    }

    private static func imuSegment(from start: Int64, to end: Int64,
                                   timeline: ActivityLane.ImuTimeline) -> ImuSegment {
        var accel: [[Double]] = []
        var gyro: [[Double]] = []
        let count = Int(end - start) * imuNativeRateHz
        accel.reserveCapacity(count)
        gyro.reserveCapacity(count)
        if let startIndex = ActivityLane.lowerBound(timeline.seconds, start) {
            var index = startIndex
            var t = start
            while t < end {
                if index < timeline.seconds.count, timeline.seconds[index] == t {
                    let base = timeline.columnOffset(index: index)
                    let c = timeline.columns
                    for i in 0..<imuNativeRateHz {
                        accel.append([Double(c[base + i]) * accelScale,
                                      Double(c[base + imuNativeRateHz + i]) * accelScale,
                                      Double(c[base + 2 * imuNativeRateHz + i]) * accelScale])
                        gyro.append([Double(c[base + 3 * imuNativeRateHz + i]) * gyroScale,
                                     Double(c[base + 4 * imuNativeRateHz + i]) * gyroScale,
                                     Double(c[base + 5 * imuNativeRateHz + i]) * gyroScale])
                    }
                    index += 1
                }
                t += 1
            }
        }
        return ImuSegment(startUnix: start, durationS: Int(end - start), accelG: accel, gyroDps: gyro)
    }

    // MARK: - PPG wire codec (kind 1)

    /// What a record's `ts` was taken from (NPB1 format 3 `clockSource`). Formats 1 and 2 carry no
    /// clock member and decode as `.unknown`; nothing infers a source for them.
    enum PpgClockSource: UInt8, Equatable, Hashable {
        case unknown = 0
        /// The strap's per-record unix second from the type-47 header, as the phone banked it.
        case strapRecordSecond = 1

        var wireName: String { self == .strapRecordSecond ? "strap_record_second" : "unknown" }
    }

    /// One decoded per-second PPG record from an NPB1 `ppgWaveformSample` object. CloudWorker cannot
    /// import NoopPush, so the layout is re-implemented here (like `Npb1ImuDecoder` for IMU) and pinned
    /// against the shared golden `Packages/NoopPush/Tests/NoopPushTests/Resources/ppg_anchor_v3_golden.json`:
    ///   magic "NPB1" (4 B) | formatVersion 1|2|3 (1 B) | kind 1 (1 B) | u32 count (4 B)
    ///   per record: i64 rowId | i64 ts | [format >= 2: u8 hasIndex + i64 recordIndex]
    ///   | u8 hasBurst + i32 burstIndex
    ///   | [format 3: u8 hasAnchor + u32 anchor | u8 clockSource | u8 hasSubsec + u16 subsecQ15
    ///      | u8 hasFlags + u8 frontEndFlags | u8 sampleFlags]
    ///   | u32 blob length | the blob (24 little-endian i16 deltas for a v26 window).
    /// Formats 1 and 2 never carried the phone's `baseCode`, so their records decode with
    /// `anchor == nil` and are withheld `missing_ppg_anchor`. Format 3 (push protocol 1.5) carries it.
    struct PpgCodec {
        struct Record: Equatable {
            let rowId: Int64
            let ts: Int64
            let recordIndex: Int64?
            let burstIndex: Int32?
            let samples: [Int16]
            /// The NPB1 format the record arrived in.
            let format: UInt8
            let anchor: UInt32?
            let clockSource: PpgClockSource
            let subsecQ15: UInt16?
            let frontEndFlags: UInt8?
            /// Format 3's encoder flag, verified against the deltas on decode.
            let deltaAtRail: Bool

            init(rowId: Int64, ts: Int64, recordIndex: Int64? = nil, burstIndex: Int32? = nil,
                 samples: [Int16], format: UInt8 = 1, anchor: UInt32? = nil,
                 clockSource: PpgClockSource = .unknown, subsecQ15: UInt16? = nil,
                 frontEndFlags: UInt8? = nil, deltaAtRail: Bool = false) {
                self.rowId = rowId
                self.ts = ts
                self.recordIndex = recordIndex
                self.burstIndex = burstIndex
                self.samples = samples
                self.format = format
                self.anchor = anchor
                self.clockSource = clockSource
                self.subsecQ15 = subsecQ15
                self.frontEndFlags = frontEndFlags
                self.deltaAtRail = deltaAtRail
            }
        }

        enum CodecError: Error, Equatable, CustomStringConvertible {
            case notNpb1
            case unsupportedVersion(UInt8)
            case unsupportedKind(UInt8)
            case emptyObject
            case invalidCount(Int)
            case invalidRow(Int, String)
            case truncated(String)
            case trailingBytes(Int)

            var description: String {
                switch self {
                case .notNpb1: return "PPG object magic mismatch"
                case .unsupportedVersion(let v): return "unsupported PPG formatVersion \(v)"
                case .unsupportedKind(let k): return "unsupported PPG kind \(k) (expected 1)"
                case .emptyObject: return "PPG object contains no records"
                case .invalidCount(let n): return "invalid PPG record count \(n)"
                case .invalidRow(let i, let d): return "invalid PPG record \(i): \(d)"
                case .truncated(let d): return "truncated PPG object: \(d)"
                case .trailingBytes(let n): return "PPG object has \(n) trailing bytes"
                }
            }
        }

        static let magicBytes: [UInt8] = [0x4E, 0x50, 0x42, 0x31]  // "NPB1"
        static let kindPpgWaveform: UInt8 = 1
        static let headerBytes = 10   // magic 4 + version 1 + kind 1 + count 4
        static let anchorFormat: UInt8 = 3

        /// Bit 0 of format 3 `sampleFlags`: a delta at an i16 rail (NoopPush `ppgSampleFlags`).
        static func deltaAtRail(_ samples: [Int16]) -> Bool {
            samples.contains { $0 == Int16.max || $0 == Int16.min }
        }

        static func unpack(_ data: Data) throws -> [Record] {
            let bytes = [UInt8](data)
            var offset = 0
            func take(_ count: Int) throws -> ArraySlice<UInt8> {
                guard count >= 0, count <= bytes.count - offset else {
                    throw CodecError.truncated("need \(count) bytes at offset \(offset), have \(bytes.count - offset)")
                }
                defer { offset += count }
                return bytes[offset..<(offset + count)]
            }
            func integer(_ width: Int) throws -> UInt64 {
                try take(width).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
            }
            func int64() throws -> Int64 {
                Int64(bitPattern: try integer(8))
            }
            func presence(_ row: Int, _ what: String) throws -> Bool {
                let value = try integer(1)
                guard value <= 1 else { throw CodecError.invalidRow(row, "invalid \(what) presence byte") }
                return value == 1
            }

            guard Array(try take(4)) == magicBytes else { throw CodecError.notNpb1 }
            let version = try take(1).first ?? 0
            let kind = try take(1).first ?? 0
            guard (1...anchorFormat).contains(version) else { throw CodecError.unsupportedVersion(version) }
            guard kind == kindPpgWaveform else { throw CodecError.unsupportedKind(kind) }
            let count = Int(try integer(4))
            guard count > 0 else { throw CodecError.emptyObject }
            guard count <= 200_000 else { throw CodecError.invalidCount(count) }

            var records: [Record] = []
            records.reserveCapacity(count)
            for i in 0..<count {
                let rowId = try int64()
                let ts = try int64()
                var recordIndex: Int64? = nil
                if version >= 2, try presence(i, "recordIndex") {
                    let value = try int64()
                    guard value >= 0, value <= Int64(UInt32.max) else {
                        throw CodecError.invalidRow(i, "recordIndex out of range")
                    }
                    recordIndex = value
                }
                let hasBurst = try integer(1)
                guard rowId > 0, hasBurst <= 1 else {
                    throw CodecError.invalidRow(i, "rowId must be positive and burst presence byte valid")
                }
                let burstIndex: Int32? = hasBurst == 1
                    ? Int32(bitPattern: UInt32(truncatingIfNeeded: try integer(4)))
                    : nil
                var anchor: UInt32? = nil, clock = PpgClockSource.unknown
                var subsec: UInt16? = nil, frontEnd: UInt8? = nil, sampleFlags: UInt64 = 0
                if version == anchorFormat {
                    if try presence(i, "anchor") { anchor = UInt32(try integer(4)) }
                    let source = UInt8(try integer(1))
                    guard let decoded = PpgClockSource(rawValue: source) else {
                        throw CodecError.invalidRow(i, "unknown clock source \(source)")
                    }
                    clock = decoded
                    if try presence(i, "subsec") { subsec = UInt16(try integer(2)) }
                    if try presence(i, "flags") { frontEnd = UInt8(try integer(1)) }
                    sampleFlags = try integer(1)
                }
                let blobLength = Int(try integer(4))
                guard blobLength >= 0, blobLength <= 4 * 1024 else {
                    throw CodecError.invalidRow(i, "invalid sample blob length \(blobLength)")
                }
                guard blobLength <= bytes.count - offset else {
                    throw CodecError.truncated("record \(i) needs \(blobLength) blob bytes at offset \(offset), have \(bytes.count - offset)")
                }
                let blob = try take(blobLength)
                var samples = [Int16](repeating: 0, count: blobLength / 2)
                for s in 0..<samples.count {
                    samples[s] = Int16(bitPattern: UInt16(blob[blob.startIndex + s * 2])
                        | (UInt16(blob[blob.startIndex + s * 2 + 1]) << 8))
                }
                let atRail = deltaAtRail(samples)
                if version == anchorFormat, sampleFlags != (atRail ? 1 : 0) {
                    throw CodecError.invalidRow(i, "sample flags \(sampleFlags) disagree with the deltas")
                }
                records.append(Record(rowId: rowId, ts: ts, recordIndex: recordIndex,
                                      burstIndex: burstIndex, samples: samples, format: version,
                                      anchor: anchor, clockSource: clock, subsecQ15: subsec,
                                      frontEndFlags: frontEnd, deltaAtRail: atRail))
            }
            guard offset == bytes.count else {
                throw CodecError.trailingBytes(bytes.count - offset)
            }
            return records
        }
    }

    // MARK: - PPG reconstruction

    /// How anchored v26 records become sample times. The one place to change it
    /// (docs/model-integration/ppg-transport.md, "Reconstruction and timing evidence").
    enum PpgGrid: String, Equatable {
        /// anchor + 24 deltas = 25 distinct consecutive samples per record, on a uniform 1/25 s grid.
        /// Recorded v26 continuity shows the next record's anchor is the 26th sample, one ordinary
        /// step after the 25th, not a repeat of it, and the v20 optical frame carries the same 25
        /// samples per record as absolute values. Nothing is dropped and no point belongs to the
        /// next record. A documented deviation from the spec text "first 24 at ts + i/24".
        case uniform25 = "uniform-25hz-v26-continuity"
        /// The pre-Spec-01 convention: the first 24 of the 25 points at ts + i/24, the 25th handed
        /// to the next record. Kept so the deviation is a one-line revert; not used in production.
        case legacy24 = "v26-first24-endpoint-next"

        var samplesPerRecord: Int { self == .uniform25 ? 25 : 24 }
        var endpoint: String { self == .uniform25 ? "own_record" : "next_record" }
    }

    /// The grid every request uses.
    static let ppgGrid: PpgGrid = .uniform25
    /// Samples per record-second on the emitted grid (`native_rate_hz`, `sample_count_per_second`).
    static var ppgNativeRateHz: Int { ppgGrid.samplesPerRecord }
    /// The recorded evidence behind `uniform25`, summarised for every segment's `clock`. Method and
    /// limits (one corpus, one firmware, no independent check of the strap clock) are in the doc.
    static let ppgGridEvidence = "frwhoop-v26-corpus fw=50.35.2.0 records=3645 pairs=3528 "
        + "exact-zero-boundary=1.8% boundary-median=18 delta-median=18 "
        + "corr(boundary,last)=0.77 corr(boundary,next)=0.84 corr(adjacent)=0.80 "
        + "v20-same-samples=823/824 next-anchor=next-v20-first 782/782"

    /// Side-channel optical configuration (v20-style source/drive/range/offset).
    /// The v26 wire records never carry it; when a caller supplies it, the
    /// config identity is built from it (a change breaks pooling) and a drive == 0
    /// block is a dark/control block, never a worn pulsatile channel.
    struct PpgOpticalConfig: Equatable, Hashable {
        var sourceA: Int? = nil
        var driveA: Int? = nil
        var sourceB: Int? = nil
        var driveB: Int? = nil
        var rangeA: Int? = nil
        var offsetA: Int? = nil
        var rangeB: Int? = nil
        var offsetB: Int? = nil

        var isDark: Bool { (driveA ?? 0) == 0 || (driveB ?? 0) == 0 }
        /// Channel (source), drive and gain (range) identified for both channels.
        var identifiesConfiguration: Bool {
            [sourceA, driveA, rangeA, sourceB, driveB, rangeB].allSatisfy { $0 != nil }
        }
        var identity: String {
            func part(_ name: String, _ value: Int?) -> String { "\(name)=\(value.map(String.init) ?? "?")" }
            return [part("srcA", sourceA), part("drvA", driveA), part("srcB", sourceB), part("drvB", driveB),
                    part("rngA", rangeA), part("offA", offsetA), part("rngB", rangeB), part("offB", offsetB)]
                .joined(separator: ";")
        }
    }

    /// What a run's optical configuration is known to be. `identity` names the configuration only
    /// (gain, drive, channel, LED), never a burst or record counter, and is "unknown" whenever the
    /// transport does not identify it: every v26 record, because v26 reports no gain, drive or channel.
    /// Equal identities mean comparable amplitudes; "unknown" is never equal to anything.
    struct PpgConfig: Equatable, Hashable {
        static let unknownIdentity = "unknown"

        let identity: String
        let known: Bool
        /// The v26 per-burst counter: part of run identity and descriptive, never configuration.
        let burstIndex: Int32?
        /// The raw type-47 header flags byte when the phone kept it (descriptive, verbatim).
        let frontEndFlags: UInt8?
        let optical: PpgOpticalConfig?

        init(burstIndex: Int32?, frontEndFlags: UInt8? = nil, optical: PpgOpticalConfig? = nil) {
            self.burstIndex = burstIndex
            self.frontEndFlags = frontEndFlags
            self.optical = optical
            self.identity = optical?.identity ?? Self.unknownIdentity
            self.known = optical?.identifiesConfiguration ?? false
        }
    }

    /// Where a record's sample times come from. Sample k of a segment is at
    /// `start_unix + phase_s + k / samples_per_second`; `phase_s` is the header Q15 sub-second phase
    /// when the record carried it, else unknown (up to one second).
    struct PpgClock: Equatable, Hashable {
        let source: PpgClockSource
        let subsecQ15: UInt16?

        /// A phase only below one second; any other value is carried, never interpreted.
        var phaseSeconds: Double? { subsecQ15.flatMap { $0 < 32_768 ? Double($0) / 32_768 : nil } }
    }

    /// A per-second PPG record as the reconstruction layer consumes it.
    struct PpgWaveformInput: Equatable {
        let rowId: Int64
        let ts: Int64
        /// The 24 signed i16 deltas, verbatim (a count other than 24 is a
        /// detected, reported native-rate variant — never assumed).
        let samples: [Int16]
        /// Raw per-burst counter (not a channel id; the v26 wire meaning).
        let burstIndex: Int32?
        let recordIndex: Int64?
        /// The absolute optical anchor. nil = the wire/object carried none →
        /// the second is withheld `missing_ppg_anchor`.
        let baseCode: Int32?
        let config: PpgOpticalConfig?
        let clockSource: PpgClockSource
        let subsecQ15: UInt16?
        let frontEndFlags: UInt8?
        /// The NPB1 format the record arrived in (0 when it did not come from the wire).
        let format: UInt8

        init(rowId: Int64 = 0, ts: Int64, samples: [Int16], burstIndex: Int32? = nil,
             recordIndex: Int64? = nil, baseCode: Int32? = nil, config: PpgOpticalConfig? = nil,
             clockSource: PpgClockSource = .unknown, subsecQ15: UInt16? = nil,
             frontEndFlags: UInt8? = nil, format: UInt8 = 0) {
            self.rowId = rowId
            self.ts = ts
            self.samples = samples
            self.burstIndex = burstIndex
            self.recordIndex = recordIndex
            self.baseCode = baseCode
            self.config = config
            self.clockSource = clockSource
            self.subsecQ15 = subsecQ15
            self.frontEndFlags = frontEndFlags
            self.format = format
        }

        /// A wire record. The u32 anchor saturates into Int32: a code that large is outside the signed
        /// 20-bit optical domain anyway, so the second is withheld as out of domain, never as missing.
        init(wireRecord: PpgCodec.Record) {
            self.init(rowId: wireRecord.rowId, ts: wireRecord.ts, samples: wireRecord.samples,
                      burstIndex: wireRecord.burstIndex, recordIndex: wireRecord.recordIndex,
                      baseCode: wireRecord.anchor.map { Int32(clamping: $0) },
                      clockSource: wireRecord.clockSource, subsecQ15: wireRecord.subsecQ15,
                      frontEndFlags: wireRecord.frontEndFlags, format: wireRecord.format)
        }

        /// From a WhoopProtocol v26 `PpgWaveformSample` (the shape
        /// `extractHistoricalStreams` persists after verifying the frame CRC).
        init(whoopSample: PpgWaveformSample, rowId: Int64 = 0) {
            self.init(rowId: rowId, ts: Int64(whoopSample.ts),
                      samples: whoopSample.samples.map { Int16(clamping: $0) },
                      burstIndex: whoopSample.burstIndex.map { Int32(clamping: $0) },
                      baseCode: whoopSample.baseCode.map { Int32(clamping: $0) },
                      clockSource: .strapRecordSecond)
        }

        var opticalConfig: PpgConfig {
            PpgConfig(burstIndex: burstIndex, frontEndFlags: frontEndFlags, optical: config)
        }
        var clock: PpgClock { PpgClock(source: clockSource, subsecQ15: subsecQ15) }

        /// How much provenance this observation carries; a richer copy of the same deltas wins a merge.
        var richness: Int {
            (baseCode != nil ? 8 : 0) + (clockSource != .unknown ? 4 : 0)
                + (recordIndex != nil ? 2 : 0) + (subsecQ15 != nil || frontEndFlags != nil ? 1 : 0)
        }
    }

    /// One reconstructed second of PPG: either emitted absolute samples or a
    /// withheld reason. Withheld seconds are never sent as amplitudes.
    struct PpgSecond: Equatable {
        let ts: Int64
        let config: PpgConfig
        let clock: PpgClock
        let burstIndex: Int32?
        /// `grid.samplesPerRecord` absolute ADC counts when emitted; empty when withheld.
        let samples: [Int32]
        /// nil = emitted; else a CONTRACTS §3 reason.
        let withheldReason: String?
        /// Any delta sat at an i16 rail (diagnostic behind `saturated_delta`).
        let saturatedDelta: Bool
        /// The reconstruction left the signed 20-bit optical domain
        /// (diagnostic behind `saturated_delta`).
        let outOfDomain: Bool
        /// The raw delta count (native-rate detection / diagnostics).
        let deltaCount: Int
        /// Drive == 0 dark/control block (when an optical config was carried).
        let darkBlock: Bool
        /// The NPB1 format the second's record arrived in (0 when not from the wire).
        let format: UInt8

        var configIdentity: String { config.identity }
    }

    /// Reconstruct one record into a second. Order of resolution (fail-closed):
    /// empty slot → `artifact_unavailable`; delta count ≠ 24 →
    /// `unsupported_native_rate` (detected, never assumed); drive == 0 dark
    /// block → `artifact_unavailable`; missing anchor → `missing_ppg_anchor`;
    /// any i16-rail delta or a reconstruction outside ±2^19 →
    /// `saturated_delta`; otherwise the second is emitted on `grid`.
    ///
    /// The anchor + 24 deltas reconstruct to 25 points (sample 0 = baseCode,
    /// WhoopProtocol.ppgWaveformAbsolute), every one checked against the optical domain. `uniform25`
    /// emits all 25 at `ts + i/25`; `legacy24` emits `points[0..<24]` at `ts + i/24`.
    static func reconstructSecond(_ record: PpgWaveformInput, grid: PpgGrid = ppgGrid) -> PpgSecond {
        let config = record.opticalConfig, clock = record.clock
        let dark = record.config?.isDark ?? false
        func second(_ samples: [Int32], _ reason: String?, saturated: Bool = false, outOfDomain: Bool = false,
                    dark isDark: Bool = false) -> PpgSecond {
            PpgSecond(ts: record.ts, config: config, clock: clock, burstIndex: record.burstIndex,
                      samples: samples, withheldReason: reason, saturatedDelta: saturated,
                      outOfDomain: outOfDomain, deltaCount: record.samples.count, darkBlock: isDark,
                      format: record.format)
        }
        if record.samples.isEmpty { return second([], reasonArtifactUnavailable, dark: dark) }
        if record.samples.count != ppgDeltasPerRecord { return second([], reasonUnsupportedNativeRate, dark: dark) }
        if dark { return second([], reasonArtifactUnavailable, dark: true) }
        guard let base = record.baseCode else { return second([], reasonMissingPpgAnchor) }
        let deltas = record.samples.map(Int.init)
        let saturated = deltas.contains { $0 == Int(Int16.min) || $0 == Int(Int16.max) }
        // The shared reconstruction (WhoopProtocol.ppgWaveformAbsolute) — the
        // same math the rest of the repo pins against Kotlin.
        guard let absolute = ppgWaveformAbsolute(baseCode: Int(base), deltas: deltas) else {
            // Unreachable with a non-nil base; fail closed rather than emit.
            return second([], reasonMissingPpgAnchor)
        }
        let outOfDomain = absolute.contains { $0 < opticalSampleMin || $0 > opticalSampleMax }
        if saturated || outOfDomain {
            return second([], reasonSaturatedDelta, saturated: saturated, outOfDomain: outOfDomain)
        }
        return second(absolute.prefix(grid.samplesPerRecord).map { Int32($0) }, nil)
    }

    /// A contiguous, configuration-compatible PPG run over EMITTED seconds. Runs break at missing
    /// seconds (a withheld second is a data gap, never bridged), at any configuration or burst change
    /// and at any clock source or phase change.
    struct PpgRun: Equatable {
        let start: Int64
        let end: Int64
        /// `ppg-<start_unix>` of the run as reconstructed; clipping keeps it, so the pieces of one run
        /// in consecutive requests share it. Unique within a device-day: runs never overlap.
        let runId: String
        let config: PpgConfig
        let clock: PpgClock

        var configIdentity: String { config.identity }
    }

    /// The full PPG reconstruction result for a set of records.
    struct PpgReconstruction: Equatable {
        /// Unique seconds in ascending ts order (identical duplicates collapse;
        /// conflicting duplicates keep the first by capture precedence).
        let seconds: [PpgSecond]
        /// Withheld-reason counts over the unique seconds.
        let reasonCounts: [String: Int]
        /// Detected native rates: delta-count → number of records. `24` is the
        /// verified native rate; anything else is reported, never assumed.
        let detectedDeltaCounts: [Int: Int]
        /// Seconds dropped as conflicting duplicates (kept first by rowId
        /// precedence; never averaged).
        let conflictingDuplicateSeconds: [Int64]
        /// Seconds whose copies carried the same deltas and one copy more provenance (an anchored
        /// 1.5 re-upload of an anchor-less second): the richer copy is kept, nothing conflicts.
        let supersededDuplicateSeconds: Int
        /// Contiguous runs over emitted seconds, one configuration and clock each.
        let runs: [PpgRun]
        /// `grid.samplesPerRecord` when every unique record carried 24 deltas; nil otherwise (mixed or
        /// unknown — never assumed).
        let nativeRateHz: Int?
        let grid: PpgGrid
        /// Unique seconds per NPB1 format, so a day shows how much of its PPG could carry an anchor.
        let secondsByFormat: [UInt8: Int]
    }

    /// Deterministically merge records (from one or more objects) into one record per second.
    /// Identical observations collapse. Two copies with the same deltas, burst and compatible identity
    /// where one carries more provenance (an anchored 1.5 copy of an anchor-less 1.3 second) are one
    /// observation: the richer copy is kept and nothing conflicts. Any other disagreement keeps the
    /// first by capture precedence `(rowId, recordIndex, burstIndex, ts)` and is reported — never averaged.
    static func mergePpgRecords(_ records: [PpgWaveformInput]) -> (merged: [PpgWaveformInput],
                                                                   identical: Int,
                                                                   conflicting: [Int64],
                                                                   superseded: Int) {
        // Observation identity excludes rowId: the same second re-uploaded in a
        // second object carries the same samples/burst/recordIndex/anchor but a
        // different storage row id, and must still count as an identical
        // duplicate. rowId is used only as the deterministic CAPTURE precedence
        // for conflicting observations (older capture wins; never averaged).
        func precedence(_ r: PpgWaveformInput) -> (Int64, Int64, Int32, Int64) {
            (r.rowId, r.recordIndex ?? Int64.max, r.burstIndex ?? Int32.max, r.ts)
        }
        func compatible<T: Equatable>(_ a: T?, _ b: T?) -> Bool { a == nil || b == nil || a == b }
        func sameObservation(_ a: PpgWaveformInput, _ b: PpgWaveformInput) -> Bool {
            a.samples == b.samples && a.burstIndex == b.burstIndex && a.config == b.config
                && compatible(a.recordIndex, b.recordIndex) && compatible(a.baseCode, b.baseCode)
                && compatible(a.subsecQ15, b.subsecQ15) && compatible(a.frontEndFlags, b.frontEndFlags)
                && (a.clockSource == b.clockSource || a.clockSource == .unknown || b.clockSource == .unknown)
        }
        var byTs: [Int64: PpgWaveformInput] = [:]
        var conflicting: [Int64] = []
        var identical = 0, superseded = 0
        for record in records {
            guard let existing = byTs[record.ts] else { byTs[record.ts] = record; continue }
            if sameObservation(existing, record), existing.richness == record.richness {
                identical += 1
                if precedence(record) < precedence(existing) { byTs[record.ts] = record }
            } else if sameObservation(existing, record) {
                superseded += 1
                if record.richness > existing.richness { byTs[record.ts] = record }
            } else {
                if precedence(record) < precedence(existing) { byTs[record.ts] = record }
                if !conflicting.contains(record.ts) { conflicting.append(record.ts) }
            }
        }
        let merged = byTs.keys.sorted().map { byTs[$0]! }
        return (merged, identical, conflicting.sorted(), superseded)
    }

    /// Reconstruct merged records into seconds, runs and diagnostics.
    static func reconstructPPG(records: [PpgWaveformInput], grid: PpgGrid = ppgGrid) -> PpgReconstruction {
        let (merged, _, conflicting, superseded) = mergePpgRecords(records)
        let seconds = merged.map { reconstructSecond($0, grid: grid) }
        var reasonCounts: [String: Int] = [:]
        var detected: [Int: Int] = [:]
        var formats: [UInt8: Int] = [:]
        for second in seconds {
            if let reason = second.withheldReason { reasonCounts[reason, default: 0] += 1 }
            detected[second.deltaCount, default: 0] += 1
            formats[second.format, default: 0] += 1
        }
        let allAt24 = !seconds.isEmpty && detected.keys.allSatisfy { $0 == ppgDeltasPerRecord }
        return PpgReconstruction(seconds: seconds, reasonCounts: reasonCounts,
                                 detectedDeltaCounts: detected,
                                 conflictingDuplicateSeconds: conflicting,
                                 supersededDuplicateSeconds: superseded,
                                 runs: ppgRuns(seconds: seconds),
                                 nativeRateHz: allAt24 ? grid.samplesPerRecord : nil,
                                 grid: grid, secondsByFormat: formats)
    }

    /// Contiguous runs over emitted seconds; a missing or withheld second, a configuration or burst
    /// change, or a clock source or phase change breaks the run.
    static func ppgRuns(seconds: [PpgSecond]) -> [PpgRun] {
        var runs: [PpgRun] = []
        var current: (start: Int64, last: Int64, config: PpgConfig, clock: PpgClock)? = nil
        func close() {
            guard let run = current else { return }
            runs.append(PpgRun(start: run.start, end: run.last + 1, runId: "ppg-\(run.start)",
                               config: run.config, clock: run.clock))
        }
        for second in seconds where second.withheldReason == nil {
            if let run = current, second.ts == run.last + 1, second.config == run.config, second.clock == run.clock {
                current = (run.start, second.ts, run.config, run.clock)
            } else {
                close()
                current = (second.ts, second.ts, second.config, second.clock)
            }
        }
        close()
        return runs
    }

    // MARK: - Input coverage

    /// Actual input coverage over a window: the seconds the transport delivered a record for
    /// (`expected`), the seconds emitted (`eligible`) and every withheld second by reason. One
    /// record per second is what the transport delivers, so record-seconds are the expectation;
    /// capture is duty-cycled (v26 arrives in bursts), so wall-clock time is not.
    struct ModalityCoverage: Equatable {
        var expectedSeconds = 0
        var eligibleSeconds = 0
        var withheld: [String: Int] = [:]
        var runs = 0
        var segments = 0

        var withheldSeconds: Int { withheld.values.reduce(0, +) }
        /// The reason most seconds were withheld for, or nil when none were.
        var dominantWithheldReason: String? {
            withheld.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        }

        func jsonObject() -> [String: Any] {
            var out: [String: Any] = ["expected_seconds": expectedSeconds, "eligible_seconds": eligibleSeconds,
                                      "withheld_seconds": withheldSeconds, "runs": runs, "segments": segments]
            out["withheld"] = withheld
            return out
        }
    }

    /// PPG coverage over `[from, to)`: every reconstructed second in the window, and the distinct runs
    /// touching it.
    static func ppgCoverage(secondsByTs: [Int64: PpgSecond], runs: [PpgRun], from: Int64, to: Int64,
                            segments: Int = 0) -> ModalityCoverage {
        var out = ModalityCoverage()
        guard to > from else { return out }
        func count(_ second: PpgSecond) {
            out.expectedSeconds += 1
            if let reason = second.withheldReason { out.withheld[reason, default: 0] += 1 }
            else { out.eligibleSeconds += 1 }
        }
        if Int(to - from) <= secondsByTs.count {
            for t in from..<to { if let second = secondsByTs[t] { count(second) } }
        } else {
            for (t, second) in secondsByTs where t >= from && t < to { count(second) }
        }
        out.runs = runs.filter { $0.start < to && $0.end > from }.count
        out.segments = segments
        return out
    }

    /// IMU coverage over `[from, to)`. The worker withholds no IMU second, so every delivered second is
    /// eligible.
    static func imuCoverage(timeline: ActivityLane.ImuTimeline, runs: [ActivityLane.Run], from: Int64, to: Int64,
                            segments: Int = 0) -> ModalityCoverage {
        var out = ModalityCoverage()
        guard to > from, let first = ActivityLane.lowerBound(timeline.seconds, from) else { return out }
        var index = first
        while index < timeline.seconds.count, timeline.seconds[index] < to {
            out.expectedSeconds += 1
            index += 1
        }
        out.eligibleSeconds = out.expectedSeconds
        out.runs = runs.filter { $0.start < to && $0.end > from }.count
        out.segments = segments
        return out
    }

    // MARK: - PPG segments

    /// One endpoint-owned PPG segment (CONTRACTS §4): `samples` holds `durationS * samplesPerSecond`
    /// absolute ADC counts; sample k is at `startUnix + clock.phaseSeconds + k / samplesPerSecond`.
    /// Consecutive segments share no sample, and the segments of one run share its `runId`, are
    /// time-contiguous and share one configuration and clock.
    struct PpgSegment: Equatable {
        let startUnix: Int64
        let durationS: Int
        let samples: [Int32]
        let runId: String
        let config: PpgConfig
        let clock: PpgClock
        let grid: PpgGrid

        /// Always true: a run carries one configuration by construction. An older sidecar's rhythm
        /// gate reads it.
        var configStable: Bool { true }
        var samplesPerSecond: Int { grid.samplesPerRecord }
    }

    /// Split a PPG run into non-overlapping segments of at most `maxDuration`
    /// seconds at whole-second boundaries, endpoint-owned.
    static func ppgSegments(run: PpgRun, secondsByTs: [Int64: PpgSecond],
                            maxDuration: Int = maxSegmentDurationSeconds,
                            grid: PpgGrid = ppgGrid) -> [PpgSegment] {
        guard maxDuration > 0 else { return [] }
        var segments: [PpgSegment] = []
        var chunkStart = run.start
        while chunkStart < run.end {
            let chunkEnd = segmentEnd(start: chunkStart, maxDuration: maxDuration, runEnd: run.end)
            var samples: [Int32] = []
            samples.reserveCapacity(Int(chunkEnd - chunkStart) * grid.samplesPerRecord)
            for t in chunkStart..<chunkEnd {
                if let second = secondsByTs[t], second.withheldReason == nil {
                    samples.append(contentsOf: second.samples)
                }
            }
            if !samples.isEmpty {
                segments.append(PpgSegment(startUnix: chunkStart, durationS: Int(chunkEnd - chunkStart),
                                           samples: samples, runId: run.runId, config: run.config,
                                           clock: run.clock, grid: grid))
            }
            chunkStart = chunkEnd
        }
        return segments
    }

    /// The segment `config` object (docs/model-integration/README.md, PPG segments).
    static func configObject(_ config: PpgConfig) -> [String: Any] {
        var out: [String: Any] = ["identity": config.identity, "known": config.known, "stable": true]
        if let burst = config.burstIndex { out["burst_index"] = Int(burst) }
        if let flags = config.frontEndFlags { out["front_end_flags"] = Int(flags) }
        if let optical = config.optical {
            for (key, value) in [("source_a", optical.sourceA), ("drive_a", optical.driveA),
                                 ("source_b", optical.sourceB), ("drive_b", optical.driveB),
                                 ("range_a", optical.rangeA), ("offset_a", optical.offsetA),
                                 ("range_b", optical.rangeB), ("offset_b", optical.offsetB)] {
                if let value { out[key] = value }
            }
        }
        return out
    }

    /// The segment `clock` object. The sidecar interprets `packet_timing_verified` and
    /// `samples_per_second`; the rest is provenance.
    static func clockObject(_ clock: PpgClock, grid: PpgGrid) -> [String: Any] {
        [
            "source": clock.source.wireName,
            "grid": grid.rawValue,
            "grid_evidence": ppgGridEvidence,
            "endpoint": grid.endpoint,
            "record_period_s": 1,
            "samples_per_second": grid.samplesPerRecord,
            "sample_time": "start_unix + phase_s + k/\(grid.samplesPerRecord)",
            "phase_s": clock.phaseSeconds.map { $0 as Any } ?? NSNull(),
            // The grid comes from offline continuity evidence on one corpus and firmware; the strap
            // clock behind `ts` was never checked against independent packet timing.
            "packet_timing_verified": false,
        ]
    }

    // MARK: - Sidecar request input (CONTRACTS §4)

    enum Modality: String { case imu, ppg }

    /// The modality a family's input comes from. A request never asks for a family whose input it
    /// does not carry; an unknown family is asked whenever the request carries anything.
    static func requiredModality(of family: String) -> Modality? {
        switch family {
        case "movement", "oscillation", "tremor", "arm_swing": return .imu
        case "ppg_quality", "pulse_shape", "perfusion_research", "rhythm_shadow": return .ppg
        default: return nil
        }
    }

    /// `families` (caller order) a request carrying the given modalities may ask for.
    static func families(_ families: [String], imu: Bool, ppg: Bool) -> [String] {
        families.filter { family in
            switch requiredModality(of: family) {
            case .imu?: return imu
            case .ppg?: return ppg
            case nil: return imu || ppg
            }
        }
    }

    /// One recorded placement declaration (`placement_intervals`): body location only, half-open
    /// `[start, end)` with a nil end for an open interval.
    struct PlacementInterval: Equatable {
        let start: Int64
        let end: Int64?
        let placement: String
        let source: String
        let deviceScoped: Bool
    }

    /// Where the strap was worn over one request, from recorded declarations only. A device-scoped
    /// declaration wins over a user-level one where both exist (the phone's PlacementStore rule).
    /// Nothing records the wrist side or the screen orientation, so `watch_side` and
    /// `device_orientation` stay "unknown"; this never guesses them from a body location.
    struct PlacementSummary: Equatable {
        /// The one location covering every second, "mixed" when several do, "unknown" when any
        /// second has no declaration.
        let bodyLocation: String
        /// "user" | "device" | "mixed" | "none" (nothing declared in the request).
        let source: String

        static let undeclared = PlacementSummary(bodyLocation: "unknown", source: "none")

        func jsonObject() -> [String: Any] {
            ["body_location": bodyLocation, "source": source,
             "watch_side_source": "not_recorded", "device_orientation_source": "not_recorded"]
        }
    }

    static func placementSummary(_ intervals: [PlacementInterval], from: Int64, to: Int64) -> PlacementSummary {
        guard to > from, !intervals.isEmpty else { return .undeclared }
        // Device-scoped declarations first; user-level ones fill only what they leave uncovered.
        var gaps: [(Int64, Int64)] = [(from, to)]
        var pieces: [PlacementInterval] = []
        for scoped in [true, false] {
            let layer = intervals.filter { $0.deviceScoped == scoped }.sorted { $0.start < $1.start }
            var remaining: [(Int64, Int64)] = []
            for (gapStart, gapEnd) in gaps {
                var cursor = gapStart
                for interval in layer where interval.start < gapEnd && (interval.end ?? Int64.max) > cursor {
                    let start = max(interval.start, cursor), end = min(interval.end ?? Int64.max, gapEnd)
                    guard start < end else { continue }
                    if start > cursor { remaining.append((cursor, start)) }
                    pieces.append(interval)
                    cursor = end
                }
                if cursor < gapEnd { remaining.append((cursor, gapEnd)) }
            }
            gaps = remaining
        }
        guard !pieces.isEmpty else { return .undeclared }
        let sources = Set(pieces.map(\.source))
        let source = sources.count == 1 ? sources.first! : "mixed"
        guard gaps.isEmpty else { return PlacementSummary(bodyLocation: "unknown", source: source) }
        let locations = Set(pieces.map(\.placement))
        return PlacementSummary(bodyLocation: locations.count == 1 ? locations.first! : "mixed", source: source)
    }

    /// The `coverage` member of one request: actual input over the request's interval.
    struct RequestCoverage: Equatable {
        let intervalStart: Int64
        let intervalEnd: Int64
        let imu: ModalityCoverage
        let ppg: ModalityCoverage

        func jsonObject() -> [String: Any] {
            ["interval_start_unix": intervalStart, "interval_end_unix": intervalEnd,
             "imu": imu.jsonObject(), "ppg": ppg.jsonObject()]
        }
    }

    /// The typed `input` member of `POST /v1/infer` for metric
    /// `sensor_biomarkers`.
    struct SensorBiomarkerInput: Equatable {
        let schemaVersion: Int
        let deviceID: String
        let deviceFamily: String
        let inputRevision: String
        let dayUTC: String
        let imu: ImuSection?
        let ppg: PpgSection?
        let watchSide: String
        let deviceOrientation: String
        let families: [String]
        let coverage: RequestCoverage?
        let placement: PlacementSummary

        struct ImuSection: Equatable {
            let samplingRateHz: Int
            let units: [String: String]
            let segments: [ImuSegment]
        }
        struct PpgSection: Equatable {
            let nativeRateHz: Int
            let units: String
            let segments: [PpgSegment]
        }

        /// The CONTRACTS §4 JSON object (no `imu`/`ppg` keys when a modality
        /// has no verified/emitted data).
        func jsonObject() -> [String: Any] {
            var input = metadataObject()
            if let imu {
                input["imu"] = [
                    "sampling_rate_hz": imu.samplingRateHz,
                    "units": imu.units,
                    "segments": imu.segments.map {
                        ["start_unix": $0.startUnix, "duration_s": $0.durationS,
                         "accel_g": $0.accelG, "gyro_dps": $0.gyroDps]
                    },
                ]
            }
            if let ppg {
                input["ppg"] = [
                    "native_rate_hz": ppg.nativeRateHz,
                    "units": ppg.units,
                    "segments": ppg.segments.map {
                        ["start_unix": $0.startUnix, "duration_s": $0.durationS,
                         "samples": $0.samples,
                         "sample_count_per_second": $0.samplesPerSecond,
                         "run_id": $0.runId,
                         "config": SensorBiomarkerInputs.configObject($0.config),
                         "clock": SensorBiomarkerInputs.clockObject($0.clock, grid: $0.grid)] as [String: Any]
                    },
                ]
            }
            return input
        }

        /// Every key except the sample-bearing `imu` / `ppg` sections.
        func metadataObject() -> [String: Any] {
            var out: [String: Any] = [
                "schema_version": schemaVersion,
                "device": ["id": deviceID, "family": deviceFamily],
                "input_revision": inputRevision,
                "day_utc": dayUTC,
                "watch_side": watchSide,
                "device_orientation": deviceOrientation,
                "families": families,
                "placement": placement.jsonObject(),
            ]
            if let coverage { out["coverage"] = coverage.jsonObject() }
            return out
        }

        /// The same JSON as `jsonObject()`, written directly. The metadata (the only strings) goes
        /// through JSONSerialization; the numeric segment arrays, pre-written once by
        /// `segmentJSON`, are spliced in. Boxing ~360k samples per request into `Any`/`JSONValue`
        /// and encoding them twice cost tens of seconds per request on the worker host.
        func writeJSON(imuSegmentsJSON: [String], ppgSegmentsJSON: [String]) throws -> Data {
            var out = String(decoding: try JSONSerialization.data(withJSONObject: metadataObject(),
                                                                  options: [.sortedKeys]), as: UTF8.self)
            out.removeLast()  // the metadata object's closing brace
            if let imu {
                let units = String(decoding: try JSONSerialization.data(withJSONObject: imu.units,
                                                                        options: [.sortedKeys]), as: UTF8.self)
                out += ",\"imu\":{\"sampling_rate_hz\":\(imu.samplingRateHz),\"units\":\(units),\"segments\":["
                out += imuSegmentsJSON.joined(separator: ",")
                out += "]}"
            }
            if let ppg {
                let units = String(decoding: try JSONSerialization.data(withJSONObject: ppg.units,
                                                                        options: [.fragmentsAllowed]), as: UTF8.self)
                out += ",\"ppg\":{\"native_rate_hz\":\(ppg.nativeRateHz),\"units\":\(units),\"segments\":["
                out += ppgSegmentsJSON.joined(separator: ",")
                out += "]}"
            }
            out += "}"
            return Data(out.utf8)
        }

        /// The `context` member of the request (CONTRACTS §4).
        func contextJSON(intervalStartUTC: String, intervalEndUTC: String) -> [String: Any] {
            ["interval_start_utc": intervalStartUTC,
             "interval_end_utc": intervalEndUTC,
             "iana_timezone": "UTC",
             "live": false]
        }
    }

    /// The smallest span covering a request's segments, as ISO UTC strings.
    static func isoInterval(start: Int64, end: Int64) -> (start: String, end: String) {
        (ActivityLane.isoUTC(Int(start)), ActivityLane.isoUTC(Int(end)))
    }

    /// A built sidecar request for one chunk-group, with its MEASURED
    /// serialized size (the size gate is part of the contract: every request
    /// stays under `maxBodyBytes`).
    struct BuiltRequest {
        let input: SensorBiomarkerInput
        let intervalStartUTC: String
        let intervalEndUTC: String
        let serializedSizeBytes: Int
        /// The input's JSON, written once; the lane posts it verbatim.
        let inputJSON: Data
    }

    /// A finite Double's `description` is its shortest round-trip decimal and valid JSON
    /// ("1.0", "-0.000244140625", "1e-05").
    private static func appendRows(_ rows: [[Double]], to out: inout String) {
        out.append("[")
        for (i, row) in rows.enumerated() {
            if i > 0 { out.append(",") }
            out.append("[")
            for (j, v) in row.enumerated() {
                if j > 0 { out.append(",") }
                out.append(v.description)
            }
            out.append("]")
        }
        out.append("]")
    }

    static func segmentJSON(_ segment: ImuSegment) -> String {
        var out = "{\"accel_g\":"
        out.reserveCapacity(segment.accelG.count * 80 + 64)
        appendRows(segment.accelG, to: &out)
        out += ",\"duration_s\":\(segment.durationS),\"gyro_dps\":"
        appendRows(segment.gyroDps, to: &out)
        out += ",\"start_unix\":\(segment.startUnix)}"
        return out
    }

    /// Small metadata values written with sorted keys, so segment JSON is deterministic.
    static func jsonText(_ value: Any) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }

    static func segmentJSON(_ segment: PpgSegment) -> String {
        var out = "{\"clock\":\(jsonText(clockObject(segment.clock, grid: segment.grid))),"
            + "\"config\":\(jsonText(configObject(segment.config))),\"duration_s\":\(segment.durationS),"
            + "\"run_id\":\(jsonText(segment.runId)),"
            + "\"sample_count_per_second\":\(segment.samplesPerSecond),\"samples\":["
        out.reserveCapacity(segment.samples.count * 8 + 1024)
        for (i, v) in segment.samples.enumerated() {
            if i > 0 { out.append(",") }
            out.append(String(v))
        }
        out += "],\"start_unix\":\(segment.startUnix)}"
        return out
    }

    /// Measured serialized size of a request input.
    static func serializedSize(_ input: SensorBiomarkerInput) throws -> Int {
        try input.writeJSON(imuSegmentsJSON: input.imu?.segments.map(segmentJSON) ?? [],
                            ppgSegmentsJSON: input.ppg?.segments.map(segmentJSON) ?? []).count
    }

    /// Build the request(s) for a run set (one or more IMU runs and/or PPG
    /// runs of a device-day): endpoint-owned segments of at most
    /// `maxDuration` seconds are packed in time order into requests whose
    /// measured serialized size stays under `maxBodyBytes`. The lane chooses
    /// which runs form one chunk-group (algorithm-context overlap is its
    /// concern, not this module's); this module only guarantees contiguous,
    /// non-overlapping segments and the 8 MiB budget.
    ///
    /// A modality no requested family reads is never sent, a request asks only for families whose
    /// input it carries, and each request reports its actual input coverage and recorded placement.
    static func buildRequests(imuRuns: [ActivityLane.Run],
                              ppgRuns: [PpgRun],
                              imuTimeline: ActivityLane.ImuTimeline,
                              ppgSecondsByTs: [Int64: PpgSecond],
                              objects: [InputObject],
                              deviceID: String,
                              deviceFamily: String = "whoop5",
                              dayUTC: String,
                              watchSide: String = "unknown",
                              deviceOrientation: String = "unknown",
                              families: [String],
                              placement: [PlacementInterval] = [],
                              maxDuration: Int = maxSegmentDurationSeconds,
                              maxBodyBytes: Int = bodyBudgetBytes,
                              grid: PpgGrid = ppgGrid) throws -> [BuiltRequest] {
        guard maxDuration > 0, maxBodyBytes > 0 else { return [] }
        let revision = inputRevision(objects: objects)
        // A modality no requested family reads is never built or sent.
        let usedImuRuns = Self.families(families, imu: true, ppg: false).isEmpty ? [] : imuRuns
        let usedPpgRuns = Self.families(families, imu: false, ppg: true).isEmpty ? [] : ppgRuns
        // IMU first, then PPG — each modality's segments are internally
        // time-ordered and non-overlapping by construction.
        var imuSegs: [ImuSegment] = []
        for run in usedImuRuns { imuSegs.append(contentsOf: imuSegments(run: run, timeline: imuTimeline, maxDuration: maxDuration)) }
        var ppgSegs: [PpgSegment] = []
        for run in usedPpgRuns { ppgSegs.append(contentsOf: ppgSegments(run: run, secondsByTs: ppgSecondsByTs, maxDuration: maxDuration, grid: grid)) }

        // Safety: if a single segment still exceeds the budget (never at the
        // 300 s cap, but defensive), halve the cap and rebuild.
        var duration = maxDuration
        while true {
            var tooBig = false
            for segment in imuSegs where estimatedBytes(segment) > maxBodyBytes { tooBig = true }
            for segment in ppgSegs where estimatedBytes(segment) > maxBodyBytes { tooBig = true }
            guard tooBig, duration > 30 else { break }
            duration /= 2
            imuSegs = []
            for run in usedImuRuns { imuSegs.append(contentsOf: imuSegments(run: run, timeline: imuTimeline, maxDuration: duration)) }
            ppgSegs = []
            for run in usedPpgRuns { ppgSegs.append(contentsOf: ppgSegments(run: run, secondsByTs: ppgSecondsByTs, maxDuration: duration, grid: grid)) }
        }

        // Pack segments greedily in time order into budget-bounded requests. Each segment's JSON
        // is written once; a request's size is the metadata skeleton plus its segments' bytes.
        typealias Kinded = (kind: String, start: Int64, end: Int64, imu: ImuSegment?, ppg: PpgSegment?, json: String)
        var kinded: [Kinded] = []
        for segment in imuSegs {
            kinded.append(("imu", segment.startUnix, segment.startUnix + Int64(segment.durationS), segment, nil,
                           segmentJSON(segment)))
        }
        for segment in ppgSegs {
            kinded.append(("ppg", segment.startUnix, segment.startUnix + Int64(segment.durationS), nil, segment,
                           segmentJSON(segment)))
        }
        kinded.sort { ($0.start, $0.kind) < ($1.start, $1.kind) }

        func makeInput(imu: [ImuSegment], ppg: [PpgSegment], emptySections: Bool = false,
                       coverage: RequestCoverage? = nil, placement summary: PlacementSummary = .undeclared,
                       requestFamilies: [String]) -> SensorBiomarkerInput {
            SensorBiomarkerInput(
                schemaVersion: 1, deviceID: deviceID, deviceFamily: deviceFamily,
                inputRevision: revision, dayUTC: dayUTC,
                imu: imu.isEmpty && !emptySections ? nil : SensorBiomarkerInput.ImuSection(
                    samplingRateHz: imuNativeRateHz,
                    units: ["accel": "g", "gyro": "deg/s"],
                    segments: imu),
                ppg: ppg.isEmpty && !emptySections ? nil : SensorBiomarkerInput.PpgSection(
                    nativeRateHz: grid.samplesPerRecord, units: "adc_counts", segments: ppg),
                watchSide: watchSide, deviceOrientation: deviceOrientation, families: requestFamilies,
                coverage: coverage, placement: summary)
        }
        // Both section headers present: an upper bound on any request's non-segment bytes, plus room
        // for the coverage and placement members.
        let skeletonBytes = try makeInput(imu: [], ppg: [], emptySections: true, requestFamilies: families)
            .writeJSON(imuSegmentsJSON: [], ppgSegmentsJSON: []).count + 4096

        var requests: [BuiltRequest] = []
        var pendingImu: [ImuSegment] = []
        var pendingPpg: [PpgSegment] = []
        var pendingImuJSON: [String] = []
        var pendingPpgJSON: [String] = []
        var pendingBytes = 0
        var requestStart: Int64? = nil
        var requestEnd: Int64? = nil

        func closeRequest() throws {
            guard let start = requestStart, let end = requestEnd else { return }
            let requestFamilies = Self.families(families, imu: !pendingImu.isEmpty, ppg: !pendingPpg.isEmpty)
            if !requestFamilies.isEmpty {
                let coverage = RequestCoverage(
                    intervalStart: start, intervalEnd: end,
                    imu: imuCoverage(timeline: imuTimeline, runs: usedImuRuns, from: start, to: end,
                                     segments: pendingImu.count),
                    ppg: ppgCoverage(secondsByTs: ppgSecondsByTs, runs: usedPpgRuns, from: start, to: end,
                                     segments: pendingPpg.count))
                let input = makeInput(imu: pendingImu, ppg: pendingPpg, coverage: coverage,
                                      placement: placementSummary(placement, from: start, to: end),
                                      requestFamilies: requestFamilies)
                let json = try input.writeJSON(imuSegmentsJSON: pendingImuJSON, ppgSegmentsJSON: pendingPpgJSON)
                let interval = isoInterval(start: start, end: end)
                requests.append(BuiltRequest(input: input, intervalStartUTC: interval.start,
                                             intervalEndUTC: interval.end, serializedSizeBytes: json.count,
                                             inputJSON: json))
            }
            pendingImu = []
            pendingPpg = []
            pendingImuJSON = []
            pendingPpgJSON = []
            pendingBytes = 0
            requestStart = nil
            requestEnd = nil
        }

        for item in kinded {
            let itemBytes = item.json.utf8.count + 1  // its separating comma
            if !pendingImu.isEmpty || !pendingPpg.isEmpty,
               skeletonBytes + pendingBytes + itemBytes > maxBodyBytes {
                try closeRequest()
            }
            if item.kind == "imu" {
                pendingImu.append(item.imu!)
                pendingImuJSON.append(item.json)
            } else {
                pendingPpg.append(item.ppg!)
                pendingPpgJSON.append(item.json)
            }
            pendingBytes += itemBytes
            requestStart = min(requestStart ?? item.start, item.start)
            requestEnd = max(requestEnd ?? item.end, item.end)
        }
        try closeRequest()
        return requests
    }

    /// A cheap upper bound for the single-segment budget guard: 12 JSON
    /// numbers per IMU sample (6 values with separators) at a generous 16 B
    /// each, plus the ADC counts at 12 B each and the PPG clock/config members.
    static func estimatedBytes(_ segment: ImuSegment) -> Int {
        let imuNumbers = segment.accelG.count * 6
        return imuNumbers * 16 + segment.startUnix.description.count + 32
    }

    static func estimatedBytes(_ segment: PpgSegment) -> Int {
        segment.samples.count * 12 + segment.startUnix.description.count + 1024
    }
}

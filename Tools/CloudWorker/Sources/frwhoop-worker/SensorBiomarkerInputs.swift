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
///     signed i16 deltas with a (nil today on the wire) absolute optical anchor.
///
/// PPG reconstruction is explicit: absolute = baseCode + cumulative deltas,
/// via the shared `WhoopProtocol.ppgWaveformAbsolute`, ONLY when the anchor is
/// present. A record without an anchor is a WITHHELD second
/// (`missing_ppg_anchor`) and is never sent as amplitudes. Reconstructed
/// windows saturate or leave the signed 20-bit optical domain and are withheld
/// (`saturated_delta`); a record whose delta count is not 24 is withheld
/// (`unsupported_native_rate`) and the DETECTED rate is reported, never
/// assumed; empty slots and dark blocks (drive == 0 when an optical config is
/// carried) are withheld (`artifact_unavailable`).
///
/// This module also builds the sidecar request input (CONTRACTS §4): for a
/// given run set it produces time-ordered, non-overlapping, endpoint-owned
/// segments (<= 5-minute chunks), the `input_revision` (sha256 over the sorted
/// verified object digests in a documented canonical string form), the
/// families list passed in by the caller, and the measured serialized size
/// (every request is kept under the sidecar `MAX_BODY_BYTES`, 8 MiB).
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
    /// PPG v26 native rate: 24 samples per 1-second record (PpgHr.sampleRateHz).
    static let ppgNativeRateHz = 24
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
               extract(epoch from m.end_at)::bigint as end_ts
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
                                     digest: digest, startTs: startTs, endTs: endTs)
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

        var description: String {
            switch self {
            case .unsupportedKind(let k): return "unsupported object kind \(k)"
            case .digestMismatch(let id, let e, let a):
                return "digest_mismatch: object \(id) expected \(e) got \(a)"
            case .decodeFailure(let id, let k, let d):
                return "decode_failure: object \(id) (\(k)): \(d)"
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

    /// Verify + decode one ppgWaveformSample object into per-second PPG records.
    static func decodePpgObject(wire: Data, object: InputObject) throws -> [PpgCodec.Record] {
        let decoded = try verifiedDecodedData(wire: wire, object: object)
        do {
            return try PpgCodec.unpack(decoded)
        } catch {
            throw LoadError.decodeFailure(objectId: object.id, kind: object.objectKind, detail: "\(error)")
        }
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
            let chunkEnd = min(chunkStart + Int64(maxDuration), run.end)
            segments.append(imuSegment(from: chunkStart, to: chunkEnd, timeline: timeline))
            chunkStart = chunkEnd
        }
        return segments
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

    /// One decoded per-second PPG record from an NPB1 `ppgWaveformSample`
    /// object. The wire layout (mirrors `PushBinaryCodec.packPpgRecords` /
    /// `unpackPpgRecords`; CloudWorker cannot import NoopPush, so the exact
    /// layout is re-implemented here like `Npb1ImuDecoder` does for IMU):
    ///   magic "NPB1" (4 B) | formatVersion 1|2 (1 B) | kind 1 (1 B) | u32 count (4 B)
    ///   per record: i64 rowId | i64 ts | [v2: u8 hasIndex + optional i64
    ///   recordIndex] | u8 hasBurst + optional i32 burstIndex | u32 blob length
    ///   | the 48 bytes of 24 little-endian i16 deltas.
    /// NOTE: the absolute optical anchor (`baseCode`) is NOT carried on this
    /// wire — it is a local-DB column on the phone. Every wire record decodes
    /// with `baseCode == nil`, and the PPG builder withholds those seconds with
    /// `missing_ppg_anchor` rather than inventing a level. An anchor can be
    /// attached from a future side channel via `PpgWaveformInput(record:baseCode:)`.
    struct PpgCodec {
        struct Record: Equatable {
            let rowId: Int64
            let ts: Int64
            let recordIndex: Int64?
            let burstIndex: Int32?
            let samples: [Int16]

            init(rowId: Int64, ts: Int64, recordIndex: Int64? = nil,
                 burstIndex: Int32? = nil, samples: [Int16]) {
                self.rowId = rowId
                self.ts = ts
                self.recordIndex = recordIndex
                self.burstIndex = burstIndex
                self.samples = samples
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

            guard Array(try take(4)) == magicBytes else { throw CodecError.notNpb1 }
            let version = try take(1).first ?? 0
            let kind = try take(1).first ?? 0
            guard version == 1 || version == 2 else { throw CodecError.unsupportedVersion(version) }
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
                if version == 2 {
                    let hasIndex = try integer(1)
                    guard hasIndex <= 1 else {
                        throw CodecError.invalidRow(i, "invalid recordIndex presence byte")
                    }
                    if hasIndex == 1 {
                        let value = try int64()
                        guard value >= 0, value <= Int64(UInt32.max) else {
                            throw CodecError.invalidRow(i, "recordIndex out of range")
                        }
                        recordIndex = value
                    }
                }
                let hasBurst = try integer(1)
                guard rowId > 0, hasBurst <= 1 else {
                    throw CodecError.invalidRow(i, "rowId must be positive and burst presence byte valid")
                }
                let burstIndex: Int32? = hasBurst == 1
                    ? Int32(bitPattern: UInt32(truncatingIfNeeded: try integer(4)))
                    : nil
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
                records.append(Record(rowId: rowId, ts: ts, recordIndex: recordIndex,
                                      burstIndex: burstIndex, samples: samples))
            }
            guard offset == bytes.count else {
                throw CodecError.trailingBytes(bytes.count - offset)
            }
            return records
        }
    }

    // MARK: - PPG reconstruction

    /// Side-channel optical configuration (v20-style source/drive/range/offset).
    /// The v26 wire records never carry it; when a caller supplies it, the
    /// config identity folds it in (a change breaks pooling) and a drive == 0
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

        init(rowId: Int64 = 0, ts: Int64, samples: [Int16], burstIndex: Int32? = nil,
             recordIndex: Int64? = nil, baseCode: Int32? = nil, config: PpgOpticalConfig? = nil) {
            self.rowId = rowId
            self.ts = ts
            self.samples = samples
            self.burstIndex = burstIndex
            self.recordIndex = recordIndex
            self.baseCode = baseCode
            self.config = config
        }

        init(wireRecord: PpgCodec.Record, baseCode: Int32? = nil) {
            self.init(rowId: wireRecord.rowId, ts: wireRecord.ts, samples: wireRecord.samples,
                      burstIndex: wireRecord.burstIndex, recordIndex: wireRecord.recordIndex,
                      baseCode: baseCode)
        }

        /// From a WhoopProtocol v26 `PpgWaveformSample` (the shape
        /// `extractHistoricalStreams` persists after verifying the frame CRC).
        init(whoopSample: PpgWaveformSample, rowId: Int64 = 0) {
            self.init(rowId: rowId, ts: Int64(whoopSample.ts),
                      samples: whoopSample.samples.map { Int16(clamping: $0) },
                      burstIndex: whoopSample.burstIndex.map { Int32(clamping: $0) },
                      baseCode: whoopSample.baseCode.map { Int32(clamping: $0) })
        }

        /// The opaque configuration identity that must be constant within a
        /// contiguous PPG run: the per-burst counter plus any side-channel
        /// optical configuration. A change breaks pooling (CONTRACTS §5:
        /// split at source/configuration change).
        var configIdentity: String {
            var parts = [burstIndex.map { "burst=\($0)" } ?? "burst=?"]
            if let config {
                parts.append("srcA=\(config.sourceA.map(String.init) ?? "?")")
                parts.append("drvA=\(config.driveA.map(String.init) ?? "?")")
                parts.append("srcB=\(config.sourceB.map(String.init) ?? "?")")
                parts.append("drvB=\(config.driveB.map(String.init) ?? "?")")
                parts.append("rngA=\(config.rangeA.map(String.init) ?? "?")")
                parts.append("offA=\(config.offsetA.map(String.init) ?? "?")")
                parts.append("rngB=\(config.rangeB.map(String.init) ?? "?")")
                parts.append("offB=\(config.offsetB.map(String.init) ?? "?")")
            }
            return parts.joined(separator: ";")
        }
    }

    /// One reconstructed second of PPG: either emitted absolute samples or a
    /// withheld reason. Withheld seconds are never sent as amplitudes.
    struct PpgSecond: Equatable {
        let ts: Int64
        let configIdentity: String
        let burstIndex: Int32?
        /// 24 absolute ADC counts when emitted; empty when withheld.
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
    }

    /// Reconstruct one record into a second. Order of resolution (fail-closed):
    /// empty slot → `artifact_unavailable`; delta count ≠ 24 →
    /// `unsupported_native_rate` (detected, never assumed); drive == 0 dark
    /// block → `artifact_unavailable`; missing anchor → `missing_ppg_anchor`;
    /// any i16-rail delta or a reconstruction outside ±2^19 →
    /// `saturated_delta`; otherwise exactly 24 absolute samples are emitted.
    ///
    /// The anchor + 24 deltas reconstruct to 25 points (sample 0 = baseCode,
    /// WhoopProtocol.ppgWaveformAbsolute). The 25th point sits at
    /// `ts + 24/24 = ts + 1`, the grid position the NEXT second's record owns;
    /// emitting it would put two samples on one grid point. So each second
    /// emits exactly `points[0..<24]` at `ts + i/24`, matching CONTRACTS
    /// `sample_count_per_second: 24` with no boundary duplication.
    static func reconstructSecond(_ record: PpgWaveformInput) -> PpgSecond {
        let identity = record.configIdentity
        let dark = record.config?.isDark ?? false
        if record.samples.isEmpty {
            return PpgSecond(ts: record.ts, configIdentity: identity, burstIndex: record.burstIndex,
                             samples: [], withheldReason: reasonArtifactUnavailable,
                             saturatedDelta: false, outOfDomain: false,
                             deltaCount: 0, darkBlock: dark)
        }
        if record.samples.count != ppgDeltasPerRecord {
            return PpgSecond(ts: record.ts, configIdentity: identity, burstIndex: record.burstIndex,
                             samples: [], withheldReason: reasonUnsupportedNativeRate,
                             saturatedDelta: false, outOfDomain: false,
                             deltaCount: record.samples.count, darkBlock: dark)
        }
        if dark {
            return PpgSecond(ts: record.ts, configIdentity: identity, burstIndex: record.burstIndex,
                             samples: [], withheldReason: reasonArtifactUnavailable,
                             saturatedDelta: false, outOfDomain: false,
                             deltaCount: record.samples.count, darkBlock: true)
        }
        guard let base = record.baseCode else {
            return PpgSecond(ts: record.ts, configIdentity: identity, burstIndex: record.burstIndex,
                             samples: [], withheldReason: reasonMissingPpgAnchor,
                             saturatedDelta: false, outOfDomain: false,
                             deltaCount: record.samples.count, darkBlock: false)
        }
        let deltas = record.samples.map(Int.init)
        let saturated = deltas.contains { $0 == Int(Int16.min) || $0 == Int(Int16.max) }
        // The shared reconstruction (WhoopProtocol.ppgWaveformAbsolute) — the
        // same math the rest of the repo pins against Kotlin.
        guard let absolute = ppgWaveformAbsolute(baseCode: Int(base), deltas: deltas) else {
            // Unreachable with a non-nil base; fail closed rather than emit.
            return PpgSecond(ts: record.ts, configIdentity: identity, burstIndex: record.burstIndex,
                             samples: [], withheldReason: reasonMissingPpgAnchor,
                             saturatedDelta: false, outOfDomain: false,
                             deltaCount: record.samples.count, darkBlock: false)
        }
        let outOfDomain = absolute.contains { $0 < opticalSampleMin || $0 > opticalSampleMax }
        if saturated || outOfDomain {
            return PpgSecond(ts: record.ts, configIdentity: identity, burstIndex: record.burstIndex,
                             samples: [], withheldReason: reasonSaturatedDelta,
                             saturatedDelta: saturated, outOfDomain: outOfDomain,
                             deltaCount: record.samples.count, darkBlock: false)
        }
        let emitted = absolute.prefix(ppgNativeRateHz).map { Int32($0) }
        return PpgSecond(ts: record.ts, configIdentity: identity, burstIndex: record.burstIndex,
                         samples: Array(emitted), withheldReason: nil,
                         saturatedDelta: false, outOfDomain: false,
                         deltaCount: record.samples.count, darkBlock: false)
    }

    /// A contiguous PPG run over EMITTED seconds, with a single config
    /// identity. Runs break at missing seconds (a withheld second is a data
    /// gap — never bridged) and at any config-identity change.
    struct PpgRun: Equatable {
        let start: Int64
        let end: Int64
        let configIdentity: String
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
        /// Contiguous runs over emitted seconds, one config identity each.
        let runs: [PpgRun]
        /// 24 when every unique record carried 24 deltas; nil otherwise (mixed
        /// or unknown — never assumed).
        let nativeRateHz: Int?
    }

    /// Deterministically merge records (from one or more objects) into one
    /// record per second: identical duplicates collapse, conflicting duplicates
    /// keep the first by capture precedence `(rowId, recordIndex, burstIndex,
    /// ts)` and are reported — never averaged.
    static func mergePpgRecords(_ records: [PpgWaveformInput]) -> (merged: [PpgWaveformInput],
                                                                   identical: Int,
                                                                   conflicting: [Int64]) {
        // Observation identity excludes rowId: the same second re-uploaded in a
        // second object carries the same samples/burst/recordIndex/anchor but a
        // different storage row id, and must still count as an identical
        // duplicate. rowId is used only as the deterministic CAPTURE precedence
        // for conflicting observations (older capture wins; never averaged).
        func precedence(_ r: PpgWaveformInput) -> (Int64, Int64, Int32, Int64) {
            (r.rowId, r.recordIndex ?? Int64.max, r.burstIndex ?? Int32.max, r.ts)
        }
        func observationKey(_ r: PpgWaveformInput) -> String {
            "ts=\(r.ts);s=\(r.samples);b=\(r.burstIndex ?? -1);ri=\(r.recordIndex ?? -1);base=\(r.baseCode ?? -1);cfg=\(r.configIdentity)"
        }
        var byTs: [Int64: (record: PpgWaveformInput, identicalCount: Int)] = [:]
        var conflicting: [Int64] = []
        var identical = 0
        for record in records {
            if let existing = byTs[record.ts] {
                if observationKey(existing.record) == observationKey(record) {
                    identical += 1
                } else {
                    if precedence(record) < precedence(existing.record) {
                        byTs[record.ts] = (record, 0)
                    }
                    if !conflicting.contains(record.ts) {
                        conflicting.append(record.ts)
                    }
                }
            } else {
                byTs[record.ts] = (record, 0)
            }
        }
        let merged = byTs.keys.sorted().map { byTs[$0]!.record }
        return (merged, identical, conflicting)
    }

    /// Reconstruct merged records into seconds, runs and diagnostics.
    static func reconstructPPG(records: [PpgWaveformInput]) -> PpgReconstruction {
        let (merged, _, conflicting) = mergePpgRecords(records)
        let seconds = merged.map { reconstructSecond($0) }
        var reasonCounts: [String: Int] = [:]
        for second in seconds {
            if let reason = second.withheldReason {
                reasonCounts[reason, default: 0] += 1
            }
        }
        var detected: [Int: Int] = [:]
        for second in seconds { detected[second.deltaCount, default: 0] += 1 }
        let allAt24 = !seconds.isEmpty && detected.keys.allSatisfy { $0 == ppgDeltasPerRecord }
        let runs = ppgRuns(seconds: seconds)
        return PpgReconstruction(seconds: seconds, reasonCounts: reasonCounts,
                                 detectedDeltaCounts: detected,
                                 conflictingDuplicateSeconds: conflicting,
                                 runs: runs,
                                 nativeRateHz: allAt24 ? ppgNativeRateHz : nil)
    }

    /// Contiguous runs over emitted seconds; a withheld second or a config
    /// identity change breaks the run.
    static func ppgRuns(seconds: [PpgSecond]) -> [PpgRun] {
        let emitted = seconds.filter { $0.withheldReason == nil }
        var runs: [PpgRun] = []
        guard let first = emitted.first else { return runs }
        var start = first.ts
        var prev = first.ts
        var identity = first.configIdentity
        for second in emitted.dropFirst() {
            if second.ts != prev + 1 || second.configIdentity != identity {
                runs.append(PpgRun(start: start, end: prev + 1, configIdentity: identity))
                start = second.ts
                identity = second.configIdentity
            }
            prev = second.ts
        }
        runs.append(PpgRun(start: start, end: prev + 1, configIdentity: identity))
        return runs
    }

    // MARK: - PPG segments

    /// One endpoint-owned PPG segment (CONTRACTS §4): `samples` holds
    /// `durationS * 24` absolute ADC counts; sample j is at
    /// `startUnix + j/24`. Consecutive segments share no endpoint sample.
    struct PpgSegment: Equatable {
        let startUnix: Int64
        let durationS: Int
        let samples: [Int32]
        /// Always true here: a run carries a single config identity by
        /// construction, so every segment's configuration is stable.
        let configStable: Bool
    }

    /// Split a PPG run into non-overlapping segments of at most `maxDuration`
    /// seconds at whole-second boundaries, endpoint-owned.
    static func ppgSegments(run: PpgRun, secondsByTs: [Int64: PpgSecond],
                            maxDuration: Int = maxSegmentDurationSeconds) -> [PpgSegment] {
        guard maxDuration > 0 else { return [] }
        var segments: [PpgSegment] = []
        var chunkStart = run.start
        while chunkStart < run.end {
            let chunkEnd = min(chunkStart + Int64(maxDuration), run.end)
            var samples: [Int32] = []
            for t in chunkStart..<chunkEnd {
                if let second = secondsByTs[t], second.withheldReason == nil {
                    samples.append(contentsOf: second.samples)
                }
            }
            if !samples.isEmpty {
                segments.append(PpgSegment(startUnix: chunkStart,
                                           durationS: Int(chunkEnd - chunkStart),
                                           samples: samples, configStable: true))
            }
            chunkStart = chunkEnd
        }
        return segments
    }

    // MARK: - Sidecar request input (CONTRACTS §4)

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
            var input: [String: Any] = [
                "schema_version": schemaVersion,
                "device": ["id": deviceID, "family": deviceFamily],
                "input_revision": inputRevision,
                "day_utc": dayUTC,
                "watch_side": watchSide,
                "device_orientation": deviceOrientation,
                "families": families,
            ]
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
                         "sample_count_per_second": SensorBiomarkerInputs.ppgNativeRateHz,
                         "config": ["stable": $0.configStable]]
                    },
                ]
            }
            return input
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
    }

    private static func serializedData(_ input: SensorBiomarkerInput) throws -> Data {
        try JSONSerialization.data(withJSONObject: input.jsonObject(), options: [.sortedKeys])
    }

    /// Measured serialized size of a request input.
    static func serializedSize(_ input: SensorBiomarkerInput) throws -> Int {
        try serializedData(input).count
    }

    /// Build the request(s) for a run set (one or more IMU runs and/or PPG
    /// runs of a device-day): endpoint-owned segments of at most
    /// `maxDuration` seconds are packed in time order into requests whose
    /// measured serialized size stays under `maxBodyBytes`. The lane chooses
    /// which runs form one chunk-group (algorithm-context overlap is its
    /// concern, not this module's); this module only guarantees contiguous,
    /// non-overlapping segments and the 8 MiB budget.
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
                              maxDuration: Int = maxSegmentDurationSeconds,
                              maxBodyBytes: Int = bodyBudgetBytes) throws -> [BuiltRequest] {
        guard maxDuration > 0, maxBodyBytes > 0 else { return [] }
        let revision = inputRevision(objects: objects)
        // IMU first, then PPG — each modality's segments are internally
        // time-ordered and non-overlapping by construction.
        var imuSegs: [ImuSegment] = []
        for run in imuRuns { imuSegs.append(contentsOf: imuSegments(run: run, timeline: imuTimeline, maxDuration: maxDuration)) }
        var ppgSegs: [PpgSegment] = []
        for run in ppgRuns { ppgSegs.append(contentsOf: ppgSegments(run: run, secondsByTs: ppgSecondsByTs, maxDuration: maxDuration)) }

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
            for run in imuRuns { imuSegs.append(contentsOf: imuSegments(run: run, timeline: imuTimeline, maxDuration: duration)) }
            ppgSegs = []
            for run in ppgRuns { ppgSegs.append(contentsOf: ppgSegments(run: run, secondsByTs: ppgSecondsByTs, maxDuration: duration)) }
        }

        // Pack segments greedily in time order into budget-bounded requests.
        typealias Kinded = (kind: String, start: Int64, end: Int64, imu: ImuSegment?, ppg: PpgSegment?)
        var kinded: [Kinded] = []
        for segment in imuSegs {
            kinded.append(("imu", segment.startUnix, segment.startUnix + Int64(segment.durationS), segment, nil))
        }
        for segment in ppgSegs {
            kinded.append(("ppg", segment.startUnix, segment.startUnix + Int64(segment.durationS), nil, segment))
        }
        kinded.sort { ($0.start, $0.kind) < ($1.start, $1.kind) }

        var requests: [BuiltRequest] = []
        var pendingImu: [ImuSegment] = []
        var pendingPpg: [PpgSegment] = []
        var requestStart: Int64? = nil
        var requestEnd: Int64? = nil

        func closeRequest() throws {
            guard let start = requestStart, let end = requestEnd else { return }
            let input = SensorBiomarkerInput(
                schemaVersion: 1, deviceID: deviceID, deviceFamily: deviceFamily,
                inputRevision: revision, dayUTC: dayUTC,
                imu: pendingImu.isEmpty ? nil : SensorBiomarkerInput.ImuSection(
                    samplingRateHz: imuNativeRateHz,
                    units: ["accel": "g", "gyro": "deg/s"],
                    segments: pendingImu),
                ppg: pendingPpg.isEmpty ? nil : SensorBiomarkerInput.PpgSection(
                    nativeRateHz: ppgNativeRateHz, units: "adc_counts", segments: pendingPpg),
                watchSide: watchSide, deviceOrientation: deviceOrientation, families: families)
            let interval = isoInterval(start: start, end: end)
            let size = try serializedSize(input)
            requests.append(BuiltRequest(input: input, intervalStartUTC: interval.start,
                                         intervalEndUTC: interval.end, serializedSizeBytes: size))
            pendingImu = []
            pendingPpg = []
            requestStart = nil
            requestEnd = nil
        }

        for item in kinded {
            // Measure the candidate request with this segment added.
            let candidateImu = item.kind == "imu" ? pendingImu + [item.imu!] : pendingImu
            let candidatePpg = item.kind == "ppg" ? pendingPpg + [item.ppg!] : pendingPpg
            let candidate = SensorBiomarkerInput(
                schemaVersion: 1, deviceID: deviceID, deviceFamily: deviceFamily,
                inputRevision: revision, dayUTC: dayUTC,
                imu: candidateImu.isEmpty ? nil : SensorBiomarkerInput.ImuSection(
                    samplingRateHz: imuNativeRateHz,
                    units: ["accel": "g", "gyro": "deg/s"],
                    segments: candidateImu),
                ppg: candidatePpg.isEmpty ? nil : SensorBiomarkerInput.PpgSection(
                    nativeRateHz: ppgNativeRateHz, units: "adc_counts", segments: candidatePpg),
                watchSide: watchSide, deviceOrientation: deviceOrientation, families: families)
            let size = try serializedSize(candidate)
            if !pendingImu.isEmpty || !pendingPpg.isEmpty {
                if size > maxBodyBytes {
                    try closeRequest()
                }
            }
            if item.kind == "imu" { pendingImu.append(item.imu!) } else { pendingPpg.append(item.ppg!) }
            requestStart = min(requestStart ?? item.start, item.start)
            requestEnd = max(requestEnd ?? item.end, item.end)
        }
        try closeRequest()
        return requests
    }

    /// A cheap upper bound for the single-segment budget guard: 12 JSON
    /// numbers per IMU sample (6 values with separators) at a generous 16 B
    /// each, plus the ADC counts at 12 B each.
    static func estimatedBytes(_ segment: ImuSegment) -> Int {
        let imuNumbers = segment.accelG.count * 6
        return imuNumbers * 16 + segment.startUnix.description.count + 32
    }

    static func estimatedBytes(_ segment: PpgSegment) -> Int {
        segment.samples.count * 12 + segment.startUnix.description.count + 32
    }
}

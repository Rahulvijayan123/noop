import Foundation

/// Decoder for NPB1 `rawImuSession` objects (PushBinaryCodec kind 4) in the
/// worker.
///
/// CloudWorker cannot import NoopPush (it links StrandAnalytics/WhoopProtocol/
/// WhoopStore only), so the exact wire layout is re-implemented here and pinned
/// by a golden test against the shared `golden_imu_*.json` fixtures (C9).
///
/// Wire layout, all little-endian (mirrors `PushBinaryCodec.packImuRecords`,
/// Packages/NoopPush/Sources/NoopPush/PushBinaryCodec.swift:191-207):
///   magic "NPB1" (4 B) | formatVersion 1 (1 B) | kind 4 (1 B) | u32 count (4 B)
///   per record: i64 rowId | i64 ts | u32 blob length | 1200 B of columns
/// where the columns blob is 600 little-endian i16, axis-major: 100 samples of
/// ax, then ay, az, gx, gy, gz (one second of 100 Hz six-axis IMU). `rowId`
/// mirrors `ts` (epoch seconds) because the file store keys records by
/// timestamp, not by SQLite rowid (PushModels.swift:128-135).
///
/// The decoder is strict: every length is bounds-checked, the blob length must
/// equal the required 1200 bytes, and trailing bytes are rejected. A corrupt
/// or truncated object throws instead of yielding partial records.
enum Npb1ImuDecoder {
    static let magicBytes: [UInt8] = [0x4E, 0x50, 0x42, 0x31]  // "NPB1"
    static let formatVersion: UInt8 = 1
    static let rawImuSessionKind: UInt8 = 4

    /// 100 samples/second x 6 axes, axis-major i16 LE.
    static let columnsPerRecord = 600
    static let samplesPerSecond = 100
    static let recordColumnsBytes = columnsPerRecord * 2       // 1200
    static let headerBytes = 10                                // 4 + 1 + 1 + 4
    static let recordFixedBytes = 20                           // rowId 8 + ts 8 + len 4
    static let recordBytes = recordFixedBytes + recordColumnsBytes  // 1220

    /// One decoded second of raw IMU.
    struct Record: Equatable {
        let rowId: Int64
        let ts: Int64
        /// 600 i16, axis-major (ax[100], ay[100], az[100], gx[100], gy[100], gz[100]).
        let columns: [Int16]
    }

    enum DecodeError: Error, CustomStringConvertible, Equatable {
        case notNpb1
        case unsupportedVersion(UInt8)
        case unsupportedKind(UInt8)
        case emptyObject
        case invalidCount(Int)
        case truncated(String)
        case malformedRecord(Int, String)
        case unexpectedColumnCount(Int)
        case trailingBytes(Int)

        var description: String {
            switch self {
            case .notNpb1: return "NPB1 magic mismatch"
            case .unsupportedVersion(let v): return "unsupported NPB1 formatVersion \(v)"
            case .unsupportedKind(let k): return "unsupported NPB1 kind \(k) (expected rawImuSession 4)"
            case .emptyObject: return "NPB1 object contains no records"
            case .invalidCount(let n): return "invalid NPB1 record count \(n)"
            case .truncated(let detail): return "truncated NPB1 object: \(detail)"
            case .malformedRecord(let i, let detail): return "malformed NPB1 record \(i): \(detail)"
            case .unexpectedColumnCount(let n): return "NPB1 record column blob is \(n) bytes, expected 1200"
            case .trailingBytes(let n): return "NPB1 object has \(n) trailing bytes"
            }
        }
    }

    static func decode(_ data: Data) throws -> [Record] {
        let bytes = [UInt8](data)
        var offset = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= bytes.count - offset else {
                throw DecodeError.truncated("need \(count) bytes at offset \(offset), have \(bytes.count - offset)")
            }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }
        func u32() throws -> UInt32 {
            let slice = try take(4)
            return slice.enumerated().reduce(0) { $0 | UInt32($1.element) << ($1.offset * 8) }
        }
        func u64() throws -> UInt64 {
            let slice = try take(8)
            return slice.enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }

        // Header: magic (4) | formatVersion (1) | kind (1) | u32 count (4).
        guard Array(try take(4)) == magicBytes else { throw DecodeError.notNpb1 }
        let version = try take(1).first ?? 0
        let kind = try take(1).first ?? 0
        guard version == formatVersion else { throw DecodeError.unsupportedVersion(version) }
        guard kind == rawImuSessionKind else { throw DecodeError.unsupportedKind(kind) }
        let count = Int(try u32())
        guard count > 0 else { throw DecodeError.emptyObject }
        // Exact-size contract: the object must contain exactly `count` records.
        let expectedTotal = headerBytes + count * recordBytes
        guard bytes.count == expectedTotal else {
            if bytes.count < expectedTotal {
                throw DecodeError.truncated("expected \(expectedTotal) bytes, have \(bytes.count)")
            }
            throw DecodeError.trailingBytes(bytes.count - expectedTotal)
        }

        var records: [Record] = []
        records.reserveCapacity(count)
        for i in 0..<count {
            let rowId = Int64(bitPattern: try u64())
            let ts = Int64(bitPattern: try u64())
            let length = Int(try u32())
            guard length == recordColumnsBytes else {
                throw DecodeError.unexpectedColumnCount(length)
            }
            guard rowId > 0 else {
                throw DecodeError.malformedRecord(i, "rowId must be positive")
            }
            let blob = try take(recordColumnsBytes)
            var columns = [Int16](repeating: 0, count: columnsPerRecord)
            for c in 0..<columnsPerRecord {
                let lo = blob[blob.startIndex + c * 2]
                let hi = blob[blob.startIndex + c * 2 + 1]
                columns[c] = Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))
            }
            records.append(Record(rowId: rowId, ts: ts, columns: columns))
        }
        return records
    }

    /// Re-packs records into the exact wire layout (mirrors
    /// `PushBinaryCodec.packImuRecords`). Used by the golden round-trip test to
    /// build NPB1 bytes from the shared fixture frames.
    static func pack(records: [Record]) throws -> Data {
        guard !records.isEmpty else { throw DecodeError.emptyObject }
        var out = Data(capacity: headerBytes + records.count * recordBytes)
        out.append(contentsOf: magicBytes)
        out.append(formatVersion)
        out.append(rawImuSessionKind)
        appendU32(UInt32(records.count), to: &out)
        for record in records {
            guard record.columns.count == columnsPerRecord else {
                throw DecodeError.unexpectedColumnCount(record.columns.count)
            }
            appendI64(record.rowId, to: &out)
            appendI64(record.ts, to: &out)
            appendU32(UInt32(recordColumnsBytes), to: &out)
            for value in record.columns {
                let le = value.littleEndian
                withUnsafeBytes(of: le) { out.append(contentsOf: $0) }
            }
        }
        return out
    }

    private static func appendU32(_ value: UInt32, to out: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    private static func appendI64(_ value: Int64, to out: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }
}

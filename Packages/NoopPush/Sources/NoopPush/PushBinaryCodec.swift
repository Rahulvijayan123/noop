import Foundation
import CryptoKit

/// Platform-neutral packed payload for `bin_gzip_noop_push_v1` / `protobuf_zstd_noop_push_v1`.
public enum PushBinaryCodec {
    public static let magic = Data("NPB1".utf8)
    public static let formatVersion: UInt8 = 1
    public static let ppgIdentityFormatVersion: UInt8 = 2
    /// Protocol 1.5 PPG (schema 3): format 2 plus the optical anchor, the record clock source, the raw
    /// header phase and flags, and the encoder's saturation flags. See `ppgRecordFields`.
    public static let ppgAnchorFormatVersion: UInt8 = 3
    /// Saturation flag bit 0: at least one delta sits at an i16 rail, where the strap's encoder clamps,
    /// so the window reconstructs only approximately. The other bits are reserved and must be zero.
    public static let ppgSampleFlagDeltaAtRail: UInt8 = 0x01

    public enum Kind: UInt8 {
        case ppgWaveformSample = 1
        case v18AuxSample = 2
        case rawBatch = 3
        case rawImuSession = 4
    }

    /// 100 samples/second × 6 axes, axis-major i16 LE — the record layout ImuSessionFileStore writes.
    public static let imuColumnsPerRecord = 600
    public static let imuRecordPayloadBytes = imuColumnsPerRecord * 2

    public static func kind(for table: PushBinaryTable) -> Kind {
        switch table {
        case .ppgWaveformSample: return .ppgWaveformSample
        case .v18AuxSample: return .v18AuxSample
        case .rawBatch: return .rawBatch
        case .rawImuSession: return .rawImuSession
        }
    }

    public static func pack(table: PushBinaryTable, rows: [PushBinaryRow], ppgIdentityV2: Bool = false,
                            ppgAnchorV3: Bool = false, v18IdentityV2: Bool = false) throws -> Data {
        guard !rows.isEmpty else { throw PushProtocolException("binary object must contain a row") }
        switch table {
        case .ppgWaveformSample:
            let records = try rows.map { row -> PushPpgWaveformRecord in
                guard case .ppgWaveform(let record) = row else {
                    throw PushProtocolException("binary row kind mismatch")
                }
                return record
            }
            return try packPpgRecords(records, format: ppgFormat(identityV2: ppgIdentityV2, anchorV3: ppgAnchorV3))
        case .v18AuxSample:
            let records = try rows.map { row -> PushV18AuxRecord in
                guard case .v18Aux(let record) = row else {
                    throw PushProtocolException("binary row kind mismatch")
                }
                return record
            }
            return try packV18Records(records, identityV2: v18IdentityV2)
        case .rawBatch:
            guard rows.count == 1, case .rawBatch(let record) = rows[0] else {
                throw PushProtocolException("rawBatch upload must contain exactly one batch row")
            }
            return try packRawBatch(record)
        case .rawImuSession:
            let records = try rows.map { row -> PushRawImuRecord in
                guard case .rawImuSession(let record) = row else {
                    throw PushProtocolException("binary row kind mismatch")
                }
                return record
            }
            return try packImuRecords(records)
        }
    }

    /// Exact packed size of the header for a table, without packing. Counted kinds carry a u32
    /// record count after the 6-byte magic/version/kind header; rawBatch does not.
    public static func packedHeaderSize(for table: PushBinaryTable) -> Int {
        switch table {
        case .rawBatch: return 6
        case .ppgWaveformSample, .v18AuxSample, .rawImuSession: return 10
        }
    }

    /// Exact packed size of one row, without packing. Lets batch selection run O(n) instead of
    /// re-packing the growing candidate set per row.
    public static func packedRowSize(_ row: PushBinaryRow, ppgIdentityV2: Bool = false,
                                      ppgAnchorV3: Bool = false, v18IdentityV2: Bool = false) throws -> Int {
        switch row {
        case .ppgWaveform(let record):
            var size = 8 + 8 + 1 + (record.burstIndex != nil ? 4 : 0) + 4 + record.samples.count
            if ppgIdentityV2 || ppgAnchorV3 { size += record.recordIndex == nil ? 1 : 9 }
            if ppgAnchorV3 {
                size += (record.anchor == nil ? 1 : 5) + 1 + (record.subsecQ15 == nil ? 1 : 3)
                    + (record.frontEndFlags == nil ? 1 : 2) + 1
            }
            return size
        case .v18Aux(let record):
            return 8 + 8 + 4 + record.fields.count + (v18IdentityV2 ? (record.recordIndex == nil ? 1 : 9) : 0)
        case .rawImuSession(let record):
            guard record.columns.count == imuRecordPayloadBytes else {
                throw PushProtocolException("rawImuSession record must carry \(imuColumnsPerRecord) i16 columns")
            }
            return 8 + 8 + 4 + record.columns.count
        case .rawBatch(let record):
            return 2 + record.batchId.utf8.count + 8 * 5 + 4 + 4 + 4 + record.framesBlob.count
        }
    }

    /// The NPB1 format a PPG object uses: 3 once protocol 1.5 is negotiated, 2 at 1.3/1.4, else 1.
    public static func ppgFormat(identityV2: Bool, anchorV3: Bool) -> UInt8 {
        anchorV3 ? ppgAnchorFormatVersion : (identityV2 ? ppgIdentityFormatVersion : formatVersion)
    }

    /// Bit 0 when any complete little-endian i16 pair sits at a rail. Derived from the bytes the record
    /// carries, so every decoder recomputes it; a mismatch means a broken encoder, never data.
    public static func ppgSampleFlags(_ samples: Data) -> UInt8 {
        samples.withUnsafeBytes { raw -> UInt8 in
            var i = 0
            while i + 1 < raw.count {
                let value = UInt16(raw[i]) | UInt16(raw[i + 1]) << 8
                if value == 0x7FFF || value == 0x8000 { return ppgSampleFlagDeltaAtRail }
                i += 2
            }
            return 0
        }
    }

    /// One PPG record up to (not including) its u32 sample-blob length, all little-endian:
    ///
    ///     i64 rowId | i64 ts
    ///     [format >= 2] u8 hasRecordIndex + [i64 recordIndex]
    ///     u8 hasBurst + [i32 burstIndex]
    ///     [format 3]    u8 hasAnchor + [u32 anchor] | u8 clockSource
    ///                   | u8 hasSubsec + [u16 subsecQ15] | u8 hasFlags + [u8 frontEndFlags] | u8 sampleFlags
    ///
    /// The in-memory packer and the streaming encoder both write through here, so the two cannot drift.
    static func ppgRecordFields(_ record: PushPpgWaveformRecord, format: UInt8) throws -> Data {
        guard format >= ppgIdentityFormatVersion || record.recordIndex == nil else {
            throw PushProtocolException("PPG record identity requires negotiated protocol 1.3")
        }
        guard format >= ppgAnchorFormatVersion || !record.carriesAnchorFormatMembers else {
            throw PushProtocolException("PPG anchor members require negotiated protocol 1.5")
        }
        var out = Data(capacity: 48)
        appendI64(record.rowId, to: &out)
        appendI64(record.ts, to: &out)
        if format >= ppgIdentityFormatVersion {
            if let index = record.recordIndex {
                // The strap's record counter is a u32; the decoders, the receiver and the worker all refuse more.
                guard (0...Int64(UInt32.max)).contains(index) else { throw PushProtocolException("invalid PPG record index") }
                out.append(1)
                appendI64(index, to: &out)
            } else { out.append(0) }
        }
        if let burstIndex = record.burstIndex {
            out.append(1)
            appendI32(burstIndex, to: &out)
        } else {
            out.append(0)
        }
        if format >= ppgAnchorFormatVersion {
            if let anchor = record.anchor { out.append(1); appendLE(anchor, to: &out) } else { out.append(0) }
            out.append(record.clockSource.rawValue)
            if let subsec = record.subsecQ15 { out.append(1); appendLE(subsec, to: &out) } else { out.append(0) }
            if let flags = record.frontEndFlags { out.append(1); out.append(flags) } else { out.append(0) }
            out.append(ppgSampleFlags(record.samples))
        }
        return out
    }

    private static func packPpgRecords(_ records: [PushPpgWaveformRecord], format: UInt8) throws -> Data {
        var out = header(kind: .ppgWaveformSample)
        out[4] = format
        appendU32(Int32(records.count), to: &out)
        for record in records {
            out.append(try ppgRecordFields(record, format: format))
            try appendBlob(record.samples, to: &out)
        }
        return out
    }

    private static func packV18Records(_ records: [PushV18AuxRecord], identityV2: Bool) throws -> Data {
        guard identityV2 || records.allSatisfy({ $0.recordIndex == nil }) else {
            throw PushProtocolException("auxiliary record identity requires negotiated protocol 1.4")
        }
        var out = header(kind: .v18AuxSample)
        if identityV2 { out[4] = 2 }
        appendU32(Int32(records.count), to: &out)
        for record in records {
            appendI64(record.rowId, to: &out)
            appendI64(record.ts, to: &out)
            if identityV2 {
                if let index = record.recordIndex {
                    guard (0...Int64(UInt32.max)).contains(index) else { throw PushProtocolException("invalid auxiliary record index") }
                    out.append(1); appendI64(index, to: &out)
                } else { out.append(0) }
            }
            try appendBlob(record.fields, to: &out)
        }
        return out
    }


    /// Reads v1 PPG, identity-preserving v2 PPG and anchor-carrying v3 PPG. Does not infer channel,
    /// anchor or sample time: members a format cannot carry decode as absent.
    public static func unpackPpgRecords(_ bytes: Data) throws -> [PushPpgWaveformRecord] {
        guard bytes.count <= PushProtocolLimits.maxObjectDecodedBytes else {
            throw PushProtocolException("PPG object exceeds decoded limit")
        }
        let data = [UInt8](bytes)
        var offset = 0
        func take(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, count <= data.count - offset else {
                throw PushProtocolException("Truncated PPG object")
            }
            defer { offset += count }
            return data[offset..<(offset + count)]
        }
        func integer(_ width: Int) throws -> UInt64 {
            try take(width).enumerated().reduce(0) { $0 | UInt64($1.element) << ($1.offset * 8) }
        }
        guard Data(try take(4)) == magic else { throw PushProtocolException("Invalid PPG magic") }
        let version = try integer(1)
        guard (1...3).contains(version), try integer(1) == UInt64(Kind.ppgWaveformSample.rawValue) else {
            throw PushProtocolException("Unsupported PPG object version or kind")
        }
        let count = Int(try integer(4))
        guard count > 0, count <= PushProtocolLimits.maxRecords else {
            throw PushProtocolException("Invalid PPG record count")
        }
        var records: [PushPpgWaveformRecord] = []
        for _ in 0..<count {
            let rowId = Int64(bitPattern: try integer(8))
            let ts = Int64(bitPattern: try integer(8))
            var index: Int64? = nil
            if version >= 2 {
                let hasIndex = try integer(1)
                guard hasIndex <= 1 else { throw PushProtocolException("Invalid PPG record") }
                if hasIndex == 1 {
                    let value = Int64(bitPattern: try integer(8))
                    guard value >= 0, (0...Int64(UInt32.max)).contains(value) else {
                        throw PushProtocolException("Invalid PPG recordIndex")
                    }
                    index = value
                }
            }
            let hasBurst = try integer(1)
            guard rowId > 0, hasBurst <= 1 else { throw PushProtocolException("Invalid PPG record") }
            let burst = hasBurst == 1 ? Int32(bitPattern: UInt32(try integer(4))) : nil
            var anchor: UInt32? = nil, clock = PushPpgClockSource.unknown
            var subsec: UInt16? = nil, frontEnd: UInt8? = nil, sampleFlags: UInt8 = 0
            if version == 3 {
                let hasAnchor = try integer(1)
                guard hasAnchor <= 1 else { throw PushProtocolException("Invalid PPG anchor presence") }
                if hasAnchor == 1 { anchor = UInt32(try integer(4)) }
                guard let source = PushPpgClockSource(rawValue: UInt8(try integer(1))) else {
                    throw PushProtocolException("Unsupported PPG clock source")
                }
                clock = source
                let hasSubsec = try integer(1)
                guard hasSubsec <= 1 else { throw PushProtocolException("Invalid PPG subsec presence") }
                if hasSubsec == 1 { subsec = UInt16(try integer(2)) }
                let hasFlags = try integer(1)
                guard hasFlags <= 1 else { throw PushProtocolException("Invalid PPG flags presence") }
                if hasFlags == 1 { frontEnd = UInt8(try integer(1)) }
                sampleFlags = UInt8(try integer(1))
            }
            let samples = Data(try take(Int(try integer(4))))
            if version == 3, sampleFlags != ppgSampleFlags(samples) {
                throw PushProtocolException("PPG saturation flags disagree with the deltas")
            }
            records.append(PushPpgWaveformRecord(rowId: rowId, ts: ts, burstIndex: burst,
                samples: samples, recordIndex: index, anchor: anchor, clockSource: clock,
                subsecQ15: subsec, frontEndFlags: frontEnd))
        }
        guard offset == data.count else { throw PushProtocolException("Trailing PPG object bytes") }
        return records
    }

    private static func packRawBatch(_ record: PushRawBatchRecord) throws -> Data {
        var out = header(kind: .rawBatch)
        try appendUtf8(record.batchId, to: &out)
        appendI64(record.capturedAt, to: &out)
        appendI64(record.deviceClockRef, to: &out)
        appendI64(record.wallClockRef, to: &out)
        appendI64(record.startTs, to: &out)
        appendI64(record.endTs, to: &out)
        appendI32(record.frameCount, to: &out)
        appendI32(record.byteSize, to: &out)
        try appendBlob(record.framesBlob, to: &out)
        return out
    }

    private static func packImuRecords(_ records: [PushRawImuRecord]) throws -> Data {
        var out = header(kind: .rawImuSession)
        appendU32(Int32(records.count), to: &out)
        for record in records {
            guard record.columns.count == imuRecordPayloadBytes else {
                throw PushProtocolException("rawImuSession record must carry \(imuColumnsPerRecord) i16 columns")
            }
            appendI64(record.rowId, to: &out)
            appendI64(record.ts, to: &out)
            try appendBlob(record.columns, to: &out)
        }
        return out
    }

    private static func header(kind: Kind) -> Data {
        var out = Data(capacity: 6)
        out.append(magic)
        out.append(formatVersion)
        out.append(kind.rawValue)
        return out
    }

    private static func appendBlob(_ blob: Data, to out: inout Data) throws {
        guard blob.count <= PushProtocolLimits.maxBodyBytes else {
            throw PushProtocolException("binary blob exceeds decoded limit")
        }
        appendU32(Int32(blob.count), to: &out)
        out.append(blob)
    }

    private static func appendUtf8(_ value: String, to out: inout Data) throws {
        let bytes = Data(value.utf8)
        guard bytes.count <= Int(UInt16.max) else {
            throw PushProtocolException("binary string exceeds limit")
        }
        var length = UInt16(bytes.count).littleEndian
        withUnsafeBytes(of: &length) { out.append(contentsOf: $0) }
        out.append(bytes)
    }

    private static func appendI32(_ value: Int32, to out: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    private static func appendU32(_ value: Int32, to out: inout Data) {
        appendI32(value, to: &out)
    }

    private static func appendLE<T: FixedWidthInteger>(_ value: T, to out: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    private static func appendI64(_ value: Int64, to out: inout Data) {
        var le = value.littleEndian
        withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
    }

    public static func sha256Hex(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
}

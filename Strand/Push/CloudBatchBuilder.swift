import Foundation
import NoopPush

/// Builds the wire batch for a set of journal entries.
///
/// The journal owns ordering, identity and durability; `NoopPush` owns the wire format. This file is
/// the seam between them, and it is deliberately thin: it decodes the canonical row JSON a journal
/// record carries, hands the rows to `PushProtocol.appendBatch`, and returns the batch plus the
/// exact entries that the batch covers.
///
/// Two properties matter here and are worth stating:
///
///  1. `rowId` is the journal's dense receive sequence. `appendBatch` requires strictly increasing
///     rowIds, and the sequence is persisted across relaunch, so a batch is reproducible from the
///     journal alone. Because the batch id is derived from the identity + lines, re-sealing the same
///     entries after a crash produces the SAME batch id, which is what makes a retry idempotent on
///     the receiver (`noop_reserve_push_batch` raises `batch_id_conflict` only when the body differs).
///  2. The batch may cover fewer entries than offered: `appendBatch` stops before the 4 MiB decoded
///     limit. `Plan.entries` is the covered prefix, and only that prefix may be marked sealed.
enum CloudBatchBuilder {
    struct Plan {
        let batch: PushBatch
        /// The covered prefix of the input, in order. Exactly these entries become sealed.
        let entries: [CloudJournalEntry]
        let protocolVersion: String
        /// The end cursor to persist once the batch is ACKNOWLEDGED (never before).
        let endCursorJSON: String?
    }

    enum BuildError: Error, CustomStringConvertible {
        case unsupportedStream(CloudStreamKind)
        case malformedRow(seq: Int64, underlying: String)
        case emptyBatch

        var description: String {
            switch self {
            case .unsupportedStream(let s):
                return "cloud: stream \(s.rawValue) is not an append-delivery stream on this path"
            case .malformedRow(let seq, let why):
                return "cloud: journal row \(seq) is not a decodable wire row: \(why)"
            case .emptyBatch:
                return "cloud: no entries to seal"
            }
        }
    }

    /// Whether a replace-window admits a row's coordinate.
    ///
    /// The receiver's window is HALF-OPEN: `start <= coordinate < endExclusive`
    /// (`noop_projection_coordinate` enforces exactly this). A live audit of the fleet found
    /// `dailyMetric` batches whose rows sat exactly ON the window's exclusive end — the day-boundary
    /// coordinate — which the receiver correctly rejects; such a row belongs to the NEXT day's window,
    /// not this one. The phone currently does not author replace-window rows at all (see
    /// `appendTable(for:)`), so no live path here can emit one; this predicate exists so that when the
    /// window path is implemented the rule is already written down, enforced in one place, and covered
    /// by a test, instead of being rediscovered from a rejection in production.
    static func windowAdmits(coordinate: Int64, start: Int64, endExclusive: Int64) -> Bool {
        coordinate >= start && coordinate < endExclusive
    }

    /// The append table for a stream, or nil when the stream is not append-delivery.
    ///
    /// Replace-window streams (`journal`, `dailyMetric`, `sleepSession`, `workout`) are NOT handled
    /// here: they require the receiver's window assembly and replacement-generation semantics, and
    /// the phone does not author them in cloud mode (the server does). They are rejected loudly rather
    /// than silently mis-sent as appends, and a replace-window row that would land on a window's
    /// exclusive end must be refused pre-upload — see `windowAdmits(coordinate:start:endExclusive:)`.
    static func appendTable(for stream: CloudStreamKind) -> PushAppendTable? {
        switch stream {
        case .hrSample: return .hrSample
        case .rrInterval: return .rrInterval
        case .event: return .event
        case .battery: return .battery
        case .spo2Sample: return .spo2Sample
        case .skinTempSample: return .skinTempSample
        case .respSample: return .respSample
        case .gravitySample: return .gravitySample
        case .stepSample: return .stepSample
        case .standardHRReceipt: return .standardHRReceipt
        case .journal, .sleepSession, .workout, .dailyMetric, .rawBatch: return nil
        }
    }

    static func plan(entries: [CloudJournalEntry],
                     stream: CloudStreamKind,
                     sourceId: String,
                     deviceId: String,
                     protocolVersion: String,
                     startCursorJSON: String?,
                     maximumDecodedBytes: Int = PushProtocolLimits.maxBodyBytes) throws -> Plan {
        guard !entries.isEmpty else { throw BuildError.emptyBatch }
        guard let table = appendTable(for: stream) else { throw BuildError.unsupportedStream(stream) }

        // Deduplicate by the record's natural (conflict) key before sealing. The receiver
        // rejects a batch that contains two rows with the same conflict key
        // (`duplicate_record_key`, 422) — and BLE legitimately delivers repeated
        // readings inside one second (verified live: an hrSample batch with two
        // records at ts=1790792481 was rejected whole). Rows in a batch already share
        // owner/device/source, so the record `key` IS the conflict key; last writer
        // wins, mirroring the receiver's own upsert semantics for a re-sent key.
        // Keep the LAST occurrence of each key at its own position: the retained
        // entries stay in receive order (strictly increasing rowIds), and a
        // re-sent key wins (mirroring the receiver's upsert).
        var lastIndexForKey: [String: Int] = [:]
        var decoded: [(entry: CloudJournalEntry, row: PushAppendRecord)?] = []
        decoded.reserveCapacity(entries.count)
        for entry in entries {
            do {
                let row = try decodeRow(entry)
                let identity = try PushProtocol.canonicalJsonMap(row.key)
                if let earlier = lastIndexForKey[identity] {
                    decoded[earlier] = nil
                }
                lastIndexForKey[identity] = decoded.count
                decoded.append((entry, row))
            } catch {
                throw BuildError.malformedRow(seq: entry.seq, underlying: String(describing: error))
            }
        }
        let kept = decoded.compactMap { $0 }
        var rows: [PushAppendRecord] = []
        rows.reserveCapacity(kept.count)
        for item in kept { rows.append(item.row) }
        let entries = kept.map { $0.entry }

        let startCursor = startCursorJSON.flatMap { json -> PushCursor? in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(PushCursor.self, from: data)
        }

        let batch = try PushProtocol.appendBatch(table: table,
                                                sourceId: sourceId,
                                                deviceId: deviceId,
                                                startCursor: startCursor,
                                                records: rows,
                                                protocolVersion: protocolVersion,
                                                maximumDecodedBytes: maximumDecodedBytes)
        // `appendBatch` selects a strictly increasing prefix of the rows it was given, so the covered
        // entries are the first `recordCount` of the input.
        let covered = Array(entries.prefix(batch.recordCount))
        var endCursorJSON: String? = nil
        if let end = batch.endCursor, let data = try? JSONEncoder().encode(end) {
            endCursorJSON = String(data: data, encoding: .utf8)
        }
        return Plan(batch: batch, entries: covered, protocolVersion: batch.protocolVersion,
                    endCursorJSON: endCursorJSON)
    }

    /// Decode the canonical `{"key":{…},"data":{…}}` row a capture seam stored.
    static func decodeRow(_ entry: CloudJournalEntry) throws -> PushAppendRecord {
        let object = try JSONSerialization.jsonObject(with: entry.record.payload)
        guard let map = object as? [String: Any],
              let keyObject = map["key"] as? [String: Any],
              let dataObject = map["data"] as? [String: Any],
              let keyValue = jsonValue(keyObject), case .map(let keyMap) = keyValue,
              let dataValue = jsonValue(dataObject), case .map(let dataMap) = dataValue else {
            throw BuildError.malformedRow(seq: entry.seq, underlying: "expected {key:{…},data:{…}}")
        }
        return PushAppendRecord(rowId: entry.seq, key: keyMap, data: dataMap)
    }

    // MARK: - JSON bridging

    /// JSONSerialization -> PushJSONValue.
    ///
    /// A JSON boolean and the numbers 1/0 both bridge to NSNumber, so the numeric cases are checked
    /// against the CFBoolean type id rather than by trying `as? Bool` (which would turn `1` into
    /// `true` and change the wire value).
    static func jsonValue(_ any: Any) -> PushJSONValue? {
        switch any {
        case let value as String:
            return .string(value)
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() { return .bool(value.boolValue) }
            let double = value.doubleValue
            if double.rounded() == double, double >= Double(Int64.min), double <= Double(Int64.max) {
                return .int(value.int64Value)
            }
            return .double(double)
        case let value as [Any]:
            let mapped = value.compactMap { jsonValue($0) }
            return mapped.count == value.count ? .array(mapped) : nil
        case let value as [String: Any]:
            var out: [String: PushJSONValue] = [:]
            for (k, v) in value {
                guard let converted = jsonValue(v) else { return nil }
                out[k] = converted
            }
            return .map(out)
        case is NSNull:
            return .null
        default:
            return nil
        }
    }
}


import Foundation

/// One decoded NOOP push protocol batch (the exact wire contract of
/// `android/app/src/main/java/com/noop/push/PushProtocol.kt`).
///
/// Line 1 is the batch header (`type: "batch"`); every following line is a
/// record (`type: "record"`, members `key` and `data`). The decoded NDJSON
/// body is authoritative; the sealed object carries it gzip-compressed.
struct PushBatch {
    struct Cursor: Equatable {
        let rowId: Int64
        let keySha256: String
    }

    let batchId: String
    let sourceId: String
    let deviceId: String
    let stream: String
    let delivery: String          // "append" | "replace_window"
    let protocolVersion: String
    let recordCount: Int
    let startCursor: Cursor?
    let endCursor: Cursor?
    let window: [String: Any]?   // replace_window only
    var records: [[String: Any]]

    /// Header as canonical JSON object (for the commit call).
    var headerObject: [String: Any] {
        var h: [String: Any] = [
            "type": "batch",
            "batchId": batchId,
            "sourceId": sourceId,
            "deviceId": deviceId,
            "stream": stream,
            "delivery": delivery,
            "protocolVersion": protocolVersion,
            "recordCount": recordCount,
        ]
        if let s = startCursor { h["startCursor"] = ["rowId": s.rowId, "keySha256": s.keySha256] }
        if let e = endCursor { h["endCursor"] = ["rowId": e.rowId, "keySha256": e.keySha256] }
        if let w = window { h["window"] = w }
        return h
    }

    enum DecodeError: Error, CustomStringConvertible {
        case malformed(String)
        var description: String {
            if case .malformed(let m) = self { return m }
            return "unknown decode error"
        }
    }

    static func decode(ndjson: Data) throws -> PushBatch {
        guard let text = String(data: ndjson, encoding: .utf8) else {
            throw DecodeError.malformed("batch body is not UTF-8")
        }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).makeIterator()
        guard let headerLine = lines.next() else { throw DecodeError.malformed("empty batch") }
        guard let header = decodeJSONObject(headerLine.data(using: .utf8)!) else {
            throw DecodeError.malformed("first line is not a JSON object")
        }
        guard header["type"] as? String == "batch" else {
            throw DecodeError.malformed("first line is not a batch header")
        }
        func cursor(_ v: Any?) -> Cursor? {
            guard let c = v as? [String: Any] else { return nil }
            guard let rowId = c["rowId"] as? Int64, let keySha = c["keySha256"] as? String else { return nil }
            return Cursor(rowId: rowId, keySha256: keySha)
        }
        guard let batchId = header["batchId"] as? String,
              let sourceId = header["sourceId"] as? String,
              let deviceId = header["deviceId"] as? String,
              let stream = header["stream"] as? String,
              let delivery = header["delivery"] as? String,
              let protocolVersion = header["protocolVersion"] as? String,
              let recordCount = header["recordCount"] as? Int else {
            throw DecodeError.malformed("batch header missing required members")
        }
        var records: [[String: Any]] = []
        records.reserveCapacity(recordCount)
        while let line = lines.next() {
            guard let obj = decodeJSONObject(line.data(using: .utf8)!) else {
                throw DecodeError.malformed("record line is not a JSON object")
            }
            guard obj["type"] as? String == "record" else { continue }
            records.append(obj)
        }
        if records.count != recordCount {
            throw DecodeError.malformed("recordCount \(recordCount) != decoded \(records.count)")
        }
        return PushBatch(
            batchId: batchId, sourceId: sourceId, deviceId: deviceId, stream: stream,
            delivery: delivery, protocolVersion: protocolVersion, recordCount: recordCount,
            startCursor: cursor(header["startCursor"]), endCursor: cursor(header["endCursor"]),
            window: header["window"] as? [String: Any], records: records
        )
    }

    /// Map decoded records to projection rows for `noop_commit_push_projection`:
    /// identity columns + key members + data members, exactly as the receiving
    /// registry expects (field names are table column names).
    func projectionRows(userId: String, deviceId: String) throws -> [[String: Any]] {
        var rows: [[String: Any]] = []
        rows.reserveCapacity(records.count)
        for rec in records {
            guard let key = rec["key"] as? [String: Any],
                  let data = rec["data"] as? [String: Any] else {
                throw DecodeError.malformed("record without key/data")
            }
            var row: [String: Any] = key
            for (k, v) in data { row[k] = v }
            row["user_id"] = userId
            row["device_id"] = deviceId
            row["source_id"] = sourceId
            row["batch_id"] = batchId
            rows.append(row)
        }
        return rows
    }

    /// keepKeys for replace_window streams: the natural key of each row in this batch.
    func keepKeys() throws -> [String] {
        var keys: [String] = []
        for rec in records {
            guard let key = rec["key"] as? [String: Any] else {
                throw DecodeError.malformed("record without key")
            }
            // The keep-keys contract on the receiving side is the row's natural
            // key as a JSON value (array for compound keys, scalar for single).
            if key.count == 1, let only = key.values.first {
                keys.append(only is String ? only as! String : String(describing: only))
            } else {
                let encoded = try? JSONSerialization.data(withJSONObject: Array(key.values))
                keys.append(encoded.map { String(data: $0, encoding: .utf8) ?? "" } ?? "")
            }
        }
        return keys
    }
}

private func decodeJSONObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

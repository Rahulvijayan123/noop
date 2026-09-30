import Foundation
import CCrypto
import CZlib

// MARK: - Canonical JSON value
//
// The push projection rows are JSON objects whose *field order* is fixed by the receiving
// registry (`supabase/functions/_shared/registry.ts`, pinned in `contracts/upstream/`).
// Swift dictionaries have no stable iteration order, so the registry is expressed with an
// ordered field list and serialized by the canonical writer below. `jsonb` ignores key order,
// but determinism is what makes the golden fixtures and the audit trail meaningful.

/// An ordered JSON object. Field order is insertion order, exactly as `registry.ts` builds it.
struct ProjectionRow: Equatable {
    private(set) var fields: [(String, ProjectionJSON)] = []

    init() {}

    /// Field order is part of the value: it is the canonical projection order.
    static func == (lhs: ProjectionRow, rhs: ProjectionRow) -> Bool {
        guard lhs.fields.count == rhs.fields.count else { return false }
        for (left, right) in zip(lhs.fields, rhs.fields) where left.0 != right.0 || left.1 != right.1 {
            return false
        }
        return true
    }

    init(_ fields: [(String, ProjectionJSON)]) {
        self.fields = fields
    }

    /// Append a field. Call order defines the canonical order.
    mutating func add(_ key: String, _ value: ProjectionJSON) {
        fields.append((key, value))
    }

    mutating func add(_ key: String, _ value: ProjectionJSON?) {
        guard let value else { return }
        fields.append((key, value))
    }

    /// Set a field in place, keeping its canonical position; append when absent.
    /// Mirrors `row[key] = value` on an already-populated JavaScript object.
    mutating func replace(_ key: String, _ value: ProjectionJSON) {
        if let index = fields.firstIndex(where: { $0.0 == key }) {
            fields[index] = (key, value)
        } else {
            fields.append((key, value))
        }
    }

    subscript(key: String) -> ProjectionJSON? {
        fields.first(where: { $0.0 == key })?.1
    }

    var keys: [String] { fields.map(\.0) }

    var isEmpty: Bool { fields.isEmpty }

    /// Legacy dictionary view for callers that still need `[String: Any]`.
    var dictionary: [String: Any] { Dictionary(uniqueKeysWithValues: fields.map { ($0.0, $0.1.anyValue) }) }

    /// Compact, deterministic JSON text with fields in canonical order.
    ///
    /// `sortKeys` is used for *nested* objects: Foundation dictionaries cannot preserve the wire
    /// order of a nested object, so nested keys are sorted on both the Swift side and in the golden
    /// oracle (`contracts/fixtures/oracle.mjs`). The top-level row keeps the registry's field order.
    func jsonText(sortKeys: Bool = false) -> String {
        var out = "{"
        var first = true
        for (key, value) in (sortKeys ? fields.sorted { $0.0 < $1.0 } : fields) {
            if !first { out += "," }
            first = false
            out += ProjectionJSON.encodeString(key)
            out += ":"
            out += value.jsonText()
        }
        out += "}"
        return out
    }
}

/// A JSON value that keeps object field order and number representation deterministic.
indirect enum ProjectionJSON: Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([ProjectionJSON])
    case object(ProjectionRow)

    /// Bridge back to the Foundation representation used by the existing callers.
    var anyValue: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map(\.anyValue)
        case .object(let v): return v.dictionary
        }
    }

    func jsonText() -> String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return ProjectionJSON.encodeNumber(v)
        case .string(let v): return ProjectionJSON.encodeString(v)
        case .array(let values):
            return "[" + values.map { $0.jsonText() }.joined(separator: ",") + "]"
        case .object(let row): return row.jsonText(sortKeys: true)
        }
    }

    /// JSON.stringify-compatible number text: integral values lose the fraction.
    static func encodeNumber(_ value: Double) -> String {
        if value.isFinite, value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// JSON.stringify-compatible string escaping.
    static func encodeString(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}

/// Build a `ProjectionJSON` tree from a value produced by `JSONSerialization`.
///
/// Object member order is lost by `JSONSerialization`, so nested objects are emitted with
/// keys sorted; that is the only place where the canonical order is not the wire order, and
/// it is invisible to `jsonb` (which compares objects as unordered maps).
func projectionJSON(from value: Any) -> ProjectionJSON {
    switch value {
    case is NSNull:
        return .null
    case let number as NSNumber:
        return projectionJSON(number: number)
    case let text as String:
        return .string(text)
    case let array as [Any]:
        return .array(array.map(projectionJSON(from:)))
    case let object as [String: Any]:
        var row = ProjectionRow()
        for key in object.keys.sorted() { row.add(key, projectionJSON(from: object[key]!)) }
        return .object(row)
    default:
        return .null
    }
}

// The canonical boolean NSNumber singletons. JSONSerialization decodes JSON
// true/false to these on both macOS (tagged kCFBoolean) and Linux corelibs
// (cached singletons), while numeric fields never share their identity —
// so identity is the portable boolean test (CFGetTypeID is macOS-only).
private let booleanTrueNumber = NSNumber(value: true)
private let booleanFalseNumber = NSNumber(value: false)

func isBooleanNumber(_ number: NSNumber) -> Bool {
    return number === booleanTrueNumber || number === booleanFalseNumber
}

func projectionJSON(number: NSNumber) -> ProjectionJSON {
    // Foundation reports JSON booleans as NSNumber; they must stay booleans.
    if isBooleanNumber(number) {
        return .bool(number.boolValue)
    }
    let type = String(cString: number.objCType)
    if type == "d" || type == "f" {
        let double = number.doubleValue
        if double == double.rounded(), abs(double) < 9_007_199_254_740_992 {
            return .int(Int64(double))
        }
        return .double(double)
    }
    return .int(number.int64Value)
}

// MARK: - JavaScript number/coercion helpers
//
// `registry.ts` mixes strict checks (`typeof value !== 'number'`, `Number.isSafeInteger`) with
// coercive ones (`Number(value)`). The two must not be conflated: the strict ones define what
// the receiver rejects, the coercive ones define what it accepts.

enum ProjectionCoercion {
    /// `Number(value)` — strings are parsed, booleans become 1/0, anything else is NaN.
    static func number(_ value: Any?) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber {
            if isBooleanNumber(number) { return number.boolValue ? 1 : 0 }
            return number.doubleValue
        }
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return 0 }
            if let int = Int64(trimmed) { return Double(int) }
            if let double = Double(trimmed) { return double }
            if trimmed.lowercased().hasPrefix("0x") { return Double(Int64(trimmed.dropFirst(2), radix: 16) ?? 0) }
            return nil
        }
        return nil
    }

    /// `Number.isFinite(Number(value))`
    static func finiteNumber(_ value: Any?) -> Double? {
        guard let double = number(value), double.isFinite else { return nil }
        return double
    }

    /// Strict JSON number: `typeof value === 'number'`. Strings and booleans are NOT numbers.
    static func strictNumber(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        if isBooleanNumber(number) { return nil }
        let type = String(cString: number.objCType)
        guard type == "d" || type == "f" || type == "q" || type == "i" || type == "c" || type == "s" || type == "l" else {
            return nil
        }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return double
    }

    /// `Number.isSafeInteger(value)` on a strict JSON number.
    static func strictSafeInteger(_ value: Any?) -> Double? {
        guard let double = strictNumber(value), isSafeInteger(double) else { return nil }
        return double
    }

    static func isSafeInteger(_ value: Double) -> Bool {
        value.isFinite && value == value.rounded() && abs(value) <= 9_007_199_254_740_991
    }

    static func isInteger(_ value: Double) -> Bool {
        value.isFinite && value == value.rounded()
    }

    /// `Boolean(value)`
    static func boolean(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let number = value as? NSNumber {
            if isBooleanNumber(number) { return number.boolValue }
            return number.doubleValue != 0
        }
        if let text = value as? String { return !text.isEmpty }
        return true
    }

    /// JavaScript `||` fallback semantics: `null`, `undefined`, `false`, `0`, `''` and `NaN` fall through.
    static func isTruthy(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let number = value as? NSNumber {
            if isBooleanNumber(number) { return number.boolValue }
            let double = number.doubleValue
            return double != 0 && !double.isNaN
        }
        if let text = value as? String { return !text.isEmpty }
        return true
    }

    /// `String(value)` for the number formatting `stableUuid` depends on.
    static func numberString(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
            return String(Int64(value))
        }
        return String(value)
    }

    /// `new Date(seconds * 1000).toISOString()`
    static func isoString(epochSeconds: Double) throws -> String {
        let milliseconds = epochSeconds * 1000
        guard milliseconds.isFinite, abs(milliseconds) <= 8_640_000_000_000_000 else {
            throw PushBatch.ProjectionError.invalidTimestamp("date out of range: \(epochSeconds)")
        }
        let formatter = ProjectionCoercion.isoFormatter
        return formatter.string(from: Date(timeIntervalSince1970: epochSeconds))
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    /// `stableUuid` from `structuredSync.ts`: sha256 of the parts joined with `|`, first 32 hex
    /// characters, with the version/variant nibbles stamped over (not replacing) hex digits.
    static func stableUuid(_ parts: [String]) -> String {
        let digest = projectionSHA256Hex(Data(parts.joined(separator: "|").utf8))
        let hex = Array(digest.prefix(32))
        func slice(_ range: Range<Int>) -> String { String(hex[range.lowerBound..<range.upperBound]) }
        return "\(slice(0..<8))-\(slice(8..<12))-5\(slice(13..<16))-a\(slice(17..<20))-\(slice(20..<32))"
    }
}

private func projectionSHA256Hex(_ data: Data) -> String {
    var digest = [UInt8](repeating: 0, count: 32)
    data.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
        _ = SHA256(ptr.baseAddress, ptr.count, &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
}

// MARK: - Push projection registry (Swift port of supabase/functions/_shared/registry.ts)
//
// Pinned source: Whoop-Nara 9abbcf22 `supabase/functions/_shared/registry.ts`
// (see contracts/upstream/MANIFEST.md). The receiving Edge Function maps every accepted
// record through this registry and hands the *mapped rows* to
// `public.noop_commit_push_projection`. The worker must produce the same rows, because the
// database validates them literally:
//   * `noop_commit_push_projection_intake_core` rejects any row whose `user_id` does not match
//     the manifest owner, or whose `device_id`/`source_device_id` does not match the manifest device
//     (`projection_owner_mismatch`).
//   * `noop_project_append_batch` rejects any column that is not a real table column
//     (`unknown append column`) and any mismatched identity (`append row identity mismatch`).
// A generic key+data merge cannot satisfy that contract: `journal` must become
// `answered_yes`/`numeric_value`, `dailyMetric` must become `daily_metrics` columns, and the
// session streams must carry `external_id`/`start_at`/`summary`.

enum ProjectionDelivery: String {
    case append = "append"
    case replaceWindow = "replace_window"
}

enum ProjectionWindowSelector: String {
    case day
    case startTs
}

/// Arguments `registry.ts` passes to every `mapRow`.
struct ProjectionMapArgs {
    let userId: String
    let deviceId: String          // canonical devices.id (uuid)
    let headerDeviceId: String    // header.deviceId, the external device identifier
    let sourceId: String
    let batchId: String
    let replacementId: String
    let protocolVersion: String
    let record: [String: Any]
    /// Fixed projection clock. `dailyMetric` stamps `computed_at` with it.
    let computedAt: String

    var key: [String: Any] { (record["key"] as? [String: Any]) ?? [:] }
    var data: [String: Any] { (record["data"] as? [String: Any]) ?? [:] }
}

struct StreamProjection {
    let stream: String
    let table: String
    let onConflict: String
    let delivery: ProjectionDelivery
    let tsKey: String?
    let windowSelector: ProjectionWindowSelector?
    let mapRow: (ProjectionMapArgs) throws -> ProjectionRow?
    let rowKey: ((ProjectionMapArgs) -> String)?
}

enum ProjectionRegistry {
    /// Every append stream with a queryable projection, in the pinned registry's key order.
    static let appendStreams: [String] = [
        "stepSample", "sleepStateSample", "ppgHrSample", "hrSample", "rrInterval",
        "rrPacketProvenance", "standardHRReceipt", "event", "battery", "spo2Sample",
        "skinTempSample", "respSample", "gravitySample",
    ]

    /// Every replace-window stream with a projection, in the pinned registry's key order.
    static let replaceStreams: [String] = ["dailyMetric", "sleepSession", "workout", "journal"]

    static let allStreams: [String] = appendStreams + replaceStreams

    private static let byName: [String: StreamProjection] = {
        var table: [String: StreamProjection] = [:]
        for projection in build() { table[projection.stream] = projection }
        return table
    }()

    static func projection(for stream: String) -> StreamProjection? { byName[stream] }

    static func isProjectable(stream: String) -> Bool { byName[stream] != nil }

    private static func build() -> [StreamProjection] {
        [
            scalarProjection(stream: "stepSample", table: "noop_step_samples"),
            scalarProjection(stream: "sleepStateSample", table: "noop_sleep_state_samples"),
            scalarProjection(stream: "ppgHrSample", table: "noop_ppg_hr_samples"),
            appendProjection(stream: "hrSample", table: "noop_hr_samples", onConflict: "user_id,device_id,ts", tsKey: "ts", map: mapHRSample),
            appendProjection(stream: "rrInterval", table: "noop_rr_intervals", onConflict: "user_id,device_id,ts,rrMs,seq", tsKey: "ts", map: mapRRInterval),
            appendProjection(stream: "rrPacketProvenance", table: "noop_rr_packet_provenance", onConflict: "user_id,device_id,packetId", tsKey: "ts", map: mapRRPacketProvenance),
            appendProjection(stream: "standardHRReceipt", table: "noop_standard_hr_receipts", onConflict: "user_id,device_id,receiptId", tsKey: "ts", map: mapStandardHRReceipt),
            appendProjection(stream: "event", table: "noop_events", onConflict: "user_id,device_id,ts,kind", tsKey: "ts", map: mapEvent),
            appendProjection(stream: "battery", table: "noop_battery_samples", onConflict: "user_id,device_id,ts", tsKey: "ts", map: mapBattery),
            appendProjection(stream: "spo2Sample", table: "noop_spo2_samples", onConflict: "user_id,device_id,ts", tsKey: "ts", map: mapSpo2Sample),
            appendProjection(stream: "skinTempSample", table: "noop_skin_temp_samples", onConflict: "user_id,device_id,ts", tsKey: "ts", map: mapSkinTempSample),
            appendProjection(stream: "respSample", table: "noop_resp_samples", onConflict: "user_id,device_id,ts", tsKey: "ts", map: mapRespSample),
            appendProjection(stream: "gravitySample", table: "noop_gravity_samples", onConflict: "user_id,device_id,ts", tsKey: "ts", map: mapGravitySample),
            StreamProjection(
                stream: "dailyMetric", table: "daily_metrics", onConflict: "user_id,day",
                delivery: .replaceWindow, tsKey: nil, windowSelector: .day,
                mapRow: mapDailyMetric, rowKey: { args in
                    guard let day = args.key["day"] else { return "" }
                    return jsString(day)
                }
            ),
            StreamProjection(
                stream: "sleepSession", table: "sessions", onConflict: "id",
                delivery: .replaceWindow, tsKey: nil, windowSelector: .startTs,
                mapRow: mapSleepSession, rowKey: { args in
                    "sleep:\(args.headerDeviceId):\(jsString(args.key["startTs"]))"
                }
            ),
            StreamProjection(
                stream: "workout", table: "sessions", onConflict: "id",
                delivery: .replaceWindow, tsKey: nil, windowSelector: .startTs,
                mapRow: mapWorkout, rowKey: { args in
                    "workout:\(args.headerDeviceId):\(jsString(args.key["startTs"])):\(jsString(args.key["sport"]))"
                }
            ),
            StreamProjection(
                stream: "journal", table: "noop_journal_entries", onConflict: "user_id,device_id,day,question",
                delivery: .replaceWindow, tsKey: nil, windowSelector: .day,
                mapRow: mapJournal, rowKey: { args in
                    "\(jsString(args.key["day"]))|\(jsString(args.key["question"]))"
                }
            ),
        ]
    }

    private static func appendProjection(
        stream: String, table: String, onConflict: String, tsKey: String,
        map: @escaping (ProjectionMapArgs) throws -> ProjectionRow?
    ) -> StreamProjection {
        StreamProjection(stream: stream, table: table, onConflict: onConflict,
                         delivery: .append, tsKey: tsKey, windowSelector: nil,
                         mapRow: map, rowKey: nil)
    }

    /// The three scalar streams share one mapper: identity, then the validated scalar fields.
    private static func scalarProjection(stream: String, table: String) -> StreamProjection {
        StreamProjection(stream: stream, table: table, onConflict: "user_id,device_id,ts",
                         delivery: .append, tsKey: "ts", windowSelector: nil,
                         mapRow: { args in
            var row = ProjectionRow()
            row.add("user_id", .string(args.userId))
            row.add("device_id", .string(args.deviceId))
            row.add("source_id", .string(args.sourceId))
            row.add("batch_id", .string(args.batchId))
            let scalars = try scalarAppendFields(stream: stream, args: args)
            for (key, value) in scalars.fields { row.add(key, value) }
            return row
        }, rowKey: nil)
    }

    /// `recordTimestamp` from the pinned registry: `rrPacketProvenance`/`standardHRReceipt` carry
    /// their timestamp in `data`, every other append stream in `key`.
    static func recordTimestamp(stream: String, record: [String: Any]) -> Double? {
        guard let tsKey = byName[stream]?.tsKey else { return nil }
        let source: Any?
        if stream == "rrPacketProvenance" || stream == "standardHRReceipt" {
            source = (record["data"] as? [String: Any])?[tsKey]
        } else {
            source = (record["key"] as? [String: Any])?[tsKey]
        }
        guard let value = ProjectionCoercion.finiteNumber(source) else { return nil }
        return value
    }
}

/// `String(value)` for the values the registry interpolates into keys.
func jsString(_ value: Any?) -> String {
    guard let value, !(value is NSNull) else { return "undefined" }
    if let text = value as? String { return text }
    if let number = value as? NSNumber {
        if isBooleanNumber(number) { return number.boolValue ? "true" : "false" }
        return ProjectionCoercion.numberString(number.doubleValue)
    }
    return "\(value)"
}

/// `projectionJSON` for a value that may be absent.
func projectionJSONOrNull(_ value: Any?) -> ProjectionJSON {
    guard let value, !(value is NSNull) else { return .null }
    return projectionJSON(from: value)
}

/// `Number.isFinite(Number(value))` as a `ProjectionJSON` number, or `.null` when absent.
private func coercedNumberJSON(_ value: Any?) -> ProjectionJSON {
    guard let double = ProjectionCoercion.finiteNumber(value) else { return .null }
    return numberJSON(double)
}

func numberJSON(_ value: Double) -> ProjectionJSON {
    if value == value.rounded(), abs(value) < 9_007_199_254_740_992 {
        return .int(Int64(value))
    }
    return .double(value)
}

/// `sleepEfficiency` from `structuredSync.ts`: fractions above 1 are percentages.
func sleepEfficiencyJSON(_ value: Any?) -> ProjectionJSON {
    guard let value, !(value is NSNull) else { return .null }
    guard let number = ProjectionCoercion.finiteNumber(value) else { return .null }
    if number > 1 { return numberJSON(number / 100) }
    return numberJSON(number)
}

/// `JSON.parse` of an optional JSON text. A parse failure yields `nil` (the caller substitutes `[]`).
func parseJSONText(_ value: Any?) -> ProjectionJSON? {
    guard let value, !(value is NSNull) else { return nil }
    if let text = value as? String {
        guard let data = text.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        return projectionJSON(from: parsed)
    }
    if let number = value as? NSNumber {
        if isBooleanNumber(number) { return .bool(number.boolValue) }
        return numberJSON(number.doubleValue)
    }
    // An object or array is not JSON text; `JSON.parse(String(value))` throws in the receiver too.
    return nil
}

func jsonArrayOrEmpty(_ value: ProjectionJSON?) -> ProjectionJSON {
    if case .array(let values)? = value { return .array(values) }
    return .array([])
}

// MARK: - Field mapping (one function per stream, in pinned registry order)

private func mapHRSample(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let ts = ProjectionCoercion.finiteNumber(args.key["ts"]),
          let bpm = ProjectionCoercion.finiteNumber(args.data["bpm"]) else { return nil }
    let row = ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("ts", numberJSON(ts)),
        ("bpm", numberJSON(bpm)),
        ("batch_id", .string(args.batchId)),
    ])
    return row
}

private func mapRRInterval(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let ts = ProjectionCoercion.finiteNumber(args.key["ts"]),
          let rrMs = ProjectionCoercion.finiteNumber(args.key["rrMs"]),
          let seq = ProjectionCoercion.finiteNumber(args.key["seq"]) else { return nil }
    var row = ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("ts", numberJSON(ts)),
        ("rrMs", numberJSON(rrMs)),
        ("seq", numberJSON(seq)),
        ("batch_id", .string(args.batchId)),
    ])
    // An absent order/channel/clock flag is unknown, not numeric zero.
    for field in ["ord", "srcChannel", "tsSuspect"] {
        guard let value = args.data[field] else { continue }
        if value is NSNull {
            row.add(field, .null)
        } else if let number = ProjectionCoercion.finiteNumber(value) {
            row.add(field, numberJSON(number))
        }
    }
    return row
}

private func mapRRPacketProvenance(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    let d = args.data
    guard let packetId = args.key["packetId"] as? String, isLowercaseHex(packetId, length: 64),
          let rawHex = d["rawHex"] as? String, isLowercaseHex(rawHex),
          rawHex.count % 2 == 0, rawHex.count >= 56, rawHex.count <= 131086,
          ProjectionCoercion.strictNumber(d["schemaVersion"]) == 1,
          ProjectionCoercion.strictNumber(d["srcChannel"]) == 5,
          (d["decoderVersion"] as? String) == "whoop5-v18-original-words-v1",
          ["sensor-second-unmapped", "legacy-stale-clock-snap300-v1"].contains(jsString(d["clockVersion"])) else { return nil }
    for name in ["ts", "sensorTs", "recordIndex", "clockOffsetSeconds", "declaredCount"] {
        guard ProjectionCoercion.strictSafeInteger(d[name]) != nil else { return nil }
    }
    guard let recordIndex = ProjectionCoercion.finiteNumber(d["recordIndex"]), recordIndex >= 0, recordIndex <= 4294967295,
          let declaredCount = ProjectionCoercion.finiteNumber(d["declaredCount"]), declaredCount >= 0, declaredCount <= 255,
          let precision = ProjectionCoercion.finiteNumber(d["timestampPrecisionSeconds"]), precision == 1 || precision == 300,
          let ts = ProjectionCoercion.finiteNumber(d["ts"]),
          let sensorTs = ProjectionCoercion.finiteNumber(d["sensorTs"]),
          let offset = ProjectionCoercion.finiteNumber(d["clockOffsetSeconds"]),
          ts - sensorTs == offset else { return nil }
    // These are raw claimed receipt fields, not server-verified timing. The reader recomputes
    // CRC, sensor-record SHA256, word positions and all metadata before creating observations.
    return ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("batch_id", .string(args.batchId)),
        ("packetId", .string(packetId)),
        ("ts", numberJSON(ts)),
        ("sensorTs", numberJSON(sensorTs)),
        ("recordIndex", numberJSON(recordIndex)),
        ("rawHex", .string(rawHex)),
        ("srcChannel", .int(5)),
        ("schemaVersion", .int(1)),
        ("decoderVersion", .string("whoop5-v18-original-words-v1")),
        ("clockVersion", .string(jsString(d["clockVersion"]))),
        ("timestampPrecisionSeconds", numberJSON(precision)),
        ("clockOffsetSeconds", numberJSON(offset)),
        ("declaredCount", numberJSON(declaredCount)),
    ])
}

private func mapStandardHRReceipt(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    let d = args.data
    guard let sessionId = d["sessionId"] as? String, isLowercaseHexUuid(sessionId),
          let rawHex = d["rawHex"] as? String, isLowercaseHex(rawHex),
          rawHex.count >= 2, rawHex.count <= 1024, rawHex.count % 2 == 0,
          ProjectionCoercion.strictNumber(d["schemaVersion"]) == 1,
          (d["clockVersion"] as? String) == "host-arrival-unmapped" else { return nil }
    for field in ["ts", "notificationOrdinal", "receivedUnixMs"] {
        guard let value = ProjectionCoercion.strictSafeInteger(d[field]), value >= 0 else { return nil }
    }
    // Nanosecond host uptime crosses JavaScript's safe-integer boundary after ~104 days. New
    // clients send a decimal string. Preserve legacy numeric values only while they are exact;
    // never round an oversized number into a PostgreSQL bigint.
    var monotonicNs: String?
    if let text = d["receivedMonotonicNs"] as? String {
        monotonicNs = text
    } else if let value = ProjectionCoercion.strictSafeInteger(d["receivedMonotonicNs"]), value >= 0 {
        monotonicNs = ProjectionCoercion.numberString(value)
    }
    guard let monotonic = monotonicNs, isDecimalMonotonic(monotonic),
          let monotonicValue = Int64(monotonic), monotonicValue <= 9_223_372_036_854_775_807,
          let receiptId = args.key["receiptId"] as? String,
          let notificationOrdinal = ProjectionCoercion.finiteNumber(d["notificationOrdinal"]),
          let ts = ProjectionCoercion.finiteNumber(d["ts"]),
          let receivedUnixMs = ProjectionCoercion.finiteNumber(d["receivedUnixMs"]),
          receiptId == "\(sessionId):\(ProjectionCoercion.numberString(notificationOrdinal))",
          ts == (receivedUnixMs / 1000).rounded(.down) else { return nil }
    // Arrival clocks and consecutive notifications do not assert sensor beat timing/continuity.
    return ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("batch_id", .string(args.batchId)),
        ("receiptId", .string(receiptId)),
        ("ts", numberJSON(ts)),
        ("sessionId", .string(sessionId)),
        ("notificationOrdinal", numberJSON(notificationOrdinal)),
        ("receivedUnixMs", numberJSON(receivedUnixMs)),
        ("receivedMonotonicNs", .string(monotonic)),
        ("rawHex", .string(rawHex)),
        ("schemaVersion", .int(1)),
        ("clockVersion", .string("host-arrival-unmapped")),
    ])
}

private func mapEvent(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let ts = ProjectionCoercion.finiteNumber(args.key["ts"]),
          let kind = args.key["kind"] as? String, !kind.isEmpty,
          let payloadJSON = args.data["payloadJSON"] as? String else { return nil }
    return ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("ts", numberJSON(ts)),
        ("kind", .string(kind)),
        ("payloadJSON", .string(payloadJSON)),
        ("batch_id", .string(args.batchId)),
    ])
}

private func mapBattery(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let ts = ProjectionCoercion.finiteNumber(args.key["ts"]) else { return nil }
    var row = ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("ts", numberJSON(ts)),
        ("batch_id", .string(args.batchId)),
    ])
    if let soc = ProjectionCoercion.finiteNumber(args.data["soc"]) { row.add("soc", numberJSON(soc)) }
    if let mv = ProjectionCoercion.finiteNumber(args.data["mv"]) { row.add("mv", numberJSON(mv)) }
    if let charging = args.data["charging"] as? NSNumber, isBooleanNumber(charging) {
        row.add("charging", .bool(charging.boolValue))
    }
    return row
}

private func mapSpo2Sample(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let ts = ProjectionCoercion.finiteNumber(args.key["ts"]),
          let red = ProjectionCoercion.finiteNumber(args.data["red"]),
          let ir = ProjectionCoercion.finiteNumber(args.data["ir"]) else { return nil }
    return ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("ts", numberJSON(ts)),
        ("red", numberJSON(red)),
        ("ir", numberJSON(ir)),
        ("batch_id", .string(args.batchId)),
    ])
}

private func mapSkinTempSample(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let ts = ProjectionCoercion.finiteNumber(args.key["ts"]),
          let raw = ProjectionCoercion.finiteNumber(args.data["raw"]) else { return nil }
    var row = ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("ts", numberJSON(ts)),
        ("raw", numberJSON(raw)),
        ("batch_id", .string(args.batchId)),
    ])
    if let aux1 = ProjectionCoercion.finiteNumber(args.data["aux1Raw"]) { row.add("aux1Raw", numberJSON(aux1)) }
    if let aux2 = ProjectionCoercion.finiteNumber(args.data["aux2Raw"]) { row.add("aux2Raw", numberJSON(aux2)) }
    return row
}

private func mapRespSample(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let ts = ProjectionCoercion.finiteNumber(args.key["ts"]),
          let raw = ProjectionCoercion.finiteNumber(args.data["raw"]) else { return nil }
    return ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("ts", numberJSON(ts)),
        ("raw", numberJSON(raw)),
        ("batch_id", .string(args.batchId)),
    ])
}

private func mapGravitySample(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let ts = ProjectionCoercion.strictSafeInteger(args.key["ts"]),
          let x = ProjectionCoercion.strictNumber(args.data["x"]),
          let y = ProjectionCoercion.strictNumber(args.data["y"]),
          let z = ProjectionCoercion.strictNumber(args.data["z"]) else { return nil }
    var row = ProjectionRow([
        ("user_id", .string(args.userId)),
        ("device_id", .string(args.deviceId)),
        ("source_id", .string(args.sourceId)),
        ("ts", numberJSON(ts)),
        ("x", numberJSON(x)),
        ("y", numberJSON(y)),
        ("z", numberJSON(z)),
        ("dynAccel", .null),
        ("orientation_evidence_version", .string("projected-gravity-g-1")),
        ("motion_evidence_version", .null),
        ("batch_id", .string(args.batchId)),
    ])
    if let dynAccel = ProjectionCoercion.strictNumber(args.data["dynAccel"]), dynAccel >= 0, dynAccel <= 8 {
        row.replace("dynAccel", numberJSON(dynAccel))
        row.replace("motion_evidence_version", .string("projected-dynamic-acceleration-g-1"))
    }
    return row
}

// MARK: - dailyMetric -> daily_metrics (structuredSync.dailyMetricRow)

/// `(metric field, data field)` pairs, in the pinned row order.
private let dailyMetricFields: [(String, String)] = [
    ("totalSleepMin", "totalSleepMin"), ("efficiency", "efficiency"), ("deepMin", "deepMin"),
    ("remMin", "remMin"), ("lightMin", "lightMin"), ("restingHr", "restingHr"),
    ("avgHrv", "avgHrv"), ("recovery", "recovery"), ("strain", "strain"),
    ("exerciseCount", "exerciseCount"), ("spo2Pct", "spo2Pct"), ("skinTempDevC", "skinTempDevC"),
    ("respRateBpm", "respRateBpm"), ("steps", "steps"), ("activeKcalEst", "activeKcalEst"),
    ("spo2Red", "spo2Red"), ("spo2Ir", "spo2Ir"),
]

private func mapDailyMetric(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let day = args.key["day"] as? String, !day.isEmpty else { return nil }
    let d = args.data
    // `data.x ?? null` — an explicit JSON null and an absent member are both null.
    func metric(_ name: String) -> ProjectionJSON {
        if args.protocolVersion == "1.1" && ["avgSdnn", "skinTempC", "sleepHrOnly"].contains(name) {
            return projectionJSONOrNull(d[name])
        }
        guard dailyMetricFields.contains(where: { $0.0 == name }) else { return .null }
        return projectionJSONOrNull(d[name])
    }
    var extras = ProjectionRow()
    if let red = d["spo2Red"], !(red is NSNull) { extras.add("spo2_red_raw_adc", projectionJSON(from: red)) }
    if let ir = d["spo2Ir"], !(ir is NSNull) { extras.add("spo2_ir_raw_adc", projectionJSON(from: ir)) }
    var noopPush = ProjectionRow()
    noopPush.add("source_id", .string(args.sourceId))
    noopPush.add("batch_id", .string(args.batchId))
    noopPush.add("protocol_version", .string(args.protocolVersion))
    extras.add("noop_push", .object(noopPush))
    extras.add("disturbances", projectionJSONOrNull(d["disturbances"]))
    if args.protocolVersion == "1.1", let sleepHrOnly = d["sleepHrOnly"], !(sleepHrOnly is NSNull) {
        extras.add("sleep_hr_only", projectionJSON(from: sleepHrOnly))
    }
    var provenance = ProjectionRow()
    provenance.add("source", .string("noop_push"))
    provenance.add("source_id", .string(args.sourceId))
    provenance.add("batch_id", .string(args.batchId))

    var row = ProjectionRow()
    row.add("user_id", .string(args.userId))
    row.add("day", .string(day))
    row.add("source_device_id", .string(args.deviceId))
    row.add("charge", metric("recovery"))
    row.add("effort", metric("strain"))
    row.add("rest", .null)
    row.add("hrv_rmssd_ms", metric("avgHrv"))
    row.add("hrv_sdnn_ms", metric("avgSdnn"))
    row.add("resting_hr_bpm", metric("restingHr"))
    row.add("resp_rate_bpm", metric("respRateBpm"))
    row.add("skin_temp_dev_c", metric("skinTempDevC"))
    row.add("spo2_pct", metric("spo2Pct"))
    row.add("steps", metric("steps"))
    row.add("active_kcal", metric("activeKcalEst"))
    row.add("sleep_total_min", metric("totalSleepMin"))
    row.add("sleep_deep_min", metric("deepMin"))
    row.add("sleep_rem_min", metric("remMin"))
    row.add("sleep_light_min", metric("lightMin"))
    row.add("sleep_efficiency", sleepEfficiencyJSON(d["efficiency"]))
    row.add("exercise_count", metric("exerciseCount"))
    row.add("chart_data", .object(ProjectionRow()))
    row.add("extras", .object(extras))
    row.add("confidence", .object(ProjectionRow()))
    row.add("provenance", .object(provenance))
    row.add("algorithm_version", .string("noop-client"))
    row.add("computed_at", .string(args.computedAt))
    if args.protocolVersion == "1.1", let skinTempC = d["skinTempC"], !(skinTempC is NSNull) {
        row.replace("skin_temp_c", coercedNumberJSON(skinTempC))
    }
    return row
}

// MARK: - sleepSession / workout -> sessions (structuredSync row builders)

private func mapSleepSession(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let startTs = ProjectionCoercion.finiteNumber(args.key["startTs"]),
          let endTs = ProjectionCoercion.finiteNumber(args.data["endTs"]) else { return nil }
    let d = args.data
    // `startTsAdjusted ?? effectiveStartTs ?? startTs`
    var start = startTs
    for name in ["startTsAdjusted", "effectiveStartTs"] {
        if let value = d[name], !(value is NSNull), let number = ProjectionCoercion.finiteNumber(value) {
            start = number
            break
        }
    }
    let stages = jsonArrayOrEmpty(parseJSONText(d["stagesJSON"]))
    var summary = ProjectionRow()
    summary.add("efficiency", projectionJSONOrNull(d["efficiency"]))
    summary.add("resting_hr", projectionJSONOrNull(d["restingHr"]))
    summary.add("avg_hrv_rmssd", projectionJSONOrNull(d["avgHrv"]))
    var extended = ProjectionRow()
    for (key, value) in summary.fields { extended.add(key, value) }
    extended.add("motion_json", projectionJSONOrNull(d["motionJSON"]))
    extended.add("sleep_state_json", projectionJSONOrNull(d["sleepStateJSON"]))
    let stagingSparse = projectionJSONOrNull(d["stagingSparse"])
    extended.add("staging_sparse", stagingSparse.isNull ? .bool(false) : stagingSparse)
    extended.add("noop_external_device_id", .string(args.headerDeviceId))

    var row = ProjectionRow()
    row.add("id", .string(ProjectionCoercion.stableUuid([args.userId, args.headerDeviceId, "sleep", ProjectionCoercion.numberString(startTs)])))
    row.add("user_id", .string(args.userId))
    row.add("device_id", .string(args.deviceId))
    row.add("kind", .string("sleep"))
    row.add("source", .string("noop_push"))
    row.add("external_id", .string("sleep:\(args.headerDeviceId):\(ProjectionCoercion.numberString(startTs))"))
    row.add("start_at", .string(try ProjectionCoercion.isoString(epochSeconds: start)))
    row.add("end_at", .string(try ProjectionCoercion.isoString(epochSeconds: endTs)))
    row.add("summary", .object(summary))
    row.add("segments", stages)
    row.add("quality", .object(ProjectionRow()))
    row.add("user_modified", .bool(ProjectionCoercion.boolean(d["userEdited"])))
    row.add("algorithm_version", .string("0.1.0"))
    row.replace("summary", .object(extended))
    return row
}

private func mapWorkout(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let startTs = ProjectionCoercion.finiteNumber(args.key["startTs"]),
          let sport = args.key["sport"], ProjectionCoercion.isTruthy(sport),
          let endTs = ProjectionCoercion.finiteNumber(args.data["endTs"]) else { return nil }
    let d = args.data
    let source = ProjectionCoercion.isTruthy(d["source"]) ? jsString(d["source"]) : "noop_push"
    let manual = source.lowercased().contains("manual")
    let zones = parseJSONText(d["zonesJSON"])
    let segments = jsonArrayOrEmpty(zones)
    let sportText = jsString(sport)
    var summary = ProjectionRow()
    summary.add("sport", projectionJSON(from: sport))
    summary.add("duration_s", projectionJSONOrNull(d["durationS"]))
    summary.add("avg_hr", projectionJSONOrNull(d["avgHr"]))
    summary.add("peak_hr", projectionJSONOrNull(d["maxHr"]))
    summary.add("strain", projectionJSONOrNull(d["strain"]))
    summary.add("calories_kcal", projectionJSONOrNull(d["energyKcal"]))
    var extended = ProjectionRow()
    for (key, value) in summary.fields { extended.add(key, value) }
    extended.add("distance_m", projectionJSONOrNull(d["distanceM"]))
    extended.add("notes", projectionJSONOrNull(d["notes"]))
    extended.add("route_polyline", projectionJSONOrNull(d["routePolyline"]))
    extended.add("steps", projectionJSONOrNull(d["steps"]))
    extended.add("noop_external_device_id", .string(args.headerDeviceId))

    var row = ProjectionRow()
    row.add("id", .string(ProjectionCoercion.stableUuid([
        args.userId, args.headerDeviceId, "workout",
        ProjectionCoercion.numberString(startTs), sportText,
    ])))
    row.add("user_id", .string(args.userId))
    row.add("device_id", .string(args.deviceId))
    row.add("kind", .string(manual ? "manual_workout" : "workout"))
    row.add("source", .string(source))
    row.add("external_id", .string("workout:\(args.headerDeviceId):\(ProjectionCoercion.numberString(startTs)):\(sportText)"))
    row.add("start_at", .string(try ProjectionCoercion.isoString(epochSeconds: startTs)))
    row.add("end_at", .string(try ProjectionCoercion.isoString(epochSeconds: endTs)))
    row.add("summary", .object(summary))
    row.add("segments", segments)
    row.add("quality", .object(ProjectionRow()))
    row.add("user_modified", .bool(ProjectionCoercion.boolean(d["userEdited"])))
    row.add("algorithm_version", .string("0.1.0"))
    row.replace("summary", .object(extended))
    return row
}

// MARK: - journal -> noop_journal_entries

private func mapJournal(_ args: ProjectionMapArgs) throws -> ProjectionRow? {
    guard let day = args.key["day"], ProjectionCoercion.isTruthy(day),
          let question = args.key["question"], ProjectionCoercion.isTruthy(question) else { return nil }
    let d = args.data
    var row = ProjectionRow()
    row.add("user_id", .string(args.userId))
    row.add("device_id", .string(args.deviceId))
    row.add("source_id", .string(args.sourceId))
    row.add("day", projectionJSON(from: day))
    row.add("question", projectionJSON(from: question))
    row.add("answered_yes", .bool(isJSONTrue(d["answeredYes"])))
    row.add("notes", projectionJSONOrNull(d["notes"]))
    row.add("numeric_value", projectionJSONOrNull(d["numericValue"]))
    row.add("batch_id", .string(args.batchId))
    row.add("replacement_id", .string(args.replacementId))
    return row
}

/// `value === true` — an explicit JSON boolean, never a truthy number or string.
func isJSONTrue(_ value: Any?) -> Bool {
    guard let number = value as? NSNumber else { return false }
    guard isBooleanNumber(number) else { return false }
    return number.boolValue
}

// MARK: - Scalar append fields (stepSample / sleepStateSample / ppgHrSample)

func scalarAppendFields(stream: String, args: ProjectionMapArgs) throws -> ProjectionRow {
    let data = args.data
    func invalid() -> PushBatch.ProjectionError { .invalidScalarRecord(stream) }
    guard let ts = ProjectionCoercion.strictSafeInteger(args.key["ts"]) else { throw invalid() }
    guard abs(ts) <= 8_640_000_000_000 else { throw invalid() }
    func integer(_ value: Any?, optional: Bool = false) throws -> Double? {
        if optional && (value == nil || value is NSNull) { return nil }
        guard let number = ProjectionCoercion.strictNumber(value), ProjectionCoercion.isInteger(number),
              number >= -2147483648, number <= 2147483647 else { throw invalid() }
        return number
    }
    let provenance = try scalarProvenance(data["provenance"], protocolVersion: args.protocolVersion)
    var row = ProjectionRow()
    row.add("ts", numberJSON(ts))
    switch stream {
    case "stepSample":
        guard let counter = try integer(data["counter"]) else { throw invalid() }
        let activity = try integer(data["activityClass"], optional: true)
        guard counter >= 0, counter <= 65535 else { throw invalid() }
        if let activity, activity < 0 || activity > 2 { throw invalid() }
        row.add("counter", numberJSON(counter))
        row.add("activity_class", activity.map(numberJSON) ?? .null)
    case "sleepStateSample":
        guard let state = try integer(data["state"]) else { throw invalid() }
        let raw = try integer(data["rawByte"], optional: true)
        guard state >= 0, state <= 3 else { throw invalid() }
        if let raw {
            guard raw >= 0, raw <= 255, ((Int64(raw) >> 4) & 3) == Int64(state) else { throw invalid() }
        }
        row.add("state", numberJSON(state))
        row.add("raw_byte", raw.map(numberJSON) ?? .null)
    default:
        guard let bpm = try integer(data["bpm"]) else { throw invalid() }
        guard bpm > 0 else { throw invalid() }
        var conf: ProjectionJSON = .null
        if let value = data["conf"], !(value is NSNull) {
            guard let number = ProjectionCoercion.strictNumber(value), number >= 0, number <= 1 else { throw invalid() }
            conf = numberJSON(number)
        }
        row.add("bpm", numberJSON(bpm))
        row.add("conf", conf)
    }
    if args.protocolVersion == "1.4" { row.add("provenance", provenance ?? .null) }
    return row
}

private let scalarProvenanceKeys: Set<String> = [
    "v", "origin", "recordIndex", "frameSHA256", "algorithm", "sampleRateHz",
    "windowSettingSeconds", "inputStartTs", "inputEndTs", "inputSHA256", "inputSelection",
]
private let scalarProvenanceIntegerKeys: Set<String> = [
    "recordIndex", "sampleRateHz", "windowSettingSeconds", "inputStartTs", "inputEndTs",
]
private let scalarProvenanceDerivation = [
    "algorithm", "sampleRateHz", "windowSettingSeconds", "inputStartTs", "inputEndTs", "inputSHA256",
]

/// `scalarProvenance` from the pinned `scalarProvenance.ts`. Absent provenance stays unknown.
/// Never inferred from current flags or scalar values.
func scalarProvenance(_ value: Any?, protocolVersion: String) throws -> ProjectionJSON? {
    guard let value, !(value is NSNull) else { return nil }
    func invalid() -> PushBatch.ProjectionError { .invalidScalarProvenance }
    guard protocolVersion == "1.4", let object = value as? [String: Any] else { throw invalid() }
    var ordered = ProjectionRow()
    for key in object.keys.sorted() { ordered.add(key, projectionJSON(from: object[key]!)) }
    guard ordered.jsonText().utf8.count <= 1024 else { throw invalid() }
    guard ProjectionCoercion.strictNumber(object["v"]) == 1 else { throw invalid() }
    guard let origin = object["origin"] as? String,
          ["whoop-v18", "whoop-v26-ppg-derived", "legacy-unknown"].contains(origin) else { throw invalid() }
    for (key, field) in object {
        guard scalarProvenanceKeys.contains(key) else { throw invalid() }
        guard !(field is NSNull), !(field is [String: Any]), !(field is [Any]) else { throw invalid() }
        if let number = field as? NSNumber, isBooleanNumber(number) { throw invalid() }
        if scalarProvenanceIntegerKeys.contains(key) {
            guard let number = ProjectionCoercion.strictSafeInteger(field) else { throw invalid() }
            if key == "recordIndex", number < 0 || number > 4294967295 { throw invalid() }
            if key == "sampleRateHz" || key == "windowSettingSeconds", number <= 0 { throw invalid() }
        }
        if key == "frameSHA256" || key == "inputSHA256" {
            guard let text = field as? String, isLowercaseHex(text, length: 64) else { throw invalid() }
        }
        if key == "algorithm" {
            guard let text = field as? String, ["ppg-acf-v1", "ppg-acf-sublag-v1"].contains(text) else { throw invalid() }
        }
        if key == "inputSelection" {
            guard let text = field as? String,
                  ["last-record-per-second-v1", "concat-records-per-second-v1"].contains(text) else { throw invalid() }
        }
    }
    let inputStart = object["inputStartTs"], inputEnd = object["inputEndTs"]
    if let start = inputStart, !(start is NSNull), let end = inputEnd, !(end is NSNull) {
        guard let startNumber = ProjectionCoercion.finiteNumber(start),
              let endNumber = ProjectionCoercion.finiteNumber(end), endNumber > startNumber else { throw invalid() }
    }
    func present(_ name: String) -> Bool {
        guard let field = object[name] else { return false }
        return !(field is NSNull)
    }
    if origin == "whoop-v26-ppg-derived" {
        guard !present("recordIndex"), !present("frameSHA256"),
              scalarProvenanceDerivation.allSatisfy(present) else { throw invalid() }
    } else {
        guard !present("inputSelection"), scalarProvenanceDerivation.allSatisfy({ !present($0) }) else { throw invalid() }
        if origin == "legacy-unknown" { guard !present("recordIndex"), !present("frameSHA256") else { throw invalid() } }
    }
    return .object(ordered)
}

// MARK: - Small validators

func isLowercaseHex(_ text: String, length: Int? = nil) -> Bool {
    if let length, text.count != length { return false }
    guard !text.isEmpty else { return false }
    for scalar in text.unicodeScalars {
        let value = scalar.value
        let isDigit = value >= 48 && value <= 57
        let isLower = value >= 97 && value <= 102
        if !isDigit && !isLower { return false }
    }
    return true
}

func isLowercaseHexUuid(_ text: String) -> Bool {
    let parts = text.split(separator: "-", omittingEmptySubsequences: false)
    guard parts.count == 5, [8, 4, 4, 4, 12].elementsEqual(parts.map(\.count)) else { return false }
    return parts.allSatisfy { isLowercaseHex(String($0)) }
}

/// `/^(0|[1-9][0-9]{0,18})$/`
func isDecimalMonotonic(_ text: String) -> Bool {
    guard let first = text.first else { return false }
    if first == "0" { return text.count == 1 }
    guard first.isNumber, text.count <= 19 else { return false }
    return text.allSatisfy { $0.isNumber && $0.isASCII }
}

private extension ProjectionJSON {
    var isNull: Bool { if case .null = self { return true }; return false }
}

// MARK: - Append conflict-key validation (port of _shared/appendProjection.ts)

enum ProjectionConflictKeyType {
    case uuid, bigint, integer, text
}

/// Types of every column currently used by an append projection's PostgreSQL conflict key.
let projectionConflictKeyTypes: [String: ProjectionConflictKeyType] = [
    "user_id": .uuid, "device_id": .uuid, "ts": .bigint, "rrMs": .integer, "seq": .integer,
    "packetId": .text, "receiptId": .text, "kind": .text,
]

/// Encode one projected conflict-key value exactly as the receiver does, so that two rows the
/// database would consider identical are always considered identical here.
func projectionKeyPart(column: String, value: ProjectionJSON?) throws -> String {
    guard let value else { throw PushBatch.ProjectionError.invalidRecordKey(column) }
    switch projectionConflictKeyTypes[column] {
    case .bigint, .integer:
        let number: Double
        switch value {
        case .int(let raw): number = Double(raw)
        case .double(let raw): number = raw
        default: throw PushBatch.ProjectionError.invalidRecordKey(column)
        }
        guard ProjectionCoercion.isSafeInteger(number) else { throw PushBatch.ProjectionError.invalidRecordKey(column) }
        if projectionConflictKeyTypes[column] == .integer, number < -2147483648 || number > 2147483647 {
            throw PushBatch.ProjectionError.invalidRecordKey(column)
        }
        return ProjectionCoercion.numberString(number)
    case .uuid:
        guard case .string(let text) = value else { throw PushBatch.ProjectionError.invalidRecordKey(column) }
        var normalized = text
        if normalized.hasPrefix("{"), normalized.hasSuffix("}"), normalized.count >= 2 {
            normalized = String(normalized.dropFirst().dropLast())
        }
        normalized = normalized.replacingOccurrences(of: "-", with: "").lowercased()
        guard isLowercaseHex(normalized, length: 32) else { throw PushBatch.ProjectionError.invalidRecordKey(column) }
        return normalized
    case .text:
        guard case .string(let text) = value else { throw PushBatch.ProjectionError.invalidRecordKey(column) }
        return text
    case nil:
        // A future conflict-column type must get an explicit database-compatible encoding.
        throw PushBatch.ProjectionError.unsupportedConflictColumn(column)
    }
}

/// Reject repeated projected identities across the entire batch before any chunk is written.
func validateAppendProjectionRows(_ rows: [ProjectionRow], onConflict: String) throws {
    let columns = onConflict.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    var seen = Set<String>()
    for row in rows {
        var parts: [String] = []
        for column in columns { parts.append(try projectionKeyPart(column: column, value: row[column])) }
        let key = "[" + parts.map(ProjectionJSON.encodeString).joined(separator: ",") + "]"
        guard seen.insert(key).inserted else { throw PushBatch.ProjectionError.duplicateRecordKey(key) }
    }
}

// MARK: - Replace-window bounds

struct ProjectionWindowBounds {
    let selector: ProjectionWindowSelector
    let replacementId: String
    let part: Int
    let parts: Int
    /// Numeric coordinate space: days-since-epoch x 86400 for `day`, epoch seconds for `startTs`.
    let start: Double
    let end: Double
}

/// `(value - '1970-01-01')::numeric * 86400` for a `date`-typed day string.
func projectionDayNumber(_ text: String) -> Double? {
    let day = String(text.prefix(10))
    let parts = day.split(separator: "-")
    guard parts.count == 3, let year = Int(parts[0]), let month = Int(parts[1]), let dayOfMonth = Int(parts[2]),
          month >= 1, month <= 12, dayOfMonth >= 1, dayOfMonth <= 31 else { return nil }
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = dayOfMonth
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    guard let date = calendar.date(from: components) else { return nil }
    return (date.timeIntervalSince1970 / 86400).rounded(.down)
}

/// `extract(epoch from value::timestamptz)`
func projectionEpochSeconds(_ text: String) -> Double? {
    if let date = projectionISO8601WithFraction.date(from: text) { return date.timeIntervalSince1970 }
    if let date = projectionISO8601.date(from: text) { return date.timeIntervalSince1970 }
    return nil
}

private let projectionISO8601WithFraction: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private let projectionISO8601: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

/// Structural checks mirror `noop_commit_push_projection_intake_core`, which raises
/// `invalid_window` for a missing/mismatched selector, missing bounds or out-of-range parts.
/// Returns `nil` when the bounds themselves cannot be parsed; the server is then the authority.
func projectionWindowBounds(stream: String, projection: StreamProjection, window: [String: Any]?) throws -> ProjectionWindowBounds? {
    guard let window else { throw PushBatch.ProjectionError.invalidWindow("missing window") }
    guard let selectorRaw = window["selector"] as? String,
          let selector = ProjectionWindowSelector(rawValue: selectorRaw) else {
        throw PushBatch.ProjectionError.invalidWindow("missing or unknown window selector")
    }
    guard selector == projection.windowSelector else {
        throw PushBatch.ProjectionError.invalidWindow("selector \(selectorRaw) does not match stream \(stream)")
    }
    guard let replacementRaw = window["replacementId"], !(replacementRaw is NSNull) else {
        throw PushBatch.ProjectionError.invalidWindow("missing replacementId")
    }
    func integerPart(_ value: Any?) -> Int? {
        guard let value, !(value is NSNull) else { return nil }
        if let number = value as? NSNumber, !isBooleanNumber(number) {
            let double = number.doubleValue
            guard ProjectionCoercion.isInteger(double) else { return nil }
            return Int(double)
        }
        return Int(jsString(value))
    }
    guard let part = integerPart(window["part"]), let parts = integerPart(window["parts"]),
          part >= 1, parts >= 1, part <= parts, parts <= 128 else {
        throw PushBatch.ProjectionError.invalidWindow("invalid window part bounds")
    }
    guard let startInclusive = window["startInclusive"], !(startInclusive is NSNull),
          let endExclusive = window["endExclusive"], !(endExclusive is NSNull) else {
        throw PushBatch.ProjectionError.invalidWindow("missing window bounds")
    }
    let replacementId = jsString(replacementRaw)
    switch selector {
    case .day:
        guard let start = projectionDayNumber(jsString(startInclusive)),
              let end = projectionDayNumber(jsString(endExclusive)), end > start else { return nil }
        return ProjectionWindowBounds(selector: selector, replacementId: replacementId, part: part, parts: parts,
                                      start: start * 86400, end: end * 86400)
    case .startTs:
        guard let start = ProjectionCoercion.finiteNumber(startInclusive),
              let end = ProjectionCoercion.finiteNumber(endExclusive), end > start else { return nil }
        return ProjectionWindowBounds(selector: selector, replacementId: replacementId, part: part, parts: parts,
                                      start: start, end: end)
    }
}

/// `noop_projection_coordinate(stream, row)` — `day` for the day-selected streams, `start_at` otherwise.
func projectionCoordinate(stream: String, row: ProjectionRow) -> Double? {
    if stream == "dailyMetric" || stream == "journal" {
        guard case .string(let day)? = row["day"] else { return nil }
        guard let number = projectionDayNumber(day) else { return nil }
        return number * 86400
    }
    guard case .string(let startAt)? = row["start_at"] else { return nil }
    return projectionEpochSeconds(startAt)
}

// MARK: - PushBatch

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

    /// Projection failures. Every case is a hard failure for the batch: the receiver never
    /// commits a partial batch, and an ACK must not claim rows a mapper discarded.
    enum ProjectionError: Error, CustomStringConvertible {
        case unsupportedStream(String)
        case unsupportedDelivery(String)
        case unsupportedProjection(String)
        case invalidRecord(stream: String, index: Int)
        case invalidScalarRecord(String)
        case invalidScalarProvenance
        case invalidRecordKey(String)
        case duplicateRecordKey(String)
        case unsupportedConflictColumn(String)
        case invalidTimestamp(String)
        case invalidWindow(String)
        case rowOutsideWindow(String)
        case foreignOwnership(String)

        var description: String {
            switch self {
            case .unsupportedStream(let stream): return "unsupported_projection: stream \(stream) has no projection"
            case .unsupportedDelivery(let detail): return "unsupported_delivery: \(detail)"
            case .unsupportedProjection(let detail): return "unsupported_projection: \(detail)"
            case .invalidRecord(let stream, let index): return "invalid_record: \(stream) record \(index) does not satisfy the receiver registry"
            case .invalidScalarRecord(let stream): return "invalid_scalar_record: \(stream)"
            case .invalidScalarProvenance: return "invalid_scalar_provenance"
            case .invalidRecordKey(let column): return "invalid_record_key: \(column)"
            case .duplicateRecordKey(let key): return "duplicate_record_key: \(key)"
            case .unsupportedConflictColumn(let column): return "unsupported_append_conflict_column: \(column)"
            case .invalidTimestamp(let detail): return "invalid_record_timestamp: \(detail)"
            case .invalidWindow(let detail): return "invalid_window: \(detail)"
            case .rowOutsideWindow(let detail): return "projection_outside_window: \(detail)"
            case .foreignOwnership(let detail): return "projection_owner_mismatch: \(detail)"
            }
        }
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
    let window: [String: Any]?    // replace_window only
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

    /// `header.window?.replacementId || header.batchId` from the pinned ingest path.
    var replacementId: String {
        if let raw = window?["replacementId"], !(raw is NSNull), ProjectionCoercion.isTruthy(raw) {
            return jsString(raw)
        }
        return batchId
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
        guard let headerLine = lines.next() else { throw DecodeError.malformed("empty_ndjson") }
        guard let header = decodeJSONObject(headerLine.data(using: .utf8)!) else {
            throw DecodeError.malformed("malformed_batch_header")
        }
        guard header["type"] as? String == "batch" else {
            throw DecodeError.malformed("missing_batch_header")
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
                throw DecodeError.malformed("malformed_record_line")
            }
            // The receiver rejects a line that is not a record; it never skips one.
            guard obj["type"] as? String == "record" else {
                throw DecodeError.malformed("invalid_record_line")
            }
            records.append(obj)
        }
        if records.count != recordCount {
            throw DecodeError.malformed("record_count_mismatch: header \(recordCount) != decoded \(records.count)")
        }
        return PushBatch(
            batchId: batchId, sourceId: sourceId, deviceId: deviceId, stream: stream,
            delivery: delivery, protocolVersion: protocolVersion, recordCount: recordCount,
            startCursor: cursor(header["startCursor"]), endCursor: cursor(header["endCursor"]),
            window: header["window"] as? [String: Any], records: records
        )
    }
}

// MARK: - Typed projection API

extension PushBatch {
    /// The stream's projection, or `nil` when the receiver has no projection for it.
    var streamProjection: StreamProjection? { ProjectionRegistry.projection(for: stream) }

    func mapArgs(index: Int, userId: String, deviceId: String, protocolVersion: String, computedAt: String) -> ProjectionMapArgs {
        ProjectionMapArgs(
            userId: userId,
            deviceId: deviceId,
            headerDeviceId: deviceId0(deviceId),
            sourceId: sourceId,
            batchId: batchId,
            replacementId: replacementId,
            protocolVersion: protocolVersion,
            record: records[index],
            computedAt: computedAt
        )
    }

    /// The header device identifier is the external device string on the wire.
    private func deviceId0(_ canonical: String) -> String { deviceId }

    /// Map every record through the typed registry, in wire order.
    ///
    /// - Parameters:
    ///   - userId: canonical owner (the manifest's `user_id`).
    ///   - deviceId: canonical `devices.id` (the manifest's `device_id`).
    ///   - protocolVersion: overrides the header value when the caller knows the negotiated one.
    ///   - computedAt: fixed projection clock for `daily_metrics.computed_at`; defaults to now.
    func typedProjectionRows(userId: String, deviceId: String,
                             protocolVersion: String? = nil,
                             computedAt: Date? = nil) throws -> [ProjectionRow] {
        let version = protocolVersion ?? self.protocolVersion
        let clock = try ProjectionCoercion.isoString(epochSeconds: (computedAt ?? Date()).timeIntervalSince1970)
        guard let projection = ProjectionRegistry.projection(for: stream) else {
            throw ProjectionError.unsupportedStream(stream)
        }
        guard let delivery = ProjectionDelivery(rawValue: self.delivery) else {
            throw ProjectionError.unsupportedDelivery(self.delivery)
        }
        switch (delivery, projection.delivery) {
        case (.append, .append), (.replaceWindow, .replaceWindow):
            break
        case (.append, .replaceWindow):
            throw ProjectionError.unsupportedDelivery("append delivery for replace-window stream \(stream)")
        case (.replaceWindow, .append):
            throw ProjectionError.unsupportedProjection("replace_window delivery for append stream \(stream)")
        }
        var bounds: ProjectionWindowBounds?
        if delivery == .replaceWindow {
            bounds = try projectionWindowBounds(stream: stream, projection: projection, window: window)
        }
        var rows: [ProjectionRow] = []
        rows.reserveCapacity(records.count)
        for index in records.indices {
            let args = mapArgs(index: index, userId: userId, deviceId: deviceId,
                               protocolVersion: version, computedAt: clock)
            try validateRecordOwnership(args)
            guard let row = try projection.mapRow(args) else {
                throw ProjectionError.invalidRecord(stream: stream, index: index)
            }
            try validateRowIdentity(row, userId: userId, deviceId: deviceId)
            if let bounds {
                // `noop_projection_coordinate` must be non-null and inside the window.
                guard let coordinate = projectionCoordinate(stream: stream, row: row) else {
                    throw ProjectionError.rowOutsideWindow("\(stream) row \(index) has no projection coordinate")
                }
                guard coordinate >= bounds.start, coordinate < bounds.end else {
                    throw ProjectionError.rowOutsideWindow("\(stream) row \(index) coordinate \(coordinate) outside [\(bounds.start), \(bounds.end))")
                }
            }
            rows.append(row)
        }
        if delivery == .append {
            try validateAppendProjectionRows(rows, onConflict: projection.onConflict)
        }
        return rows
    }

    /// Legacy dictionary form of `typedProjectionRows`, kept for existing callers.
    /// Field order is not preserved by a Swift dictionary; use `canonicalProjectionRowsJSON`
    /// or `typedProjectionRows` when the byte-level field order matters.
    func projectionRows(userId: String, deviceId: String,
                        protocolVersion: String? = nil,
                        computedAt: Date? = nil) throws -> [[String: Any]] {
        try typedProjectionRows(userId: userId, deviceId: deviceId,
                                protocolVersion: protocolVersion, computedAt: computedAt).map(\.dictionary)
    }

    /// Deterministic JSON array of the mapped rows: canonical field order, no dictionary iteration.
    func canonicalProjectionRowsJSON(userId: String, deviceId: String,
                                     protocolVersion: String? = nil,
                                     computedAt: Date? = nil) throws -> Data {
        let rows = try typedProjectionRows(userId: userId, deviceId: deviceId,
                                           protocolVersion: protocolVersion, computedAt: computedAt)
        let text = "[" + rows.map { $0.jsonText() }.joined(separator: ",") + "]"
        guard let data = text.data(using: .utf8) else {
            throw ProjectionError.unsupportedProjection("row encoding is not UTF-8")
        }
        return data
    }

    /// `keep_keys` for `replace_window` streams: the natural key of every record in this batch,
    /// deduplicated in first-occurrence order. Append streams have no replacement keys.
    ///
    /// The compound keys come from the stream's `rowKey` (`day|question`,
    /// `sleep:<headerDeviceId>:<startTs>`, `workout:<headerDeviceId>:<startTs>:<sport>`), never
    /// from iterating a dictionary.
    func keepKeys() throws -> [String] {
        guard let projection = ProjectionRegistry.projection(for: stream),
              projection.delivery == .replaceWindow,
              let rowKey = projection.rowKey else { return [] }
        var seen = Set<String>()
        var keys: [String] = []
        for index in records.indices {
            guard records[index]["key"] is [String: Any] else {
                throw DecodeError.malformed("record without key")
            }
            let args = mapArgs(index: index, userId: "", deviceId: "",
                               protocolVersion: protocolVersion, computedAt: "")
            let key = rowKey(args)
            guard !key.isEmpty else { continue }
            if seen.insert(key).inserted { keys.append(key) }
        }
        return keys
    }

    /// A record may not declare an owner, device, source or batch that differs from the manifest
    /// identity it is being projected under. The pinned registry silently ignores those members;
    /// ignoring them is unsafe here, because the previous worker merged `data` over `key` and let
    /// a record overwrite `user_id`/`device_id`. The canonical values are always used to build the
    /// row, so this check is defence in depth rather than the primary control.
    func validateRecordOwnership(_ args: ProjectionMapArgs) throws {
        let expected: [String: String] = [
            "user_id": args.userId,
            "device_id": args.deviceId,
            "source_id": args.sourceId,
            "batch_id": args.batchId,
        ]
        for (field, canonical) in expected {
            for (container, label) in [(args.key, "key"), (args.data, "data")] {
                guard let value = container[field], !(value is NSNull) else { continue }
                guard let text = value as? String else {
                    throw ProjectionError.foreignOwnership("\(label).\(field) is not a string")
                }
                var accepted = [canonical.lowercased()]
                // A record may name the external device string instead of the canonical uuid.
                if field == "device_id" { accepted.append(args.headerDeviceId.lowercased()) }
                guard accepted.contains(text.lowercased()) else {
                    throw ProjectionError.foreignOwnership("\(label).\(field)=\(text) does not match the batch identity")
                }
            }
        }
    }

    /// The server rejects a row whose owner/device does not match the manifest
    /// (`projection_owner_mismatch`); `daily_metrics` carries its device in `source_device_id`.
    func validateRowIdentity(_ row: ProjectionRow, userId: String, deviceId: String) throws {
        guard case .string(let rowUser)? = row["user_id"], rowUser.lowercased() == userId.lowercased() else {
            throw ProjectionError.foreignOwnership("row user_id does not match the manifest owner")
        }
        let rowDevice: String?
        switch row["device_id"] {
        case .string(let value)?: rowDevice = value
        default:
            if case .string(let value)? = row["source_device_id"] { rowDevice = value } else { rowDevice = nil }
        }
        guard let rowDevice, rowDevice.lowercased() == deviceId.lowercased() else {
            throw ProjectionError.foreignOwnership("row device_id does not match the manifest device")
        }
    }
}

private func decodeJSONObject(_ data: Data) -> [String: Any]? {
    (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

// MARK: - Strict gzip verification
//
// The lane's existing `Inflator.gunzip` stops when `inflate` stops making progress, so a gzip
// object whose trailer is missing returns a *partial* body with no error. This additive entry
// point requires the member to reach `Z_STREAM_END`, validates the 4-byte ISIZE trailer and the
// CRC32 trailer explicitly, and rejects bytes after the last member. It does not modify
// `Inflator.gunzip`; the projection lane can adopt it with a one-line change.

extension Inflator {
    /// Strict RFC1952 decode: every member must terminate, and its CRC32 and ISIZE must match.
    static func gunzipStrict(_ input: Data) throws -> Data {
        guard !input.isEmpty else { throw WorkerError.io("empty gzip object") }
        var offset = 0
        var output = Data()
        while offset < input.count {
            let base = input.startIndex + offset
            func byte(_ index: Int) -> UInt8 { input[base + index] }
            let available = input.count - offset
            guard available >= 10 else { throw WorkerError.io("gzip header truncated") }
            guard byte(0) == 0x1f, byte(1) == 0x8b else { throw WorkerError.io("not a gzip member") }
            guard byte(2) == 0x08 else { throw WorkerError.io("unsupported gzip compression method \(byte(2))") }
            let flags = byte(3)
            guard flags & 0xe0 == 0 else { throw WorkerError.io("reserved gzip flag bits set") }
            var cursor = 10
            if flags & 0x04 != 0 {
                guard available >= cursor + 2 else { throw WorkerError.io("gzip FEXTRA truncated") }
                let extraLength = Int(byte(cursor)) | (Int(byte(cursor + 1)) << 8)
                cursor += 2 + extraLength
                guard available >= cursor else { throw WorkerError.io("gzip FEXTRA truncated") }
            }
            if flags & 0x08 != 0 {
                while cursor < available, byte(cursor) != 0 { cursor += 1 }
                guard cursor < available else { throw WorkerError.io("gzip FNAME truncated") }
                cursor += 1
            }
            if flags & 0x10 != 0 {
                while cursor < available, byte(cursor) != 0 { cursor += 1 }
                guard cursor < available else { throw WorkerError.io("gzip FCOMMENT truncated") }
                cursor += 1
            }
            if flags & 0x02 != 0 {
                cursor += 2
                guard available >= cursor else { throw WorkerError.io("gzip FHCRC truncated") }
            }
            let deflateStart = offset + cursor
            guard input.count > deflateStart else { throw WorkerError.io("gzip deflate stream missing") }

            var stream = z_stream()
            let initStatus = CZlib.inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
            guard initStatus == Z_OK else { throw WorkerError.io("inflateInit failed \(initStatus)") }
            defer { CZlib.inflateEnd(&stream) }

            var source = [UInt8](input[(input.startIndex + deflateStart)...])
            var member = Data()
            var consumed = 0
            var status: Int32 = Z_OK
            var terminated = false
            source.withUnsafeMutableBufferPointer { sourceBuffer in
                stream.next_in = sourceBuffer.baseAddress
                stream.avail_in = uInt(sourceBuffer.count)
                while true {
                    var chunk = [UInt8](repeating: 0, count: 1 << 16)
                    var produced = 0
                    chunk.withUnsafeMutableBufferPointer { outputBuffer in
                        stream.next_out = outputBuffer.baseAddress
                        stream.avail_out = uInt(outputBuffer.count)
                        status = CZlib.inflate(&stream, Z_NO_FLUSH)
                        produced = outputBuffer.count - Int(stream.avail_out)
                    }
                    if produced > 0 { member.append(contentsOf: chunk[0..<produced]) }
                    if status == Z_STREAM_END { terminated = true; break }
                    if status != Z_OK && status != Z_BUF_ERROR { break }
                    if produced == 0 && (stream.avail_in == 0 || status == Z_BUF_ERROR) { break }
                    if member.count > maxOutputBytes { break }
                }
                consumed = Int(stream.total_in)
            }
            guard terminated, status == Z_STREAM_END else {
                throw WorkerError.io("gzip member did not reach Z_STREAM_END (truncated or corrupt): zlib \(status)")
            }
            guard member.count <= maxOutputBytes else { throw WorkerError.io("inflated output exceeds cap") }

            let trailerStart = deflateStart + consumed
            guard input.count - trailerStart >= 8 else { throw WorkerError.io("gzip trailer truncated") }
            let trailer = input.startIndex + trailerStart
            func trailerWord(_ index: Int) -> UInt32 {
                UInt32(input[trailer + index]) | (UInt32(input[trailer + index + 1]) << 8)
                    | (UInt32(input[trailer + index + 2]) << 16) | (UInt32(input[trailer + index + 3]) << 24)
            }
            let crcField = trailerWord(0)
            let isizeField = trailerWord(4)
            guard isizeField == UInt32(truncatingIfNeeded: member.count) else {
                throw WorkerError.io("gzip ISIZE mismatch: trailer \(isizeField) != \(member.count & 0xffffffff)")
            }
            guard crcField == gzipCRC32(member) else {
                throw WorkerError.io("gzip CRC32 mismatch: trailer \(crcField) != \(gzipCRC32(member))")
            }
            output.append(member)
            guard output.count <= maxOutputBytes else { throw WorkerError.io("inflated output exceeds cap") }
            offset = trailerStart + 8
        }
        return output
    }

    private static func gzipCRC32(_ data: Data) -> UInt32 {
        var value: uLong = CZlib.crc32(0, nil, 0)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress, raw.count > 0 else { return }
            value = CZlib.crc32(value, base.assumingMemoryBound(to: Bytef.self), uInt(raw.count))
        }
        return UInt32(truncatingIfNeeded: value)
    }
}

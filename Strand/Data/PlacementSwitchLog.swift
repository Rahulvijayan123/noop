import Foundation

/// Append-only record of every strap-placement switch and what it switched (hsmm-2.0).
///
/// A placement change re-derives a lot: the activity decoder's posture cues and its per-placement calibration, the
/// skin-temperature baseline stratum, the step-estimate calibration, the Watchdog's skin-temperature and IMU channels,
/// and (server side) physiology-context references and activity days. Each switch is written here as it happens and
/// again once the phone has recalculated, so the wearer and an exported log can see when the placement changed, from
/// what to what, and which calibrations were in use before and after. The server keeps its own append-only record
/// (`public.placement_change_events`).
///
/// Stored as JSON lines in Application Support (`OpenWhoop/PlacementSwitchLog.jsonl`), capped at `maxEntries`.
final class PlacementSwitchLog: @unchecked Sendable {
    static let shared = PlacementSwitchLog()
    static let maxEntries = 500

    struct Entry: Codable, Equatable, Identifiable {
        enum Kind: String, Codable {
            /// The wearer declared a new placement (Settings) or one arrived from another device (sync).
            case declared
            /// The phone finished switching what depends on placement.
            case recalculated
        }
        var id = UUID()
        var kind: Kind
        var at: Date
        var deviceId: String
        /// "settings" (this phone) or "sync" (pulled from the server).
        var source: String
        var from: String?
        var to: String
        var effectiveStart: Date?
        var revision: Int64?
        /// What switched, e.g. ["activity_posture_cues", "activity_calibration", "skin_temp_baseline", …].
        var switched: [String] = []
        /// Per-placement adopted calibration before / after (`ActivityPersonalProfileStore.adoptedSummary`).
        var calibrationBefore: String?
        var calibrationAfter: String?
        /// The activity decoder's config tag for today before / after (its `-pl` / `-pp` / `-ph` parts change).
        var decoderTagBefore: String?
        var decoderTagAfter: String?
        var note: String?
    }

    private let lock = NSLock()
    private let url: URL

    init(directory: URL? = nil) {
        let fm = FileManager.default
        let base = directory ?? ((try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)) ?? fm.temporaryDirectory)
            .appendingPathComponent("OpenWhoop", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        url = base.appendingPathComponent("PlacementSwitchLog.jsonl")
    }

    func append(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        var rows = readLocked()
        rows.append(entry)
        if rows.count > Self.maxEntries { rows.removeFirst(rows.count - Self.maxEntries) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let text = rows.compactMap { try? encoder.encode($0) }.compactMap { String(data: $0, encoding: .utf8) }
            .joined(separator: "\n") + "\n"
        try? text.data(using: .utf8)?.write(to: url, options: .atomic)
    }

    /// Newest first.
    func recent(_ limit: Int = 20) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        return Array(readLocked().suffix(limit).reversed())
    }

    private func readLocked() -> [Entry] {
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { try? decoder.decode(Entry.self, from: Data($0.utf8)) }
    }

    /// One strap-log line for an entry (goes out with the Test Centre export).
    static func logLine(_ e: Entry) -> String {
        let f = ISO8601DateFormatter()
        var line = "Placement \(e.kind.rawValue): \(e.from ?? "none") -> \(e.to) via \(e.source)"
        if let start = e.effectiveStart { line += " effective \(f.string(from: start))" }
        if let rev = e.revision { line += " rev \(rev)" }
        if !e.switched.isEmpty { line += " switched [\(e.switched.joined(separator: ","))]" }
        if let b = e.calibrationBefore, let a = e.calibrationAfter, b != a { line += " calibration \(b) => \(a)" }
        if let b = e.decoderTagBefore, let a = e.decoderTagAfter, b != a { line += " decoder \(b) => \(a)" }
        if let n = e.note { line += " (\(n))" }
        return line
    }
}

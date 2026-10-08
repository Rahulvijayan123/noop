import Foundation
import StrandAnalytics

/// HART's per-window output fetched from the server (`GET scores/activity-windows`), kept on disk so the
/// phone's activity decoder can use it.
///
/// The server runs HART over the raw motion this phone uploads and stores the windows per UTC day. The
/// decoder that draws the Heart rate page runs here, on the strap's own streams; this store is how the
/// windows reach it (`Repository.activityContext(from:)`). Each UTC day is one file holding the server's
/// `hart-windows-1` object and its result revision, under the account and strap it belongs to, so another
/// account signing in on this phone never decodes with someone else's windows.
///
/// Thread-safe: the decoder input is assembled off the main actor.
final class ActivityEncoderWindowStore: @unchecked Sendable {
    static let shared = ActivityEncoderWindowStore()

    struct Scope: Codable, Equatable, Sendable {
        var ownerId: String
        /// The id the server knows the strap by (`whoop-<serial>`).
        var deviceId: String
    }

    /// One stored UTC day as the route returned it.
    struct DayRecord: Codable, Equatable {
        var day: String
        var resultRevision: String
        var encoderId: String
        var modelVersion: String
        /// The `hart-windows-1` object, kept as the JSON text it arrived as.
        var windowsJSON: String
    }

    private let lock = NSLock()
    private let directory: URL
    private let defaults: UserDefaults
    private static let scopeKey = "activityEncoderWindowScope.v1"
    private var scope: Scope?
    /// Parsed days, so a decode does not re-parse megabytes of JSON: UTC day → (revision, set).
    private var parsed: [String: (revision: String, set: ActivityEncoderWindowSet?)] = [:]
    /// What each stored day is, without its windows: `revisions` and `save` only compare these, and used to decode
    /// the whole file (0.3–1 MB) to read them, on every sync pass, on the main actor.
    private struct Stamp: Equatable {
        let resultRevision: String
        let encoderId: String
        let modelVersion: String
        init(_ record: DayRecord) {
            resultRevision = record.resultRevision
            encoderId = record.encoderId
            modelVersion = record.modelVersion
        }
    }
    private var stamps: [String: Stamp] = [:]

    init(directory: URL? = nil, defaults: UserDefaults = .standard) {
        let fm = FileManager.default
        let base = directory ?? ((try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)) ?? fm.temporaryDirectory)
            .appendingPathComponent("OpenWhoop/ActivityWindows", isDirectory: true)
        self.directory = base
        self.defaults = defaults
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = defaults.data(forKey: Self.scopeKey) {
            scope = try? JSONDecoder().decode(Scope.self, from: data)
        }
    }

    // MARK: Scope

    /// The account and strap whose windows the decoder should use. Set by the sync before it stores anything.
    func setScope(_ new: Scope?) {
        lock.lock(); defer { lock.unlock() }
        guard new != scope else { return }
        scope = new
        parsed = [:]
        stamps = [:]
        if let new, let data = try? JSONEncoder().encode(new) { defaults.set(data, forKey: Self.scopeKey) }
        else { defaults.removeObject(forKey: Self.scopeKey) }
    }

    var currentScope: Scope? {
        lock.lock(); defer { lock.unlock() }
        return scope
    }

    /// Sign-out: forget the scope (the files stay with their account and are read again if it returns).
    func reset() { setScope(nil) }

    // MARK: Days

    /// The stored result revision of each of `days`, for the route's `known` parameter.
    func revisions(days: [String]) -> [String: String] {
        lock.lock(); defer { lock.unlock() }
        guard let scope else { return [:] }
        var out: [String: String] = [:]
        for day in days {
            if let hit = parsed[day] {
                if !hit.revision.isEmpty { out[day] = hit.revision }
            } else if let stamp = stamp(day: day, scope: scope) {
                out[day] = stamp.resultRevision
            }
        }
        return out
    }

    /// Store a day the route returned with its windows. Returns true when it is a different result from the
    /// one stored (another revision, encoder or model).
    @discardableResult
    func save(_ record: DayRecord, scope expected: Scope) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard scope == expected, let url = file(day: record.day, scope: expected) else { return false }
        // The server's result revision names the content; the JSON text of the same set can differ in key order.
        if let existing = stamp(day: record.day, scope: expected), existing == Stamp(record) { return false }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record), (try? data.write(to: url, options: .atomic)) != nil else {
            stamps[record.day] = nil
            return false
        }
        parsed[record.day] = nil
        stamps[record.day] = Stamp(record)
        return true
    }

    /// The stored day's stamp, read from its file once (lock held).
    private func stamp(day: String, scope: Scope) -> Stamp? {
        if let cached = stamps[day] { return cached }
        guard let record = readRecord(day: day, scope: scope) else { return nil }
        let stamp = Stamp(record)
        stamps[day] = stamp
        return stamp
    }

    /// The windows that END inside `[from, to)` (the decoder keys a window by its end second), from every
    /// stored UTC day overlapping it; nil when there are none.
    func windows(from: Int, to: Int) -> ActivityEncoderWindowSet? {
        guard to > from else { return nil }
        lock.lock(); defer { lock.unlock() }
        guard let scope else { return nil }
        var sets: [ActivityEncoderWindowSet] = []
        for day in Self.utcDays(from: from, to: to) {
            if let set = parsedSet(day: day, scope: scope) { sets.append(set) }
        }
        guard let merged = ActivityEncoderWindowSet.merged(sets)?.clipped(from: from, to: to),
              !merged.isEmpty else { return nil }
        return merged
    }

    /// UTC calendar days ("yyyy-MM-dd") overlapping `[from, to)`.
    static func utcDays(from: Int, to: Int) -> [String] {
        guard to > from else { return [] }
        var days: [String] = []
        var t = from - ((from % 86_400) + 86_400) % 86_400
        while t < to {
            days.append(utcDay(t))
            t += 86_400
        }
        return days
    }

    static func utcDay(_ ts: Int) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    // MARK: Private (lock held)

    /// Every write goes through `save`, which drops the day's parsed copy, so a cached parse is current.
    private func parsedSet(day: String, scope: Scope) -> ActivityEncoderWindowSet? {
        if let hit = parsed[day] { return hit.set }
        guard let record = readRecord(day: day, scope: scope) else {
            parsed[day] = ("", nil)
            return nil
        }
        let object = record.windowsJSON.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
        let set = ActivityEncoderWindowSet.decode(object, encoderId: record.encoderId,
                                                  encoderVersion: record.modelVersion)
        parsed[day] = (record.resultRevision, set)
        return set
    }

    private func readRecord(day: String, scope: Scope) -> DayRecord? {
        guard let url = file(day: day, scope: scope), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DayRecord.self, from: data)
    }

    private func file(day: String, scope: Scope) -> URL? {
        func safe(_ s: String) -> String? {
            let ok = !s.isEmpty && s.count <= 128 && s.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) }
            return ok && s != "." && s != ".." ? s : nil
        }
        guard let owner = safe(scope.ownerId.lowercased()), let device = safe(scope.deviceId),
              day.count == 10, let d = safe(day) else { return nil }
        return directory.appendingPathComponent(owner, isDirectory: true)
            .appendingPathComponent(device, isDirectory: true)
            .appendingPathComponent("\(d).json")
    }
}

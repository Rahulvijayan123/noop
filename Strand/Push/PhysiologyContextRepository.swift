import Foundation
import CryptoKit
import StrandAnalytics

// PhysiologyContextRepository.swift — the phone's read side of the physiology context layer
// (docs/physiology-context/contracts.md §8, §9).
//
// The server owns every value here. The phone reads two routes on the `scores` edge function:
//
//   GET {scores}/context?deviceId=&day=YYYY-MM-DD[&mode=][&metric=]   → {context: <read_v1>, identity}
//   GET {scores}/context/history?deviceId=&from=&to=[&mode=]          → {history: <history_read_v1>, identity}
//
// The outer envelope is read with JSONSerialization (unknown members are ignored, absent ones tolerated) and the
// document / arrays with `PhysiologyContext.decoder()` into the shared Swift types. A server that predates the
// routes answers 405, which is "context unavailable", never an error banner. Results are cached per owner on
// disk (owner-checked, atomic, pruned), exactly like `ServerScoreRepository.intradaySeries`.

// MARK: - Values

/// One device-day of physiology context as the server published it.
public struct PhysiologyContextDay: Sendable, Equatable {

    /// What the read RPC said about the day.
    public enum Status: String, Sendable, Equatable {
        /// A published context revision exists.
        case available
        /// A context job is queued or running and nothing is published yet.
        case pending
        /// No context exists for the day (and none is queued).
        case none
    }

    /// Whether the context was built from the same scoring result the phone shows.
    public struct Pairing: Sendable, Equatable {
        /// The scoring snapshot revision currently published for the day.
        public let snapshotResultRevision: String?
        /// The scoring snapshot revision the context was built from.
        public let contextScoringResultRevision: String?
        /// False when the two differ: the context is from an earlier result and must not be paired silently.
        public let consistent: Bool?
    }

    /// The context job's state, when the server reports one.
    public struct Job: Sendable, Equatable {
        public let pending: Bool
        public let dirtyAt: String?
    }

    public let day: String
    /// The device id that answered (one of the read candidates).
    public let deviceId: String
    /// The metric filter the read asked for (`MetricKind.rawValue`), nil for the whole document.
    public let metric: String?
    public let status: Status
    public let mode: PhysiologyContext.ProcessingMode?
    public let contextRevision: Int?
    public let finality: PhysiologyContext.Finality?
    public let document: PhysiologyContextDocument?
    public let pairing: Pairing?
    public let job: Job?
    /// When the phone read it (ms); 0 for a value that came straight from the network.
    public let fetchedAtMs: Int

    /// The document's processing mode, else the envelope's.
    public var effectiveMode: PhysiologyContext.ProcessingMode? {
        document?.header?.interpretation.mode ?? mode
    }

    /// The document's finality, else the envelope's.
    public var effectiveFinality: PhysiologyContext.Finality? {
        document?.header?.interpretation.finality ?? finality
    }
}

/// The day document, decoded member by member so one member the app cannot read (an older or newer server
/// shape) never costs the rest. `full` is the exact `DayDocument` when every member decoded.
public struct PhysiologyContextDocument: Sendable, Equatable {
    public let full: PhysiologyContext.DayDocument?
    public let header: PhysiologyContext.DocumentHeader?
    public let status: PhysiologyContext.ProductStatus?
    public let statusReasons: [PhysiologyContext.ReasonCode]
    public let availability: [PhysiologyContext.AvailabilityEntry]
    public let regimes: PhysiologyContext.RegimeTimeline?
    public let envelopes: [PhysiologyContext.MeasurementEnvelope]
    public let sleep: PhysiologyContext.SleepRhythmSummary?
    public let bouts: [PhysiologyContext.ExertionBout]
    public let exertion: [PhysiologyContext.ExertionWindowSummary]
    public let exposures: PhysiologyContext.ExposureDaySummary?
    public let dailyValues: [PhysiologyContext.DailyValue]
    public let comparisons: [PhysiologyContext.ReferenceComparison]
    public let episodes: [PhysiologyContext.ChangeEpisode]
    public let dependence: [PhysiologyContext.DependenceNote]
    /// Array elements that could not be decoded and were left out.
    public let undecodedElements: Int
    /// Members that were present but could not be decoded, by JSON name.
    public let undecodedMembers: [String]

    /// The IANA zone the day is interpreted in, when the header carried one.
    public var timezoneId: String? { header?.identity.timezoneId }

    /// Decode a document. Nil only when `data` is not a JSON object.
    public static func decode(_ data: Data) -> PhysiologyContextDocument? {
        let decoder = PhysiologyContext.decoder()
        guard let lenient = try? decoder.decode(LenientDayDocument.self, from: data) else { return nil }
        let full = try? decoder.decode(PhysiologyContext.DayDocument.self, from: data)
        return PhysiologyContextDocument(
            full: full, header: lenient.header, status: lenient.status,
            statusReasons: lenient.statusReasons.elements, availability: lenient.availability.elements,
            regimes: lenient.regimes, envelopes: lenient.envelopes.elements, sleep: lenient.sleep,
            bouts: lenient.bouts.elements, exertion: lenient.exertion.elements, exposures: lenient.exposures,
            dailyValues: lenient.dailyValues.elements, comparisons: lenient.comparisons.elements,
            episodes: lenient.episodes.elements, dependence: lenient.dependence.elements,
            undecodedElements: lenient.undecodedElements, undecodedMembers: lenient.undecodedMembers)
    }
}

/// Episodes, bouts and daily values over a range of days (`GET scores/context/history`).
public struct PhysiologyContextHistory: Sendable, Equatable {
    public let from: String
    public let to: String
    public let deviceId: String
    public let mode: PhysiologyContext.ProcessingMode?
    public let episodes: [PhysiologyContext.ChangeEpisode]
    public let bouts: [PhysiologyContext.ExertionBout]
    public let dailyValues: [PhysiologyContext.DailyValue]
    public let undecodedElements: Int
    public let fetchedAtMs: Int

    public var isEmpty: Bool { episodes.isEmpty && bouts.isEmpty && dailyValues.isEmpty }
}

/// The answer of one context read. Failures that asking again can fix are thrown instead.
public enum PhysiologyContextRead<Value: Sendable & Equatable>: Sendable, Equatable {
    case loaded(Value)
    /// The server predates the context routes (405). "Context unavailable", not an error.
    case unsupportedServer
    /// The account holds no such device yet (409 `device_registration_pending`).
    case deviceRegistrationPending
}

// MARK: - Repository

public actor PhysiologyContextRepository {

    public enum ReadError: Error, CustomStringConvertible, Equatable {
        case notConfigured
        case missingIdentity
        case http(Int, String?)
        case malformed(String)

        public var description: String {
            switch self {
            case .notConfigured: return "cloud: scores endpoint not configured"
            case .missingIdentity: return "cloud: no installation identity"
            case .http(let code, _): return "cloud: context HTTP \(code)"
            case .malformed(let why): return "cloud: malformed context response: \(why)"
            }
        }
    }

    private let session: URLSession
    private let endpoint: URL?
    private let identity: @Sendable () -> CloudPushIdentity?
    private let directory: URL
    private let now: @Sendable () -> Int

    /// Cache entries older than this are deleted on the next write.
    static let cacheRetention: TimeInterval = 14 * 86_400
    /// The history route serves at most this many days per read (contracts.md §8).
    public static let maxHistoryDays = 120

    /// `identity` supplies the credential to read with. The app passes one bound to the running account's scope
    /// (`CloudPushRuntime.credentialProvider`), so a repository made for account A never reads with B's.
    public init(session: URLSession = .shared,
                endpoint: URL? = nil,
                directory: URL? = nil,
                identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() },
                now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.session = session
        self.endpoint = endpoint ?? PhysiologyContextRepository.derivedEndpoint()
        self.directory = directory ?? ((try? CloudJournalPaths.defaultDirectory())
            .map { $0.appendingPathComponent("physiology-context", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("noop-physiology-context",
                                                                              isDirectory: true))
        self.identity = identity
        self.now = now
    }

    /// The `scores` edge route, derived from the push receiver exactly as `ServerScoreRepository` derives it.
    public static func derivedEndpoint() -> URL? { ServerScoreRepository.derivedEndpoint() }

    // MARK: Day context

    /// The day's context from the first of `deviceIds` that has one: an available document wins, then a
    /// pending one, then a "none" answer. A 405 from any candidate means the server has no context routes at
    /// all, so it ends the walk. Only when no candidate answered is the last failure thrown.
    public func dayContext(day: String, deviceIds: [String], metric: PhysiologyContext.MetricKind? = nil,
                           mode: PhysiologyContext.ProcessingMode? = nil)
        async throws -> PhysiologyContextRead<PhysiologyContextDay> {
        var firstPending: PhysiologyContextDay?
        var firstNone: PhysiologyContextDay?
        var registrationPending = false
        var lastFailure: Error?
        for id in Self.unique(deviceIds) {
            do {
                switch try await dayContext(day: day, deviceId: id, metric: metric, mode: mode) {
                case .unsupportedServer:
                    return .unsupportedServer
                case .deviceRegistrationPending:
                    registrationPending = true
                case .loaded(let value):
                    switch value.status {
                    case .available: return .loaded(value)
                    case .pending: firstPending = firstPending ?? value
                    case .none: firstNone = firstNone ?? value
                    }
                }
            } catch {
                lastFailure = error
            }
        }
        if let firstPending { return .loaded(firstPending) }
        if let firstNone { return .loaded(firstNone) }
        if registrationPending { return .deviceRegistrationPending }
        throw lastFailure ?? ReadError.missingIdentity
    }

    /// One device's day context. Caches every answer the server gave (a later "none" replaces an older
    /// document: the server withdrew it).
    public func dayContext(day: String, deviceId: String, metric: PhysiologyContext.MetricKind? = nil,
                           mode: PhysiologyContext.ProcessingMode? = nil)
        async throws -> PhysiologyContextRead<PhysiologyContextDay> {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }

        var components = URLComponents(url: endpoint.appendingPathComponent("context"),
                                       resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "deviceId", value: deviceId), URLQueryItem(name: "day", value: day)]
        if let mode { items.append(URLQueryItem(name: "mode", value: mode.rawValue)) }
        if let metric { items.append(URLQueryItem(name: "metric", value: metric.rawValue)) }
        components?.queryItems = items
        guard let url = components?.url else { throw ReadError.malformed("context endpoint") }

        let body: [String: Any]
        do {
            body = try await get(url: url, identity: identity)
        } catch let error as ReadError {
            if let mapped: PhysiologyContextRead<PhysiologyContextDay> = Self.mapped(error) { return mapped }
            throw error
        }
        // A 200 without the member is a server that does not speak this contract.
        guard body.keys.contains("context") else { return .unsupportedServer }
        let context = body["context"] as? [String: Any] ?? [:]
        let value = Self.parseDay(context: context, day: day, deviceId: deviceId, metric: metric?.rawValue,
                                  fetchedAtMs: 0)
        writeCache(context, ownerId: identity.ownerId, deviceId: deviceId,
                   key: Self.dayCacheKey(day: day, metric: metric, mode: mode))
        return .loaded(value)
    }

    /// The last cached context for the CURRENT owner, from the first candidate holding an available one (else
    /// the first cached answer). A pure local read: no network and no configuration requirement.
    public func cachedDayContext(day: String, deviceIds: [String], metric: PhysiologyContext.MetricKind? = nil,
                                 mode: PhysiologyContext.ProcessingMode? = nil) -> PhysiologyContextDay? {
        guard let ownerId = identity()?.ownerId else { return nil }
        var fallback: PhysiologyContextDay?
        for id in Self.unique(deviceIds) {
            guard let (payload, fetchedAt) = readCache(ownerId: ownerId, deviceId: id,
                                                       key: Self.dayCacheKey(day: day, metric: metric, mode: mode))
            else { continue }
            let value = Self.parseDay(context: payload, day: day, deviceId: id, metric: metric?.rawValue,
                                      fetchedAtMs: max(1, fetchedAt))
            if value.status == .available { return value }
            fallback = fallback ?? value
        }
        return fallback
    }

    // MARK: History

    /// Episodes, bouts and daily values from `from` through `to` (inclusive local days) from the first
    /// candidate with any; the range is clamped to the server's 120-day limit (the later end is kept).
    public func history(from: String, to: String, deviceIds: [String],
                        mode: PhysiologyContext.ProcessingMode? = nil)
        async throws -> PhysiologyContextRead<PhysiologyContextHistory> {
        let from = Self.clampedFrom(from, to: to)
        var firstEmpty: PhysiologyContextHistory?
        var registrationPending = false
        var lastFailure: Error?
        for id in Self.unique(deviceIds) {
            do {
                switch try await history(from: from, to: to, deviceId: id, mode: mode) {
                case .unsupportedServer: return .unsupportedServer
                case .deviceRegistrationPending: registrationPending = true
                case .loaded(let value):
                    if !value.isEmpty { return .loaded(value) }
                    firstEmpty = firstEmpty ?? value
                }
            } catch {
                lastFailure = error
            }
        }
        if let firstEmpty { return .loaded(firstEmpty) }
        if registrationPending { return .deviceRegistrationPending }
        throw lastFailure ?? ReadError.missingIdentity
    }

    public func history(from: String, to: String, deviceId: String, mode: PhysiologyContext.ProcessingMode? = nil)
        async throws -> PhysiologyContextRead<PhysiologyContextHistory> {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }
        var components = URLComponents(url: endpoint.appendingPathComponent("context/history"),
                                       resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "deviceId", value: deviceId), URLQueryItem(name: "from", value: from),
                     URLQueryItem(name: "to", value: to)]
        if let mode { items.append(URLQueryItem(name: "mode", value: mode.rawValue)) }
        components?.queryItems = items
        guard let url = components?.url else { throw ReadError.malformed("history endpoint") }

        let body: [String: Any]
        do {
            body = try await get(url: url, identity: identity)
        } catch let error as ReadError {
            if let mapped: PhysiologyContextRead<PhysiologyContextHistory> = Self.mapped(error) { return mapped }
            throw error
        }
        guard body.keys.contains("history") else { return .unsupportedServer }
        let history = body["history"] as? [String: Any] ?? [:]
        let value = Self.parseHistory(history, from: from, to: to, deviceId: deviceId, mode: mode, fetchedAtMs: 0)
        writeCache(history, ownerId: identity.ownerId, deviceId: deviceId,
                   key: Self.historyCacheKey(from: from, to: to, mode: mode))
        return .loaded(value)
    }

    public func cachedHistory(from: String, to: String, deviceIds: [String],
                              mode: PhysiologyContext.ProcessingMode? = nil) -> PhysiologyContextHistory? {
        guard let ownerId = identity()?.ownerId else { return nil }
        let from = Self.clampedFrom(from, to: to)
        var fallback: PhysiologyContextHistory?
        for id in Self.unique(deviceIds) {
            guard let (payload, fetchedAt) = readCache(ownerId: ownerId, deviceId: id,
                                                       key: Self.historyCacheKey(from: from, to: to, mode: mode))
            else { continue }
            let value = Self.parseHistory(payload, from: from, to: to, deviceId: id, mode: mode,
                                          fetchedAtMs: max(1, fetchedAt))
            if !value.isEmpty { return value }
            fallback = fallback ?? value
        }
        return fallback
    }

    // MARK: - Transport

    /// GET with the account's installation bearer only: no shared fleet token rides on these routes.
    private func get(url: URL, identity: CloudPushIdentity) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(identity.uploadToken)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ReadError.malformed("no response") }
        guard http.statusCode == 200 else {
            throw ReadError.http(http.statusCode, String(data: data, encoding: .utf8))
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ReadError.malformed("not a JSON object")
        }
        return object
    }

    /// The two HTTP answers that are states, not failures.
    private static func mapped<V: Sendable & Equatable>(_ error: ReadError) -> PhysiologyContextRead<V>? {
        guard case .http(let status, let body) = error else { return nil }
        if status == 405 { return .unsupportedServer }
        if ServerScoreRepository.isUnregisteredDevice(status: status, body: body) { return .deviceRegistrationPending }
        return nil
    }

    // MARK: - Parsing

    /// The inner `context` object (as served, or as cached) to a value. Every member is optional.
    static func parseDay(context: [String: Any], day: String, deviceId: String, metric: String?,
                         fetchedAtMs: Int) -> PhysiologyContextDay {
        let header = context["header"] as? [String: Any] ?? [:]
        func member(_ key: String) -> Any? {
            if let v = context[key], !(v is NSNull) { return v }
            if let v = header[key], !(v is NSNull) { return v }
            return nil
        }
        let document = (context["document"] as? [String: Any]).flatMap { object -> PhysiologyContextDocument? in
            guard JSONSerialization.isValidJSONObject(object),
                  let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return PhysiologyContextDocument.decode(data)
        }
        let status: PhysiologyContextDay.Status = (member("status") as? String)
            .flatMap(PhysiologyContextDay.Status.init(rawValue:))
            ?? (document != nil ? .available : .none)
        let pairing = (context["pairing"] as? [String: Any]).map { p in
            PhysiologyContextDay.Pairing(snapshotResultRevision: revisionString(p["snapshot_result_revision"]),
                                         contextScoringResultRevision: revisionString(p["context_scoring_result_revision"]),
                                         consistent: p["consistent"] as? Bool)
        }
        let job = (context["job"] as? [String: Any]).map { j in
            PhysiologyContextDay.Job(pending: (j["pending"] as? Bool) ?? false,
                                     dirtyAt: revisionString(j["dirty_at"]))
        }
        return PhysiologyContextDay(
            day: day, deviceId: deviceId, metric: metric, status: status,
            mode: (member("mode") as? String).flatMap(PhysiologyContext.ProcessingMode.init(rawValue:)),
            contextRevision: number(member("context_revision")).map { Int($0) },
            finality: (member("finality") as? String).flatMap(PhysiologyContext.Finality.init(rawValue:)),
            document: document, pairing: pairing, job: job, fetchedAtMs: fetchedAtMs)
    }

    static func parseHistory(_ history: [String: Any], from: String, to: String, deviceId: String,
                             mode: PhysiologyContext.ProcessingMode?, fetchedAtMs: Int) -> PhysiologyContextHistory {
        let decoded: LenientHistory? = JSONSerialization.isValidJSONObject(history)
            ? (try? JSONSerialization.data(withJSONObject: history))
                .flatMap { try? PhysiologyContext.decoder().decode(LenientHistory.self, from: $0) }
            : nil
        return PhysiologyContextHistory(
            from: from, to: to, deviceId: deviceId, mode: mode,
            episodes: decoded?.episodes.elements ?? [], bouts: decoded?.bouts.elements ?? [],
            dailyValues: decoded?.dailyValues.elements ?? [],
            undecodedElements: (decoded?.episodes.dropped ?? 0) + (decoded?.bouts.dropped ?? 0)
                + (decoded?.dailyValues.dropped ?? 0),
            fetchedAtMs: fetchedAtMs)
    }

    /// A finite JSON number (a JSON bool also bridges to NSNumber and is rejected).
    static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        return n.doubleValue.isFinite ? n.doubleValue : nil
    }

    /// A revision may arrive as a number or a string; both become a string (never a locally computed number).
    static func revisionString(_ value: Any?) -> String? {
        switch value {
        case let s as String: return s.isEmpty ? nil : s
        case let n as NSNumber:
            // A JSON bool also bridges to NSNumber; it is not a revision.
            if CFGetTypeID(n) == CFBooleanGetTypeID() { return nil }
            let d = n.doubleValue
            return d == d.rounded() && abs(d) < 9.0e15 ? String(Int64(d)) : n.stringValue
        default: return nil
        }
    }

    static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }

    /// Keep the later end of an over-long range: the server refuses more than 120 days.
    static func clampedFrom(_ from: String, to: String) -> String {
        guard let toDate = PhysiologyContextDates.date(to), let fromDate = PhysiologyContextDates.date(from),
              let earliest = PhysiologyContextDates.calendar.date(byAdding: .day, value: -(maxHistoryDays - 1),
                                                                  to: toDate),
              fromDate < earliest else { return from }
        return PhysiologyContextDates.key(earliest)
    }

    // MARK: - Cache

    static func dayCacheKey(day: String, metric: PhysiologyContext.MetricKind?,
                            mode: PhysiologyContext.ProcessingMode?) -> String {
        "day|\(day)|\(mode?.rawValue ?? "default")|\(metric?.rawValue ?? "all")"
    }

    static func historyCacheKey(from: String, to: String, mode: PhysiologyContext.ProcessingMode?) -> String {
        "history|\(from)|\(to)|\(mode?.rawValue ?? "default")"
    }

    /// File name: a digest of owner+device+key, so no user data appears in a path.
    private func cacheURL(ownerId: String, deviceId: String, key: String) -> URL {
        let name = "\(ownerId.lowercased())|\(deviceId.lowercased())|\(key)"
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    /// The payload stored for this owner, or nil. Another owner's file is neither returned nor deleted: their
    /// context must still be there if they sign back in.
    private func readCache(ownerId: String, deviceId: String, key: String) -> ([String: Any], Int)? {
        guard let data = try? Data(contentsOf: cacheURL(ownerId: ownerId, deviceId: deviceId, key: key)),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storedOwner = envelope["ownerId"] as? String,
              storedOwner.lowercased() == ownerId.lowercased(),
              let payload = envelope["payload"] as? [String: Any] else { return nil }
        return (payload, (envelope["fetchedAtMs"] as? NSNumber)?.intValue ?? 0)
    }

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
        #endif
    }

    private func writeCache(_ payload: [String: Any], ownerId: String, deviceId: String, key: String) {
        ensureDirectory()
        pruneCache()
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "ownerId": ownerId,
            "deviceId": deviceId,
            "fetchedAtMs": now(),
            "payload": payload,
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        let target = cacheURL(ownerId: ownerId, deviceId: deviceId, key: key)
        let temporary = target.appendingPathExtension("tmp")
        // Atomic: a reader never observes a half-written entry.
        do {
            try data.write(to: temporary, options: [.atomic])
            if FileManager.default.fileExists(atPath: target.path) {
                _ = try FileManager.default.replaceItemAt(target, withItemAt: temporary)
            } else {
                try FileManager.default.moveItem(at: temporary, to: target)
            }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    /// A day's entry is not read again once the day is weeks old, so old entries are deleted, not kept.
    private func pruneCache() {
        let cutoff = Date().addingTimeInterval(-Self.cacheRetention)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }
}

// MARK: - Day keys

/// `yyyy-MM-dd` arithmetic for history ranges, in the gregorian calendar and UTC (day keys only, no instants).
enum PhysiologyContextDates {
    static let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = calendar
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func date(_ key: String) -> Date? { formatter.date(from: key) }
    static func key(_ date: Date) -> String { formatter.string(from: date) }

    /// The key `days` days before `key` (negative goes forward).
    static func key(_ key: String, minusDays days: Int) -> String? {
        date(key).flatMap { calendar.date(byAdding: .day, value: -days, to: $0) }.map(Self.key)
    }

    /// Inclusive day count from `from` through `to`, nil when either is not a day key.
    static func inclusiveDays(from: String, to: String) -> Int? {
        guard let a = date(from), let b = date(to),
              let n = calendar.dateComponents([.day], from: a, to: b).day else { return nil }
        return n + 1
    }
}

// MARK: - Lenient decoding

/// An array that keeps the elements it can decode and counts the rest. Each element is read through a wrapper
/// that always succeeds, so the container advances exactly once per element whatever the element held.
struct LossyArray<Element: Decodable>: Decodable {
    var elements: [Element] = []
    var dropped = 0

    init() {}

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        while !container.isAtEnd {
            guard let slot = try? container.decode(Failable.self) else { break }
            if let value = slot.value { elements.append(value) } else { dropped += 1 }
        }
    }

    private struct Failable: Decodable {
        let value: Element?
        init(from decoder: Decoder) throws { value = try? Element(from: decoder) }
    }
}

/// The day document with every member optional. Keys are the camelCase names `convertFromSnakeCase` produces.
private struct LenientDayDocument: Decodable {
    var header: PhysiologyContext.DocumentHeader?
    var status: PhysiologyContext.ProductStatus?
    var statusReasons = LossyArray<PhysiologyContext.ReasonCode>()
    var availability = LossyArray<PhysiologyContext.AvailabilityEntry>()
    var regimes: PhysiologyContext.RegimeTimeline?
    var envelopes = LossyArray<PhysiologyContext.MeasurementEnvelope>()
    var sleep: PhysiologyContext.SleepRhythmSummary?
    var bouts = LossyArray<PhysiologyContext.ExertionBout>()
    var exertion = LossyArray<PhysiologyContext.ExertionWindowSummary>()
    var exposures: PhysiologyContext.ExposureDaySummary?
    var dailyValues = LossyArray<PhysiologyContext.DailyValue>()
    var comparisons = LossyArray<PhysiologyContext.ReferenceComparison>()
    var episodes = LossyArray<PhysiologyContext.ChangeEpisode>()
    var dependence = LossyArray<PhysiologyContext.DependenceNote>()
    var undecodedMembers: [String] = []

    var undecodedElements: Int {
        statusReasons.dropped + availability.dropped + envelopes.dropped + bouts.dropped + exertion.dropped
            + dailyValues.dropped + comparisons.dropped + episodes.dropped + dependence.dropped
    }

    enum CodingKeys: String, CodingKey {
        case header, status, statusReasons, availability, regimes, envelopes, sleep, bouts, exertion, exposures,
             dailyValues, comparisons, episodes, dependence
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var failed: [String] = []
        func one<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            guard c.contains(key), (try? c.decodeNil(forKey: key)) == false else { return nil }
            if let v = try? c.decode(T.self, forKey: key) { return v }
            failed.append(key.stringValue)
            return nil
        }
        func many<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> LossyArray<T> {
            guard c.contains(key), (try? c.decodeNil(forKey: key)) == false else { return LossyArray() }
            if let v = try? c.decode(LossyArray<T>.self, forKey: key) { return v }
            failed.append(key.stringValue)
            return LossyArray()
        }
        header = one(PhysiologyContext.DocumentHeader.self, .header)
        status = one(PhysiologyContext.ProductStatus.self, .status)
        statusReasons = many(PhysiologyContext.ReasonCode.self, .statusReasons)
        availability = many(PhysiologyContext.AvailabilityEntry.self, .availability)
        regimes = one(PhysiologyContext.RegimeTimeline.self, .regimes)
        envelopes = many(PhysiologyContext.MeasurementEnvelope.self, .envelopes)
        sleep = one(PhysiologyContext.SleepRhythmSummary.self, .sleep)
        bouts = many(PhysiologyContext.ExertionBout.self, .bouts)
        exertion = many(PhysiologyContext.ExertionWindowSummary.self, .exertion)
        exposures = one(PhysiologyContext.ExposureDaySummary.self, .exposures)
        dailyValues = many(PhysiologyContext.DailyValue.self, .dailyValues)
        comparisons = many(PhysiologyContext.ReferenceComparison.self, .comparisons)
        episodes = many(PhysiologyContext.ChangeEpisode.self, .episodes)
        dependence = many(PhysiologyContext.DependenceNote.self, .dependence)
        undecodedMembers = failed
    }
}

private struct LenientHistory: Decodable {
    var episodes = LossyArray<PhysiologyContext.ChangeEpisode>()
    var bouts = LossyArray<PhysiologyContext.ExertionBout>()
    var dailyValues = LossyArray<PhysiologyContext.DailyValue>()

    enum CodingKeys: String, CodingKey { case episodes, bouts, dailyValues }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = (try? c.decodeIfPresent(LossyArray<PhysiologyContext.ChangeEpisode>.self, forKey: .episodes))
            .flatMap { $0 } ?? LossyArray()
        bouts = (try? c.decodeIfPresent(LossyArray<PhysiologyContext.ExertionBout>.self, forKey: .bouts))
            .flatMap { $0 } ?? LossyArray()
        dailyValues = (try? c.decodeIfPresent(LossyArray<PhysiologyContext.DailyValue>.self, forKey: .dailyValues))
            .flatMap { $0 } ?? LossyArray()
    }
}

import Foundation
import CryptoKit
import WhoopProtocol
import StrandAnalytics
import WhoopStore

/// One day that the server says has changed, from the pull-based invalidation channel.
public struct ServerScoreChange: Sendable, Equatable {
    public let day: String
    public let changeRevision: Int64
}

/// Whether a day has server-computed values.
///
/// The distinction is load-bearing: an empty result is NOT a zero. Presenting "no server result yet"
/// as a score of 0 would invent physiology the server never computed.
public enum ServerScoreStatus: String, Sendable {
    case populated
    case noData
    case unavailable
}

/// One server-scored feature's state, kept typed so the UI can say WHY a number is missing.
public struct ServerScoreFeature: Sendable, Equatable {
    public let name: String
    public let status: String
    public let reason: String?
    public let algorithmVersion: String?
    public let inputRevision: String?
    public let computedAt: String?
    public let observedThrough: String?
}

/// An immutable, owner-scoped server result for one day.
///
/// The raw decoded JSON is RETAINED alongside the typed fields. The server contract has more members
/// than this type models (per-feature qualification, boundary overrides, computation mode, …), and
/// silently dropping what is not modelled would make a future UI change look like a server change.
public struct ServerScoreSnapshot: Sendable, Equatable {
    public let day: String
    public let deviceId: String
    public let schemaVersion: Int?
    public let contractRevision: Int?
    public let algorithmVersion: String?
    /// The server's own result revision for this day when it publishes one; otherwise the joined
    /// per-feature input revisions. This is what freshness and cache invalidation key off — never a
    /// locally computed number.
    public let resultRevision: String?
    public let computedAt: String?
    public let observedThrough: String?
    public let timezoneId: String?
    public let stale: Bool
    public let status: ServerScoreStatus
    public let features: [ServerScoreFeature]
    /// Fetched-at (unix ms), from the cache envelope. 0 for a fresh network read.
    public let fetchedAtMs: Int
    public let rawJSON: Data

    public var rawObject: [String: Any]? {
        (try? JSONSerialization.jsonObject(with: rawJSON)) as? [String: Any]
    }
}

/// Readback of server-computed results, with a revision-aware local cache.
///
/// Contract (verified against the deployed edge and its SQL, and against a live audit):
///  - Reads go to the `scores` edge route, NOT to the legacy `get_day_snapshot` RPC. A live trace
///    proved that RPC reads only the legacy tables (`daily_metrics`, `daily_physiology_series`,
///    `sessions`, `events`) and returns `metrics: null` / `availability.hr 0/288` / `events: []` even
///    when the PROJECTED tables hold the day's rows. The authoritative surface is the server-computed
///    `server_scoring` contract (server_physiology_results + scoring_snapshots_v2, carrying
///    result_revision / input_revision and a per-feature status), which the edge route returns.
///  - Auth is the same installation credential as ingest: `Authorization: Bearer <noop_…>`, bound
///    server-side to exactly one (account, source). No Supabase user session and no shared token is
///    involved on this route, and `deviceId` is required (the edge validates it and resolves it to a
///    device that account owns).
///  - Invalidation is cursor-based (`/days`), not realtime: a relaunch resumes the cursor, and a
///    changed scope revision resets it.
public actor ServerScoreRepository {

    public enum ReadError: Error, CustomStringConvertible {
        case notConfigured
        case missingIdentity
        case http(Int, String?)
        case malformed(String)
        case ownershipMismatch

        public var description: String {
            switch self {
            case .notConfigured: return "cloud: scores endpoint not configured"
            case .missingIdentity: return "cloud: no installation identity"
            case .http(let code, let body): return "cloud: scores HTTP \(code) \(body ?? "")"
            case .malformed(let why): return "cloud: malformed scores response: \(why)"
            case .ownershipMismatch: return "cloud: cached scores belong to a different owner"
            }
        }
    }

    private let session: URLSession
    private let endpoint: URL?
    private let identity: @Sendable () -> CloudPushIdentity?
    private let directory: URL
    private let now: @Sendable () -> Int

    /// `identity` supplies the credential to read with. The default is the signed-in account's; the
    /// runtime passes one bound to its own scope, so a repository created for account A never reads
    /// with account B's credential.
    public init(session: URLSession = .shared,
                endpoint: URL? = nil,
                directory: URL? = nil,
                identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() },
                now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.session = session
        self.endpoint = endpoint ?? ServerScoreRepository.derivedEndpoint()
        self.directory = directory ?? ((try? CloudJournalPaths.defaultDirectory())
            .map { $0.appendingPathComponent("scores", isDirectory: true) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("noop-scores", isDirectory: true))
        self.identity = identity
        self.now = now
    }

    /// The `scores` edge route, derived from the configured push receiver by swapping the function
    /// name. Both routes live on the same function host, and the receiver URL is the only endpoint the
    /// build carries, so deriving one from the other keeps a single source of truth.
    public static func derivedEndpoint() -> URL? {
        guard let push = CloudPushSettings.receiverURL else { return nil }
        var components = URLComponents(url: push, resolvingAgainstBaseURL: false)
        var parts = components?.path.split(separator: "/").map(String.init) ?? []
        guard let last = parts.last, last == "push" else { return nil }
        parts[parts.count - 1] = "scores"
        components?.path = "/" + parts.joined(separator: "/")
        return components?.url
    }

    // MARK: - cache

    private func ensureDirectory(_ target: URL? = nil) {
        let folder = target ?? directory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #if os(iOS)
        // Written from background wakes as well, so it takes the same after-first-unlock protection as
        // the store and the journal (see Strand/Collect/StorePaths.swift for the original reasoning).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: folder.path)
        #endif
    }

    /// Cache file name: a digest of owner+device+day, so no user data appears in a path.
    private func cacheURL(ownerId: String, deviceId: String, day: String) -> URL {
        let key = "\(ownerId.lowercased())|\(deviceId.lowercased())|\(day)"
        let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(digest).json")
    }

    /// Cached day for the CURRENT owner. A pure local read: no network, and no configuration
    /// requirement, because showing the last known server result offline is the point of the cache.
    ///
    /// A cache written by a DIFFERENT owner is not returned and is NOT deleted: the previous owner's
    /// results must still be there if they sign back in.
    public func cachedDay(day: String, deviceId: String) -> ServerScoreSnapshot? {
        guard let ownerId = identity()?.ownerId else { return nil }
        let url = cacheURL(ownerId: ownerId, deviceId: deviceId, day: day)
        guard let data = try? Data(contentsOf: url),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storedOwner = envelope["ownerId"] as? String,
              storedOwner.lowercased() == ownerId.lowercased(),
              let payload = envelope["payload"] as? [String: Any] else { return nil }
        let fetchedAt = (envelope["fetchedAtMs"] as? NSNumber)?.intValue ?? 0
        // The cache stores the INNER scoring object, so it is re-wrapped before parsing: `snapshot`
        // expects the edge's `{ "server_scoring": … }` envelope, and a cached read must produce exactly
        // the same result as the network read that wrote it — including the populated/noData decision.
        return ServerScoreRepository.snapshot(day: day, deviceId: deviceId,
                                              envelope: ["server_scoring": payload],
                                              fetchedAtMs: fetchedAt)
    }

    /// Fetch one day from the server, validate it, then cache it. Throws `notConfigured` (touching no
    /// network) when this build carries no receiver.
    @discardableResult
    public func refresh(day: String, deviceId: String) async throws -> ServerScoreSnapshot {
        // "Configured" is decided by THIS instance's own endpoint, not by a global read: an unconfigured
        // build derives no endpoint (so this still fails fast and touches no network), while a caller
        // that injected one is configured by construction.
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }

        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "day", value: day),
                                  URLQueryItem(name: "deviceId", value: deviceId)]
        guard let url = components?.url else { throw ReadError.malformed("endpoint") }

        let body = try await get(url: url, identity: identity)
        let snapshot = ServerScoreRepository.snapshot(day: day, deviceId: deviceId, envelope: body,
                                                      fetchedAtMs: 0)
        writeCache(snapshot, ownerId: identity.ownerId, deviceId: deviceId)
        return snapshot
    }

    /// Pull the days the server says changed since the persisted cursor, and advance it.
    ///
    /// The cursor is per (owner, device). The response carries a `scope_revision` that summarises the
    /// selection/configuration the cursor was taken under: when it changes, the cursor is meaningless
    /// and restarts at 0, which is what the server contract requires.
    @discardableResult
    public func pollChangedDays(deviceId: String, limit: Int = 32) async throws -> [ServerScoreChange] {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }

        let storedScope = defaults.string(forKey: scopeKey(ownerId: identity.ownerId, deviceId: deviceId))
        var components = URLComponents(url: endpoint.appendingPathComponent("days"),
                                       resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "deviceId", value: deviceId),
                     URLQueryItem(name: "limit", value: String(min(max(limit, 1), 32)))]
        if let storedScope, !storedScope.isEmpty {
            items.append(URLQueryItem(name: "cursor", value: String(cursor(ownerId: identity.ownerId, deviceId: deviceId))))
            items.append(URLQueryItem(name: "scopeRevision", value: storedScope))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw ReadError.malformed("days endpoint") }

        let body = try await get(url: url, identity: identity)
        let scope = body["scope_revision"] as? String
        var changes: [ServerScoreChange] = []
        for entry in (body["days"] as? [[String: Any]]) ?? [] {
            guard let day = entry["day"] as? String else { continue }
            let revision = (entry["change_revision"] as? NSNumber)?.int64Value ?? 0
            changes.append(ServerScoreChange(day: day, changeRevision: revision))
        }
        if let next = (body["next_cursor"] as? NSNumber)?.intValue {
            setCursor(next, ownerId: identity.ownerId, deviceId: deviceId)
        }
        if let scope, !scope.isEmpty { defaults.set(scope, forKey: scopeKey(ownerId: identity.ownerId, deviceId: deviceId)) }
        return changes
    }

    /// Whether the server already holds `deviceId` for this account.
    ///
    /// Asks the change feed for a single entry WITHOUT a cursor and keeps nothing from the answer, so it never
    /// moves the cursor `pollChangedDays` reads from. The route resolves `deviceId` to a device the account owns
    /// and answers `409 device_registration_pending` when there is none; that one answer is "no", and any other
    /// failure is thrown so a caller can tell "no" from "could not ask".
    public func holdsDevice(_ deviceId: String) async throws -> Bool {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }
        var components = URLComponents(url: endpoint.appendingPathComponent("days"),
                                       resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "deviceId", value: deviceId),
                                  URLQueryItem(name: "limit", value: "1")]
        guard let url = components?.url else { throw ReadError.malformed("days endpoint") }
        do {
            _ = try await get(url: url, identity: identity)
            return true
        } catch ReadError.http(let status, let body) where ServerScoreRepository.isUnregisteredDevice(status: status, body: body) {
            return false
        }
    }

    /// The server's "this account has no such device" answer, as opposed to any other failure.
    static func isUnregisteredDevice(status: Int, body: String?) -> Bool {
        status == 409 && (body?.contains("device_registration_pending") ?? false)
    }

    // MARK: - activity encoder windows

    /// One UTC day of `GET scores/activity-windows`: the server's HART windows, or `unchanged` when the day
    /// was listed in `known` at its current revision (the windows are then left out).
    public struct ActivityWindowsDay: Equatable, Sendable {
        public var day: String
        public var resultRevision: String
        public var encoderId: String
        public var modelVersion: String
        /// The `hart-windows-1` object re-serialized as JSON text; nil when `unchanged`.
        public var windowsJSON: String?
        public var unchanged: Bool { windowsJSON == nil }
    }

    /// HART's per-window output for up to three UTC days, skipping the windows of any day whose revision the
    /// caller already holds (`known`: day → result revision). A day the server has nothing for is absent.
    public func activityWindows(days: [String], deviceId: String,
                                known: [String: String] = [:]) async throws -> [ActivityWindowsDay] {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }
        guard !days.isEmpty else { return [] }
        var components = URLComponents(url: endpoint.appendingPathComponent("activity-windows"),
                                       resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "deviceId", value: deviceId),
                     URLQueryItem(name: "days", value: days.joined(separator: ","))]
        let held = days.compactMap { day in known[day].map { "\(day):\($0)" } }
        if !held.isEmpty { items.append(URLQueryItem(name: "known", value: held.joined(separator: ","))) }
        components?.queryItems = items
        guard let url = components?.url else { throw ReadError.malformed("activity-windows endpoint") }
        let body = try await get(url: url, identity: identity)
        return Self.activityWindowsDays(from: body)
    }

    static func activityWindowsDays(from body: [String: Any]) -> [ActivityWindowsDay] {
        ((body["days"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let day = entry["day"] as? String,
                  let revision = (entry["result_revision"] as? String)
                    ?? (entry["result_revision"] as? NSNumber)?.stringValue else { return nil }
            var json: String?
            if (entry["unchanged"] as? Bool) != true {
                guard let windows = entry["windows"] as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: windows) else { return nil }
                json = String(data: data, encoding: .utf8)
            }
            return ActivityWindowsDay(day: day, resultRevision: revision,
                                      encoderId: entry["encoder_id"] as? String ?? "hart",
                                      modelVersion: entry["model_version"] as? String ?? "unknown",
                                      windowsJSON: json)
        }
    }

    // MARK: - intraday series

    /// The dense intraday series between two instants (`GET scores/series`), cached under `cacheKey`.
    ///
    /// `metrics` narrows the answer to what the caller draws; nil asks for all five. The cache keeps the
    /// server's own JSON, so a cached read goes through exactly the parser the network read used.
    @discardableResult
    public func intradaySeries(from: Int, to: Int, deviceId: String, metrics: [IntradayMetric]? = nil,
                               cacheKey: String) async throws -> IntradaySeriesWindow {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }

        var components = URLComponents(url: endpoint.appendingPathComponent("series"),
                                       resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "deviceId", value: deviceId),
                     URLQueryItem(name: "from", value: String(from)),
                     URLQueryItem(name: "to", value: String(to))]
        if let metrics, !metrics.isEmpty {
            items.append(URLQueryItem(name: "metrics", value: metrics.map(\.rawValue).joined(separator: ",")))
        }
        components?.queryItems = items
        guard let url = components?.url else { throw ReadError.malformed("series endpoint") }

        let body = try await get(url: url, identity: identity)
        guard let series = body["series"], let window = IntradaySeriesWindow(envelope: body) else {
            throw ReadError.malformed("series")
        }
        writeSeriesCache(series, ownerId: identity.ownerId, deviceId: deviceId, key: cacheKey)
        return window
    }

    /// The last series stored under `cacheKey` for the CURRENT owner. A pure local read, so a screen can
    /// paint the last known readings before (or without) the network.
    public func cachedIntradaySeries(cacheKey: String, deviceId: String) -> IntradaySeriesWindow? {
        guard let ownerId = identity()?.ownerId else { return nil }
        guard let data = try? Data(contentsOf: seriesCacheURL(ownerId: ownerId, deviceId: deviceId, key: cacheKey)),
              let envelope = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let storedOwner = envelope["ownerId"] as? String,
              storedOwner.lowercased() == ownerId.lowercased(),
              let series = envelope["series"] as? [String: Any] else { return nil }
        return IntradaySeriesWindow(envelope: series)
    }

    /// Drop a cached day (used when a local edit makes it stale).
    public func invalidate(day: String, deviceId: String) {
        guard let ownerId = identity()?.ownerId else { return }
        try? FileManager.default.removeItem(at: cacheURL(ownerId: ownerId, deviceId: deviceId, day: day))
    }

    /// One short line for the UI. It NEVER presents an absent or future boundary as freshness: with no
    /// server result it says so, and it reports the server's own computed/observed times when present.
    public func freshnessLabel(for snapshot: ServerScoreSnapshot?) -> String {
        guard let snapshot else { return "No server result yet" }
        switch snapshot.status {
        case .unavailable:
            return "Server result unavailable"
        case .noData:
            let reason = snapshot.features.compactMap(\.reason).first
            return reason.map { "Server has no result yet (\($0))" } ?? "Server has no result yet"
        case .populated:
            var parts = ["Server score"]
            if let computed = snapshot.computedAt, let age = ServerScoreRepository.relativeAge(from: computed, nowMs: now()) {
                parts.append("computed \(age)")
            } else if snapshot.fetchedAtMs > 0 {
                parts.append("cached \(max(0, (now() - snapshot.fetchedAtMs) / 1000 / 60)) min ago")
            }
            let unavailable = snapshot.features.filter { $0.status != "available" }.map(\.name)
            if !unavailable.isEmpty { parts.append("missing: \(unavailable.joined(separator: ", "))") }
            if snapshot.stale { parts.append("stale") }
            return parts.joined(separator: " · ")
        }
    }

    // MARK: - transport

    private func get(url: URL, identity: CloudPushIdentity) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        CloudReceiverAuth.apply(identity, to: &request)
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

    // MARK: - parsing

    /// Turn the edge envelope into a snapshot.
    ///
    /// The day route answers `{ "server_scoring": { … } }`; `daily == null` with a `pending`-style
    /// contract means the server has not computed the day yet, which is reported as `noData` rather
    /// than as a zeroed result.
    static func snapshot(day: String, deviceId: String, envelope: [String: Any], fetchedAtMs: Int) -> ServerScoreSnapshot {
        let scoring = envelope["server_scoring"] as? [String: Any] ?? envelope
        let hasScoring = envelope["server_scoring"] != nil
        let raw = (try? JSONSerialization.data(withJSONObject: scoring, options: [.sortedKeys])) ?? Data()

        var features: [ServerScoreFeature] = []
        if let featureMap = scoring["features"] as? [String: Any] {
            for (name, value) in featureMap {
                guard let object = value as? [String: Any] else { continue }
                features.append(ServerScoreFeature(
                    name: name,
                    status: object["status"] as? String ?? "unknown",
                    reason: object["reason"] as? String,
                    algorithmVersion: object["algorithm_version"] as? String,
                    inputRevision: object["input_revision"] as? String,
                    computedAt: object["computed_at"] as? String,
                    observedThrough: object["observed_through"] as? String))
            }
            features.sort { $0.name < $1.name }
        }

        let nights = scoring["nights"] as? [Any] ?? []
        let measurements = scoring["measurements"] as? [Any] ?? []
        let hasDaily = scoring["daily"] is [String: Any]
        let status: ServerScoreStatus
        if !hasScoring {
            status = .unavailable
        } else if hasDaily || !nights.isEmpty || !measurements.isEmpty {
            status = .populated
        } else {
            status = .noData
        }

        // The revision the cache and the UI key off. A server-published result revision wins; otherwise
        // the per-feature input revisions are joined, which still changes when the inputs change.
        let resultRevision = (scoring["result_revision"] as? String)
            ?? (scoring["daily"] as? [String: Any]).flatMap { $0["result_revision"] as? String }
            ?? features.compactMap(\.inputRevision).sorted().joined(separator: "+").nilIfEmpty

        let observed = (scoring["daily"] as? [String: Any])?["observed_through"] as? String
            ?? features.compactMap(\.observedThrough).max()

        return ServerScoreSnapshot(
            day: scoring["day"] as? String ?? day,
            deviceId: deviceId,
            schemaVersion: (scoring["schema_version"] as? NSNumber)?.intValue,
            contractRevision: (scoring["contract_revision"] as? NSNumber)?.intValue,
            algorithmVersion: scoring["algorithm_version"] as? String,
            resultRevision: resultRevision,
            computedAt: scoring["computed_at"] as? String ?? features.compactMap(\.computedAt).max(),
            observedThrough: observed,
            timezoneId: (scoring["daily"] as? [String: Any])?["timezone_id"] as? String
                ?? features.compactMap { _ in nil as String? }.first,
            stale: scoring["stale"] as? Bool ?? false,
            status: status,
            features: features,
            fetchedAtMs: fetchedAtMs,
            rawJSON: raw)
    }

    /// "2h ago" from an ISO-8601 timestamp. Returns nil for an unparseable or FUTURE time, so a
    /// future `dataThrough` can never be rendered as a freshness claim.
    static func relativeAge(from iso: String, nowMs: Int) -> String? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        var date = formatter.date(from: iso)
        if date == nil {
            formatter.formatOptions.remove(.withFractionalSeconds)
            date = formatter.date(from: iso)
        }
        guard let date else { return nil }
        let seconds = nowMs / 1000 - Int(date.timeIntervalSince1970)
        guard seconds >= 0 else { return nil }
        if seconds < 90 { return "just now" }
        if seconds < 3600 { return "\(seconds / 60)m ago" }
        if seconds < 86_400 { return "\(seconds / 3600)h ago" }
        return "\(seconds / 86_400)d ago"
    }

    // MARK: - cache + cursor persistence

    private func writeCache(_ snapshot: ServerScoreSnapshot, ownerId: String, deviceId: String) {
        ensureDirectory()
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "ownerId": ownerId,
            "deviceId": deviceId,
            "day": snapshot.day,
            "fetchedAtMs": now(),
            "resultRevision": snapshot.resultRevision ?? "",
            "timezoneId": snapshot.timezoneId ?? "",
            "payload": (try? JSONSerialization.jsonObject(with: snapshot.rawJSON)) ?? [:],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys]) else { return }
        let target = cacheURL(ownerId: ownerId, deviceId: deviceId, day: snapshot.day)
        let temporary = target.appendingPathExtension("tmp")
        // Atomic: a reader never observes a half-written cache entry.
        do {
            try data.write(to: temporary, options: [.atomic])
            _ = try? FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    private var seriesDirectory: URL { directory.appendingPathComponent("series", isDirectory: true) }

    private func seriesCacheURL(ownerId: String, deviceId: String, key: String) -> URL {
        let name = "\(ownerId.lowercased())|\(deviceId.lowercased())|\(key)"
        let digest = SHA256.hash(data: Data(name.utf8)).map { String(format: "%02x", $0) }.joined()
        return seriesDirectory.appendingPathComponent("\(digest).json")
    }

    private func writeSeriesCache(_ series: Any, ownerId: String, deviceId: String, key: String) {
        ensureDirectory(seriesDirectory)
        pruneSeriesCache()
        let envelope: [String: Any] = [
            "schemaVersion": 1,
            "ownerId": ownerId,
            "deviceId": deviceId,
            "fetchedAtMs": now(),
            "series": series,
        ]
        guard JSONSerialization.isValidJSONObject(envelope),
              let data = try? JSONSerialization.data(withJSONObject: envelope) else { return }
        let target = seriesCacheURL(ownerId: ownerId, deviceId: deviceId, key: key)
        let temporary = target.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            _ = try? FileManager.default.replaceItemAt(target, withItemAt: temporary)
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    /// One entry per (screen, day), and a day-keyed entry is never read again once its day is more than a
    /// week old, so entries older than two weeks are deleted instead of accumulating.
    private func pruneSeriesCache() {
        let cutoff = Date().addingTimeInterval(-14 * 86_400)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: seriesDirectory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        for file in files {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
            if let modified, modified < cutoff { try? FileManager.default.removeItem(at: file) }
        }
    }

    private var defaults: UserDefaults { .standard }
    private func scopeKey(ownerId: String, deviceId: String) -> String {
        "noop.cloud.scores.scope.\(ownerId.lowercased()).\(deviceId.lowercased())"
    }
    private func cursorKey(ownerId: String, deviceId: String) -> String {
        "noop.cloud.scores.cursor.\(ownerId.lowercased()).\(deviceId.lowercased())"
    }
    private func cursor(ownerId: String, deviceId: String) -> Int {
        defaults.integer(forKey: cursorKey(ownerId: ownerId, deviceId: deviceId))
    }
    private func setCursor(_ value: Int, ownerId: String, deviceId: String) {
        defaults.set(value, forKey: cursorKey(ownerId: ownerId, deviceId: deviceId))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - hosted worker result

extension ServerScoreSnapshot {
    /// The hosted worker's own published result for this day, when the scores route attached one.
    public var hostedResult: HostedDayResult? {
        (rawObject?["hosted_snapshot"] as? [String: Any]).flatMap { HostedDayResult(day: day, object: $0) }
    }
}

/// One 15-minute HRV reading from the hosted worker's intraday series.
public struct HrvSeriesPoint: Equatable, Sendable {
    /// Slot start, unix seconds.
    public let startTs: Int
    public let rmssd: Double
    /// Clean beats behind the reading; a thin slot is a weaker reading.
    public let cleanBeats: Int
}

/// The hosted worker's published day result, in the shapes the dashboard already stores.
///
/// The worker runs the app's own `AnalyticsEngine.analyzeDay`, so each field maps one-to-one onto what
/// a local scoring pass would have persisted. Nothing here derives a value: a key the worker left out
/// stays nil, and a Charge the worker could not compute yet (no baseline) stays nil rather than zero.
public struct HostedDayResult: Equatable {
    public let day: String
    public let resultRevision: String
    public let computedAt: String?
    /// The server holds newer input for the day than this result was computed from.
    public let pending: Bool
    public let status: String?
    public let statusReasons: [String]
    public let daily: DailyMetric
    /// The Rest composite (0–100), which the local engine stores as the `sleep_performance` series.
    public let restScore: Double?
    /// The night's mean of the strap's own SpO₂ estimate (`@82`, whole percent), which the local engine
    /// stores as the `spo2_candidate` series, and the number of in-band readings it is the mean of.
    /// A strap estimate, not a blood-oxygen measurement: it never becomes `daily.spo2Pct`.
    public let spo2Candidate: Int?
    public let spo2CandidateSamples: Int?
    public let sleep: [CachedSleepSession]
    /// Intraday HRV, one reading per slot of the local day, oldest first. Empty when the worker has not
    /// published one. Informational only: it is not what Charge or the baselines use.
    public let hrvSeries: [HrvSeriesPoint]
    public let hrvSlotSeconds: Int
    /// The optional C10 `daily.activity_context` snapshot (server-computed 30-s activity grid).
    /// Nil when the payload has no key, when the field is malformed, or when this app build has not
    /// learned a newer schema yet — never fatal. The UI renders nothing when it is nil (feature off).
    ///
    /// Cache: this rides inside the `daily` object that `snapshot()` keeps verbatim in `rawJSON`
    /// (ServerScoreRepository.swift:293-347), so `writeCache` persists it automatically — no new
    /// cache field. A cached read re-wraps the same payload and re-parses through `snapshot()`,
    /// so offline renders the exact timeline the network read produced for the same
    /// owner + device + result revision.
    public let activityContext: ActivityContextDocument?
    /// The optional sleep-features enrichment document (`daily.sleep_features`, spec-25 §7.3).
    /// Nil when the payload has no key, when it is malformed, or when this app build has not
    /// learned a newer schema yet — never fatal. The Sleep page renders the Sleep details section
    /// only when this is non-nil, so builds without the payload render exactly as before.
    ///
    /// Cache: like `activityContext`, this rides inside the `daily` object that `snapshot()` keeps
    /// verbatim in `rawJSON`, so `writeCache` persists it automatically — no new cache field and a
    /// cached read re-parses through `snapshot()` offline.
    public let sleepFeatures: SleepFeatureDocument?

    init?(day: String, object: [String: Any]) {
        guard let daily = object["daily"] as? [String: Any],
              let revision = object["result_revision"] as? String, !revision.isEmpty else { return nil }
        func number(_ key: String) -> Double? { Self.number(daily[key]) }
        func integer(_ key: String) -> Int? { number(key).map { Int($0.rounded()) } }
        self.day = day
        self.resultRevision = revision
        self.computedAt = object["computed_at"] as? String
        self.pending = object["pending"] as? Bool ?? false
        self.status = object["status"] as? String
        self.statusReasons = (object["status_reasons"] as? [Any])?.compactMap { $0 as? String } ?? []
        self.daily = DailyMetric(
            day: day,
            totalSleepMin: number("sleep_total_min"), efficiency: number("sleep_efficiency"),
            deepMin: number("sleep_deep_min"), remMin: number("sleep_rem_min"),
            lightMin: number("sleep_light_min"), disturbances: integer("disturbances"),
            restingHr: integer("resting_hr_bpm"), avgHrv: number("hrv_rmssd_ms"),
            recovery: number("recovery"), strain: number("strain"),
            exerciseCount: integer("exerciseCount"),
            spo2Pct: number("spo2_pct"), skinTempDevC: number("skin_temp_dev_c"),
            respRateBpm: number("resp_rate_bpm"), steps: integer("steps"),
            activeKcalEst: number("activeKcalEst"), spo2Red: integer("spo2Red"),
            spo2Ir: integer("spo2Ir"), avgSdnn: number("hrv_sdnn_ms"),
            skinTempC: number("skin_temp_c"), sleepHrOnly: daily["sleepHrOnly"] as? Bool)
        self.restScore = number("restScore")
        let candidateSamples = integer("spo2_candidate_samples").flatMap { $0 > 0 ? $0 : nil }
        self.spo2Candidate = candidateSamples == nil ? nil
            : integer("spo2_candidate_pct").flatMap { Spo2StrapEstimate.band.contains($0) ? $0 : nil }
        self.spo2CandidateSamples = self.spo2Candidate == nil ? nil : candidateSamples
        let series = daily["hrv_series"] as? [String: Any]
        let slot = Self.number(series?["slot_s"]).flatMap { Int(exactly: $0) } ?? 900
        self.hrvSlotSeconds = (60...3_600).contains(slot) ? slot : 900
        self.hrvSeries = ((series?["points"] as? [Any]) ?? []).compactMap { entry -> HrvSeriesPoint? in
            guard let point = entry as? [Any], point.count >= 3,
                  let start = Self.number(point[0]).flatMap({ Int(exactly: $0) }),
                  let rmssd = Self.number(point[1]), rmssd > 0,
                  let beats = Self.number(point[2]).flatMap({ Int(exactly: $0) }) else { return nil }
            return HrvSeriesPoint(startTs: start, rmssd: rmssd, cleanBeats: beats)
        }.sorted { $0.startTs < $1.startTs }
        self.activityContext = Self.activityContext(from: daily)
        self.sleepFeatures = Self.sleepFeatures(from: daily)
        self.sleep = ((object["sleep"] as? [Any]) ?? []).compactMap { entry -> CachedSleepSession? in
            guard let night = entry as? [String: Any],
                  night["is_nap"] as? Bool != true,
                  let start = Self.unixSeconds(night["start_at"]),
                  let end = Self.unixSeconds(night["end_at"]), end > start else { return nil }
            let stages = (night["stages"] as? [Any]).flatMap { segments -> String? in
                guard !segments.isEmpty,
                      let data = try? JSONSerialization.data(withJSONObject: segments, options: [.sortedKeys])
                else { return nil }
                return String(data: data, encoding: .utf8)
            }
            return CachedSleepSession(startTs: start, endTs: end,
                                      efficiency: Self.number(night["efficiency"]),
                                      restingHr: Self.number(night["resting_hr_bpm"]).map { Int($0.rounded()) },
                                      avgHrv: Self.number(night["hrv_rmssd_ms"]),
                                      stagesJSON: stages)
        }
    }

    /// A finite JSON number. JSON booleans decode as NSNumber too and are rejected here.
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }

    static func unixSeconds(_ value: Any?) -> Int? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return Int(date.timeIntervalSince1970) }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text).map { Int($0.timeIntervalSince1970) }
    }

    /// Decode the optional C10 `daily.activity_context` object into the SHARED StrandAnalytics
    /// schema (the same types the worker serializes with), so app and server can never drift.
    ///
    /// Deliberately non-fatal on every failure mode: a missing key, a non-object value, a future
    /// schema bump, or a malformed field all return nil and leave the rest of the hosted result
    /// intact. Old payloads without the key are unaffected (spec-14 §10 "Preserve old clients and
    /// snapshots with no activity_context field").
    static func activityContext(from daily: [String: Any]) -> ActivityContextDocument? {
        guard let raw = daily["activity_context"] else { return nil }
        guard JSONSerialization.isValidJSONObject(raw) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(ActivityContextDocument.self, from: data)
    }

    /// Decode the optional sleep-features document (`daily.sleep_features`) into the SHARED
    /// StrandAnalytics schema — the same types the worker serializes with.
    ///
    /// Deliberately non-fatal on every failure mode (spec-25 §7.3 "Decode in HostedDayResult with
    /// a shared typed document; missing/malformed/future-schema data must not break the entire
    /// day"): a missing key, a non-object value, a future schema bump or a malformed field all
    /// return nil and leave the rest of the hosted result intact. Old payloads without the key are
    /// unaffected — the snapshot publishes without `sleep_features` when the sidecar is absent.
    static func sleepFeatures(from daily: [String: Any]) -> SleepFeatureDocument? {
        guard let raw = daily["sleep_features"] else { return nil }
        guard JSONSerialization.isValidJSONObject(raw) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        return try? JSONDecoder().decode(SleepFeatureDocument.self, from: data)
    }
}

/// Writes hosted results where the dashboard reads computed scores.
///
/// The dashboard unions the local engine's computed namespace (`<device>-noop`) into every card. In
/// cloud mode the local engine does not run, so writing the server's rows there is what lets the
/// existing Charge / Effort / Rest / sleep surfaces show the server's numbers with no second
/// presentation path.
public enum HostedResultMaterializer {
    public static func computedId(for deviceId: String) -> String { deviceId + "-noop" }

    /// The `metricSeries` key the local engine writes the nightly SpO₂ estimate under (`IntelligenceEngine`).
    static let spo2CandidateKey = "spo2_candidate"

    /// Persist one hosted day. `skipWindows` are nights the user deleted; a hosted session overlapping
    /// one (or a hand-edited night) is not written, the same guard a local pass applies.
    public static func persist(_ result: HostedDayResult,
                               store: WhoopStore,
                               deviceId: String,
                               skipWindows: [(start: Int, end: Int)] = []) async throws {
        let computedId = computedId(for: deviceId)
        let day = result.day
        var points = result.restScore.map { [MetricPoint(day: day, key: "sleep_performance", value: $0)] } ?? []
        // The strap's SpO₂ estimate goes where the local engine puts it, so the Blood Oxygen surfaces that
        // already fall back to it (behind `PuffinExperiment.spo2CandidateDisplayEnabled`, labelled "strap
        // estimate (unverified)") work in cloud mode with no second path. It is replaced with the day, so a
        // recompute that finds no estimate clears a stale one.
        if let candidate = result.spo2Candidate {
            points.append(MetricPoint(day: day, key: spo2CandidateKey, value: Double(candidate)))
        }
        var provenance: [ScoreInputProvenanceRow] = []
        if result.daily.recovery != nil { provenance.append(.init(day: day, key: "recovery", sourceId: deviceId)) }
        if result.daily.strain != nil { provenance.append(.init(day: day, key: "strain", sourceId: deviceId)) }
        if result.restScore != nil {
            provenance.append(.init(day: day, key: "sleep_performance", sourceId: deviceId))
        }
        try await store.persistComputedScores(dailyMetrics: [result.daily], metricPoints: points,
                                              provenance: provenance, deviceId: computedId,
                                              from: day, to: day,
                                              replaceMetricKeys: ["sleep_performance", spo2CandidateKey])

        guard let earliest = result.sleep.map(\.startTs).min(),
              let latest = result.sleep.map(\.endTs).max() else { return }
        func overlaps(_ a: (start: Int, end: Int), _ b: (start: Int, end: Int)) -> Bool {
            a.start < b.end && b.start < a.end
        }
        let existing = try await store.sleepSessions(deviceId: computedId, from: earliest - 86_400,
                                                     to: latest, limit: 64)
        let protected = existing.filter(\.userEdited).map { (start: $0.effectiveStartTs, end: $0.endTs) }
            + skipWindows
        let kept = result.sleep.filter { night in
            !protected.contains { overlaps($0, (night.startTs, night.endTs)) }
        }
        // A re-computed night can move its detected onset as more of the night arrives. The row keyed by
        // the old onset would otherwise stay beside the new one and the day would count the night twice.
        let keys = Set(kept.map(\.startTs))
        for old in existing where !old.userEdited && !keys.contains(old.startTs)
            && kept.contains(where: { overlaps(($0.startTs, $0.endTs), (old.startTs, old.endTs)) }) {
            _ = try await store.deleteSleepSession(deviceId: computedId, startTs: old.startTs)
        }
        if !kept.isEmpty { _ = try await store.upsertSleepSessions(kept, deviceId: computedId) }
    }
}

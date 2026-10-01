import Foundation
import CryptoKit

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
///  - Auth is the same installation credential as ingest: `Authorization: Bearer <noop_…>` plus
///    `x-noop-fleet-token`. No Supabase user session is involved on this route, and `deviceId` is
///    required (the edge validates it and resolves it to an owned device).
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
    private let fleetToken: String
    private let identity: @Sendable () -> CloudPushIdentity?
    private let directory: URL
    private let now: @Sendable () -> Int

    public init(session: URLSession = .shared,
                endpoint: URL? = nil,
                fleetToken: String? = nil,
                directory: URL? = nil,
                identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() },
                now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) }) {
        self.session = session
        self.endpoint = endpoint ?? ServerScoreRepository.derivedEndpoint()
        self.fleetToken = fleetToken ?? CloudPushSettings.fleetToken
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

    private func ensureDirectory() {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        // Written from background wakes as well, so it takes the same after-first-unlock protection as
        // the store and the journal (see Strand/Collect/StorePaths.swift for the original reasoning).
        try? FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: directory.path)
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
        // "Configured" is decided by THIS instance's own endpoint and fleet credential, not by a global
        // read: an unconfigured build derives no endpoint (so this still fails fast and touches no
        // network), while a caller that injected an endpoint and token is configured by construction.
        guard let endpoint, !fleetToken.isEmpty else { throw ReadError.notConfigured }
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
        guard let endpoint, !fleetToken.isEmpty else { throw ReadError.notConfigured }
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
        request.setValue("Bearer \(identity.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue(fleetToken, forHTTPHeaderField: "x-noop-fleet-token")
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

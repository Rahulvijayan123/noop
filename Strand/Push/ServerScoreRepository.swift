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
    /// The hosted worker's own published result for this day, when the scores route attached one.
    ///
    /// Decoded once, where the snapshot is built (inside the repository actor), rather than on every read:
    /// the payload is 100–150 KB and carries the activity-context, sleep-features and sleep-analytics
    /// documents, and views read this property from their bodies and load tasks on the main actor.
    public let hostedResult: HostedDayResult?

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

    /// How long a network read of a day answers later asks for the same (owner, device, day). The app model's
    /// sync, the Today card, the sleep sections, the activity pages and the biomarker store each read the same
    /// day on their own schedule; inside this window they share one 100–150 KB response instead of each
    /// downloading it again. Shorter than the app model's half-minute refresh, so that loop still reads anew.
    public static let sharedReadWindowMs = 20_000

    private struct DayReadKey: Hashable {
        let ownerId: String
        let deviceId: String
        let day: String
    }

    /// Network reads in flight, so callers asking for the same day at the same time wait on one request.
    private var dayReadsInFlight: [DayReadKey: Task<ServerScoreSnapshot, Error>] = [:]
    /// The last network read of each day, for `sharedReadWindowMs`.
    private var recentDayReads: [DayReadKey: (snapshot: ServerScoreSnapshot, atMs: Int)] = [:]

    /// Fetch one day from the server, validate it, then cache it. Throws `notConfigured` (touching no
    /// network) when this build carries no receiver.
    ///
    /// `maxAgeMs` is how old a read this repository already made may be and still answer: the default shares
    /// one request between callers asking within `sharedReadWindowMs`; 0 always asks the server (a change the
    /// server just reported).
    @discardableResult
    public func refresh(day: String, deviceId: String,
                        maxAgeMs: Int = ServerScoreRepository.sharedReadWindowMs) async throws -> ServerScoreSnapshot {
        // "Configured" is decided by THIS instance's own endpoint, not by a global read: an unconfigured
        // build derives no endpoint (so this still fails fast and touches no network), while a caller
        // that injected one is configured by construction.
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }

        let key = DayReadKey(ownerId: identity.ownerId.lowercased(), deviceId: deviceId.lowercased(), day: day)
        // A forced read neither reuses nor joins an earlier request: one that left before the server published
        // the change it is asking about would answer with the result it replaced.
        if maxAgeMs > 0 {
            if let recent = recentDayReads[key], now() - recent.atMs < maxAgeMs { return recent.snapshot }
            if let running = dayReadsInFlight[key] { return try await running.value }
        }
        // Unstructured on purpose: a caller whose own task is cancelled (a view that went away) must not
        // cancel the request the other callers are waiting on.
        let read = Task { try await self.fetchDay(day: day, deviceId: deviceId, endpoint: endpoint,
                                                  identity: identity) }
        dayReadsInFlight[key] = read
        defer { if dayReadsInFlight[key] == read { dayReadsInFlight[key] = nil } }
        let snapshot = try await read.value
        let readAtMs = now()
        recentDayReads = recentDayReads.filter { readAtMs - $0.value.atMs < Self.sharedReadWindowMs }
        recentDayReads[key] = (snapshot, readAtMs)
        return snapshot
    }

    private func fetchDay(day: String, deviceId: String, endpoint: URL,
                          identity: CloudPushIdentity) async throws -> ServerScoreSnapshot {
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
        /// The raw-IMU input revision the windows were computed from; nil from a server without the field.
        public var inputRevision: Int64? = nil
        /// HART's release (`release_mode`) and that of the ElderNet windows embedded in the set
        /// (`embedded_gait_release_mode`), as the route sent them; nil when absent.
        public var releaseMode: String? = nil
        public var embeddedGaitReleaseMode: String? = nil
    }

    /// HART's per-window output for up to three UTC days, skipping the windows of any day whose revision the
    /// caller already holds (`known`: day → result revision). A day the server has nothing for is absent.
    public func activityWindows(days: [String], deviceId: String,
                                known: [String: String] = [:]) async throws -> [ActivityWindowsDay] {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }
        guard !days.isEmpty else { return [] }
        guard let url = Self.windowsURL(endpoint: endpoint, route: "activity-windows", days: days, deviceId: deviceId,
                                        known: known) else { throw ReadError.malformed("activity-windows endpoint") }
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
                                      windowsJSON: json,
                                      inputRevision: revisionNumber(entry["input_revision"]),
                                      releaseMode: entry["release_mode"] as? String,
                                      embeddedGaitReleaseMode: entry["embedded_gait_release_mode"] as? String)
        }
    }

    /// An int64 the route sends as a string (or, from an older encoder, a number); nil when absent or malformed.
    static func revisionNumber(_ value: Any?) -> Int64? {
        if let text = value as? String { return Int64(text) }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            let n = number.int64Value
            return number.doubleValue == Double(n) ? n : nil
        }
        return nil
    }

    // MARK: - gait windows

    /// One UTC day of `GET scores/gait-windows`: ElderNet's gait detection and gait quality, or `unchanged`
    /// when the day was listed in `known` at its current revision.
    public struct GaitWindowsDay: Sendable {
        public var day: String
        public var resultRevision: String
        public var mode: String
        public var modelVersion: String
        /// The `gait-windows-1` columns; nil when `unchanged` or when the server withheld an oversized day.
        public var windows: GaitWindowColumns?
        public var unchanged: Bool
        /// The model the windows came from, when the server named it and its weights digest checks out.
        public var model: GaitQualityModelInfo? = nil
        /// The `gait-windows-1` object as it arrived, for the on-disk store.
        public var windowsJSON: String? = nil
        /// The release-authority fields (docs/model-integration/activity-authority.md), nil from an older server.
        /// `releaseMode` is the weaker of the row's `release_mode` and its authority block's; `mode` stays the
        /// worker mode the row was written under. A consumer derives the release from these, never above `mode`.
        public var releaseMode: String? = nil
        public var inputRevision: Int64? = nil
        /// The authority block's pins and prior (`pinned_model_version`, `pinned_weights_digest`, `gait_prior`).
        public var pinnedModelVersion: String? = nil
        public var pinnedWeightsDigest: String? = nil
        public var gaitPrior: Double? = nil
        /// The producer's own decision for the row (`authority.use` / `.reason`); informational.
        public var producerUse: String? = nil
        public var producerReason: String? = nil
        /// The row's model identity (`identity`), when sent.
        public var identity: [String: String]? = nil
    }

    /// The release-authority capability this build declares on the window routes (`authority=1`): it applies the
    /// shared release policy itself, so the server may send expert rows below production with their model. Without
    /// it the server withholds anything an older build would turn into decoder evidence
    /// (docs/model-integration/activity-authority.md, "Older phones").
    static let windowsAuthorityCapability = "1"

    /// `GET scores/<route>?deviceId=…&days=…[&known=…]&authority=1`.
    static func windowsURL(endpoint: URL, route: String, days: [String], deviceId: String,
                           known: [String: String]) -> URL? {
        var components = URLComponents(url: endpoint.appendingPathComponent(route), resolvingAgainstBaseURL: false)
        var items = [URLQueryItem(name: "deviceId", value: deviceId),
                     URLQueryItem(name: "days", value: days.joined(separator: ","))]
        let held = days.compactMap { day in known[day].map { "\(day):\($0)" } }
        if !held.isEmpty { items.append(URLQueryItem(name: "known", value: held.joined(separator: ","))) }
        items.append(URLQueryItem(name: "authority", value: windowsAuthorityCapability))
        components?.queryItems = items
        return components?.url
    }

    /// ElderNet's per-window output for up to three UTC days (same `known` rule as `activityWindows`).
    public func gaitWindows(days: [String], deviceId: String,
                            known: [String: String] = [:]) async throws -> [GaitWindowsDay] {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }
        guard !days.isEmpty else { return [] }
        guard let url = Self.windowsURL(endpoint: endpoint, route: "gait-windows", days: days, deviceId: deviceId,
                                        known: known) else { throw ReadError.malformed("gait-windows endpoint") }
        let body = try await get(url: url, identity: identity)
        return Self.gaitWindowsDays(from: body)
    }

    static func gaitWindowsDays(from body: [String: Any]) -> [GaitWindowsDay] {
        ((body["days"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let day = entry["day"] as? String,
                  let revision = (entry["result_revision"] as? String)
                    ?? (entry["result_revision"] as? NSNumber)?.stringValue else { return nil }
            let unchanged = (entry["unchanged"] as? Bool) == true
            let windowsJSON = unchanged ? nil : (entry["windows"] as? [String: Any]).flatMap { object in
                (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
            }
            let authority = entry["authority"] as? [String: Any]
            let identity = (entry["identity"] as? [String: Any])?.compactMapValues { $0 as? String }
            var model = unchanged ? nil : gaitModel(entry["model"])
            // The identity names the same model as `model` or the windows are not trusted.
            if let m = model, let identity,
               (identity["model_version"] ?? m.modelVersion) != m.modelVersion
                || (identity["weights_digest"] ?? m.weightsDigest) != m.weightsDigest { model = nil }
            return GaitWindowsDay(day: day, resultRevision: revision,
                                  mode: entry["mode"] as? String ?? "shadow",
                                  modelVersion: entry["model_version"] as? String ?? "unknown",
                                  windows: unchanged ? nil : GaitWindowColumns(entry["windows"]),
                                  unchanged: unchanged,
                                  model: model,
                                  windowsJSON: windowsJSON,
                                  releaseMode: weakerRelease(entry["release_mode"], authority?["release_mode"]),
                                  inputRevision: revisionNumber(entry["input_revision"])
                                    ?? revisionNumber(authority?["input_revision"]),
                                  pinnedModelVersion: authority?["pinned_model_version"] as? String,
                                  pinnedWeightsDigest: authority?["pinned_weights_digest"] as? String,
                                  gaitPrior: (authority?["gait_prior"] as? NSNumber).flatMap { n in
                                      CFGetTypeID(n) == CFBooleanGetTypeID() || !n.doubleValue.isFinite
                                          ? nil : n.doubleValue
                                  },
                                  producerUse: authority?["use"] as? String,
                                  producerReason: authority?["reason"] as? String,
                                  identity: identity)
        }
    }

    /// The weaker of two recorded releases, as text; nil when neither was sent. A value that is present but not a
    /// release name reads as shadow (`ActivityReleaseMode(recorded:)`), so it can only lower.
    static func weakerRelease(_ a: Any?, _ b: Any?) -> String? {
        let sent = [a, b].compactMap { $0 }.filter { !($0 is NSNull) }
        guard !sent.isEmpty else { return nil }
        return sent.map { ActivityReleaseMode(recorded: $0 as? String) }.min()?.rawValue
    }

    /// The route's `model` object as the decoder's model info. Its `weights_digest` is not part of the model's
    /// wire form; it must equal the digest of the per-head weights, or the model is not trusted.
    static func gaitModel(_ object: Any?) -> GaitQualityModelInfo? {
        guard var o = object as? [String: Any] else { return nil }
        let digest = o.removeValue(forKey: "weights_digest") as? String
        guard let data = try? JSONSerialization.data(withJSONObject: o),
              let model = try? JSONDecoder().decode(GaitQualityModelInfo.self, from: data),
              digest == nil || digest == model.weightsDigest else { return nil }
        return model
    }

    // MARK: - motion heads

    /// One UTC day of `GET scores/motion-heads`: the ActiNet / Inertia-1 motion-head windows of one bundle, or
    /// `unchanged` when the day was listed in `known` at its current revision.
    public struct MotionHeadsDay: Sendable {
        public var day: String
        public var resultRevision: String
        /// The worker mode the row was written under.
        public var mode: String
        public var unchanged: Bool
        /// The weaker of the row's `release_mode` and its authority block's; nil when neither was sent.
        public var releaseMode: String? = nil
        public var inputRevision: Int64? = nil
        /// The row's `bundle_sha256` column, sent on every row.
        public var bundleSha256: String? = nil
        /// The bundle the windows came from (the worker's payload `bundle`), when it decodes strictly and names the
        /// row's digest; nil when `unchanged` or on an older row without it.
        public var bundle: MotionHeadsBundleInfo? = nil
        /// The policy inputs the row was produced under (`authority`); nil = none recorded.
        public var authority: ActivityExpertAuthority? = nil
        /// The `mh-col-1` object as it arrived, for the on-disk store; nil when `unchanged` or withheld.
        public var windowsJSON: String? = nil
    }

    /// The motion-head windows for up to three UTC days (same `known` rule as `activityWindows`).
    public func motionHeads(days: [String], deviceId: String,
                            known: [String: String] = [:]) async throws -> [MotionHeadsDay] {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }
        guard !days.isEmpty else { return [] }
        guard let url = Self.windowsURL(endpoint: endpoint, route: "motion-heads", days: days, deviceId: deviceId,
                                        known: known) else { throw ReadError.malformed("motion-heads endpoint") }
        let body = try await get(url: url, identity: identity)
        return Self.motionHeadsDays(from: body)
    }

    static func motionHeadsDays(from body: [String: Any]) -> [MotionHeadsDay] {
        ((body["days"] as? [[String: Any]]) ?? []).compactMap { entry in
            guard let day = entry["day"] as? String,
                  let revision = (entry["result_revision"] as? String)
                    ?? (entry["result_revision"] as? NSNumber)?.stringValue else { return nil }
            let unchanged = (entry["unchanged"] as? Bool) == true
            let rowSha = entry["bundle_sha256"] as? String
            func decoded<T: Decodable>(_ type: T.Type, _ value: Any?) -> T? {
                guard let object = value as? [String: Any],
                      let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
                return try? JSONDecoder().decode(type, from: data)
            }
            let authority = decoded(ActivityExpertAuthority.self, entry["authority"])
            var bundle = unchanged ? nil : decoded(MotionHeadsBundleInfo.self, entry["bundle"])
            if let b = bundle, let rowSha, b.bundleSha256 != rowSha { bundle = nil }
            let windowsJSON = unchanged ? nil : (entry["windows"] as? [String: Any]).flatMap { object in
                (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) }
            }
            let rawAuthority = entry["authority"] as? [String: Any]
            return MotionHeadsDay(day: day, resultRevision: revision,
                                  mode: entry["mode"] as? String ?? "shadow",
                                  unchanged: unchanged,
                                  releaseMode: weakerRelease(entry["release_mode"], rawAuthority?["release_mode"]),
                                  inputRevision: revisionNumber(entry["input_revision"])
                                    ?? revisionNumber(rawAuthority?["input_revision"]),
                                  bundleSha256: rowSha, bundle: bundle, authority: authority,
                                  windowsJSON: windowsJSON)
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

        let resolvedDay = scoring["day"] as? String ?? day
        let hosted = (scoring["hosted_snapshot"] as? [String: Any])
            .flatMap { HostedDayResult(day: resolvedDay, object: $0) }

        return ServerScoreSnapshot(
            day: resolvedDay,
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
            rawJSON: raw,
            hostedResult: hosted)
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

/// One 15-minute HRV reading from the hosted worker's intraday series.
public struct HrvSeriesPoint: Equatable, Sendable {
    /// Slot start, unix seconds.
    public let startTs: Int
    public let rmssd: Double
    /// Clean beats behind the reading; a thin slot is a weaker reading.
    public let cleanBeats: Int
    /// The worker's context flags for this slot (`hrv_series.context`, audit D6-14). Nil when the
    /// snapshot predates them: the point then renders as it always did.
    public let context: HrvSlotQuality?

    public init(startTs: Int, rmssd: Double, cleanBeats: Int, context: HrvSlotQuality? = nil) {
        self.startTs = startTs; self.rmssd = rmssd; self.cleanBeats = cleanBeats; self.context = context
    }
}

/// How well one intraday HRV slot is supported, as the worker published it. The reading itself stays
/// valid; a `weak` slot is one to show but not to lean on.
public struct HrvSlotQuality: Equatable, Sendable {
    public enum Reason: String, Equatable, Sendable, CaseIterable {
        /// A quarter or more of the slot was walking, running or other movement.
        case movement
        /// Half or more of the slot has no activity context (not covered, or the model abstained).
        case unknownContext = "unknown_context"
        /// The clean beats cover less than a third of the slot.
        case sparseBeats = "sparse_beats"
        /// The activity lane has not published this slot yet. Not a weakness of the reading: it never makes a
        /// point weak on its own (review R10).
        case contextPending = "context_pending"
    }

    public let weak: Bool
    /// Known reasons only; a code this build does not know still leaves `weak` as the worker set it.
    public let reasons: [Reason]
    public let movingShare: Double?
    public let unknownShare: Double?
    public let cleanCoverage: Double?

    public init(weak: Bool, reasons: [Reason], movingShare: Double? = nil, unknownShare: Double? = nil,
                cleanCoverage: Double? = nil) {
        self.weak = weak; self.reasons = reasons
        self.movingShare = movingShare; self.unknownShare = unknownShare; self.cleanCoverage = cleanCoverage
    }

    /// Parse one `hrv_series.context` entry; nil when it is malformed.
    init?(json: [String: Any]) {
        guard let weak = json["weak"] as? Bool else { return nil }
        let reasons = ((json["reasons"] as? [Any]) ?? []).compactMap { ($0 as? String).flatMap(Reason.init(rawValue:)) }
        // A slot flagged only because its context is not published yet is a normal reading, whatever the flag says.
        self.weak = weak && !(reasons == [.contextPending])
        self.reasons = reasons
        self.movingShare = (json["moving_share"] as? NSNumber)?.doubleValue
        self.unknownShare = (json["unknown_share"] as? NSNumber)?.doubleValue
        self.cleanCoverage = (json["clean_coverage"] as? NSNumber)?.doubleValue
    }
}

/// The hosted worker's published day result, in the shapes the dashboard already stores.
///
/// The worker runs the app's own `AnalyticsEngine.analyzeDay`, so each field maps one-to-one onto what
/// a local scoring pass would have persisted. Nothing here derives a value: a key the worker left out
/// stays nil, and a Charge the worker could not compute yet (no baseline) stays nil rather than zero.
public struct HostedDayResult: Equatable, Sendable {
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
    /// The optional Phase-1 sleep analytics document (`daily.sleep_analytics_v1`,
    /// docs/sleep-analytics/spec.md §8 app steps 1–5).
    /// Nil when the payload has no key, when it is malformed, when the schema version is not the
    /// supported v1, or when this app build has not learned a newer schema yet — never fatal. The
    /// Sleep page renders the Sleep analytics section only when this is non-nil AND the document's
    /// fragment fingerprint still matches the night on screen (the staleness guard), so builds
    /// without the payload render exactly as before.
    ///
    /// Cache: like `activityContext`/`sleepFeatures`, this rides inside the `daily` object that
    /// `snapshot()` keeps verbatim in `rawJSON`, so `writeCache` persists it automatically — no new
    /// cache field and a cached read re-parses through `snapshot()` offline (owner isolation
    /// unchanged: the per-owner cache key is untouched).
    public let sleepAnalytics: SleepAnalyticsDocument?

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
        var slotContext: [Int: HrvSlotQuality] = [:]
        for entry in (series?["context"] as? [Any]) ?? [] {
            guard let object = entry as? [String: Any],
                  let start = Self.number(object["slot_s"]).flatMap({ Int(exactly: $0) }),
                  let quality = HrvSlotQuality(json: object) else { continue }
            slotContext[start] = quality
        }
        self.hrvSeries = ((series?["points"] as? [Any]) ?? []).compactMap { entry -> HrvSeriesPoint? in
            guard let point = entry as? [Any], point.count >= 3,
                  let start = Self.number(point[0]).flatMap({ Int(exactly: $0) }),
                  let rmssd = Self.number(point[1]), rmssd > 0,
                  let beats = Self.number(point[2]).flatMap({ Int(exactly: $0) }) else { return nil }
            return HrvSeriesPoint(startTs: start, rmssd: rmssd, cleanBeats: beats, context: slotContext[start])
        }.sorted { $0.startTs < $1.startTs }
        self.activityContext = Self.activityContext(from: daily)
        self.sleepFeatures = Self.sleepFeatures(from: daily)
        self.sleepAnalytics = Self.sleepAnalytics(from: daily)
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

    /// Decode the optional Phase-1 sleep analytics document (`daily.sleep_analytics_v1`) into the
    /// SHARED StrandAnalytics schema — the same type the worker serializes with
    /// (docs/sleep-analytics/spec.md §8 app step 1).
    ///
    /// Deliberately non-fatal on every failure mode: a missing key, a non-object value, a malformed
    /// field or a future schema bump all return nil and leave the rest of the hosted result intact.
    /// An absent/unsupported version preserves old-result behavior (the day decodes with
    /// `sleepAnalytics == nil` exactly like a payload that never had the key).
    static func sleepAnalytics(from daily: [String: Any]) -> SleepAnalyticsDocument? {
        guard let raw = daily["sleep_analytics_v1"] else { return nil }
        guard JSONSerialization.isValidJSONObject(raw) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
        var decoded = try? JSONDecoder().decode(SleepAnalyticsDocument.self, from: data)
        if decoded == nil {
            // One spec-02 group at a time first, so a malformed morning response does not also drop a
            // good pNN50; then all of them together.
            for parts in [[Spec02AnalyticsPart.morningResponse], [.stageMovement], [.pnn50], Spec02AnalyticsPart.allCases] {
                guard let stripped = withoutSpec02Additions(raw, dropping: Set(parts)) else { continue }
                if let document = try? JSONDecoder().decode(SleepAnalyticsDocument.self, from: stripped) {
                    decoded = document
                    break
                }
            }
        }
        guard let document = decoded, document.schemaVersion == SleepAnalyticsV1.schemaVersion else { return nil }
        return document
    }

    /// The spec-02 additions to `sleep_analytics_v1` (docs/spec-02/CONTRACT.md §4).
    enum Spec02AnalyticsPart: CaseIterable, Hashable {
        case morningResponse, stageMovement, pnn50
    }

    /// The spec-02 additions are optional groups and fields on an otherwise strict decoder. When one of them does
    /// not decode (a newer or malformed shape), it is dropped and the document is decoded again, so the existing
    /// continuity / stage / movement / thermal / PRV groups survive another group's failure (spec-02 acceptance:
    /// "existing successful outputs survive another group's failure"). Nil when there was nothing to drop.
    static func withoutSpec02Additions(_ raw: Any, dropping parts: Set<Spec02AnalyticsPart>) -> Data? {
        guard var document = raw as? [String: Any] else { return nil }
        var changed = false
        if parts.contains(.morningResponse), document.removeValue(forKey: "morning_response") != nil { changed = true }
        if parts.contains(.stageMovement), var movement = document["movement"] as? [String: Any] {
            for key in ["stage_movement", "stage_movement_note"] where movement.removeValue(forKey: key) != nil {
                changed = true
            }
            document["movement"] = movement
        }
        if parts.contains(.pnn50), var prv = document["prv_diagnostics"] as? [String: Any] {
            for key in ["nightly_pnn50_pct", "pnn50_pair_count", "nn50_count", "pnn50_method"]
            where prv.removeValue(forKey: key) != nil {
                changed = true
            }
            if let windows = prv["windows"] as? [[String: Any]] {
                prv["windows"] = windows.map { window -> [String: Any] in
                    var w = window
                    if w.removeValue(forKey: "pnn50_pct") != nil { changed = true }
                    if w.removeValue(forKey: "nn50_count") != nil { changed = true }
                    return w
                }
            }
            document["prv_diagnostics"] = prv
        }
        guard changed, JSONSerialization.isValidJSONObject(document) else { return nil }
        return try? JSONSerialization.data(withJSONObject: document)
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

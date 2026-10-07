import Foundation
import StrandAnalytics

// AnomalyCandidateRepository.swift — the phone's read side of the VPS anomaly models (docs/BASELINE_WATCHDOG_V2.md §5).
//
//   GET {scores}/anomaly-candidates?deviceId=<id>&since=<result_revision>   → { candidates: [...], cursor, identity }
//
// TimesFM 3.0 (forecast) and UniTS (reconstruction) run on the VPS (`frwhoop-anomaly`). Their output is a
// CANDIDATE window, never an alert: WatchdogVerifier verifies every candidate against this phone's own baseline,
// activity, sensor-quality, significance and independence checks before anything can notify. The cursor makes
// each read incremental (only rows changed since the last read); retracted rows are dropped locally.
//
// Throttled (`minInterval`) and only asked from the Watchdog tick; no new background poll is added.

/// Feature gate for the server-model lane on the phone. ON by default; set `noop.anomalyCandidatesEnabled` = false
/// to stop reading (the Watchdog then verifies its own candidates only; personal deviations then need two
/// independent sensing paths to alert).
public enum AnomalyCandidateFeature {
    public static let disabledKey = "noop.anomalyCandidatesDisabled"
    public static var isEnabled: Bool { !UserDefaults.standard.bool(forKey: disabledKey) }
}

public actor AnomalyCandidateRepository {
    public enum ReadError: Error, Equatable {
        case notConfigured
        case missingIdentity
        case http(Int)
        case malformed(String)
    }

    public static let minInterval: TimeInterval = 120
    /// Rows older than this (by window end) are forgotten.
    public static let retention: TimeInterval = 24 * 3600

    private let session: URLSession
    private let endpoint: URL?
    private let identity: @Sendable () -> CloudPushIdentity?
    private var cursorByDevice: [String: Int] = [:]
    private var rowsByDevice: [String: [String: WatchdogModelCandidate]] = [:]
    private var lastFetch: [String: Date] = [:]
    private(set) var lastError: String?

    public init(session: URLSession = .shared, endpoint: URL? = nil,
                identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() }) {
        self.session = session
        self.endpoint = endpoint ?? ServerScoreRepository.derivedEndpoint()
        self.identity = identity
    }

    /// Fresh candidates for `deviceId` (refreshing at most every `minInterval`). Never throws: a failed read keeps
    /// the last known set and records `lastError` (the Watchdog simply has no model corroboration then).
    public func candidates(deviceId: String, now: Date = Date()) async -> [WatchdogModelCandidate] {
        if AnomalyCandidateFeature.isEnabled,
           lastFetch[deviceId].map({ now.timeIntervalSince($0) >= Self.minInterval }) ?? true {
            lastFetch[deviceId] = now
            do {
                try await refresh(deviceId: deviceId)
                lastError = nil
            } catch {
                lastError = String(describing: error)
            }
        }
        let cutoff = Int(now.timeIntervalSince1970 - Self.retention)
        rowsByDevice[deviceId] = rowsByDevice[deviceId]?.filter { $0.value.endUnix >= cutoff }
        return (rowsByDevice[deviceId].map { Array($0.values) } ?? []).sorted { $0.startUnix < $1.startUnix }
    }

    func refresh(deviceId: String) async throws {
        guard let endpoint else { throw ReadError.notConfigured }
        guard let identity = identity() else { throw ReadError.missingIdentity }
        var page = 0
        while page < 5 {
            page += 1
            var components = URLComponents(url: endpoint.appendingPathComponent("anomaly-candidates"),
                                           resolvingAgainstBaseURL: false)
            components?.queryItems = [URLQueryItem(name: "deviceId", value: deviceId),
                                      URLQueryItem(name: "since", value: String(cursorByDevice[deviceId] ?? 0))]
            guard let url = components?.url else { throw ReadError.malformed("endpoint") }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            CloudReceiverAuth.apply(identity, to: &request)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            request.timeoutInterval = 20
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw ReadError.malformed("no response") }
            guard http.statusCode == 200 else { throw ReadError.http(http.statusCode) }
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw ReadError.malformed("not an object")
            }
            let (rows, cursor) = try Self.parse(object)
            var current = rowsByDevice[deviceId] ?? [:]
            for (key, row) in rows {
                if let row, row.status != "retracted" { current[key] = row } else { current[key] = nil }
            }
            rowsByDevice[deviceId] = current
            let before = cursorByDevice[deviceId] ?? 0
            cursorByDevice[deviceId] = max(before, cursor)
            if rows.count < 200 || cursor <= before { break }
        }
    }

    /// Parses `{ candidates: [...], cursor }`. A row whose status is `retracted` maps to nil (drop it).
    static func parse(_ object: [String: Any]) throws -> (rows: [(String, WatchdogModelCandidate?)], cursor: Int) {
        guard let list = object["candidates"] as? [[String: Any]] else { throw ReadError.malformed("candidates") }
        let cursor = (object["cursor"] as? NSNumber)?.intValue ?? 0
        var out: [(String, WatchdogModelCandidate?)] = []
        for r in list {
            guard let key = r["candidate_key"] as? String else { continue }
            let status = (r["status"] as? String) ?? "candidate"
            guard status != "retracted",
                  let start = isoUnix(r["start_ts"]), let end = isoUnix(r["end_ts"]) else {
                out.append((key, nil)); continue
            }
            let modelP = (r["model_p"] as? [String: Any] ?? [:]).compactMapValues { ($0 as? NSNumber)?.doubleValue }
            let versions = (r["model_versions"] as? [String: Any] ?? [:]).compactMapValues { $0 as? String }
            out.append((key, WatchdogModelCandidate(
                candidateKey: key, startUnix: start, endUnix: end,
                channels: r["channels"] as? [String] ?? [],
                modelP: modelP, flaggedBy: r["flagged_by"] as? [String] ?? [],
                direction: (r["direction"] as? NSNumber)?.intValue ?? 0,
                score: (r["score"] as? NSNumber)?.doubleValue ?? 0,
                severity: r["severity"] as? String ?? "candidate", status: status,
                modelVersions: versions, computedAtUnix: isoUnix(r["computed_at"]) ?? end)))
        }
        return (out, cursor)
    }

    static func isoUnix(_ any: Any?) -> Int? {
        guard let s = any as? String else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return Int(d.timeIntervalSince1970) }
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return Int(d.timeIntervalSince1970) }
        // PostgREST may send "+00:00" offsets with microseconds; trim to milliseconds.
        if let dot = s.firstIndex(of: "."), let tz = s[dot...].firstIndex(where: { $0 == "+" || $0 == "-" || $0 == "Z" }) {
            let frac = s[s.index(after: dot)..<tz]
            let ms = String(frac.prefix(3))
            let trimmed = String(s[..<dot]) + "." + ms + String(s[tz...])
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return f.date(from: trimmed).map { Int($0.timeIntervalSince1970) }
        }
        return nil
    }

    // MARK: - Live repository

    private static var live: (scope: CloudDataScope, repository: AnomalyCandidateRepository)?

    @MainActor
    public static func runningAccountRepository() -> AnomalyCandidateRepository? {
        guard let scope = CloudPushRuntime.shared.runningScope else { return nil }
        if let l = live, l.scope == scope { return l.repository }
        let created = AnomalyCandidateRepository(identity: CloudPushRuntime.credentialProvider(for: scope))
        live = (scope, created)
        return created
    }
}

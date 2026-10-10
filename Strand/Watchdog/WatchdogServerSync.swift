import CryptoKit
import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Keeps three Watchdog records on the account, not only on this phone:
/// - the episode ledger and the wearer's notes (`POST scores/watchdog-episodes`): what was judged, against which
///   reference and exercise context, what was sent, what the wearer said — the alarm's lineage;
/// - the per-minute optical evidence only the phone holds (`POST scores/quality-minutes`): the v18 aux bytes are never
///   uploaded and are pruned after about a week, so without this a reading's contact quality is lost;
/// - the activity-context intervals (`POST scores/context-intervals`) as Layer 1 reads them (causal, the wearer's
///   corrections overlaid), so the server builds the same context-strata baselines for its event detection.
/// Best-effort and retried: an episode is marked sent, and the quality cursor advances, only after the server
/// accepted it. Runs only while the account syncs (an installation credential exists).
@MainActor
final class WatchdogServerSync {
    private let session: URLSession
    private let defaults: UserDefaults
    private var lastEpisodeAttempt = 0
    private var lastQualityAttempt = 0
    private var qualityInFlight = false
    private var lastContextAttempt = 0
    private var lastContextFullScan = 0
    private var contextInFlight = false

    static let episodeEverySeconds = 60
    static let qualityEverySeconds = 10 * 60
    /// First run: the phone keeps about 7 days of v18 aux.
    static let qualityFirstLookbackSeconds = 6 * 86_400
    /// Minutes younger than this wait (late offloads).
    static let qualitySettleSeconds = 5 * 60
    static let qualityChunkSeconds = 86_400
    static let contextEverySeconds = 30 * 60
    /// UTC days kept on the server (Layer 1's 60-day copy plus its change history), rescanned once a day.
    static let contextHistoryDays = 120
    /// Recent days, rescanned every run (late offloads, re-decodes, the wearer's corrections).
    static let contextRecentDays = 8
    static let contextFullScanEverySeconds = 86_400
    /// Days sent per run; the rest wait for the next run.
    static let contextDaysPerRun = 30
    /// A day with more intervals than this goes in 6-hour parts (the route takes at most 5000).
    static let contextMaxIntervalsPerPost = 4_000

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    private func post(_ path: String, body: [String: Any], identity: CloudPushIdentity) async -> Bool {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
        return await post(path, data: data, identity: identity)
    }

    private func post(_ path: String, data: Data, identity: CloudPushIdentity) async -> Bool {
        guard let base = PlacementCloudSync.derivedEndpoint() else { return false }
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: 30)
        req.httpMethod = "POST"
        CloudReceiverAuth.apply(identity, to: &req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        guard let (_, resp) = try? await session.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return (200..<300).contains(http.statusCode)
    }

    // MARK: Episodes

    func syncEpisodes(rows: [WatchdogEpisodeLedgerRow], annotations: [WatchdogEpisodeAnnotation],
                      localDeviceId: String, serverDeviceId: String?, now: Int) async {
        guard now - lastEpisodeAttempt >= Self.episodeEverySeconds,
              let serverDeviceId, let identity = CloudPushIdentityStore.current() else { return }
        lastEpisodeAttempt = now
        let key = "noop.watchdog.serverSync.episodes.v1.\(identity.ownerId).\(localDeviceId)"
        var sent = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let notes = Dictionary(annotations.map { ($0.episodeId, $0) }, uniquingKeysWith: { _, b in b })
        let changed = rows.filter { WatchdogEpisodeLedger.fingerprint($0, annotation: notes[$0.episodeId]) != sent[$0.episodeId] }
        guard !changed.isEmpty else { return }
        let versions = ["watchdog": WatchdogConfig.configVersion, "baseline": WatchdogExpectation.version,
                        "exercise_rule": ExerciseSessionRule.rule, "reason_codes": DataReasonCatalog.version]
        var start = 0
        while start < changed.count {
            let chunk = Array(changed[start..<min(start + 50, changed.count)])
            let body = WatchdogEpisodeLedger.serverBody(rows: chunk, annotations: annotations,
                                                        serverDeviceId: serverDeviceId, localDeviceId: localDeviceId,
                                                        versions: versions, nowUnix: now)
            guard await post("watchdog-episodes", body: body, identity: identity) else { return }
            for r in chunk { sent[r.episodeId] = WatchdogEpisodeLedger.fingerprint(r, annotation: notes[r.episodeId]) }
            start += 50
        }
        let live = Set(rows.map(\.episodeId))
        sent = sent.filter { live.contains($0.key) }
        defaults.set(sent, forKey: key)
    }

    // MARK: Quality minutes

    func syncQualityMinutes(store: WhoopStore, readIds: [String], localDeviceId: String, serverDeviceId: String?,
                            now: Int) async {
        guard !qualityInFlight, now - lastQualityAttempt >= Self.qualityEverySeconds,
              let serverDeviceId, let identity = CloudPushIdentityStore.current() else { return }
        lastQualityAttempt = now
        qualityInFlight = true
        defer { qualityInFlight = false }
        let key = "noop.watchdog.serverSync.qualityCursor.v1.\(identity.ownerId).\(localDeviceId)"
        let end = (now - Self.qualitySettleSeconds) - (now - Self.qualitySettleSeconds) % 60
        var cursor = (defaults.object(forKey: key) as? Int) ?? (end - Self.qualityFirstLookbackSeconds)
        while cursor < end {
            let to = min(end, cursor + Self.qualityChunkSeconds)
            var aux: [V18AuxSample] = []
            for id in readIds {
                var t = cursor
                var rows: [V18AuxSample] = []
                while t < to {
                    let next = min(to, t + 3_600)
                    rows += (try? await store.v18AuxSamples(deviceId: id, from: t, to: next - 1, limit: 8_000)) ?? []
                    t = next
                }
                if !rows.isEmpty { aux = rows; break }
            }
            let (from, upTo) = (cursor, to)
            let minutes = await Task.detached(priority: .utility) {
                WatchdogQualityMinutes.summarize(aux, from: from, to: upTo)
            }.value
            if !minutes.isEmpty {
                let body = WatchdogQualityMinutes.body(deviceId: serverDeviceId, rows: minutes)
                guard await post("quality-minutes", body: body, identity: identity) else { return }
            }
            cursor = to
            defaults.set(cursor, forKey: key)
        }
    }

    // MARK: Context intervals

    /// One interval as `POST scores/context-intervals` takes it (absent = NULL).
    struct ContextInterval: Encodable, Sendable, Equatable {
        var start_ts: Int, end_ts: Int, activity_class: String, confidence: Double, evidence_quality: Double
        var posture: String?, locomotion: String?, sleep_state: String?, wear_state: String?
        var intensity: Double?, hr_samples: Int, hr_mean: Double?, rmssd: Double?, rr_beats: Int
        var rr_diff_sq_sum_ms2: Double, rr_diff_count: Int, detail: String?, arm_behavior: String?
    }

    private struct ContextBody: Encodable {
        var device_id: String, version: String, source_id: String, from: Int, to: Int
        var intervals: [ContextInterval]
    }

    func syncContextIntervals(repo: Repository, localDeviceId: String, serverDeviceId: String?, now: Int) async {
        guard !contextInFlight, now - lastContextAttempt >= Self.contextEverySeconds,
              let serverDeviceId, let identity = CloudPushIdentityStore.current() else { return }
        lastContextAttempt = now
        contextInFlight = true
        defer { contextInFlight = false }
        let key = "noop.watchdog.serverSync.contextDays.v1.\(identity.ownerId).\(localDeviceId)"
        var sent = defaults.dictionary(forKey: key) as? [String: String] ?? [:]
        let today = now - now % 86_400
        let oldest = today - (Self.contextHistoryDays - 1) * 86_400
        let full = now - lastContextFullScan >= Self.contextFullScanEverySeconds
        let lo = full ? oldest : today - (Self.contextRecentDays - 1) * 86_400
        let rows = await repo.storedActivityContext(from: lo, to: now).intervals.map(\.storeRow)
        let version = LongitudinalBaseline.ContextMaterializer.version
        let days = await Task.detached(priority: .utility) {
            Self.contextDays(rows: rows, from: lo, through: today)
        }.value
        var budget = Self.contextDaysPerRun
        var complete = true
        for day in stride(from: today, through: lo, by: -86_400) {
            let dayKey = String(day)
            let items = days[day] ?? []
            let fingerprint = Self.fingerprint(items, version: version)
            if sent[dayKey] == fingerprint || (items.isEmpty && sent[dayKey] == nil) { continue }
            guard budget > 0 else { complete = false; break }
            budget -= 1
            let parts = items.count > Self.contextMaxIntervalsPerPost
                ? stride(from: day, to: day + 86_400, by: 6 * 3_600).map { ($0, $0 + 6 * 3_600) }
                : [(day, day + 86_400)]
            for (from, to) in parts {
                let body = ContextBody(device_id: serverDeviceId, version: version, source_id: localDeviceId,
                                       from: from, to: to,
                                       intervals: items.filter { $0.start_ts >= from && $0.start_ts < to })
                guard let data = try? JSONEncoder().encode(body),
                      await post("context-intervals", data: data, identity: identity) else {
                    defaults.set(sent, forKey: key)
                    return
                }
            }
            sent[dayKey] = fingerprint
        }
        if full && complete { lastContextFullScan = now }
        sent = sent.filter { (Int($0.key) ?? 0) >= oldest }
        defaults.set(sent, forKey: key)
    }

    /// The rows by UTC day of their start, as the route takes them: a label the route would refuse is sent as
    /// absent (the class as unknown), non-finite numbers as absent or 0, one row per start (the later one wins).
    nonisolated static func contextDays(rows: [ActivityContextIntervalRow], from: Int,
                                        through: Int) -> [Int: [ContextInterval]] {
        func text(_ v: String?) -> String? {
            guard let v, let first = v.unicodeScalars.first, v.unicodeScalars.count <= 64 else { return nil }
            func alnum(_ c: Unicode.Scalar) -> Bool { c.isASCII && CharacterSet.alphanumerics.contains(c) }
            guard alnum(first), v.unicodeScalars.allSatisfy({ alnum($0) || " ._:-".unicodeScalars.contains($0) })
            else { return nil }
            return v
        }
        func real(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
        func count(_ v: Int) -> Int { max(0, min(1_000_000, v)) }
        var byStart: [Int: ActivityContextIntervalRow] = [:]
        for r in rows where r.startTs >= from && r.startTs < through + 86_400 && r.endTs > r.startTs
            && r.endTs - r.startTs <= 86_400 {
            byStart[r.startTs] = r
        }
        var out: [Int: [ContextInterval]] = [:]
        for r in byStart.values.sorted(by: { $0.startTs < $1.startTs }) {
            out[r.startTs - r.startTs % 86_400, default: []].append(ContextInterval(
                start_ts: r.startTs, end_ts: r.endTs, activity_class: text(r.activityClass) ?? "unknown",
                confidence: real(r.confidence) ?? 0, evidence_quality: real(r.evidenceQuality) ?? 0,
                posture: text(r.posture), locomotion: text(r.locomotion), sleep_state: text(r.sleepState),
                wear_state: text(r.wearState), intensity: real(r.intensity), hr_samples: count(r.hrSamples),
                hr_mean: real(r.hrMean), rmssd: real(r.rmssd), rr_beats: count(r.rrBeats),
                rr_diff_sq_sum_ms2: real(r.rrDiffSqSumMs2) ?? 0, rr_diff_count: count(r.rrDiffCount),
                detail: text(r.detail), arm_behavior: text(r.armBehavior)))
        }
        return out
    }

    /// Stable across launches (Swift's Hasher is not): SHA-256 of the day's intervals and the materializer version.
    nonisolated static func fingerprint(_ items: [ContextInterval], version: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        var hash = SHA256()
        hash.update(data: Data(version.utf8))
        hash.update(data: (try? encoder.encode(items)) ?? Data())
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Keeps two Watchdog records on the account, not only on this phone:
/// - the episode ledger and the wearer's notes (`POST scores/watchdog-episodes`): what was judged, against which
///   reference and exercise context, what was sent, what the wearer said — the alarm's lineage;
/// - the per-minute optical evidence only the phone holds (`POST scores/quality-minutes`): the v18 aux bytes are never
///   uploaded and are pruned after about a week, so without this a reading's contact quality is lost.
/// Best-effort and retried: an episode is marked sent, and the quality cursor advances, only after the server
/// accepted it. Runs only while the account syncs (an installation credential exists).
@MainActor
final class WatchdogServerSync {
    private let session: URLSession
    private let defaults: UserDefaults
    private var lastEpisodeAttempt = 0
    private var lastQualityAttempt = 0
    private var qualityInFlight = false

    static let episodeEverySeconds = 60
    static let qualityEverySeconds = 10 * 60
    /// First run: the phone keeps about 7 days of v18 aux.
    static let qualityFirstLookbackSeconds = 6 * 86_400
    /// Minutes younger than this wait (late offloads).
    static let qualitySettleSeconds = 5 * 60
    static let qualityChunkSeconds = 86_400

    init(session: URLSession = .shared, defaults: UserDefaults = .standard) {
        self.session = session
        self.defaults = defaults
    }

    private func post(_ path: String, body: [String: Any], identity: CloudPushIdentity) async -> Bool {
        guard let base = PlacementCloudSync.derivedEndpoint(),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return false }
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
}

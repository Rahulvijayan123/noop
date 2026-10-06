import Foundation
import StrandAnalytics

// MARK: - Exposure event upload and reconcile

/// Sends pending exposure event revisions to the `scores` edge function and reads the account's recent revisions
/// back (contracts §8, §10):
///
///   - `POST {scores}/exposures` `{"events": [<revision JSON>]}` (≤ 25 per request) →
///     `{"results": [{"event_id", "revision", "status": "saved"|"ignored"|"rejected", "reason"}], "identity"}`
///   - `GET {scores}/exposures?from=<unix>&to=<unix>&history=1` → `{"events": [<revision JSON>], "identity"}`
///
/// Revision JSON is `PhysiologyContext.ExposureEventRevision` encoded with `PhysiologyContext.encoder()`.
///
/// Ownership: nothing is sent unless an account is signed in AND that account owns the on-device data
/// (`CloudLocalDataBinding.isOwner`), and only that account's own rows are read for upload, so one account's
/// events never upload as another's. Revisions recorded before anyone claimed the phone are adopted by the owner
/// first. Status handling: 2xx applies per-revision results; 405/404 (a server without the route) is
/// "unsupported" and keeps everything pending; 401 stops (the account layer renews the credential) and keeps
/// everything pending; 409 reconciles from the server (renumbering pending revisions that collide with another
/// phone's) and retries on the next flush; anything else stops and keeps everything pending. A revision is never
/// dropped for failing to upload.
enum ExposureEventCloudSync {

    @MainActor private static var running = false

    /// Best-effort flush for the app (call next to the stretch-feedback flush). Never throws; one run at a time.
    @MainActor
    static func flush() async {
        guard !running else { return }
        running = true
        defer { running = false }
        guard let store = await ExposureEventStoreLocator.resolve() else { return }
        let outcome = await ExposureEventSyncClient(store: store).sync()
        if outcome.uploaded + outcome.rejected + outcome.pulled > 0 || outcome.stopped != nil {
            NSLog("ExposureEventCloudSync: uploaded=\(outcome.uploaded) ignored=\(outcome.ignored) "
                  + "rejected=\(outcome.rejected) pulled=\(outcome.pulled) rebased=\(outcome.rebased) "
                  + "stopped=\(outcome.stopped?.rawValue ?? "-")")
        }
    }
}

/// The testable core of the exposure sync: session, endpoint, identity, ownership check and store are injected.
final class ExposureEventSyncClient: @unchecked Sendable {
    static let batchSize = 25
    /// The reconcile window reaches this far back (and one day ahead).
    static let pullWindowS = 30 * 86_400

    enum Stop: String, Equatable, Sendable {
        case signedOut = "signed_out"
        case notLocalOwner = "not_local_owner"
        case noEndpoint = "no_endpoint"
        /// The server has no exposure route yet (405/404).
        case unsupported
        case unauthorized
        case conflict
        case serverError = "server_error"
        case transport
        case identityMismatch = "identity_mismatch"
    }

    struct Outcome: Equatable, Sendable {
        var uploaded = 0
        var ignored = 0
        var rejected = 0
        var pulled = 0
        var rebased = 0
        var adopted = 0
        var stopped: Stop?
    }

    private let session: URLSession
    private let endpoint: @Sendable () -> URL?
    private let identity: @Sendable () -> CloudPushIdentity?
    private let isOwner: @Sendable (String) -> Bool
    private let store: ExposureEventStore
    private let now: @Sendable () -> Date

    init(store: ExposureEventStore,
         session: URLSession = .shared,
         endpoint: @escaping @Sendable () -> URL? = { PlacementCloudSync.derivedEndpoint() },
         identity: @escaping @Sendable () -> CloudPushIdentity? = { CloudPushIdentityStore.current() },
         isOwner: @escaping @Sendable (String) -> Bool = { CloudLocalDataBinding.isOwner($0) },
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.session = session
        self.endpoint = endpoint
        self.identity = identity
        self.isOwner = isOwner
        self.now = now
    }

    /// Adopt unclaimed revisions, reconcile the recent window, then upload pending revisions in batches.
    func sync() async -> Outcome {
        var outcome = Outcome()
        guard let id = identity() else { outcome.stopped = .signedOut; return outcome }
        guard isOwner(id.ownerId) else { outcome.stopped = .notLocalOwner; return outcome }
        guard let base = endpoint() else { outcome.stopped = .noEndpoint; return outcome }
        do { outcome.adopted = try store.adoptUnclaimed(owner: id.ownerId) } catch {
            NSLog("ExposureEventSync: adopt failed: \(error)")
        }
        // Reconcile first so a revision number another phone already used is renumbered before it is sent. A
        // missing route, a refused credential or someone else's reply stops everything; a transient read failure
        // still lets the upload run.
        if let stop = await pull(id: id, base: base, into: &outcome),
           [.unsupported, .unauthorized, .identityMismatch, .noEndpoint].contains(stop) {
            outcome.stopped = stop
            return outcome
        }
        outcome.stopped = await push(id: id, base: base, into: &outcome)
        return outcome
    }

    // MARK: Upload

    private struct Body: Encodable { let events: [ExposureEventStore.Revision] }

    private func push(id: CloudPushIdentity, base: URL, into outcome: inout Outcome) async -> Stop? {
        var sentKeys = Set<ExposureEventStore.Key>()
        while true {
            let batch: [ExposureEventStore.Revision]
            do {
                batch = try store.pending(owner: id.ownerId, limit: Self.batchSize)
                    .filter { !sentKeys.contains(ExposureEventStore.Key(eventId: $0.eventId, revision: $0.revision)) }
            } catch {
                NSLog("ExposureEventSync: pending read failed: \(error)")
                return nil
            }
            guard !batch.isEmpty else { return nil }
            for r in batch { sentKeys.insert(ExposureEventStore.Key(eventId: r.eventId, revision: r.revision)) }

            var request = URLRequest(url: base.appendingPathComponent("exposures"), timeoutInterval: 30)
            request.httpMethod = "POST"
            CloudReceiverAuth.apply(id, to: &request)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            do { request.httpBody = try PhysiologyContext.encoder().encode(Body(events: batch)) } catch {
                NSLog("ExposureEventSync: encode failed: \(error)")
                return .serverError
            }
            let data: Data
            let response: URLResponse
            do { (data, response) = try await session.data(for: request) } catch { return .transport }
            guard let http = response as? HTTPURLResponse else { return .transport }
            switch http.statusCode {
            case 200..<300: break
            case 404, 405: return .unsupported
            case 401, 403: return .unauthorized
            case 409:
                _ = await pull(id: id, base: base, into: &outcome)
                return .conflict
            default: return .serverError
            }
            guard Self.identityMatches(data, ownerId: id.ownerId) else { return .identityMismatch }
            let results = Self.results(in: data)
            var saved: [ExposureEventStore.Key] = [], ignored: [ExposureEventStore.Key] = []
            for r in results where batch.contains(where: { $0.eventId == r.key.eventId && $0.revision == r.key.revision }) {
                switch r.status {
                case .saved: saved.append(r.key)
                case .ignored: ignored.append(r.key)
                case .rejected:
                    try? store.markSynced(owner: id.ownerId, keys: [r.key], status: .rejected, reason: r.reason)
                    outcome.rejected += 1
                }
            }
            do {
                try store.markSynced(owner: id.ownerId, keys: saved, status: .saved)
                try store.markSynced(owner: id.ownerId, keys: ignored, status: .ignored)
            } catch {
                NSLog("ExposureEventSync: markSynced failed: \(error)")
                return nil
            }
            outcome.uploaded += saved.count
            outcome.ignored += ignored.count
            // A reply that names nothing would loop on the same rows: stop and retry on the next flush.
            if results.isEmpty { return nil }
        }
    }

    struct Result: Equatable {
        let key: ExposureEventStore.Key
        let status: ExposureEventStore.ServerStatus
        let reason: String?
    }

    /// Per-revision results of a POST reply. Unknown statuses and unreadable entries are skipped (those revisions
    /// stay pending), so an unexpected body never marks anything as delivered.
    static func results(in data: Data) -> [Result] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rows = json["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let eventId = row["event_id"] as? String,
                  let revision = (row["revision"] as? NSNumber)?.intValue,
                  let raw = row["status"] as? String,
                  let status = ExposureEventStore.ServerStatus(rawValue: raw) else { return nil }
            return Result(key: ExposureEventStore.Key(eventId: eventId, revision: revision), status: status,
                          reason: row["reason"] as? String)
        }
    }

    /// When the reply names the account it acted for, it must be ours.
    static func identityMatches(_ data: Data, ownerId: String) -> Bool {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let identity = json["identity"] as? [String: Any] else { return true }
        let named = (identity["userId"] ?? identity["user_id"] ?? identity["owner"]) as? String
        return named.map { $0.lowercased() == ownerId.lowercased() } ?? true
    }

    // MARK: Reconcile

    private func pull(id: CloudPushIdentity, base: URL, into outcome: inout Outcome) async -> Stop? {
        let t = Int(now().timeIntervalSince1970)
        guard var components = URLComponents(url: base.appendingPathComponent("exposures"),
                                             resolvingAgainstBaseURL: false) else { return .noEndpoint }
        components.queryItems = [URLQueryItem(name: "from", value: String(t - Self.pullWindowS)),
                                 URLQueryItem(name: "to", value: String(t + 86_400)),
                                 URLQueryItem(name: "history", value: "1")]
        guard let url = components.url else { return .noEndpoint }
        var request = URLRequest(url: url, timeoutInterval: 30)
        CloudReceiverAuth.apply(id, to: &request)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) } catch { return .transport }
        guard let http = response as? HTTPURLResponse else { return .transport }
        switch http.statusCode {
        case 200..<300: break
        case 404, 405: return .unsupported
        case 401, 403: return .unauthorized
        default: return .serverError
        }
        guard Self.identityMatches(data, ownerId: id.ownerId) else { return .identityMismatch }
        let revisions = Self.revisions(in: data)
        do {
            let r = try store.replaceFromServer(owner: id.ownerId, revisions: revisions)
            outcome.pulled += r.inserted + r.confirmed
            outcome.rebased += r.rebased
        } catch {
            NSLog("ExposureEventSync: reconcile failed: \(error)")
        }
        return nil
    }

    /// Revisions in a GET reply: `events` (and `revisions` when the server lists history separately), each decoded
    /// on its own so one unreadable entry does not hide the rest. Nested `revisions` arrays are read too.
    static func revisions(in data: Data) -> [ExposureEventStore.Revision] {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var raw: [[String: Any]] = []
        for key in ["events", "revisions"] {
            for item in (json[key] as? [[String: Any]]) ?? [] {
                raw.append(item)
                raw += (item["revisions"] as? [[String: Any]]) ?? []
            }
        }
        let decoder = PhysiologyContext.decoder()
        var seen = Set<ExposureEventStore.Key>()
        var out: [ExposureEventStore.Revision] = []
        for item in raw {
            guard let bytes = try? JSONSerialization.data(withJSONObject: item),
                  let r = try? decoder.decode(ExposureEventStore.Revision.self, from: bytes),
                  seen.insert(ExposureEventStore.Key(eventId: r.eventId, revision: r.revision)).inserted else { continue }
            out.append(r)
        }
        return out
    }
}

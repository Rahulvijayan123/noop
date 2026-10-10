import Foundation
import Combine

struct EventDetectorSetting: Codable, Identifiable {
    var typeId: UUID
    var enabled: Bool
    var revision: Int64
    var state: String
    var activeModelId: UUID?
    var lastTrainingAt: String?
    var lastInputAt: String?
    var detail: Detail
    var id: UUID { typeId }
    struct Detail: Codable {
        var reason: String?
        var candidate: String?
        var timeSavedSecondsPerDay: Double?
        var falseAlertsPerDay: Double?
        var recall: Double?
        var delaySeconds: Double?
        var events: Int?
        var coverage: Double?
        var reviewedHours: Double?
    }
    enum CodingKeys: String, CodingKey {
        case typeId = "type_id", enabled, revision, state, activeModelId = "active_model_id"
        case lastTrainingAt = "last_training_at", lastInputAt = "last_input_at", detail
    }
    var statusText: String {
        guard enabled else { return "Off" }
        switch state {
        case "active": return "Active"
        case "training": return "Training"
        case "waiting": return "Waiting for data"
        case "paused": return "Paused"
        default: return "Needs more examples"
        }
    }
}

struct DetectedEvent: Codable, Identifiable {
    var id: UUID
    var typeId: UUID
    var deviceId: UUID
    var start: Double
    var end: Double
    var modelId: UUID
    var status: String
    var manualEventId: UUID?
    var historical: Bool
    enum CodingKeys: String, CodingKey {
        case id, typeId = "type_id", deviceId = "device_id", start = "start_at", end = "end_at"
        case modelId = "model_id", status, manualEventId = "manual_event_id", historical
    }
}

struct EventDetectionCommand: Codable, Identifiable {
    var requestId = UUID()
    var action: String
    var typeId: UUID
    var enabled: Bool?
    var detectionId: UUID?
    var outcome: String?
    var start: Double?
    var end: Double?
    var deviceId: UUID?
    var reviewId: UUID?
    var id: UUID { requestId }
}

struct NegativeEventReview: Codable, Identifiable {
    var id: UUID; var typeId: UUID; var start: Double; var end: Double
}

/// Durable owner-bound writes. A server acknowledgement, not an optimistic toggle, confirms cloud state.
@MainActor
final class EventDetectionCenter: ObservableObject {
    static let shared = EventDetectionCenter()
    @Published private(set) var owner: String?
    @Published private(set) var settings: [EventDetectorSetting] = []
    @Published private(set) var detections: [DetectedEvent] = []
    @Published private(set) var pending: [EventDetectionCommand] = []
    @Published private(set) var negativeReviews: [NegativeEventReview] = []
    @Published private(set) var physiology: [String: EventPhysiology] = [:]
    /// The newest signature report per event type (signature-report-1), as last received for this owner.
    @Published private(set) var signatures: [UUID: SignatureReport] = [:]
    /// Types the cloud has answered for at least once (a report or "none yet").
    @Published private(set) var signaturesChecked: Set<UUID> = []
    /// The report bodies as received, kept in the owner's cache so the card shows without a connection.
    private var signatureBodies: [UUID: Data] = [:]
    @Published private(set) var message: String?
    @Published private(set) var error: String?
    private let identity: () -> CloudPushIdentity?
    private let endpoint: () -> URL?
    private let session: URLSession
    private let syncManual: () async -> Void
    private let automaticallySync: Bool
    private let directory: URL
    private var generation = UUID()
    private var syncing = false

    init(directory: URL? = nil, session: URLSession = .shared, automaticallySync: Bool = true,
         syncManual: @escaping () async -> Void = { await ManualEventCenter.shared.syncNow() },
         identity: @escaping () -> CloudPushIdentity? = { CloudPushIdentityStore.current() },
         endpoint: @escaping () -> URL? = { PlacementCloudSync.derivedEndpoint()?.appendingPathComponent("event-detection") }) {
        self.identity = identity; self.endpoint = endpoint; self.session = session
        self.syncManual = syncManual; self.automaticallySync = automaticallySync
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OpenWhoop/EventDetection", isDirectory: true)
    }
    private struct Cache: Codable {
        var settings: [EventDetectorSetting]; var detections: [DetectedEvent]; var pending: [EventDetectionCommand]
        var negativeReviews: [NegativeEventReview]?
        var signatures: [UUID: Data]?
    }
    private func cacheURL(_ owner: String) -> URL? {
        guard let uuid = UUID(uuidString: owner) else { return nil }
        return directory.appendingPathComponent(uuid.uuidString + ".json")
    }
    func bindAccount() {
        let next = identity()?.ownerId
        guard next != owner else { return }
        generation = UUID(); syncing = false; owner = next
        settings = []; detections = []; pending = []; negativeReviews = []; physiology = [:]; message = nil; error = nil
        signatures = [:]; signaturesChecked = []; signatureBodies = [:]
        if let next, let url = cacheURL(next), let data = try? Data(contentsOf: url),
           let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            settings = cache.settings; detections = cache.detections; pending = cache.pending
            negativeReviews = cache.negativeReviews ?? []
            signatureBodies = cache.signatures ?? [:]
            signatures = signatureBodies.compactMapValues(SignatureReport.decode)
            message = "Saved results. Refreshing cloud status."
        }
    }
    private func persist() throws {
        guard let owner, let url = cacheURL(owner) else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        #endif
        try JSONEncoder().encode(Cache(settings: settings, detections: detections, pending: pending, negativeReviews: negativeReviews,
                                       signatures: signatureBodies)).write(to: url, options: .atomic)
    }
    @discardableResult
    func enqueue(_ command: EventDetectionCommand, expectedOwner: String?) -> Bool {
        guard let owner, expectedOwner == owner, identity()?.ownerId == owner else { return false }
        pending.append(command)
        do { try persist() }
        catch { pending.removeLast(); self.error = "Could not save this change. Please try again."; return false }
        error = nil
        if automaticallySync { Task { await sync() } }
        return true
    }
    func isEnabled(_ type: UUID) -> Bool {
        pending.last(where: { $0.typeId == type && $0.action == "setting" })?.enabled
            ?? settings.first(where: { $0.typeId == type })?.enabled ?? false
    }
    func status(_ type: UUID) -> String {
        if pending.contains(where: { $0.typeId == type && $0.action == "setting" }) { return "Waiting to sync" }
        return settings.first(where: { $0.typeId == type })?.statusText ?? "Off"
    }
    private struct Identity: Decodable { var userId: String; var sourceId: String }
    private struct Page: Decodable {
        var identity: Identity; var settings: [EventDetectorSetting]; var detections: [DetectedEvent]; var next: String?
        var negativeReviews: [NegativeEventReview]?
    }
    private struct Ack: Decodable { var identity: Identity; var saved: UUID }
    private enum Failure: Error { case unavailable, invalid }
    private func send<T: Decodable>(_ request: URLRequest, as: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.invalid }
        if [404, 405, 503].contains(http.statusCode) { throw Failure.unavailable }
        guard (200..<300).contains(http.statusCode) else { throw Failure.invalid }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func sync() async {
        bindAccount()
        guard !syncing, let identity = identity(), let url = endpoint() else { return }
        let started = generation
        syncing = true
        defer { if started == generation { syncing = false } }
        do {
            // A type must reach the server before its detector setting or review can reference it.
            await syncManual()
            guard started == generation else { return }
            for command in pending {
                var request = URLRequest(url: url, timeoutInterval: 30)
                request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                CloudReceiverAuth.apply(identity, to: &request)
                request.httpBody = try JSONEncoder().encode(command)
                let ack = try await send(request, as: Ack.self)
                guard started == generation, self.identity()?.scope == identity.scope else { return }
                guard ack.saved == command.requestId, ack.identity.userId.lowercased() == identity.ownerId,
                      ack.identity.sourceId.lowercased() == identity.sourceId else { throw Failure.invalid }
                pending.removeAll { $0.id == command.id }; try persist()
            }
            var all: [DetectedEvent] = [], before: String?
            var fetched: [EventDetectorSetting] = []
            repeat {
                var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
                parts.queryItems = before.map { [URLQueryItem(name: "before", value: $0)] }
                var request = URLRequest(url: parts.url!, timeoutInterval: 30)
                CloudReceiverAuth.apply(identity, to: &request)
                let page = try await send(request, as: Page.self)
                guard started == generation, self.identity()?.scope == identity.scope else { return }
                guard page.identity.userId.lowercased() == identity.ownerId,
                      page.identity.sourceId.lowercased() == identity.sourceId,
                      page.next == nil || page.next != before else { throw Failure.invalid }
                all.append(contentsOf: page.detections); fetched = page.settings; before = page.next
                negativeReviews = page.negativeReviews ?? []
                guard all.count <= 20000 else { throw Failure.invalid }
            } while before != nil
            settings = fetched; detections = all; try persist(); message = nil
            await syncManual()
            // What each learning type's signature looks like now. A failure keeps the saved report.
            for setting in settings where setting.enabled {
                guard started == generation else { return }
                await loadSignature(for: setting.typeId)
            }
        } catch {
            guard started == generation else { return }
            message = (error as? Failure) == .unavailable
                ? "Cloud detection is not deployed yet. Your choices stay saved on this device."
                : "Cloud detection could not refresh. Saved results may be out of date; changes will retry."
        }
    }
    /// `GET <endpoint>/signature?typeId=`: the newest signature report of one event type, or none yet. Only a
    /// reply for this owner and installation, of this contract and this type, replaces the saved one.
    func loadSignature(for type: UUID) async {
        guard let id = identity(), id.ownerId == owner, let url = endpoint() else { return }
        let started = generation
        var parts = URLComponents(url: url.appendingPathComponent("signature"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "typeId", value: type.uuidString.lowercased())]
        var request = URLRequest(url: parts.url!, timeoutInterval: 30)
        CloudReceiverAuth.apply(id, to: &request)
        guard let reply = try? await session.data(for: request),
              let http = reply.1 as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              started == generation, identity()?.scope == id.scope,
              let root = try? JSONSerialization.jsonObject(with: reply.0) as? [String: Any],
              let who = root["identity"] as? [String: Any],
              (who["userId"] as? String)?.lowercased() == id.ownerId,
              (who["sourceId"] as? String)?.lowercased() == id.sourceId,
              root.keys.contains("report") else { return }
        if root["report"] is NSNull {
            signatures[type] = nil; signatureBodies[type] = nil
        } else {
            guard let object = root["report"] as? [String: Any],
                  let body = try? JSONSerialization.data(withJSONObject: object),
                  let report = SignatureReport.decode(body),
                  report.typeId.map({ $0.lowercased() == type.uuidString.lowercased() }) ?? true else { return }
            signatures[type] = report; signatureBodies[type] = body
        }
        signaturesChecked.insert(type)
        try? persist()
    }

    /// The short status under a type in the list: off, waiting to sync, or where its signature stands.
    func signatureStatus(_ type: UUID, loggedEvents: Int) -> String {
        if pending.contains(where: { $0.typeId == type && $0.action == "setting" }) { return "Waiting to sync" }
        guard isEnabled(type) else { return "Off" }
        return SignaturePresentation.status(signatures[type], loggedEvents: loggedEvents).title
    }

    #if DEBUG
    /// Simulator screenshots only: show a report without a server.
    func showSignatureForPreview(_ report: SignatureReport, for type: UUID) {
        signatures[type] = report; signaturesChecked.insert(type)
        if !settings.contains(where: { $0.typeId == type }) {
            settings.append(EventDetectorSetting(typeId: type, enabled: true, revision: 1, state: "needs_examples", detail: .init()))
        }
    }
    #endif

    struct TracePoint: Decodable { var time: Double; var value: Double; var support: Double }
    private struct Trace: Decodable {
        var identity: Identity; var heartRate: [TracePoint]; var hrv: [TracePoint]; var movement: [TracePoint]
    }
    func loadPhysiology(for event: HealthEvent) async {
        guard let id = identity(), event.ownerId == id.ownerId,
              let device = event.deviceId, let url = endpoint() else { return }
        let started = generation, end = event.endDate ?? event.date
        let low = event.date.addingTimeInterval(-1800), high = min(Date(), end.addingTimeInterval(1800))
        guard high > low, high.timeIntervalSince(low) <= 172800 else { return }
        var parts = URLComponents(url: url.appendingPathComponent("physiology"), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "deviceId", value: device),
            URLQueryItem(name: "from", value: String(low.timeIntervalSince1970)),
            URLQueryItem(name: "to", value: String(high.timeIntervalSince1970))]
        var request = URLRequest(url: parts.url!, timeoutInterval: 30); CloudReceiverAuth.apply(id, to: &request)
        guard let trace = try? await send(request, as: Trace.self), started == generation,
              self.identity()?.scope == id.scope, trace.identity.userId.lowercased() == id.ownerId,
              trace.identity.sourceId.lowercased() == id.sourceId else { return }
        func metric(_ name: String, _ unit: String, _ rows: [TracePoint], _ higher: Bool?) -> PhysiologyMetric {
            PhysiologyMetric(name: name, unit: unit, higherIsBetter: higher, points: rows.filter {
                $0.value.isFinite && $0.support > 0
            }.map { PhysiologyPoint(time: Date(timeIntervalSince1970: $0.time), value: $0.value, supportSeconds: $0.support) })
        }
        physiology[event.id] = EventPhysiology(metrics: [metric("Heart rate", "bpm", trace.heartRate, false),
            metric("HRV", "ms", trace.hrv, true), metric("Movement", "g", trace.movement, nil)],
            windowStart: low, eventStart: event.date, eventEnd: min(end, high), windowEnd: high)
    }
}

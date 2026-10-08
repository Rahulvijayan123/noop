import Foundation
import NoopPush

/// The HTTP layer for the NoopPush object lane (CONTRACTS C1): intent → presigned PUT → complete.
///
/// This is deliberately transport-only. The `PushCoordinator` drives the state machine (409
/// `object_id_conflict` retry-once, resume onto the same objectKey, receipt validation); this type
/// only builds the requests and parses the receiver's responses with the package's own parsers
/// (`PushObjectIntent.parse`, `PushObjectAck.parse`, `PushCapabilities.parse`).
///
/// Headers mirror `CloudUploadSession`: the installation credential (`CloudReceiverAuth`, which adds the
/// fleet token only for a legacy enrollment credential) and the capability negotiation header on every
/// receiver request, plus the manifest body for intents and exactly `intent.requiredHeaders` on the
/// presigned PUT.
///
/// It carries every object stream the phone uploads (raw IMU and, behind `PpgObjectUploadFeature`, anchored
/// PPG). It offers protocol 1.5 only while `offersPpgAnchor` is true: a receiver that advertises 1.5
/// negotiates it for the whole lane, so with the flag off the lane negotiates exactly what it did before.
public final class ImuObjectTransport: PushTransport, @unchecked Sendable {
    private let endpoint: URL
    private let identity: @Sendable () -> CloudPushIdentity?
    private let session: URLSession
    private let offersPpgAnchor: @Sendable () -> Bool
    private let lock = NSLock()
    /// The negotiated protocol version, refreshed by `capabilities()`. Used as the expected
    /// version when parsing acks (the receiver echoes it).
    private var protocolVersion = PushProtocol.objectVersion
    /// The stream of each object this transport opened, so a failed completion is labelled with its own stream.
    private var streamsByObjectId: [String: PushBinaryTable] = [:]

    public init(endpoint: URL,
                identity: @escaping @Sendable () -> CloudPushIdentity?,
                session: URLSession? = nil,
                offersPpgAnchor: @escaping @Sendable () -> Bool = { false }) {
        self.endpoint = endpoint
        self.identity = identity
        self.offersPpgAnchor = offersPpgAnchor
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 90
        configuration.timeoutIntervalForResource = 120
        self.session = session ?? URLSession(configuration: configuration)
    }

    // MARK: - PushTransport

    public func capabilities() async throws -> PushCapabilitiesResult {
        let request = try authRequest(endpoint, method: "GET", contentType: nil)
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw PushTransportException(PushFailure(code: .networkIO))
        }
        guard http.statusCode == 200 else {
            throw PushTransportException(PushError.httpFailure(status: http.statusCode, body: data,
                                                               expectedVersion: PushProtocol.version))
        }
        let caps = try PushCapabilities.parse(data)
        lock.lock(); protocolVersion = caps.protocolVersion; lock.unlock()
        return .available(caps)
    }

    public func createObjectIntent(_ manifest: PushObjectManifest, lane: PushObjectLane) async throws -> PushObjectIntent {
        let url = try objectURL(lane, objectId: nil)
        var request = try authRequest(url, method: "POST", contentType: "application/json")
        request.httpBody = try manifest.encode()
        let table = PushBinaryTable(rawValue: manifest.stream) ?? .rawImuSession
        lock.lock(); streamsByObjectId[manifest.objectId] = table; lock.unlock()
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw PushTransportException(PushFailure(code: .networkIO))
        }
        guard (200...299).contains(http.statusCode) else {
            throw PushTransportException(PushError.httpFailure(status: http.statusCode, body: data,
                                                               expectedVersion: manifest.protocolVersion,
                                                               table: table))
        }
        return try PushObjectIntent.parse(data, expectedObjectId: manifest.objectId,
                                          expectedVersion: manifest.protocolVersion)
    }

    public func uploadObject(_ intent: PushObjectIntent, body: Data) async throws {
        guard let uploadURL = intent.uploadUrl.flatMap({ URL(string: $0) }) else {
            throw PushTransportException(PushFailure(code: .localData))
        }
        var request = URLRequest(url: uploadURL)
        request.httpMethod = "PUT"
        request.httpBody = body
        for (name, value) in intent.requiredHeaders {
            request.setValue(value, forHTTPHeaderField: name)
        }
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw PushTransportException(PushFailure(code: .networkIO))
        }
        guard (200...299).contains(http.statusCode) else {
            throw PushTransportException(PushError.httpFailure(status: http.statusCode, body: data,
                                                               expectedVersion: PushProtocol.objectVersion))
        }
    }

    public func completeObject(objectId: String, lane: PushObjectLane) async throws -> PushObjectAck {
        let url = try objectURL(lane, objectId: objectId)
        let request = try authRequest(url, method: "POST", contentType: nil)
        lock.lock(); let table = streamsByObjectId[objectId] ?? .rawImuSession; lock.unlock()
        let (data, response) = try await perform(request)
        guard let http = response as? HTTPURLResponse else {
            throw PushTransportException(PushFailure(code: .networkIO))
        }
        guard (200...299).contains(http.statusCode) else {
            throw PushTransportException(PushError.httpFailure(status: http.statusCode, body: data,
                                                               expectedVersion: negotiatedVersion(),
                                                               table: table))
        }
        lock.lock(); streamsByObjectId[objectId] = nil; lock.unlock()
        return try PushObjectAck.parse(data, expectedObjectId: objectId,
                                       expectedVersion: negotiatedVersion())
    }

    /// The NDJSON inline lane is not part of this transport; the object lane never calls it.
    public func post(_ batch: PushBatch) async throws -> PushTransportResponse {
        throw PushTransportException(PushFailure(code: .localData))
    }

    // MARK: - Request construction

    /// The exact receiver header set `CloudUploadSession` sends.
    private func authRequest(_ url: URL, method: String, contentType: String?) throws -> URLRequest {
        guard let identity = identity() else {
            throw PushTransportException(PushFailure(code: .httpAuth))
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        CloudReceiverAuth.apply(identity, to: &request)
        request.setValue(PushProtocol.acceptVersions(offeringPPGAnchor: offersPpgAnchor()),
                         forHTTPHeaderField: "noop-push-accept-version")
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        return request
    }

    /// The object lane's advertised endpoint (`objectLane.endpoint`, e.g. `/functions/v1/push/objects`)
    /// resolved against the receiver origin; `objectId` appends the completion route.
    private func objectURL(_ lane: PushObjectLane, objectId: String?) throws -> URL {
        guard let base = URL(string: lane.endpoint, relativeTo: endpoint),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: true) else {
            throw PushTransportException(PushFailure(code: .localData))
        }
        if let objectId {
            let separator = components.path.hasSuffix("/") ? "" : "/"
            components.path = components.path + separator + objectId + "/complete"
        }
        guard let url = components.url else {
            throw PushTransportException(PushFailure(code: .localData))
        }
        return url
    }

    private func negotiatedVersion() -> String {
        lock.lock(); defer { lock.unlock() }
        return protocolVersion
    }

    private func perform(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch {
            throw PushTransportException(PushFailure(code: .networkIO))
        }
    }
}

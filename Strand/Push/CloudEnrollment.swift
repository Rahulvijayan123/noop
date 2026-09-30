import Foundation
import NoopPush
import CryptoKit

/// Which OS this installation is enrolling from. The receiver only accepts `ios`, `macos` (and
/// `android`, which this app never sends); anything else is rejected server-side with
/// `invalid_platform`.
public enum CloudEnrollmentPlatform: String, Sendable {
    case ios
    case macos
}

/// Typed enrollment / negotiation failures, keyed off the receiver's documented error codes.
///
/// `retryable` drives the UI: it is true for 5xx / 503 / 429 and for the window-elapsed retry the
/// UI may offer once; it is false for every other 4xx and for ownership failures, which are never
/// transient.
public enum CloudEnrollmentError: Error, LocalizedError, Equatable, Sendable {
    // Client-side (fail locally, no request was made)
    case malformedEnrollmentCode
    case invalidAppVersion
    case notConfigured
    // Server error bodies (`code` string on the wire)
    case invalidSourceId
    case invalidPlatform
    case enrollmentCodeInvalid
    case alreadyUsed
    case retryWindowElapsed
    case retryUnavailable
    case sourceAlreadyBound
    case expired
    case revoked
    case unauthorized
    case payloadTooLarge
    case malformedEnrollment
    case rateLimited
    case failed
    // Capability negotiation
    case unsupportedVersion
    case ownershipMismatch
    // Local transport / unknown status
    case transport
    case unexpectedStatus(Int)

    /// The receiver's wire `code` string for this error, when one exists. Nil for purely local
    /// failures, transport failures and the ownership guard.
    public var serverCode: String? {
        switch self {
        case .invalidSourceId: return "invalid_source_id"
        case .invalidPlatform: return "invalid_platform"
        case .invalidAppVersion: return "invalid_app_version"
        case .malformedEnrollmentCode: return "malformed_enrollment_code"
        case .enrollmentCodeInvalid: return "enrollment_code_invalid"
        case .alreadyUsed: return "enrollment_code_already_used"
        case .retryWindowElapsed: return "enrollment_retry_window_elapsed"
        case .retryUnavailable: return "enrollment_retry_unavailable"
        case .sourceAlreadyBound: return "enrollment_source_already_bound"
        case .expired: return "enrollment_code_expired"
        case .revoked: return "enrollment_code_revoked"
        case .notConfigured: return "enrollment_not_configured"
        case .unauthorized: return "unauthorized"
        case .payloadTooLarge: return "payload_too_large"
        case .malformedEnrollment: return "malformed_enrollment"
        case .rateLimited: return "rate_limited"
        case .failed: return "enrollment_failed"
        case .unsupportedVersion: return "unsupported_version"
        case .transport, .ownershipMismatch, .unexpectedStatus: return nil
        }
    }

    /// Whether the UI may offer a Retry. 5xx / 503 / 429 are retryable; 4xx are not, except
    /// `retryWindowElapsed`, which the UI may offer to retry once. Ownership and local-code failures
    /// are never retryable.
    public var retryable: Bool {
        switch self {
        case .retryWindowElapsed: return true
        case .notConfigured: return true
        case .rateLimited: return true
        case .failed: return true
        case .transport: return true
        case .unexpectedStatus(let status): return status >= 500 || status == 429
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .invalidSourceId: return "The installation id is invalid. Please try again."
        case .invalidPlatform: return "This platform can't enroll."
        case .invalidAppVersion: return "The app version couldn't be read. Please update NOOP."
        case .malformedEnrollmentCode: return "That enrollment code isn't valid. Check it and try again."
        case .enrollmentCodeInvalid: return "That enrollment code wasn't found."
        case .alreadyUsed: return "That enrollment code has already been used."
        case .retryWindowElapsed: return "The retry window for this enrollment has passed."
        case .retryUnavailable: return "This enrollment can't be retried right now."
        case .sourceAlreadyBound: return "This installation is already bound to a different owner."
        case .expired: return "That enrollment code has expired."
        case .revoked: return "That enrollment code has been revoked."
        case .notConfigured: return "Cloud mode isn't configured on this build."
        case .unauthorized: return "The cloud service rejected these credentials."
        case .payloadTooLarge: return "The enrollment request was too large."
        case .malformedEnrollment: return "The cloud service couldn't read the request."
        case .rateLimited: return "Too many attempts. Wait a minute and try again."
        case .failed: return "The cloud service failed. Try again."
        case .transport: return "Couldn't reach the cloud service. Check your connection."
        case .unsupportedVersion: return "This build's protocol version isn't supported by the server."
        case .ownershipMismatch: return "The cloud server returned a different account. Enroll again."
        case .unexpectedStatus(let status): return "The cloud service returned an error (HTTP \(status))."
        }
    }

    /// Map a server `code` string + HTTP status to the typed error.
    ///
    /// Accepts both the authoritative wire codes (`enrollment_code_already_used`, …) and the shorter
    /// forms the brief lists (`already_used`, `retry_window_elapsed`, …), so either spelling maps
    /// correctly.
    init(code: String?, status: Int) {
        switch code {
        case "invalid_source_id": self = .invalidSourceId
        case "invalid_platform": self = .invalidPlatform
        case "invalid_app_version": self = .invalidAppVersion
        case "malformed_enrollment_code": self = .malformedEnrollmentCode
        case "enrollment_code_invalid": self = .enrollmentCodeInvalid
        case "enrollment_code_already_used", "already_used": self = .alreadyUsed
        case "enrollment_retry_window_elapsed", "retry_window_elapsed": self = .retryWindowElapsed
        case "enrollment_retry_unavailable", "retry_unavailable": self = .retryUnavailable
        case "enrollment_source_already_bound", "source_already_bound": self = .sourceAlreadyBound
        case "enrollment_code_expired", "expired": self = .expired
        case "enrollment_code_revoked", "revoked": self = .revoked
        case "enrollment_not_configured": self = .notConfigured
        case "unauthorized": self = .unauthorized
        case "payload_too_large": self = .payloadTooLarge
        case "malformed_enrollment": self = .malformedEnrollment
        case "intake_rate_limited", "ingest_quota_exceeded", "rate_limited": self = .rateLimited
        case "unsupported_version": self = .unsupportedVersion
        // Server-side faults the client can only retry.
        case "enrollment_service_role_required", "enrollment_failed": self = .failed
        default: self = .unexpectedStatus(status)
        }
    }
}

/// The UI-renderable enrollment state. `enrolled` carries the adopted owner/source and the protocol
/// version the app will speak; `failed` carries a short message plus whether the UI may offer Retry.
public enum EnrollmentState: Equatable, Sendable {
    case notEnrolled
    case enrolling
    case enrolled(ownerId: String, sourceId: String, protocolVersion: String)
    case failed(message: String, retryable: Bool)

    /// True while a request is in flight (the UI shows a progress indicator).
    public var isEnrolling: Bool {
        if case .enrolling = self { return true }
        return false
    }

    /// True after a successful enrollment.
    public var isEnrolled: Bool {
        if case .enrolled = self { return true }
        return false
    }
}

/// The negotiated capability document plus the negotiated protocol version.
public struct CloudCapabilities: Sendable {
    public let protocolVersion: String
    public let capabilities: PushCapabilities

    public init(protocolVersion: String, capabilities: PushCapabilities) {
        self.protocolVersion = protocolVersion
        self.capabilities = capabilities
    }
}

/// Namespace for enrollment helpers: code canonicalization and the per-owner protocol-version cache.
public enum CloudEnrollment {

    /// The deployed receiver's preference order for capability negotiation. The server picks the
    /// FIRST of its own preference list that the client offers, so offering `1.3,1.2,1.1,1.0` lands
    /// on the newest protocol the deployment supports.
    public static let acceptVersions = "1.3,1.2,1.1,1.0"

    /// The protocol version reported when negotiation has never run. The deployed edge prefers
    /// 1.3 > 1.2 > 1.1 > 1.0, and the NEGOTIATED value always wins over this default.
    public static let defaultProtocolVersion = "1.2"

    private static let negotiatedVersionKeyPrefix = "noop.cloud.negotiatedProtocol"
    private static let enrollmentCodePattern = "^NARA[0-9A-HJKMNP-TV-Z]{20}$"
    private static let enrollmentCodeRegex: NSRegularExpression = {
        // The pattern is a compile-time constant; a failure here is a programming error.
        try! NSRegularExpression(pattern: enrollmentCodePattern)
    }()

    /// Canonicalize an enrollment code exactly as the receiver does:
    /// strip ASCII whitespace + hyphens, uppercase, then map I→1, L→1, O→0.
    /// Returns nil when the result does not match `^NARA[0-9A-HJKMNP-TV-Z]{20}$`.
    public static func canonicalCode(_ code: String) -> String? {
        // The receiver rejects over-long codes before canonicalizing; mirror that bound.
        guard code.count <= 128 else { return nil }
        let stripped = code.filter { !" \t\n\r\u{000B}\u{000C}-".contains($0) }
        let uppercased = stripped.uppercased()
        let mapped = String(uppercased.map { character in
            switch character {
            case "I", "L": return "1"
            case "O": return "0"
            default: return character
            }
        })
        let range = NSRange(location: 0, length: mapped.utf16.count)
        guard enrollmentCodeRegex.firstMatch(in: mapped, options: [], range: range) != nil else {
            return nil
        }
        return mapped
    }

    // MARK: - Protocol-version cache (keyed by owner)

    public static func negotiatedProtocolVersion(forOwner ownerId: String) -> String? {
        let owner = ownerId.lowercased()
        return UserDefaults.standard.string(forKey: "\(negotiatedVersionKeyPrefix).\(owner)")
    }

    static func storeNegotiatedVersion(_ version: String, forOwner ownerId: String) {
        let owner = ownerId.lowercased()
        UserDefaults.standard.set(version, forKey: "\(negotiatedVersionKeyPrefix).\(owner)")
    }

    /// The protocol version the app should use for the current owner: the negotiated value when one
    /// has been cached, otherwise the deployed `defaultProtocolVersion` ("1.2"). Negotiation always
    /// wins once it has run.
    public static func currentProtocolVersion() -> String {
        guard let owner = CloudPushIdentityStore.currentOwnerId() else { return defaultProtocolVersion }
        return negotiatedProtocolVersion(forOwner: owner) ?? defaultProtocolVersion
    }
}

/// Client for the receiver's enrollment + capability endpoints.
///
/// Enrollment is the ONE cloud path that uses the FLEET token as the bearer: it redeems a
/// human-readable enrollment code into a per-installation `noop_…` credential. Every later request
/// (ingest, capabilities, readback) switches to that installation credential plus the fleet token in
/// `x-noop-fleet-token`.
///
/// Wire contract (verified against the deployed edge):
///   POST <base>/enroll   → 201 {type, protocolVersion, userId, sourceId, tokenId, uploadToken}
///   GET  <base>          → 200 capabilities (negotiates protocolVersion)
public struct CloudEnrollmentClient: Sendable {

    /// The receiver base (`…/functions/v1/push`). `enroll` posts to `<base>/enroll`; capability
    /// negotiation GETs `<base>`. Nil resolves from `CloudPushSettings` at call time, so an
    /// unconfigured build fails locally with `.notConfigured` before any network call.
    public var endpoint: URL?

    /// The session used for every request. Inject a mock-backed session for tests.
    public var session: URLSession

    /// Override for the fleet token. Nil uses `CloudPushSettings.fleetToken` (the Info.plist
    /// credential). Injected so the wire contract can be exercised without a signed bundle.
    public var fleetToken: String?

    public init(session: URLSession = .shared, endpoint: URL? = nil, fleetToken: String? = nil) {
        self.session = session
        self.endpoint = endpoint
        self.fleetToken = fleetToken
    }

    // MARK: - Enrollment

    /// Redeem `code` and adopt the returned installation credential.
    ///
    /// - Parameter code: the raw enrollment code the user typed (canonicalization happens here).
    /// - Parameter appVersion: the app's marketing version (1…64 chars, no control characters).
    /// - Parameter platform: `ios` or `macos`.
    /// - Returns: the adopted `CloudPushIdentity` (ownerId/sourceId/tokenId/uploadToken).
    ///
    /// The code is validated against `^NARA[0-9A-HJKMNP-TV-Z]{20}$` after canonicalization, and an
    /// invalid code fails locally with `.malformedEnrollmentCode` before any network call. On a 201
    /// the installation token is persisted to the Keychain via `CloudPushIdentityStore.adopt(_:)`.
    /// The upload token is never logged.
    public func enroll(code: String, appVersion: String, platform: CloudEnrollmentPlatform) async throws -> CloudPushIdentity {
        guard let canonical = CloudEnrollment.canonicalCode(code) else {
            throw CloudEnrollmentError.malformedEnrollmentCode
        }
        // Fail fast on the other locally-checkable field the receiver validates.
        let trimmedVersion = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVersion.isEmpty, trimmedVersion.count <= 64,
              !trimmedVersion.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw CloudEnrollmentError.invalidAppVersion
        }
        guard let url = enrollmentURL() else { throw CloudEnrollmentError.notConfigured }
        let fleet = resolvedFleetToken()
        guard !fleet.isEmpty else { throw CloudEnrollmentError.notConfigured }

        let body: [String: String] = [
            "code": canonical,
            "sourceId": CloudPushIdentityStore.sourceId(),
            "platform": platform.rawValue,
            "appVersion": trimmedVersion,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(fleet)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 20
        request.httpBody = payload

        let data: Data
        let status: Int
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudEnrollmentError.transport }
            data = responseData
            status = http.statusCode
        } catch let error as CloudEnrollmentError {
            throw error
        } catch {
            throw CloudEnrollmentError.transport
        }

        guard (200..<300).contains(status) else {
            throw CloudEnrollmentError(code: Self.errorCode(from: data), status: status)
        }

        let identity = try Self.parseEnrollmentResponse(data)
        CloudPushIdentityStore.adopt(identity)
        return identity
    }

    /// Negotiate the protocol version + capability set with the deployed receiver.
    ///
    /// Uses the stored installation credential (`Authorization`) plus the fleet token
    /// (`x-noop-fleet-token`) and offers `noop-push-accept-version: 1.3,1.2,1.1,1.0`. A 406 becomes
    /// the typed `.unsupportedVersion`. The returned userId/sourceId MUST match the stored identity;
    /// a mismatch is `.ownershipMismatch` (an ownership failure, never transient), and the caller
    /// must not proceed. On success the negotiated protocol version is cached per owner.
    /// Confirm the provisional device for this installation against the strap's
    /// real Device Information serial, so the server can link this source to
    /// the wearer's canonical `whoop-<serial>` device. Without this the score
    /// readback route honestly reports `device_registration_pending`.
    /// Wire contract (deployed edge, verified live): POST <base>/wearables/confirm
    /// with Bearer installation token + fleet header; body {provisionalExternalDeviceId,
    /// evidence{method, serial, receiptSha256}}; 200 {userId, sourceId, deviceId, state:"confirmed"}.
    public func confirmWearable(provisionalExternalDeviceId: String, serial: String) async throws -> String {
        guard let base = enrollmentURL()?.deletingLastPathComponent() else { throw CloudEnrollmentError.notConfigured }
        guard let url = URL(string: base.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/wearables/confirm") else { throw CloudEnrollmentError.notConfigured }
        guard let identity = CloudPushIdentityStore.current() else { throw CloudEnrollmentError.unauthorized }
        let witness = "device_information_serial_v1:\(identity.sourceId):\(provisionalExternalDeviceId):\(serial)"
        let digest = SHA256.hash(data: Data(witness.utf8)).map { String(format: "%02x", $0) }.joined()
        let body: [String: Any] = [
            "provisionalExternalDeviceId": provisionalExternalDeviceId,
            "evidence": [
                "method": "device_information_serial_v1",
                "serial": serial,
                "receiptSha256": digest,
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.cachePolicy = URLRequest.CachePolicy.reloadIgnoringLocalCacheData
        request.setValue("Bearer \(identity.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue(resolvedFleetToken(), forHTTPHeaderField: "x-noop-fleet-token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["state"] as? String == "confirmed",
              (object["userId"] as? String)?.lowercased() == identity.ownerId else {
            throw CloudEnrollmentError.failed
        }
        return object["deviceId"] as? String ?? ""
    }

    public func negotiateCapabilities() async throws -> CloudCapabilities {
        guard let identity = CloudPushIdentityStore.current() else {
            throw CloudEnrollmentError.unauthorized
        }
        guard let url = capabilitiesURL() else { throw CloudEnrollmentError.notConfigured }
        let fleet = resolvedFleetToken()
        guard !fleet.isEmpty else { throw CloudEnrollmentError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(identity.uploadToken)", forHTTPHeaderField: "Authorization")
        request.setValue(fleet, forHTTPHeaderField: "x-noop-fleet-token")
        request.setValue(CloudEnrollment.acceptVersions, forHTTPHeaderField: "noop-push-accept-version")
        request.timeoutInterval = 20

        let data: Data
        let status: Int
        do {
            let (responseData, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudEnrollmentError.transport }
            data = responseData
            status = http.statusCode
        } catch let error as CloudEnrollmentError {
            throw error
        } catch {
            throw CloudEnrollmentError.transport
        }

        guard status != 406 else { throw CloudEnrollmentError.unsupportedVersion }
        guard status == 200 else {
            throw CloudEnrollmentError(code: Self.errorCode(from: data), status: status)
        }

        let capabilities: PushCapabilities
        do {
            capabilities = try PushCapabilities.parse(data)
        } catch {
            throw CloudEnrollmentError.failed
        }
        guard capabilities.userId?.lowercased() == identity.ownerId,
              capabilities.sourceId?.lowercased() == identity.sourceId else {
            throw CloudEnrollmentError.ownershipMismatch
        }
        CloudEnrollment.storeNegotiatedVersion(capabilities.protocolVersion, forOwner: identity.ownerId)
        return CloudCapabilities(protocolVersion: capabilities.protocolVersion, capabilities: capabilities)
    }

    // MARK: - Request plumbing

    /// The fleet credential to send: the injected override when present, else `CloudPushSettings`.
    private func resolvedFleetToken() -> String {
        fleetToken ?? CloudPushSettings.fleetToken
    }

    /// `<base>/enroll`, or the configured `…/push/enroll` when no endpoint was injected.
    private func enrollmentURL() -> URL? {
        if let endpoint { return endpoint.appendingPathComponent("enroll") }
        return CloudPushSettings.route("enroll")
    }

    /// `<base>` (capability negotiation hits the receiver root), or the configured base URL.
    private func capabilitiesURL() -> URL? {
        if let endpoint { return endpoint }
        return CloudPushSettings.route("")
    }

    /// The `code` member of a JSON error body, or nil when the body isn't that shape.
    private static func errorCode(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty else { return nil }
        return code
    }

    /// Parse the 201 enrollment body. Any 2xx with an unreadable body is a server fault (`.failed`).
    private static func parseEnrollmentResponse(_ data: Data) throws -> CloudPushIdentity {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = object["userId"] as? String, !userId.isEmpty,
              let sourceId = object["sourceId"] as? String, !sourceId.isEmpty,
              let tokenId = object["tokenId"] as? String, !tokenId.isEmpty,
              let uploadToken = object["uploadToken"] as? String, !uploadToken.isEmpty else {
            throw CloudEnrollmentError.failed
        }
        return CloudPushIdentity(ownerId: userId, sourceId: sourceId, tokenId: tokenId, uploadToken: uploadToken)
    }
}

import Foundation
import NoopPush
import CryptoKit

/// Which OS this installation runs on. The receiver only accepts `ios` / `macos` from this app.
public enum CloudProvisioningPlatform: String, Sendable {
    case ios
    case macos

    public static var current: CloudProvisioningPlatform {
        #if os(iOS)
        return .ios
        #else
        return .macos
        #endif
    }
}

/// Typed failures of the receiver's account endpoints (provisioning, wearable confirmation, capability
/// negotiation), keyed off the documented error codes. `isTransient` separates "try again later" from
/// "this account can not use this installation": the caller never retries the latter blindly.
public enum CloudReceiverError: Error, LocalizedError, Equatable, Sendable {
    case notConfigured
    case notSignedIn
    /// The Supabase session was rejected (401): the account may have been deleted, banned or signed out.
    case sessionRejected
    case emailNotConfirmed
    /// The installation credential was rejected (401): revoked, expired, retired or the account is gone.
    case credentialRejected
    /// This source id is not available to this account (it belongs to nobody, or to someone else). The
    /// two are deliberately indistinguishable to the client.
    case installationUnavailable
    case installationRetired
    case installationRevoked
    case accountRetired
    case installationLimit
    case rateLimited(retryAfter: TimeInterval?)
    case serverFault(Int)
    case transport
    case malformedResponse
    /// The server answered for a different account or source than the one asked about.
    case ownershipMismatch
    case unsupportedVersion
    case rejected(code: String?, status: Int)

    public var isTransient: Bool {
        switch self {
        case .rateLimited, .serverFault, .transport: return true
        default: return false
        }
    }

    public var errorDescription: String? {
        switch self {
        case .notConfigured: return String(localized: "Nara isn't configured with a cloud account service in this build.")
        case .notSignedIn: return String(localized: "Sign in to your Nara account first.")
        case .sessionRejected: return String(localized: "Your Nara sign-in is no longer valid. Sign in again.")
        case .emailNotConfirmed: return String(localized: "Confirm your email address first, then try again.")
        case .credentialRejected: return String(localized: "This phone's Nara upload access was revoked. Sign in again to restore it.")
        case .installationUnavailable: return String(localized: "This phone couldn't be linked to your account. Try again.")
        case .installationRetired, .installationRevoked:
            return String(localized: "This phone's link to your account was removed. It will be set up again.")
        case .accountRetired: return String(localized: "This Nara account has been closed.")
        case .installationLimit: return String(localized: "This account is linked to too many phones. Remove one and try again.")
        case .rateLimited: return String(localized: "Too many attempts. Wait a few minutes and try again.")
        case .serverFault: return String(localized: "The Nara service had a problem. Try again shortly.")
        case .transport: return String(localized: "Couldn't reach the Nara service. Check your connection.")
        case .malformedResponse: return String(localized: "The Nara service sent an unexpected reply.")
        case .ownershipMismatch: return String(localized: "The Nara service answered for a different account. Nothing was changed.")
        case .unsupportedVersion: return String(localized: "This version of Nara isn't supported by the service. Update the app.")
        case .rejected: return String(localized: "The Nara service rejected the request.")
        }
    }

    init(code: String?, status: Int, retryAfter: TimeInterval? = nil) {
        switch (code, status) {
        case ("email_not_confirmed", _): self = .emailNotConfirmed
        case ("installation_unavailable", _): self = .installationUnavailable
        case ("installation_retired", _): self = .installationRetired
        case ("installation_revoked", _): self = .installationRevoked
        case ("account_retired", _): self = .accountRetired
        case ("installation_limit", _): self = .installationLimit
        case ("provision_rate_limited", _), (_, 429): self = .rateLimited(retryAfter: retryAfter)
        case ("unsupported_version", _): self = .unsupportedVersion
        case (_, 401): self = .rejected(code: code, status: 401)
        case (_, 500...): self = .serverFault(status)
        default: self = .rejected(code: code, status: status)
        }
    }
}

/// The single place that decides which credential headers a receiver request carries.
///
/// The per-account installation token is the bearer on every request and is enough on its own. The
/// shared fleet header exists only for an installation that was redeemed with a legacy enrollment code,
/// and is empty (so never sent) in any build that does not explicitly allow that path.
enum CloudReceiverAuth {
    static func apply(_ identity: CloudPushIdentity, to request: inout URLRequest) {
        request.setValue("Bearer \(identity.uploadToken)", forHTTPHeaderField: "Authorization")
        if identity.provisioning == .legacyEnrollment {
            let fleet = CloudPushSettings.fleetToken
            if !fleet.isEmpty { request.setValue(fleet, forHTTPHeaderField: "x-noop-fleet-token") }
        }
    }
}

/// What the server granted for one `(account, source)`.
public struct CloudInstallationGrant: Equatable, Sendable {
    public enum Action: String, Sendable { case created, reused, rotated, upgraded }

    public let userId: String
    public let sourceId: String
    public let tokenId: String
    public let action: Action
    public let expiresAt: Date?
    /// Present unless the presented credential is still valid (`reused`). Never logged.
    public let installationToken: String?
}

/// The negotiated capability document plus the negotiated protocol version.
public struct CloudCapabilities: Sendable {
    public let protocolVersion: String
    public let capabilities: PushCapabilities
}

/// Protocol-version helpers shared by the transport.
public enum CloudReceiverProtocol {
    /// The deployed receiver's preference order for capability negotiation. The server picks the FIRST of
    /// its own preference list that the client offers, so offering `1.3,1.2,1.1,1.0` lands on the newest
    /// protocol the deployment supports.
    public static let acceptVersions = "1.3,1.2,1.1,1.0"
    public static let defaultProtocolVersion = "1.2"
}

/// Client for the receiver's account endpoints.
///
///   POST <base>/installations/provision   (Supabase access token)  → installation credential
///   POST <base>/wearables/confirm         (installation credential) → canonical device link
///   GET  <base>                           (installation credential) → capability negotiation
///
/// Every call is bound to an explicit identity (or session) passed in by the caller. Nothing here reads
/// "the current account", so a call started for one account can not complete on behalf of another.
public struct CloudReceiverClient: Sendable {
    /// The receiver base (`…/functions/v1/push`). Nil resolves from `CloudPushSettings` at call time, so an
    /// unconfigured build fails locally with `.notConfigured` before any network call.
    public var endpoint: URL?
    public var session: URLSession
    /// Sent as `apikey` on provisioning so a gateway that wants a project key is satisfied.
    public var publishableKey: String?

    public init(session: URLSession = .shared, endpoint: URL? = nil, publishableKey: String? = nil) {
        self.session = session
        self.endpoint = endpoint
        self.publishableKey = publishableKey
    }

    private var base: URL? { endpoint ?? CloudPushSettings.receiverURL }

    private func route(_ path: String) -> URL? {
        guard let base else { return nil }
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? base : base.appendingPathComponent(trimmed)
    }

    // MARK: - Provisioning

    /// Ask the server to bind this installation to the account the access token belongs to.
    ///
    /// The request carries no user id: the server takes the account from the verified token alone. The
    /// reply is checked against what was asked (`expectedOwnerId`, `sourceId`) before it is believed.
    public func provisionInstallation(accessToken: String, expectedOwnerId: String, sourceId: String,
                                      platform: CloudProvisioningPlatform = .current,
                                      appVersion: String, currentToken: String?) async throws -> CloudInstallationGrant {
        guard let url = route("installations/provision") else { throw CloudReceiverError.notConfigured }
        let version = appVersion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty, version.count <= 64,
              !version.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else {
            throw CloudReceiverError.malformedResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let apiKey = publishableKey ?? CloudPushSettings.publishableKey
        if !apiKey.isEmpty { request.setValue(apiKey, forHTTPHeaderField: "apikey") }
        if let currentToken, !currentToken.isEmpty {
            request.setValue(currentToken, forHTTPHeaderField: "x-noop-installation-token")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sourceId": sourceId.lowercased(),
            "platform": platform.rawValue,
            "appVersion": version,
        ])
        let (data, status, retryAfter) = try await send(request)
        if status == 401 { throw CloudReceiverError.sessionRejected }
        guard (200..<300).contains(status) else {
            throw CloudReceiverError(code: Self.errorCode(from: data), status: status, retryAfter: retryAfter)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let userId = (object["userId"] as? String)?.lowercased(),
              let echoedSource = (object["sourceId"] as? String)?.lowercased(),
              let tokenId = (object["tokenId"] as? String)?.lowercased(),
              let actionRaw = object["action"] as? String,
              let action = CloudInstallationGrant.Action(rawValue: actionRaw) else {
            throw CloudReceiverError.malformedResponse
        }
        guard userId == expectedOwnerId.lowercased(), echoedSource == sourceId.lowercased() else {
            throw CloudReceiverError.ownershipMismatch
        }
        let token = (object["installationToken"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        if action != .reused, token == nil { throw CloudReceiverError.malformedResponse }
        if let token, !token.hasPrefix("noop_") { throw CloudReceiverError.malformedResponse }
        let expiry = (object["expiresAt"] as? String).flatMap(Self.parseDate)
        return CloudInstallationGrant(userId: userId, sourceId: echoedSource, tokenId: tokenId, action: action,
                                      expiresAt: expiry, installationToken: token)
    }

    // MARK: - Wearable confirmation

    /// Confirm the provisional device for this installation against the strap's real Device Information
    /// serial, so the server links this source to the wearer's canonical `whoop-<serial>` device. Without
    /// it the score readback honestly reports `device_registration_pending`.
    ///
    /// Wire contract: `POST <base>/wearables/confirm`, bearer = the installation credential, body
    /// `{provisionalExternalDeviceId, evidence{method, serial, receiptSha256}}`, 200
    /// `{userId, sourceId, deviceId, state:"confirmed"}`. The reply is accepted only when it names the same
    /// account as `identity`.
    public func confirmWearable(identity: CloudPushIdentity, provisionalExternalDeviceId: String,
                                serial: String) async throws -> String {
        guard let url = route("wearables/confirm") else { throw CloudReceiverError.notConfigured }
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
        request.cachePolicy = .reloadIgnoringLocalCacheData
        CloudReceiverAuth.apply(identity, to: &request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, status, retryAfter) = try await send(request)
        if status == 401 { throw CloudReceiverError.credentialRejected }
        guard status == 200 else {
            throw CloudReceiverError(code: Self.errorCode(from: data), status: status, retryAfter: retryAfter)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["state"] as? String == "confirmed" else { throw CloudReceiverError.malformedResponse }
        guard (object["userId"] as? String)?.lowercased() == identity.ownerId,
              (object["sourceId"] as? String).map({ $0.lowercased() == identity.sourceId }) ?? true else {
            throw CloudReceiverError.ownershipMismatch
        }
        return object["deviceId"] as? String ?? ""
    }

    // MARK: - Capability negotiation

    /// Negotiate the protocol version with the receiver. The reply must name `identity`'s account and
    /// source; anything else is `.ownershipMismatch` and the caller must not proceed.
    public func negotiateCapabilities(identity: CloudPushIdentity) async throws -> CloudCapabilities {
        guard let url = route("") else { throw CloudReceiverError.notConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        CloudReceiverAuth.apply(identity, to: &request)
        request.setValue(CloudReceiverProtocol.acceptVersions, forHTTPHeaderField: "noop-push-accept-version")
        let (data, status, retryAfter) = try await send(request)
        if status == 401 { throw CloudReceiverError.credentialRejected }
        guard status != 406 else { throw CloudReceiverError.unsupportedVersion }
        guard status == 200 else {
            throw CloudReceiverError(code: Self.errorCode(from: data), status: status, retryAfter: retryAfter)
        }
        let capabilities: PushCapabilities
        do { capabilities = try PushCapabilities.parse(data) } catch { throw CloudReceiverError.malformedResponse }
        guard capabilities.userId?.lowercased() == identity.ownerId,
              capabilities.sourceId?.lowercased() == identity.sourceId else {
            throw CloudReceiverError.ownershipMismatch
        }
        return CloudCapabilities(protocolVersion: capabilities.protocolVersion, capabilities: capabilities)
    }

    // MARK: - Plumbing

    private func send(_ request: URLRequest) async throws -> (Data, Int, TimeInterval?) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw CloudReceiverError.transport }
            let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            return (data, http.statusCode, retryAfter)
        } catch let error as CloudReceiverError {
            throw error
        } catch {
            throw CloudReceiverError.transport
        }
    }

    private static func errorCode(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let code = object["code"] as? String, !code.isEmpty else { return nil }
        return code
    }

    private static func parseDate(_ text: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: text) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text)
    }
}

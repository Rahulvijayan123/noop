import Foundation
@testable import Strand

/// Credentials in memory, so tests never touch the Keychain.
final class MemorySecretStore: CloudSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func get(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return values[account]
    }

    func set(_ value: String, account: String) {
        lock.lock(); values[account] = value; lock.unlock()
    }

    func remove(account: String) {
        lock.lock(); values[account] = nil; lock.unlock()
    }

    var accounts: [String] {
        lock.lock(); defer { lock.unlock() }
        return values.keys.sorted()
    }
}

/// A `UserDefaults` that belongs to one test.
func isolatedDefaults(_ name: String = UUID().uuidString) -> UserDefaults {
    let suite = "nara.tests.\(name)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
}

/// The cloud runtime as the account layer sees it, without a journal, session or network.
final class FakeRuntime: CloudRuntimeControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var scope: CloudDataScope?
    private var _started: [CloudPushIdentity] = []
    private var _stops = 0
    private var _handler: (@Sendable (CloudDataScope, Int) -> Void)?
    private var _syncStatus: CloudSyncStatus?

    /// What `syncStatus()` reports while running.
    var reportedSyncStatus: CloudSyncStatus? {
        get { lock.lock(); defer { lock.unlock() }; return _syncStatus }
        set { lock.lock(); _syncStatus = newValue; lock.unlock() }
    }

    func syncStatus() async -> CloudSyncStatus? {
        runningScope != nil ? reportedSyncStatus : nil
    }

    var runningScope: CloudDataScope? {
        lock.lock(); defer { lock.unlock() }
        return scope
    }

    var started: [CloudPushIdentity] {
        lock.lock(); defer { lock.unlock() }
        return _started
    }

    var stopCount: Int {
        lock.lock(); defer { lock.unlock() }
        return _stops
    }

    func start(identity: CloudPushIdentity, deviceId: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let scope, scope != identity.scope { throw CloudPushRuntime.StartError.runningForAnotherAccount }
        if scope == nil { _started.append(identity) }
        scope = identity.scope
    }

    func stop() async {
        markStopped()
    }

    private func markStopped() {
        lock.lock()
        scope = nil
        _stops += 1
        lock.unlock()
    }

    func setCredentialRejectionHandler(_ handler: (@Sendable (CloudDataScope, Int) -> Void)?) {
        lock.lock(); _handler = handler; lock.unlock()
    }

    var rejectionHandler: (@Sendable (CloudDataScope, Int) -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return _handler
    }
}

/// A model of the server's provisioning and wearable-link rules, as far as the client can observe them.
///
/// The Supabase session is modelled by an access token of the form `jwt-for-<user id>`: the server learns
/// WHO is asking from the token alone and never from the request body, exactly as the real route does.
/// What it enforces is what the SQL and Edge suites prove against the real database: a source belongs to one
/// account forever, a presented credential is reused until it nears expiry, a revoked or lost credential is
/// replaced for its own account only, and a strap belongs to the first account that confirms it.
final class FakeProvisioningServer: CloudInstallationProvisioning, @unchecked Sendable {
    struct Call: Equatable {
        let accessToken: String
        let expectedOwnerId: String
        let sourceId: String
        let currentToken: String?
    }

    struct Confirmation: Equatable {
        let scope: CloudDataScope
        let provisionalDeviceId: String
        let serial: String
    }

    private struct Installation {
        var owner: String
        var token: String
        var tokenId: String
        var expiresAt: Date
        var revoked = false
        var retired = false
        var installationRevoked = false
    }

    private let lock = NSLock()
    private let clock: TestClock
    private var installations: [String: Installation] = [:]
    private var strapOwners: [String: String] = [:]
    private var counter = 0
    private var _calls: [Call] = []
    private var _confirmations: [Confirmation] = []

    /// Injected faults, consumed one per request. A nil entry means "behave".
    var provisionFaults: [Error?] = []
    var confirmFaults: [Error?] = []
    /// Make the next success answer for someone else (a misbehaving or spoofed server).
    var answerForOwner: String?

    init(clock: TestClock) { self.clock = clock }

    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }

    var confirmations: [Confirmation] {
        lock.lock(); defer { lock.unlock() }
        return _confirmations
    }

    func installationOwner(of sourceId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return installations[sourceId.lowercased()]?.owner
    }

    func currentToken(of sourceId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return installations[sourceId.lowercased()]?.token
    }

    /// Make the server stop honouring a credential, as if an operator revoked it.
    func revoke(sourceId: String) {
        lock.lock(); installations[sourceId.lowercased()]?.revoked = true; lock.unlock()
    }

    func retire(sourceId: String) {
        lock.lock(); installations[sourceId.lowercased()]?.retired = true; lock.unlock()
    }

    /// Close the installation itself (not just its credential). Every later request for it is refused, however
    /// many times it is asked, until the person registers this phone again under a new source.
    func revokeInstallation(sourceId: String) {
        lock.lock(); installations[sourceId.lowercased()]?.installationRevoked = true; lock.unlock()
    }

    /// Pretend `owner` already holds `sourceId` (so another account asking for it must be refused).
    func claim(sourceId: String, owner: String) {
        lock.lock()
        counter += 1
        installations[sourceId.lowercased()] = Installation(
            owner: owner.lowercased(), token: "noop_claimed\(counter)", tokenId: UUID().uuidString.lowercased(),
            expiresAt: clock.now.addingTimeInterval(365 * 86_400))
        lock.unlock()
    }

    func claimStrap(serial: String, owner: String) {
        lock.lock(); strapOwners[serial] = owner.lowercased(); lock.unlock()
    }

    func provisionInstallation(accessToken: String, expectedOwnerId: String, sourceId: String,
                               platform: CloudProvisioningPlatform, appVersion: String,
                               currentToken: String?) async throws -> CloudInstallationGrant {
        try provision(accessToken: accessToken, expectedOwnerId: expectedOwnerId, sourceId: sourceId,
                      currentToken: currentToken)
    }

    func confirmWearable(identity: CloudPushIdentity, provisionalExternalDeviceId: String,
                         serial: String) async throws -> String {
        try confirm(identity: identity, provisionalDeviceId: provisionalExternalDeviceId, serial: serial)
    }

    private func provision(accessToken: String, expectedOwnerId: String, sourceId: String,
                           currentToken: String?) throws -> CloudInstallationGrant {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(Call(accessToken: accessToken, expectedOwnerId: expectedOwnerId, sourceId: sourceId,
                           currentToken: currentToken))
        if !provisionFaults.isEmpty, let fault = provisionFaults.removeFirst() { throw fault }

        guard accessToken.hasPrefix("jwt-for-") else { throw CloudReceiverError.sessionRejected }
        let caller = String(accessToken.dropFirst("jwt-for-".count)).lowercased()
        let source = sourceId.lowercased()

        counter += 1
        func mint() -> (String, String) { ("noop_minted\(counter)", UUID().uuidString.lowercased()) }
        let expiry = clock.now.addingTimeInterval(365 * 86_400)
        let reportedOwner = answerForOwner ?? caller
        answerForOwner = nil

        if var existing = installations[source] {
            guard existing.owner == caller else { throw CloudReceiverError.installationUnavailable }
            if existing.retired { throw CloudReceiverError.installationRetired }
            if existing.installationRevoked { throw CloudReceiverError.installationRevoked }
            let valid = !existing.revoked && existing.token == currentToken
                && existing.expiresAt.timeIntervalSince(clock.now) > 30 * 86_400
            if valid {
                return CloudInstallationGrant(userId: reportedOwner, sourceId: source, tokenId: existing.tokenId,
                                              action: .reused, expiresAt: existing.expiresAt, installationToken: nil)
            }
            let (token, tokenId) = mint()
            existing.token = token
            existing.tokenId = tokenId
            existing.expiresAt = expiry
            existing.revoked = false
            installations[source] = existing
            return CloudInstallationGrant(userId: reportedOwner, sourceId: source, tokenId: tokenId,
                                          action: .rotated, expiresAt: expiry, installationToken: token)
        }
        let (token, tokenId) = mint()
        installations[source] = Installation(owner: caller, token: token, tokenId: tokenId, expiresAt: expiry)
        return CloudInstallationGrant(userId: reportedOwner, sourceId: source, tokenId: tokenId,
                                      action: .created, expiresAt: expiry, installationToken: token)
    }

    private func confirm(identity: CloudPushIdentity, provisionalDeviceId: String,
                         serial: String) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        _confirmations.append(Confirmation(scope: identity.scope, provisionalDeviceId: provisionalDeviceId,
                                           serial: serial))
        if !confirmFaults.isEmpty, let fault = confirmFaults.removeFirst() { throw fault }
        if let holder = strapOwners[serial], holder != identity.ownerId {
            throw CloudReceiverError.rejected(code: "device_owner_conflict", status: 409)
        }
        strapOwners[serial] = identity.ownerId
        return "whoop-\(serial.lowercased())"
    }
}

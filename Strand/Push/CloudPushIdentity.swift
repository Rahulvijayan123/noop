import Foundation

/// The identity one account uses to talk to the hosted-compute receiver.
///
/// The chain is `Supabase auth.users.id → account-scoped source id → installation credential`, and the
/// three are only ever handled together: a credential is stored under the source it was minted for and is
/// never returned alongside any other source, so a source id can not be re-bound to another account's
/// credential by construction. `ownerId` is the Supabase user id and the only cloud user id there is.
public struct CloudPushIdentity: Equatable, Sendable {
    /// How the server came to trust this installation.
    public enum Provisioning: String, Sendable {
        /// Minted by `POST …/installations/provision` from a verified Supabase session. Needs nothing else.
        case supabaseAuth
        /// Redeemed with a NARA enrollment code. Only honoured by a migration build, and still needs the
        /// legacy fleet header on every request.
        case legacyEnrollment
    }

    public let ownerId: String
    public let sourceId: String
    public let tokenId: String
    /// Installation bearer (`noop_…`). Never logged.
    public let uploadToken: String
    public let provisioning: Provisioning

    public init(ownerId: String, sourceId: String, tokenId: String, uploadToken: String,
                provisioning: Provisioning = .supabaseAuth) {
        self.ownerId = ownerId.lowercased()
        self.sourceId = sourceId.lowercased()
        self.tokenId = tokenId.lowercased()
        self.uploadToken = uploadToken
        self.provisioning = provisioning
    }

    /// The `(owner, source)` pair that names where journaled data belongs.
    public var scope: CloudDataScope { CloudDataScope(ownerId: ownerId, sourceId: sourceId) }
}

/// The pair every journaled record, sealed batch and append cursor is stamped with. Two scopes are the
/// same only when BOTH halves match: the same phone signed into two accounts has two scopes, and the data
/// of one is never visible to, sealed by, or uploaded with the credential of the other.
public struct CloudDataScope: Hashable, Sendable {
    public let ownerId: String
    public let sourceId: String

    public init(ownerId: String, sourceId: String) {
        self.ownerId = ownerId.lowercased()
        self.sourceId = sourceId.lowercased()
    }
}

/// Where the account credentials live. The Keychain in production; in memory under test.
protocol CloudSecretStore: Sendable {
    func get(account: String) -> String?
    func set(_ value: String, account: String)
    func remove(account: String)
}

struct KeychainCloudSecretStore: CloudSecretStore {
    static let service = "com.noopapp.noop.cloudpush"
    func get(account: String) -> String? { CloudKeychain.get(account: account, service: Self.service) }
    func set(_ value: String, account: String) { CloudKeychain.set(value, account: account, service: Self.service) }
    func remove(account: String) { CloudKeychain.remove(account: account, service: Self.service) }
}

/// Persistence for the per-account `CloudPushIdentity`.
///
/// Everything is keyed by the account (and the credential additionally by its source), never by the
/// install, so signing A out and B in on the same phone can neither hand B A's source id or credential nor
/// let B's uploads reach A's journal rows. The *active owner* pointer says whose runtime may run; it is
/// written when a verified session is bound and cleared on sign-out, and nothing but the Auth layer moves it.
public struct CloudPushIdentityStore: @unchecked Sendable {
    let defaults: UserDefaults
    let secrets: CloudSecretStore

    init(defaults: UserDefaults = .standard, secrets: CloudSecretStore = KeychainCloudSecretStore()) {
        self.defaults = defaults
        self.secrets = secrets
    }

    /// The store the app uses.
    public static let shared = CloudPushIdentityStore()

    // MARK: - keys

    private static let activeOwnerKey = "noop.cloud.account.active"
    private static let sourcePrefix = "noop.cloud.account.source."
    private static let tokenIdPrefix = "noop.cloud.account.tokenId."
    private static let tokenExpiryPrefix = "noop.cloud.account.tokenExpiry."
    private static let legacySourceKey = "noop.cloud.sourceId"
    private static let legacyOwnerKey = "noop.cloud.ownerId"
    private static let legacyTokenIdPrefix = "noop.cloud.tokenId."

    private static func tokenAccount(owner: String, source: String) -> String {
        "installationToken.\(owner).\(source)"
    }

    private static func legacyTokenAccount(owner: String) -> String { "uploadToken.\(owner)" }

    private static func normalized(_ value: String) -> String { value.lowercased() }

    // MARK: - active owner

    /// The account whose runtime may run, or nil when nobody is signed in.
    public func currentOwnerId() -> String? {
        defaults.string(forKey: Self.activeOwnerKey).map(Self.normalized)
    }

    /// Mark `ownerId` as the signed-in account. Called only with a verified Supabase user id.
    public func activate(ownerId: String) {
        defaults.set(Self.normalized(ownerId), forKey: Self.activeOwnerKey)
    }

    /// Stop scheduling for the signed-out owner WITHOUT touching their source id or journal rows, so their
    /// pending inputs can resume when they sign back in. Their installation credential is removed: a
    /// signed-out account holds no live upload credential on this phone.
    public func signOutCurrentOwner() {
        guard let owner = currentOwnerId() else { return }
        removeCredential(forOwner: owner)
        defaults.removeObject(forKey: Self.activeOwnerKey)
    }

    // MARK: - source id (per account)

    /// The account's source id, if one has been minted on this install.
    public func existingSourceId(forOwner ownerId: String) -> String? {
        defaults.string(forKey: Self.sourcePrefix + Self.normalized(ownerId)).map(Self.normalized)
    }

    /// The account's source id, minted on first use. It is stable for the life of the install and unique
    /// to the account: there is no install-wide source id.
    ///
    /// The one carry-over is a pre-Auth install: if the account is the owner that enrolled this install
    /// with a code, it keeps the source id that enrollment bound server-side, so the server can upgrade that
    /// installation in place instead of creating a second one. Any other account gets a fresh id.
    @discardableResult
    public func sourceId(forOwner ownerId: String) -> String {
        let owner = Self.normalized(ownerId)
        if let existing = existingSourceId(forOwner: owner) { return existing }
        let fresh: String
        if let legacyOwner = defaults.string(forKey: Self.legacyOwnerKey).map(Self.normalized),
           legacyOwner == owner,
           let legacySource = defaults.string(forKey: Self.legacySourceKey).map(Self.normalized),
           UUID(uuidString: legacySource) != nil {
            fresh = legacySource
        } else {
            fresh = UUID().uuidString.lowercased()
        }
        defaults.set(fresh, forKey: Self.sourcePrefix + owner)
        return fresh
    }

    // MARK: - credential (per account and source)

    /// The installation credential for `ownerId`, together with the source it is bound to.
    public func identity(forOwner ownerId: String) -> CloudPushIdentity? {
        let owner = Self.normalized(ownerId)
        guard let source = existingSourceId(forOwner: owner) else { return nil }
        if let token = secrets.get(account: Self.tokenAccount(owner: owner, source: source)), !token.isEmpty {
            let tokenId = defaults.string(forKey: Self.tokenIdPrefix + owner + "." + source) ?? ""
            return CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: tokenId, uploadToken: token,
                                     provisioning: .supabaseAuth)
        }
        return legacyIdentity(forOwner: owner, source: source)
    }

    /// The pre-Auth enrollment credential, honoured only by a build that explicitly allows it.
    private func legacyIdentity(forOwner owner: String, source: String) -> CloudPushIdentity? {
        guard CloudPushSettings.allowLegacyEnrollment,
              defaults.string(forKey: Self.legacyOwnerKey).map(Self.normalized) == owner,
              defaults.string(forKey: Self.legacySourceKey).map(Self.normalized) == source,
              let token = secrets.get(account: Self.legacyTokenAccount(owner: owner)), !token.isEmpty
        else { return nil }
        let tokenId = defaults.string(forKey: Self.legacyTokenIdPrefix + owner) ?? ""
        return CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: tokenId, uploadToken: token,
                                 provisioning: .legacyEnrollment)
    }

    /// The signed-in account's identity: its source id and credential, or nil until it has been provisioned.
    public func current() -> CloudPushIdentity? {
        guard let owner = currentOwnerId() else { return nil }
        return identity(forOwner: owner)
    }

    /// Persist a freshly provisioned credential for `(owner, source)`. The secret is written before the
    /// token id, and neither moves the active-owner pointer: binding an account is a separate, explicit step.
    public func store(token: String, tokenId: String, expiresAt: Date?, ownerId: String, sourceId: String) {
        let owner = Self.normalized(ownerId)
        let source = Self.normalized(sourceId)
        secrets.set(token, account: Self.tokenAccount(owner: owner, source: source))
        defaults.set(Self.normalized(tokenId), forKey: Self.tokenIdPrefix + owner + "." + source)
        if let expiresAt {
            defaults.set(expiresAt.timeIntervalSince1970, forKey: Self.tokenExpiryPrefix + owner + "." + source)
        } else {
            defaults.removeObject(forKey: Self.tokenExpiryPrefix + owner + "." + source)
        }
    }

    /// When the stored credential stops being valid, if the server said.
    public func credentialExpiry(forOwner ownerId: String) -> Date? {
        let owner = Self.normalized(ownerId)
        guard let source = existingSourceId(forOwner: owner) else { return nil }
        let key = Self.tokenExpiryPrefix + owner + "." + source
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: key))
    }

    /// Delete the credential of one account (the source id and its journal rows stay).
    public func removeCredential(forOwner ownerId: String) {
        let owner = Self.normalized(ownerId)
        if let source = existingSourceId(forOwner: owner) {
            secrets.remove(account: Self.tokenAccount(owner: owner, source: source))
            defaults.removeObject(forKey: Self.tokenIdPrefix + owner + "." + source)
            defaults.removeObject(forKey: Self.tokenExpiryPrefix + owner + "." + source)
        }
        secrets.remove(account: Self.legacyTokenAccount(owner: owner))
        defaults.removeObject(forKey: Self.legacyTokenIdPrefix + owner)
    }

    /// Replace an account's source id after the server reported the old one retired or unavailable. The
    /// previous id (and any rows stamped with it) is abandoned, never re-bound: those rows stay under the
    /// old scope, and only new data carries the new id.
    @discardableResult
    public func rotateSourceId(forOwner ownerId: String) -> String {
        let owner = Self.normalized(ownerId)
        removeCredential(forOwner: owner)
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: Self.sourcePrefix + owner)
        return fresh
    }

    /// Irreversible removal, for an explicit account deletion or an account the server no longer knows.
    public func forget(ownerId: String) {
        let owner = Self.normalized(ownerId)
        removeCredential(forOwner: owner)
        defaults.removeObject(forKey: Self.sourcePrefix + owner)
        if currentOwnerId() == owner { defaults.removeObject(forKey: Self.activeOwnerKey) }
    }

    // MARK: - static facade (call sites that predate the instance API)

    public static func currentOwnerId() -> String? { shared.currentOwnerId() }
    public static func current() -> CloudPushIdentity? { shared.current() }
    public static func identity(forOwner ownerId: String) -> CloudPushIdentity? { shared.identity(forOwner: ownerId) }
    public static func signOutCurrentOwner() { shared.signOutCurrentOwner() }
    public static func forget(ownerId: String) { shared.forget(ownerId: ownerId) }
}

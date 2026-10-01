import Foundation

/// Owner-scoped identity for the hosted-compute path.
///
/// Every journaled record is stamped with the owner that was signed in when it arrived, so a
/// sign-out or account switch can never retag old captures to the next user. The prior owner's
/// pending inputs stay isolated under their own owner id and resume only with that owner's
/// credentials. `sourceId` is the stable per-install UUID the receiver binds enrollment to.
public struct CloudPushIdentity: Equatable, Sendable {
    public let ownerId: String
    public let sourceId: String
    public let tokenId: String
    /// Installation bearer (`noop_…`). Never logged.
    public let uploadToken: String

    public init(ownerId: String, sourceId: String, tokenId: String, uploadToken: String) {
        self.ownerId = ownerId.lowercased()
        self.sourceId = sourceId.lowercased()
        self.tokenId = tokenId.lowercased()
        self.uploadToken = uploadToken
    }
}

/// Persistence for `CloudPushIdentity` plus the per-install source id and per-strap device ids.
public enum CloudPushIdentityStore {
    private static let service = "com.noopapp.noop.cloudpush"
    private static let sourceIdKey = "noop.cloud.sourceId"
    private static let ownerIdKey = "noop.cloud.ownerId"
    private static let tokenIdKey = "noop.cloud.tokenId"

    // MARK: - Source id (stable per install)

    /// The receiver requires a lowercase UUID `sourceId`. It is minted once and never rotated, so a
    /// re-enroll retry stays idempotent for the same source.
    public static func sourceId() -> String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: sourceIdKey), !existing.isEmpty {
            return existing.lowercased()
        }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: sourceIdKey)
        return fresh
    }

    // MARK: - Owner-scoped credential

    public static func currentOwnerId() -> String? {
        UserDefaults.standard.string(forKey: ownerIdKey)?.lowercased()
    }

    public static func identity(forOwner ownerId: String) -> CloudPushIdentity? {
        let owner = ownerId.lowercased()
        guard let source = UserDefaults.standard.string(forKey: sourceIdKey),
              let token = CloudKeychain.get(account: "uploadToken.\(owner)", service: service)
        else { return nil }
        let tokenId = UserDefaults.standard.string(forKey: "\(tokenIdKey).\(owner)") ?? ""
        return CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: tokenId, uploadToken: token)
    }

    public static func current() -> CloudPushIdentity? {
        guard let owner = currentOwnerId() else { return nil }
        return identity(forOwner: owner)
    }

    /// Commits a redeemed enrollment. The token is written before the owner pointer flips, so a
    /// crash mid-commit cannot leave the active owner without a usable credential.
    public static func adopt(_ identity: CloudPushIdentity) {
        CloudKeychain.set(identity.uploadToken, account: "uploadToken.\(identity.ownerId)", service: service)
        UserDefaults.standard.set(identity.tokenId, forKey: "\(tokenIdKey).\(identity.ownerId)")
        UserDefaults.standard.set(identity.ownerId, forKey: ownerIdKey)
    }

    /// Stops scheduling for the signed-out owner WITHOUT deleting their credential or journal, so
    /// their pending inputs can resume when they sign back in.
    public static func signOutCurrentOwner() {
        UserDefaults.standard.removeObject(forKey: ownerIdKey)
    }

    /// Irreversible removal, for an explicit account deletion.
    public static func forget(ownerId: String) {
        let owner = ownerId.lowercased()
        CloudKeychain.remove(account: "uploadToken.\(owner)", service: service)
        UserDefaults.standard.removeObject(forKey: "\(tokenIdKey).\(owner)")
        if currentOwnerId() == owner { UserDefaults.standard.removeObject(forKey: ownerIdKey) }
    }

    // MARK: - Device id

    /// A server-registered device UUID per physical strap. The local CoreBluetooth identifier is
    /// metadata only and is never used as a global user identity.
    public static func deviceId(forPeripheralKey peripheralKey: String) -> String {
        let key = "noop.cloud.deviceId.\(peripheralKey)"
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: key), !existing.isEmpty { return existing.lowercased() }
        let fresh = UUID().uuidString.lowercased()
        defaults.set(fresh, forKey: key)
        return fresh
    }
}

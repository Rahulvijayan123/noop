import Foundation

/// Which account the phone's on-device history belongs to.
///
/// The decoded store the dashboards read is a single, device-wide cache; it is not partitioned by
/// account. What *is* partitioned is everything that leaves the phone: the journal, the credentials and
/// the server rows. This record is the bridge between the two. The first verified account to sign in
/// claims the on-device history, and only that account's cloud path may replay it:
///
///  - the history seeders, which re-upload what the store already holds, run for the owner only, so
///    signing out A and signing in B can never upload A's banked history as B's;
///  - server results are written back into the shared store for the owner only, so B's numbers can not
///    overwrite A's on-device days.
///
/// Live capture is not gated: a record is stamped with whoever is signed in when it arrives.
public enum CloudLocalDataBinding {
    static let ownerKey = "noop.cloud.localDataOwner"

    /// The account that owns the on-device history, or nil until someone has claimed it.
    public static func owner(defaults: UserDefaults = .standard) -> String? {
        defaults.string(forKey: ownerKey).map { $0.lowercased() }
    }

    /// Claim the on-device history for `ownerId` if nobody has. Returns whether `ownerId` owns it afterwards.
    @discardableResult
    public static func claimIfUnclaimed(by ownerId: String, defaults: UserDefaults = .standard) -> Bool {
        let candidate = ownerId.lowercased()
        if let existing = owner(defaults: defaults) { return existing == candidate }
        defaults.set(candidate, forKey: ownerKey)
        return true
    }

    public static func isOwner(_ ownerId: String, defaults: UserDefaults = .standard) -> Bool {
        owner(defaults: defaults) == ownerId.lowercased()
    }

    /// Whether the account signed in on this phone right now is the one the on-device history belongs to.
    /// False when nobody is signed in.
    public static func signedInAccountOwnsLocalData(store: CloudPushIdentityStore = .shared,
                                                    defaults: UserDefaults = .standard) -> Bool {
        guard let signedIn = store.currentOwnerId() else { return false }
        return isOwner(signedIn, defaults: defaults)
    }

    /// Give up the claim. Only for an explicit erase of the on-device history.
    public static func release(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: ownerKey)
    }
}

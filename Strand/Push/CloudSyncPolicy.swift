import Foundation

/// What the server says about keeping a signed-in account synced.
///
/// The receiver sends it as `syncPolicy: {required, staleAfterHours}` in the provisioning reply, in the push
/// capabilities and in coach `GET status`. `required: true` means a signed-in account always uploads: there is no
/// switch to turn that off, and an account that stops uploading is flagged as stale after `staleAfterHours`.
/// The phone keeps the latest one it saw per account; before it has seen one it behaves as `required`, so a
/// server that never said anything (or a reply that was lost) can never turn sync off.
public struct CloudSyncPolicy: Codable, Equatable, Sendable {
    public var required: Bool
    public var staleAfterHours: Int

    public init(required: Bool, staleAfterHours: Int) {
        self.required = required
        self.staleAfterHours = staleAfterHours
    }

    /// What applies until the server says otherwise.
    public static let assumed = CloudSyncPolicy(required: true, staleAfterHours: 24)

    /// The `syncPolicy` object of a reply, or nil when there is none or it is malformed. Missing fields fall back
    /// to the assumed policy's, so only an explicit `required: false` relaxes anything.
    static func parse(_ value: Any?) -> CloudSyncPolicy? {
        guard let object = value as? [String: Any] else { return nil }
        let required: Bool
        switch object["required"] {
        case let flag as Bool: required = flag
        case let number as NSNumber: required = number.intValue != 0
        default: required = true
        }
        let hours = (object["staleAfterHours"] as? NSNumber)?.intValue ?? assumed.staleAfterHours
        return CloudSyncPolicy(required: required, staleAfterHours: (1...720).contains(hours) ? hours : assumed.staleAfterHours)
    }

    /// The policy carried at the top level of a JSON reply body.
    static func parse(replyBody data: Data) -> CloudSyncPolicy? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return parse(object["syncPolicy"])
    }
}

/// The server's view of whether an account is still uploading (coach `GET status` → `sync`).
public struct CloudSyncHealth: Equatable, Sendable {
    public var required: Bool
    /// The newest upload the server accepted for the account, or nil when it has none.
    public var lastUploadAt: Date?
    /// True when nothing reached the server within the policy's `staleAfterHours`.
    public var stale: Bool

    public init(required: Bool, lastUploadAt: Date?, stale: Bool) {
        self.required = required
        self.lastUploadAt = lastUploadAt
        self.stale = stale
    }

    static func parse(_ value: Any?) -> CloudSyncHealth? {
        guard let object = value as? [String: Any] else { return nil }
        let required = (object["required"] as? Bool) ?? true
        let stale = (object["stale"] as? Bool) ?? false
        let last = (object["lastUploadAt"] as? String).flatMap(Self.parseDate)
        return CloudSyncHealth(required: required, lastUploadAt: last, stale: stale)
    }

    private static func parseDate(_ text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: text) { return date }
        return ISO8601DateFormatter().date(from: text)
    }
}

/// The policy and health one coach `GET status` reply carried.
public struct CloudSyncStatus: Equatable, Sendable {
    public var policy: CloudSyncPolicy?
    public var health: CloudSyncHealth?

    public init(policy: CloudSyncPolicy?, health: CloudSyncHealth?) {
        self.policy = policy
        self.health = health
    }
}

/// The latest `CloudSyncPolicy` per account, kept in the app's preferences.
///
/// Keyed by the account, never by the install: one account's relaxed policy says nothing about another's.
public struct CloudSyncPolicyStore: @unchecked Sendable {
    let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public static let shared = CloudSyncPolicyStore()

    private static func key(_ ownerId: String) -> String { "noop.cloud.syncPolicy.v1.\(ownerId.lowercased())" }

    /// The policy the server last sent for `ownerId`, or `assumed` (required) when it has sent none.
    public func policy(forOwner ownerId: String) -> CloudSyncPolicy {
        guard let data = defaults.data(forKey: Self.key(ownerId)),
              let stored = try? JSONDecoder().decode(CloudSyncPolicy.self, from: data) else { return .assumed }
        return stored
    }

    public func record(_ policy: CloudSyncPolicy, forOwner ownerId: String) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: Self.key(ownerId))
    }

    /// Record a reply body's `syncPolicy`, if it carries one.
    public func record(replyBody data: Data, forOwner ownerId: String) {
        guard let policy = CloudSyncPolicy.parse(replyBody: data) else { return }
        record(policy, forOwner: ownerId)
    }
}

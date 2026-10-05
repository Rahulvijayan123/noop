import Foundation
import WhoopStore

/// Which device id the cloud path files a strap's data under, and reads its server results for.
///
/// The server keeps ONE canonical device per physical strap and account, `whoop-<serial>`. An installation
/// whose local registry has not adopted the serial files its rows under a throwaway
/// `installation:<source>:my-whoop` device instead, and the server refuses to merge that device into the
/// canonical one once it holds history (the "retained legacy identity" rule). A reinstall, a second phone or
/// an account recovery therefore started a fresh, near-empty history for a strap whose earlier days sat under
/// another device id, and the app only ever read its own: yesterday and the days before it were stored,
/// scored and published, but under a device this installation never asked for.
///
/// The local registry cannot be the fix. The legacy `my-whoop` seed is deliberately excluded from serial
/// adoption (`WhoopSerialIdentity.mayAdopt`) because ~47 code paths still read that literal id, and migrating
/// the rows under it would split the local history. So the translation happens at the cloud boundary only:
/// the local store keeps its ids, the upload and the readback speak the strap's own.
public enum CloudDeviceIdentity {

    /// The seeded single-strap id. The only local id this translation applies to: a `whoop-<…>` id already
    /// is (or adopts) the strap's own id through the registry, and every other source is not a WHOOP.
    public static let legacySeedId = "my-whoop"

    /// The id the cloud path uses for `localId`, given the strap serial read from that device (if any).
    ///
    /// Pure. A serial `WhoopSerialIdentity` refuses (blank, truncated, prose) never produces an id, so a bad
    /// read can only leave the strap on the id it already had.
    public static func cloudId(localId: String, serial: String?) -> String {
        guard localId.lowercased() == legacySeedId,
              let canonical = WhoopSerialIdentity.adoptedId(serial: serial) else { return localId }
        return canonical
    }

    /// The serial in the form it is stored and compared in, or nil when it cannot identify a strap.
    public static func normalizedSerial(_ serial: String?) -> String? {
        guard WhoopSerialIdentity.adoptedId(serial: serial) != nil else { return nil }
        return serial?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// Read candidates for a device's server results, best first, without duplicates.
    ///
    /// The strap's own device leads. The local id follows so an install whose canonical device has no
    /// results yet (the first minutes after the serial is learned, before anything was uploaded under it)
    /// keeps showing what it had instead of going blank.
    public static func readCandidates(localId: String, serial: String?) -> [String] {
        let primary = cloudId(localId: localId, serial: serial)
        return primary == localId ? [localId] : [primary, localId]
    }
}

/// The strap serial each local device id has been read to carry, kept across launches.
///
/// The serial arrives over BLE only after a connection (the DIS read, or a WHOOP 4.0's hello), but uploads
/// and the first server read happen before the strap reconnects. Remembering it is what lets a relaunch
/// speak the strap's id from the first record instead of re-splitting its history every cold start.
///
/// Thread-safe: capture runs on the BLE and backfill actors, and consults this once per record.
public final class CloudStrapSerialStore: @unchecked Sendable {

    public enum Change: Equatable {
        /// Nothing new: the same serial, or one that cannot identify a strap.
        case unchanged
        /// First serial this local id has carried.
        case learned
        /// A different strap now answers to this local id (the old one was swapped out).
        case replaced(previous: String)
    }

    public static let shared = CloudStrapSerialStore()

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var cache: [String: String?] = [:]

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func serialKey(_ localId: String) -> String {
        "noop.cloud.strapSerial.v1.\(localId.lowercased())"
    }

    static func replacedKey(_ localId: String) -> String {
        "noop.cloud.strapSerialReplaced.v1.\(localId.lowercased())"
    }

    public func serial(forLocalId localId: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return storedSerial(localId)
    }

    /// The id the cloud path uses for `localId` right now.
    public func cloudId(forLocalId localId: String) -> String {
        CloudDeviceIdentity.cloudId(localId: localId, serial: serial(forLocalId: localId))
    }

    public func readCandidates(forLocalId localId: String) -> [String] {
        CloudDeviceIdentity.readCandidates(localId: localId, serial: serial(forLocalId: localId))
    }

    /// True once a different strap has replaced the one first seen under this local id. The rows banked
    /// locally before that belong to the earlier strap, so they must never be replayed under the new one's
    /// cloud device.
    public func hasReplacedStrap(forLocalId localId: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return defaults.bool(forKey: Self.replacedKey(localId))
    }

    @discardableResult
    public func record(serial rawSerial: String, forLocalId localId: String) -> Change {
        guard let serial = CloudDeviceIdentity.normalizedSerial(rawSerial) else { return .unchanged }
        lock.lock(); defer { lock.unlock() }
        let previous = storedSerial(localId)
        if previous == serial { return .unchanged }
        defaults.set(serial, forKey: Self.serialKey(localId))
        cache[localId.lowercased()] = .some(serial)
        guard let previous else { return .learned }
        defaults.set(true, forKey: Self.replacedKey(localId))
        return .replaced(previous: previous)
    }

    /// Drop everything remembered for `localId` (used when the strap is removed from the phone).
    public func forget(localId: String) {
        lock.lock(); defer { lock.unlock() }
        defaults.removeObject(forKey: Self.serialKey(localId))
        defaults.removeObject(forKey: Self.replacedKey(localId))
        cache[localId.lowercased()] = .some(nil)
    }

    private func storedSerial(_ localId: String) -> String? {
        let key = localId.lowercased()
        if let cached = cache[key] { return cached }
        let value = defaults.string(forKey: Self.serialKey(localId))
            .flatMap { CloudDeviceIdentity.normalizedSerial($0) }
        cache[key] = .some(value)
        return value
    }
}

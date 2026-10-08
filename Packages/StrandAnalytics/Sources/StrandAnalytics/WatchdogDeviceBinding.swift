import Foundation
import WhoopProtocol

/// Which strap the Watchdog reads, what family it is, and which key its persisted state lives under.
///
/// The service used to read every stream with `AppModel.deviceId`, the constant "my-whoop" (the canonical
/// import id), and keyed its carry by it. A re-added or serial-adopted strap writes under its own registry id,
/// so the Watchdog silently scored the canonical history instead of the strap on the wrist.
public enum WatchdogDeviceBinding {
    /// The canonical import id every pre-binding carry was persisted under.
    public static let legacyCarryId = "my-whoop"

    /// The key persisted state lives under: the active strap's registry id (stable per physical strap once
    /// its serial identity is adopted), or the legacy id when none is known yet.
    public static func stateKey(activeDeviceId: String) -> String {
        let trimmed = activeDeviceId.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? legacyCarryId : trimmed
    }

    /// Where to copy persisted Watchdog state from when binding `target`, or nil to load `target` as is.
    ///
    /// 1. `target` already holds state: use it.
    /// 2. The previously bound id is gone from the registry (a serial-identity adoption MOVED its rows to
    ///    `target`, same physical strap): carry its state over.
    /// 3. Once per install, the legacy "my-whoop" state (every carry before this binding existed) moves to the
    ///    first non-legacy id bound.
    public static func migrationSource(target: String, previous: String?,
                                       targetHasState: Bool, previousHasState: Bool,
                                       previousStillRegistered: Bool,
                                       legacyHasState: Bool, legacyAlreadyMigrated: Bool) -> String? {
        if targetHasState { return nil }
        if let previous, !previous.isEmpty, previous != target, previousHasState, !previousStillRegistered {
            return previous
        }
        if target != legacyCarryId, legacyHasState, !legacyAlreadyMigrated { return legacyCarryId }
        return nil
    }

    /// The strap family that wrote `deviceId`'s rows, from positive evidence only; nil = unknown.
    ///
    /// v18 history records are emitted only by a 5.0/MG, so they win over a registry label (a 5/MG labelled
    /// "WHOOP 4.0" exists in the field). Then the registry's confirmed model. Then the R-R transport labels the
    /// rows carry (5/6/7 are WHOOP 5 transports, 8/9/10 WHOOP 4). The legacy "WHOOP" label, an unknown model,
    /// a non-WHOOP brand and no evidence all return nil: the family is NOT guessed.
    public static func whoopFamily(registryModel: String?, registryBrand: String?, holdsV18: Bool,
                                   rrChannels: Set<Int>) -> DeviceFamily? {
        if isNonWhoop(brand: registryBrand) { return nil }
        if holdsV18 { return .whoop5 }
        if let confirmed = DeviceFamily.confirmedRegistryFamily(model: registryModel, brand: registryBrand) {
            return confirmed
        }
        let w5: Set<Int> = [RRSourceChannel.whoop5Historical.rawValue, RRSourceChannel.whoop5Realtime.rawValue,
                            RRSourceChannel.whoop5Standard.rawValue]
        let w4: Set<Int> = [RRSourceChannel.whoop4Historical.rawValue, RRSourceChannel.whoop4Realtime.rawValue,
                            RRSourceChannel.whoop4Standard.rawValue]
        let hasW5 = !rrChannels.isDisjoint(with: w5)
        let hasW4 = !rrChannels.isDisjoint(with: w4)
        if hasW5 && !hasW4 { return .whoop5 }
        if hasW4 && !hasW5 { return .whoop4 }
        return nil
    }

    /// The raw→°C branch for this id's skin-temperature rows, or nil when it cannot be known (leave the
    /// temperature UNKNOWN). A positively non-WHOOP device already stores a centi-degree / °C-scaled value and
    /// shares the non-4.0 branch (`DeviceFamily.forRegistryDevice` callers coalesce it the same way).
    public static func temperatureScale(whoopFamily: DeviceFamily?, registryBrand: String?) -> DeviceFamily? {
        if let whoopFamily { return whoopFamily }
        return isNonWhoop(brand: registryBrand) ? .whoop5 : nil
    }

    static func isNonWhoop(brand: String?) -> Bool {
        guard let brand, !brand.isEmpty else { return false }
        return brand.caseInsensitiveCompare("WHOOP") != .orderedSame
    }
}

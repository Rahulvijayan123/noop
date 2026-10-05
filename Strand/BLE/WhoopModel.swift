import CoreBluetooth
import WhoopProtocol

/// Which WHOOP the user is pairing. WHOOP 4.0 support was retired: this app connects to WHOOP 5.0/MG straps
/// (and, through their own paths, Oura rings), so there is exactly one WHOOP model. The enum stays, rather
/// than being deleted, because the scan, the pairing screens and `persisted` are written against it, and
/// because a value saved before the retirement ("WHOOP 4.0") has to resolve to something: it resolves to the
/// one supported model (`resolve`, `migrateLegacySelection`). A saved 4.0 choice used to make a 5.0/MG install
/// register its strap as "WHOOP 4.0", which then sent that strap's data down the 4.0 conversions.
public enum WhoopModel: String, CaseIterable, Identifiable, Hashable {
    case whoop5mg = "WHOOP 5.0 / MG"

    public var id: String { rawValue }
    public var displayName: String { rawValue }

    /// UserDefaults key the pickers and `persisted` share (`@AppStorage("selectedWhoopModel")`).
    public static let storageKey = "selectedWhoopModel"

    /// The WHOOP family to try when a scan for this model finds nothing. With one supported family there is
    /// nowhere to rotate to, so it is this model again, and `BLEManager.startScan` does not schedule a rotation
    /// onto itself.
    var fallbackScanModel: WhoopModel { self }

    /// The protocol-layer device family this model maps to — drives framing (CRC16), characteristic UUIDs,
    /// and the CLIENT_HELLO handshake.
    public var deviceFamily: DeviceFamily { .whoop5 }

    /// A stored model string → the model. Anything that is not a current model, including the retired
    /// "WHOOP 4.0" and a missing value, is the one supported model.
    public static func resolve(_ raw: String?) -> WhoopModel {
        raw.flatMap(WhoopModel.init(rawValue:)) ?? .whoop5mg
    }

    /// The model the user last chose, read from the same key the pickers write. Used as the default for scans
    /// the user didn't directly trigger — BLE state restoration, power-on reconnect.
    public static var persisted: WhoopModel {
        resolve(UserDefaults.standard.string(forKey: storageKey))
    }

    /// Rewrite a selection saved before WHOOP 4.0 was retired ("WHOOP 4.0") to the supported model, so nothing
    /// that reads the raw string sees the old value. Idempotent; a no-op on a fresh install. Run from app
    /// `init()`, before any `@AppStorage` reads the key. Returns whether it changed anything.
    @discardableResult
    public static func migrateLegacySelection(defaults: UserDefaults = .standard) -> Bool {
        guard let saved = defaults.string(forKey: storageKey), WhoopModel(rawValue: saved) == nil else { return false }
        defaults.set(WhoopModel.whoop5mg.rawValue, forKey: storageKey)
        return true
    }

    /// The BLE service to scan for, and to discover after connecting, for this model.
    /// These mirror `BLEManager.whoop5Service` (kept inline here so the enum stays nonisolated —
    /// `BLEManager` is `@MainActor`). CBUUID compares by value.
    public var scanService: CBUUID { CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a") }
}

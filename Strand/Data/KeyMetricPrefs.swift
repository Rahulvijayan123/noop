import Foundation
import SwiftUI

// MARK: - Editable Key-Metrics layout (#251)
//
// The Today screen's "Key Metrics" grid was a fixed list of ten tiles in one order. This lets the user
// choose WHICH tiles show and in WHAT order, with the default being the original order so nothing changes
// for anyone who never opens the editor. Persistence is display-only — no metric is computed or stored
// differently; this just decides which of the already-computed tiles render and in what sequence.
//
// Stored as a single comma-joined string of metric keys in @AppStorage (UserDefaults), the same
// mechanism every other macOS NOOP preference uses. The Android side mirrors this exactly in
// KeyMetricPrefs.kt (SharedPreferences "today.keyMetrics"). Unknown keys are dropped on read and any
// known key missing from the saved list is appended (disabled) so a future tile addition can't be lost.

/// One of the Today screen's Key-Metric tiles. The rawValue is the stable persisted identifier — keep it
/// byte-identical to the Android `KeyMetric` enum so a backup/restore reads the same layout on either OS.
enum KeyMetric: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest
    case hrv
    case restingHr
    case bloodOxygen
    case respiratory
    case steps
    case weight
    case calories
    /// Added 2026-08-24 (queue 11c follow-up): Skin Temp was already a "Your Cards" (`DashboardCard`)
    /// option, but was never offered as a Key Metrics tile. It began life outside `defaultOrder`, which
    /// also kept it out of the layout editor (the editor's universe IS `defaultOrder`), so nobody could
    /// switch it on. It is now a default tile; `migrateSkinTempAndBloodOxygenShown` adds it (and Blood
    /// Oxygen) once to layouts saved before this.
    case skinTemp

    var id: String { rawValue }

    /// The tile's display label: the same name on the Today tile, in the editor and (for the scores) on the
    /// detail page. Sentence case.
    var title: String {
        switch self {
        case .charge:      return String(localized: "Charge")
        case .effort:      return String(localized: "Effort")
        case .rest:        return String(localized: "Rest")
        case .hrv:         return "HRV"
        case .restingHr:   return String(localized: "Resting HR")
        case .bloodOxygen: return String(localized: "Blood oxygen")
        case .respiratory: return String(localized: "Respiratory rate")
        case .steps:       return String(localized: "Steps")
        case .weight:      return String(localized: "Weight")
        case .calories:    return String(localized: "Calories")
        // Same short label the sibling "Your Cards" tile (`DashboardCard.skinTemp`) already uses —
        // reuses its translation key rather than adding a new "Skin Temperature" one for this tile.
        case .skinTemp:    return String(localized: "Skin temp")
        }
    }

    /// Every tile in its canonical order: the editor's universe (a case outside it could never be switched
    /// on), and the order the hidden tiles are listed in.
    static let defaultOrder: [KeyMetric] = [
        .charge, .effort, .rest, .hrv, .restingHr,
        .bloodOxygen, .skinTemp, .respiratory, .steps, .weight, .calories,
    ]

    /// The tiles a fresh install shows (and "Reset layout" restores): eight, so the grid is four even rows.
    /// Rest is already the third hero ring above the grid, and Blood oxygen and Weight are one switch away
    /// in the editor. Display-only: nothing is computed differently for a hidden tile. The Android twin
    /// (`KeyMetric.DEFAULT_ENABLED`) should match this list when it adopts it.
    static let defaultEnabled: [KeyMetric] = [
        .charge, .effort, .hrv, .restingHr, .respiratory, .skinTemp, .steps, .calories,
    ]
}

/// Display-only persistence for the Key-Metrics layout. Holds an ORDERED list of the enabled tiles; a
/// tile not in the list is hidden. Mirrors the macOS @AppStorage("today.keyMetrics") + Android side.
enum KeyMetricPrefs {
    /// UserDefaults key — a comma-joined list of `KeyMetric` rawValues in display order.
    static let layoutKey = "today.keyMetrics"

    /// Set once `migrateSkinTempAndBloodOxygenShown` has run, so a user who later hides either tile keeps it hidden.
    static let skinTempBloodOxygenMigrationKey = "today.keyMetrics.skinTempBloodOxygenShown.v1"

    /// The layout string a saved layout becomes when Blood Oxygen and Skin Temp are added to it, or nil when
    /// nothing changes: no saved layout (a blank one decodes to `defaultEnabled`, the fresh-install set) or a
    /// layout that already shows both. The missing tiles go on the END so nothing the user arranged moves.
    static func layoutAddingBloodOxygenAndSkinTemp(savedLayout raw: String) -> String? {
        guard !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        var enabled = decodeEnabled(raw)
        let missing = [KeyMetric.bloodOxygen, .skinTemp].filter { !enabled.contains($0) }
        guard !missing.isEmpty else { return nil }
        enabled.append(contentsOf: missing)
        return encode(enabled)
    }

    /// One-time: a layout saved before Skin Temp joined `defaultOrder` never offered it, and Blood Oxygen
    /// may have been dropped from it, so neither tile would ever appear for that user. Adds whichever is
    /// missing, once; after that the layout editor owns the choice. Idempotent. Run from app `init()`, before
    /// any `@AppStorage` reads the layout (the `PuffinExperiment` migrations' pattern). Returns whether the
    /// saved layout changed.
    @discardableResult
    static func migrateSkinTempAndBloodOxygenShown(defaults: UserDefaults = .standard) -> Bool {
        guard !defaults.bool(forKey: skinTempBloodOxygenMigrationKey) else { return false }
        defer { defaults.set(true, forKey: skinTempBloodOxygenMigrationKey) }
        guard let migrated = layoutAddingBloodOxygenAndSkinTemp(savedLayout: defaults.string(forKey: layoutKey) ?? "")
        else { return false }
        defaults.set(migrated, forKey: layoutKey)
        return true
    }

    /// Encode an ordered list of enabled tiles into the stored comma-joined string.
    static func encode(_ metrics: [KeyMetric]) -> String {
        metrics.map(\.rawValue).joined(separator: ",")
    }

    /// Decode the stored string into an ordered list of enabled tiles. An empty/unset string yields
    /// `KeyMetric.defaultEnabled` (what a fresh install shows). Unknown tokens are ignored; this returns
    /// ONLY the enabled tiles in their saved order — the editor pairs it with the disabled remainder.
    static func decodeEnabled(_ raw: String) -> [KeyMetric] {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return KeyMetric.defaultEnabled }
        var seen = Set<KeyMetric>()
        var result: [KeyMetric] = []
        for token in trimmed.split(separator: ",") {
            // #1518: trim EACH token, not just the whole string. `KeyMetric(rawValue:)` matches exactly, so
            // "charge, effort" dropped `effort` on the space alone. Kotlin's twin already does this
            // (`KeyMetric.fromRaw(token.trim())`), as does `DashboardCards.decodeEnabled`, so Swift was the
            // only decoder that could lose a tile the user had enabled.
            //
            // Latent rather than live: `encode` joins rawValues with no spaces, and this key is not in the
            // `.noopbak` whitelist, so nothing in the app writes a spaced value today. It is fixed because
            // a decoder that silently drops what it cannot parse should not also be picky about a space —
            // the capabilities decoder in this same change was exactly that, and there it WAS reachable.
            let raw = token.trimmingCharacters(in: .whitespaces)
            if let m = KeyMetric(rawValue: raw), seen.insert(m).inserted {
                result.append(m)
            }
        }
        return result
    }
}

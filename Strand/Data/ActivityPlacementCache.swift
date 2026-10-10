import Foundation
import StrandAnalytics

/// The wearer's declared strap placements as the activity decoder reads them (hsmm-2.0, `ActivityWearPlacement`).
///
/// The decoder config is built synchronously and off the main actor, so the placements live here rather than being
/// read from the registry database on every day decode. `Repository.refreshActivityPlacements()` reloads them from
/// `PlacementStore` at launch, after a sync and after the wearer changes placement; the last copy is kept in
/// UserDefaults so a cold launch decodes with the placement it decoded with before (no wrist-reading flash, no
/// needless re-derive). A placement change changes the config's `cacheTag`, so stored days re-derive.
final class ActivityPlacementCache: @unchecked Sendable {
    static let shared = ActivityPlacementCache()

    private static let defaultsKey = "activityPlacementSpans.v1"
    private let lock = NSLock()
    private let defaults: UserDefaults
    /// Spans by device id ("" = user-level declarations).
    private var byDevice: [String: [ActivityPlacementSpan]]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
           let stored = try? JSONDecoder().decode([String: [ActivityPlacementSpan]].self, from: data) {
            byDevice = stored
        } else {
            byDevice = [:]
        }
    }

    /// The spans the decoder reads for `deviceId`: the strap's own declarations, or the user-level ones when the strap
    /// has none.
    func spans(deviceId: String) -> [ActivityPlacementSpan] {
        lock.lock(); defer { lock.unlock() }
        let own = byDevice[deviceId] ?? []
        return own.isEmpty ? (byDevice[""] ?? []) : own
    }

    /// Replace the spans for `deviceId` (nil = user-level). Returns true when they changed.
    @discardableResult
    func set(_ intervals: [PlacementInterval], deviceId: String?) -> Bool {
        let spans = intervals.map {
            ActivityPlacementSpan(start: Int($0.effectiveStart.timeIntervalSince1970),
                                  end: $0.effectiveEnd.map { Int($0.timeIntervalSince1970) },
                                  placement: ActivityWearPlacement(declared: $0.placement.rawValue))
        }
        lock.lock(); defer { lock.unlock() }
        let key = deviceId ?? ""
        guard byDevice[key] != spans else { return false }
        byDevice[key] = spans
        if let data = try? JSONEncoder().encode(byDevice) { defaults.set(data, forKey: Self.defaultsKey) }
        return true
    }
}

extension Repository {
    /// Reload the declared placements for this strap (and the user-level ones) into `ActivityPlacementCache`.
    /// Returns true when they changed, so the caller can re-derive the activity pages.
    @discardableResult
    func refreshActivityPlacements() async -> Bool {
        guard let store = await storeHandle(), let placements = try? PlacementStore(dbQueue: store.registryWriter) else {
            return false
        }
        let device = (try? placements.intervals(deviceId: deviceId)) ?? []
        let user = (try? placements.intervals(deviceId: nil)) ?? []
        let a = ActivityPlacementCache.shared.set(device, deviceId: deviceId)
        let b = ActivityPlacementCache.shared.set(user, deviceId: nil)
        return a || b
    }
}

import Foundation
import WhoopStore
import StrandAnalytics

/// Reads and probes for the persisted activity context (the `activityContextInterval` / `activityContextDay`
/// tables), across the same device ids the raw streams are read under.
extension Repository {

    /// Which device a day's context is written under, and how far the day's heart rate reaches.
    ///
    /// The first id (active strap, then other registered WHOOPs, then the canonical history) that holds heart
    /// rate inside the range owns the day, so a day is described once however many ids carry streams for it.
    /// `newestHeartRateTs` is the newest second across all of them, which is what the day's decode would read.
    struct ActivityContextOwner: Equatable {
        let deviceId: String
        let newestHeartRateTs: Int
    }

    func activityContextOwner(store: WhoopStore, ids: [String], from: Int, to: Int) async -> ActivityContextOwner? {
        var owner: String?
        var newest = Int.min
        for id in ids {
            guard let ts = try? await store.newestHeartRateTs(deviceId: id, from: from, to: to) else { continue }
            owner = owner ?? id
            newest = max(newest, ts)
        }
        return owner.map { ActivityContextOwner(deviceId: $0, newestHeartRateTs: newest) }
    }

    /// Ledger rows for the local days holding `[from, to)`, per device, keyed by `dayStart`.
    func activityContextLedgers(store: WhoopStore, ids: [String], days: [ActivityContextMaterialization.Day])
        async -> [String: [Int: ActivityContextDayRow]] {
        guard let first = days.map(\.key).min(), let last = days.map(\.key).max() else { return [:] }
        var out: [String: [Int: ActivityContextDayRow]] = [:]
        for id in ids {
            let rows = (try? await store.activityContextDays(deviceId: id, from: first, to: last)) ?? []
            out[id] = Dictionary(rows.map { ($0.dayStart, $0) }, uniquingKeysWith: { _, newer in newer })
        }
        return out
    }

    /// The saved activity context overlapping `[from, to)`, oldest first, and how far the saved days reach.
    ///
    /// Every id the raw streams are read under is consulted and the lists are merged with earlier ids winning
    /// where two cover the same seconds (`ActivityContextPersistence.merged`), so a strap swap or a re-paired
    /// strap does not split a day's story. `through` is the latest decode horizon of the days in the window
    /// (nil when none has been saved).
    func storedActivityContext(from: Int, to: Int, timeZone: TimeZone = .current)
        async -> (intervals: [ActivityContextInterval], through: Int?) {
        guard to > from, let store = await storeHandle() else { return ([], nil) }
        let ids = rawPhysiologyReadIds(store: store)
        var lists: [[ActivityContextInterval]] = []
        for id in ids {
            let rows = (try? await store.activityContextIntervals(deviceId: id, from: from, to: to)) ?? []
            if !rows.isEmpty { lists.append(rows.map(ActivityContextInterval.init(row:))) }
        }
        let merged = ActivityContextPersistence.merged(lists)
        guard !merged.isEmpty else { return ([], nil) }

        let span = max(1, (to - from) / 86_400 + 2)
        let days = ActivityContextMaterialization.localDays(endingAt: to - 1, count: span, timeZone: timeZone)
            .filter { $0.end > from }
        let ledgers = await activityContextLedgers(store: store, ids: ids, days: days)
        let through = ledgers.values
            .flatMap { $0.values }
            .filter { $0.dayEnd > from && $0.dayStart < to }
            .compactMap(\.dataThrough)
            .max()
        return (merged, through)
    }
}

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

    /// The materializer's witness of everything a day's decode reads, computed without loading the day: the
    /// store's witness over the raw ids' streams, the sleep sessions (raw and computed ids) and the workouts
    /// (every namespace the Workouts list reads), the encoder and ElderNet window revisions the decode would
    /// attach (only for a day the active strap owns), the ledger config tag and the dismissed workout spans
    /// overlapping the day. nil when the store cannot answer (the day then gets no fingerprint rule).
    func activityContextInputFingerprint(store: WhoopStore, ids: [String], day: ActivityContextMaterialization.Day,
                                         ownerId: String, configTag: String) async -> String? {
        let computed = ids.map { $0.hasSuffix("-noop") ? $0 : $0 + "-noop" }
        guard let witness = try? await store.activityContextInputFingerprint(
            streamIds: ids, sleepIds: ids + computed.filter { !ids.contains($0) },
            workoutIds: Self.workoutNamespaces(rawIds: ids), from: day.start, to: day.end) else { return nil }
        var encoder: [String: String] = [:], gait: [String: String] = [:]
        if serverWindowsApply(toDayOwnedBy: ownerId) {
            let utcDays = ActivityEncoderWindowStore.utcDays(from: day.start, to: day.end)
            encoder = ActivityEncoderWindowStore.shared.revisions(days: utcDays)
            gait = GaitWindowStore.shared.revisions(days: utcDays)
        }
        let dismissed = (UserDefaults.standard.stringArray(forKey: WorkoutSource.dismissedDefaultsKey) ?? [])
            .filter { token in
                let parts = token.split(separator: ":").compactMap { Int($0) }
                return parts.count == 2 && parts[1] > day.start && parts[0] < day.end
            }.sorted().joined(separator: ",")
        return ActivityContextMaterialization.inputFingerprint(store: witness, encoderRevisions: encoder,
                                                               gaitRevisions: gait, configTag: configTag,
                                                               dismissedWorkouts: dismissed)
    }

    /// One saved day as a reader should take it.
    struct StoredActivityContextDay: Equatable {
        let day: String
        let dayStart: Int
        let dayEnd: Int
        /// The id the day's context is stored under.
        let deviceId: String
        let status: ActivityContextPersistence.ServingStatus
        /// True until the day is `final`: it was live, or its sleep had not settled, when it was derived.
        let isProvisional: Bool
        let decoderVersion: String
        let configTag: String?
        let dataThrough: Int?
        let computedAt: Int
    }

    /// The saved activity context overlapping `[from, to)` with each saved day's standing.
    struct StoredActivityContext: Equatable {
        /// Merged across ids, oldest first. Intervals of a `.stale` day (another taxonomy / decoder rule set)
        /// are left out: their labels cannot be read as this build's.
        let intervals: [ActivityContextInterval]
        /// The latest decode horizon of the days in the window (nil when none has been saved).
        let through: Int?
        /// Every saved day overlapping the window, oldest first.
        let days: [StoredActivityContextDay]

        /// True when any served interval comes from a day that may still change or is being re-derived.
        var hasProvisionalContext: Bool {
            days.contains { $0.status != .stale && ($0.isProvisional || $0.status == .refreshing) }
        }
    }

    /// The saved activity context overlapping `[from, to)`, oldest first, and how far the saved days reach.
    ///
    /// Every id the raw streams are read under is consulted and the lists are merged with earlier ids winning
    /// where two cover the same seconds (`ActivityContextPersistence.merged`), so a strap swap or a re-paired
    /// strap does not split a day's story. `through` is the latest decode horizon of the days in the window
    /// (nil when none has been saved). Days derived by another rule set are not served (see
    /// `storedActivityContextWithStatus`, which also says which days are provisional).
    func storedActivityContext(from: Int, to: Int, timeZone: TimeZone = .current)
        async -> (intervals: [ActivityContextInterval], through: Int?) {
        let stored = await storedActivityContextWithStatus(from: from, to: to, timeZone: timeZone)
        return (stored.intervals, stored.through)
    }

    func storedActivityContextWithStatus(from: Int, to: Int, timeZone: TimeZone = .current) async -> StoredActivityContext {
        let empty = StoredActivityContext(intervals: [], through: nil, days: [])
        guard to > from, let store = await storeHandle() else { return empty }
        let ids = rawPhysiologyReadIds(store: store)
        let span = max(1, (to - from) / 86_400 + 2)
        let localDays = ActivityContextMaterialization.localDays(endingAt: to - 1, count: span, timeZone: timeZone)
            .filter { $0.end > from }
        let ledgers = await activityContextLedgers(store: store, ids: ids, days: localDays)

        var lists: [[ActivityContextInterval]] = []
        var days: [StoredActivityContextDay] = []
        for id in ids {
            let rows = (try? await store.activityContextIntervals(deviceId: id, from: from, to: to)) ?? []
            let own = (ledgers[id] ?? [:]).values.filter { $0.dayEnd > from && $0.dayStart < to }
            for ledger in own {
                days.append(StoredActivityContextDay(
                    day: ledger.day, dayStart: ledger.dayStart, dayEnd: ledger.dayEnd, deviceId: id,
                    status: ActivityContextPersistence.servingStatus(
                        ledger, configTag: activityContextLedgerConfigTag(dayStart: ledger.dayStart)),
                    isProvisional: !ledger.isFinal, decoderVersion: ledger.decoderVersion,
                    configTag: ledger.configTag, dataThrough: ledger.dataThrough, computedAt: ledger.computedAt))
            }
            // `.stale` depends on the rule-set versions only, never on the config tag.
            let staleDays = own.filter { ActivityContextPersistence.servingStatus($0) == .stale }
            let served = rows.filter { row in !staleDays.contains { $0.dayStart <= row.startTs && row.startTs < $0.dayEnd } }
            if !served.isEmpty { lists.append(served.map(ActivityContextInterval.init(row:))) }
        }
        let merged = ActivityContextPersistence.merged(lists)
        days.sort { ($0.dayStart, $0.deviceId) < ($1.dayStart, $1.deviceId) }
        guard !merged.isEmpty else { return StoredActivityContext(intervals: [], through: nil, days: days) }
        let through = days.filter { $0.status != .stale }.compactMap(\.dataThrough).max()
        return StoredActivityContext(intervals: merged, through: through, days: days)
    }
}

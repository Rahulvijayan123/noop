import Foundation
import WhoopStore

// ActivityContextMaterialization.swift — when a day's stored activity context has to be derived again.
//
// The context tables are derived data. They are written after the strap's data lands (a post-offload pass) and
// must neither lag the streams they describe nor re-derive a month of history on every pass. Deriving a day
// means loading its streams and running the decoder, so the question "does this day need work?" has to be
// answerable from a few indexed lookups: the ledger row, and the newest heart-rate second the database holds
// for that day.
//
// Rules, in the order they are applied to a day that has any heart rate at all:
//   1. No current ledger row (never done, or done under an older taxonomy / decoder / interval rule) -> derive.
//   2. Heart rate at or past where the ledger says decoding stopped, which this process has not already looked
//      at -> derive (new data arrived, in an offload or a late backfill).
//   3. The ledger was written while the day was still in progress and the day has since closed -> derive once:
//      a finished day reads time outside logged sleep as awake, a live one as unknown.
//   4. A day that ended less than `recentWindowS` ago, last looked at `recheckIntervalS` or more ago -> derive:
//      sleep, workouts and wrist-off events (the inputs that are not streams) may have changed.
//   5. When the caller tracks an input fingerprint (the cheap COUNT/MAX witness over the day's streams), a day
//      whose input no longer matches the fingerprint recorded when it was last derived, or what this process
//      last saw, -> derive: a late IMU/step/wear backfill inside a covered span never moves the newest
//      heart-rate second, so only the fingerprint sees it (spec §4 A07, WS-10-F03).
// Days that are not recent are limited to `maxBacklogPerPass` per pass, newest first, so a first run over months
// of history spreads across passes instead of stalling one.

public enum ActivityContextMaterialization {

    /// One local calendar day. `end` is the next local midnight, which is 23 or 25 hours after `start` on a
    /// daylight-saving change.
    public struct Day: Equatable, Hashable, Sendable {
        public var key: String
        public var start: Int
        public var end: Int

        public init(key: String, start: Int, end: Int) {
            self.key = key; self.start = start; self.end = end
        }
    }

    /// What this process last saw of a day: when, the newest heart-rate second then, and (when the caller
    /// tracks one) the fingerprint of the day's whole input then. Kept in memory only.
    public struct Check: Equatable, Sendable {
        public var at: Int
        public var newestHeartRateTs: Int?
        /// Fingerprint of the day's input (HR, motion, IMU/encoder, sleep/workout/wear spans) the last time
        /// this process looked. nil when the caller does not track one.
        public var inputFingerprint: String?

        public init(at: Int, newestHeartRateTs: Int?, inputFingerprint: String? = nil) {
            self.at = at; self.newestHeartRateTs = newestHeartRateTs
            self.inputFingerprint = inputFingerprint
        }
    }

    public struct Candidate: Sendable {
        public var day: Day
        public var ledger: ActivityContextDayRow?
        /// Newest heart-rate second the database holds inside the day; nil when there is none.
        public var newestHeartRateTs: Int?
        public var lastCheck: Check?
        /// Cheap fingerprint of the day's input as the caller reads it now (for example the store's
        /// `dayStreamFingerprint`: COUNT/MAX index walks that materialise no rows). nil when the caller
        /// does not track the non-HR input, in which case no fingerprint rule applies.
        public var inputFingerprint: String?
        /// The same fingerprint as recorded when the day was last derived (its ledger record). nil when
        /// the ledger does not carry one (older rows) or the caller has none. The caller must write the
        /// fingerprint it derived back here (or into `Check.inputFingerprint`) or the mismatch below
        /// would flag the day again on every pass.
        public var storedInputFingerprint: String?

        public init(day: Day, ledger: ActivityContextDayRow? = nil, newestHeartRateTs: Int? = nil,
                    lastCheck: Check? = nil, inputFingerprint: String? = nil,
                    storedInputFingerprint: String? = nil) {
            self.day = day; self.ledger = ledger
            self.newestHeartRateTs = newestHeartRateTs; self.lastCheck = lastCheck
            self.inputFingerprint = inputFingerprint
            self.storedInputFingerprint = storedInputFingerprint
        }
    }

    public struct Config: Equatable, Sendable {
        /// A day that ended less than this long ago is "recent": always eligible, and re-read now and then.
        public var recentWindowS = 36 * 3_600
        /// Longest a recent day goes without being looked at again.
        public var recheckIntervalS = 1_800
        /// Days that are not recent that one pass will derive.
        public var maxBacklogPerPass = 2
        public init() {}
    }

    /// The `count` local calendar days up to and including the one holding `now`, newest first. Day keys are
    /// `yyyy-MM-dd` in the Gregorian calendar whatever the user's calendar is, as everywhere else in the app.
    public static func localDays(endingAt now: Int, count: Int, timeZone: TimeZone) -> [Day] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var days: [Day] = []
        var cursor = Date(timeIntervalSince1970: TimeInterval(now))
        for _ in 0..<max(0, count) {
            let start = calendar.startOfDay(for: cursor)
            guard let next = calendar.date(byAdding: .day, value: 1, to: start) else { break }
            let parts = calendar.dateComponents([.year, .month, .day], from: start)
            let key = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
            days.append(Day(key: key, start: Int(start.timeIntervalSince1970), end: Int(next.timeIntervalSince1970)))
            cursor = start.addingTimeInterval(-1)
        }
        return days
    }

    /// The days to derive this pass, newest first.
    public static func plan(_ candidates: [Candidate], now: Int, config: Config = Config()) -> [Day] {
        var backlog = 0
        var days: [Day] = []
        for candidate in candidates.sorted(by: { $0.day.start > $1.day.start })
        where needsWork(candidate, now: now, config: config) {
            if !isRecent(candidate.day, now: now, config: config) {
                guard backlog < config.maxBacklogPerPass else { continue }
                backlog += 1
            }
            days.append(candidate.day)
        }
        return days
    }

    public static func isRecent(_ day: Day, now: Int, config: Config = Config()) -> Bool {
        day.end > now - config.recentWindowS
    }

    public static func needsWork(_ c: Candidate, now: Int, config: Config = Config()) -> Bool {
        guard c.day.start < now else { return false }
        guard let newest = c.newestHeartRateTs else { return false }
        guard let ledger = c.ledger, ActivityContextPersistence.isCurrent(ledger) else { return true }

        let horizon = ledger.dataThrough ?? ledger.dayStart
        if newest >= horizon, newest > (c.lastCheck?.newestHeartRateTs ?? Int.min) { return true }

        let closedAt = max(ledger.dayEnd, ledger.dayStart + 86_400)
        if ledger.computedAt < closedAt, now >= closedAt, (c.lastCheck?.at ?? 0) < closedAt { return true }

        if isRecent(c.day, now: now, config: config),
           now - (c.lastCheck?.at ?? ledger.computedAt) >= config.recheckIntervalS { return true }

        // Late data the HR witness cannot see — an IMU/step/wear backfill landing inside an old day's
        // covered span — never moves `newestHeartRateTs`, and an old day is not re-read by rule 4. When
        // the caller tracks an input fingerprint, recheck whenever the streams now read differ from the
        // fingerprint recorded when the day was last derived or from what this process last saw. It is a
        // cheap string compare, never a re-decode, so every old day can be asked every pass.
        if let current = c.inputFingerprint {
            if let stored = c.storedInputFingerprint, stored != current { return true }
            if let seen = c.lastCheck?.inputFingerprint, seen != current { return true }
        }
        return false
    }

    /// Whether the stored day already is this document: written by the current rules, from the same
    /// decode (its timestamp), reaching as far. A day for which this holds is not written again.
    public static func covers(_ ledger: ActivityContextDayRow?, document: ActivityContextDayDocument) -> Bool {
        guard let ledger, ActivityContextPersistence.isCurrent(ledger) else { return false }
        return ledger.dayStart == document.dayStart
            && ledger.computedAt == document.generatedAt
            && ledger.dataThrough == document.dataThrough.map { min($0, ledger.dayEnd) }
    }
}

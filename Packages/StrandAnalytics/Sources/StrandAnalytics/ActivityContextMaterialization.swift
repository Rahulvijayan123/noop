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
//   1. No current ledger row (never done, or done under an older taxonomy / decoder / interval rule / feature
//      schema, or — when the caller passes it — another decoder config tag) -> derive.
//   2. Heart rate at or past where the ledger says decoding stopped, which this process has not already looked
//      at -> derive (new data arrived, in an offload or a late backfill).
//   3. The ledger was written while the day was still in progress and the day has since closed -> derive once:
//      a finished day reads time outside logged sleep as awake, a live one as unknown.
//   4. A day that ended less than `recentWindowS` ago, last looked at `recheckIntervalS` or more ago -> derive:
//      sleep, workouts and wrist-off events (the inputs that are not streams) may have changed.
//   5. When the caller tracks an input fingerprint (the cheap witness over everything the decode reads: the
//      day's streams across ids, sleep, workouts, the encoder / gait window revisions), a day whose input no
//      longer matches the fingerprint recorded in its ledger when it was last derived, or what this process
//      last saw, -> derive: a late IMU/step/wear backfill inside a covered span never moves the newest
//      heart-rate second, so only the fingerprint sees it (spec §4 A07, WS-10-F03). Not throttled: new encoder
//      windows for a day re-derive it on the next pass, recent or not.
//   6. A ledger still `provisional` once the day has been closed for `sleepSettleS`, which this process has not
//      looked at since -> derive (or confirm) once, so the day becomes `final`.
//   7. When the caller writes retrospective rows (`Candidate.retrospectiveVersion`), a final ledger that does not
//      record that smoother version, which this process has not looked at since the day settled -> derive once,
//      so the day gains its retrospective intervals (D8-10).
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
        /// The decoder config tag the caller decodes with now. When set, a ledger derived under another tag is
        /// not current (rule 1). nil: the config is not compared.
        public var configTag: String?
        /// The retrospective smoother version the caller writes for final days (`ActivityContextRetrospective.
        /// version`). When set, a final ledger that does not record it is derived once more so the day gains its
        /// retrospective rows (rule 7). nil: the caller writes none, and the rule is off (it must stay off for a
        /// caller that does not write them, or the day would be planned again on every pass).
        public var retrospectiveVersion: String?

        /// `storedInputFingerprint` defaults to the ledger's own record (v50), so a caller that passes the
        /// ledger gets rule 5 across launches without threading it through.
        public init(day: Day, ledger: ActivityContextDayRow? = nil, newestHeartRateTs: Int? = nil,
                    lastCheck: Check? = nil, inputFingerprint: String? = nil,
                    storedInputFingerprint: String? = nil, configTag: String? = nil,
                    retrospectiveVersion: String? = nil) {
            self.day = day; self.ledger = ledger
            self.newestHeartRateTs = newestHeartRateTs; self.lastCheck = lastCheck
            self.inputFingerprint = inputFingerprint
            self.storedInputFingerprint = storedInputFingerprint ?? ledger?.inputFingerprint
            self.configTag = configTag
            self.retrospectiveVersion = retrospectiveVersion
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
        guard let ledger = c.ledger, ActivityContextPersistence.isCurrent(ledger, configTag: c.configTag) else { return true }

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

        let settledAt = ledger.dayEnd + ActivityContextPersistence.sleepSettleS
        if !ledger.isFinal, now >= settledAt, (c.lastCheck?.at ?? ledger.computedAt) < settledAt { return true }

        // 7. A final day without the retrospective rows of the smoother the caller writes (never smoothed, or by
        // another version): derive it once more, unless this process already looked since it became final.
        if let wanted = c.retrospectiveVersion, ledger.isFinal, ledger.retrospectiveVersion != wanted,
           c.lastCheck.map({ $0.at < settledAt }) ?? true { return true }
        return false
    }

    /// Days that still have stored context but no longer any heart rate (or no owner): samples moved out by a
    /// timestamp heal, a deleted device, deleted data. Their rows describe seconds that have nothing behind them
    /// and are cleared. `ledgerDays` are the day starts holding a ledger row under any id.
    ///
    /// Only a confirmed "no heart rate" orphans a day: when any owner probe of the pass failed (`unanswered`
    /// holds the days whose store read threw), nothing is cleared that pass, because a transient read failure
    /// looks exactly like a day with no data and the stored context of a whole horizon would otherwise be lost.
    public static func orphanedDays(_ days: [Day], ledgerDays: Set<Int>, owned: Set<Int>,
                                    unanswered: Set<Int> = []) -> [Day] {
        guard unanswered.isEmpty else { return [] }
        return days.filter { ledgerDays.contains($0.start) && !owned.contains($0.start) }
    }

    /// The materializer's input fingerprint for a day: the store's witness over the day's streams, sleep and
    /// workouts, the encoder, gait and motion-head window revisions the decode would attach, the decoder config tag
    /// and the dismissed workout spans. Revisions are folded in sorted-key order, so an unchanged set never reads as
    /// changed; motion-head revisions only when there are any, so a day without them keeps its fingerprint.
    public static func inputFingerprint(store: String, encoderRevisions: [String: String] = [:],
                                        gaitRevisions: [String: String] = [:],
                                        motionHeadsRevisions: [String: String] = [:], configTag: String,
                                        dismissedWorkouts: String = "") -> String {
        func revs(_ r: [String: String]) -> String { r.keys.sorted().map { "\($0)=\(r[$0]!)" }.joined(separator: ",") }
        let motion = motionHeadsRevisions.isEmpty ? "" : "|mh[\(revs(motionHeadsRevisions))]"
        return "\(store)|enc[\(revs(encoderRevisions))]|gait[\(revs(gaitRevisions))]\(motion)|cfg[\(configTag)]|dis[\(dismissedWorkouts)]"
    }

    /// Whether the stored day already is this document: written by the current rules, from the same
    /// decode (its timestamp), reaching as far. A day for which this holds is not written again.
    public static func covers(_ ledger: ActivityContextDayRow?, document: ActivityContextDayDocument,
                              configTag: String? = nil) -> Bool {
        guard let ledger, ActivityContextPersistence.isCurrent(ledger, configTag: configTag) else { return false }
        return ledger.dayStart == document.dayStart
            && ledger.computedAt == document.generatedAt
            && ledger.dataThrough == document.dataThrough.map { min($0, ledger.dayEnd) }
    }
}

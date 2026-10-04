import XCTest
@testable import Strand

/// T06 travel — the effective-dated zone journal (F3): `IntelligenceEngine.localDayRun` resolves each
/// historical day in the zone that was actually in effect for it (from `ProfileStore.timezoneHistory`,
/// mirroring the server's `scoring_timezone_history`), so after a trip the app's day bounds agree with
/// SQL for the same instants instead of re-bucketing every day in the phone's CURRENT zone.
@MainActor
final class ZoneHistoryDayRunTests: XCTestCase {
    private let keys = ["profile.timezone", "profile.timezoneHistory", "profile.cloudDirty"]

    override func setUp() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    /// A user who flew from New York to Los Angeles on 2025-11-05: days before the flight must stay
    /// bucketed in New York (05:00Z local midnights, EST), days after in Los Angeles (08:00Z, PST).
    func testLocalDayRunPicksTheZoneEffectiveForEachDay() {
        let travelTs = 1_762_344_000   // 2025-11-05T12:00:00Z — the phone observed LA here
        let history = [TimezoneChange(zoneId: "America/New_York", effectiveFrom: 0),
                       TimezoneChange(zoneId: "America/Los_Angeles", effectiveFrom: travelTs)]
        let now = 1_762_819_200        // 2025-11-10T12:00:00Z
        let run = IntelligenceEngine.localDayRun(endingAt: now, count: 10,
                                                 zoneHistory: history, defaultZone: .la)

        // 2025-11-03 (before travel): New York's local midnight (05:00Z), NOT Los Angeles' (08:00Z).
        let nov3 = run.first { $0.date.key == "2025-11-03" }
        XCTAssertEqual(nov3?.date.key, "2025-11-03")
        XCTAssertEqual(Int(nov3!.start.timeIntervalSince1970), 1_762_146_000,
                       "a pre-travel day must stay bucketed in the zone it happened in (NY 05:00Z)")
        XCTAssertEqual(Int(nov3!.nextStart.timeIntervalSince1970), 1_762_232_400)

        // 2025-11-07 (after travel): Los Angeles' local midnight (08:00Z).
        let nov7 = run.first { $0.date.key == "2025-11-07" }
        XCTAssertEqual(Int(nov7!.start.timeIntervalSince1970), 1_762_502_400,
                       "a post-travel day must use the new zone (LA 08:00Z)")

        // The two days use DIFFERENT zones' midnights — the old single-zone behavior would have given
        // 08:00Z for BOTH.
        XCTAssertNotEqual(Int(nov3!.start.timeIntervalSince1970), Int(nov7!.start.timeIntervalSince1970))
    }

    /// The no-journal default keeps the pre-journal behavior: every day in the default zone.
    func testLocalDayRunEmptyHistoryUsesDefaultZone() {
        let now = 1_762_819_200
        let run = IntelligenceEngine.localDayRun(endingAt: now, count: 10, zoneHistory: [],
                                                 defaultZone: .la)
        let nov3 = run.first { $0.date.key == "2025-11-03" }
        XCTAssertEqual(Int(nov3!.start.timeIntervalSince1970), 1_762_156_800,
                       "empty journal: all days resolve in the default zone (LA 08:00Z)")
    }

    /// The zone resolver picks the LATEST journal entry at-or-before the instant, falling back to the
    /// journal's oldest (pre-journal days) and then to the caller's fallback.
    func testZoneResolverPicksTheLatestEffectiveEntry() {
        let fallback = TimeZone(identifier: "UTC")!
        let journal = [TimezoneChange(zoneId: "America/New_York", effectiveFrom: 0),
                       TimezoneChange(zoneId: "America/Los_Angeles", effectiveFrom: 1_762_344_000)]
        XCTAssertEqual(IntelligenceEngine.zone(at: 1_762_300_000, journal: journal, fallback: fallback).identifier,
                       "America/New_York")
        XCTAssertEqual(IntelligenceEngine.zone(at: 1_762_500_000, journal: journal, fallback: fallback).identifier,
                       "America/Los_Angeles")
        XCTAssertEqual(IntelligenceEngine.zone(at: 1_762_300_000, journal: [], fallback: fallback).secondsFromGMT(),
                       0, "an empty journal falls back (Foundation may name UTC as GMT)")
    }

    /// ProfileStore seeds the journal on first use and appends on a device-zone change.
    func testProfileStoreSeedsAndAppendsTheZoneJournal() {
        let store = ProfileStore()
        XCTAssertFalse(store.timezoneHistory.isEmpty, "a fresh store must seed the journal")
        XCTAssertEqual(store.timezoneHistory.first?.zoneId, TimeZone.current.identifier)

        // Simulate a zone change while the app was running: stale persisted zone, then the device refresh
        // reverts it and appends a fresh effectiveFrom to the journal.
        store.timezone = "Asia/Tokyo"
        XCTAssertEqual(store.timezoneHistory.count, 1, "setting the field directly must not journal")
        XCTAssertTrue(store.refreshTimezoneFromDevice(), "the refresh must observe the change")
        XCTAssertEqual(store.timezoneHistory.count, 2, "the refresh must append the observed change")
        XCTAssertEqual(store.timezoneHistory.last?.zoneId, TimeZone.current.identifier)
        XCTAssertGreaterThan(store.timezoneHistory.last?.effectiveFrom ?? 0, 0)

        // Persistence: a second store instance reloads the same journal.
        let reloaded = ProfileStore()
        XCTAssertEqual(reloaded.timezoneHistory, store.timezoneHistory)
    }

    // MARK: - Round-3 regression (audit F3-P1): a stale journal must never mis-bucket TODAY

    /// The phone's CURRENT zone is New York but the journal's last observed zone is Los Angeles (the
    /// zone-change append has not run yet — a non-cloud user before the next sync/observer). TODAY must
    /// resolve in the LIVE zone (`defaultZone` = `TimeZone.current`), while past days keep their journal
    /// zone. This is the exact round-3 P1 regression the audit named.
    func testStaleJournalNeverMisBucketsToday() {
        let history = [TimezoneChange(zoneId: "America/Los_Angeles", effectiveFrom: 0)]
        let now = 1_762_819_200   // 2025-11-10T12:00:00Z
        let run = IntelligenceEngine.localDayRun(endingAt: now, count: 5,
                                                 zoneHistory: history, defaultZone: .ny)

        let today = run.first
        XCTAssertEqual(today?.date.key, "2025-11-10")
        XCTAssertEqual(Int(today!.start.timeIntervalSince1970), 1_762_750_800,
                       "TODAY must resolve in the LIVE zone (NY 05:00Z), never a stale journal zone")
        XCTAssertNotEqual(Int(today!.start.timeIntervalSince1970), 1_762_761_600,
                          "the LA 08:00Z answer must not be used for today")
        let past = run.first { $0.date.key == "2025-11-08" }
        XCTAssertEqual(Int(past!.start.timeIntervalSince1970), 1_762_588_800,
                       "a past day keeps its journal zone (LA 08:00Z)")
    }

    /// Launch-time append (round-3 fix 1): a journal persisted from a previous zone is appended with the
    /// CURRENT zone when the app relaunches there, so the journal never goes stale at launch after travel.
    func testProfileStoreLaunchAppendsWhenTheJournalIsStale() {
        let stale = TimeZone.current.identifier == "America/New_York" ? "America/Los_Angeles" : "America/New_York"
        UserDefaults.standard.set(stale, forKey: "profile.timezone")
        let data = try! JSONEncoder().encode([TimezoneChange(zoneId: stale, effectiveFrom: 0)])
        UserDefaults.standard.set(data, forKey: "profile.timezoneHistory")

        let store = ProfileStore()
        XCTAssertEqual(store.timezone, TimeZone.current.identifier, "launch must adopt the live zone")
        XCTAssertEqual(store.timezoneHistory.last?.zoneId, TimeZone.current.identifier,
                       "a stale journal must be appended at launch")
        XCTAssertEqual(store.timezoneHistory.count, 2, "seed(old) + appended(live)")
        XCTAssertTrue(store.cloudDirty, "profiles.timezone is stale; the next cloud sync must push it")
    }

    /// Un-gated zone-change hook (round-3 fix 2): the `Repository.dayKeyDidChange` observer calls
    /// `refreshTimezoneFromDevice()` WITHOUT cloud mode, so a mid-session zone change appends to the
    /// journal immediately for every user.
    func testZoneChangeNotificationRefreshesTheJournalWithoutCloudMode() async {
        let store = ProfileStore()
        let stale = store.timezone == "America/New_York" ? "America/Los_Angeles" : "America/New_York"
        store.timezone = stale
        let before = store.timezoneHistory.count

        NotificationCenter.default.post(name: Repository.dayKeyDidChange, object: nil)
        for _ in 0..<10 { await Task.yield() }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(store.timezone, TimeZone.current.identifier,
                       "the dayKeyDidChange observer must refresh from the device, cloud or not")
        XCTAssertEqual(store.timezoneHistory.count, before + 1,
                       "the un-gated observer must append the observed zone change")
        XCTAssertEqual(store.timezoneHistory.last?.zoneId, TimeZone.current.identifier)
    }
}

private extension TimeZone {
    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static let ny = TimeZone(identifier: "America/New_York")!
}

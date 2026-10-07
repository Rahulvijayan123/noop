import XCTest
@testable import Strand

/// `SettingsCloudSync`: which preferences follow the account, and the per-key merge that decides what each
/// side keeps. Runs against a private defaults suite and a fake route, so nothing here touches the app's own
/// preferences or the network.
@MainActor
final class SettingsCloudSyncTests: XCTestCase {

    private final class FakeRoute {
        var stored: [String: Any]?
        var saves: [[String: Any]] = []
        var offline = false

        func fetch() throws -> [String: Any]? {
            if offline { throw URLError(.notConnectedToInternet) }
            return stored
        }

        func save(_ values: [String: Any]) throws {
            if offline { throw URLError(.notConnectedToInternet) }
            saves.append(values)
            stored = (stored ?? [:]).merging(values) { _, new in new }
        }
    }

    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "SettingsCloudSyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private func makeSync(_ route: FakeRoute, owner: @escaping () -> String? = { "owner-a" },
                          available: @escaping () -> Bool = { true }, throttle: TimeInterval = 60,
                          onApplied: @escaping ([String]) -> Void = { _ in }) -> SettingsCloudSync {
        SettingsCloudSync(defaults: defaults, throttle: throttle, isAvailable: available, owner: owner,
                          fetch: { try route.fetch() }, save: { try route.save($0) }, onApplied: onApplied)
    }

    // MARK: What follows the account

    func testTheSyncedSettingsAreTheAccountWideOnes() {
        let keys = Set(SyncedSetting.all.map(\.defaultsKey))
        XCTAssertEqual(SyncedSetting.all.count, keys.count, "one cloud name per preference")
        for kept in [UnitPrefs.systemKey, "noop.coachEnabled", AppModel.wristAlertsMasterKey,
                     BehaviorStore.K.batteryAlerts, HapticPrefs.liftRest, InactivityPrefs.K.threshold] {
            XCTAssertTrue(keys.contains(kept), kept)
        }
        // Names something on this phone, or a consent given here.
        for local in [BehaviorStore.K.dtAction, BehaviorStore.K.dtShortcut, BehaviorStore.K.wristOffShortcut,
                      AppModel.cycleAwarenessKey, RhythmConsent.enabledKey, SensorBiomarkerFeature.enabledKey] {
            XCTAssertFalse(keys.contains(local), local)
        }
    }

    func testOnlyRealValuesOfASettingCount() {
        let minutes = SyncedSetting("m", "m", .int(15...120))
        XCTAssertEqual(minutes.value(45), .int(45))
        XCTAssertEqual(minutes.value(45.0), .int(45))
        XCTAssertNil(minutes.value(47.5))
        XCTAssertNil(minutes.value(500))
        XCTAssertNil(minutes.value(true), "a boolean is not a number of minutes")
        let flag = SyncedSetting("f", "f", .bool)
        XCTAssertEqual(flag.value(false), .bool(false))
        XCTAssertNil(flag.value(1), "a number is not a switch")
        XCTAssertNil(flag.value("true"))
        let units = SyncedSetting("u", "u", .choice(["metric", "imperial"]))
        XCTAssertEqual(units.value("imperial"), .string("imperial"))
        XCTAssertNil(units.value("nautical"))
    }

    // MARK: The merge

    func testAFirstExchangeKeepsTheAccountsValuesAndUploadsTheRest() {
        let plan = SettingsCloudSync.merge(local: ["units": .string("metric"), "sanaEnabled": .bool(false)],
                                           remote: ["units": .string("imperial"), "zoneCoaching": .bool(true)],
                                           base: nil)
        XCTAssertEqual(plan.adopt, ["units": .string("imperial"), "zoneCoaching": .bool(true)])
        XCTAssertEqual(plan.upload, ["sanaEnabled": .bool(false)])
        XCTAssertEqual(plan.merged, ["units": .string("imperial"), "zoneCoaching": .bool(true),
                                     "sanaEnabled": .bool(false)])
    }

    func testAfterAnExchangeEachSideKeepsWhatItChanged() {
        let base: [String: SettingValue] = ["units": .string("metric"), "batteryAlerts": .bool(true)]
        let plan = SettingsCloudSync.merge(local: ["units": .string("imperial"), "batteryAlerts": .bool(true)],
                                           remote: ["units": .string("metric"), "batteryAlerts": .bool(false)],
                                           base: base)
        XCTAssertEqual(plan.upload, ["units": .string("imperial")], "changed here")
        XCTAssertEqual(plan.adopt, ["batteryAlerts": .bool(false)], "changed on another phone")
    }

    func testNothingMovesWhenBothSidesAgree() {
        let same: [String: SettingValue] = ["units": .string("metric")]
        XCTAssertEqual(SettingsCloudSync.merge(local: same, remote: same, base: same), .init(merged: same))
        XCTAssertEqual(SettingsCloudSync.merge(local: same, remote: same, base: nil), .init(merged: same))
    }

    // MARK: The exchange

    func testAnEmptyAccountIsSeededWithWhatThisPhoneHasStored() async {
        defaults.set("imperial", forKey: UnitPrefs.systemKey)
        defaults.set(false, forKey: BehaviorStore.K.batteryAlerts)
        defaults.set(45, forKey: InactivityPrefs.K.threshold)
        let route = FakeRoute()
        await makeSync(route).reconcile()

        XCTAssertEqual(route.saves.count, 1)
        XCTAssertEqual(route.saves.first?["units"] as? String, "imperial")
        XCTAssertEqual(route.saves.first?["batteryAlerts"] as? Bool, false)
        XCTAssertEqual(route.saves.first?["moveReminderMinutes"] as? Int, 45)
        XCTAssertEqual(route.saves.first?.count, 3, "a preference nobody set stays the default everywhere")
    }

    func testAFreshInstallRestoresTheAccountsSettings() async {
        let route = FakeRoute()
        route.stored = ["units": "imperial", "batteryAlerts": false, "moveReminderMinutes": 45, "hapticLiftRest": false]
        var applied: [String] = []
        let posted = expectation(forNotification: .syncedSettingsDidApply, object: nil)
        await makeSync(route, onApplied: { applied = $0 }).reconcile()

        await fulfillment(of: [posted], timeout: 1)
        XCTAssertEqual(defaults.string(forKey: UnitPrefs.systemKey), "imperial")
        XCTAssertEqual(defaults.object(forKey: BehaviorStore.K.batteryAlerts) as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: InactivityPrefs.K.threshold) as? Int, 45)
        XCTAssertEqual(defaults.object(forKey: HapticPrefs.liftRest) as? Bool, false)
        XCTAssertEqual(applied, ["batteryAlerts", "hapticLiftRest", "moveReminderMinutes", "units"])
        XCTAssertTrue(route.saves.isEmpty, "nothing to send back")
    }

    func testEditsOnEitherSideTravelAfterTheFirstExchange() async {
        defaults.set("metric", forKey: UnitPrefs.systemKey)
        let route = FakeRoute()
        let sync = makeSync(route)
        await sync.reconcile()

        defaults.set(false, forKey: "noop.coachEnabled")
        route.stored?["units"] = "imperial"
        await sync.reconcile()
        XCTAssertEqual(route.saves.last?.keys.sorted(), ["sanaEnabled"])
        XCTAssertEqual(defaults.string(forKey: UnitPrefs.systemKey), "imperial")
    }

    func testAnotherAccountOnThisPhoneStartsFromItsOwnSettings() async {
        defaults.set("metric", forKey: UnitPrefs.systemKey)
        let route = FakeRoute()
        var owner = "owner-a"
        let sync = makeSync(route, owner: { owner })
        await sync.reconcile()

        // Account B saved imperial elsewhere. Account A's exchange is no base for it, so B's value wins.
        owner = "owner-b"
        route.stored = ["units": "imperial"]
        await sync.reconcile()
        XCTAssertEqual(defaults.string(forKey: UnitPrefs.systemKey), "imperial")
    }

    func testAnOfflineExchangeIsRetriedLater() async {
        defaults.set(true, forKey: BehaviorStore.K.zoneCoaching)
        let route = FakeRoute()
        route.offline = true
        let sync = makeSync(route)
        await sync.reconcile()
        XCTAssertNil(defaults.dictionary(forKey: SettingsCloudSync.baseKey), "nothing recorded as exchanged")

        route.offline = false
        await sync.syncIfChanged()
        XCTAssertEqual(route.saves.first?["zoneCoaching"] as? Bool, true)
        let saves = route.saves.count
        await sync.syncIfChanged()
        XCTAssertEqual(route.saves.count, saves, "no exchange once both sides agree")
    }

    func testInvalidCloudValuesAreIgnored() async {
        defaults.set(30, forKey: InactivityPrefs.K.threshold)
        let route = FakeRoute()
        route.stored = ["moveReminderMinutes": 500, "units": "nautical", "batteryAlerts": "no"]
        await makeSync(route).reconcile()
        XCTAssertEqual(defaults.object(forKey: InactivityPrefs.K.threshold) as? Int, 30)
        XCTAssertNil(defaults.string(forKey: UnitPrefs.systemKey))
        XCTAssertNil(defaults.object(forKey: BehaviorStore.K.batteryAlerts))
        XCTAssertEqual(route.saves.first?["moveReminderMinutes"] as? Int, 30)
    }

    func testNothingIsExchangedWithoutAnAccountThatOwnsThisPhone() async {
        defaults.set("imperial", forKey: UnitPrefs.systemKey)
        let route = FakeRoute()
        route.stored = ["units": "metric"]
        await makeSync(route, available: { false }).reconcile()
        XCTAssertEqual(defaults.string(forKey: UnitPrefs.systemKey), "imperial")
        XCTAssertTrue(route.saves.isEmpty)
    }

    func testAnEditIsUploadedOnItsOwn() async throws {
        let route = FakeRoute()
        let sync = makeSync(route, throttle: 0.05)
        await sync.reconcile()
        XCTAssertTrue(route.saves.isEmpty)

        defaults.set(false, forKey: HapticPrefs.workout)
        for _ in 0..<40 where route.saves.isEmpty { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(route.saves.first?["hapticWorkout"] as? Bool, false)
        withExtendedLifetime(sync) {}
    }
}

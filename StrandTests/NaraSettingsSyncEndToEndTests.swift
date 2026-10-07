import XCTest
import WhoopStore
@testable import Strand

/// The Settings values that belong to the account, against real services: Supabase Auth, the `coach`
/// function's profile and settings routes, the `scores` function's placement route and real Postgres. Each
/// test saves through the same sync code the app runs, reads the stored row back as the server holds it, then
/// plays a fresh install and checks Settings would show the saved values again. Skips itself unless the
/// disposable stack is up; see supabase/tests/e2e/README.md.
@MainActor
final class NaraSettingsSyncEndToEndTests: XCTestCase {
    private let profileKeys = ["profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
                               "profile.heightCm", "profile.displayName", "profile.cloudDirty", "profile.timezone",
                               "profile.timezoneHistory"]

    private var env: E2EEnvironment!
    private var mailbox: E2EMailbox!
    private var server: E2EServer!
    private var phones: [E2EPhone] = []
    private var defaultZone: TimeZone?
    private var cloudEnabledBefore: Any?

    private static let enabledOverrideKey = "noop.cloud.enabled.override"

    override func setUp() async throws {
        env = try E2EEnvironment.load()
        mailbox = E2EMailbox(env: env)
        server = E2EServer(env: env)
        let endpoint = env.pushEndpoint.absoluteString
        let key = env.publishableKey
        CloudPushSettings.bundleStringOverride = { name in
            switch name {
            case CloudPushSettings.endpointInfoKey: return endpoint
            case CloudPushSettings.publishableKeyInfoKey: return key
            default: return nil
            }
        }
        profileKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        // The capture path (strap uploads) only runs with cloud sync switched on, as in the app.
        cloudEnabledBefore = UserDefaults.standard.object(forKey: Self.enabledOverrideKey)
        UserDefaults.standard.set(true, forKey: Self.enabledOverrideKey)
    }

    override func tearDown() async throws {
        for phone in phones { await phone.tearDown() }
        phones = []
        CloudPushSettings.bundleStringOverride = nil
        profileKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        if let defaultZone { NSTimeZone.default = defaultZone }
        if let cloudEnabledBefore {
            UserDefaults.standard.set(cloudEnabledBefore, forKey: Self.enabledOverrideKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.enabledOverrideKey)
        }
    }

    private var coachEndpoint: URL { env.gateway.appendingPathComponent("functions/v1/coach") }

    private func signedInPhone(_ label: String) async throws -> (E2EPhone, CloudPushIdentity) {
        let phone = try E2EPhone(env: env, label: label)
        phones.append(phone)
        _ = try await phone.signUp(mailbox: mailbox)
        let identity = try XCTUnwrap(phone.identity, "the verified session linked this phone")
        return (phone, identity)
    }

    private func profileSync(_ store: ProfileStore, _ coach: CoachAPI) -> ProfileCloudSync {
        ProfileCloudSync(profile: store, debounce: 3600, isAvailable: { true },
                         fetch: { try await coach.profile() },
                         save: { try await coach.saveProfile($0) })
    }

    private func storedProfile(_ owner: String) async throws -> [String: Any] {
        let rows = try await server.rows("profiles",
                                         "id=eq.\(owner)&select=display_name,date_of_birth,sex_model,height_cm,weight_kg,timezone")
        return try XCTUnwrap(rows.first, "sign-up creates the profiles row")
    }

    /// Settings → Profile edits reach `profiles`, and a reinstall shows them again.
    func testProfileEditedInSettingsIsStoredAndRestoredOnAFreshInstall() async throws {
        let (_, identity) = try await signedInPhone("profile")
        let coach = CoachAPI(endpoint: { [coachEndpoint] in coachEndpoint }, identity: { identity })

        let phone = ProfileStore()
        let sync = profileSync(phone, coach)
        phone.displayName = "Settings E2E"
        phone.sex = "female"
        phone.heightCm = 171
        phone.weightKg = 61.5
        phone.dateOfBirth = try XCTUnwrap(ProfileStore.day(from: "1991-03-04"))
        XCTAssertTrue(phone.cloudDirty)
        await sync.pushIfDirty()
        XCTAssertFalse(phone.cloudDirty, "the upload was accepted")

        let row = try await storedProfile(identity.ownerId)
        XCTAssertEqual(row["display_name"] as? String, "Settings E2E")
        XCTAssertEqual(row["sex_model"] as? String, "female")
        XCTAssertEqual((row["height_cm"] as? NSNumber)?.doubleValue, 171)
        XCTAssertEqual((row["weight_kg"] as? NSNumber)?.doubleValue, 61.5)
        XCTAssertEqual(row["date_of_birth"] as? String, "1991-03-04")
        XCTAssertEqual(row["timezone"] as? String, TimeZone.current.identifier)

        // A fresh install: nothing stored locally, so Settings starts from its defaults.
        profileKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        let reinstalled = ProfileStore()
        XCTAssertEqual(reinstalled.displayName, "")
        await profileSync(reinstalled, coach).reconcile()
        XCTAssertEqual(reinstalled.displayName, "Settings E2E")
        XCTAssertEqual(reinstalled.sex, "female")
        XCTAssertEqual(reinstalled.heightCm, 171)
        XCTAssertEqual(reinstalled.weightKg, 61.5)
        XCTAssertEqual(ProfileStore.dayString(reinstalled.dateOfBirth), "1991-03-04")
        XCTAssertFalse(reinstalled.cloudDirty, "restoring is not an edit")
    }

    /// A profile entered before signing in reaches the row sign-up created, on a phone whose zone matches the
    /// row's 'UTC' default, so only the empty-row rule can trigger the upload.
    func testAProfileEnteredBeforeSignInSeedsTheEmptyRow() async throws {
        defaultZone = NSTimeZone.default
        NSTimeZone.default = try XCTUnwrap(TimeZone(identifier: "UTC"))
        let (_, identity) = try await signedInPhone("seed")
        let coach = CoachAPI(endpoint: { [coachEndpoint] in coachEndpoint }, identity: { identity })

        let untouched = try await coach.profile()
        XCTAssertEqual(untouched?.timezone, "UTC", "the route returns the sign-up row as a profile")
        XCTAssertEqual(untouched?.hasSavedFields, false)

        UserDefaults.standard.set("UTC", forKey: "profile.timezone")
        UserDefaults.standard.set(66.0, forKey: "profile.weightKg")
        UserDefaults.standard.set(158.0, forKey: "profile.heightCm")
        let phone = ProfileStore()
        XCTAssertFalse(phone.cloudDirty)
        await profileSync(phone, coach).reconcile()

        let row = try await storedProfile(identity.ownerId)
        XCTAssertEqual((row["weight_kg"] as? NSNumber)?.doubleValue, 66)
        XCTAssertEqual((row["height_cm"] as? NSNumber)?.doubleValue, 158)
        XCTAssertEqual(phone.weightKg, 66, "the empty row did not overwrite the phone")
    }

    /// Settings → alerts, haptics and the Sana switch reach the account's `user_settings` row through the
    /// `coach` function's settings route, and a fresh install shows them again. The row sign-up created holds
    /// column defaults ('imperial'), which must not read as anyone's choice, and a key another client keeps in
    /// `extra_settings` survives the write.
    func testAccountSettingsAreStoredAndRestoredOnAFreshInstall() async throws {
        let (_, identity) = try await signedInPhone("settings")
        let coach = CoachAPI(endpoint: { [coachEndpoint] in coachEndpoint }, identity: { identity })
        let owner = "user_id=eq.\(identity.ownerId)"
        let signUpRows = try await server.rows("user_settings", "\(owner)&select=units")
        let signUpRow = try XCTUnwrap(signUpRows.first, "sign-up creates the user_settings row")
        XCTAssertEqual(signUpRow["units"] as? String, "imperial")
        let untouched = try await coach.settings()
        XCTAssertNil(untouched, "column defaults are not a saved choice")
        _ = try await server.patch("user_settings", owner, ["extra_settings": ["wear_location": "wrist"]])

        func sync(_ defaults: UserDefaults) -> SettingsCloudSync {
            SettingsCloudSync(defaults: defaults, throttle: 3600, isAvailable: { true }, owner: { identity.ownerId },
                              fetch: { try await coach.settings() }, save: { try await coach.saveSettings($0) })
        }
        let suites = ["phone", "reinstalled"].map { "nara-e2e-settings-\($0)-\(UUID().uuidString)" }
        defer { suites.forEach { UserDefaults.standard.removePersistentDomain(forName: $0) } }
        let phone = try XCTUnwrap(UserDefaults(suiteName: suites[0]))
        phone.set(false, forKey: "noop.coachEnabled")
        phone.set(false, forKey: BehaviorStore.K.batteryAlerts)
        phone.set(true, forKey: BehaviorStore.K.zoneCoaching)
        phone.set(40, forKey: InactivityPrefs.K.threshold)
        phone.set(false, forKey: HapticPrefs.liftRest)
        await sync(phone).reconcile()

        let rows = try await server.rows("user_settings", "\(owner)&select=units,extra_settings")
        let row = try XCTUnwrap(rows.first)
        XCTAssertEqual(row["units"] as? String, "imperial", "units is not carried: the column keeps its default")
        let extra = try XCTUnwrap(row["extra_settings"] as? [String: Any])
        XCTAssertEqual(extra["wear_location"] as? String, "wrist", "another client's key is left alone")
        let saved = try XCTUnwrap(extra["nara"] as? [String: Any])
        XCTAssertNil(saved["units"], "there is no unit choice to save")
        XCTAssertEqual(saved["sanaEnabled"] as? Bool, false)
        XCTAssertEqual(saved["batteryAlerts"] as? Bool, false)
        XCTAssertEqual(saved["zoneCoaching"] as? Bool, true)
        XCTAssertEqual(saved["moveReminderMinutes"] as? Int, 40)
        XCTAssertEqual(saved["hapticLiftRest"] as? Bool, false)
        XCTAssertEqual(saved.count, 5, "only what the phone stored")

        // A fresh install: an empty preferences domain, so Settings starts from its defaults.
        let reinstalled = try XCTUnwrap(UserDefaults(suiteName: suites[1]))
        await sync(reinstalled).reconcile()
        XCTAssertEqual(reinstalled.object(forKey: "noop.coachEnabled") as? Bool, false)
        XCTAssertEqual(reinstalled.object(forKey: BehaviorStore.K.batteryAlerts) as? Bool, false)
        XCTAssertEqual(reinstalled.object(forKey: BehaviorStore.K.zoneCoaching) as? Bool, true)
        XCTAssertEqual(reinstalled.object(forKey: InactivityPrefs.K.threshold) as? Int, 40)
        XCTAssertEqual(reinstalled.object(forKey: HapticPrefs.liftRest) as? Bool, false)

        // An edit on the reinstalled phone travels back, and the first phone picks it up.
        reinstalled.set(30, forKey: InactivityPrefs.K.threshold)
        await sync(reinstalled).syncIfChanged()
        await sync(phone).reconcile()
        XCTAssertEqual(phone.object(forKey: InactivityPrefs.K.threshold) as? Int, 30)
        let afterRows = try await server.rows("user_settings", "\(owner)&select=extra_settings")
        let afterExtra = try XCTUnwrap(afterRows.first?["extra_settings"] as? [String: Any])
        let afterSaved = try XCTUnwrap(afterExtra["nara"] as? [String: Any])
        XCTAssertEqual(afterSaved["moveReminderMinutes"] as? Int, 30)
    }

    /// Settings → Wear placement reaches `placement_intervals`, and a reinstall reads it back.
    func testWearPlacementIsStoredAndRestoredOnAFreshInstall() async throws {
        let (_, identity) = try await signedInPhone("placement")
        let scores = env.scoresEndpoint
        func cloudSync(_ store: PlacementStore) -> PlacementCloudSync {
            PlacementCloudSync(endpoint: { scores }, identity: { identity }, store: { store })
        }

        let whoop = try await WhoopStore.inMemory()
        let local = try PlacementStore(dbQueue: whoop.registryWriter)
        try local.setCurrent(.bicep, deviceId: nil)
        let uploaded = try await cloudSync(local).pushPending()
        XCTAssertEqual(uploaded, 1)
        XCTAssertTrue(try local.pendingChanges().isEmpty, "the accepted change is marked synced")

        let rows = try await server.rows("placement_intervals",
                                         "owner=eq.\(identity.ownerId)&select=placement,effective_end")
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?["placement"] as? String, "bicep")
        XCTAssertTrue(rows.first?["effective_end"] is NSNull, "the declaration is open-ended")

        let fresh = try PlacementStore(dbQueue: try await WhoopStore.inMemory().registryWriter)
        XCTAssertEqual(try fresh.activePlacement(at: Date(), deviceId: nil)?.placement, nil)
        _ = try await cloudSync(fresh).reconcile()
        XCTAssertEqual(try fresh.activePlacement(at: Date(), deviceId: nil)?.placement, .bicep)

        // A correction replaces the open interval rather than stacking a second open one.
        try fresh.setCurrent(.wrist, deviceId: nil)
        _ = try await cloudSync(fresh).pushPending()
        let after = try await server.rows("placement_intervals",
                                          "owner=eq.\(identity.ownerId)&effective_end=is.null&select=placement")
        XCTAssertEqual(after.map { $0["placement"] as? String }, ["wrist"])
    }

    /// The app declares placement for the strap it is reading (`repo.deviceId`), so the round trip has to
    /// come back under that same id: a reinstall looks the placement up by it. Covers both ids the server
    /// answers with: the installation-scoped one, and the strap's own `whoop-<serial>` once it is confirmed.
    func testStrapPlacementComesBackUnderTheStrapsOwnId() async throws {
        let (phone, identity) = try await signedInPhone("strap")
        let strap = "e2e-place-strap"
        let serial = "E2E-P-\(Int.random(in: 1000...9999))"
        let end = Int(Date().timeIntervalSince1970) - 60
        _ = try await phone.capture(E2EPhone.liveRecords(bpm: 62, rrPattern: [960, 980], seconds: 30,
                                                         endingAt: end, deviceId: strap))
        let scores = env.scoresEndpoint
        func cloudSync(_ store: PlacementStore, cloudId: String) -> PlacementCloudSync {
            PlacementCloudSync(endpoint: { scores }, identity: { identity }, store: { store },
                               localDevices: { [.init(local: strap, cloud: cloudId)] })
        }

        // Before the serial is known the server files the strap under this installation.
        let local = try PlacementStore(dbQueue: try await WhoopStore.inMemory().registryWriter)
        try local.setCurrent(.wrist, deviceId: strap)
        let uploaded = try await cloudSync(local, cloudId: strap).pushPending()
        XCTAssertEqual(uploaded, 1, "the strap is registered, so the device-scoped declaration is accepted")
        let fresh = try PlacementStore(dbQueue: try await WhoopStore.inMemory().registryWriter)
        _ = try await cloudSync(fresh, cloudId: strap).reconcile()
        XCTAssertEqual(try fresh.activePlacement(at: Date(), deviceId: strap)?.placement, .wrist)

        // Once the strap's serial is confirmed, the server answers with its canonical device.
        let confirmed = await phone.controller.confirmWearableIfNeeded(provisionalDeviceId: strap, serial: serial)
        XCTAssertTrue(confirmed)
        try local.setCurrent(.bicep, deviceId: strap)
        _ = try await cloudSync(local, cloudId: "whoop-\(serial)").pushPending()
        let canonicalRows = try await server.rows("placement_intervals",
                                                  "owner=eq.\(identity.ownerId)&effective_end=is.null&select=placement,device_id")
        XCTAssertTrue(canonicalRows.contains { ($0["placement"] as? String) == "bicep" })
        let reinstalled = try PlacementStore(dbQueue: try await WhoopStore.inMemory().registryWriter)
        _ = try await cloudSync(reinstalled, cloudId: "whoop-\(serial)").reconcile()
        XCTAssertEqual(try reinstalled.activePlacement(at: Date(), deviceId: strap)?.placement, .bicep,
                       "the canonical device maps back to the phone's own id")
    }
}

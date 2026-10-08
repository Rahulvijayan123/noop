import XCTest
@testable import Strand

/// The Settings rules that do not need a screen: which page each row opens, what the rows say, which wear
/// placements can be declared, and when the profile is handed to the cloud.
@MainActor
final class SettingsCleanupTests: XCTestCase {
    private let profileKeys = ["profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
                               "profile.heightCm", "profile.displayName", "profile.cloudDirty", "profile.timezone",
                               "profile.timezoneHistory"]

    override func setUp() { profileKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { profileKeys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    // MARK: Automations pages

    func testEachAutomationsPageShowsOnlyItsOwnTopic() {
        for page in AutomationsView.Page.allCases {
            XCTAssertEqual(AutomationsView.pages(for: page), [page])
        }
        // The macOS sidebar entry (no page) shows all of them, each once, in order.
        XCTAssertEqual(AutomationsView.pages(for: nil), [.alerts, .shortcuts, .haptics, .healthInsights])
    }

    func testDoubleTapPickerNeverOffersLockOnIPhone() {
        #if os(iOS)
        XCTAssertFalse(AutomationsView.doubleTapOptions.contains(.lockScreen))
        #else
        XCTAssertTrue(AutomationsView.doubleTapOptions.contains(.lockScreen))
        #endif
        XCTAssertTrue(AutomationsView.doubleTapOptions.contains(.none))
    }

    // MARK: Row values

    func testDoubleTapRowSaysWhatTheGestureDoes() {
        XCTAssertEqual(SettingsView.doubleTapValue(.none), "Off")
        XCTAssertEqual(SettingsView.doubleTapValue(.runShortcut), "Shortcut")
        XCTAssertEqual(SettingsView.doubleTapValue(.markMoment), MacActionKind.markMoment.label)
    }

    func testStrapRowUsesThePairPageWordingAndALiveBatteryOnly() {
        let paired = StrapLinkInputs(connected: true, bonded: true, encryptedBond: true, batteryPct: 64.4)
        XCTAssertEqual(SettingsView.strapRowValue(paired), "Connected · 64%")

        // A disconnected strap keeps its last battery reading; the row must not present it as current.
        let away = StrapLinkInputs(connected: false, bonded: true, batteryPct: 64, knownStrap: true)
        XCTAssertEqual(SettingsView.strapRowValue(away), "Not connected")

        let never = StrapLinkInputs()
        XCTAssertEqual(SettingsView.strapRowValue(never), "No strap connected")
        for link in [paired, away, never] {
            let value = SettingsView.strapRowValue(link)
            XCTAssertFalse(value.localizedCaseInsensitiveContains("bond"), "no protocol wording: \(value)")
            XCTAssertFalse(value.localizedCaseInsensitiveContains("charg"), value)
        }
    }

    func testVersionRowShowsTheBundleVersion() {
        XCTAssertTrue(SettingsView.versionLabel.hasPrefix(UpdateWatch.installedVersion))
    }

    // MARK: Wear placement

    func testOnlyRealPlacementsCanBeDeclared() {
        XCTAssertEqual(PlacementChoices.options, [.wrist, .bicep, .other])
        XCTAssertFalse(PlacementChoices.options.contains(.unknown),
                       "Unknown is unannotated history; offering it showed a checkmark that saved nothing")
    }

    func testServerPlacementDevicesMapBackToThePhonesOwnIds() {
        let source = "2E05F682-900F-47BA-AA96-484931C51678"
        let devices = [PlacementCloudSync.LocalDevice(local: "my-whoop", cloud: "whoop-4A1B2C3D")]
        func local(_ id: String?) -> String? {
            PlacementCloudSync.localDeviceId(forServer: id, sourceId: source, localDevices: devices)
        }
        XCTAssertEqual(local("installation:2e05f682-900f-47ba-aa96-484931c51678:my-whoop"), "my-whoop")
        XCTAssertEqual(local("whoop-4A1B2C3D"), "my-whoop", "the strap's canonical device is this phone's strap")
        XCTAssertNil(local(nil), "a user-level placement stays user-level")
        XCTAssertEqual(local("installation:00000000-0000-4000-8000-000000000000:my-whoop"),
                       "installation:00000000-0000-4000-8000-000000000000:my-whoop",
                       "another installation's device is not this phone's")
        XCTAssertEqual(local("whoop-OTHER123"), "whoop-OTHER123")
    }

    func testALaterDeclarationUnderTheStrapsOtherDeviceEndsTheEarlierOne() {
        let t0 = Date(timeIntervalSince1970: 1_790_000_000)
        let t1 = t0.addingTimeInterval(3600)
        let wrist = PlacementInterval(deviceId: "my-whoop", placement: .wrist, effectiveStart: t0, effectiveEnd: nil)
        let bicep = PlacementInterval(deviceId: "my-whoop", placement: .bicep, effectiveStart: t1, effectiveEnd: nil)
        let merged = PlacementCloudSync.oneAtATime([bicep, wrist])
        XCTAssertEqual(merged.map(\.placement), [.wrist, .bicep])
        XCTAssertEqual(merged[0].effectiveEnd, t1, "the newer declaration closes the older open one")
        XCTAssertNil(merged[1].effectiveEnd)
        XCTAssertEqual(merged.first { $0.contains(t1.addingTimeInterval(60)) }?.placement, .bicep)

        let closed = PlacementInterval(deviceId: "my-whoop", placement: .wrist, effectiveStart: t0,
                                       effectiveEnd: t0.addingTimeInterval(60))
        XCTAssertEqual(PlacementCloudSync.oneAtATime([closed, bicep])[0].effectiveEnd, t0.addingTimeInterval(60),
                       "an interval that already ended keeps its end")
    }

    // MARK: Profile → Supabase

    private final class FakeCloud {
        var stored: CloudProfile?
        var saves: [CloudProfile] = []
    }

    private func sync(_ store: ProfileStore, _ cloud: FakeCloud) -> ProfileCloudSync {
        ProfileCloudSync(profile: store, debounce: 3600, isAvailable: { true },
                         fetch: { cloud.stored },
                         save: { cloud.saves.append($0); cloud.stored = $0 })
    }

    /// The `profiles` row exists from sign-up with only `timezone` set (NOT NULL, default 'UTC'), and the
    /// route returns it. On a phone whose zone matches, nothing used to trigger the upload, so a profile
    /// entered before signing in never reached the server that scores with it.
    func testAProfileIsSeededIntoTheEmptyRowSignUpCreates() async {
        let zone = TimeZone.current.identifier
        UserDefaults.standard.set(zone, forKey: "profile.timezone")
        UserDefaults.standard.set(64.5, forKey: "profile.weightKg")
        UserDefaults.standard.set("female", forKey: "profile.sex")
        let cloud = FakeCloud()
        cloud.stored = CloudProfile(displayName: "", timezone: zone)
        let store = ProfileStore()
        XCTAssertFalse(store.cloudDirty, "values saved before sync existed are not an edit")

        await sync(store, cloud).reconcile()

        XCTAssertEqual(cloud.saves.count, 1)
        XCTAssertEqual(cloud.saves.first?.weightKg, 64.5)
        XCTAssertEqual(cloud.saves.first?.sex, "female")
        XCTAssertEqual(store.weightKg, 64.5, "the empty row must not wipe the local values")
    }

    func testAnEmptyRowAndAnUntouchedPhoneExchangeNothing() async {
        let zone = TimeZone.current.identifier
        UserDefaults.standard.set(zone, forKey: "profile.timezone")
        let cloud = FakeCloud()
        cloud.stored = CloudProfile(displayName: "", timezone: zone)
        await sync(ProfileStore(), cloud).reconcile()
        XCTAssertTrue(cloud.saves.isEmpty, "defaults are never uploaded")
    }

    func testASavedCloudProfileStillWinsOnAFreshInstall() async {
        let zone = TimeZone.current.identifier
        UserDefaults.standard.set(zone, forKey: "profile.timezone")
        let cloud = FakeCloud()
        cloud.stored = CloudProfile(displayName: "Ana", dateOfBirth: "1992-05-06", sex: "female",
                                    heightCm: 168, weightKg: 59, timezone: zone)
        let store = ProfileStore()
        await sync(store, cloud).reconcile()
        XCTAssertTrue(cloud.saves.isEmpty)
        XCTAssertEqual(store.displayName, "Ana")
        XCTAssertEqual(store.heightCm, 168)
    }

    func testSavedFieldsAreReadFromTheFieldsNotTheRow() {
        XCTAssertFalse(CloudProfile(displayName: "", timezone: "UTC").hasSavedFields)
        XCTAssertTrue(CloudProfile(displayName: "Ana").hasSavedFields)
        XCTAssertTrue(CloudProfile(displayName: "", weightKg: 70).hasSavedFields)
        XCTAssertTrue(CloudProfile(displayName: "", dateOfBirth: "1990-01-01").hasSavedFields)
    }
}

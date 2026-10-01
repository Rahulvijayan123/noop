import XCTest
@testable import Strand

/// The Settings profile (name, date of birth, sex, height, weight) round-trips through the cloud profile:
/// edits upload once, a clean install adopts what the cloud holds, and nothing is lost when the network is.
@MainActor
final class ProfileCloudSyncTests: XCTestCase {
    private let keys = ["profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
                        "profile.heightCm", "profile.displayName", "profile.cloudDirty"]

    override func setUp() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    private final class FakeCloud {
        var stored: CloudProfile?
        var saves: [CloudProfile] = []
        var failing = false
    }

    private func sync(_ store: ProfileStore, _ cloud: FakeCloud) -> ProfileCloudSync {
        // A one-hour debounce keeps the observer out of the way: each test drives the sync directly.
        ProfileCloudSync(profile: store, debounce: 3600, isAvailable: { true },
                         fetch: { cloud.stored },
                         save: {
                             if cloud.failing { throw CoachAPIError.unavailable }
                             cloud.saves.append($0)
                             cloud.stored = $0
                         })
    }

    func testFreshInstallAdoptsTheCloudProfile() async {
        let cloud = FakeCloud()
        cloud.stored = CloudProfile(displayName: "Rahul", dateOfBirth: "1990-04-12", sex: "female",
                                    heightCm: 165, weightKg: 58.5)
        let store = ProfileStore()
        await sync(store, cloud).reconcile()

        XCTAssertEqual(store.displayName, "Rahul")
        XCTAssertEqual(ProfileStore.dayString(store.dateOfBirth), "1990-04-12")
        XCTAssertEqual(store.sex, "female")
        XCTAssertEqual(store.heightCm, 165)
        XCTAssertEqual(store.weightKg, 58.5)
        XCTAssertFalse(store.cloudDirty, "loading the profile is not a user edit")
        XCTAssertTrue(cloud.saves.isEmpty)
    }

    func testAnEditUploadsOnceAndClearsTheFlag() async {
        let cloud = FakeCloud()
        let store = ProfileStore()
        let engine = sync(store, cloud)
        XCTAssertFalse(store.cloudDirty)

        store.weightKg = 81.25
        XCTAssertTrue(store.cloudDirty)
        await engine.pushIfDirty()
        await engine.pushIfDirty()

        XCTAssertEqual(cloud.saves.count, 1)
        XCTAssertEqual(cloud.saves.first?.weightKg, 81.25)
        XCTAssertFalse(store.cloudDirty)
    }

    func testAnUnsyncedEditIsNotOverwrittenByTheCloud() async {
        let cloud = FakeCloud()
        cloud.stored = CloudProfile(displayName: "Old", dateOfBirth: "1980-01-01", sex: "male",
                                    heightCm: 170, weightKg: 70)
        let store = ProfileStore()
        store.heightCm = 190
        await sync(store, cloud).reconcile()

        XCTAssertEqual(store.heightCm, 190)
        XCTAssertEqual(cloud.stored?.heightCm, 190)
        XCTAssertFalse(store.cloudDirty)
    }

    func testAFailedUploadStaysQueuedUntilItSucceeds() async {
        let cloud = FakeCloud()
        cloud.failing = true
        let store = ProfileStore()
        let engine = sync(store, cloud)

        store.displayName = "Rahul"
        await engine.pushIfDirty()
        XCTAssertTrue(store.cloudDirty)

        cloud.failing = false
        await engine.reconcile()
        XCTAssertEqual(cloud.saves.last?.displayName, "Rahul")
        XCTAssertFalse(store.cloudDirty)
    }

    func testAProfileEnteredBeforeSyncExistedIsUploaded() async {
        UserDefaults.standard.set(62.5, forKey: "profile.weightKg")
        let cloud = FakeCloud()
        let store = ProfileStore()
        await sync(store, cloud).reconcile()

        XCTAssertEqual(cloud.saves.count, 1)
        XCTAssertEqual(cloud.saves.first?.weightKg, 62.5)
    }

    func testDefaultsAreNeverUploaded() async {
        let cloud = FakeCloud()
        await sync(ProfileStore(), cloud).reconcile()
        XCTAssertTrue(cloud.saves.isEmpty)
    }

    func testBirthDayRoundTripsThroughTheWireFormat() throws {
        let date = try XCTUnwrap(ProfileStore.day(from: "1990-04-12"))
        XCTAssertEqual(ProfileStore.dayString(date), "1990-04-12")
    }
}

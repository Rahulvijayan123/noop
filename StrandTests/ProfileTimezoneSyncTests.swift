import XCTest
@testable import Strand

/// The reporting timezone (spec §3 / contract C2) travels with the cloud profile: the payload carries
/// the phone's IANA zone on every upload, a server zone that disagrees with the phone is pushed over
/// (never adopted — the phone is the timezone authority), a matching server zone is left alone, and a
/// stale/refreshed zone marks the profile dirty so the next sync propagates it.
@MainActor
final class ProfileTimezoneSyncTests: XCTestCase {
    private let keys = ["profile.dateOfBirth", "profile.age", "profile.sex", "profile.weightKg",
                        "profile.heightCm", "profile.displayName", "profile.cloudDirty", "profile.timezone"]

    override func setUp() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
    override func tearDown() { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }

    private final class FakeCloud {
        var stored: CloudProfile?
        var saves: [CloudProfile] = []
    }

    private func sync(_ store: ProfileStore, _ cloud: FakeCloud) -> ProfileCloudSync {
        ProfileCloudSync(profile: store, debounce: 3600, isAvailable: { true },
                         fetch: { cloud.stored },
                         save: { cloud.saves.append($0); cloud.stored = $0 })
    }

    /// Every upload carries the device's IANA zone id, so a single profile sync seeds `profiles.timezone`
    /// with the same zone the phone scores local days in.
    func testTheUploadedPayloadCarriesTheDevicesTimezone() async {
        let cloud = FakeCloud()
        let store = ProfileStore()
        store.displayName = "Rahul"
        await sync(store, cloud).pushIfDirty()

        XCTAssertEqual(cloud.saves.last?.timezone, TimeZone.current.identifier)
        XCTAssertEqual(cloud.saves.last?.timezone, store.cloudSnapshot.timezone)
    }

    /// A server zone that disagrees with the phone is PUSHED OVER, never adopted: the phone is the
    /// timezone authority, so a stored 'UTC' default (or a stale travel value) must not decide the
    /// user's day ownership.
    func testAServerTimezoneThatDisagreesIsPushedOverNotAdopted() async {
        let cloud = FakeCloud()
        cloud.stored = CloudProfile(displayName: "", dateOfBirth: nil, sex: nil,
                                    heightCm: nil, weightKg: nil, timezone: "UTC")
        let store = ProfileStore()
        await sync(store, cloud).reconcile()

        XCTAssertEqual(store.timezone, TimeZone.current.identifier, "the phone zone must survive")
        XCTAssertEqual(cloud.saves.last?.timezone, TimeZone.current.identifier,
                       "a conflicting server zone must be pushed over, not adopted")
        XCTAssertFalse(store.cloudDirty)
    }

    /// A server zone that already matches the phone triggers no upload and no dirty flag.
    func testMatchingServerTimezoneIsNotReUploaded() async {
        let cloud = FakeCloud()
        cloud.stored = CloudProfile(displayName: "Rahul", dateOfBirth: "1990-04-12", sex: "male",
                                    heightCm: 178, weightKg: 75, timezone: TimeZone.current.identifier)
        let store = ProfileStore()
        await sync(store, cloud).reconcile()

        XCTAssertTrue(cloud.saves.isEmpty, "nothing to sync when the cloud already holds the phone zone")
        XCTAssertEqual(store.timezone, TimeZone.current.identifier)
        XCTAssertFalse(store.cloudDirty)
    }

    /// The zone is refreshed from the device at profile sync: a stale persisted zone is reverted and
    /// the corrected value reaches the cloud (travel propagation).
    func testRefreshFromDeviceRevertsAStaleZoneAndUploads() async {
        let cloud = FakeCloud()
        let store = ProfileStore()
        store.timezone = "Asia/Tokyo"   // a stale zone (e.g. from an earlier location)
        await sync(store, cloud).reconcile()

        XCTAssertEqual(store.timezone, TimeZone.current.identifier)
        XCTAssertEqual(cloud.saves.last?.timezone, TimeZone.current.identifier,
                       "the refreshed zone must reach the cloud")
        XCTAssertFalse(store.cloudDirty)
    }
}

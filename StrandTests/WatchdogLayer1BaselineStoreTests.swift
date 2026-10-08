import XCTest
import StrandAnalytics
@testable import Strand

/// WP8 app wiring of the Layer 1 awake tape and IMU usual in `BaselineStore`: device-era binding,
/// one-time adoption of the pre-scope blob, strap swap archive, unbound never writes, persisted
/// skips, and `resetCourse` clearing the scoped keys.
@MainActor
final class WatchdogLayer1BaselineStoreTests: XCTestCase {
    private let base = 98_000_000 - 98_000_000 % 60
    private let scopedTape = LBDeviceScope.tapePrefix + "my-whoop"
    private let scopedImu = LBDeviceScope.imuPrefix + "my-whoop"

    private func suite() throws -> UserDefaults {
        let name = "wp8-layer1-\(UUID().uuidString)"
        let d = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return d
    }

    private func stillWindow(now: Int, hr: Double = 62) throws -> WatchdogWindow {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: 44, temp: 33.0, resp: 14,
                                          motion: 0, stepsPerMin: 0)
        feed.motion = []
        feed.imu = (now - WatchdogConfig.contextSeconds..<now).map {
            WatchdogIMUSample(ts: $0, x: 0, y: 0, z: 1, dynAccel: 0.01)
        }
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            throw XCTSkip("window did not build")
        }
        return win
    }

    private func scopedTapeRows(_ d: UserDefaults, key: String? = nil) throws -> LBDeviceScopedRows<LBDayTape> {
        let data = try XCTUnwrap(d.data(forKey: key ?? scopedTape))
        return try JSONDecoder().decode(LBDeviceScopedRows<LBDayTape>.self, from: data)
    }

    func testLegacyTapeIsAdoptedStampedThenArchivedOnStrapSwap() throws {
        let d = try suite()
        var legacy = LBDayTape(day: "2026-10-01")
        for k in 0..<10 { legacy.restHR.addUnique(value: 61, minuteUnix: base - 86_400 + k * 60) }
        d.set(try JSONEncoder().encode([legacy]), forKey: "noop.baseline.daytape.v2")
        let store = BaselineStore(defaults: d)

        store.bindLayer1Tapes(deviceId: "my-whoop", strapSerial: nil)
        var rows = try scopedTapeRows(d)
        XCTAssertEqual(rows.rows.map(\.day), ["2026-10-01"], "history survives the update")
        XCTAssertNil(rows.strapSerial)
        XCTAssertEqual(BaselineStore(defaults: d).observations(from: [], series: .awakeRestHR).count, 1,
                       "relaunch before the next tick reads the bound device's adopted rows")

        // Learning the serial stamps the same era and keeps the history.
        store.bindLayer1Tapes(deviceId: "my-whoop", strapSerial: "A")
        rows = try scopedTapeRows(d)
        XCTAssertEqual(rows.strapSerial, "A")
        XCTAssertEqual(rows.rows.map(\.day), ["2026-10-01"])

        // A different strap under the same local id: old era archived, new era empty.
        store.bindLayer1Tapes(deviceId: "my-whoop", strapSerial: "B")
        rows = try scopedTapeRows(d)
        XCTAssertEqual(rows.strapSerial, "B")
        XCTAssertTrue(rows.rows.isEmpty)
        let archived = try scopedTapeRows(d, key: LBDeviceScope.archiveKey(
            prefix: LBDeviceScope.tapePrefix, deviceId: "my-whoop", serial: "A"))
        XCTAssertEqual(archived.rows.map(\.day), ["2026-10-01"])

        // The relaunch read path shows the bound era's rows, never the legacy blob again.
        XCTAssertNotNil(d.data(forKey: "noop.baseline.daytape.v2"))
        XCTAssertTrue(BaselineStore(defaults: d).observations(from: [], series: .awakeRestHR).isEmpty)
    }

    func testUnboundStoreNeverWritesLayer1Rows() throws {
        let d = try suite()
        let store = BaselineStore(defaults: d)
        let win = try stillWindow(now: base)
        store.ingestWatchdogTape(window: win, nowUnix: base, lastWorkoutEndUnix: 0)
        store.ingestImu(samples: win.imu, nowUnix: base)
        store.skipWatchdogTape(window: win, nowUnix: base)
        let written = d.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(LBDeviceScope.tapePrefix) || $0.hasPrefix(LBDeviceScope.imuPrefix)
                || $0.hasPrefix("noop.baseline.daytape") || $0.hasPrefix("noop.baseline.imu")
        }
        XCTAssertTrue(written.isEmpty, "\(written)")
    }

    func testBoundIngestPersistsAndRelaunchReadsIt() throws {
        let d = try suite()
        let store = BaselineStore(defaults: d)
        store.bindLayer1Tapes(deviceId: "my-whoop", strapSerial: "A")
        let win = try stillWindow(now: base)
        store.ingestWatchdogTape(window: win, nowUnix: base, lastWorkoutEndUnix: 0)
        store.ingestImu(samples: win.imu, nowUnix: base)
        XCTAssertEqual(store.observations(from: [], series: .awakeRestHR).count, 1)
        XCTAssertNotNil(d.data(forKey: scopedImu))
        let relaunched = BaselineStore(defaults: d)
        XCTAssertEqual(relaunched.observations(from: [], series: .awakeRestHR).count, 1)
        XCTAssertEqual(relaunched.observations(from: [], series: .wakingImuEnergy).count, 1)
    }

    func testSkipIsPersistedSoARelaunchCannotBackFillAlertMinutes() throws {
        let d = try suite()
        let store = BaselineStore(defaults: d)
        store.bindLayer1Tapes(deviceId: "my-whoop", strapSerial: "A")
        // An alerting tick may not train: its window is consumed, then the app is killed.
        let alerting = try stillWindow(now: base, hr: 120)
        store.skipWatchdogTape(window: alerting, nowUnix: base)
        let relaunched = BaselineStore(defaults: d)
        relaunched.bindLayer1Tapes(deviceId: "my-whoop", strapSerial: "A")
        // The first quiet tick after relaunch re-delivers the alert stretch in its window.
        let quiet = try stillWindow(now: base + 60, hr: 120)
        relaunched.ingestWatchdogTape(window: quiet, nowUnix: base + 60, lastWorkoutEndUnix: 0)
        relaunched.ingestImu(samples: quiet.imu, nowUnix: base + 60)
        XCTAssertTrue(relaunched.observations(from: [], series: .awakeRestHR).isEmpty,
                      "alerting minutes must not form an awake-rest day")
        let imu = relaunched.observations(from: [], series: .wakingImuEnergy)
        XCTAssertEqual(imu.count, 1)
        XCTAssertEqual(imu.first?.coverage, 1, "only the one new minute of IMU counts, not 30")
    }

    func testResetCourseClearsScopedAndArchivedKeys() throws {
        let d = try suite()
        let store = BaselineStore(defaults: d)
        store.bindLayer1Tapes(deviceId: "my-whoop", strapSerial: "A")
        let win = try stillWindow(now: base)
        store.ingestWatchdogTape(window: win, nowUnix: base, lastWorkoutEndUnix: 0)
        store.ingestImu(samples: win.imu, nowUnix: base)
        store.bindLayer1Tapes(deviceId: "my-whoop", strapSerial: "B")
        XCTAssertNotNil(d.data(forKey: LBDeviceScope.archiveKey(
            prefix: LBDeviceScope.tapePrefix, deviceId: "my-whoop", serial: "A")))
        _ = BaselineStore(defaults: d, resetCourse: true)
        let left = d.dictionaryRepresentation().keys.filter {
            $0.hasPrefix(LBDeviceScope.tapePrefix) || $0.hasPrefix(LBDeviceScope.imuPrefix)
                || $0 == "noop.baseline.layer1Device.v1"
        }
        XCTAssertTrue(left.isEmpty, "\(left)")
    }
}

import XCTest
import StrandAnalytics
@testable import Strand

/// The always-on raw motion capture that feeds HART, and the way HART's windows come back to the phone's
/// activity decoder.
final class ActivityImuCaptureTests: XCTestCase {

    // MARK: Capture policy

    private func at(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(1_791_158_400 + seconds)) }

    func testPartTimeRecordsTheFirstMinuteOfEveryThree() {
        for (offset, expected) in [(0, true), (59, true), (60, false), (179, false), (180, true), (240, false)] {
            XCTAssertEqual(ActivityImuCapture.wantsStream(mode: .partTime, now: at(offset), batteryPct: 80,
                                                          charging: false), expected, "offset \(offset)")
        }
    }

    func testContinuousAndOff() {
        XCTAssertTrue(ActivityImuCapture.wantsStream(mode: .continuous, now: at(100), batteryPct: 80, charging: false))
        XCTAssertFalse(ActivityImuCapture.wantsStream(mode: .off, now: at(0), batteryPct: 100, charging: true))
    }

    func testALowStrapBatteryReleasesTheStreamUnlessCharging() {
        XCTAssertFalse(ActivityImuCapture.wantsStream(mode: .continuous, now: at(0), batteryPct: 15, charging: false))
        XCTAssertTrue(ActivityImuCapture.wantsStream(mode: .continuous, now: at(0), batteryPct: 15, charging: true))
        XCTAssertTrue(ActivityImuCapture.wantsStream(mode: .continuous, now: at(0), batteryPct: 16, charging: false))
        XCTAssertFalse(ActivityImuCapture.wantsStream(mode: .continuous, now: at(0), batteryPct: 30, charging: false,
                                                      pauseBatteryPct: 30), "Power saving's threshold applies")
    }

    func testModeDefaultsToPartTimeAndPersists() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "activity-imu-\(UUID().uuidString)"))
        XCTAssertEqual(ActivityImuCapture.mode(defaults), .partTime)
        ActivityImuCapture.setMode(.continuous, defaults)
        XCTAssertEqual(ActivityImuCapture.mode(defaults), .continuous)
        defaults.set("garbage", forKey: ActivityImuCapture.modeKey)
        XCTAssertEqual(ActivityImuCapture.mode(defaults), .partTime)
    }

    func testActivityWindowsKeepAWeekOnly() {
        let policy = ImuRetentionPolicy.default.activityCapture
        XCTAssertEqual(policy.maxAgeDays, 7)
        XCTAssertEqual(policy.maxTotalBytes, ImuRetentionPolicy.default.maxTotalBytes)
        XCTAssertTrue(ActivityImuCapture.isActivityWindow(ActivityImuCapture.windowId(deviceId: "whoop-ABC")))
        XCTAssertFalse(ActivityImuCapture.isActivityWindow("raw-session-1"))
    }

    // MARK: Windows coming back

    private func makeStore() throws -> ActivityEncoderWindowStore {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-windows-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "activity-windows-\(UUID().uuidString)"))
        return ActivityEncoderWindowStore(directory: dir, defaults: defaults)
    }

    private let dayStart = 1_791_158_400   // 2026-10-05T00:00:00Z

    private func record(day: String, t0: Int, revision: String, starts: [Int]) throws -> ActivityEncoderWindowStore.DayRecord {
        let set = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "hart-wisdm-v0", windows: starts.map {
            ActivityWindowPrediction(startTs: t0 + $0, endTs: t0 + $0 + 4, label: .walking, probs: ["walking": 0.9])
        })
        let json = String(decoding: try JSONSerialization.data(withJSONObject: set.jsonObject(dayStart: t0)), as: UTF8.self)
        return .init(day: day, resultRevision: revision, encoderId: "hart", modelVersion: "hart-wisdm-v0",
                     windowsJSON: json)
    }

    func testStoredWindowsCoverALocalDayAcrossTwoUtcDays() throws {
        let store = try makeStore()
        let scope = ActivityEncoderWindowStore.Scope(ownerId: "owner-1", deviceId: "whoop-MGB0214654")
        store.setScope(scope)
        XCTAssertTrue(store.save(try record(day: "2026-10-05", t0: dayStart, revision: "7", starts: [100, 80_000]),
                                 scope: scope))
        XCTAssertTrue(store.save(try record(day: "2026-10-06", t0: dayStart + 86_400, revision: "3", starts: [3_600]),
                                 scope: scope))
        // A Pacific local day: 07:00Z to 07:00Z the next day.
        let local = try XCTUnwrap(store.windows(from: dayStart + 7 * 3600, to: dayStart + 31 * 3600))
        XCTAssertEqual(local.windows.map(\.startTs), [dayStart + 80_000, dayStart + 86_400 + 3_600])
        XCTAssertEqual(local.encoderId, "hart")
        XCTAssertEqual(store.revisions(days: ["2026-10-05", "2026-10-06", "2026-10-07"]),
                       ["2026-10-05": "7", "2026-10-06": "3"])
        XCTAssertFalse(store.save(try record(day: "2026-10-05", t0: dayStart, revision: "7", starts: [100, 80_000]),
                                  scope: scope), "the same day again is not a change")
    }

    func testAnotherAccountNeverSeesTheWindows() throws {
        let store = try makeStore()
        let mine = ActivityEncoderWindowStore.Scope(ownerId: "owner-1", deviceId: "whoop-A")
        store.setScope(mine)
        store.save(try record(day: "2026-10-05", t0: dayStart, revision: "1", starts: [100]), scope: mine)
        XCTAssertNotNil(store.windows(from: dayStart, to: dayStart + 86_400))
        store.setScope(.init(ownerId: "owner-2", deviceId: "whoop-A"))
        XCTAssertNil(store.windows(from: dayStart, to: dayStart + 86_400))
        XCTAssertFalse(store.save(try record(day: "2026-10-05", t0: dayStart, revision: "2", starts: [100]), scope: mine),
                       "a sync that finishes after the account changed must not write")
        store.reset()
        XCTAssertNil(store.windows(from: dayStart, to: dayStart + 86_400))
    }

    func testUtcDays() {
        XCTAssertEqual(ActivityEncoderWindowStore.utcDays(from: dayStart - 3_600, to: dayStart + 3_600),
                       ["2026-10-04", "2026-10-05"])
        XCTAssertEqual(ActivityEncoderWindowStore.utcDays(from: dayStart, to: dayStart + 86_400), ["2026-10-05"])
    }

    func testRouteResponseParsing() {
        let body: [String: Any] = ["days": [
            ["day": "2026-10-04", "result_revision": "7", "unchanged": true, "encoder_id": "hart",
             "model_version": "hart-wisdm-v0"],
            ["day": "2026-10-05", "result_revision": "12", "encoder_id": "hart", "model_version": "hart-wisdm-v0",
             "windows": ["format": "hart-windows-1", "t0": dayStart]],
            ["day": "2026-10-06"],   // no revision: dropped
        ]]
        let days = ServerScoreRepository.activityWindowsDays(from: body)
        XCTAssertEqual(days.map(\.day), ["2026-10-04", "2026-10-05"])
        XCTAssertTrue(days[0].unchanged)
        XCTAssertEqual(days[1].resultRevision, "12")
        XCTAssertNotNil(days[1].windowsJSON)
    }
}

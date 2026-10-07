import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// BW2 reliability: sensor-quality parsing, wear evidence beyond the window, device binding.
final class WatchdogQualityFeedTests: XCTestCase {

    // MARK: - Quality feed parsing

    func testV18SecondsParseSentinelBaselineAndSpO2() {
        let rows = [
            V18AuxSample(ts: 1, hrQualityFlags: 0x80, auxByte82: 97, opticalBaselineA: 40, opticalBaselineB: 41,
                         opticalAmpA: 60, opticalAmpB: 61),
            V18AuxSample(ts: 2, hrQualityFlags: 0x80, opticalAmpA: 128, opticalAmpB: 128),
            V18AuxSample(ts: 3, hrQualityFlags: 0x05, auxByte82: 255),
            V18AuxSample(ts: 4, opticalBaselineA: 0, opticalBaselineB: 0),
            V18AuxSample(ts: 5, rrCount: 2),
        ]
        let seconds = WatchdogQualityFeedBuilder.v18Seconds(rows)
        XCTAssertEqual(seconds.map(\.ts), [1, 2, 3, 4], "a record with no optical evidence is UNKNOWN, skipped")
        XCTAssertEqual(seconds.map(\.sentinel), [false, true, true, false])
        XCTAssertEqual(seconds.map(\.baselineZero), [false, false, false, true])
        XCTAssertEqual(seconds.map(\.spo2Pct), [97, nil, nil, nil])
    }

    func testEventParsing() {
        let events = [
            WhoopEvent(ts: 10, kind: "WRIST_OFF(10)", payload: [:]),
            WhoopEvent(ts: 20, kind: "WRIST_ON(9)", payload: [:]),
            WhoopEvent(ts: 20, kind: "WRIST_ON(9)", payload: [:]),
            WhoopEvent(ts: 30, kind: "BOOT(15)", payload: [:]),
            WhoopEvent(ts: 31, kind: "RTC_LOST(13)", payload: [:]),
            WhoopEvent(ts: 32, kind: "BLE_SYSTEM_RESET(43)", payload: [:]),
            WhoopEvent(ts: 33, kind: "SET_RTC(16)", payload: [:]),
            WhoopEvent(ts: 40, kind: "CH1_SATURATION_DETECTED(40)", payload: [:]),
            WhoopEvent(ts: 41, kind: "ACCELEROMETER_SATURATION_DETECTED(42)", payload: [:]),
            WhoopEvent(ts: 42, kind: "AFE_RESET(36)", payload: [:]),
            WhoopEvent(ts: 43, kind: "SHIP_MODE_BOOT(39)", payload: [:]),
        ]
        XCTAssertEqual(WatchdogQualityFeedBuilder.wristEvents(events),
                       [.init(ts: 10, on: false), .init(ts: 20, on: true)])
        XCTAssertEqual(WatchdogQualityFeedBuilder.resetEventTimes(events), [30, 31, 32])
        XCTAssertEqual(WatchdogQualityFeedBuilder.saturationEventTimes(events), [40, 41, 42])
    }

    func testChargingPrecedenceAndUnknown() {
        let now = 100_000
        XCTAssertNil(WatchdogQualityFeedBuilder.charging(battery: [], events: [], liveCharging: nil, nowUnix: now))
        XCTAssertEqual(WatchdogQualityFeedBuilder.charging(battery: [], events: [], liveCharging: true,
                                                           nowUnix: now), true)
        // A level row only speaks for an hour; an older one is no evidence.
        let stale = [BatterySample(ts: now - 2 * 3600, soc: 40, mv: nil, charging: true)]
        XCTAssertNil(WatchdogQualityFeedBuilder.charging(battery: stale, events: [], liveCharging: nil, nowUnix: now))
        let fresh = [BatterySample(ts: now - 600, soc: 40, mv: nil, charging: false),
                     BatterySample(ts: now - 300, soc: 41, mv: nil, charging: nil)]
        XCTAssertEqual(WatchdogQualityFeedBuilder.charging(battery: fresh, events: [], liveCharging: nil,
                                                           nowUnix: now), false)
        // An edge holds until the next one; the newer evidence wins.
        let edge = [WhoopEvent(ts: now - 5 * 3600, kind: "CHARGING_ON(7)", payload: [:])]
        XCTAssertEqual(WatchdogQualityFeedBuilder.charging(battery: [], events: edge, liveCharging: nil,
                                                           nowUnix: now), true)
        XCTAssertEqual(WatchdogQualityFeedBuilder.charging(battery: fresh, events: edge, liveCharging: nil,
                                                           nowUnix: now), false)
    }

    func testContactsAndPpgPassThroughWithConfidence() {
        let contacts = WatchdogQualityFeedBuilder.contacts([
            StandardHRContactSample(ts: 5, contact: .supportedNotDetected),
            StandardHRContactSample(ts: 2, contact: .unsupported),
        ])
        XCTAssertEqual(contacts, [.init(ts: 2, state: "unsupported"), .init(ts: 5, state: "supported_not_detected")])
        let ppg = WatchdogQualityFeedBuilder.ppgHr([PpgHrRow(ts: 3, bpm: 61.4, conf: 0.35),
                                                   PpgHrRow(ts: 1, bpm: 60.2, conf: 0.72)])
        XCTAssertEqual(ppg, [.init(ts: 1, bpm: 60.2, conf: 0.72), .init(ts: 3, bpm: 61.4, conf: 0.35)])
    }

    func testPlacementChecksBareAndInstallationScopesAndNeverDefaultsToWrist() {
        typealias Row = WatchdogQualityFeedBuilder.PlacementRow
        let rows = [
            Row(scope: "installation:aaa:my-whoop", placement: "wrist", effectiveStart: 0, effectiveEnd: nil,
                recordedAt: 100, revision: 1),
            Row(scope: "my-whoop", placement: "bicep", effectiveStart: 500, effectiveEnd: nil,
                recordedAt: 500, revision: 1),
            Row(scope: "installation:bbb:my-whoop", placement: "bicep", effectiveStart: 500, effectiveEnd: nil,
                recordedAt: 500, revision: 2),
            Row(scope: "installation:ccc:other-strap", placement: "other", effectiveStart: 0, effectiveEnd: nil,
                recordedAt: 900, revision: 1),
        ]
        XCTAssertEqual(WatchdogQualityFeedBuilder.placement(at: 200, rows: rows, deviceIds: ["my-whoop"]), "wrist")
        XCTAssertEqual(WatchdogQualityFeedBuilder.placement(at: 600, rows: rows, deviceIds: ["my-whoop"]), "bicep")
        XCTAssertNil(WatchdogQualityFeedBuilder.placement(at: 600, rows: rows, deviceIds: ["whoop-x"]))
        XCTAssertNil(WatchdogQualityFeedBuilder.placement(at: 600, rows: [], deviceIds: ["my-whoop"]))
        let unknown = [Row(scope: "my-whoop", placement: "unknown", effectiveStart: 0, effectiveEnd: nil,
                           recordedAt: 1, revision: 1)]
        XCTAssertNil(WatchdogQualityFeedBuilder.placement(at: 600, rows: unknown, deviceIds: ["my-whoop"]))
        // Active strap first: its own declaration wins over the canonical id's.
        let twoIds = [Row(scope: "whoop-a", placement: "wrist", effectiveStart: 0, effectiveEnd: nil,
                          recordedAt: 1, revision: 1)] + rows
        XCTAssertEqual(WatchdogQualityFeedBuilder.placement(at: 600, rows: twoIds,
                                                            deviceIds: ["whoop-a", "my-whoop"]), "wrist")
        XCTAssertFalse(WatchdogQualityFeedBuilder.scope("installation:x:my-whoop2", names: "my-whoop"))
    }

    func testCoverageAndHrSecondsAreOnTheWindowGrid() {
        let start = 10_000
        let end = start + 1_800
        // Minute 1: 60 s of 1000 ms beats. Minute 3: half. Minute 2: none, between beats → 0. Others: absent.
        var beats = (0..<60).map { RRInterval(ts: start + 60 + $0, rrMs: 1_000) }
        beats += (0..<30).map { RRInterval(ts: start + 180 + $0, rrMs: 1_000) }
        let coverage = WatchdogQualityFeedBuilder.rrCoverageByMinute(beats, startUnix: start, endUnix: end)
        XCTAssertEqual(coverage[start + 60] ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(coverage[start + 120] ?? -1, 0.0, accuracy: 1e-9)
        XCTAssertEqual(coverage[start + 180] ?? -1, 0.5, accuracy: 1e-9)
        XCTAssertNil(coverage[start])
        XCTAssertNil(coverage[start + 240])
        XCTAssertTrue(WatchdogQualityFeedBuilder.rrCoverageByMinute([], startUnix: start, endUnix: end).isEmpty)

        let hr = [HRSample(ts: start + 5, bpm: 60), HRSample(ts: start + 5, bpm: 61), HRSample(ts: start + 59, bpm: 60),
                  HRSample(ts: start + 61, bpm: 60), HRSample(ts: end, bpm: 60)]
        let seconds = WatchdogQualityFeedBuilder.hrSecondsByMinute(hr, startUnix: start, endUnix: end)
        XCTAssertEqual(seconds, [start: 2, start + 60: 1])
    }

    func testMissingDynAccelIsUnknownMotionOnWhoop5() {
        let imu = [WatchdogIMUSample(ts: 1, x: 0, y: 0, z: 1, dynAccel: nil),
                   WatchdogIMUSample(ts: 2, x: 0, y: 0, z: 1, dynAccel: 0.2)]
        let w5 = WatchdogQualityFeedBuilder.motionOccupancy(imu, family: .whoop5)
        XCTAssertEqual(w5, [WatchdogScalarSample(ts: 2, value: 0.5)])
        XCTAssertEqual(WatchdogQualityFeedBuilder.motionOccupancy(imu, family: nil).map(\.ts), [2])
        // WHOOP 4 gravity rows are raw g: the magnitude fallback still applies there.
        let w4 = WatchdogQualityFeedBuilder.motionOccupancy(
            [WatchdogIMUSample(ts: 1, x: 0, y: 0, z: 1.2, dynAccel: nil)], family: .whoop4)
        XCTAssertEqual(w4.first?.value ?? -1, 0.5, accuracy: 1e-9)
    }

    // MARK: - Wear evidence

    private func steadyHR(from: Int, to: Int) -> [HRSample] {
        stride(from: from, to: to, by: 1).map { HRSample(ts: $0, bpm: 64) }
    }

    func testOpenWristOffOlderThanTheWindowStillReadsOff() {
        let now = 1_000_000
        let off = [WatchdogQualityFeed.WristEvent(ts: now - 6 * 3600, on: false)]
        XCTAssertEqual(WatchdogWearEvidence.openWristOffTs(stored: off, live: [], hr: [], nowUnix: now), now - 6 * 3600)
        // A later WRIST_ON closes it.
        let closed = off + [.init(ts: now - 3600, on: true)]
        XCTAssertNil(WatchdogWearEvidence.openWristOffTs(stored: closed, live: [], hr: [], nowUnix: now))
        // So does five minutes of sustained heart rate after it.
        XCTAssertNil(WatchdogWearEvidence.openWristOffTs(stored: off, live: [],
                                                         hr: steadyHR(from: now - 4000, to: now - 3000), nowUnix: now))
        // A few scattered beats do not.
        let scattered = stride(from: now - 4000, to: now, by: 30).map { HRSample(ts: $0, bpm: 64) }
        XCTAssertNotNil(WatchdogWearEvidence.openWristOffTs(stored: off, live: [], hr: scattered, nowUnix: now))
        // Older than the 24 h lookback: no evidence (UNKNOWN), not off.
        let ancient = [WatchdogQualityFeed.WristEvent(ts: now - 25 * 3600, on: false)]
        XCTAssertNil(WatchdogWearEvidence.openWristOffTs(stored: ancient, live: [], hr: [], nowUnix: now))
        XCTAssertNil(WatchdogWearEvidence.openWristOffTs(stored: [], live: [], hr: [], nowUnix: now))
    }

    func testFreshLiveWristOffWinsOverAStoredOn() {
        let now = 2_000_000
        let stored = [WatchdogQualityFeed.WristEvent(ts: now - 600, on: true)]
        let live = [WatchdogQualityFeed.WristEvent(ts: now - 20, on: false)]
        XCTAssertEqual(WatchdogWearEvidence.openWristOffTs(stored: stored, live: live, hr: [], nowUnix: now), now - 20)
        // Same second OFF then ON: on.
        let reseat = [WatchdogQualityFeed.WristEvent(ts: now - 5, on: false), .init(ts: now - 5, on: true)]
        XCTAssertNil(WatchdogWearEvidence.openWristOffTs(stored: reseat, live: [], hr: [], nowUnix: now))
    }

    // MARK: - Device binding

    func testCarryMigrationRules() {
        typealias B = WatchdogDeviceBinding
        // Target already has state.
        XCTAssertNil(B.migrationSource(target: "whoop-a", previous: "my-whoop", targetHasState: true,
                                       previousHasState: true, previousStillRegistered: false,
                                       legacyHasState: true, legacyAlreadyMigrated: false))
        // Serial adoption moved the rows: follow them.
        XCTAssertEqual(B.migrationSource(target: "whoop-SER", previous: "whoop-uuid", targetHasState: false,
                                         previousHasState: true, previousStillRegistered: false,
                                         legacyHasState: true, legacyAlreadyMigrated: true), "whoop-uuid")
        // A different strap that is still registered does not inherit.
        XCTAssertNil(B.migrationSource(target: "whoop-b", previous: "whoop-a", targetHasState: false,
                                       previousHasState: true, previousStillRegistered: true,
                                       legacyHasState: true, legacyAlreadyMigrated: true))
        // The legacy "my-whoop" carry moves once.
        XCTAssertEqual(B.migrationSource(target: "whoop-a", previous: nil, targetHasState: false,
                                         previousHasState: false, previousStillRegistered: false,
                                         legacyHasState: true, legacyAlreadyMigrated: false), "my-whoop")
        XCTAssertNil(B.migrationSource(target: "whoop-a", previous: nil, targetHasState: false,
                                       previousHasState: false, previousStillRegistered: false,
                                       legacyHasState: true, legacyAlreadyMigrated: true))
        XCTAssertNil(B.migrationSource(target: "my-whoop", previous: nil, targetHasState: false,
                                       previousHasState: false, previousStillRegistered: false,
                                       legacyHasState: true, legacyAlreadyMigrated: false))
        XCTAssertEqual(B.stateKey(activeDeviceId: "  "), "my-whoop")
        XCTAssertEqual(B.stateKey(activeDeviceId: "whoop-a "), "whoop-a")
    }

    func testFamilyComesFromEvidenceAndIsNeverGuessed() {
        typealias B = WatchdogDeviceBinding
        // The legacy seeded row ("WHOOP") with nothing else: unknown.
        XCTAssertNil(B.whoopFamily(registryModel: "WHOOP", registryBrand: "WHOOP", holdsV18: false, rrChannels: []))
        XCTAssertNil(B.whoopFamily(registryModel: nil, registryBrand: nil, holdsV18: false, rrChannels: []))
        XCTAssertEqual(B.whoopFamily(registryModel: "WHOOP 5.0 / MG", registryBrand: "WHOOP", holdsV18: false,
                                     rrChannels: []), .whoop5)
        XCTAssertEqual(B.whoopFamily(registryModel: "4.0", registryBrand: "WHOOP", holdsV18: false,
                                     rrChannels: []), .whoop4)
        // v18 records prove a 5/MG even under a 4.0 label.
        XCTAssertEqual(B.whoopFamily(registryModel: "4.0", registryBrand: "WHOOP", holdsV18: true,
                                     rrChannels: []), .whoop5)
        XCTAssertEqual(B.whoopFamily(registryModel: "WHOOP", registryBrand: nil, holdsV18: false,
                                     rrChannels: [7]), .whoop5)
        XCTAssertEqual(B.whoopFamily(registryModel: "WHOOP", registryBrand: nil, holdsV18: false,
                                     rrChannels: [8, 10]), .whoop4)
        XCTAssertNil(B.whoopFamily(registryModel: "Ring 4", registryBrand: "Oura", holdsV18: false, rrChannels: [1]))
        // Temperature: unknown WHOOP stays unknown (no 4.0 formula on a 5.0 centidegree value); non-WHOOP is °C-scaled.
        XCTAssertNil(B.temperatureScale(whoopFamily: nil, registryBrand: "WHOOP"))
        XCTAssertEqual(B.temperatureScale(whoopFamily: nil, registryBrand: "Oura"), .whoop5)
        XCTAssertEqual(B.temperatureScale(whoopFamily: .whoop4, registryBrand: "WHOOP"), .whoop4)
    }
}

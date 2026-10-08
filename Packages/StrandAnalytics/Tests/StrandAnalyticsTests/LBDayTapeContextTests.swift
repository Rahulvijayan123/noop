import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// WP8: the Layer-1 awake day tape files every fresh minute once, by that minute's own civil day,
/// never files a minute without motion evidence as rest, and is scoped to one device era.
final class LBDayTapeContextTests: XCTestCase {
    private let base = 98_000_000 - 98_000_000 % 60

    private func window(now: Int, hr: Double = 62, motion: Double? = 0.02,
                        imuStill: Bool = false, stepsPerMin: Int = 0) throws -> WatchdogWindow {
        var feed = Watchdog.syntheticFeed(now: now, hr: hr, hrv: 44, temp: 33.0, resp: 14,
                                          motion: motion ?? 0, stepsPerMin: stepsPerMin)
        if motion == nil { feed.motion = [] }
        if imuStill {
            feed.imu = (now - WatchdogConfig.contextSeconds..<now).map {
                WatchdogIMUSample(ts: $0, x: 0, y: 0, z: 1, dynAccel: 0.01)
            }
        }
        guard case .success(let win) = WatchdogWindowBuilder.build(feed) else {
            throw XCTSkip("window did not build")
        }
        return win
    }

    private static let utc: TimeZone = TimeZone(identifier: "UTC")!
    private static func utcDay(_ unix: Int) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let c = cal.dateComponents([.year, .month, .day], from: Date(timeIntervalSince1970: TimeInterval(unix)))
        return String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
    }

    // MARK: No motion evidence (D6-02 / D4-V01)

    func testNoMotionEvidenceMinutesAreUnknownContextNotRest() throws {
        let win = try window(now: base, hr: 95, motion: nil)
        XCTAssertEqual(WatchdogActivityFeatures.motionEvidence(window: win), Array(repeating: false, count: 30))
        var tape = LBDayTape(day: "d")
        XCTAssertTrue(tape.ingest(window: win, nowUnix: base))
        XCTAssertEqual(tape.restHR.n, 0, "no IMU / steps / motion scalar is never rest")
        XCTAssertEqual(tape.restHRV.n, 0)
        XCTAssertEqual(tape.restSpO2.n, 0)
        XCTAssertEqual(tape.effortHR.n, 0)
        XCTAssertEqual(tape.unknownContextHR.n, 25, "settled minutes are kept for provenance only")
        XCTAssertEqual(tape.allHR.n, 30, "continuous HR still counts every fresh minute")
        XCTAssertNil(tape.observation(series: .awakeRestHR))
    }

    func testStillImuMinutesAreRest() throws {
        let win = try window(now: base, motion: nil, imuStill: true)
        var tape = LBDayTape(day: "d")
        tape.ingest(window: win, nowUnix: base)
        XCTAssertEqual(tape.restHR.n, 25)
        XCTAssertEqual(tape.unknownContextHR.n, 0)
        XCTAssertEqual(tape.restPosture, LBDayTape.restPosturePooledUnresolved)
    }

    func testWalkingMinutesAreEffortNotRest() throws {
        let win = try window(now: base, hr: 105, motion: 0.4, stepsPerMin: 60)
        var tape = LBDayTape(day: "d")
        tape.ingest(window: win, nowUnix: base)
        XCTAssertEqual(tape.restHR.n, 0)
        XCTAssertEqual(tape.effortHR.n, 25)
        XCTAssertEqual(tape.activeMinutes, 25)
    }

    // MARK: Every fresh minute, once (D4-07)

    func testOneWindowFilesEverySettledMinuteAndNextTickFilesTheRest() throws {
        var tape = LBDayTape(day: "d")
        tape.ingest(window: try window(now: base, imuStill: true), nowUnix: base)
        XCTAssertEqual(tape.restHR.n, 25, "30 fresh minutes minus the 5-minute settle, not 1 per tick")
        // Five minutes later the previously unsettled minutes are filed; overlap is not re-counted.
        tape.ingest(window: try window(now: base + 300, imuStill: true), nowUnix: base + 300)
        XCTAssertEqual(tape.restHR.n, 30)
        XCTAssertEqual(tape.allHR.n, 35)
        XCTAssertFalse(tape.ingest(window: try window(now: base + 300, imuStill: true), nowUnix: base + 300))
        XCTAssertEqual(tape.restHR.n, 30)
    }

    func testUnsettledMinuteIsNotJudgedBeforeItsMotionLands() throws {
        // At the first tick the newest minutes have no motion yet (gravity lags live HR).
        var early = try window(now: base, imuStill: true)
        let cut = base - 3 * 60
        early.imu = early.imu.filter { $0.ts < cut }
        early.motion = early.motion.enumerated().map { i, v in
            early.startUnix + i * 60 >= cut ? nil : v
        }
        var tape = LBDayTape(day: "d")
        tape.ingest(window: early, nowUnix: base)
        XCTAssertEqual(tape.unknownContextHR.n, 0, "minutes inside the settle horizon wait")
        XCTAssertEqual(tape.restHR.n, 25)
    }

    func testSkipThroughStopsAlertMinutesBackFillingRest() throws {
        var tapes: [String: LBDayTape] = [:]
        let day: (Int) -> String = { _ in "d" }
        LBDayTape.ingest(window: try window(now: base, imuStill: true), nowUnix: base,
                         into: &tapes, dayOf: day)
        XCTAssertEqual(tapes["d"]?.restHR.n, 25)
        // Ten alerting minutes are not allowed to train.
        let alerting = try window(now: base + 600, hr: 120, imuStill: true)
        LBDayTape.skipThrough(window: alerting, into: &tapes, dayOf: day)
        // The next quiet tick must not file those alerting minutes into rest.
        LBDayTape.ingest(window: try window(now: base + 660, hr: 120, imuStill: true),
                         nowUnix: base + 660, into: &tapes, dayOf: day)
        let tape = try XCTUnwrap(tapes["d"])
        XCTAssertEqual(tape.restHR.n, 25)
        XCTAssertEqual(tape.restHR.mean ?? 0, 62, accuracy: 1e-9)
    }

    func testSkipThroughReportsOnlyDaysWhoseWatermarksMoved() throws {
        var tapes: [String: LBDayTape] = [:]
        let day: (Int) -> String = { _ in "d" }
        let alerting = try window(now: base, hr: 120, imuStill: true)
        XCTAssertEqual(LBDayTape.skipThrough(window: alerting, into: &tapes, dayOf: day), ["d"])
        XCTAssertEqual(LBDayTape.skipThrough(window: alerting, into: &tapes, dayOf: day), [],
                       "nothing new to persist")
    }

    // MARK: Post-workout gate keys off live-tail effort, not fidget (review fix)

    /// Minute `i` with fidget-level IMU occupancy (~0.2): above the effort-bucket floor (0.15), below the
    /// live-tail effort line (chair-still 0.32), with no steps and a still label.
    private func fidget(_ win: inout WatchdogWindow, at i: Int) {
        var rows = win.resolvedActivityFeatures()
        rows[i][9] = 0.8
        win.activityFeatures = rows
    }

    func testOneFidgetMinuteDoesNotOpenAPostWorkoutGap() throws {
        var win = try window(now: base, imuStill: true)
        fidget(&win, at: 5)
        XCTAssertEqual(WatchdogActivityFeatures.priorOccupancy(win.activityFeatures[5]), 0.2, accuracy: 1e-9)
        XCTAssertEqual(WatchdogLiveTail.periods(win)[5], .rest)
        var tape = LBDayTape(day: "d")
        tape.ingest(window: win, nowUnix: base)
        XCTAssertEqual(tape.effortHR.n, 1, "the fidget minute itself still files as effort")
        XCTAssertEqual(tape.restHR.n, 24, "minutes 6-24 stay rest: a fidget is not a workout end")
    }

    func testRealEffortMinuteStillOpensThePostWorkoutGap() throws {
        var win = try window(now: base, imuStill: true)
        win.motion[5] = 0.4
        XCTAssertEqual(WatchdogLiveTail.periods(win)[5], .effort)
        var tape = LBDayTape(day: "d")
        tape.ingest(window: win, nowUnix: base)
        XCTAssertEqual(tape.effortHR.n, 1)
        XCTAssertEqual(tape.restHR.n, 5, "minutes 6-24 are recovering, in no bucket")
    }

    // MARK: Day keyed by the minute, not the tick (D4-07)

    func testMinutesBeforeMidnightLandOnTheEarlierDay() throws {
        // Tick at 00:10 UTC: 20 minutes of the window belong to the previous civil day.
        let midnight = 1_790_000_000 - 1_790_000_000 % 86_400
        let now = midnight + 600
        var tapes: [String: LBDayTape] = [:]
        let changed = LBDayTape.ingest(window: try window(now: now, imuStill: true), nowUnix: now,
                                       into: &tapes, dayOf: Self.utcDay)
        let before = Self.utcDay(midnight - 60)
        let after = Self.utcDay(midnight)
        XCTAssertEqual(changed, [before, after])
        XCTAssertEqual(tapes[before]?.restHR.n, 20, "23:40-23:59 stay on the day they were measured")
        XCTAssertEqual(tapes[before]?.allHR.n, 20)
        XCTAssertEqual(tapes[after]?.restHR.n, 5, "00:00-00:04 settled; 00:05-00:09 wait")
        XCTAssertEqual(tapes[after]?.allHR.n, 10)
    }

    func testTimeZoneChangeDoesNotFileAMinuteOnTwoDays() throws {
        // Tick at 00:20 UTC, then a westward hop (UTC-1h) one minute later: the same absolute minutes
        // now map to the previous local day, whose own watermark is older.
        let midnight = 1_790_000_000 - 1_790_000_000 % 86_400
        var tapes: [String: LBDayTape] = [:]
        let first = midnight + 1200
        LBDayTape.ingest(window: try window(now: first, imuStill: true), nowUnix: first,
                         into: &tapes, dayOf: Self.utcDay)
        XCTAssertEqual(tapes.values.map(\.allHR.n).reduce(0, +), 30)
        XCTAssertEqual(tapes.values.map(\.restHR.n).reduce(0, +), 25)
        let second = first + 60
        let west: (Int) -> String = { Self.utcDay($0 - 3600) }
        LBDayTape.ingest(window: try window(now: second, imuStill: true), nowUnix: second,
                         into: &tapes, dayOf: west)
        XCTAssertEqual(tapes.values.map(\.allHR.n).reduce(0, +), 31, "one new minute, not 21")
        XCTAssertEqual(tapes.values.map(\.restHR.n).reduce(0, +), 26, "one newly settled minute")
    }

    func testImuTimeZoneChangeDoesNotCountASampleTwice() {
        let midnight = 1_790_000_000 - 1_790_000_000 % 86_400
        let s1 = (midnight - 300..<midnight + 300).map {
            WatchdogIMUSample(ts: $0, x: 0, y: 0, z: 1, dynAccel: 0.2)
        }
        var accs: [String: LBImuDayAccumulator] = [:]
        LBImuDaily.ingest(s1, sleepIntervals: [], into: &accs, dayOf: Self.utcDay)
        let s2 = (midnight - 300..<midnight + 360).map {
            WatchdogIMUSample(ts: $0, x: 0, y: 0, z: 1, dynAccel: 0.2)
        }
        LBImuDaily.ingest(s2, sleepIntervals: [], into: &accs, dayOf: { Self.utcDay($0 - 3600) })
        XCTAssertEqual(accs.values.map(\.sampleCount).reduce(0, +), 660, "600 then 60 new, not 600 + 360")
    }

    func testImuSkipThroughStopsAlertSamplesBackFillingTheUsual() {
        func samples(_ r: Range<Int>, energy: Double) -> [WatchdogIMUSample] {
            r.map { WatchdogIMUSample(ts: $0, x: 0, y: 0, z: 1, dynAccel: energy) }
        }
        let day: (Int) -> String = { _ in "d" }
        var accs: [String: LBImuDayAccumulator] = [:]
        LBImuDaily.ingest(samples(base..<base + 600, energy: 0.1), sleepIntervals: [], into: &accs, dayOf: day)
        // An alerting tick may not train; its samples are consumed.
        XCTAssertEqual(LBImuDaily.skipThrough(samples(base..<base + 1200, energy: 0.9), into: &accs, dayOf: day),
                       ["d"])
        XCTAssertEqual(LBImuDaily.skipThrough(samples(base..<base + 1200, energy: 0.9), into: &accs, dayOf: day),
                       [])
        // The next quiet tick re-delivers the alert stretch in its window; only new samples count.
        LBImuDaily.ingest(samples(base + 600..<base + 1500, energy: 0.1), sleepIntervals: [],
                          into: &accs, dayOf: day)
        XCTAssertEqual(accs["d"]?.sampleCount, 900)
        XCTAssertEqual(accs["d"]?.meanEnergy ?? 0, 0.1, accuracy: 1e-9)
    }

    func testSkipOnlyImuDayHasNoSamples() {
        var accs: [String: LBImuDayAccumulator] = [:]
        LBImuDaily.skipThrough([WatchdogIMUSample(ts: base, x: 0, y: 0, z: 1, dynAccel: 0.5)],
                               into: &accs, dayOf: { _ in "d" })
        XCTAssertEqual(accs["d"]?.sampleCount, 0, "callers drop skip-only accumulators from observations")
        XCTAssertEqual(accs["d"]?.lastTs, base)
    }

    // MARK: Ingest regime provenance (review fix)

    func testContextRuleMarksLegacyAndMixedDays() throws {
        XCTAssertEqual(LBDayTape(day: "d").contextRule, LBDayTape.contextRuleCurrent)
        XCTAssertTrue(LBDayTape(day: "d").currentContextRule)
        let legacyJSON = #"{"day":"2026-10-01","restHR":{"sum":620,"n":10,"lastMinuteUnix":1}}"#
        var legacy = try JSONDecoder().decode(LBDayTape.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(legacy.contextRule, LBDayTape.contextRuleLegacy,
                       "a pre-regime row must not look like a current-regime row")
        XCTAssertFalse(legacy.currentContextRule)
        XCTAssertEqual(legacy.restPosture, LBDayTape.restPosturePooledUnresolved)
        legacy.ingest(window: try window(now: base, imuStill: true), nowUnix: base)
        XCTAssertEqual(legacy.contextRule, LBDayTape.contextRuleMixed)
        let round = try JSONDecoder().decode(LBDayTape.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(round.contextRule, LBDayTape.contextRuleMixed)
        var fresh = LBDayTape(day: "d")
        fresh.ingest(window: try window(now: base, imuStill: true), nowUnix: base)
        XCTAssertEqual(fresh.contextRule, LBDayTape.contextRuleCurrent)
    }

    // MARK: Persisted format

    func testLegacyTapeDecodesAndDerivesWatermark() throws {
        let legacy = """
        {"day":"2026-10-01","restHR":{"sum":620,"n":10,"lastMinuteUnix":\(base - 600)},
         "restHRV":{"sum":440,"n":10,"lastMinuteUnix":\(base - 600)},
         "restSpO2":{"sum":0,"n":0,"lastMinuteUnix":0},
         "effortHR":{"sum":0,"n":0,"lastMinuteUnix":0},"effortHRV":{"sum":0,"n":0,"lastMinuteUnix":0},
         "effortSpO2":{"sum":0,"n":0,"lastMinuteUnix":0},
         "allHR":{"sum":620,"n":10,"lastMinuteUnix":\(base - 600)},
         "allHRV":{"sum":440,"n":10,"lastMinuteUnix":\(base - 600)},
         "allSpO2":{"sum":0,"n":0,"lastMinuteUnix":0},
         "sleepSpO2N":0,"sleepSpO2LastMinute":0,"activeMinutes":0,"lastActiveMinute":0}
        """
        var tape = try JSONDecoder().decode(LBDayTape.self, from: Data(legacy.utf8))
        XCTAssertEqual(tape.contextWatermark, [base - 600, base - 600, 0])
        XCTAssertEqual(tape.unknownContextHR.n, 0)
        tape.ingest(window: try window(now: base, imuStill: true), nowUnix: base)
        XCTAssertEqual(tape.restHR.n, 10 + 4, "only settled minutes after the legacy watermark are new")
        let round = try JSONDecoder().decode(LBDayTape.self, from: JSONEncoder().encode(tape))
        XCTAssertEqual(round, tape)
    }

    // MARK: Device scope (D4-07 / D4-13)

    private final class Defaults {
        var data: [String: Data] = [:]
        var strings: [String: String] = [:]
        var io: LBKeyValueIO {
            LBKeyValueIO(data: { self.data[$0] }, setData: { self.data[$1] = $0 },
                         string: { self.strings[$0] }, setString: { self.strings[$1] = $0 })
        }
    }

    private func legacyTapes() throws -> Data {
        var t = LBDayTape(day: "2026-10-01")
        t.restHR.addUnique(value: 61, minuteUnix: base)
        return try JSONEncoder().encode([t])
    }

    func testLegacyGlobalTapeIsAdoptedOnceByTheFirstDevice() throws {
        let d = Defaults()
        d.data["noop.baseline.daytape.v2"] = try legacyTapes()
        let (first, o1): (LBDeviceScopedRows<LBDayTape>, LBDeviceScope.Origin) = LBDeviceScope.load(
            prefix: LBDeviceScope.tapePrefix, legacyKeys: LBDeviceScope.legacyTapeKeys,
            deviceId: "my-whoop", serial: nil, io: d.io)
        XCTAssertEqual(o1, .legacyAdopted)
        XCTAssertEqual(first.rows.map(\.day), ["2026-10-01"], "history survives the update")
        // Reload: the device's own scoped copy.
        let (again, o2): (LBDeviceScopedRows<LBDayTape>, LBDeviceScope.Origin) = LBDeviceScope.load(
            prefix: LBDeviceScope.tapePrefix, legacyKeys: LBDeviceScope.legacyTapeKeys,
            deviceId: "my-whoop", serial: nil, io: d.io)
        XCTAssertEqual(o2, .own)
        XCTAssertEqual(again.rows, first.rows)
        // A second device never inherits the legacy blob.
        let (other, o3): (LBDeviceScopedRows<LBDayTape>, LBDeviceScope.Origin) = LBDeviceScope.load(
            prefix: LBDeviceScope.tapePrefix, legacyKeys: LBDeviceScope.legacyTapeKeys,
            deviceId: "whoop-5", serial: nil, io: d.io)
        XCTAssertEqual(o3, .fresh)
        XCTAssertTrue(other.rows.isEmpty)
    }

    func testDevicesKeepSeparateTapes() throws {
        let d = Defaults()
        var a = LBDeviceScopedRows<LBDayTape>(deviceId: "a", strapSerial: nil, rows: [LBDayTape(day: "x")])
        a.rows[0].restHR.addUnique(value: 60, minuteUnix: base)
        LBDeviceScope.save(a, prefix: LBDeviceScope.tapePrefix, io: d.io)
        let b = LBDeviceScopedRows<LBDayTape>(deviceId: "b", strapSerial: nil, rows: [LBDayTape(day: "x")])
        LBDeviceScope.save(b, prefix: LBDeviceScope.tapePrefix, io: d.io)
        let (la, _): (LBDeviceScopedRows<LBDayTape>, LBDeviceScope.Origin) = LBDeviceScope.load(
            prefix: LBDeviceScope.tapePrefix, legacyKeys: [], deviceId: "a", serial: nil, io: d.io)
        let (lb, _): (LBDeviceScopedRows<LBDayTape>, LBDeviceScope.Origin) = LBDeviceScope.load(
            prefix: LBDeviceScope.tapePrefix, legacyKeys: [], deviceId: "b", serial: nil, io: d.io)
        XCTAssertEqual(la.rows.first?.restHR.n, 1)
        XCTAssertEqual(lb.rows.first?.restHR.n, 0)
    }

    func testStrapSwapUnderSameLocalIdArchivesAndStartsFresh() throws {
        let d = Defaults()
        d.data["noop.baseline.daytape.v2"] = try legacyTapes()
        typealias Loaded = (LBDeviceScopedRows<LBDayTape>, LBDeviceScope.Origin)
        func load(_ serial: String?) -> Loaded {
            LBDeviceScope.load(prefix: LBDeviceScope.tapePrefix, legacyKeys: LBDeviceScope.legacyTapeKeys,
                               deviceId: "my-whoop", serial: serial, io: d.io)
        }
        XCTAssertEqual(load(nil).1, .legacyAdopted)
        // First time the serial is learned: same strap, stamped, history kept.
        let stamped = load("4A1")
        XCTAssertEqual(stamped.1, .own)
        XCTAssertEqual(stamped.0.strapSerial, "4A1")
        XCTAssertEqual(stamped.0.rows.count, 1)
        XCTAssertEqual(load(nil).0.rows.count, 1, "unknown serial does not split the era")
        // A different strap answers to my-whoop: old era archived, new era empty.
        let swapped = load("5B2")
        XCTAssertEqual(swapped.1, .strapReplaced)
        XCTAssertTrue(swapped.0.rows.isEmpty)
        XCTAssertNotNil(d.data[LBDeviceScope.archiveKey(prefix: LBDeviceScope.tapePrefix,
                                                         deviceId: "my-whoop", serial: "4A1")])
        XCTAssertEqual(load("5B2").1, .own)
    }

    // MARK: Waking IMU energy (D4-13)

    func testImuEnergyDropsSleepSamplesAndKeysBySampleDay() {
        let midnight = 1_790_000_000 - 1_790_000_000 % 86_400
        let samples = (midnight - 600..<midnight + 600).map {
            WatchdogIMUSample(ts: $0, x: 0, y: 0, z: 1, dynAccel: 0.2)
        }
        let sleep = [WatchdogSleepInterval(startUnix: midnight - 300, endUnix: midnight + 300)]
        var accs: [String: LBImuDayAccumulator] = [:]
        let changed = LBImuDaily.ingest(samples, sleepIntervals: sleep, into: &accs, dayOf: Self.utcDay)
        let before = Self.utcDay(midnight - 60)
        let after = Self.utcDay(midnight)
        XCTAssertEqual(changed, [before, after].sorted())
        XCTAssertEqual(accs[before]?.sampleCount, 300, "23:50-23:55 awake, 23:55-00:00 asleep")
        XCTAssertEqual(accs[after]?.sampleCount, 300, "00:05-00:10 awake")
        XCTAssertEqual(accs[before]?.minutes, 5)
        // Re-ingesting the same samples is a no-op.
        XCTAssertTrue(LBImuDaily.ingest(samples, sleepIntervals: sleep, into: &accs, dayOf: Self.utcDay).isEmpty)
    }

    func testImuDeviceScopeAdoptsLegacyAccumulator() throws {
        let d = Defaults()
        let legacy = [LBImuDayAccumulator(day: "2026-10-01", energySum: 2, sampleCount: 10, lastTs: base)]
        d.data["noop.baseline.imu.v1"] = try JSONEncoder().encode(legacy)
        let (rows, origin): (LBDeviceScopedRows<LBImuDayAccumulator>, LBDeviceScope.Origin) = LBDeviceScope.load(
            prefix: LBDeviceScope.imuPrefix, legacyKeys: LBDeviceScope.legacyImuKeys,
            deviceId: "my-whoop", serial: "4A1", io: d.io)
        XCTAssertEqual(origin, .legacyAdopted)
        XCTAssertEqual(rows.rows, legacy)
    }
}

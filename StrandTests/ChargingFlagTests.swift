import XCTest
@testable import Strand
import WhoopProtocol

/// Charging on a WHOOP 5.0 / MG. The 5.0 BATTERY_LEVEL charge bit reads 0 through a real charge, so the flag comes from
/// the CHARGING_ON / CHARGING_OFF and pack edges, and an ON flag is reviewed against the battery gauge (#1935).
///
/// The replay is a real capture from 9 Oct 2026: a pack went on the charger at 11:47, came off at 12:06, and went back
/// on at 12:10. The gauge rose from 12.9% to 45.1%, and every reading in it had the charge bit at 0.
final class ChargingFlagTests: XCTestCase {

    /// The captured 5.0 BATTERY_LEVEL(3) event of `Whoop5EventTests`: SoC at @21, pack mV at @25, charge bit at @30.
    private let batteryEventHex =
        "aa01240001002eb130350300a589266a5118140002f3010000f90e00000000340806003500000000358eb56f"
    /// The captured DOUBLE_TAP(14) frame of `FrameRouterDoubleTapDedupTests`, reused with another event byte.
    private let doubleTapHex = "aa0110000100208130340e008089266a3d2a000030b8df92"
    /// Real WHOOP 4.0 BATTERY_LEVEL frames from `golden.json` (entries 24 and 23, CRC valid): charge bit 1, then 0.
    private let whoop4ChargingOn = "aa220084300b030091d67e67000000000003020000e20e00000001000000000000004f78d829"
    private let whoop4ChargingOff = "aa220084300a030055d67e670000000000f9010000d80e0000000000000000000000367d04c2"

    /// Event numbers from the shared `EventNumber` schema.
    private enum Event {
        static let chargingOn: UInt8 = 7
        static let chargingOff: UInt8 = 8
        static let packConnected: UInt8 = 21
        static let packRemoved: UInt8 = 22
    }

    /// The strap's charging edges in the capture: a 13-second attach at 11:46:56 that never charged, the charge from
    /// 11:47:25 to the unplug at 12:06:02, and the re-attach at 12:10:41.
    private let edges: [(ts: Int, on: Bool)] = [
        (1791571616, true), (1791571629, false), (1791571634, false),
        (1791571645, true), (1791572762, false), (1791573041, true),
    ]

    /// The capture's battery readings from the store, `unix-seconds SoC%`, 11:40 to 12:19 local on 9 Oct 2026.
    private let captured = """
        1791571231 12.9
        1791571682 13.6
        1791571712 14.2
        1791571742 14.8
        1791571772 15.4
        1791571802 16.0
        1791571832 16.6
        1791571862 17.3
        1791571892 17.9
        1791571922 18.6
        1791571952 19.2
        1791571982 19.8
        1791572012 20.5
        1791572042 21.1
        1791572072 21.7
        1791572102 22.4
        1791572132 23.0
        1791572162 23.7
        1791572192 24.4
        1791572222 25.0
        1791572252 25.7
        1791572282 26.3
        1791572312 27.0
        1791572342 27.6
        1791572373 28.3
        1791572403 28.9
        1791572433 29.6
        1791572463 30.2
        1791572493 30.8
        1791572520 31.5
        1791572550 32.1
        1791572580 32.7
        1791572610 33.3
        1791572641 33.9
        1791572671 34.5
        1791572701 35.1
        1791572731 35.7
        1791572761 36.3
        1791573061 36.7
        1791573091 37.2
        1791573121 37.8
        1791573151 38.3
        1791573182 38.9
        1791573212 39.5
        1791573242 40.1
        1791573272 40.7
        1791573302 41.2
        1791573332 41.8
        1791573362 42.4
        1791573392 42.9
        1791573422 43.5
        1791573452 44.1
        1791573482 44.6
        1791573512 45.1
        """

    private struct Reading {
        let ts: Int
        let soc: Double
    }

    private var readings: [Reading] {
        captured.split(whereSeparator: \.isNewline).map { line in
            let parts = line.split(separator: " ")
            return Reading(ts: Int(parts[0])!, soc: Double(parts[1])!)
        }
    }

    /// What the strap said about the charger at `ts`: the state of the last edge at or before it, nil before the first.
    private func expectedFlag(at ts: Int) -> Bool? {
        edges.last(where: { $0.ts <= ts })?.on
    }

    // MARK: - Frame helpers

    private func bytes(_ hex: String) -> [UInt8] {
        var out = [UInt8](), i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            out.append(UInt8(hex[i..<j], radix: 16)!)
            i = j
        }
        return out
    }

    /// Recomputes the payload CRC32 (the last four bytes) after an edit, the way the strap seals a frame.
    private func reseal(_ f: inout [UInt8]) {
        let crc = crc32(f, 8, f.count - 4)
        f.replaceSubrange(f.count - 4..<f.count, with: withUnsafeBytes(of: crc.littleEndian, Array.init))
    }

    /// `doubleTapHex` with its event byte replaced, so the router sees a 5.0 event with that number.
    private func eventFrame(_ event: UInt8) -> [UInt8] {
        var f = bytes(doubleTapHex)
        f[10] = event
        reseal(&f)
        return f
    }

    /// `batteryEventHex` with its SoC and charge bit replaced.
    private func batteryFrame(percent: Double, chargeBit: UInt8 = 0) -> [UInt8] {
        var f = bytes(batteryEventHex)
        let raw = UInt16((percent * 10).rounded())
        f[21] = UInt8(raw & 0xFF)
        f[22] = UInt8(raw >> 8)
        f[30] = chargeBit
        reseal(&f)
        return f
    }

    @MainActor
    private func whoop5Router() -> (LiveState, FrameRouter) {
        let live = LiveState()
        let router = FrameRouter(state: live)
        router.family = .whoop5
        return (live, router)
    }

    // MARK: - The router

    @MainActor
    func testChargingOnHoldsWhileBatteryReadingsReportTheChargeBitAsZero() {
        let (live, router) = whoop5Router()
        router.handle(frame: eventFrame(Event.chargingOn))
        XCTAssertEqual(live.charging, true)

        router.handle(frame: batteryFrame(percent: 45.0, chargeBit: 0))
        router.handle(frame: batteryFrame(percent: 45.3, chargeBit: 0))
        XCTAssertEqual(live.batteryPct, 45.3)
        XCTAssertEqual(live.charging, true, "the 5.0 charge bit reads 0 through a real charge, so it must not clear the flag")

        router.handle(frame: eventFrame(Event.chargingOff))
        XCTAssertEqual(live.charging, false)
    }

    @MainActor
    func testPackEdgesSetAndClearTheFlag() {
        let (live, router) = whoop5Router()
        router.handle(frame: eventFrame(Event.packConnected))
        XCTAssertEqual(live.charging, true)
        router.handle(frame: eventFrame(Event.packRemoved))
        XCTAssertEqual(live.charging, false)
    }

    @MainActor
    func testA5BatteryReadingWithItsChargeBitSetDoesNotStartACharge() {
        let (live, router) = whoop5Router()
        router.handle(frame: batteryFrame(percent: 60, chargeBit: 1))
        XCTAssertEqual(live.batteryPct, 60)
        XCTAssertNil(live.charging, "the 5.0 charge bit is not decoded, so a reading cannot start a charge by itself")
    }

    @MainActor
    func testWhoop4ChargeBitStillSetsAndClearsTheFlag() {
        let live = LiveState()
        let router = FrameRouter(state: live)   // family defaults to .whoop4
        router.handle(frame: bytes(whoop4ChargingOn))
        XCTAssertEqual(live.charging, true)
        router.handle(frame: bytes(whoop4ChargingOff))
        XCTAssertEqual(live.charging, false)
    }

    // MARK: - The gauge review

    @MainActor
    func testAnEdgeWithAFlatGaugeIsClearedWhenItsWindowCloses() {
        let live = LiveState()
        live.noteChargingEdge(on: true)
        var t = 1_000
        for _ in 0..<10 {                          // 30 s cadence, 4.5 minutes, flat at 20%
            live.reviewChargingAgainstGauge(pct: 20, now: t)
            t += 30
        }
        XCTAssertEqual(live.charging, true, "the first window has not closed")
        live.reviewChargingAgainstGauge(pct: 20, now: t)   // 300 s after the first reading
        XCTAssertEqual(live.charging, false)
    }

    @MainActor
    func testAnEdgeWithAChargingGaugeStaysOn() {
        let live = LiveState()
        live.noteChargingEdge(on: true)
        var t = 1_000, soc = 20.0
        for _ in 0..<120 {                         // an hour at 30 s cadence, +0.6 a step (the captured rate)
            live.reviewChargingAgainstGauge(pct: soc, now: t)
            t += 30
            soc += 0.6
        }
        XCTAssertEqual(live.charging, true)
    }

    @MainActor
    func testAFullPackIsNotClearedBecauseItCannotRise() {
        let live = LiveState()
        live.noteChargingEdge(on: true)
        var t = 1_000
        for _ in 0..<25 {
            live.reviewChargingAgainstGauge(pct: 100, now: t)
            t += 30
        }
        XCTAssertEqual(live.charging, true)
    }

    @MainActor
    func testTheGaugeNeverSetsTheFlag() {
        let live = LiveState()
        var t = 1_000
        for soc in stride(from: 20.0, through: 60.0, by: 2.0) {   // a steep climb, but no edge
            live.reviewChargingAgainstGauge(pct: soc, now: t)
            t += 30
        }
        XCTAssertNil(live.charging)
    }

    @MainActor
    func testANewEdgeRestartsTheReviewAndForgetClearsEverything() {
        let live = LiveState()
        live.noteChargingEdge(on: true)
        live.reviewChargingAgainstGauge(pct: 20, now: 1_000)
        live.reviewChargingAgainstGauge(pct: 20, now: 1_300)   // the flat window closes: cleared
        XCTAssertEqual(live.charging, false)

        live.noteChargingEdge(on: true)
        live.reviewChargingAgainstGauge(pct: 20, now: 1_310)   // a new window opens here
        live.reviewChargingAgainstGauge(pct: 20, now: 1_500)   // 190 s in: not yet judged
        XCTAssertEqual(live.charging, true)

        live.forgetCharging()                                  // disconnect
        XCTAssertNil(live.charging)
    }

    // MARK: - The real capture

    /// Feeds the capture's edges and battery readings through the same calls the router makes, with the clock injected.
    /// The flag has to follow the strap's edges through the whole charge, with the 5.0 charge bit at 0 throughout.
    @MainActor
    func testTheFlagHoldsThroughTheCaptureChargeAndClearsAtTheUnplug() {
        let live = LiveState()
        var pending = edges[...]
        for r in readings {
            while let edge = pending.first, edge.ts <= r.ts {
                live.noteChargingEdge(on: edge.on)
                XCTAssertEqual(live.charging, edge.on, "edge at \(edge.ts)")
                pending = pending.dropFirst()
            }
            live.bankBatterySample(r.soc, now: r.ts)
            live.reviewChargingAgainstGauge(pct: r.soc, now: r.ts)
            if let expected = expectedFlag(at: r.ts) {
                XCTAssertEqual(live.charging, expected, "reading \(r.soc)% at \(r.ts)")
            }
        }
        XCTAssertEqual(live.charging, true, "the pack was still on the charger at the last reading")
    }

    /// With no edge at all (the app opened while the strap was already charging), the gauge trend alone has to read as
    /// charging from five minutes in, up to the unplug, and again at the end of the capture.
    func testTheGaugeTrendShowsTheChargeWithoutAnyEdge() {
        let rs = readings
        for (i, r) in rs.enumerated() where (r.ts >= 1791571682 && r.ts <= 1791572761) || r.ts == 1791573512 {
            let samples = rs[...i].map { (ts: $0.ts, soc: $0.soc) }
            XCTAssertTrue(ChargingEvidence.rising(samples: samples, now: r.ts), "reading \(r.soc)% at \(r.ts)")
        }
    }

    // MARK: - The trend fallback

    func testTheTrendIgnoresAnIdleGaugeAndNeedsAClearRise() {
        // 8-minute cadence, flat.
        var idle: [(ts: Int, soc: Double)] = []
        for i in 0..<12 { idle.append((ts: 1_000 + i * 480, soc: 40.0)) }
        XCTAssertFalse(ChargingEvidence.rising(samples: idle, now: idle[idle.count - 1].ts))

        // 30 s cadence, the captured charging rate (+0.6 a step).
        var charging: [(ts: Int, soc: Double)] = []
        for i in 0..<20 { charging.append((ts: 1_000 + i * 30, soc: 40.0 + Double(i) * 0.6)) }
        let lastTs: Int = charging[charging.count - 1].ts
        XCTAssertTrue(ChargingEvidence.rising(samples: charging, now: lastTs))
        XCTAssertFalse(ChargingEvidence.rising(samples: charging, now: lastTs + 3_000),
                       "a stale trend says nothing about now")

        let single: [(ts: Int, soc: Double)] = [(ts: 1_000, soc: 40.0)]
        XCTAssertFalse(ChargingEvidence.rising(samples: single, now: 1_000))
    }
}

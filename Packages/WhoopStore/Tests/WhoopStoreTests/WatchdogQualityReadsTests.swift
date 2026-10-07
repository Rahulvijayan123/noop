import XCTest
import WhoopProtocol
@testable import WhoopStore

/// Additive reads behind the Watchdog sensor-quality feed.
final class WatchdogQualityReadsTests: XCTestCase {
    private let dev = "whoop-a"
    private let base = 1_791_000_000

    func testPpgHrRowsKeepRealBpmAndConfidence() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(ppgHr: [PpgHrSample(ts: base, bpm: 63, conf: 0.81),
                                                   PpgHrSample(ts: base + 1, bpm: 64, conf: 0.35)]), deviceId: dev)
        _ = try await store.insert(Streams(ppgHr: [PpgHrSample(ts: base, bpm: 90, conf: 0.9)]), deviceId: "other")
        let rows = try await store.ppgHrRows(deviceId: dev, from: base, to: base + 10, limit: 100)
        XCTAssertEqual(rows, [PpgHrRow(ts: base, bpm: 63, conf: 0.81), PpgHrRow(ts: base + 1, bpm: 64, conf: 0.35)])
    }

    func testBatteryChargingSamplesCarryTheBit() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(battery: [
            BatterySample(ts: base, soc: 50, mv: 3_900, charging: true),
            BatterySample(ts: base + 60, soc: 51, mv: nil, charging: nil),
        ]), deviceId: dev)
        let rows = try await store.batteryChargingSamples(deviceId: dev, from: base, to: base + 100, limit: 10)
        XCTAssertEqual(rows.map(\.ts), [base, base + 60])
        XCTAssertEqual(rows.map(\.charging), [true, nil])
    }

    func testEventsFilteredByKindPrefix() async throws {
        let store = try await WhoopStore.inMemory()
        _ = try await store.insert(Streams(events: [
            WhoopEvent(ts: base, kind: "WRIST_OFF(10)", payload: [:]),
            WhoopEvent(ts: base + 1, kind: "BATTERY_LEVEL(3)", payload: [:]),
            WhoopEvent(ts: base + 2, kind: "WRIST_ON(9)", payload: [:]),
            WhoopEvent(ts: base + 3, kind: "BOOT(15)", payload: [:]),
            WhoopEvent(ts: base + 4, kind: "WRISTXON(99)", payload: [:]),
        ]), deviceId: dev)
        let rows = try await store.events(deviceId: dev, from: base, to: base + 10,
                                          kindPrefixes: ["WRIST_ON", "WRIST_OFF", "BOOT"], limit: 10)
        XCTAssertEqual(rows.map(\.kind), ["WRIST_OFF(10)", "WRIST_ON(9)", "BOOT(15)"])
        let none = try await store.events(deviceId: dev, from: base, to: base + 10, kindPrefixes: [], limit: 10)
        XCTAssertTrue(none.isEmpty)
    }
}

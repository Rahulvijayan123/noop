import XCTest
import GRDB
@testable import WhoopStore

/// D8-10: retrospective intervals are stored beside the causal ones for final days only; causal reads (and the
/// `*Ctx` views) never see them; historical reads prefer them for final, smoothed days, deterministically.
final class ActivityContextRetrospectiveStoreTests: XCTestCase {
    private let dev = "my-whoop"
    private let day0 = 1_760_000_000

    private func row(_ start: Int, _ length: Int, _ cls: String) -> ActivityContextIntervalRow {
        ActivityContextIntervalRow(startTs: start, endTs: start + length, activityClass: cls, confidence: 0.7,
                                   sleepState: "awake", wearState: "on_wrist")
    }

    private func ledger(_ dayStart: Int, finality: String, retro: String? = nil) -> ActivityContextDayRow {
        ActivityContextDayRow(day: "2025-10-09", dayStart: dayStart, dayEnd: dayStart + 86_400,
                              taxonomyVersion: "act-class-4", decoderVersion: "hsmm-1.8", ontologyVersion: "2.0",
                              intervalVersion: "ctx-int-2", dataThrough: dayStart + 86_400, computedAt: 1,
                              finality: finality, retrospectiveVersion: retro)
    }

    private var causal: [ActivityContextIntervalRow] {
        [row(day0, 300, "walking"), row(day0 + 300, 60, "standing"), row(day0 + 360, 120, "stationary"),
         row(day0 + 480, 1020, "sitting")]
    }
    private var retrospective: [ActivityContextIntervalRow] {
        [row(day0, 300, "walking"), row(day0 + 300, 900, "sitting"), row(day0 + 1200, 300, "sitting")]
    }

    func testFinalDayStoresBothDerivationsAndEachReadGetsItsOwn() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, finality: "final", retro: "ctx-retro-1"),
                                               intervals: causal, retrospective: retrospective)
        let plain = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400)
        XCTAssertEqual(plain.map(\.activityClass), ["walking", "standing", "stationary", "sitting"])
        XCTAssertTrue(plain.allSatisfy { $0.derivation == ActivityContextIntervalRow.causal })
        let asCausal = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400,
                                                                reading: .causal)
        XCTAssertEqual(asCausal, plain, "a causal consumer never reads a smoothed row")
        let retro = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400,
                                                             reading: .retrospective)
        XCTAssertEqual(retro.map(\.activityClass), ["walking", "sitting", "sitting"])
        XCTAssertTrue(retro.allSatisfy { $0.derivation == ActivityContextIntervalRow.retrospective })
        let history = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400,
                                                               reading: .historical)
        XCTAssertEqual(history, retro)
        let again = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400,
                                                             reading: .historical)
        XCTAssertEqual(history, again)
        let day = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        XCTAssertEqual(day?.retrospectiveVersion, "ctx-retro-1")
        // The sample views join the causal rows only.
        try await store.syncWrite { db in
            try db.execute(sql: "INSERT INTO hrSample (deviceId, ts, bpm) VALUES (?, ?, ?)",
                           arguments: [self.dev, self.day0 + 320, 80])
        }
        let ctx = try await store.syncRead { db in
            try String.fetchOne(db, sql: "SELECT ctxClass FROM hrSampleCtx WHERE deviceId = ? AND ts = ?",
                                arguments: [self.dev, self.day0 + 320])
        }
        XCTAssertEqual(ctx, "standing")
    }

    func testRetrospectiveRowsAreRefusedForAProvisionalDay() async throws {
        let store = try await WhoopStore.inMemory()
        do {
            try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, finality: "provisional"),
                                                   intervals: causal, retrospective: retrospective)
            XCTFail("a provisional day cannot hold retrospective rows")
        } catch let e as ActivityContextStoreError {
            XCTAssertEqual(e, .retrospectiveOnProvisionalDay("2025-10-09"))
        }
        // A provisional day is served causally to every reader.
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, finality: "provisional"),
                                               intervals: causal)
        let history = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400,
                                                               reading: .historical)
        XCTAssertEqual(history.map(\.activityClass), ["walking", "standing", "stationary", "sitting"])
        let ledger0 = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        XCTAssertNil(ledger0?.retrospectiveVersion)
    }

    func testRewritingOrUnfinalisingADayClearsItsRetrospectiveRows() async throws {
        let store = try await WhoopStore.inMemory()
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, finality: "final", retro: "ctx-retro-1"),
                                               intervals: causal, retrospective: retrospective)
        // Back to provisional (late data): the smoothed rows go with it.
        _ = try await store.updateActivityContextDayStatus(deviceId: dev, dayStart: day0, inputFingerprint: "x",
                                                           finality: "provisional")
        let retro = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400,
                                                             reading: .retrospective)
        XCTAssertTrue(retro.isEmpty)
        let ledger1 = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        XCTAssertNil(ledger1?.retrospectiveVersion)
        // A rewrite without retrospective rows leaves none and records no smoother.
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, finality: "final", retro: "ctx-retro-1"),
                                               intervals: causal, retrospective: retrospective)
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, finality: "final", retro: "ctx-retro-1"),
                                               intervals: causal)
        let none = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400,
                                                            reading: .retrospective)
        XCTAssertTrue(none.isEmpty)
        let ledger2 = try await store.activityContextDay(deviceId: dev, day: "2025-10-09")
        XCTAssertNil(ledger2?.retrospectiveVersion)
        // Clearing and deleting a device's data clear both tables.
        try await store.replaceActivityContext(deviceId: dev, day: ledger(day0, finality: "final", retro: "ctx-retro-1"),
                                               intervals: causal, retrospective: retrospective)
        try await store.clearActivityContext(deviceId: dev)
        let cleared = try await store.activityContextIntervals(deviceId: dev, from: day0, to: day0 + 86_400,
                                                               reading: .retrospective)
        XCTAssertTrue(cleared.isEmpty)
        XCTAssertTrue(DeviceRegistryStore.deviceScopedTables.contains("activityContextIntervalRetrospective"))
    }
}

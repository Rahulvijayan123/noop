import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
@testable import Strand

/// The store-backed half of "every reading": what a 5.0/MG banks (skin temperature every second, SpO₂ bytes in
/// sleep-time windows) comes back from `Repository` whole, counted, and plotted, on an in-memory `WhoopStore`.
@MainActor
final class BankedReadingsRepositoryTests: XCTestCase {

    private let dev = "my-whoop"
    private let base = 1_790_700_000

    private func makeRepo(_ streams: Streams) async throws -> Repository {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        try await store.insert(streams, deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)
        return repo
    }

    /// Two hours at 1 Hz: skin temperature every second, and the SpO₂ byte written in two 30-second windows
    /// (one all percentages, one mixed with status codes), zero the rest of the time, exactly as the strap does.
    private func twoHours() -> Streams {
        var skin: [SkinTempSample] = []
        var aux: [V18AuxSample] = []
        for i in 0..<7_200 {
            skin.append(SkinTempSample(ts: base + i, raw: 3300 + i / 72))     // 33.00 to 34.00 C, rising
            var byte = 0
            if (600..<630).contains(i) { byte = 90 + i % 9 }                   // window 1: 30 percentages
            if (3_000..<3_030).contains(i) { byte = i % 2 == 0 ? 97 : 160 }    // window 2: 15 percentages, 15 sentinels
            aux.append(V18AuxSample(ts: base + i, auxByte82: byte))
        }
        return Streams(skinTemp: skin, v18Aux: aux)
    }

    // MARK: a 5.0/MG registered as "WHOOP 4.0" (the real phone: 321 °F)

    /// The registry label is only what the strap was called when added. One phone holds a 5.0/MG registered as
    /// "WHOOP 4.0"; the family then came from the label and the 4.0's experimental map turned a 33.4 °C
    /// register into 160 °C.
    private func makeRepo(_ streams: Streams, registeredAs model: String, brand: String = "WHOOP") async throws -> Repository {
        let store = try await WhoopStore.inMemory()
        try await store.upsertDevice(id: dev, mac: nil, name: model)
        try await store.insert(streams, deviceId: dev)
        try DeviceRegistryStore(dbQueue: store.registryWriter).add(PairedDevice(
            id: dev, brand: brand, model: model, peripheralId: nil, sourceKind: .liveBLE,
            capabilities: [.hr], status: .active, addedAt: 1, lastSeenAt: 1))
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)
        return repo
    }

    func testAFiveOhMGRegisteredAsAFourPointZeroStillReadsInRealCelsius() async throws {
        let repo = try await makeRepo(twoHours(), registeredAs: "WHOOP 4.0")   // holds v18 records: a 5/MG
        let series = await repo.bankedSkinTemp(from: base, to: base + 7_200)
        XCTAssertEqual(series.count, 7_200)
        XCTAssertEqual(try XCTUnwrap(series.lastValue), 33.99, accuracy: 0.011, "33.99 °C, not ~160 °C / 321 °F")
        XCTAssertLessThan(try XCTUnwrap(series.maxValue), 45)
        let tile = await repo.currentSkinTemp(now: base + 7_200 + 90)
        XCTAssertEqual(try XCTUnwrap(tile).celsius, 33.99, accuracy: 0.011,
                       "the Skin Temp tile shows the live reading for a mislabelled 5/MG too")
    }

    func testTheDeepTimelineSkinTempAndSpo2TracksAlsoTrustTheDataOverTheLabel() async throws {
        let repo = try await makeRepo(twoHours(), registeredAs: "WHOOP 4.0")
        let skin = await repo.timelineSeries(metric: .skinTemp, from: base, to: base + 60, source: dev)
        XCTAssertFalse(skin.points.isEmpty)
        XCTAssertTrue(skin.points.allSatisfy { (30...36).contains($0.value) }, "33 to 34 °C, not 150+")
        let spo2 = await repo.timelineSeries(metric: .spo2, from: base + 590, to: base + 640, source: dev)
        XCTAssertEqual(spo2.points.count, 30, "the strap's percentages are plotted for a mislabelled 5/MG too")
    }

    func testOnlyV18RecordsUpgradeAFourPointZeroLabel() async throws {
        // A real 4.0 banks skin temperature but never a v18 record: the label stands.
        let onlySkin = Streams(skinTemp: (0..<60).map { SkinTempSample(ts: base + $0, raw: 830) })
        let fourOh = try await makeRepo(onlySkin, registeredAs: "WHOOP 4.0")
        let isFiveOnFour = await fourOh.activeStrapIsWhoop5WithEvidence()
        XCTAssertFalse(isFiveOnFour)
        let live = await fourOh.currentSkinTemp(now: base + 90)
        XCTAssertNil(live, "a 4.0 never gets a live absolute temperature")

        // The mislabelled 5/MG, by contrast, is recognised.
        let fiveOh = try await makeRepo(twoHours(), registeredAs: "WHOOP 4.0")
        let isFive = await fiveOh.activeStrapIsWhoop5WithEvidence()
        XCTAssertTrue(isFive)

        // A non-WHOOP device is never upgraded, whatever rows it holds.
        let garmin = try await makeRepo(twoHours(), registeredAs: "Forerunner 265", brand: "Garmin")
        let isFiveOnGarmin = await garmin.activeStrapIsWhoop5WithEvidence()
        XCTAssertFalse(isFiveOnGarmin)
    }

    func testARegistryRowLabelledFourPointZeroThatHoldsV18RecordsIsRelabelledToTheFiveOhMG() async throws {
        let repo = try await makeRepo(twoHours(), registeredAs: "WHOOP 4.0")
        await repo.relabelMislabelledWhoop5()
        let handle = await repo.storeHandle()
        let store = try XCTUnwrap(handle)
        let registry = DeviceRegistryStore(dbQueue: store.registryWriter)
        XCTAssertEqual(try registry.all().first { $0.id == dev }?.model, "WHOOP 5.0 / MG")
        await repo.relabelMislabelledWhoop5()      // idempotent
        XCTAssertEqual(try registry.all().first { $0.id == dev }?.model, "WHOOP 5.0 / MG")
    }

    func testARealFourPointZeroHistoryKeepsItsLabel() async throws {
        // Skin temperature but no v18 record: a genuine 4.0's history. Its label must stand.
        let onlySkin = Streams(skinTemp: (0..<60).map { SkinTempSample(ts: base + $0, raw: 830) })
        let repo = try await makeRepo(onlySkin, registeredAs: "WHOOP 4.0")
        await repo.relabelMislabelledWhoop5()
        let handle = await repo.storeHandle()
        let store = try XCTUnwrap(handle)
        XCTAssertEqual(try DeviceRegistryStore(dbQueue: store.registryWriter).all().first { $0.id == dev }?.model,
                       "WHOOP 4.0")
    }

    func testAnImplausibleConversionIsDroppedNotPlotted() async throws {
        // raw 150 on a 5/MG is 1.5 °C: not a skin temperature, so it never reaches the card.
        let streams = Streams(skinTemp: [SkinTempSample(ts: base, raw: 150), SkinTempSample(ts: base + 1, raw: 3300)])
        let repo = try await makeRepo(streams)
        let series = await repo.bankedSkinTemp(from: base, to: base + 10)
        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(try XCTUnwrap(series.lastValue), 33.0, accuracy: 0.001)
    }

    func testEverySkinTempSampleIsCountedAndTheLineIsFiveMinuteMeans() async throws {
        let repo = try await makeRepo(twoHours())
        let series = await repo.bankedSkinTemp(from: base, to: base + 7_200)
        XCTAssertEqual(series.count, 7_200, "one reading per second, none dropped")
        XCTAssertEqual(series.points.count, 24, "two hours of 5-minute means")
        XCTAssertEqual(series.firstTs, base)
        XCTAssertEqual(series.lastTs, base + 7_199)
        let last = try XCTUnwrap(series.lastValue)
        XCTAssertEqual(last, 33.99, accuracy: 0.011, "the newest raw reading in °C (raw / 100 on a 5/MG)")
        XCTAssertEqual(try XCTUnwrap(series.minValue), 33.0, accuracy: 0.001)
    }

    func testEverySpo2ReadingIsReturnedAndTheStatusBytesAreCountedApart() async throws {
        let repo = try await makeRepo(twoHours())
        let series = await repo.bankedSpo2(from: base, to: base + 7_200)
        XCTAssertEqual(series.count, 45, "30 in window one and 15 in window two")
        XCTAssertEqual(series.points.count, 45, "every reading is its own point, not averaged away")
        XCTAssertEqual(series.statusBytes, 15, "the 160 sentinels are not readings")
        XCTAssertTrue(series.points.allSatisfy { (70...100).contains($0.value) })
        XCTAssertEqual(series.firstTs, base + 600)
    }

    func testAnAwakeWindowHasNoSpo2ReadingsAtAll() async throws {
        let repo = try await makeRepo(twoHours())
        let awake = await repo.bankedSpo2(from: base + 1_000, to: base + 2_900)
        XCTAssertEqual(awake.count, 0)
        XCTAssertEqual(awake.statusBytes, 0)
        XCTAssertNil(awake.lastValue)
    }

    /// The bug behind "the Deep Timeline shows no SpO₂": a 5.0/MG banks no raw red/IR, so the track read the
    /// empty `spo2Sample` table and drew nothing, with the phone holding hundreds of readings.
    func testADeepTimelineSpo2TrackOnAFiveOhMGPlotsTheStrapsPercentages() async throws {
        let repo = try await makeRepo(twoHours())
        let series = await repo.timelineSeries(metric: .spo2, from: base + 590, to: base + 640, source: dev)
        XCTAssertTrue(series.isRaw, "a 50-second window reads raw seconds")
        XCTAssertEqual(series.points.count, 30, "the 30 readings in that window")
        XCTAssertTrue(series.points.allSatisfy { FullDayChartView.spo2IsPercent($0.value) },
                      "plotted as percentages, not the 4.0's ratio")
    }

    func testTheCurrentSkinTempIsTheNewestSampleWhenItIsFresh() async throws {
        let repo = try await makeRepo(twoHours())
        let now = base + 7_200 + 90
        let current = await repo.currentSkinTemp(now: now)
        let reading = try XCTUnwrap(current)
        XCTAssertEqual(reading.ts, base + 7_199)
        XCTAssertEqual(reading.celsius, 33.99, accuracy: 0.011)
        let later = now + KeyMetricReadings.currentSkinTempSeconds
        let stale = await repo.currentSkinTemp(now: later)
        XCTAssertNil(stale, "half an hour with nothing new is no longer the current reading")
    }

    func testTheTileSpo2CountMatchesTheUploadedRowsForTheSameWindow() async throws {
        let repo = try await makeRepo(twoHours())
        let banked = await repo.spo2Readings(from: base, to: base + 7_200)
        let tile = try XCTUnwrap(banked)
        XCTAssertEqual(tile.count, 45)
        XCTAssertEqual(tile.latestTs, base + 3_028)
        let streams = twoHours()
        let uploaded = CloudCapture.rows(from: streams, provenance: .history, family: .whoop5,
                                         wallClockRef: nil, deviceClockRef: nil, receivedAtMs: 0,
                                         characteristic: nil, deviceId: dev)
        XCTAssertEqual(uploaded.filter { $0.stream == .event }.count, tile.count)
    }
}

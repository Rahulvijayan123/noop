import XCTest
import WhoopProtocol
@testable import Strand

/// The Skin Temp and Blood Oxygen Key Metrics tiles read the strap's banked samples directly, and the
/// uploader turns the same samples into Supabase rows. These pin both halves: what a tile may call a
/// current reading, and that every reading the strap sends is counted once and uploaded once.
final class KeyMetricReadingsTests: XCTestCase {

    private let now = 1_790_800_000

    // MARK: current skin temperature

    func testNewestWornSampleIsTheCurrentReadingInCelsius() throws {
        let samples = [SkinTempSample(ts: now - 240, raw: 3310),
                       SkinTempSample(ts: now - 60, raw: 3342),
                       SkinTempSample(ts: now - 120, raw: 3321)]
        let reading = try XCTUnwrap(KeyMetricReadings.currentSkinTemp(samples, family: .whoop5, now: now))
        XCTAssertEqual(reading.ts, now - 60)
        XCTAssertEqual(reading.celsius, 33.42, accuracy: 1e-9, "5/MG register is centidegrees")
    }

    func testAnOffWristSampleIsNotASkinTemperature() {
        // 22.47 C is the ambient reading of a strap lying on a table (the proven off-wrist fixture, raw 2247).
        let samples = [SkinTempSample(ts: now - 30, raw: 2247)]
        XCTAssertNil(KeyMetricReadings.currentSkinTemp(samples, family: .whoop5, now: now))
        XCTAssertNil(KeyMetricReadings.currentSkinTemp([SkinTempSample(ts: now - 30, raw: 4500)],
                                                       family: .whoop5, now: now), "and 45 C is a fault")
    }

    func testOnlyTheNewestSampleCounts() {
        // Worn a minute ago, lifted off since: the newest sample is ambient, so there is no current reading,
        // and an older worn sample must not stand in for it.
        let samples = [SkinTempSample(ts: now - 90, raw: 3340), SkinTempSample(ts: now - 10, raw: 2300)]
        XCTAssertNil(KeyMetricReadings.currentSkinTemp(samples, family: .whoop5, now: now))
    }

    func testASampleOlderThanThirtyMinutesIsNotCurrent() {
        let edge = now - KeyMetricReadings.currentSkinTempSeconds
        XCTAssertNotNil(KeyMetricReadings.currentSkinTemp([SkinTempSample(ts: edge, raw: 3300)],
                                                          family: .whoop5, now: now))
        XCTAssertNil(KeyMetricReadings.currentSkinTemp([SkinTempSample(ts: edge - 1, raw: 3300)],
                                                       family: .whoop5, now: now))
    }

    func testAStrapClockAheadOfThePhoneReadsAsNow() throws {
        let reading = try XCTUnwrap(KeyMetricReadings.currentSkinTemp(
            [SkinTempSample(ts: now + 90, raw: 3300)], family: .whoop5, now: now))
        XCTAssertEqual(reading.ts, now)
    }

    func testAWhoop4NeverGetsALiveAbsoluteTemperature() {
        // The 4.0 register is a raw ADC on a provisional map; the nightly deviation stays its only number.
        XCTAssertNil(KeyMetricReadings.currentSkinTemp([SkinTempSample(ts: now - 5, raw: 830)],
                                                       family: .whoop4, now: now))
    }

    func testNoSamplesIsNoReading() {
        XCTAssertNil(KeyMetricReadings.currentSkinTemp([], family: .whoop5, now: now))
    }

    // MARK: SpO2 readings

    func testReadingsCountOnlyInBandBytesOncePerSecond() throws {
        let aux = [V18AuxSample(ts: 10, auxByte82: 96),
                   V18AuxSample(ts: 11, auxByte82: 0),
                   V18AuxSample(ts: 12, auxByte82: 128),     // saturation sentinel
                   V18AuxSample(ts: 13, auxByte82: 69),      // diagnostic code
                   V18AuxSample(ts: 14, auxByte82: 94),
                   V18AuxSample(ts: 14, auxByte82: 95),      // same second again: still one reading
                   V18AuxSample(ts: 15)]
        let readings = try XCTUnwrap(KeyMetricReadings.spo2Readings(aux))
        XCTAssertEqual(readings.count, 2, "seconds 10 and 14")
        XCTAssertEqual(readings.latestTs, 14)
    }

    func testAnAwakeStretchHasNoReadingsAndSaysSo() {
        // The strap writes zero into @82 while awake; that is its schedule, so there is nothing to count.
        let aux = (0..<3600).map { V18AuxSample(ts: 1_790_760_000 + $0, auxByte82: 0) }
        XCTAssertNil(KeyMetricReadings.spo2Readings(aux))
        XCTAssertNil(KeyMetricReadings.spo2Readings([]))
    }

    func testTheNightWindowRunsFromSixPmTheEveningBeforeToSixPmAndClampsToNow() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let dayStart = try XCTUnwrap(cal.date(from: DateComponents(year: 2026, month: 10, day: 5)))
        let pastDay = KeyMetricReadings.spo2NightWindow(dayStart: dayStart, now: dayStart.addingTimeInterval(86_400 * 3),
                                                        calendar: cal)
        XCTAssertEqual(pastDay.from, Int(dayStart.timeIntervalSince1970) - 6 * 3600)
        XCTAssertEqual(pastDay.to, Int(dayStart.timeIntervalSince1970) + 18 * 3600)
        let midMorning = dayStart.addingTimeInterval(10 * 3600)
        let today = KeyMetricReadings.spo2NightWindow(dayStart: dayStart, now: midMorning, calendar: cal)
        XCTAssertEqual(today.to, Int(midMorning.timeIntervalSince1970), "today's window ends now")
        let nextDay = cal.date(byAdding: .day, value: 1, to: dayStart)!
        XCTAssertEqual(KeyMetricReadings.spo2NightWindow(dayStart: nextDay, now: nextDay.addingTimeInterval(86_400),
                                                         calendar: cal).from,
                       pastDay.to, "consecutive days' windows meet without overlapping")
    }

    // MARK: "Every reading" series

    func testBankedSeriesKeepsEveryReadingWhenNotBucketed() throws {
        let series = KeyMetricReadings.bankedSeries([(ts: 30, value: 96), (ts: 10, value: 94), (ts: 20, value: 99)],
                                                    bucketSeconds: 1)
        XCTAssertEqual(series.points.map(\.ts), [10, 20, 30], "oldest first")
        XCTAssertEqual(series.points.map(\.value), [94, 99, 96])
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual([series.firstTs, series.lastTs], [10, 30])
        XCTAssertEqual(series.lastValue, 96, "the newest raw reading")
        XCTAssertEqual([series.minValue, series.maxValue], [94, 99])
    }

    func testBankedSeriesBucketsToMeansButCountsAndRangesTheRawReadings() {
        // Two 5-minute buckets: [0,300) holds 10 and 20, [300,600) holds 40.
        let series = KeyMetricReadings.bankedSeries([(ts: 10, value: 10), (ts: 290, value: 20), (ts: 310, value: 40)],
                                                    bucketSeconds: 300)
        XCTAssertEqual(series.points.map(\.ts), [0, 300])
        XCTAssertEqual(series.points.map(\.value), [15, 40])
        XCTAssertEqual(series.count, 3, "the raw readings, not the buckets")
        XCTAssertEqual([series.minValue, series.maxValue], [10, 40], "raw extremes, not bucket means")
        XCTAssertEqual(series.lastValue, 40)
    }

    func testBankedSeriesOfNothingIsEmptyButKeepsTheStatusByteCount() {
        let series = KeyMetricReadings.bankedSeries([], bucketSeconds: 1, statusBytes: 12)
        XCTAssertEqual(series.count, 0)
        XCTAssertTrue(series.points.isEmpty)
        XCTAssertNil(series.lastValue)
        XCTAssertEqual(series.statusBytes, 12)
    }

    func testHourlyCountsSumTheRawReadingsBehindEachPointNotThePointCount() {
        // One full worn hour of skin temperature (3,600 per-second samples in twelve 5-minute buckets), the next
        // hour short because the strap came off 20 minutes in.
        var readings: [(ts: Int, value: Double)] = []
        let hour0 = 1_790_712_000 - 1_790_712_000 % 3600
        for s in 0..<3600 { readings.append((hour0 + s, 33)) }
        for s in 0..<1200 { readings.append((hour0 + 3600 + s, 33)) }
        let series = KeyMetricReadings.bankedSeries(readings, bucketSeconds: 300)
        let hourly = KeyMetricReadings.hourlyCounts(series.points)
        XCTAssertEqual(hourly.map(\.hourStart), [hour0, hour0 + 3600])
        XCTAssertEqual(hourly.map(\.count), [3600, 1200], "raw samples per hour, not 12 and 4 bucket means")
        XCTAssertEqual(hourly.map(\.count).reduce(0, +), series.count)
    }

    func testEachSpo2ReadingCountsAsOneInItsHour() {
        let base = 1_790_712_000 - 1_790_712_000 % 3600
        let series = KeyMetricReadings.bankedSeries([(ts: base + 5, value: 96), (ts: base + 9, value: 97),
                                                     (ts: base + 3600 + 1, value: 95)], bucketSeconds: 1)
        XCTAssertEqual(KeyMetricReadings.hourlyCounts(series.points).map(\.count), [2, 1])
        XCTAssertTrue(KeyMetricReadings.hourlyCounts([]).isEmpty)
    }

    func testRunsBreakWhereTheStrapBankedNothingSoAGapIsDrawnAsAGap() {
        typealias P = KeyMetricReadings.BankedSeries.Point
        let points = [P(ts: 0, value: 1), P(ts: 300, value: 1), P(ts: 600, value: 1),
                      P(ts: 600 + 901, value: 2), P(ts: 600 + 901 + 300, value: 2)]
        let runs = KeyMetricReadings.runs(points, maxGapSeconds: 15 * 60)
        XCTAssertEqual(runs.map { $0.map(\.ts) }, [[0, 300, 600], [1501, 1801]], "a 901 s hole splits the line")
        XCTAssertEqual(KeyMetricReadings.runs(points, maxGapSeconds: 901).count, 1, "exactly the limit does not")
        XCTAssertTrue(KeyMetricReadings.runs([], maxGapSeconds: 60).isEmpty)
    }

    /// Last night on a real 5.0/MG: 720 nonzero `@82` bytes across nine hours of 30-second windows, of which 178
    /// were percentages. The other 542 are status codes and saturation sentinels, so they are counted apart
    /// and never become readings or uploaded rows.
    func testAnOvernightOfMostlyStatusBytesCountsTheCodesApartFromTheReadings() {
        let codes = [2, 8, 32, 40, 128, 160, 168, 69]
        var aux: [V18AuxSample] = []
        for i in 0..<720 {
            let value = i < 178 ? 90 + i % 9 : codes[i % codes.count]
            aux.append(V18AuxSample(ts: 1_790_750_000 + i, auxByte82: value))
        }
        aux += (720..<3000).map { V18AuxSample(ts: 1_790_750_000 + $0, auxByte82: 0) }   // zeros are nothing
        XCTAssertEqual(KeyMetricReadings.spo2Readings(aux)?.count, 178)
        XCTAssertEqual(KeyMetricReadings.spo2StatusByteCount(aux), 542)
        let series = KeyMetricReadings.bankedSeries(
            Spo2StrapEstimate.readings(from: aux).map { (ts: $0.ts, value: Double($0.percent)) },
            bucketSeconds: 1, statusBytes: KeyMetricReadings.spo2StatusByteCount(aux))
        XCTAssertEqual(series.points.count, 178)
        XCTAssertEqual(series.statusBytes, 542)
    }

    func testStatusBytesAreCountedOncePerSecondAndIgnoreZeroAndAbsent() {
        let aux = [V18AuxSample(ts: 1, auxByte82: 160),
                   V18AuxSample(ts: 1, auxByte82: 160),   // same second again
                   V18AuxSample(ts: 2, auxByte82: 0),
                   V18AuxSample(ts: 3),
                   V18AuxSample(ts: 4, auxByte82: 97)]    // a reading, not a status byte
        XCTAssertEqual(KeyMetricReadings.spo2StatusByteCount(aux), 1)
    }

    func testDeepTimelineTellsAPercentageFromTheFourPointZeroRatioProxy() {
        XCTAssertTrue(FullDayChartView.spo2IsPercent(97))
        XCTAssertTrue(FullDayChartView.spo2IsPercent(50))
        XCTAssertFalse(FullDayChartView.spo2IsPercent(0.83), "the 4.0's red/IR ratio stays unitless")
        XCTAssertFalse(FullDayChartView.spo2IsPercent(nil))
    }

    // MARK: every reading the strap sends becomes exactly one uploaded row

    private func uploadRows(_ streams: Streams) -> [CloudJournalRecord] {
        CloudCapture.rows(from: streams, provenance: .history, family: .whoop5,
                          wallClockRef: nil, deviceClockRef: nil, receivedAtMs: 0,
                          characteristic: nil, deviceId: "my-whoop")
    }

    private func key(_ record: CloudJournalRecord) throws -> [String: Any] {
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: record.payload) as? [String: Any])
        return try XCTUnwrap(payload["key"] as? [String: Any])
    }

    /// An 8-hour night at the strap's 1 Hz: skin temperature every second, and the SpO2 byte in-band for
    /// 430 seconds (the documented 400 to 500 a night), zero otherwise.
    func testAFullNightUploadsEveryReadingOnceAndEverySkinTemperatureSample() throws {
        let start = 1_790_750_000
        let seconds = 8 * 3600
        let readingSeconds = Set(stride(from: 0, to: seconds, by: 67).prefix(430))   // 430 distinct seconds
        var aux: [V18AuxSample] = []
        var skin: [SkinTempSample] = []
        aux.reserveCapacity(seconds); skin.reserveCapacity(seconds)
        for i in 0..<seconds {
            aux.append(V18AuxSample(ts: start + i, auxByte82: readingSeconds.contains(i) ? 90 + i % 9 : 0))
            skin.append(SkinTempSample(ts: start + i, raw: 3300 + i % 40))
        }
        XCTAssertEqual(readingSeconds.count, 430)

        let records = uploadRows(Streams(skinTemp: skin, v18Aux: aux))

        let events = records.filter { $0.stream == .event }
        XCTAssertEqual(events.count, 430, "one event row per in-band second, none dropped, none invented")
        XCTAssertGreaterThan(events.count, 200, "the night's reading count is well past the 200 floor")
        let eventKeys = try events.map { try key($0) }
        XCTAssertTrue(eventKeys.allSatisfy { $0["kind"] as? String == Spo2StrapEstimate.eventKind })
        XCTAssertEqual(Set(eventKeys.compactMap { $0["ts"] as? Int }).count, 430,
                       "no two rows share a (ts, kind) key, so the receiver can never see a conflict")

        let temps = records.filter { $0.stream == .skinTempSample }
        XCTAssertEqual(temps.count, seconds, "every second's skin temperature is a row")
        XCTAssertEqual(Set(try temps.compactMap { try key($0)["ts"] as? Int }).count, seconds)

        // The number the Blood Oxygen tile shows for the same samples is the number of event rows sent.
        XCTAssertEqual(KeyMetricReadings.spo2Readings(aux)?.count, events.count)
    }

    func testADayAwakeUploadsNoSpo2ReadingsAndStillUploadsEveryTemperature() {
        let start = 1_790_700_000
        let seconds = 16 * 3600
        let aux = (0..<seconds).map { V18AuxSample(ts: start + $0, auxByte82: 0) }
        let skin = (0..<seconds).map { SkinTempSample(ts: start + $0, raw: 3280) }
        let records = uploadRows(Streams(skinTemp: skin, v18Aux: aux))
        XCTAssertEqual(records.filter { $0.stream == .event }.count, 0,
                       "the strap writes no SpO2 while awake, and the uploader does not make any up")
        XCTAssertEqual(records.filter { $0.stream == .skinTempSample }.count, seconds)
    }
}

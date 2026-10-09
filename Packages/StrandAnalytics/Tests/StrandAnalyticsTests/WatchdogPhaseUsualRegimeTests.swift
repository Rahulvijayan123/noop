import XCTest
@testable import StrandAnalytics
import WhoopProtocol

/// WP8 / D4-06 (corrected): the awake phase usual is a quiet-still regime with a real day median,
/// and the live tick records when the still usual stands in for another context.
final class WatchdogPhaseUsualRegimeTests: XCTestCase {
    private let prompt = UniTSPrompt(hr: 58, rhr: 58, hrv: 48, temp: 33.1, resp: 14, spo2: 97)

    // MARK: Day median

    func testP2MedianIsExactForFewValuesAndRobustToALateSpike() {
        var m = WatchdogP2Median()
        XCTAssertNil(m.median)
        [70, 60, 65].forEach { m.add($0) }
        XCTAssertEqual(m.median, 65)
        m.add(.nan)
        XCTAssertEqual(m.count, 3, "non-finite values are not observations")
        m.add(61)
        XCTAssertEqual(m.median, 63)

        // A still phase that ends with a brief HR rise. The old EMA (a = 0.12) was dragged up by
        // the tail; the median stays on the bulk of the day.
        var day = WatchdogP2Median()
        var ema = 0.0
        let values = Array(repeating: 68.0, count: 100) + Array(repeating: 110.0, count: 10)
        for (i, v) in values.enumerated() {
            day.add(v + Double(i % 3) - 1)
            ema = i == 0 ? v : 0.88 * ema + 0.12 * v
        }
        XCTAssertEqual(day.median ?? 0, 68, accuracy: 1.0)
        XCTAssertGreaterThan(ema, 95, "the EMA the old code called dayMedian")
    }

    func testP2MedianTracksTheSampleMedianOfAnUnorderedStream() {
        var m = WatchdogP2Median()
        var xs: [Double] = []
        var seed: UInt64 = 7
        for _ in 0..<600 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            let x = 55 + Double(seed >> 40) / Double(1 << 24) * 30
            xs.append(x)
            m.add(x)
        }
        let s = xs.sorted()
        let exact = (s[299] + s[300]) / 2
        XCTAssertEqual(m.median ?? 0, exact, accuracy: 1.0)
        let round = try? JSONDecoder().decode(WatchdogP2Median.self, from: JSONEncoder().encode(m))
        XCTAssertEqual(round, m)
    }

    // MARK: Regime purity

    func testOnlyQuietStillTrainsTheAwakeStillUsual() {
        XCTAssertTrue(WatchdogPhaseUsualStore.trainsStillUsual(phase: .midday, cls: .still))
        XCTAssertFalse(WatchdogPhaseUsualStore.trainsStillUsual(phase: .midday, cls: .stand),
                       "occupancy stand is fidget, not a posture, and not quiet still")
        XCTAssertFalse(WatchdogPhaseUsualStore.trainsStillUsual(phase: .morning, cls: .unknown),
                       "no motion evidence is not still")
        XCTAssertTrue(WatchdogPhaseUsualStore.trainsStillUsual(phase: .sleep, cls: .unknown))
        // `stand` is never promoted to a family / posture key.
        XCTAssertEqual(WatchdogPhaseUsualStore.family(label: .normalStillAwake, cls: .stand), .still)
    }

    private func window(now: Int, motion: Double, quietSteps: Bool) throws -> WatchdogWindow {
        var feed = Watchdog.syntheticFeed(now: now, hr: 58, hrv: 48, temp: 33.1, resp: 14, motion: motion)
        if quietSteps {
            // Still-class step ticks make the minute IMU/step evidenced; occupancy picks still vs stand.
            feed.steps = stride(from: now - WatchdogConfig.contextSeconds, to: now, by: 2).enumerated().map {
                StepSample(ts: $0.element, counter: $0.offset, activityClass: 0)
            }
        }
        guard case .success(let w) = WatchdogWindowBuilder.build(feed) else { throw XCTSkip("window") }
        return w
    }

    /// An established awake-rest HR reference: the Watchdog only learns a usual from minutes a Layer 1 reference
    /// screened (`WatchdogExpectation`).
    private func awakeRestReference(asOf: Date) -> LBEvaluation {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let c = cal.dateComponents([.year, .month, .day], from: asOf)
        let day = String(format: "%04d-%02d-%02d", c.year!, c.month!, c.day!)
        let t = LongitudinalBaseline.isoEpochDay(day)!
        let rows = (1...40).map {
            LBDailyObservation(day: LongitudinalBaseline.isoFromEpochDay(t - $0), value: 57 + Double($0 % 3),
                               qualityStatus: .ok, coverage: 300)
        }
        return LongitudinalBaseline.evaluate(asOf: day, series: .awakeRestHR, observations: rows)
    }

    private func ticks(motion: Double, quietSteps: Bool, minutes: Int = 14) throws -> WatchdogCarry {
        // Midday local, away from any civil-day roll.
        var cal = Calendar.current
        cal.timeZone = .current
        let noon = cal.date(bySettingHour: 13, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
        let start = Int(noon.timeIntervalSince1970) - Int(noon.timeIntervalSince1970) % 60
        let reference = awakeRestReference(asOf: noon)
        XCTAssertNotNil(WatchdogLiveReferences.lookup([reference], series: [.awakeRestHR]))
        var carry = WatchdogCarry.empty
        for i in 0..<minutes {
            let now = start + i * 60
            let r = Watchdog.evaluate(window: .success(try window(now: now, motion: motion, quietSteps: quietSteps)),
                                      prompt: prompt, evaluations: [reference], nowUnix: now, previous: carry)
            carry = r.carry
        }
        return carry
    }

    func testStillTicksFeedTheMiddayStillKeyWithAMedian() throws {
        let carry = try ticks(motion: 0.02, quietSteps: true)
        let id = WatchdogPhaseKey(phase: .midday, family: .still).id
        XCTAssertGreaterThan(carry.sessionKeyTicks[id] ?? 0, 0)
        let med = try XCTUnwrap(carry.sessionMedianByKey[id])
        XCTAssertEqual(med[0].median ?? 0, 58, accuracy: 0.5)
        XCTAssertEqual(med[0].count, carry.sessionNativeCountByKey[id]?[0])
    }

    func testStandOccupancyTicksDoNotTrainTheStillKey() throws {
        let stand = try window(now: 1_790_000_000, motion: 0.16, quietSteps: true)
        XCTAssertEqual(WatchdogActivityClass.labels(logits: stand.activityLogits).last, "stand")
        let carry = try ticks(motion: 0.16, quietSteps: true)
        let id = WatchdogPhaseKey(phase: .midday, family: .still).id
        XCTAssertNil(carry.sessionKeyTicks[id], "stand-class ticks stay out of the quiet-still usual")
        XCTAssertNil(carry.sessionMedianByKey[id])
    }

    // MARK: Provenance

    private func matureStore() -> WatchdogPhaseUsualStore {
        var store = WatchdogPhaseUsualStore.empty
        var e = WatchdogPhaseEntry()
        e.center = [66, 58, 48, 33.1, 14, 97]
        e.nDays = WatchdogPhaseUsualStore.matureDays
        store.entries[WatchdogPhaseKey(phase: .midday, family: .still).id] = e
        return store
    }

    func testWalkKeyKeepsStillFirstAnchorButRecordsFallback() {
        let store = matureStore()
        let walk = WatchdogPhaseKey(phase: .midday, family: .walk)
        let (blended, prov) = store.blendPromptWithProvenance(prompt, key: walk, liveClass: .walk)
        XCTAssertEqual(blended, store.blendPrompt(prompt, key: walk), "still-first HR anchor unchanged")
        XCTAssertEqual(prov.hrAnchorKey, WatchdogPhaseKey(phase: .midday, family: .still).id)
        XCTAssertTrue(prov.fallbackUsed)
        XCTAssertEqual(prov.fallbackFamily, "still")
        XCTAssertEqual(prov.posture, WatchdogUsualProvenance.postureUnresolved)
        XCTAssertEqual(prov.dayReducer, WatchdogUsualProvenance.dayReducerMedian)
    }

    func testStillKeyOnStandOrUnknownMinuteIsAFallbackButQuietStillIsNot() {
        let store = matureStore()
        let still = WatchdogPhaseKey(phase: .midday, family: .still)
        XCTAssertFalse(store.blendPromptWithProvenance(prompt, key: still, liveClass: .still).1.fallbackUsed)
        XCTAssertTrue(store.blendPromptWithProvenance(prompt, key: still, liveClass: .stand).1.fallbackUsed)
        XCTAssertTrue(store.blendPromptWithProvenance(prompt, key: still, liveClass: .unknown).1.fallbackUsed)
        let none = WatchdogPhaseUsualStore.empty.blendPromptWithProvenance(prompt, key: still, liveClass: .still).1
        XCTAssertNil(none.hrAnchorKey, "no mature phase usual: Layer 1 prompt only")
        XCTAssertFalse(none.fallbackUsed)
    }

    func testEvaluateSurfacesProvenanceAndOldResultsStillDecode() throws {
        var carry = WatchdogCarry.empty
        carry.phaseUsual = matureStore()
        var cal = Calendar.current
        cal.timeZone = .current
        let noon = cal.date(bySettingHour: 13, minute: 0, second: 0, of: Date(timeIntervalSince1970: 1_790_000_000))!
        let now = Int(noon.timeIntervalSince1970)
        let r = Watchdog.evaluate(window: .success(try window(now: now, motion: 0.02, quietSteps: true)),
                                  prompt: prompt, nowUnix: now, previous: carry)
        let prov = try XCTUnwrap(r.usualProvenance)
        XCTAssertEqual(prov.requestedKey, WatchdogPhaseKey(phase: .midday, family: .still).id)
        XCTAssertFalse(prov.fallbackUsed)
        // A result persisted before the field existed decodes with nil provenance. Minutes with no expectation
        // carry NaN, so the round trip spells non-finite numbers out.
        let encoder = JSONEncoder()
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        var json = try JSONSerialization.jsonObject(with: encoder.encode(r)) as! [String: Any]
        json["usualProvenance"] = nil
        let old = try decoder.decode(WatchdogResult.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.usualProvenance)
    }
}

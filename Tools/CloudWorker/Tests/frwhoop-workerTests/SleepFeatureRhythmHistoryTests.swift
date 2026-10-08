// SleepFeatureRhythmHistoryTests.swift
//
// spec-02 rhythm history (docs/spec-02/CONTRACT.md §5.1): the per-day hourly fold of the
// pass's own rows, the snapshot record round trip, the bounded loader, and the wire
// assembly (conversion, nulls never 0, digest, bounds, mixed families). DB-free.

import XCTest
@testable import frwhoop_worker
import StrandAnalytics
import WhoopProtocol

final class SleepFeatureRhythmHistoryTests: XCTestCase {

    typealias RH = SleepFeatureRhythmHistory

    /// 2026-09-10T00:00:00Z — a UTC day keeps the hour arithmetic checkable.
    let d0 = 1_788_998_400

    private func seconds(_ from: Int, _ to: Int, every step: Int = 1) -> [Int] {
        stride(from: from, to: to, by: step).map { $0 }
    }

    // MARK: - Day fold

    func testBuildDayAppliesMinuteRulesAndHourBins() {
        let dayEnd = d0 + 86_400
        // HR 1 Hz all day, except hour 3 (off-wrist: no HR at all).
        var hr = seconds(d0, dayEnd).filter { ($0 - d0) / 3600 != 3 }.map { HRSample(ts: $0, bpm: 60) }
        // duplicate seconds must not inflate coverage or move the mean
        hr += (0..<10).map { HRSample(ts: d0 + $0, bpm: 200) }
        // Temperature 1 Hz at 33.00 °C (5/MG raw 3300); hour 5 thins to 20 s per minute,
        // hour 9 is out of the plausible band (20 °C).
        let temp: [SkinTempSample] = seconds(d0, dayEnd).compactMap { (ts: Int) -> SkinTempSample? in
            let hour = (ts - d0) / 3600
            if hour == 5 && (ts - d0) % 60 >= 20 { return nil }
            return SkinTempSample(ts: ts, raw: hour == 9 ? 2000 : 3300 + (hour == 12 ? 50 : 0))
        }
        // Gravity: hour 7 moves every other second (Δ = 0.02 g, then back); hour 8 has a
        // sample only every 2 s (no one-second adjacency); elsewhere perfectly still.
        let gravity: [GravitySample] = seconds(d0 - 1, dayEnd).compactMap { (ts: Int) -> GravitySample? in
            let hour = (ts - d0) / 3600
            if hour == 8 && ts % 2 == 1 { return nil }
            let z: Double = (hour == 7 && ts % 2 == 0) ? 1.02 : 1.0
            return GravitySample(ts: ts, x: 0, y: 0, z: z)
        }
        let day = RH.buildDay(day: "2026-09-10", timezoneId: "UTC", dayStart: d0, dayEnd: dayEnd,
                              family: .whoop5, revision: 9, hr: hr, skinTemp: temp, gravity: gravity)
        XCTAssertEqual(day.bins.count, 23)                      // hour 3: no signal at all
        XCTAssertNil(day.bins.first { $0.start == d0 + 3 * 3600 })
        let byHour = Dictionary(uniqueKeysWithValues: day.bins.map { (($0.start - d0) / 3600, $0) })
        XCTAssertEqual(byHour[0]?.skinTempRaw, 3300)
        XCTAssertEqual(byHour[0]?.skinTempValidMinutes, 60)
        XCTAssertEqual(byHour[0]?.hrMeanBpm, 60)                // duplicates collapsed (first wins)
        XCTAssertEqual(byHour[0]?.hrValidMinutes, 60)
        XCTAssertEqual(byHour[12]?.skinTempRaw, 3350)
        XCTAssertNil(byHour[5]?.skinTempRaw)                    // 20 s per minute < 30: thin
        XCTAssertEqual(byHour[5]?.skinTempValidMinutes, 0)
        XCTAssertEqual(byHour[5]?.hrValidMinutes, 60)           // HR still supported
        XCTAssertNil(byHour[9]?.skinTempRaw)                    // out of band, never a value
        XCTAssertEqual(byHour[0]?.movementSPerMin, 0)           // still is a true 0 (worn, observed)
        XCTAssertEqual(byHour[0]?.movementValidMinutes, 60)
        XCTAssertEqual(byHour[7]?.movementSPerMin ?? -1, 60, accuracy: 1e-9)  // every adjacency moves
        XCTAssertNil(byHour[8]?.movementSPerMin)                // no adjacency: unknown, not still
        XCTAssertEqual(byHour[8]?.movementValidMinutes, 0)
        XCTAssertEqual(day.revision, 9)
        XCTAssertEqual(day.deviceFamily, "whoop5")
    }

    func testBuildDayCoversTheTrueLocalDayIncludingDST() {
        // 2026-11-01 in Los Angeles is a 25 h day (PDT -> PST).
        let tz = TimeZone(identifier: "America/Los_Angeles")!
        let ds = DayScorer.dayStartUnix("2026-11-01", tz: tz)!
        let de = DayScorer.nextDayStartUnix(after: ds, tz: tz)
        XCTAssertEqual(de - ds, 25 * 3600)
        let hr = seconds(ds - 3600, de + 3600).map { HRSample(ts: $0, bpm: 55) }
        let day = RH.buildDay(day: "2026-11-01", timezoneId: tz.identifier, dayStart: ds, dayEnd: de,
                              family: .whoop5, revision: 1, hr: hr, skinTemp: [], gravity: [])
        XCTAssertEqual(day.bins.count, 25)
        XCTAssertEqual(day.bins.first?.start, ds)
        XCTAssertEqual(day.bins.last?.start, de - 3600)
        XCTAssertTrue(day.bins.allSatisfy { $0.skinTempRaw == nil && $0.movementSPerMin == nil })
    }

    func testBuildDayCostOnAFullScoringWindow() {
        // The pass's real input: 84 h of 1 Hz HR, temperature and gravity (~302 k rows each).
        let from = d0 - 30 * 3600, to = d0 + 54 * 3600
        let hr = seconds(from, to).map { HRSample(ts: $0, bpm: 60 + $0 % 7) }
        let temp = seconds(from, to).map { SkinTempSample(ts: $0, raw: 3300 + $0 % 13) }
        let gravity = seconds(from, to).map { (ts: Int) -> GravitySample in
            GravitySample(ts: ts, x: 0, y: 0, z: 1.0 + Double(ts % 3) * 0.01)
        }
        // Reference: one plain pass over the same rows, so the cost reads as a ratio that does not
        // depend on how loaded the machine is.
        let refStarted = Date()
        var checksum = 0
        for s in hr { checksum &+= s.ts &+ s.bpm }
        for s in temp { checksum &+= s.ts &+ s.raw }
        for g in gravity { checksum &+= g.ts &+ Int(g.z * 100) }
        let refMs = Date().timeIntervalSince(refStarted) * 1000
        XCTAssertNotEqual(checksum, 0)
        let started = Date()
        let day = RH.buildDay(day: "2026-09-10", timezoneId: "UTC", dayStart: d0, dayEnd: d0 + 86_400,
                              family: .whoop5, revision: 1, hr: hr, skinTemp: temp, gravity: gravity)
        let ms = Date().timeIntervalSince(started) * 1000
        print("rhythm buildDay on 3 x \(hr.count) rows: \(Int(ms)) ms; one plain pass over the same rows: "
              + "\(Int(refMs)) ms (ratio \(String(format: "%.1f", ms / max(refMs, 0.001))))")
        XCTAssertEqual(day.bins.count, 24)
        XCTAssertTrue(day.bins.allSatisfy { $0.skinTempValidMinutes == 60 && $0.movementValidMinutes == 60 })
    }

    // MARK: - Snapshot record

    func testSnapshotRecordRoundTrips() throws {
        let day = RH.Day(day: "2026-09-10", timezone: "UTC", dayStart: d0, dayEnd: d0 + 86_400,
                         deviceFamily: "whoop5", rulesVersion: RH.Rules.rulesVersion, revision: 3,
                         bins: [RH.Bin(start: d0, skinTempRaw: 3311.5, skinTempValidMinutes: 52,
                                       hrMeanBpm: nil, hrValidMinutes: 0,
                                       movementSPerMin: 4.25, movementValidMinutes: 57)])
        let json = RH.snapshotJSON(day)
        let data = try JSONSerialization.data(withJSONObject: json)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertTrue((obj["bins"] as? [[String: Any]])?.first?["hr_mean_bpm"] is NSNull)
        XCTAssertEqual(RH.parseSnapshotDay(obj, revision: 3), day)
        var other = obj
        other["rules_version"] = "rhythm-rules-0"
        XCTAssertNil(RH.parseSnapshotDay(other, revision: 3))   // other rules never mix in
    }

    // MARK: - Loader (one bounded query)

    private final class FakeDB: PostgresClientProtocol {
        let rows: [[String: String]]
        var calls: [(String, [String])] = []
        init(_ rows: [[String: String]]) { self.rows = rows }
        func query(_ sql: String, _ params: [String]) throws -> [[String: String]] {
            calls.append((sql, params))
            return rows
        }
    }

    private func recordText(_ day: RH.Day) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: RH.snapshotJSON(day)), encoding: .utf8)!
    }

    private func flatDay(_ i: Int, family: String = "whoop5", raw: Double = 3300, rev: Int64 = 1) -> RH.Day {
        let ds: Int = d0 + i * 86_400
        var bins: [RH.Bin] = []
        for h in 0..<24 {
            let still: Bool = h == 4
            let movement: Double? = still ? nil : 3.0
            let movementMinutes: Int = still ? 0 : 60
            let temp: Double = raw + Double(h)
            bins.append(RH.Bin(start: ds + h * 3600, skinTempRaw: temp, skinTempValidMinutes: 60,
                               hrMeanBpm: 60.0, hrValidMinutes: 60,
                               movementSPerMin: movement, movementValidMinutes: movementMinutes))
        }
        return RH.Day(day: isoDay(ds), timezone: "UTC", dayStart: ds, dayEnd: ds + 86_400,
                      deviceFamily: family, rulesVersion: RH.Rules.rulesVersion, revision: rev,
                      bins: bins)
    }

    private func isoDay(_ ts: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }

    func testLoadDaysReadsOnlyNewestPublishedRecords() throws {
        let good = flatDay(0, rev: 40)
        var stale = RH.snapshotJSON(flatDay(1))
        stale["rules_version"] = "rhythm-rules-0"
        let rows: [[String: String]] = [
            ["day": good.day, "rev": "40", "rhythm": try recordText(good)],
            ["day": isoDay(d0 + 86_400), "rev": "41",
             "rhythm": String(data: try JSONSerialization.data(withJSONObject: stale), encoding: .utf8)!],
            ["day": isoDay(d0 + 2 * 86_400), "rev": "42", "rhythm": ""],   // no rhythmDay published
        ]
        let db = FakeDB(rows)
        let days = try RH.loadDays(db: db, userId: "u", deviceId: "d", todayDay: "2026-09-14",
                                   algorithmVersion: "frwhoop-server-1")
        XCTAssertEqual(days, [good])
        XCTAssertEqual(db.calls.count, 1)                        // one bounded query
        XCTAssertEqual(db.calls[0].1, ["u", "d", "2026-09-14", "34", "frwhoop-server-1"])
        XCTAssertTrue(db.calls[0].0.contains("limit 1"))
        XCTAssertTrue(db.calls[0].0.contains("payload->'rhythmDay'"))
    }

    // MARK: - Assembly

    func testAssembleConvertsNullsDigestAndBounds() throws {
        let days = (0..<40).map { flatDay($0, rev: Int64(100 + $0)) }
        let wire = try XCTUnwrap(RH.assemble(days: days))
        XCTAssertEqual(wire["schema"] as? String, "rhythm-history-1")
        XCTAssertEqual(wire["bin_seconds"] as? Int, 3600)
        XCTAssertEqual(wire["device_family"] as? String, "whoop5")
        XCTAssertEqual(wire["conversion_identity"] as? String, "whoop5-centidegree")
        let rules = try XCTUnwrap(wire["rules"] as? [String: Any])
        XCTAssertEqual(rules["movement_threshold_g"] as? Double, 0.01)
        XCTAssertEqual(rules["minute_min_distinct_seconds"] as? Int, 30)
        let wdays = try XCTUnwrap(wire["days"] as? [[String: Any]])
        XCTAssertEqual(wdays.count, 35)                          // the newest 35 days only
        XCTAssertEqual(wdays.first?["day"] as? String, days[5].day)
        XCTAssertTrue(wdays.allSatisfy { (($0["bins"] as? [Any])?.count ?? 99) <= 26 })
        let bins = try XCTUnwrap(wdays[0]["bins"] as? [[String: Any]])
        XCTAssertEqual(bins[2]["skin_temp_c"] as? Double, 33.02)  // raw / 100
        XCTAssertTrue(bins[4]["movement_s_per_min"] is NSNull)    // missing is null ...
        XCTAssertEqual(bins[4]["movement_valid_minutes"] as? Int, 0) // ... never 0 s/min
        XCTAssertEqual(wdays[0]["revision"] as? Int64, 105)
        XCTAssertEqual(wdays[0]["timezone"] as? String, "UTC")
        let digest = try XCTUnwrap(wire["revision_digest"] as? String)
        XCTAssertEqual(digest.count, 64)
        // Any republished day changes the digest; an identical history does not.
        XCTAssertEqual(RH.assemble(days: days)?["revision_digest"] as? String, digest)
        var bumped = days
        bumped[20].revision += 1
        XCTAssertNotEqual(RH.assemble(days: bumped)?["revision_digest"] as? String, digest)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(wire))
    }

    func testAssembleKeepsNewestRevisionOfADuplicatedDayAndDropsImplausibleHours() throws {
        let old = flatDay(0, raw: 3300, rev: 1)
        let new = flatDay(0, raw: 3400, rev: 2)
        var hot = flatDay(1, raw: 4300, rev: 1)                  // 43 °C+: outside the band
        hot.revision = 5
        let wire = try XCTUnwrap(RH.assemble(days: [new, old, hot]))
        let wdays = try XCTUnwrap(wire["days"] as? [[String: Any]])
        XCTAssertEqual(wdays.count, 2)
        let first = try XCTUnwrap(wdays[0]["bins"] as? [[String: Any]])
        XCTAssertEqual(first[0]["skin_temp_c"] as? Double, 34.0)
        let second = try XCTUnwrap(wdays[1]["bins"] as? [[String: Any]])
        XCTAssertTrue(second.allSatisfy { $0["skin_temp_c"] is NSNull && $0["skin_temp_valid_minutes"] as? Int == 0 })
        XCTAssertTrue(second.allSatisfy { $0["hr_mean_bpm"] as? Double == 60 })
    }

    func testAssembleMarksMixedFamiliesAndUsesOneWhoop4Anchor() throws {
        let w4a = flatDay(0, family: "whoop4", raw: 1280)
        let w4b = flatDay(1, family: "whoop4", raw: 1300)
        let wire4 = try XCTUnwrap(RH.assemble(days: [w4a, w4b]))
        XCTAssertEqual(wire4["device_family"] as? String, "whoop4")
        let identity = try XCTUnwrap(wire4["conversion_identity"] as? String)
        XCTAssertTrue(identity.hasPrefix("whoop4-provisional-affine:anchor="))
        let wdays = try XCTUnwrap(wire4["days"] as? [[String: Any]])
        XCTAssertEqual(Set(wdays.compactMap { $0["conversion_identity"] as? String }), [identity])
        let a = try XCTUnwrap((wdays[0]["bins"] as? [[String: Any]])?[0]["skin_temp_c"] as? Double)
        let b = try XCTUnwrap((wdays[1]["bins"] as? [[String: Any]])?[0]["skin_temp_c"] as? Double)
        // One anchor for both days: the 20-unit raw difference stays 20 x 0.05 = 1.0 °C.
        XCTAssertEqual(b - a, 1.0, accuracy: 1e-6)

        let mixed = try XCTUnwrap(RH.assemble(days: [w4a, flatDay(1)]))
        XCTAssertEqual(mixed["device_family"] as? String, "mixed")
        XCTAssertEqual(mixed["conversion_identity"] as? String, "mixed")
        let mdays = try XCTUnwrap(mixed["days"] as? [[String: Any]])
        XCTAssertEqual(Set(mdays.compactMap { $0["device_family"] as? String }), ["whoop4", "whoop5"])
    }

    func testAssembleReturnsNilWithoutAnyBins() {
        let empty = RH.Day(day: "2026-09-10", timezone: "UTC", dayStart: d0, dayEnd: d0 + 86_400,
                           deviceFamily: "whoop5", rulesVersion: RH.Rules.rulesVersion, revision: 1, bins: [])
        XCTAssertNil(RH.assemble(days: [empty]))
        XCTAssertNil(RH.assemble(days: []))
    }

    // MARK: - Request

    func testRequestCarriesTheRhythmHistoryOnlyWhenAssembled() throws {
        let night = SleepFeatureNightInput(nightId: "n", start: d0, end: d0 + 3600, isNap: false,
                                           userEdited: false,
                                           stages: [StageSegment(start: d0, end: d0 + 3600, stage: "light")])
        func input(_ rhythm: [String: Any]?) -> SleepFeatureEnrichment.AssemblyInput {
            SleepFeatureEnrichment.AssemblyInput(
                userId: "u", deviceId: "d", day: "2026-09-10", timezoneId: "UTC", inputRevision: 1,
                intervalStart: d0, intervalEnd: d0 + 86_400, stageAlgorithmVersion: "frwhoop-server-1",
                nights: [night], hr: [], tempCelsius: [], beats: [],
                breathTrack: SleepStager.respBreathTrack([]), history: nil, rhythmHistory: rhythm)
        }
        XCTAssertNil(SleepFeatureEnrichment.buildRequest(input(nil))["rhythm_history"])
        let wire = try XCTUnwrap(RH.assemble(days: [flatDay(0)]))
        let request = SleepFeatureEnrichment.buildRequest(input(wire))
        let sent = try XCTUnwrap(request["rhythm_history"] as? [String: Any])
        XCTAssertEqual(sent["revision_digest"] as? String, wire["revision_digest"] as? String)
        XCTAssertTrue(JSONSerialization.isValidJSONObject(request))
    }
}

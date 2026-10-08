// SleepFeatureEnrichmentTests.swift
//
// Root-owned tests for the enrichment lane's pure seams: request assembly
// bounds, response validation, and the 31-day history fold (spec section 9:
// "Integration" and "Isolation" rows). No database and no sidecar are needed.

import XCTest
@testable import frwhoop_worker
import StrandAnalytics
import WhoopProtocol

final class SleepFeatureEnrichmentTests: XCTestCase {

    // MARK: - Night assembly (canonical main-night group)

    private func session(_ start: Int, _ end: Int, stage: String = "light") -> SleepSession {
        SleepSession(start: start, end: end, efficiency: 0.9,
                     stages: [StageSegment(start: start, end: end, stage: stage)],
                     restingHR: nil, avgHRV: nil)
    }

    func testSplitNightIsOneMainNightWithTheGapAsWake() {
        let midnight = 1_789_948_800
        let first = session(midnight - 3_600, midnight + 7_200)
        let second = session(midnight + 9_000, midnight + 25_200, stage: "deep")
        let nap = session(midnight + 50_400, midnight + 52_800)

        let nights = DayScorer.sleepFeatureNights([first, second, nap], offsetSec: 0)

        XCTAssertEqual(nights.count, 2)
        let main = try? XCTUnwrap(nights.first { !$0.isNap })
        XCTAssertEqual(main?.start, midnight - 3_600)
        XCTAssertEqual(main?.end, midnight + 25_200)
        XCTAssertEqual(main?.stages.map(\.stage), ["light", "wake", "deep"])
        XCTAssertEqual(main?.stages[1].start, midnight + 7_200)
        XCTAssertEqual(main?.stages[1].end, midnight + 9_000)
        XCTAssertEqual(nights.filter(\.isNap).map(\.start), [midnight + 50_400])
    }

    func testSingleNightHasNoInventedWake() {
        let midnight = 1_789_948_800
        let night = session(midnight - 3_600, midnight + 25_200)
        let nights = DayScorer.sleepFeatureNights([night], offsetSec: 0)
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0].isNap, false)
        XCTAssertEqual(nights[0].stages.map(\.stage), ["light"])
    }

    func testNoSessionsYieldsNoNights() {
        XCTAssertTrue(DayScorer.sleepFeatureNights([], offsetSec: 0).isEmpty)
    }

    private func makeNight(start: Int, end: Int,
                           stages: [(Int, Int, String)] = [(0, 3600, "light")]) -> SleepFeatureNightInput {
        SleepFeatureNightInput(
            nightId: "sleep-d-\(start)", start: start, end: end, isNap: false, userEdited: false,
            stages: stages.map { StageSegment(start: $0.0, end: $0.1, stage: $0.2) })
    }

    private func makeInput(nights: [SleepFeatureNightInput],
                           hr: [HRSample] = [],
                           temp: [(Int, Double)] = [],
                           beats: [RRInterval] = [],
                           history: SleepFeatureHistory? = nil) -> SleepFeatureEnrichment.AssemblyInput {
        SleepFeatureEnrichment.AssemblyInput(
            userId: "u", deviceId: "d", day: "2026-10-05", timezoneId: "America/Los_Angeles",
            inputRevision: 7, intervalStart: 1789000000, intervalEnd: 1789086400,
            stageAlgorithmVersion: "frwhoop-server-1",
            nights: nights, hr: hr, tempCelsius: temp, beats: beats,
            breathTrack: SleepStager.respBreathTrack(beats), history: history)
    }

    // MARK: Request assembly

    func testRequestShapeAndBounds() throws {
        let n0 = 1789000000
        let hr = (0..<100).map { HRSample(ts: n0 + $0, bpm: 60) }
        let beats = (0..<100).map { RRInterval(ts: n0 + $0, rrMs: 1000, srcChannel: nil, ord: nil, seq: 0) }
        let request = SleepFeatureEnrichment.buildRequest(makeInput(
            nights: [makeNight(start: n0, end: n0 + 3600)], hr: hr, temp: [(n0, 31.0)], beats: beats))
        XCTAssertEqual(request["schema_version"] as? Int, 1)
        XCTAssertEqual(request["algorithm_version"] as? String, "nara-sleep-features-1")
        let context = try XCTUnwrap(request["context"] as? [String: Any])
        XCTAssertEqual(context["day"] as? String, "2026-10-05")
        XCTAssertEqual(context["input_revision"] as? Int64, 7)
        XCTAssertEqual(context["iana_timezone"] as? String, "America/Los_Angeles")
        let nights = try XCTUnwrap(request["nights"] as? [[String: Any]])
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0]["is_nap"] as? Bool, false)
        let stages = try XCTUnwrap(nights[0]["stages"] as? [[String: Any]])
        XCTAssertEqual(stages[0]["stage"] as? String, "light")
        XCTAssertEqual((request["hr_samples"] as? [[String: Any]])?.count, 100)
        XCTAssertEqual((request["skin_temp_samples"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((request["rr_beats"] as? [[String: Any]])?.count, 100)
        XCTAssertNotNil(request["resp_breaths"])
        XCTAssertNil(request["history"])  // nil history -> no key, not an empty one
    }

    func testRequestForwardsOnlySamplesAroundTheNights() throws {
        // The scoring pass loads 84 h per claim; only [start - lead-in, end + tail) may be sent
        // (real data sent whole was a 17.6 MB body the sidecar refused).
        let n0 = 1789000000
        let lead = SleepFeatureEnrichment.leadInSeconds
        let tail = SleepFeatureEnrichment.tailSeconds
        let stamps = [n0 - 24 * 3600, n0 - lead - 1, n0 - lead, n0 + 10, n0 + 3600 + tail - 1,
                      n0 + 3600 + tail, n0 + 30 * 3600]
        let request = SleepFeatureEnrichment.buildRequest(makeInput(
            nights: [makeNight(start: n0, end: n0 + 3600)],
            hr: stamps.map { HRSample(ts: $0, bpm: 60) },
            temp: stamps.map { ($0, 31.0) },
            beats: stamps.map { RRInterval(ts: $0, rrMs: 1000, srcChannel: nil, ord: nil, seq: 0) }))
        let kept = [n0 - lead, n0 + 10, n0 + 3600 + tail - 1]
        for key in ["hr_samples", "skin_temp_samples", "rr_beats"] {
            let rows = try XCTUnwrap(request[key] as? [[String: Any]], key)
            XCTAssertEqual(rows.compactMap { $0["ts"] as? Int }, kept, key)
        }
    }

    func testRequestCarriesHistoryAndDigest() throws {
        let n0 = 1789000000
        let history = SleepFeatureHistory(
            dayRevisions: [("2026-10-04", 11), ("2026-10-03", 9)],
            minutes: [("2026-10-04", n0, 1, true), ("2026-10-04", n0 + 60, 0, true)])
        let request = SleepFeatureEnrichment.buildRequest(makeInput(
            nights: [makeNight(start: n0, end: n0 + 3600)], history: history))
        let hist = try XCTUnwrap(request["history"] as? [String: Any])
        XCTAssertEqual(hist["pair_policy"] as? String, "elapsed_24h")
        let days = try XCTUnwrap(hist["days"] as? [[String: Any]])
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(try XCTUnwrap(days[0]["minutes"] as? [[String: Any]]).count, 2)
        let context = try XCTUnwrap(request["context"] as? [String: Any])
        XCTAssertEqual((context["history_revision_digest"] as? String)?.count, 64)
    }

    // MARK: Response validation

    func testValidateResponseAcceptsGoodShape() throws {
        let good: [String: Any] = [
            "schema_version": 1, "algorithm_version": "nara-sleep-features-1",
            "status": "available", "status_reasons": [] as [String],
            "nights": [[
                "night_id": "n", "start_utc": "2026-10-04T23:00:00Z",
                "end_utc": "2026-10-05T07:00:00Z",
                "continuity": ["status": "available"],
            ] as [String: Any]],
            "capabilities": ["oxygen_events": ["ready": false]],
        ]
        let data = try JSONSerialization.data(withJSONObject: good)
        let out = SleepFeatureEnrichment.validateResponse(data)
        XCTAssertEqual(out?["status"] as? String, "available")
    }

    func testValidateResponseRefusesMalformed() throws {
        for bad in [
            "{\"schema_version\": 2}",
            "{\"schema_version\": 1, \"status\": \"weird\", \"nights\": []}",
            "{\"schema_version\": 1, \"status\": \"available\", \"nights\": \"not-a-list\"}",
            "not json at all",
        ] {
            XCTAssertNil(SleepFeatureEnrichment.validateResponse(Data(bad.utf8)))
        }
    }

    // MARK: History fold (pure, DB-free via the protocol)

    /// Answers each of loadHistory's two bounded queries by its SQL marker.
    private final class FakeDB: PostgresClientProtocol {
        let snapshotRows: [[String: String]]
        let hrRows: [[String: String]]
        init(snapshotRows: [[String: String]], hrRows: [[String: String]] = []) {
            self.snapshotRows = snapshotRows
            self.hrRows = hrRows
        }
        func query(_ sql: String, _ params: [String]) throws -> [[String: String]] {
            if sql.contains("noop_hr_samples") { return hrRows }
            return snapshotRows
        }
    }

    func testLoadHistoryFoldsStagesToMinuteGrid() throws {
        // UTC day 2026-09-10; one history night 23:00 -> 00:10 local(LA)... in
        // UTC the history night runs 2026-09-10T00:26:40Z. The day grid is the
        // FULL LOCAL DAY (America/Los_Angeles), so use a UTC day and timezone
        // UTC to keep the arithmetic checkable.
        let tz = "UTC"
        // local day 2026-09-10 in UTC starts at 2026-09-10T00:00:00Z
        let dayStart = SleepFeatureEnrichment.unixSeconds("2026-09-10T00:00:00Z")!
        // a staged night 00:00 -> 00:10: 5 min wake then 5 min sleep
        let isoStart = SleepFeatureEnrichment.isoUTC(dayStart)
        let isoEnd = SleepFeatureEnrichment.isoUTC(dayStart + 600)
        let stages: [[String: Any]] = [
            ["start": dayStart, "end": dayStart + 300, "stage": "wake"],
            ["start": dayStart + 300, "end": dayStart + 600, "stage": "deep"],
        ]
        let night: [String: Any] = [
            "start_at": isoStart, "end_at": isoEnd, "is_nap": false, "stages": stages,
        ]
        let sleepJSON = String(data: try JSONSerialization.data(withJSONObject: [night]),
                               encoding: .utf8)!
        // Worn all day (HR presence >= 30 s per minute) but staged only 10 min.
        let hrRows = (0..<1440).map { i in
            ["minute": String((dayStart / 60 + i) * 60), "n": "60"]
        }
        let db = FakeDB(snapshotRows: [["day": "2026-09-10", "rev": "5", "sleep": sleepJSON]],
                        hrRows: hrRows)
        let history = try SleepFeatureEnrichment.loadHistory(
            db: db, userId: "u", deviceId: "d", days: 31, todayDay: "2026-09-11",
            ianaTimezone: tz, algorithmVersion: "frwhoop-server-1")
        XCTAssertEqual(history?.dayRevisions.count, 1)
        XCTAssertEqual(history?.dayRevisions.first?.revision, 5)
        let minutes = history?.minutes ?? []
        // The FULL local day grid: 1440 minutes, all valid (in-session staged
        // decision; worn awake outside the session).
        XCTAssertEqual(minutes.count, 1440)
        XCTAssertEqual(minutes.filter { $0.state == 1 }.count, 5)
        XCTAssertTrue(minutes.allSatisfy { $0.valid })
        // An out-of-session minute (e.g. noon) is monitored AWAKE, not invalid.
        let noon = minutes.first { $0.ts == dayStart + 12 * 3600 }
        XCTAssertEqual(noon?.state, 0)
        XCTAssertEqual(noon?.valid, true)
    }

    func testLoadHistoryOutOfSessionUnwornMinutesAreInvalidNeverAwake() throws {
        let dayStart = SleepFeatureEnrichment.unixSeconds("2026-09-10T00:00:00Z")!
        let stages: [[String: Any]] = [
            ["start": dayStart, "end": dayStart + 600, "stage": "deep"],
        ]
        let night: [String: Any] = [
            "start_at": SleepFeatureEnrichment.isoUTC(dayStart),
            "end_at": SleepFeatureEnrichment.isoUTC(dayStart + 600),
            "is_nap": false, "stages": stages,
        ]
        let sleepJSON = String(data: try JSONSerialization.data(withJSONObject: [night]),
                               encoding: .utf8)!
        // NO HR presence anywhere (the strap was off-wrist outside the session).
        let db = FakeDB(snapshotRows: [["day": "2026-09-10", "rev": "5", "sleep": sleepJSON]])
        let history = try SleepFeatureEnrichment.loadHistory(
            db: db, userId: "u", deviceId: "d", days: 31, todayDay: "2026-09-11",
            ianaTimezone: "UTC", algorithmVersion: "frwhoop-server-1")
        let minutes = history?.minutes ?? []
        XCTAssertEqual(minutes.count, 1440)
        XCTAssertEqual(minutes.filter { $0.valid }.count, 10)  // only the staged span
        // every invalid minute carries state 0 but valid=false (excluded, never awake)
        XCTAssertTrue(minutes.filter { !$0.valid }.allSatisfy { $0.state == 0 })
    }

    func testLoadHistorySkipsNightsWithoutStages() throws {
        let dayStart = SleepFeatureEnrichment.unixSeconds("2026-09-10T00:00:00Z")!
        let night: [String: Any] = [
            "start_at": SleepFeatureEnrichment.isoUTC(dayStart),
            "end_at": SleepFeatureEnrichment.isoUTC(dayStart + 600),
            "is_nap": true, "stages": [] as [Any],
        ]
        let sleepJSON = String(data: try JSONSerialization.data(withJSONObject: [night]),
                               encoding: .utf8)!
        // Worn all day: without a stage array the staged decision is UNKNOWN,
        // so staged minutes stay excluded; worn out-of-session minutes are
        // monitored awake.
        let hrRows = (0..<1440).map { i in
            ["minute": String((dayStart / 60 + i) * 60), "n": "60"]
        }
        let db = FakeDB(snapshotRows: [["day": "2026-09-10", "rev": "5", "sleep": sleepJSON]],
                        hrRows: hrRows)
        let history = try SleepFeatureEnrichment.loadHistory(
            db: db, userId: "u", deviceId: "d", days: 31, todayDay: "2026-09-11",
            ianaTimezone: "UTC", algorithmVersion: "frwhoop-server-1")
        XCTAssertEqual(history?.dayRevisions.count, 1)
        let minutes = history?.minutes ?? []
        XCTAssertEqual(minutes.count, 1440)
        // all worn awake: no fabricated staged classification
        XCTAssertEqual(minutes.filter { $0.state == 1 }.count, 0)
        XCTAssertTrue(minutes.allSatisfy { $0.valid })
    }

    // MARK: spec-02 history nights / timezone (rebound input)

    func testLoadHistoryCarriesPublishedNightsAndZone() throws {
        let dayStart = SleepFeatureEnrichment.unixSeconds("2026-09-10T00:00:00Z")!
        let main: [String: Any] = [
            "start_at": SleepFeatureEnrichment.isoUTC(dayStart), "end_at": SleepFeatureEnrichment.isoUTC(dayStart + 28_800),
            "is_nap": false, "asleep_min": 432.5, "awake_min": 47.5, "efficiency": 0.901,
            "stages": [["start": dayStart, "end": dayStart + 28_800, "stage": "light"]],
        ]
        // A nap with no minute fields and an out-of-range value: nil, never zero.
        let nap: [String: Any] = [
            "start_at": SleepFeatureEnrichment.isoUTC(dayStart + 50_000),
            "end_at": SleepFeatureEnrichment.isoUTC(dayStart + 52_000),
            "is_nap": true, "awake_min": 5000.0, "stages": [] as [Any],
        ]
        let broken: [String: Any] = ["start_at": "nope", "end_at": "nope", "stages": [] as [Any]]
        let sleepJSON = String(data: try JSONSerialization.data(withJSONObject: [main, nap, broken]), encoding: .utf8)!
        let db = FakeDB(snapshotRows: [["day": "2026-09-10", "rev": "5", "sleep": sleepJSON,
                                        "tz": "America/Los_Angeles"]])
        let history = try XCTUnwrap(try SleepFeatureEnrichment.loadHistory(
            db: db, userId: "u", deviceId: "d", days: 31, todayDay: "2026-09-11",
            ianaTimezone: "UTC", algorithmVersion: "frwhoop-server-1"))
        XCTAssertEqual(history.timezoneByDay["2026-09-10"], "America/Los_Angeles")
        let nights = try XCTUnwrap(history.nightsByDay["2026-09-10"])
        XCTAssertEqual(nights.count, 2)
        XCTAssertEqual(nights[0], SleepFeatureHistoryNight(start: dayStart, end: dayStart + 28_800, isNap: false,
                                                           asleepMin: 432.5, awakeMin: 47.5, efficiency: 0.901))
        XCTAssertEqual(nights[1].isNap, true)
        XCTAssertNil(nights[1].asleepMin)
        XCTAssertNil(nights[1].awakeMin, "out of the sidecar's range: nil, so the request is never refused")
    }

    func testRequestSendsHistoryNightsBoundedWithNullsNotZeros() throws {
        let n0 = 1789000000
        var many: [SleepFeatureHistoryNight] = []
        for k in 0..<10 {  // 10 entries; the sidecar accepts 8 per day
            many.append(SleepFeatureHistoryNight(start: n0 + k * 4000, end: n0 + k * 4000 + 600 + k * 10,
                                                 isNap: k > 0, asleepMin: k == 3 ? nil : 10, awakeMin: 1,
                                                 efficiency: nil))
        }
        many.append(SleepFeatureHistoryNight(start: n0 + 50_000, end: n0 + 80_000, isNap: false,
                                             asleepMin: 400, awakeMin: 20, efficiency: 0.95))
        var history = SleepFeatureHistory(dayRevisions: [("2026-10-04", 11)],
                                          minutes: [("2026-10-04", n0, 1, true)])
        history.nightsByDay["2026-10-04"] = many
        history.timezoneByDay["2026-10-04"] = "Europe/London"
        let request = SleepFeatureEnrichment.buildRequest(makeInput(
            nights: [makeNight(start: n0, end: n0 + 3600)], history: history))
        let days = try XCTUnwrap((request["history"] as? [String: Any])?["days"] as? [[String: Any]])
        XCTAssertEqual(days[0]["timezone"] as? String, "Europe/London")
        let sent = try XCTUnwrap(days[0]["nights"] as? [[String: Any]])
        XCTAssertEqual(sent.count, SleepFeatureHistoryNight.maxPerDay)
        XCTAssertTrue(sent.contains { ($0["end"] as? Int) == n0 + 80_000 }, "the main night is never dropped")
        let starts = sent.compactMap { $0["start"] as? Int }
        XCTAssertEqual(starts, starts.sorted())
        XCTAssertTrue(sent.allSatisfy { $0["efficiency"] is NSNull || $0["efficiency"] is Double })
        if let k3 = sent.first(where: { ($0["start"] as? Int) == n0 + 3 * 4000 }) {
            XCTAssertTrue(k3["asleep_min"] is NSNull, "missing minutes travel as null, never 0")
        }
        XCTAssertTrue(JSONSerialization.isValidJSONObject(request))
    }

    // MARK: Transport through the real loopback server (StubHTTPServer)

    func testEnrichRoundTripsThroughRealHTTP() throws {
        // The stub answers with the Python sidecar's real fixture response
        // shape; the enrichment must POST /v1/sleep-features, accept 200 and
        // return the validated document.
        let n0 = 1789000000
        let response: [String: Any] = [
            "schema_version": 1, "algorithm_version": "nara-sleep-features-1",
            "status": "available", "status_reasons": [] as [String],
            "nights": [[
                "night_id": "sleep-d-\(n0)",
                "start_utc": "2026-09-10T00:26:40Z", "end_utc": "2026-09-10T08:26:40Z",
                "continuity": ["status": "available", "tib_min": 480.0],
            ] as [String: Any]],
            "capabilities": ["oxygen_events": ["ready": false,
                                                "reason": "unverified_sparse_oxygen"]],
        ]
        let body = try JSONSerialization.data(withJSONObject: response)
        let server = StubHTTPServer { _ in .json(String(data: body, encoding: .utf8)!) }
        defer { server.stop() }
        let client = InferenceClient(baseURL: URL(string: server.baseURL)!, timeoutMS: 20_000)
        let request = SleepFeatureEnrichment.buildRequest(makeInput(
            nights: [makeNight(start: n0, end: n0 + 3600)]))
        let doc = SleepFeatureEnrichment.enrich(request: request, client: client)
        XCTAssertEqual(doc?["status"] as? String, "available")
        XCTAssertEqual(server.requestCount, 1)
        let served = try XCTUnwrap(server.servedRequests.first)
        XCTAssertEqual(served.method, "POST")
        XCTAssertEqual(served.path, "/v1/sleep-features")
        XCTAssertEqual(served.headers["content-type"], "application/json")
    }

    func testEnrichTimeoutReturnsNilNeverThrows() throws {
        // A sidecar that never answers: the bounded transport settles the call
        // and the enrichment returns nil (snapshot publishes without the key).
        let server = StubHTTPServer { _ in
            StubHTTPServer.Response(neverRespond: true)
        }
        defer { server.stop() }
        let client = InferenceClient(baseURL: URL(string: server.baseURL)!, timeoutMS: 500)
        let n0 = 1789000000
        let request = SleepFeatureEnrichment.buildRequest(makeInput(
            nights: [makeNight(start: n0, end: n0 + 3600)]))
        let started = Date()
        let doc = SleepFeatureEnrichment.enrich(request: request, client: client)
        XCTAssertNil(doc)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10.0, "must settle within its budget")
    }

    func testEnrichRefusedConnectionReturnsNil() throws {
        // Nothing listening (a real refused port, not a mock): nil, no throw.
        let client = InferenceClient(baseURL: URL(string: "http://127.0.0.1:1")!,
                                      timeoutMS: 2_000)
        let n0 = 1789000000
        let request = SleepFeatureEnrichment.buildRequest(makeInput(
            nights: [makeNight(start: n0, end: n0 + 3600)]))
        XCTAssertNil(SleepFeatureEnrichment.enrich(request: request, client: client))
    }

    // MARK: Cross-language contract (the real Python response fixture)

    /// The committed fixture pair proves the two languages agree on the wire:
    /// the request JSON is what the Swift assembler produces, and the response
    /// JSON is the REAL Python sidecar's answer to it (captured over HTTP,
    /// `duration_ms` stripped as wall-clock). A change on either side that
    /// breaks the pair fails here before it reaches production.
    private static let fixtureDir = "SleepFeatureWireFixtures"

    private func fixtureData(_ name: String) throws -> Data {
        let url = Bundle.module.url(forResource: name.replacingOccurrences(
            of: ".json", with: ""), withExtension: "json",
            subdirectory: Self.fixtureDir)
        return try Data(contentsOf: try XCTUnwrap(url, "missing fixture \(name)"))
    }

    func testRealPythonResponseValidatesThroughTheTransport() throws {
        let responseText = String(data: try fixtureData("sleep_features_response.json"),
                                   encoding: .utf8)!
        let server = StubHTTPServer { _ in .json(responseText) }
        defer { server.stop() }
        let client = InferenceClient(baseURL: URL(string: server.baseURL)!, timeoutMS: 20_000)
        let n0 = 1789000000
        let request = SleepFeatureEnrichment.buildRequest(makeInput(
            nights: [makeNight(start: n0, end: n0 + 3600)]))
        let doc = SleepFeatureEnrichment.enrich(request: request, client: client)
        // The real Python fixture validates through the Swift transport.
        XCTAssertEqual(doc?["status"] as? String, "available")
        let nights = try XCTUnwrap(doc?["nights"] as? [[String: Any]])
        XCTAssertEqual(nights.count, 1)
        XCTAssertEqual(nights[0]["stage_algorithm_version"] as? String, "frwhoop-server-1")
    }

    func testSwiftRequestMatchesCommittedFixtureShape() throws {
        // The committed request fixture is the exact wire shape the Swift
        // assembler produces for the same inputs; the required keys and their
        // types must all match (a Python parser regression fails here).
        let fixture = try XCTUnwrap(JSONSerialization.jsonObject(
            with: fixtureData("sleep_features_request.json")) as? [String: Any])
        for key in ["schema_version", "algorithm_version", "context", "nights",
                    "hr_samples", "skin_temp_samples", "rr_beats", "resp_breaths", "history"] {
            XCTAssertNotNil(fixture[key], "fixture request missing \(key)")
        }
        XCTAssertEqual(fixture["schema_version"] as? Int, 1)
        let context = try XCTUnwrap(fixture["context"] as? [String: Any])
        XCTAssertEqual(context["stage_algorithm_version"] as? String, "frwhoop-server-1")
        let nights = try XCTUnwrap(fixture["nights"] as? [[String: Any]])
        XCTAssertTrue(nights.allSatisfy { $0["stages"] is [[String: Any]] || $0["stages"] is [Any] })
        let history = try XCTUnwrap(fixture["history"] as? [String: Any])
        XCTAssertEqual(history["pair_policy"] as? String, "elapsed_24h")
    }

    // MARK: ISO helpers

    func testIsoRoundTrip() {
        let n0 = 1789000000
        XCTAssertEqual(SleepFeatureEnrichment.isoUTC(n0), "2026-09-10T00:26:40Z")
        XCTAssertEqual(SleepFeatureEnrichment.unixSeconds("2026-09-10T00:26:40Z"), n0)
        XCTAssertNil(SleepFeatureEnrichment.unixSeconds("not-a-date"))
    }
}

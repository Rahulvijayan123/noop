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

    private final class FakeDB: PostgresClientProtocol {
        let rows: [[String: String]]
        init(rows: [[String: String]]) { self.rows = rows }
        func query(_ sql: String, _ params: [String]) throws -> [[String: String]] { rows }
    }

    func testLoadHistoryFoldsStagesToMinuteGrid() throws {
        let n0 = 1789000000
        // one history night 23:00 -> 00:10 (10 min): 5 min wake then 5 min sleep
        let isoStart = SleepFeatureEnrichment.isoUTC(n0)
        let isoEnd = SleepFeatureEnrichment.isoUTC(n0 + 600)
        let stages: [[String: Any]] = [
            ["start": n0, "end": n0 + 300, "stage": "wake"],
            ["start": n0 + 300, "end": n0 + 600, "stage": "deep"],
        ]
        let night: [String: Any] = [
            "start_at": isoStart, "end_at": isoEnd, "is_nap": false, "stages": stages,
        ]
        let sleepJSON = String(data: try JSONSerialization.data(withJSONObject: [night]),
                               encoding: .utf8)!
        let db = FakeDB(rows: [["day": "2026-10-04", "rev": "5", "sleep": sleepJSON]])
        let history = try SleepFeatureEnrichment.loadHistory(
            db: db, userId: "u", deviceId: "d", days: 31, todayDay: "2026-10-05")
        XCTAssertEqual(history?.dayRevisions.count, 1)
        XCTAssertEqual(history?.dayRevisions.first?.revision, 5)
        let minutes = history?.minutes ?? []
        XCTAssertEqual(minutes.count, 10)
        // first 5 minutes: wake (state 0); last 5: sleep (state 1); all valid
        XCTAssertEqual(minutes.filter { $0.state == 1 }.count, 5)
        XCTAssertTrue(minutes.allSatisfy { $0.valid })
    }

    func testLoadHistorySkipsNightsWithoutStages() throws {
        let n0 = 1789000000
        let night: [String: Any] = [
            "start_at": SleepFeatureEnrichment.isoUTC(n0),
            "end_at": SleepFeatureEnrichment.isoUTC(n0 + 600),
            "is_nap": true, "stages": [] as [Any],
        ]
        let sleepJSON = String(data: try JSONSerialization.data(withJSONObject: [night]),
                               encoding: .utf8)!
        let db = FakeDB(rows: [["day": "2026-10-04", "rev": "5", "sleep": sleepJSON]])
        let history = try SleepFeatureEnrichment.loadHistory(
            db: db, userId: "u", deviceId: "d", days: 31, todayDay: "2026-10-05")
        XCTAssertEqual(history?.dayRevisions.count, 1)
        XCTAssertEqual(history?.minutes.count, 0)
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

    // MARK: ISO helpers

    func testIsoRoundTrip() {
        let n0 = 1789000000
        XCTAssertEqual(SleepFeatureEnrichment.isoUTC(n0), "2026-09-10T00:26:40Z")
        XCTAssertEqual(SleepFeatureEnrichment.unixSeconds("2026-09-10T00:26:40Z"), n0)
        XCTAssertNil(SleepFeatureEnrichment.unixSeconds("not-a-date"))
    }
}

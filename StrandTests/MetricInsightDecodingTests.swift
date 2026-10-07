import XCTest
@testable import Strand

/// A transport stub for `POST {scores}/insights`: records each request (with its body, which URLSession hands the
/// protocol as a stream) and answers per test.
private final class InsightStub: URLProtocol {
    static var status = 200
    static var body: Any = [String: Any]()
    /// Raw bytes to answer with instead of `body` (for malformed replies).
    static var rawBody: Data?
    static var failure: URLError?
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []
    private static let lock = NSLock()

    static func reset() {
        status = 200; body = [String: Any](); rawBody = nil; failure = nil
        lock.lock(); requests = []; bodies = []; lock.unlock()
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let sent = request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data()
        Self.lock.lock(); Self.requests.append(request); Self.bodies.append(sent); Self.lock.unlock()
        if let failure = Self.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let data = Self.rawBody ?? (try? JSONSerialization.data(withJSONObject: Self.body)) ?? Data()
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            guard n > 0 else { break }
            data.append(buffer, count: n)
        }
        return data
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InsightStub.self]
        return URLSession(configuration: config)
    }
}

/// Fixtures in the server's shape (`internal.metric_insight_json` + `metric_insight_request_v1`).
enum MetricInsightFixtures {
    static func insight(headline: String = "Resting heart rate is back near your usual range",
                        stale: Bool = false, kind: String = "explained",
                        observed: [Any] = ["Last night was 52 bpm.", "Your 30-night median is 54 bpm."],
                        interpretation: [Any] = ["This is within your usual night-to-night range."],
                        uncertainty: [Any] = ["Two nights in the window were not measured."],
                        related: [Any]? = [["metric": "hrv_rmssd", "label": "HRV",
                                            "summary": "85 ms, above your 30-night median",
                                            "direction": "up", "estimated": false]],
                        basis: [String: Any]? = ["nights": 28, "from": "2026-09-08", "to": "2026-10-06",
                                                 "missing_nights": 2, "comparison_status": "ready"],
                        citations: [Any] = [["id": "pmid:123", "title": "Resting heart rate in adults",
                                             "year": 2020, "url": "https://pubmed.ncbi.nlm.nih.gov/123/"]],
                        extra: [String: Any] = [:]) -> [String: Any] {
        var o: [String: Any] = [
            "id": 42, "metric": "resting_hr", "kind": kind,
            "generated_at": "2026-10-07T02:43:31.835123+00:00",
            "analysis_version": "metric-insight-1", "data_through": "2026-10-06", "stale": stale,
            "headline": headline, "observed": observed, "interpretation": interpretation,
            "uncertainty": uncertainty, "citations": citations,
        ]
        if let related { o["related"] = related }
        if let basis { o["basis"] = basis }
        for (k, v) in extra { o[k] = v }
        return o
    }

    static func response(status: String, insight: Any? = nil, reason: String? = nil,
                         retryAfter: Any? = nil) -> [String: Any] {
        var o: [String: Any] = ["status": status, "metric": "resting_hr", "insight": insight ?? NSNull()]
        if let reason { o["reason"] = reason }
        if let retryAfter { o["retry_after_s"] = retryAfter }
        return o
    }

    static func decoded(_ object: [String: Any]) -> MetricInsightResponse? {
        MetricInsightResponse.decode(try! JSONSerialization.data(withJSONObject: object))
    }

    static func cleanInsight(headline: String = "Resting heart rate is back near your usual range",
                             stale: Bool = false) -> MetricInsight {
        MetricInsight.decode(insight(headline: headline, stale: stale))!
    }
}

/// The contract half of the metric explanations: every documented response shape decodes, unknown members are
/// ignored, optional members may be missing, the Postgres timestamp reads, and the client sends exactly the
/// documented request and maps every documented status.
final class MetricInsightDecodingTests: XCTestCase {

    typealias F = MetricInsightFixtures

    override func setUp() { InsightStub.reset() }
    override func tearDown() { InsightStub.reset() }

    // MARK: - Responses

    func testReadyDecodesEveryMember() throws {
        let r = try XCTUnwrap(F.decoded(F.response(status: "ready", insight: F.insight())))
        XCTAssertEqual(r.status, .ready)
        XCTAssertEqual(r.metric, "resting_hr")
        XCTAssertNil(r.reason)
        XCTAssertNil(r.retryAfterS)
        let i = try XCTUnwrap(r.insight)
        XCTAssertEqual(i.id, 42)
        XCTAssertEqual(i.metric, "resting_hr")
        XCTAssertEqual(i.kind, .explained)
        XCTAssertEqual(i.analysisVersion, "metric-insight-1")
        XCTAssertEqual(i.dataThrough, "2026-10-06")
        XCTAssertFalse(i.stale)
        XCTAssertEqual(i.headline, "Resting heart rate is back near your usual range")
        XCTAssertEqual(i.observed, ["Last night was 52 bpm.", "Your 30-night median is 54 bpm."])
        XCTAssertEqual(i.interpretation, ["This is within your usual night-to-night range."])
        XCTAssertEqual(i.uncertainty, ["Two nights in the window were not measured."])
        XCTAssertEqual(i.related, [MetricInsight.Related(metric: "hrv_rmssd", label: "HRV",
                                                         summary: "85 ms, above your 30-night median",
                                                         direction: .up, estimated: false)])
        XCTAssertEqual(i.basis, MetricInsight.Basis(nights: 28, from: "2026-09-08", to: "2026-10-06",
                                                    missingNights: 2, comparisonStatus: "ready"))
        XCTAssertEqual(i.citations, [MetricInsight.Citation(id: "pmid:123", title: "Resting heart rate in adults",
                                                            year: 2020,
                                                            url: URL(string: "https://pubmed.ncbi.nlm.nih.gov/123/"))])
        XCTAssertEqual(i.generatedAtText, "2026-10-07T02:43:31.835123+00:00")
        let generated = try XCTUnwrap(i.generatedAt)
        XCTAssertEqual(generated.timeIntervalSince1970, 1_791_341_011.835123, accuracy: 0.000_5)
    }

    func testPendingWithAndWithoutAStaleInsight() throws {
        let fresh = try XCTUnwrap(F.decoded(F.response(status: "pending", retryAfter: 10)))
        XCTAssertEqual(fresh.status, .pending)
        XCTAssertEqual(fresh.retryAfterS, 10)
        XCTAssertNil(fresh.insight, "a JSON null insight is no insight")

        let stale = try XCTUnwrap(F.decoded(F.response(status: "pending", insight: F.insight(stale: true),
                                                       retryAfter: 37)))
        XCTAssertEqual(stale.status, .pending)
        XCTAssertEqual(stale.retryAfterS, 37)
        XCTAssertEqual(stale.insight?.stale, true)
        XCTAssertEqual(stale.insight?.headline, "Resting heart rate is back near your usual range")

        // A whole-number float and a numeric string still read as seconds.
        XCTAssertEqual(F.decoded(F.response(status: "pending", retryAfter: 12.0))?.retryAfterS, 12)
        XCTAssertEqual(F.decoded(F.response(status: "pending", retryAfter: "15"))?.retryAfterS, 15)
        XCTAssertNil(F.decoded(F.response(status: "pending", retryAfter: true))?.retryAfterS, "a bool is not a number")
    }

    func testUnavailableForEachReason() throws {
        let none = try XCTUnwrap(F.decoded(F.response(status: "unavailable", reason: "no_measured_data")))
        XCTAssertEqual(none.status, .unavailable)
        XCTAssertEqual(none.reason, .noMeasuredData)
        XCTAssertNil(none.insight)

        let failed = try XCTUnwrap(F.decoded(F.response(status: "unavailable", insight: F.insight(stale: true),
                                                        reason: "analysis_failed")))
        XCTAssertEqual(failed.reason, .analysisFailed)
        XCTAssertEqual(failed.insight?.stale, true)

        let limited = try XCTUnwrap(F.decoded(F.response(status: "unavailable", reason: "daily_limit")))
        XCTAssertEqual(limited.reason, .dailyLimit)

        let other = try XCTUnwrap(F.decoded(F.response(status: "unavailable", reason: "maintenance")))
        XCTAssertEqual(other.reason, .other("maintenance"))
    }

    func testUnknownMembersAreIgnoredEverywhere() throws {
        var related = F.insight()["related"] as! [[String: Any]]
        related[0]["confidence"] = 0.8
        let insight = F.insight(related: related,
                                basis: ["nights": 28, "to": "2026-10-06", "window": ["a": 1]],
                                citations: [["title": "A study", "year": 2019, "doi": "10.1/x", "authors": ["A"]]],
                                extra: ["model": "x", "tone": "calm-ish", "sections": ["nested": true]])
        var body = F.response(status: "ready", insight: insight)
        body["identity"] = ["userId": "someone"]
        body["future_member"] = [1, 2, 3]
        let r = try XCTUnwrap(F.decoded(body))
        XCTAssertEqual(r.status, .ready)
        XCTAssertEqual(r.insight?.related.first?.label, "HRV")
        XCTAssertEqual(r.insight?.basis?.nights, 28)
        XCTAssertEqual(r.insight?.citations, [MetricInsight.Citation(id: nil, title: "A study", year: 2019, url: nil)])
    }

    func testMissingOptionalMembersAreTolerated() throws {
        let minimal: [String: Any] = ["headline": "Only 2 nights measured so far", "kind": "insufficient_data"]
        let r = try XCTUnwrap(F.decoded(["status": "ready", "insight": minimal]))
        XCTAssertNil(r.metric)
        let i = try XCTUnwrap(r.insight)
        XCTAssertEqual(i.kind, .insufficientData)
        XCTAssertEqual(i.headline, "Only 2 nights measured so far")
        XCTAssertEqual(i.observed, [])
        XCTAssertEqual(i.interpretation, [])
        XCTAssertEqual(i.uncertainty, [])
        XCTAssertEqual(i.related, [])
        XCTAssertNil(i.basis)
        XCTAssertEqual(i.citations, [])
        XCTAssertNil(i.id)
        XCTAssertNil(i.generatedAt)
        XCTAssertNil(i.dataThrough)
        XCTAssertFalse(i.stale)

        // Citation year and url are optional; a related entry may leave direction and estimated out.
        let partial = try XCTUnwrap(MetricInsight.decode(F.insight(
            related: [["label": "Sleep", "summary": "7 h 10 min"]],
            citations: [["title": "No year or link"], ["title": "Year only", "year": 2021]])))
        XCTAssertEqual(partial.related, [MetricInsight.Related(metric: nil, label: "Sleep", summary: "7 h 10 min",
                                                               direction: .unknown, estimated: false)])
        XCTAssertEqual(partial.citations.map(\.year), [nil, 2021])
        XCTAssertEqual(partial.citations.map(\.url), [nil, nil])

        // Related absent entirely, or empty.
        XCTAssertEqual(MetricInsight.decode(F.insight(related: nil))?.related, [])
        XCTAssertEqual(MetricInsight.decode(F.insight(related: []))?.related, [])
    }

    func testUnreadableMembersCostOnlyThemselves() throws {
        let insight = F.insight(observed: ["Kept", 7, "", "  ", NSNull(), "Also kept"],
                                related: [["label": "HRV"], "not an object", ["label": "RHR", "summary": "52 bpm",
                                                                             "direction": "sideways"]],
                                basis: nil,
                                citations: [["year": 2020], ["title": "Kept", "url": "javascript:alert(1)"],
                                            ["title": "Plain http", "url": "http://example.com/a"]],
                                extra: ["id": "not a number", "stale": "yes", "generated_at": "yesterday"])
        let i = try XCTUnwrap(MetricInsight.decode(insight))
        XCTAssertEqual(i.observed, ["Kept", "Also kept"])
        XCTAssertEqual(i.related.map(\.label), ["RHR"])
        XCTAssertEqual(i.related.first?.direction, .unknown)
        XCTAssertEqual(i.citations.map(\.title), ["Kept", "Plain http"])
        XCTAssertEqual(i.citations.map(\.url), [nil, nil], "only https links are kept")
        XCTAssertNil(i.id)
        XCTAssertFalse(i.stale)
        XCTAssertEqual(i.generatedAtText, "yesterday")
        XCTAssertNil(i.generatedAt)

        // Text lists are capped at the server's bound.
        let long = try XCTUnwrap(MetricInsight.decode(F.insight(observed: (1...9).map { "Sentence \($0)." })))
        XCTAssertEqual(long.observed.count, MetricInsight.maxSentences)
    }

    func testAnInsightWithoutAHeadlineIsNoInsight() throws {
        for headline: Any in ["", "   ", 7, NSNull()] {
            var o = F.insight()
            o["headline"] = headline
            XCTAssertNil(F.decoded(F.response(status: "ready", insight: o))?.insight, "\(headline)")
        }
        var o = F.insight()
        o.removeValue(forKey: "headline")
        XCTAssertNil(F.decoded(F.response(status: "ready", insight: o))?.insight)
    }

    func testUnknownStatusAndKindAreKeptAsUnknown() throws {
        let r = try XCTUnwrap(F.decoded(F.response(status: "queued", insight: F.insight(kind: "partial"))))
        XCTAssertEqual(r.status, .unknown("queued"))
        XCTAssertEqual(r.insight?.kind, .other("partial"))
    }

    func testABodyThatIsNotThisContractDoesNotDecode() {
        XCTAssertNil(MetricInsightResponse.decode(Data("[1,2]".utf8)))
        XCTAssertNil(MetricInsightResponse.decode(Data("not json".utf8)))
        XCTAssertNil(MetricInsightResponse.decode(Data(#"{"error":"scores_unavailable"}"#.utf8)))
        XCTAssertNil(MetricInsightResponse.decode(Data(#"{"status":7}"#.utf8)))
    }

    // MARK: - Timestamps

    func testPostgresTimestampTextAndNearbyISOForms() throws {
        let base = 1_791_341_011.0   // 2026-10-07T02:43:31Z
        func parsed(_ s: String) -> TimeInterval? { MetricInsightTimestamp.parse(s)?.timeIntervalSince1970 }
        XCTAssertEqual(try XCTUnwrap(parsed("2026-10-07T02:43:31.835123+00:00")), base + 0.835123, accuracy: 0.000_5)
        XCTAssertEqual(try XCTUnwrap(parsed("2026-10-07T02:43:31.8+00:00")), base + 0.8, accuracy: 0.000_5)
        XCTAssertEqual(parsed("2026-10-07T02:43:31Z"), base)
        XCTAssertEqual(parsed("2026-10-07T02:43:31+00:00"), base)
        XCTAssertEqual(parsed("2026-10-07 02:43:31+00"), base)
        XCTAssertEqual(parsed("2026-10-07T02:43:31"), base, "no offset reads as UTC")
        XCTAssertEqual(parsed("2026-10-07T08:13:31+05:30"), base)
        XCTAssertEqual(parsed("2026-10-06T19:43:31-0700"), base)
        XCTAssertEqual(try XCTUnwrap(parsed(" 2026-10-06T19:43:31.250-07:00 ")), base + 0.25, accuracy: 0.000_5)
        for bad in ["", "2026-10-07", "2026-13-07T02:43:31Z", "2026-02-30T02:43:31Z", "2026-10-07T25:00:00Z",
                    "07/10/2026 02:43", "2026-10-07T02:43:31+0"] {
            XCTAssertNil(MetricInsightTimestamp.parse(bad), bad)
        }
    }

    // MARK: - Client

    private let owner = "11111111-1111-4111-8111-111111111111"
    private let source = "22222222-2222-4222-8222-222222222222"
    private let endpoint = URL(string: "https://example.invalid/functions/v1/scores")!

    private func client(identity: Bool = true, endpoint: URL?? = nil) -> MetricInsightClient {
        let owner = self.owner, source = self.source
        return MetricInsightClient(
            session: InsightStub.session(), endpoint: endpoint ?? self.endpoint,
            identity: { identity ? CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: "t",
                                                     uploadToken: "noop_installation") : nil })
    }

    func testTheClientSendsTheDocumentedRequest() async throws {
        InsightStub.body = F.response(status: "ready", insight: F.insight())
        let result = await client().request(.restingHeartRate)
        guard case .response(let r) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(r.status, .ready)

        let request = try XCTUnwrap(InsightStub.requests.first)
        XCTAssertEqual(InsightStub.requests.count, 1)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://example.invalid/functions/v1/scores/insights")
        XCTAssertNil(request.url?.query, "no device id or other query")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop_installation")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-noop-fleet-token"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: InsightStub.bodies[0]) as? [String: Any])
        XCTAssertEqual(body as NSDictionary, ["metric": "resting_hr"] as NSDictionary, "the metric and nothing else")

        _ = await client().request(.hrvRmssd)
        let second = try XCTUnwrap(JSONSerialization.jsonObject(with: InsightStub.bodies[1]) as? [String: Any])
        XCTAssertEqual(second as NSDictionary, ["metric": "hrv_rmssd"] as NSDictionary)
    }

    func testTheClientMapsEveryStatus() async {
        InsightStub.body = ["error": "method_not_allowed"]
        InsightStub.status = 405
        var result = await client().request(.restingHeartRate)
        XCTAssertEqual(result, .unsupportedServer, "an older server without the route is not an error")
        InsightStub.status = 404
        result = await client().request(.restingHeartRate)
        XCTAssertEqual(result, .unsupportedServer)

        for status in [400, 401, 403, 409, 413, 500, 502, 503] {
            InsightStub.status = status
            InsightStub.body = ["error": "scores_unavailable"]
            result = await client().request(.restingHeartRate)
            XCTAssertEqual(result, .failed(.http(status)), "\(status)")
        }

        InsightStub.status = 200
        InsightStub.rawBody = Data("<html>gateway</html>".utf8)
        result = await client().request(.restingHeartRate)
        XCTAssertEqual(result, .failed(.malformed))
        InsightStub.rawBody = nil

        InsightStub.failure = URLError(.notConnectedToInternet)
        result = await client().request(.restingHeartRate)
        XCTAssertEqual(result, .failed(.transport))
        InsightStub.failure = nil
    }

    func testTheClientNeedsAnEndpointAndACredential() async {
        var result = await client(identity: false).request(.restingHeartRate)
        XCTAssertEqual(result, .failed(.missingIdentity))
        result = await client(endpoint: .some(nil)).request(.restingHeartRate)
        XCTAssertEqual(result, .failed(.notConfigured))
        XCTAssertTrue(InsightStub.requests.isEmpty, "nothing is sent without both")
    }
}

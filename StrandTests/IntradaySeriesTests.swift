import XCTest
@testable import Strand

/// A transport stub that records what the repository asked for, so the real request, parse and cache path
/// runs with no network.
private final class SeriesStub: URLProtocol {
    static var body: [String: Any] = [:]
    static var status = 200
    static var requests: [URLRequest] = []

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        SeriesStub.requests.append(request)
        let data = (try? JSONSerialization.data(withJSONObject: SeriesStub.body)) ?? Data()
        let http = HTTPURLResponse(url: request.url!, statusCode: SeriesStub.status,
                                   httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SeriesStub.self]
        return URLSession(configuration: config)
    }
}

/// The phone's side of the dense intraday series: parsing what the server publishes, choosing which stretch
/// of time to ask for, and the cache. The numbers themselves are the server's; nothing here computes one.
final class IntradaySeriesTests: XCTestCase {

    private let owner = "11111111-1111-4111-8111-111111111111"
    private let dayStart = 1_790_838_000      // 2026-10-01 00:00 America/Los_Angeles

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-series-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        SeriesStub.body = [:]
        SeriesStub.status = 200
        SeriesStub.requests = []
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func losAngeles() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }

    private func repository(owner: String? = nil) -> ServerScoreRepository {
        let ownerId = owner ?? self.owner
        return ServerScoreRepository(
            session: SeriesStub.session(),
            endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
            fleetToken: "noop_test", directory: directory,
            identity: { CloudPushIdentity(ownerId: ownerId, sourceId: "22222222-2222-4222-8222-222222222222",
                                          tokenId: "t", uploadToken: "noop_x") })
    }

    /// The `series` object `server_metric_series_read` returns.
    private func series(from: Int, to: Int, metrics: [String: Any]) -> [String: Any] {
        ["from": from, "to": to, "bucket_seconds": 300,
         "latest_computed_at": "2026-10-01T21:03:12.345678+00:00", "metrics": metrics]
    }

    /// That object wrapped the way the edge route wraps it.
    private func edgeBody() -> [String: Any] {
        let hrv: [[Any]] = [[dayStart + 300, 62.5, 120, 0.8, 0.05], [dayStart, 58.0, 90, 0.7, NSNull()]]
        let resting: [[Any]] = [[dayStart, 54.0, 300, 1.0, 0.0]]
        let steps: [[Any]] = [[dayStart, 12.0, 1, 1.0, NSNull()], [dayStart + 300, 30.0, 1, 1.0, NSNull()],
                              [dayStart + 900, 8.0, 1, 1.0, NSNull()]]
        let calories: [[Any]] = [[dayStart, 1.2, 1, 1.0, NSNull()]]
        let metrics: [String: Any] = ["hrv_rmssd_ms": hrv, "resting_hr_bpm": resting,
                                      "resp_rate_bpm": [[Any]](), "steps": steps, "calories_kcal": calories]
        return ["series": series(from: dayStart, to: dayStart + 86_400, metrics: metrics),
                "identity": ["userId": owner]]
    }

    // MARK: - parsing

    func testParsesTheEdgeEnvelopeIntoSortedPoints() throws {
        let window = try XCTUnwrap(IntradaySeriesWindow(envelope: edgeBody()))
        XCTAssertEqual(window.from, dayStart)
        XCTAssertEqual(window.to, dayStart + 86_400)
        XCTAssertEqual(window.bucketSeconds, 300)

        // Rows arrive in any order; the window hands them back by time.
        XCTAssertEqual(window.points(.hrv).map(\.start), [dayStart, dayStart + 300])
        XCTAssertEqual(window.points(.hrv).map(\.value), [58.0, 62.5])
        XCTAssertEqual(window.points(.hrv).map(\.samples), [90, 120])
        XCTAssertNil(window.points(.hrv)[0].motion, "a null motion is not a zero")
        XCTAssertEqual(try XCTUnwrap(window.points(.hrv)[1].motion), 0.05, accuracy: 1e-9)
        XCTAssertEqual(window.latest(.hrv)?.value, 62.5)

        XCTAssertTrue(window.points(.respiratoryRate).isEmpty)
        XCTAssertFalse(window.isEmpty)
    }

    func testTheCacheShapeParsesLikeTheNetworkShape() throws {
        let inner = try XCTUnwrap(edgeBody()["series"] as? [String: Any])
        XCTAssertEqual(IntradaySeriesWindow(envelope: inner), IntradaySeriesWindow(envelope: edgeBody()))
    }

    func testAMicrosecondTimestampKeepsItsWholeSeconds() throws {
        let window = try XCTUnwrap(IntradaySeriesWindow(envelope: edgeBody()))
        let stamp = try XCTUnwrap(window.latestComputedAt).timeIntervalSince1970
        XCTAssertEqual(stamp, 1_790_888_592.345, accuracy: 0.001)

        XCTAssertEqual(IntradaySeriesWindow.parseTimestamp("2026-10-01T21:03:12Z")?.timeIntervalSince1970, 1_790_888_592)
        XCTAssertEqual(IntradaySeriesWindow.parseTimestamp("2026-10-01T21:03:12.5+00:00")?.timeIntervalSince1970 ?? 0,
                       1_790_888_592.5, accuracy: 0.001)
        XCTAssertNil(IntradaySeriesWindow.parseTimestamp("not a time"))
    }

    func testADamagedRowCostsOnePointAndNeverTheScreen() throws {
        var body = edgeBody()
        var inner = try XCTUnwrap(body["series"] as? [String: Any])
        var metrics = try XCTUnwrap(inner["metrics"] as? [String: Any])
        let damaged: [[Any]] = [
            [dayStart, 58.0, 90, 0.7, NSNull()],
            [dayStart + 300, "not a number", 1, 1.0, NSNull()],
            [dayStart + 600, 61.0],
            [dayStart + 900, Double.nan, 1, 1.0, NSNull()],
            [dayStart + 1200, 64.0, 80, 0.9, NSNull()],
            [dayStart + 1200, 65.0, 81, 0.9, NSNull()],
        ]
        let unknown: [[Any]] = [[dayStart, 1.0, 1, 1.0, NSNull()]]
        metrics["hrv_rmssd_ms"] = damaged
        metrics["calories_kcal"] = "garbage"
        metrics["mood"] = unknown
        inner["metrics"] = metrics
        body["series"] = inner

        let window = try XCTUnwrap(IntradaySeriesWindow(envelope: body))
        XCTAssertEqual(window.points(.hrv).map(\.start), [dayStart, dayStart + 1200])
        XCTAssertEqual(window.points(.hrv).last?.value, 65.0, "a repeated timestamp keeps its last value")
        XCTAssertTrue(window.points(.calories).isEmpty)
        XCTAssertEqual(window.points(.steps).count, 3, "other metrics are untouched")
    }

    func testAnEnvelopeWithoutARangeOrMetricsIsRejected() {
        let none: [String: Any] = [:]
        XCTAssertNil(IntradaySeriesWindow(envelope: none))
        XCTAssertNil(IntradaySeriesWindow(envelope: ["series": ["from": 1, "to": 2] as [String: Any]]))
        XCTAssertNil(IntradaySeriesWindow(envelope: ["series": series(from: 5, to: 5, metrics: [:])]),
                     "an empty range is not a window")
        XCTAssertNotNil(IntradaySeriesWindow(envelope: ["series": series(from: 1, to: 2, metrics: [:])]))
    }

    // MARK: - derived views

    func testRunningTotalsAddUpAndTheStaircaseHoldsAcrossAGap() throws {
        let window = try XCTUnwrap(IntradaySeriesWindow(envelope: edgeBody()))
        XCTAssertEqual(window.total(.steps), 50.0, accuracy: 1e-9)
        XCTAssertEqual(window.cumulative(.steps).map(\.total), [12.0, 42.0, 50.0])
        XCTAssertEqual(window.cumulative(.steps).map(\.ts), [dayStart + 300, dayStart + 600, dayStart + 1200])

        // Buckets at +0, +300 and +900 (nothing at +600): the total stays at 42 from +600 until +900
        // instead of sloping between them.
        let stairs = window.staircase(.steps)
        XCTAssertEqual(stairs.map(\.ts), [dayStart, dayStart + 300, dayStart + 300, dayStart + 600,
                                          dayStart + 900, dayStart + 1200])
        XCTAssertEqual(stairs.map(\.total), [0, 12, 12, 42, 42, 50])
    }

    func testALongHoleEndsALineButABucketAwayDoesNot() {
        func point(_ buckets: Int) -> IntradaySeriesPoint {
            IntradaySeriesPoint(start: 1_000_000 + buckets * 300, value: 50, samples: 10, coverage: 1, motion: nil)
        }
        let window = IntradaySeriesWindow(from: 1_000_000, to: 1_100_000,
                                          metrics: [.hrv: [point(0), point(1), point(3), point(10), point(11)]])
        let runs = window.runs(.hrv)
        XCTAssertEqual(runs.map { $0.map(\.start) },
                       [[1_000_000, 1_000_300, 1_000_900], [1_003_000, 1_003_300]],
                       "three buckets (15 minutes) still join; ten do not")
        XCTAssertEqual(window.runs(.hrv, maxGapBuckets: 1).map { $0.map(\.start) },
                       [[1_000_000, 1_000_300], [1_000_900], [1_003_000, 1_003_300]],
                       "with only adjacent buckets joined, the two-bucket hole splits too")
        XCTAssertTrue(window.runs(.steps).isEmpty)
    }

    func testEachMetricUsesItsOwnBucketWidth() throws {
        var body = edgeBody()
        var inner = try XCTUnwrap(body["series"] as? [String: Any])
        inner["metric_bucket_seconds"] = ["steps": 60, "resp_rate_bpm": 60, "hrv_rmssd_ms": 300, "mood": 5, "calories_kcal": -1]
        inner["metrics"] = [
            "steps": [[dayStart, 3.0, 1, 1.0, NSNull()], [dayStart + 60, 4.0, 1, 1.0, NSNull()]],
            "resp_rate_bpm": [[dayStart, 14.0, 12, 0.5, NSNull()], [dayStart + 60, 14.5, 12, 0.5, NSNull()],
                              [dayStart + 300, 15.0, 12, 0.5, NSNull()], [dayStart + 1000, 15.5, 12, 0.5, NSNull()]],
            "hrv_rmssd_ms": [[dayStart, 58.0, 90, 0.7, NSNull()]],
        ] as [String: Any]
        body["series"] = inner
        let window = try XCTUnwrap(IntradaySeriesWindow(envelope: body))

        XCTAssertEqual(window.bucketSeconds, 300, "the default stays the widest")
        XCTAssertEqual(window.bucketSeconds(for: .steps), 60)
        XCTAssertEqual(window.bucketSeconds(for: .respiratoryRate), 60)
        XCTAssertEqual(window.bucketSeconds(for: .hrv), 300)
        XCTAssertEqual(window.bucketSeconds(for: .restingHeartRate), 300, "an unnamed metric takes the default")
        XCTAssertEqual(window.bucketSeconds(for: .calories), 300, "a nonsense width is ignored")

        XCTAssertEqual(window.cumulative(.steps).map(\.ts), [dayStart + 60, dayStart + 120])
        XCTAssertEqual(window.staircase(.steps).map(\.ts), [dayStart, dayStart + 60, dayStart + 60, dayStart + 120])

        // Minute points are joined across a short dropout (up to five minutes) and split by a long one.
        XCTAssertEqual(window.runs(.respiratoryRate).map { $0.map(\.start) },
                       [[dayStart, dayStart + 60, dayStart + 300], [dayStart + 1000]])
    }

    func testAServerWithoutPerMetricWidthsDrawsEveryMetricAtTheDefault() throws {
        let window = try XCTUnwrap(IntradaySeriesWindow(envelope: edgeBody()))
        for metric in IntradayMetric.allCases {
            XCTAssertEqual(window.bucketSeconds(for: metric), 300)
        }
    }

    // MARK: - which stretch of time to ask for

    func testALineMetricAsksForTheLast24HoursEndingAtTheNextBucket() {
        let now = Date(timeIntervalSince1970: 1_790_850_123)
        let bounds = IntradayRange.bounds(for: .hrv, dayOffset: 0, now: now, calendar: losAngeles())
        XCTAssertTrue(bounds.isLive)
        XCTAssertEqual(bounds.to - bounds.from, 86_400)
        XCTAssertEqual(bounds.to % 300, 0)
        XCTAssertGreaterThan(bounds.to, Int(now.timeIntervalSince1970))
        XCTAssertLessThanOrEqual(bounds.to - Int(now.timeIntervalSince1970), 300)
        XCTAssertEqual(bounds.key, "hrv_rmssd_ms|live")

        // Asking again a minute later is the same cache entry with a window that has not moved a bucket.
        let later = IntradayRange.bounds(for: .hrv, dayOffset: 0, now: now.addingTimeInterval(60), calendar: losAngeles())
        XCTAssertEqual(later.key, bounds.key)
    }

    func testAnAdditiveMetricAsksForTheLocalDaySoFar() {
        let calendar = losAngeles()
        let now = Date(timeIntervalSince1970: TimeInterval(dayStart + 14 * 3_600 + 123))
        let bounds = IntradayRange.bounds(for: .steps, dayOffset: 0, now: now, calendar: calendar)
        XCTAssertEqual(bounds.from, dayStart)
        XCTAssertEqual(bounds.to, dayStart + 86_400)
        XCTAssertTrue(bounds.isLive)
        XCTAssertEqual(bounds.key, "steps|day|\(dayStart)", "a new day is a new entry, never yesterday's total")
    }

    func testEarlierDaysAreWholeLocalDaysThatFollowDaylightSaving() throws {
        let calendar = losAngeles()
        // 2026-11-02 noon: the day before it (Nov 1) had 25 hours.
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12)))
        let yesterday = IntradayRange.bounds(for: .calories, dayOffset: 1, now: now, calendar: calendar)
        XCTAssertEqual(yesterday.to - yesterday.from, 90_000)
        XCTAssertFalse(yesterday.isLive)
        XCTAssertEqual(yesterday.from, Int(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1)))
            .timeIntervalSince1970))
        XCTAssertEqual(yesterday.to, Int(try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
            .timeIntervalSince1970))

        // The same offset for a line metric is also a calendar day, not a rolling 24 hours.
        let lineYesterday = IntradayRange.bounds(for: .hrv, dayOffset: 1, now: now, calendar: calendar)
        XCTAssertEqual(lineYesterday.from, yesterday.from)
        XCTAssertEqual(lineYesterday.to, yesterday.to)
        XCTAssertFalse(lineYesterday.isLive)

        // Spring forward: the day is 23 hours.
        let spring = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12)))
        let march8 = IntradayRange.bounds(for: .steps, dayOffset: 1, now: spring, calendar: calendar)
        XCTAssertEqual(march8.to - march8.from, 82_800)
    }

    func testTheDayOffsetIsClamped() {
        let now = Date(timeIntervalSince1970: 1_790_850_123)
        let farBack = IntradayRange.bounds(for: .steps, dayOffset: 99, now: now, calendar: losAngeles())
        let limit = IntradayRange.bounds(for: .steps, dayOffset: IntradayRange.maxDayOffset, now: now, calendar: losAngeles())
        XCTAssertEqual(farBack, limit)
        XCTAssertEqual(IntradayRange.bounds(for: .steps, dayOffset: -3, now: now, calendar: losAngeles()),
                       IntradayRange.bounds(for: .steps, dayOffset: 0, now: now, calendar: losAngeles()))
    }

    func testAxisLabelsSitOnClockTimesWhateverWhenTheWindowStarts() throws {
        let calendar = losAngeles()
        func hours(from start: DateComponents, to end: DateComponents) throws -> [Int] {
            let lower = try XCTUnwrap(calendar.date(from: start))
            let upper = try XCTUnwrap(calendar.date(from: end))
            let span = lower ... upper
            return IntradaySeriesSection.axisTicks(in: span, calendar: calendar).map { calendar.component(.hour, from: $0) }
        }

        // A rolling 24 hours that begins mid-afternoon is labelled 6 PM, midnight, 6 AM, noon.
        XCTAssertEqual(try hours(from: DateComponents(year: 2026, month: 9, day: 30, hour: 15, minute: 25),
                                 to: DateComponents(year: 2026, month: 10, day: 1, hour: 15, minute: 25)), [18, 0, 6, 12])

        // A calendar day keeps its own midnight and the three marks after it, but not the next midnight, which
        // is the day after.
        XCTAssertEqual(try hours(from: DateComponents(year: 2026, month: 10, day: 1),
                                 to: DateComponents(year: 2026, month: 10, day: 2)), [0, 6, 12, 18])

        // The 25-hour and 23-hour days still get one mark per six hours of the clock.
        XCTAssertEqual(try hours(from: DateComponents(year: 2026, month: 11, day: 1),
                                 to: DateComponents(year: 2026, month: 11, day: 2)), [0, 6, 12, 18])
        XCTAssertEqual(try hours(from: DateComponents(year: 2026, month: 3, day: 8),
                                 to: DateComponents(year: 2026, month: 3, day: 9)), [0, 6, 12, 18])
    }

    // MARK: - catalog mapping and wording

    func testOnlyTheStrapsOwnEntriesMapToASeries() {
        XCTAssertEqual(IntradayMetric(catalogKey: "hrv", source: "my-whoop"), .hrv)
        XCTAssertEqual(IntradayMetric(catalogKey: "rhr", source: "my-whoop"), .restingHeartRate)
        XCTAssertEqual(IntradayMetric(catalogKey: "resp_rate", source: "my-whoop"), .respiratoryRate)
        XCTAssertEqual(IntradayMetric(catalogKey: "steps", source: "my-whoop"), .steps)
        XCTAssertEqual(IntradayMetric(catalogKey: "energy_kcal", source: "my-whoop"), .calories)

        XCTAssertNil(IntradayMetric(catalogKey: "steps", source: "apple-health"))
        XCTAssertNil(IntradayMetric(catalogKey: "rhr", source: "xiaomi-band"))
        XCTAssertNil(IntradayMetric(catalogKey: "steps_est", source: "my-whoop"))
        XCTAssertNil(IntradayMetric(catalogKey: "spo2", source: "my-whoop"))
    }

    func testEveryMetricHasACatalogEntryThatShowsIt() {
        for metric in IntradayMetric.allCases {
            let keys = ["hrv", "rhr", "resp_rate", "steps", "energy_kcal"]
            let mapped = keys.filter { IntradayMetric(catalogKey: $0, source: "my-whoop") == metric }
            XCTAssertEqual(mapped.count, 1, "\(metric) must be reachable from exactly one catalog key")
            XCTAssertNotNil(MetricCatalog.metric(key: mapped[0], source: "my-whoop"),
                            "\(mapped[0]) must exist in the catalog for the strap")
        }
    }

    func testWireNamesMatchTheServersAllowList() {
        XCTAssertEqual(Set(IntradayMetric.allCases.map(\.rawValue)),
                       ["hrv_rmssd_ms", "resting_hr_bpm", "resp_rate_bpm", "steps", "calories_kcal"])
    }

    func testFormattingFollowsTheMetric() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(IntradayMetric.hrv.format(62.6, locale: us), "63")
        XCTAssertEqual(IntradayMetric.respiratoryRate.format(15.04, locale: us), "15.0")
        XCTAssertEqual(IntradayMetric.steps.format(12_345.4, locale: us), "12,345")
        XCTAssertTrue(IntradayMetric.steps.isCumulative && IntradayMetric.calories.isCumulative)
        XCTAssertFalse(IntradayMetric.hrv.isCumulative || IntradayMetric.restingHeartRate.isCumulative
                       || IntradayMetric.respiratoryRate.isCumulative)
    }

    func testAgeNeverClaimsFreshnessItCannotBackUp() {
        let now = Date(timeIntervalSince1970: 1_790_888_592)
        XCTAssertEqual(IntradayFormat.age(from: now.addingTimeInterval(-30), to: now), "just now")
        XCTAssertEqual(IntradayFormat.age(from: now.addingTimeInterval(120), to: now), "just now",
                       "a computed-at in the future is a skewed clock, not freshness")
        XCTAssertTrue(IntradayFormat.age(from: now.addingTimeInterval(-300), to: now).contains("5"))
        XCTAssertTrue(IntradayFormat.age(from: now.addingTimeInterval(-3 * 3_600), to: now).contains("3"))
        XCTAssertTrue(IntradayFormat.age(from: now.addingTimeInterval(-2 * 86_400), to: now).contains("2"))
    }

    // MARK: - repository

    func testFetchAsksTheSeriesRouteParsesAndCaches() async throws {
        SeriesStub.body = edgeBody()
        let repo = repository()
        let window = try await repo.intradaySeries(from: dayStart, to: dayStart + 86_400, deviceId: "whoop-MGB0214654",
                                                   metrics: [.hrv, .steps], cacheKey: "hrv|live")
        XCTAssertEqual(window.points(.hrv).count, 2)

        let request = try XCTUnwrap(SeriesStub.requests.first)
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.path, "/functions/v1/scores/series")
        let query = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["deviceId"], "whoop-MGB0214654")
        XCTAssertEqual(query["from"], String(dayStart))
        XCTAssertEqual(query["to"], String(dayStart + 86_400))
        XCTAssertEqual(query["metrics"], "hrv_rmssd_ms,steps")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop_x")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-noop-fleet-token"), "noop_test")

        // The cache returns exactly what the network read produced.
        let cached = await repo.cachedIntradaySeries(cacheKey: "hrv|live", deviceId: "whoop-MGB0214654")
        XCTAssertEqual(cached, window)
        let otherKey = await repo.cachedIntradaySeries(cacheKey: "steps|live", deviceId: "whoop-MGB0214654")
        XCTAssertNil(otherKey, "entries are per screen")
        let otherDevice = await repo.cachedIntradaySeries(cacheKey: "hrv|live", deviceId: "another-strap")
        XCTAssertNil(otherDevice, "entries are per device")
    }

    func testNoMetricsMeansAllFiveAndNoFilterIsSent() async throws {
        SeriesStub.body = edgeBody()
        _ = try await repository().intradaySeries(from: dayStart, to: dayStart + 3_600, deviceId: "d", cacheKey: "all")
        let url = try XCTUnwrap(SeriesStub.requests.first?.url)
        let names = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map(\.name)
        XCTAssertFalse(names.contains("metrics"))
    }

    func testAnotherOwnerNeverSeesTheCachedSeriesAndTheOriginalOwnerKeepsIt() async throws {
        SeriesStub.body = edgeBody()
        let mine = repository()
        let window = try await mine.intradaySeries(from: dayStart, to: dayStart + 86_400, deviceId: "d", cacheKey: "k")

        let theirs = repository(owner: "33333333-3333-4333-8333-333333333333")
        let foreign = await theirs.cachedIntradaySeries(cacheKey: "k", deviceId: "d")
        XCTAssertNil(foreign, "another owner's readings must never be returned")
        let stillMine = await mine.cachedIntradaySeries(cacheKey: "k", deviceId: "d")
        XCTAssertEqual(stillMine, window)
    }

    func testAFailedReadKeepsTheLastCachedSeriesAndSaysWhy() async throws {
        SeriesStub.body = edgeBody()
        let repo = repository()
        let good = try await repo.intradaySeries(from: dayStart, to: dayStart + 86_400, deviceId: "d", cacheKey: "k")

        SeriesStub.status = 409
        SeriesStub.body = ["error": "device_registration_pending"]
        do {
            _ = try await repo.intradaySeries(from: dayStart, to: dayStart + 86_400, deviceId: "d", cacheKey: "k")
            XCTFail("a 409 must surface")
        } catch let error as ServerScoreRepository.ReadError {
            guard case .http(let code, _) = error else { return XCTFail("expected an HTTP error, got \(error)") }
            XCTAssertEqual(code, 409)
        }
        let cached = await repo.cachedIntradaySeries(cacheKey: "k", deviceId: "d")
        XCTAssertEqual(cached, good, "a failed read must not clobber what was already stored")

        SeriesStub.status = 200
        SeriesStub.body = ["series": NSNull()]
        do {
            _ = try await repo.intradaySeries(from: dayStart, to: dayStart + 86_400, deviceId: "d", cacheKey: "k")
            XCTFail("a null series is malformed")
        } catch let error as ServerScoreRepository.ReadError {
            guard case .malformed = error else { return XCTFail("expected malformed, got \(error)") }
        }
        let afterMalformed = await repo.cachedIntradaySeries(cacheKey: "k", deviceId: "d")
        XCTAssertEqual(afterMalformed, good)
    }

    func testAnUnconfiguredBuildTouchesNoNetwork() async {
        let repo = ServerScoreRepository(session: SeriesStub.session(), endpoint: nil, fleetToken: "",
                                         directory: directory, identity: { nil })
        do {
            _ = try await repo.intradaySeries(from: 1, to: 2, deviceId: "d", cacheKey: "k")
            XCTFail("must not read without configuration")
        } catch {
            XCTAssertTrue(SeriesStub.requests.isEmpty)
        }
        let cached = await repo.cachedIntradaySeries(cacheKey: "k", deviceId: "d")
        XCTAssertNil(cached)
    }

    // MARK: - store

    @MainActor
    func testTheStorePaintsTheCachedWindowFirstAndNeverOverwritesALiveOne() async throws {
        // F6b (audit-g1-day): loadCached only seeds a `|live` window that REACHES the current local
        // midnight (a prior-day cache must not paint as today), so the fixture window is current-dated.
        let now = Int(Date().timeIntervalSince1970)
        let from = now - 86_400
        var currentBody = edgeBody()
        if var series = currentBody["series"] as? [String: Any] {
            series["from"] = from
            series["to"] = now
            currentBody["series"] = series
        }
        SeriesStub.body = currentBody
        let repo = repository()
        let bounds = IntradayRange.Bounds(from: from, to: now, key: "hrv_rmssd_ms|live", isLive: true)
        let warm = try await repo.intradaySeries(from: bounds.from, to: bounds.to, deviceId: "my-whoop",
                                                 metrics: [.hrv], cacheKey: bounds.key)

        let store = IntradaySeriesStore(repositoryProvider: { repo })
        await store.loadCached(bounds)
        XCTAssertEqual(store.windows[bounds.key], warm)

        // A network read replaces it, and a later cache load does not step back over the newer window.
        var fresher = currentBody
        var series = try XCTUnwrap(fresher["series"] as? [String: Any])
        var metrics = try XCTUnwrap(series["metrics"] as? [String: Any])
        let newer: [[Any]] = [[dayStart, 58.0, 90, 0.7, NSNull()], [dayStart + 600, 70.0, 100, 0.9, NSNull()]]
        metrics["hrv_rmssd_ms"] = newer
        series["metrics"] = metrics
        fresher["series"] = series
        SeriesStub.body = fresher
        await store.refresh(.hrv, bounds: bounds)
        XCTAssertEqual(store.windows[bounds.key]?.latest(.hrv)?.value, 70.0)
        XCTAssertNil(store.failures[bounds.key])
        await store.loadCached(bounds)
        XCTAssertEqual(store.windows[bounds.key]?.latest(.hrv)?.value, 70.0)
    }

    @MainActor
    func testAFailedRefreshKeepsWhatWasShownAndRecordsTheFailure() async throws {
        SeriesStub.body = edgeBody()
        let repo = repository()
        let store = IntradaySeriesStore(repositoryProvider: { repo })
        let bounds = IntradayRange.Bounds(from: dayStart, to: dayStart + 86_400, key: "steps|day|\(dayStart)", isLive: true)
        await store.refresh(.steps, bounds: bounds)
        let shown = try XCTUnwrap(store.windows[bounds.key])

        SeriesStub.status = 500
        await store.refresh(.steps, bounds: bounds)
        XCTAssertEqual(store.windows[bounds.key], shown)
        XCTAssertNotNil(store.failures[bounds.key])

        SeriesStub.status = 200
        await store.refresh(.steps, bounds: bounds)
        XCTAssertNil(store.failures[bounds.key], "a good read clears the failure")
    }

    @MainActor
    func testWithoutARepositoryTheStoreDoesNothing() async {
        let store = IntradaySeriesStore(repositoryProvider: { nil })
        let bounds = IntradayRange.Bounds(from: 1, to: 2, key: "k", isLive: true)
        await store.loadCached(bounds)
        await store.refresh(.hrv, bounds: bounds)
        XCTAssertTrue(store.windows.isEmpty)
        XCTAssertTrue(store.failures.isEmpty)
    }
}

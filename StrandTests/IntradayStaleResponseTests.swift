import XCTest
@testable import Strand

/// G1 T04 (findings/g1-day-ui.md Q3): a response that STARTED before local midnight must never land after
/// midnight and overwrite the new day's live window under the shared `"<metric>|live"` key. The
/// `IntradaySeriesStore` generation guard drops a stale pre-midnight read the moment the day rolls; a
/// fresh post-rollover read still writes.
@MainActor
final class IntradayStaleResponseTests: XCTestCase {

    private let owner = "11111111-1111-4111-8111-111111111111"
    private let dayStart = 1_790_838_000      // 2026-10-01 00:00 America/Los_Angeles
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-stale-series-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        GatedSeriesStub.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func edgeBody() -> [String: Any] {
        let hrv: [[Any]] = [[dayStart + 300, 62.5, 120, 0.8, 0.05], [dayStart, 58.0, 90, 0.7, NSNull()]]
        let metrics: [String: Any] = ["hrv_rmssd_ms": hrv, "resting_hr_bpm": [[Any]](),
                                      "resp_rate_bpm": [[Any]](), "steps": [[Any]](),
                                      "calories_kcal": [[Any]]()]
        return ["series": ["from": dayStart, "to": dayStart + 86_400, "bucket_seconds": 300,
                           "latest_computed_at": "2026-10-01T21:03:12.345678+00:00", "metrics": metrics],
                "identity": ["userId": owner]]
    }

    private func repository(session: URLSession) -> ServerScoreRepository {
        ServerScoreRepository(
            session: session,
            endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
            directory: directory,
            identity: { CloudPushIdentity(ownerId: self.owner,
                                          sourceId: "22222222-2222-4222-8222-222222222222",
                                          tokenId: "t", uploadToken: "noop_x") })
    }

    /// A pre-midnight refresh that is still in flight when the day rolls must be DROPPED, not written.
    func testStalePreMidnightResponseIsDroppedAfterDayRollover() async throws {
        GatedSeriesStub.body = edgeBody()
        GatedSeriesStub.armGate()
        let store = IntradaySeriesStore(repositoryProvider: { self.repository(session: GatedSeriesStub.session()) })
        let bounds = IntradayRange.Bounds(from: dayStart, to: dayStart + 86_400,
                                          key: "hrv_rmssd_ms|live", isLive: true)

        // Start a read that will suspend on the gate (the pre-midnight request).
        let staleTask = Task { await store.refresh(.hrv, bounds: bounds) }
        await GatedSeriesStub.waitForRequestStarted()

        // Local midnight rolls over while the read is in flight: the store bumps its generation.
        store.noteDayRolledOver()

        // Release the stale response.
        GatedSeriesStub.releaseGate()
        await staleTask.value

        // The stale pre-midnight window must never have been written.
        XCTAssertNil(store.windows[bounds.key],
                     "a response started before the day rollover must not overwrite the new day's live key")
        XCTAssertNil(store.failures[bounds.key], "a dropped stale read must not record a failure either")

        // A fresh post-rollover read writes normally.
        await store.refresh(.hrv, bounds: bounds)
        XCTAssertNotNil(store.windows[bounds.key],
                        "a fresh read after the rollover is the new day's window and must write")
    }

    /// A cancelled in-flight read is dropped too (honours Task cancellation before assignment).
    func testCancelledRefreshIsDropped() async throws {
        GatedSeriesStub.body = edgeBody()
        GatedSeriesStub.armGate()
        let store = IntradaySeriesStore(repositoryProvider: { self.repository(session: GatedSeriesStub.session()) })
        let bounds = IntradayRange.Bounds(from: dayStart, to: dayStart + 86_400,
                                          key: "hrv_rmssd_ms|live", isLive: true)

        let staleTask = Task { await store.refresh(.hrv, bounds: bounds) }
        await GatedSeriesStub.waitForRequestStarted()
        staleTask.cancel()
        GatedSeriesStub.releaseGate()
        await staleTask.value

        XCTAssertNil(store.windows[bounds.key],
                     "a cancelled in-flight read must not write its window")
    }

    // MARK: - audit-g1-day F6

    /// F6a: a pre-midnight in-flight refresh holds the shared `|live` slot; the rollover must RELEASE it
    /// so the new day's refresh starts immediately instead of waiting for the stale one (≤30 s self-heal).
    @MainActor
    func testDayRolloverReleasesTheInFlightSlotForTheLiveKey() async throws {
        GatedSeriesStub.body = edgeBody()
        GatedSeriesStub.armGate()
        let store = IntradaySeriesStore(repositoryProvider: { self.repository(session: GatedSeriesStub.session()) })
        let bounds = IntradayRange.Bounds(from: dayStart, to: dayStart + 86_400,
                                          key: "hrv_rmssd_ms|live", isLive: true)

        // Pre-midnight refresh that is still awaiting its response.
        let staleTask = Task { await store.refresh(.hrv, bounds: bounds) }
        await GatedSeriesStub.waitForRequestStarted()
        store.noteDayRolledOver()   // releases the slot (and drops the stale generation)

        // A NEW refresh for the SAME live key must start immediately — not be blocked until the stale
        // one finishes. `waitForRequestStarted` only returns when this request reached the URL layer.
        let freshTask = Task { await store.refresh(.hrv, bounds: bounds) }
        await GatedSeriesStub.waitForRequestStarted()

        GatedSeriesStub.releaseGate()
        await staleTask.value
        await freshTask.value

        // The stale (pre-rollover) response was dropped; the fresh one wrote the new day's window.
        XCTAssertEqual(store.windows[bounds.key]?.latest(.hrv)?.value, 62.5,
                       "the fresh post-rollover read writes; the stale one is dropped (generation guard)")
        XCTAssertNil(store.failures[bounds.key])
    }

    /// F6b: on a cold launch after midnight, a cached PRIOR-DAY window under the constant `|live` key
    /// must not seed the new day's view.
    @MainActor
    func testLoadCachedSkipsAPriorDayLiveWindow() async throws {
        GatedSeriesStub.body = edgeBody()   // immediate delivery (gate not armed)
        let repo = repository(session: GatedSeriesStub.session())
        let store = IntradaySeriesStore(repositoryProvider: { repo })
        let bounds = IntradayRange.Bounds(from: dayStart, to: dayStart + 86_400,
                                          key: "hrv_rmssd_ms|live", isLive: true)
        // Prime the on-disk cache for the live key with a window that ends BEFORE the current local
        // midnight (the existing edgeBody is 2026-10-01 — long past on this machine).
        _ = try await repo.intradaySeries(from: bounds.from, to: bounds.to, deviceId: "my-whoop",
                                          metrics: [.hrv], cacheKey: bounds.key)
        await store.loadCached(bounds)
        XCTAssertNil(store.windows[bounds.key],
                     "a PRIOR-DAY cached live window must not paint as the new day's window (F6b)")
    }

    /// F6b control: a cached live window that reaches the current local midnight IS applied.
    @MainActor
    func testLoadCachedAppliesACurrentDayLiveWindow() async throws {
        // The response's from/to must span the current local midnight (the request args don't change
        // what the server publishes).
        let now = Int(Date().timeIntervalSince1970)
        let from = now - 3_600
        var body = edgeBody()
        var series = try XCTUnwrap(body["series"] as? [String: Any])
        series["from"] = from
        series["to"] = now
        body["series"] = series
        GatedSeriesStub.body = body
        let repo = repository(session: GatedSeriesStub.session())
        let store = IntradaySeriesStore(repositoryProvider: { repo })
        let bounds = IntradayRange.Bounds(from: from, to: now, key: "hrv_rmssd_ms|live", isLive: true)
        _ = try await repo.intradaySeries(from: from, to: now, deviceId: "my-whoop",
                                          metrics: [.hrv], cacheKey: bounds.key)
        await store.loadCached(bounds)
        XCTAssertNotNil(store.windows[bounds.key],
                        "a cached live window that reaches today's local midnight is the current day's and applies")
    }

    /// Control: with no rollover in between, a refresh writes and a later one replaces it.
    func testSameGenerationRefreshWritesNormally() async throws {
        GatedSeriesStub.body = edgeBody()
        let store = IntradaySeriesStore(repositoryProvider: { self.repository(session: GatedSeriesStub.session()) })
        let bounds = IntradayRange.Bounds(from: dayStart, to: dayStart + 86_400,
                                          key: "hrv_rmssd_ms|live", isLive: true)
        await store.refresh(.hrv, bounds: bounds)
        XCTAssertNotNil(store.windows[bounds.key])
        // A day rollover then a fresh read: the fresh read is the new generation and writes.
        store.noteDayRolledOver()
        await store.refresh(.hrv, bounds: bounds)
        XCTAssertNotNil(store.windows[bounds.key])
    }
}

/// A URLProtocol that can HOLD a response until the test releases it, so a refresh can be left suspended
/// mid-await while the day rolls over underneath it.
private final class GatedSeriesStub: URLProtocol {
    static var body: [String: Any] = [:]
    static var requests: [URLRequest] = []
    /// When true, pending responses are delivered immediately. `armGate()` flips it false so responses
    /// HOLD until `releaseGate()`. Polled by every suspended response, so MULTIPLE concurrent requests
    /// all release together (F6a needs two in-flight refreshes on the same `|live` key).
    private static var released = true
    private static var startedContinuation: CheckedContinuation<Void, Never>?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    static func armGate() { released = false }
    static func releaseGate() { released = true }
    static func waitForRequestStarted() async {
        if let startedContinuation {
            startedContinuation.resume()
            self.startedContinuation = nil
            return
        }
        await withCheckedContinuation { startedContinuation = $0 }
    }
    static func reset() {
        body = [:]
        requests = []
        released = true
        startedContinuation = nil
    }

    /// Resolve any waiter that asked to be told when the request reached startLoading.
    private static func markStarted() {
        if let continuation = startedContinuation {
            continuation.resume()
            startedContinuation = nil
        }
    }

    override func startLoading() {
        GatedSeriesStub.requests.append(request)
        GatedSeriesStub.markStarted()
        let data = (try? JSONSerialization.data(withJSONObject: GatedSeriesStub.body)) ?? Data()
        let http = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                   headerFields: nil)!
        let client = self.client
        let proto = self
        Task {
            // Hold (or deliver immediately) per the gate; polling lets several responses release together.
            while !GatedSeriesStub.released {
                try? await Task.sleep(nanoseconds: 1_000_000)
            }
            client?.urlProtocol(proto, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(proto, didLoad: data)
            client?.urlProtocolDidFinishLoading(proto)
        }
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GatedSeriesStub.self]
        return URLSession(configuration: config)
    }
}

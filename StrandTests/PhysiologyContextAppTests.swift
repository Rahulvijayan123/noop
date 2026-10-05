import XCTest
import StrandAnalytics
@testable import Strand

/// A transport stub: records what the repository asked for and answers per request, so the real request,
/// parse and cache path runs with no network.
private final class ContextStub: URLProtocol {
    static var status = 200
    static var body: Any = [String: Any]()
    /// Per-request answer; overrides `status` / `body` when set.
    static var responder: ((URLRequest) -> (Int, Any))?
    /// Seconds to hold each answer back (to put a read in flight).
    static var delay: TimeInterval = 0
    static var requests: [URLRequest] = []
    private static let lock = NSLock()

    static func reset() {
        status = 200; body = [String: Any](); responder = nil; delay = 0
        lock.lock(); requests = []; lock.unlock()
    }

    static var requestCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); Self.lock.unlock()
        let (status, body) = Self.responder?(request) ?? (Self.status, Self.body)
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let respond = { [weak self] in
            guard let self else { return }
            let http = HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if Self.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.delay, execute: respond)
        } else {
            respond()
        }
    }
    override func stopLoading() {}

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ContextStub.self]
        return URLSession(configuration: config)
    }
}

/// The phone side of the physiology context layer: the repository (routes, auth, owner-isolated cache, old
/// servers), the store's state machine (including context built from an earlier scoring result), and the
/// wording the card, detail and history screens show.
final class PhysiologyContextAppTests: XCTestCase {

    typealias PC = PhysiologyContext

    private let owner = "11111111-1111-4111-8111-111111111111"
    private let tz = "America/Los_Angeles"
    private let day = "2026-10-01"
    private var dayWindow: PC.Interval { PC.Engine.dayInterval(day, timezoneId: tz) }
    private let en = Locale(identifier: "en_US")
    private let gb = Locale(identifier: "en_GB")

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("noop-pc-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ContextStub.reset()
    }

    override func tearDownWithError() throws {
        ContextStub.reset()
        try? FileManager.default.removeItem(at: directory)
    }

    private func repository(owner: String? = nil) -> PhysiologyContextRepository {
        let ownerId = owner ?? self.owner
        return PhysiologyContextRepository(
            session: ContextStub.session(),
            endpoint: URL(string: "https://example.invalid/functions/v1/scores")!,
            directory: directory,
            identity: { CloudPushIdentity(ownerId: ownerId, sourceId: "22222222-2222-4222-8222-222222222222",
                                          tokenId: "t", uploadToken: "noop_x") })
    }

    private func query(_ request: URLRequest?) -> [String: String] {
        guard let url = request?.url else { return [:] }
        return Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }

    // MARK: - Fixtures

    /// A small synthetic day run through the real engine (placeholder systems included).
    private func builtDocument() -> PC.DayDocument {
        let w = dayWindow
        let night = PC.Interval(w.start - 50 * 60, w.start + 6 * 3600 + 42 * 60)
        let hr = stride(from: w.start + 14 * 3600, to: w.start + 14 * 3600 + 900, by: 1).map {
            PC.HeartRateObservation(ts: $0, bpm: 58 + ($0 % 7), availableAt: $0 + 40)
        }
        let nightly = PC.MeasurementInput(
            metric: .hrvRmssd,
            method: PC.MethodRef(id: "snapshot.hrv_rmssd.night", algorithmVersion: "frwhoop-server-1",
                                 aggregation: .session, windowS: night.duration, units: "ms"),
            source: PC.SourceRef(product: .scoringSnapshot, key: "daily.hrv_rmssd_ms", inputRevision: 3,
                                 resultRevision: 12),
            value: 48.5, support: night, sessionId: "sleep-1")
        let window = PC.MeasurementInput(
            metric: .hrvRmssd,
            method: PC.MethodRef(id: "series.hrv_rmssd.5min", algorithmVersion: "frwhoop-series-2",
                                 aggregation: .window, windowS: 300, units: "ms"),
            source: PC.SourceRef(product: .metricSeries, key: "hrv_rmssd_ms@\(w.start + 14 * 3600)",
                                 resultRevision: 12),
            value: 52.25, support: PC.Interval(w.start + 14 * 3600, w.start + 14 * 3600 + 300))
        let input = PC.DayInput(
            identity: PC.DayIdentity(deviceScope: "whoop-TEST", day: day, timezoneId: tz, dayWindow: w),
            mode: .retrospective, availabilityCutoff: w.end + 31 * 3600, generatedAt: w.end + 31 * 3600,
            heartRate: hr, measurements: [nightly, window],
            sleepSessions: [PC.SleepSessionInput(id: "sleep-1", interval: night, isNap: false, detector: "v2")],
            regime: PC.DeviceRegimeInput(scoringAlgorithmVersion: "frwhoop-server-1"),
            inputRevisions: [PC.InputRevision(input: "scoring_snapshot", revision: "12")])
        return PC.Engine.buildDay(input, history: .empty)
    }

    private func jsonObject(_ document: PC.DayDocument) throws -> Any {
        try JSONSerialization.jsonObject(with: PC.encoder().encode(document))
    }

    /// The edge's `{context, identity}` envelope.
    private func contextBody(document: Any?, status: String = "available", consistent: Bool? = true,
                             jobPending: Bool = false) -> [String: Any] {
        var context: [String: Any] = ["status": status, "mode": "retrospective", "context_revision": 7,
                                      "finality": "final",
                                      "job": ["pending": jobPending, "dirty_at": NSNull()]]
        if let document { context["document"] = document }
        if let consistent {
            context["pairing"] = ["snapshot_result_revision": 12,
                                  "context_scoring_result_revision": consistent ? 12 : 11,
                                  "consistent": consistent]
        }
        return ["context": context, "identity": ["user_id": owner, "device_id": "whoop-TEST"]]
    }

    private func composition(_ support: PC.Interval, labels: [(String, Double)], unknownS: Double = 0,
                             uncoveredS: Double = 0, source: PC.ActivitySource = .strapMotion) -> PC.ActivityComposition {
        let total = Double(support.duration)
        return PC.ActivityComposition(
            interval: support, intervalS: support.duration, source: source, heartRateDependent: false,
            labels: labels.map { PC.LabelShare(label: $0.0, seconds: $0.1, share: $0.1 / total) },
            unknownS: unknownS, uncoveredS: uncoveredS, transitions: labels.count > 1 ? 1 : 0,
            mixed: labels.count > 1, dominantLabel: labels.first.flatMap { $0.1 / total >= 0.9 ? $0.0 : nil },
            resolvedOverlapS: 0, reasons: uncoveredS > 0 ? ["uncovered_time"] : [])
    }

    private func envelope(metric: PC.MetricKind = .hrvRmssd, nightly: Bool = false, support: PC.Interval,
                          value: Double? = 55, units: String = "ms",
                          labels: [(String, Double)]? = nil, unknownS: Double = 0, uncoveredS: Double = 0,
                          verdicts: [PC.EligibilityVerdict] = [], comparisons: [PC.ReferenceComparison] = [],
                          validity: PC.ValidityState = .valid, coverage: Double? = 0.95,
                          sleep: PC.SleepWakeState = .awake, sinceActivity: Int? = nil,
                          lastActivity: String? = nil, finality: PC.Finality = .final) -> PC.MeasurementEnvelope {
        let method = nightly
            ? PC.MethodRef(id: "snapshot.\(metric.rawValue).night", algorithmVersion: "frwhoop-server-1",
                           aggregation: .session, windowS: support.duration, units: units)
            : PC.MethodRef(id: "series.\(metric.rawValue).5min", algorithmVersion: "frwhoop-series-2",
                           aggregation: .window, windowS: support.duration, units: units)
        let source = PC.SourceRef(product: nightly ? .scoringSnapshot : .metricSeries, key: "k@\(support.start)",
                                  inputRevision: 3, resultRevision: 12)
        let comp = composition(support, labels: labels ?? [("still", Double(support.duration))],
                               unknownS: unknownS, uncoveredS: uncoveredS)
        return PC.MeasurementEnvelope(
            id: PC.MeasurementEnvelope.makeId(method: method, support: support), metric: metric, method: method,
            source: source, value: value, support: support, displayBucket: nil,
            localTime: PC.localTime(at: support.start, timezoneId: tz),
            validity: PC.SignalValidity(state: validity, reasons: validity == .valid ? [] : ["signal_invalid"],
                                        coverage: coverage, observedS: support.duration),
            regimeKey: "r1", activity: comp, decoderActivity: nil,
            preceding: PC.PrecedingHistory(lookback: PC.Interval(support.start - 1800, support.start),
                                           source: .strapMotion, stillRunS: 600, stillRunEndedBy: "movement",
                                           secondsSinceSupportedActivity: sinceActivity,
                                           lastSupportedActivityLabel: lastActivity, coveredS: 1700, transitions: 1),
            sleepWear: PC.SleepWearContext(sleepState: sleep, sleepEvidence: ["outside_detected_sleep"],
                                           sleepDependsOnHeartSignals: true, wearState: .worn,
                                           wearEvidence: ["heart_rate_signal_present"], reasons: []),
            history: PC.HistoryContext(
                wake: PC.WakeReference(secondsSinceWake: 7 * 3600, wakeAt: support.start - 7 * 3600,
                                       referenceEpisodeId: "sleep-1", referenceKind: .mainSleep, reasons: []),
                recentBouts: [PC.BoutRef(boutId: "b1", kind: "walking", endedAt: support.start - 600,
                                         secondsBeforeMeasurement: 600, durationS: 1500)],
                exertion: [PC.ExertionWindowSummary(windowH: 24, interval: PC.Interval(support.start - 86_400, support.start),
                                                    boutCount: 2, locomotionS: 2400, observedS: 70_000, reasons: [])],
                exposures: [],
                exposureCoverage: [PC.ExposureCategoryStatus(kind: .caffeine, status: "recorded"),
                                   PC.ExposureCategoryStatus(kind: .alcohol, status: "unrecorded")]),
            eligibility: verdicts, comparisons: comparisons, finality: finality)
    }

    private func verdict(_ kind: PC.ComparisonKind, _ state: PC.EligibilityState,
                         _ reasons: [PC.ReasonCode] = []) -> PC.EligibilityVerdict {
        PC.EligibilityVerdict(comparison: kind, state: state, reasons: reasons, policyVersion: "pc-eligibility-1")
    }

    private func reference(view: PC.ReferenceView = .rolling, status: PC.ReferenceStatus = .ready,
                           diff: Double? = 6.2, from: String? = "2026-09-03", to: String? = "2026-09-30",
                           series: String = "hrv_rmssd.stable_awake_5min") -> PC.ReferenceComparison {
        PC.ReferenceComparison(day: day, seriesKey: series, regimeKey: "r1", view: view, referenceId: nil,
                               status: status, supportDays: 21, fromDay: from, toDay: to, value: 58,
                               center: 52, scale: 6, scaleFloored: false, signedDifference: diff,
                               transformedDifference: 0.1, robustZ: 1.0, centerUncertainty: 1.5, transform: "ln",
                               pooledContribution: 0, reasons: [])
    }

    private func episode(_ state: PC.EpisodeState, ongoing: Bool = true, finality: PC.Finality = .provisional,
                         series: String = "hrv_rmssd.stable_awake_5min") -> PC.ChangeEpisode {
        PC.ChangeEpisode(id: "ep-\(state.rawValue)-\(series)", seriesKey: series, regimeKey: "r1", state: state,
                         direction: -1, startDay: "2026-09-24", lastDay: day, ongoing: ongoing, durationDays: 8,
                         finality: finality, reasons: ["insufficient_history"])
    }

    /// A day value carrying `envelopes` (and `episodes`) in an otherwise engine-built document.
    private func contextDay(envelopes: [PC.MeasurementEnvelope], episodes: [PC.ChangeEpisode] = [],
                            mode: PC.ProcessingMode = .retrospective, finality: PC.Finality = .final,
                            consistent: Bool? = true, exposures: PC.ExposureDaySummary? = nil,
                            availability: [PC.AvailabilityEntry] = []) throws -> PhysiologyContextDay {
        var doc = builtDocument()
        doc.envelopes = envelopes
        doc.episodes = episodes
        doc.header.interpretation.mode = mode
        doc.header.interpretation.finality = finality
        if let exposures { doc.exposures = exposures }
        doc.availability = availability
        let decoded = try XCTUnwrap(PhysiologyContextDocument.decode(PC.encoder().encode(doc)))
        return PhysiologyContextDay(
            day: day, deviceId: "whoop-TEST", metric: nil, status: .available, mode: mode, contextRevision: 7,
            finality: finality, document: decoded,
            pairing: consistent.map { PhysiologyContextDay.Pairing(snapshotResultRevision: "12",
                                                                   contextScoringResultRevision: $0 ? "12" : "11",
                                                                   consistent: $0) },
            job: nil, fetchedAtMs: 0)
    }

    // MARK: - Repository: routes and auth

    func testDayContextAsksTheContextRouteWithTheInstallationBearerOnly() async throws {
        ContextStub.body = contextBody(document: try jsonObject(builtDocument()))
        let read = try await repository().dayContext(day: day, deviceId: "whoop-MGB0214654", metric: .hrvRmssd)
        guard case .loaded(let value) = read else { return XCTFail("expected a context, got \(read)") }
        XCTAssertEqual(value.status, .available)

        let request = try XCTUnwrap(ContextStub.requests.first)
        XCTAssertEqual(request.url?.path, "/functions/v1/scores/context")
        XCTAssertEqual(request.httpMethod, "GET")
        let q = query(request)
        XCTAssertEqual(q["deviceId"], "whoop-MGB0214654")
        XCTAssertEqual(q["day"], day)
        XCTAssertEqual(q["metric"], "hrv_rmssd")
        XCTAssertNil(q["mode"], "no mode asks for the server default (retrospective when present)")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop_x")
        XCTAssertNil(request.value(forHTTPHeaderField: "x-noop-fleet-token"), "no shared token rides on context reads")
    }

    func testHistoryAsksTheHistoryRouteAndDecodesItsArrays() async throws {
        let doc = builtDocument()
        let bout = PC.ExertionBout(id: "b1", interval: PC.Interval(dayWindow.start + 3600, dayWindow.start + 5400),
                                   day: day, kind: "walking", status: .censored, durationS: 1800,
                                   reasons: ["next_bout"])
        let episodes = try JSONSerialization.jsonObject(with: PC.encoder().encode([episode(.persistentShift)]))
        let bouts = try JSONSerialization.jsonObject(with: PC.encoder().encode([bout]))
        let values = try JSONSerialization.jsonObject(with: PC.encoder().encode(doc.dailyValues))
        ContextStub.body = ["history": ["episodes": episodes, "bouts": bouts, "daily_values": values],
                            "identity": [:]]
        let read = try await repository().history(from: "2026-09-02", to: day, deviceIds: ["whoop-A"], mode: .retrospective)
        guard case .loaded(let history) = read else { return XCTFail("expected history, got \(read)") }
        XCTAssertEqual(history.episodes, [episode(.persistentShift)])
        XCTAssertEqual(history.bouts, [bout])
        XCTAssertEqual(history.dailyValues, doc.dailyValues)

        let request = try XCTUnwrap(ContextStub.requests.first)
        XCTAssertEqual(request.url?.path, "/functions/v1/scores/context/history")
        let q = query(request)
        XCTAssertEqual(q["from"], "2026-09-02")
        XCTAssertEqual(q["to"], day)
        XCTAssertEqual(q["deviceId"], "whoop-A")
        XCTAssertEqual(q["mode"], "retrospective")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop_x")

        let cached = await repository().cachedHistory(from: "2026-09-02", to: day, deviceIds: ["whoop-A"],
                                                      mode: .retrospective)
        XCTAssertEqual(cached?.episodes, history.episodes)
        XCTAssertGreaterThan(cached?.fetchedAtMs ?? 0, 0, "a cached read says it is a saved copy")
    }

    func testAnOverLongHistoryRangeIsClampedToTheServersLimit() async throws {
        ContextStub.body = ["history": ["episodes": [], "bouts": [], "daily_values": []]]
        _ = try await repository().history(from: "2026-01-01", to: day, deviceIds: ["d"])
        let q = query(ContextStub.requests.first)
        XCTAssertEqual(PhysiologyContextDates.inclusiveDays(from: q["from"] ?? "", to: q["to"] ?? ""), 120)
        XCTAssertEqual(q["to"], day)
    }

    // MARK: - Repository: decoding

    func testABuiltDayDocumentRoundTripsThroughTheAPIEnvelopeAndTheCache() async throws {
        let doc = builtDocument()
        XCTAssertFalse(doc.envelopes.isEmpty)
        ContextStub.body = contextBody(document: try jsonObject(doc))
        let repo = repository()
        let read = try await repo.dayContext(day: day, deviceIds: ["whoop-TEST"])
        guard case .loaded(let value) = read else { return XCTFail("expected a context, got \(read)") }

        XCTAssertEqual(value.document?.full, doc, "the document decodes into exactly the engine's types")
        XCTAssertEqual(value.document?.envelopes, doc.envelopes)
        XCTAssertEqual(value.document?.undecodedElements, 0)
        XCTAssertEqual(value.document?.undecodedMembers, [])
        XCTAssertEqual(value.contextRevision, 7)
        XCTAssertEqual(value.mode, .retrospective)
        XCTAssertEqual(value.finality, .final)
        XCTAssertEqual(value.effectiveFinality, doc.header.interpretation.finality)
        XCTAssertEqual(value.pairing, .init(snapshotResultRevision: "12", contextScoringResultRevision: "12",
                                            consistent: true))
        XCTAssertEqual(value.job, .init(pending: false, dirtyAt: nil))
        XCTAssertEqual(value.deviceId, "whoop-TEST")

        let cached = await repo.cachedDayContext(day: day, deviceIds: ["whoop-TEST"])
        XCTAssertEqual(cached?.document?.full, doc, "a cached read goes through the same parser")
        XCTAssertEqual(cached?.pairing, value.pairing)
        let otherMetric = await repo.cachedDayContext(day: day, deviceIds: ["whoop-TEST"], metric: .restingHeartRate)
        XCTAssertNil(otherMetric, "entries are per metric filter")
        let otherDevice = await repo.cachedDayContext(day: day, deviceIds: ["another-strap"])
        XCTAssertNil(otherDevice, "entries are per device")
    }

    func testAnOlderOrNewerShapeKeepsWhatDecodesAndIgnoresUnknownMembers() async throws {
        let doc = builtDocument()
        var object = try XCTUnwrap(try jsonObject(doc) as? [String: Any])
        // A member the app does not know, one it knows removed, and one envelope it cannot read.
        object["something_new"] = ["x": 1]
        object.removeValue(forKey: "functional")
        var envelopes = try XCTUnwrap(object["envelopes"] as? [[String: Any]])
        envelopes[0]["future_field"] = "ignored"
        envelopes.append(["id": "broken"])
        object["envelopes"] = envelopes
        object["sleep"] = "not an object"

        var body = contextBody(document: object)
        var context = try XCTUnwrap(body["context"] as? [String: Any])
        context.removeValue(forKey: "pairing")
        context.removeValue(forKey: "status")
        context["unknown_envelope_member"] = true
        body["context"] = context
        ContextStub.body = body

        let read = try await repository().dayContext(day: day, deviceId: "d")
        guard case .loaded(let value) = read else { return XCTFail("expected a context, got \(read)") }
        let decoded = try XCTUnwrap(value.document)
        XCTAssertNil(decoded.full, "a document missing a member is not a full DayDocument")
        XCTAssertEqual(decoded.envelopes, doc.envelopes, "readable envelopes survive; the broken one is dropped")
        XCTAssertEqual(decoded.undecodedElements, 1)
        XCTAssertEqual(decoded.undecodedMembers, ["sleep"])
        XCTAssertEqual(decoded.header, doc.header)
        XCTAssertEqual(value.status, .available, "a document without a status reads as available")
        XCTAssertNil(value.pairing, "absent pairing is not invented")
    }

    func testANullContextIsNoneAndAMissingContextIsAnOlderServer() async throws {
        ContextStub.body = ["context": NSNull(), "identity": [:]]
        let none = try await repository().dayContext(day: day, deviceId: "d")
        guard case .loaded(let value) = none else { return XCTFail("expected none, got \(none)") }
        XCTAssertEqual(value.status, .none)
        XCTAssertNil(value.document)

        ContextStub.body = ["server_scoring": ["daily": NSNull()]]
        let old = try await repository().dayContext(day: day, deviceId: "d")
        XCTAssertEqual(old, .unsupportedServer)
    }

    // MARK: - Repository: states and failures

    func testAnOldServers405IsUnsupportedNotAnError() async throws {
        ContextStub.status = 405
        ContextStub.body = ["error": "method_not_allowed"]
        let repo = repository()
        let day = try await repo.dayContext(day: self.day, deviceIds: ["whoop-A", "my-whoop"])
        XCTAssertEqual(day, .unsupportedServer)
        XCTAssertEqual(ContextStub.requestCount, 1, "a 405 is server-wide: the other candidates are not asked")
        let history = try await repo.history(from: "2026-09-02", to: self.day, deviceIds: ["whoop-A"])
        XCTAssertEqual(history, .unsupportedServer)
    }

    func testRegistrationPendingIsPendingAndTheNextCandidateStillAnswers() async throws {
        let doc = try jsonObject(builtDocument())
        ContextStub.responder = { request in
            let device = self.query(request)["deviceId"]
            if device == "whoop-NEW" { return (409, ["error": "device_registration_pending"]) }
            return (200, self.contextBody(document: doc))
        }
        let repo = repository()
        let onlyNew = try await repo.dayContext(day: day, deviceIds: ["whoop-NEW"])
        XCTAssertEqual(onlyNew, .deviceRegistrationPending)

        let walked = try await repo.dayContext(day: day, deviceIds: ["whoop-NEW", "my-whoop"])
        guard case .loaded(let value) = walked else { return XCTFail("expected a context, got \(walked)") }
        XCTAssertEqual(value.deviceId, "my-whoop")

        ContextStub.responder = { _ in (409, ["error": "conflict_other"]) }
        do {
            _ = try await repo.dayContext(day: day, deviceIds: ["whoop-NEW"])
            XCTFail("another 409 is a failure, not a state")
        } catch let error as PhysiologyContextRepository.ReadError {
            XCTAssertEqual(error, .http(409, "{\"error\":\"conflict_other\"}"))
        }
    }

    func testTheWalkPrefersAnAvailableDocumentOverPendingOrNone() async throws {
        let doc = try jsonObject(builtDocument())
        ContextStub.responder = { request in
            switch self.query(request)["deviceId"] {
            case "a": return (200, ["context": ["status": "none"]])
            case "b": return (200, ["context": ["status": "pending", "job": ["pending": true, "dirty_at": "2026-10-01T10:00:00Z"]]])
            default: return (200, self.contextBody(document: doc))
            }
        }
        let repo = repository()
        let best = try await repo.dayContext(day: day, deviceIds: ["a", "b", "c"])
        guard case .loaded(let value) = best else { return XCTFail() }
        XCTAssertEqual(value.deviceId, "c")
        XCTAssertEqual(value.status, .available)

        let pending = try await repo.dayContext(day: day, deviceIds: ["a", "b"])
        guard case .loaded(let p) = pending else { return XCTFail() }
        XCTAssertEqual(p.status, .pending)
        XCTAssertEqual(p.job, .init(pending: true, dirtyAt: "2026-10-01T10:00:00Z"))

        let cached = await repo.cachedDayContext(day: day, deviceIds: ["a", "b", "c"])
        XCTAssertEqual(cached?.deviceId, "c", "the cache prefers the candidate holding an available document")
    }

    func testAnotherOwnerNeverSeesTheCachedContextAndTheOriginalOwnerKeepsIt() async throws {
        let doc = builtDocument()
        ContextStub.body = contextBody(document: try jsonObject(doc))
        let mine = repository()
        _ = try await mine.dayContext(day: day, deviceId: "d")

        let theirs = repository(owner: "33333333-3333-4333-8333-333333333333")
        let foreign = await theirs.cachedDayContext(day: day, deviceIds: ["d"])
        XCTAssertNil(foreign, "another owner's context must never be returned")
        let stillMine = await mine.cachedDayContext(day: day, deviceIds: ["d"])
        XCTAssertEqual(stillMine?.document?.full, doc)

        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(files.isEmpty)
        XCTAssertFalse(files.contains { $0.contains(owner) || $0.contains(day) },
                       "no owner id or day appears in a cache path")
    }

    func testAFailedReadThrowsAndKeepsTheLastCachedContext() async throws {
        let doc = builtDocument()
        ContextStub.body = contextBody(document: try jsonObject(doc))
        let repo = repository()
        _ = try await repo.dayContext(day: day, deviceId: "d")
        ContextStub.status = 500
        ContextStub.body = ["error": "boom"]
        do {
            _ = try await repo.dayContext(day: day, deviceIds: ["d"])
            XCTFail("a 500 must surface")
        } catch let error as PhysiologyContextRepository.ReadError {
            guard case .http(500, _) = error else { return XCTFail("expected HTTP 500, got \(error)") }
        }
        let cached = await repo.cachedDayContext(day: day, deviceIds: ["d"])
        XCTAssertEqual(cached?.document?.full, doc, "a failed read must not clobber what was stored")
    }

    func testAnUnconfiguredBuildTouchesNoNetwork() async {
        let repo = PhysiologyContextRepository(session: ContextStub.session(), endpoint: nil, directory: directory,
                                               identity: { nil })
        do {
            _ = try await repo.dayContext(day: day, deviceId: "d")
            XCTFail("must not read without configuration")
        } catch {
            XCTAssertEqual(ContextStub.requestCount, 0)
        }
        let cached = await repo.cachedDayContext(day: day, deviceIds: ["d"])
        XCTAssertNil(cached)
    }

    // MARK: - Store

    @MainActor
    private func store(cloud: Bool = true, signedIn: Bool = true,
                       repository repo: PhysiologyContextRepository?) -> PhysiologyContextStore {
        PhysiologyContextStore(environment: .init(cloudEnabled: { cloud }, signedIn: { signedIn },
                                                  repository: { repo }))
    }

    @MainActor
    func testTheStoreSaysWhyThereIsNothingInsteadOfLoadingForever() async {
        let key = PhysiologyContextStore.Key(day: day, metric: .hrvRmssd)
        let off = store(cloud: false, repository: repository())
        await off.load(key)
        XCTAssertEqual(off.state(for: key), .unavailable(.cloudOff))

        let signedOut = store(signedIn: false, repository: nil)
        await signedOut.load(key)
        XCTAssertEqual(signedOut.state(for: key), .unavailable(.signedOut))

        let connecting = store(signedIn: true, repository: nil)
        await connecting.load(key)
        XCTAssertEqual(connecting.state(for: key), .unavailable(.accountNotReady))
        XCTAssertEqual(ContextStub.requestCount, 0)

        let before = connecting.epoch
        connecting.setReadCandidates(["my-whoop"])
        XCTAssertGreaterThan(connecting.epoch, before, "a card waiting for the account retries when it is ready")
    }

    @MainActor
    func testTheStoreStateMachine() async throws {
        let doc = try jsonObject(builtDocument())
        let key = PhysiologyContextStore.Key(day: day, metric: .hrvRmssd)
        let s = store(repository: repository())
        s.setReadCandidates(["whoop-A"])

        ContextStub.body = contextBody(document: doc)
        await s.load(key)
        guard case .available(let shown)? = s.state(for: key) else { return XCTFail("\(String(describing: s.state(for: key)))") }
        XCTAssertEqual(shown.deviceId, "whoop-A")
        XCTAssertEqual(query(ContextStub.requests.last)["metric"], "hrv_rmssd")

        // Built from an earlier scoring result: shown as updating, never as current.
        ContextStub.body = contextBody(document: doc, consistent: false)
        await s.load(key)
        guard case .stale(let stale)? = s.state(for: key) else { return XCTFail("expected stale") }
        XCTAssertEqual(stale.pairing?.consistent, false)
        XCTAssertTrue(s.state(for: key)?.wantsPolling == true)

        ContextStub.body = ["context": ["status": "pending", "job": ["pending": true]]]
        await s.load(key)
        XCTAssertEqual(s.state(for: key), .pending(nil, .computing))

        ContextStub.body = ["context": ["status": "none"]]
        await s.load(key)
        XCTAssertEqual(s.state(for: key), .unavailable(.noData))

        ContextStub.status = 409
        ContextStub.body = ["error": "device_registration_pending"]
        await s.load(key)
        XCTAssertEqual(s.state(for: key), .pending(nil, .deviceRegistration))

        ContextStub.status = 405
        ContextStub.body = ["error": "method_not_allowed"]
        await s.load(key)
        XCTAssertEqual(s.state(for: key), .unavailable(.unsupportedServer))

        // A failure keeps what was shown.
        ContextStub.status = 200
        ContextStub.body = contextBody(document: doc)
        await s.load(key)
        guard case .available(let good)? = s.state(for: key) else { return XCTFail("expected available") }
        ContextStub.status = 503
        await s.load(key)
        XCTAssertEqual(s.state(for: key), .failed(cached: good, message: "http-503"))

        // Reset forgets everything and points back at the provisional device.
        let epoch = s.epoch
        s.reset()
        XCTAssertNil(s.state(for: key))
        XCTAssertEqual(s.readCandidates, ["my-whoop"])
        XCTAssertGreaterThan(s.epoch, epoch)
    }

    @MainActor
    func testTheStorePaintsTheCacheFirstAndAFirstFailureWithoutOneSaysSo() async throws {
        let key = PhysiologyContextStore.Key(day: day, metric: .hrvRmssd)
        let repo = repository()
        ContextStub.status = 500
        let empty = store(repository: repo)
        await empty.load(key)
        XCTAssertEqual(empty.state(for: key), .failed(cached: nil, message: "http-500"))

        ContextStub.status = 200
        ContextStub.body = contextBody(document: try jsonObject(builtDocument()))
        _ = try await repo.dayContext(day: day, deviceId: "my-whoop", metric: .hrvRmssd)
        ContextStub.status = 500
        let warm = store(repository: repo)
        await warm.load(key)
        guard case .failed(let cached?, _)? = warm.state(for: key) else { return XCTFail("expected the cached copy") }
        XCTAssertGreaterThan(cached.fetchedAtMs, 0)
    }

    @MainActor
    func testAReadInFlightWhenTheAccountEndsNeverLands() async throws {
        let key = PhysiologyContextStore.Key(day: day, metric: .hrvRmssd)
        ContextStub.body = contextBody(document: try jsonObject(builtDocument()))
        ContextStub.delay = 0.6
        let s = store(repository: repository())
        let read = Task { await s.load(key) }
        for _ in 0..<200 where ContextStub.requestCount == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(ContextStub.requestCount, 1)
        s.reset()
        await read.value
        XCTAssertNil(s.state(for: key), "a response read with the previous account's credential is dropped")
    }

    @MainActor
    func testTheStoreLoadsHistoryAndMapsOldServers() async throws {
        let key = PhysiologyContextStore.HistoryKey(from: "2026-09-02", to: day)
        let s = store(repository: repository())
        ContextStub.body = ["history": ["episodes": try JSONSerialization.jsonObject(
            with: PC.encoder().encode([episode(.transientDeviation)])), "bouts": [], "daily_values": []]]
        await s.loadHistory(key)
        guard case .loaded(let h)? = s.historyState(for: key) else { return XCTFail() }
        XCTAssertEqual(h.episodes.count, 1)

        ContextStub.status = 405
        await s.loadHistory(key)
        XCTAssertEqual(s.historyState(for: key), .unavailable(.unsupportedServer))
    }

    func testClassifyNeverPairsStaleContextSilently() throws {
        let fresh = try contextDay(envelopes: [], consistent: true)
        XCTAssertEqual(PhysiologyContextStore.classify(fresh), .available(fresh))
        let unknown = try contextDay(envelopes: [], consistent: nil)
        XCTAssertEqual(PhysiologyContextStore.classify(unknown), .available(unknown))
        let stale = try contextDay(envelopes: [], consistent: false)
        XCTAssertEqual(PhysiologyContextStore.classify(stale), .stale(stale))
        XCTAssertEqual(MeasurementContextSummary.stale().statePhrase, "Context updating")
        XCTAssertNil(MeasurementContextSummary.stale().referenceText, "no difference is paired with stale context")
    }

    // MARK: - Wording: numbers and times

    func testSignedDifferencesKeepTheirOriginalUnits() {
        typealias W = PhysiologyContextWording
        XCTAssertEqual(W.signedDifference(6.2, units: "ms", locale: en), "+6 ms")
        XCTAssertEqual(W.signedDifference(-3.4, units: "bpm", locale: en), "\u{2212}3 bpm")
        XCTAssertEqual(W.signedDifference(0.3, units: "ms", locale: en), "\u{00B1}0 ms")
        XCTAssertEqual(W.signedDifference(-0.3, units: "bpm", locale: en), "\u{00B1}0 bpm")
        XCTAssertEqual(W.signedDifference(0.44, units: "breaths_per_min", locale: en), "+0.4 br/min")
        XCTAssertEqual(W.signedDifference(-0.123, units: "degC", locale: en), "\u{2212}0.12 °C")
        XCTAssertEqual(W.value(48.6, units: "ms", locale: en), "49 ms")
        XCTAssertEqual(W.referenceLine(reference(), units: "ms", locale: en), "+6 ms vs your 28-day reference")
        XCTAssertEqual(W.referenceLine(reference(view: .frozen, diff: -4), units: "ms", locale: en),
                       "\u{2212}4 ms vs your historical reference")
        XCTAssertEqual(W.referenceLine(reference(status: .insufficient, diff: nil), units: "ms", locale: en),
                       "Not enough comparable days for a reference yet")
    }

    func testSupportTimeIsShownInTheMeasurementsOwnZone() {
        typealias W = PhysiologyContextWording
        let w = dayWindow
        let night = envelope(nightly: true, support: PC.Interval(w.start - 50 * 60, w.start + 6 * 3600 + 42 * 60))
        XCTAssertEqual(W.supportLine(night, locale: gb), "Measured 23:10\u{2013}06:42")
        let window = envelope(support: PC.Interval(w.start + 14 * 3600 + 5 * 60, w.start + 14 * 3600 + 10 * 60))
        XCTAssertEqual(W.supportLine(window, locale: gb), "5-min window 14:05\u{2013}14:10")
        let hour = envelope(metric: .restingHeartRate, support: PC.Interval(w.start + 13 * 3600 + 600, w.start + 14 * 3600 + 600))
        XCTAssertEqual(W.supportLine(hour, locale: gb), "60-min window 13:10\u{2013}14:10")
        // The same instant in another zone reads differently: the envelope's zone wins over the phone's.
        let zone = W.zone(night.localTime.timezoneId)
        XCTAssertEqual(W.zoneLabel(zone, at: night.support.start), "PDT, UTC\u{2212}7")
        XCTAssertEqual(W.timeRange(window.support, zone: TimeZone(identifier: "Europe/Berlin")!, locale: gb),
                       "23:05\u{2013}23:10")
        XCTAssertEqual(W.duration(45), "45 s")
        XCTAssertEqual(W.duration(300), "5 min")
        XCTAssertEqual(W.duration(7 * 3600 + 32 * 60), "7 h 32 min")
    }

    func testFinalityAndEpisodeBadges() {
        typealias W = PhysiologyContextWording
        XCTAssertEqual(W.processingBadges(mode: .retrospective, finality: .provisional, unverified: false).map(\.text),
                       ["Provisional", "Revised"])
        XCTAssertEqual(W.processingBadges(mode: .causalLive, finality: .final, unverified: false).map(\.text), [])
        XCTAssertEqual(W.processingBadges(mode: .causalLive, finality: .provisional, unverified: true).map(\.text),
                       ["Provisional", "Unverified"])
        XCTAssertEqual(W.episodeBadges(episode(.persistentShift)).map(\.text), ["Ongoing", "Provisional"])
        XCTAssertEqual(W.episodeBadges(episode(.transientDeviation, ongoing: false, finality: .final)).map(\.text),
                       ["Transient", "Final"])
        XCTAssertEqual(W.episodeState(.persistentShift), "Persistent change from historical reference")
    }

    // MARK: - Card summary

    func testTheHeadlinePrefersTheNightlyValueThenTheLatestQualifyingWindow() {
        let w = dayWindow
        let nightly = envelope(nightly: true, support: PC.Interval(w.start - 3000, w.start + 24_000))
        let early = envelope(support: PC.Interval(w.start + 3600, w.start + 3900),
                             verdicts: [verdict(.stableAwakeRest, .eligible)])
        let late = envelope(support: PC.Interval(w.start + 7200, w.start + 7500),
                            verdicts: [verdict(.stableAwakeRest, .unknown)])
        let other = envelope(metric: .restingHeartRate, nightly: true, support: PC.Interval(w.start, w.start + 9000))
        typealias S = MeasurementContextSelection
        XCTAssertEqual(S.headline(in: [early, nightly, late, other], metric: .hrvRmssd)?.id, nightly.id)
        XCTAssertEqual(S.headline(in: [early, late, other], metric: .hrvRmssd)?.id, early.id)
        XCTAssertEqual(S.headline(in: [late, other], metric: .hrvRmssd)?.id, late.id)
        XCTAssertNil(S.headline(in: [other], metric: .hrvRmssd))
        XCTAssertEqual(S.selectedComparison(for: nightly), .sleepMeasurement)
        XCTAssertEqual(S.selectedComparison(for: early), .stableAwakeRest)
    }

    func testTheSummaryOfAStableAwakeWindow() throws {
        let w = dayWindow
        let support = PC.Interval(w.start + 14 * 3600 + 300, w.start + 14 * 3600 + 600)
        let e = envelope(support: support, labels: [("still", 276)], unknownS: 9, uncoveredS: 15,
                         verdicts: [verdict(.stableAwakeRest, .eligible)], comparisons: [reference()],
                         finality: .provisional)
        let day = try contextDay(envelopes: [e], episodes: [episode(.persistentShift)], finality: .provisional)
        let summary = MeasurementContextSummary.build(day: day, metric: .hrvRmssd, locale: gb)
        XCTAssertEqual(summary.envelopeId, e.id)
        XCTAssertEqual(summary.statePhrase, "Stable awake measurement")
        XCTAssertEqual(summary.supportText, "5-min window 14:05\u{2013}14:10")
        XCTAssertEqual(summary.eligibilityText, "Qualifies for the stable awake comparison")
        XCTAssertEqual(summary.coverageText, "Activity known for 92% \u{00B7} 8% unknown \u{00B7} signal 95%")
        XCTAssertEqual(summary.referenceText, "+6 ms vs your 28-day reference")
        XCTAssertEqual(summary.episodeText, "Persistent change from historical reference")
        XCTAssertEqual(summary.episodeBadges.map(\.text), ["Ongoing", "Provisional"])
        XCTAssertEqual(summary.badges.map(\.text), ["Provisional", "Revised"])
    }

    func testRecentWalkingAndInsufficientContextAreSaidPlainly() throws {
        let w = dayWindow
        let support = PC.Interval(w.start + 9 * 3600, w.start + 9 * 3600 + 300)
        let walking = envelope(support: support, labels: [("still", 200), ("walking", 100)],
                               verdicts: [verdict(.stableAwakeRest, .ineligible, ["walking_during_support"])])
        XCTAssertEqual(PhysiologyContextWording.statePhrase(walking), "Recent walking")
        let afterWalk = envelope(support: support, verdicts: [verdict(.stableAwakeRest, .ineligible)],
                                 sinceActivity: 240, lastActivity: "walking")
        XCTAssertEqual(PhysiologyContextWording.statePhrase(afterWalk), "Recent walking")
        let summary = MeasurementContextSummary.build(day: try contextDay(envelopes: [walking]), metric: .hrvRmssd, locale: gb)
        XCTAssertEqual(summary.eligibilityText,
                       "Does not qualify for the stable awake comparison: walking during the measurement")
        XCTAssertEqual(summary.referenceText, "No reference comparison for this measurement yet")

        let unknown = envelope(support: support, verdicts: [verdict(.stableAwakeRest, .unknown, ["awake_unknown"])])
        XCTAssertEqual(PhysiologyContextWording.statePhrase(unknown), "Insufficient context")
        XCTAssertEqual(PhysiologyContextWording.eligibilityLine(unknown.verdict(.stableAwakeRest), kind: .stableAwakeRest),
                       "Can't tell whether it qualifies for the stable awake comparison: it is unclear whether you were awake")

        let nothing = MeasurementContextSummary.build(day: try contextDay(envelopes: []), metric: .restingHeartRate)
        XCTAssertEqual(nothing.statePhrase, "Insufficient context")
        XCTAssertNil(nothing.envelopeId)
    }

    func testOnlyTheStrapsHRVAndRestingHeartRatePagesCarryTheCard() {
        XCTAssertEqual(MeasurementContextPage.metric(forCatalogKey: "hrv", source: "my-whoop"), .hrvRmssd)
        XCTAssertEqual(MeasurementContextPage.metric(forCatalogKey: "rhr", source: "my-whoop"), .restingHeartRate)
        XCTAssertNil(MeasurementContextPage.metric(forCatalogKey: "rhr", source: "xiaomi-band"))
        XCTAssertNil(MeasurementContextPage.metric(forCatalogKey: "resp_rate", source: "my-whoop"))
        XCTAssertTrue(MeasurementContextPage.belongs(seriesKey: "resting_hr.sleep_night", to: .restingHeartRate))
        XCTAssertFalse(MeasurementContextPage.belongs(seriesKey: "hrv_rmssd.sleep_night", to: .restingHeartRate))
    }

    // MARK: - Detail and history

    func testTheDetailShowsUnknownContextExposuresAndUnavailableInputs() throws {
        let w = dayWindow
        let e = envelope(support: PC.Interval(w.start + 9 * 3600, w.start + 9 * 3600 + 300),
                         labels: [("still", 240)], unknownS: 30, uncoveredS: 30,
                         verdicts: [verdict(.stableAwakeRest, .unknown, ["wear_unknown"]),
                                    verdict(.sleepMeasurement, .ineligible, ["not_in_sleep"])],
                         comparisons: [reference(), reference(view: .frozen, status: .insufficient, diff: nil)])
        let event = PC.ExposureEvent(eventId: "ev1", revision: 2, kind: .caffeine, label: "Espresso",
                                     occurred: PC.Interval(w.start + 8 * 3600, w.start + 8 * 3600 + 1),
                                     timePrecision: .exact, source: .userEntered, confirmation: .confirmed,
                                     doseAmount: 80, doseUnit: "mg", doseProvenance: "user_entered",
                                     availableAt: w.start + 8 * 3600 + 60, revisionCount: 2)
        let exposures = PC.ExposureDaySummary(events: [event], categoryStatus: [], revisionsNotYetAvailable: 0,
                                              reasons: [])
        let availability = [PC.AvailabilityEntry(metric: nil, assessment: "ppg_waveform_quality", source: "strap",
                                                 state: .unsupported, comparability: "none", reasons: []),
                            PC.AvailabilityEntry(metric: .spo2Candidate, assessment: "spo2_validity", source: "strap",
                                                 state: .unverified, comparability: "none", reasons: [])]
        let day = try contextDay(envelopes: [e], exposures: exposures, availability: availability)
        let model = MeasurementContextDetailModel.build(day: day, metric: .hrvRmssd, isStale: false, locale: gb)
        func row(_ section: String, _ id: String) -> ContextDetailRow? {
            model.sections.first { $0.id == section }?.rows.first { $0.id == id }
        }
        XCTAssertEqual(row("measurement", "time")?.value, "09:00\u{2013}09:05")
        XCTAssertEqual(row("measurement", "time")?.note, "PDT, UTC\u{2212}7")
        XCTAssertEqual(row("activity", "unknown")?.value, "10%")
        XCTAssertEqual(row("activity", "uncovered")?.value, "10%")
        XCTAssertEqual(row("eligibility", "eligibility-stable_awake_rest")?.value, "Can't tell")
        XCTAssertEqual(row("eligibility", "eligibility-sleep_measurement")?.note, "It was outside detected sleep")
        XCTAssertEqual(row("references", "reference-0")?.value, "+6 ms")
        XCTAssertEqual(row("references", "reference-1")?.value, "Not enough comparable days yet")
        XCTAssertEqual(row("exposures", "exposure-event-ev1")?.title, "Espresso")
        XCTAssertEqual(row("exposures", "exposure-status-alcohol")?.value, "Not recorded")
        XCTAssertEqual(row("availability", "availability-0")?.value, "Not supported")
        XCTAssertEqual(row("availability", "availability-1")?.title, "Blood oxygen (unverified): Blood oxygen")
        XCTAssertEqual(row("processing", "mode")?.value, "Revised with later data")
        XCTAssertEqual(model.exposureWindow, w)
        XCTAssertTrue(model.diagnostics.contains { $0.id == "d-policy" })
        XCTAssertNil(model.banner)

        let stale = MeasurementContextDetailModel.build(day: day, metric: .hrvRmssd, isStale: true, locale: gb)
        XCTAssertEqual(stale.title, "Context updating")
        XCTAssertNotNil(stale.banner)
    }

    func testHistorySplitsThisMetricsEpisodesAndDescribesBoutFollowUp() {
        let w = dayWindow
        let history = PhysiologyContextHistory(
            from: "2026-09-02", to: day, deviceId: "d", mode: nil,
            episodes: [episode(.persistentShift), episode(.transientDeviation, series: "resp_rate.sleep_night")],
            bouts: [PC.ExertionBout(id: "b1", interval: PC.Interval(w.start + 7 * 3600, w.start + 7 * 3600 + 1800),
                                    day: day, kind: "walking", status: .censored, durationS: 1800,
                                    reasons: ["continued_movement"]),
                    PC.ExertionBout(id: "b2", interval: PC.Interval(w.start + 18 * 3600, w.start + 18 * 3600 + 600),
                                    day: day, kind: "running", status: .ongoing, durationS: 600)],
            dailyValues: [], undecodedElements: 0, fetchedAtMs: 0)
        let model = PhysiologyContextHistoryModel.build(history, metric: .hrvRmssd, zone: TimeZone(identifier: tz)!,
                                                        locale: gb)
        XCTAssertEqual(model.metricEpisodes.map(\.title), ["HRV, stable awake measurements"])
        XCTAssertEqual(model.metricEpisodes.first?.state, "Persistent change from historical reference")
        XCTAssertEqual(model.metricEpisodes.first?.direction, "Below reference")
        XCTAssertEqual(model.otherEpisodes.map(\.title), ["Nightly respiratory rate"])
        XCTAssertEqual(model.bouts.map(\.id), ["b2", "b1"], "newest first")
        XCTAssertEqual(model.bouts.last?.status, "Follow-up incomplete: movement continued")
        XCTAssertEqual(model.bouts.first?.status, "Ongoing")
        XCTAssertEqual(model.bouts.last?.duration, "30 min")
    }

    // MARK: - Copy rules

    func testTheGuardFindsWholeWordsOnly() {
        typealias W = PhysiologyContextWording
        XCTAssertEqual(W.containsForbiddenTerm("You seem Stressed today"), "stressed")
        XCTAssertEqual(W.containsForbiddenTerm("fully recovered"), "recovered")
        XCTAssertEqual(W.containsForbiddenTerm("a calm reading"), "calm")
        XCTAssertNil(W.containsForbiddenTerm("Still beforehand"), "\"still\" is not \"ill\"")
        XCTAssertNil(W.containsForbiddenTerm("Stable awake measurement"))
        XCTAssertEqual(W.humanized("stress_detected"), "another reason", "a server code never smuggles in an inference")
        XCTAssertEqual(W.humanized("brand_new_code"), "brand new code")
    }

    func testNoScreenWordingInfersIllnessMedicationEffectsOrPsychologicalStates() throws {
        typealias W = PhysiologyContextWording
        var texts: [String] = MeasurementContextCopy.allFixedText + PhysiologyContextHistoryCopy.allFixedText
        let w = dayWindow
        let support = PC.Interval(w.start + 10 * 3600, w.start + 10 * 3600 + 300)

        // Every reason the app knows, the engine's and join's registries, and unknown codes.
        let codes: [String] = PC.Engine.reasonCodes.map(\.rawValue) + PC.IntervalAlgebra.reasonCodes.map(\.rawValue) + [
            "not_implemented", "regime_differs", "insufficient_stationary_share", "insufficient_coverage",
            "insufficient_preceding_stillness", "awake_unknown", "wear_unknown", "not_worn", "asleep", "not_in_sleep",
            "recent_exertion", "recent_walking", "walking_during_support", "signal_invalid", "signal_missing",
            "unverified", "no_bout", "insufficient_history", "disconnect", "continued_movement", "next_bout",
            "cutoff_reached", "no_follow_up", "stress_index_high", "recovered_fully", "illness_flag", "brand_new_code",
        ]
        texts += codes.map { W.reason(PC.ReasonCode($0)) }

        // Every state of every enum the screens describe.
        texts += PC.ValidityState.allCases.map(W.validity)
        texts += PC.SleepWakeState.allCases.map(W.sleepState)
        texts += PC.WearEvidenceState.allCases.map(W.wearState)
        texts += PC.EpisodeState.allCases.map(W.episodeState)
        texts += PC.ReferenceStatus.allCases.map(W.referenceStatus)
        texts += PC.ReferenceView.allCases.map(W.referenceTitle)
        texts += PC.ActivitySource.allCases.map(W.activitySource)
        texts += PC.ExposureKind.allCases.map(W.exposureKind)
        texts += PC.ExposureConfirmation.allCases.map(W.exposureConfirmation)
        texts += PC.TimePrecision.allCases.compactMap(W.timePrecision)
        texts += PC.AvailabilityState.allCases.map(W.availabilityState)
        texts += PC.MetricKind.allCases.map(W.metric)
        texts += PC.ProcessingMode.allCases.map(W.mode)
        texts += PC.Finality.allCases.map(W.finality)
        for kind in PC.ComparisonKind.allCases { texts += [W.comparison(kind), W.comparisonTitle(kind)] }
        texts += PC.EligibilityState.allCases.map(W.eligibilityState)
        let categoryStatuses = ["recorded", "denied", "candidate_only", "unrecorded"]
        texts += categoryStatuses.map(W.exposureCategoryStatus)
        let boutKinds = ["walking", "running", "stepping", "workout", "mixed_locomotion"]
        texts += boutKinds.map(W.boutKind)
        let seriesKeys = ["hrv_rmssd.sleep_night", "resting_hr.sleep_night", "resp_rate.sleep_night",
                          "skin_temp.sleep_night", "hrv_rmssd.stable_awake_5min", "heart_rate.stable_awake_5min",
                          "hr_response.walk", "functional.locomotion_s_per_worn_hour", "coverage.motion_observed_s"]
        texts += seriesKeys.map(W.series)
        let labels: Set<String> = PC.MotionVocabulary.stationary.union(PC.MotionVocabulary.locomotion)
            .union(PC.MotionVocabulary.otherMovement)
        texts += labels.map(W.activityLabel)
        let evidence = ["detected_sleep_session", "outside_detected_sleep", "band_sleep_state", "wear_events",
                        "heart_rate_signal_present"]
        texts += evidence.map(W.evidence)
        let assessments = ["ppg_waveform_quality", "spo2_validity", "core_temperature", "posture"]
        texts += assessments.map(W.assessment)

        // Cards, details and histories across eligibility, sleep, validity, reference and episode states.
        var envelopes: [PC.MeasurementEnvelope] = []
        for kind in PC.ComparisonKind.allCases {
            for state in PC.EligibilityState.allCases {
                for validity in PC.ValidityState.allCases {
                    texts.append(W.eligibilityLine(verdict(kind, state, ["insufficient_coverage"]), kind: kind))
                    envelopes.append(envelope(support: support, verdicts: [verdict(kind, state)], validity: validity))
                }
            }
        }
        for sleep in PC.SleepWakeState.allCases {
            envelopes.append(envelope(nightly: true, support: PC.Interval(w.start - 3000, w.start + 24_000),
                                      sleep: sleep, lastActivity: nil))
        }
        envelopes.append(envelope(support: support, labels: [("running", 300)], sinceActivity: 60, lastActivity: "running"))
        envelopes.append(envelope(support: support, labels: [("still", 200), ("walking", 100)]))
        for status in PC.ReferenceStatus.allCases {
            for view in PC.ReferenceView.allCases {
                texts.append(W.referenceLine(reference(view: view, status: status), units: "ms", locale: en))
                texts.append(W.referenceLine(reference(view: view, status: status, diff: nil), units: "bpm", locale: en))
            }
        }
        for e in envelopes {
            let day = try contextDay(envelopes: [e], episodes: PC.EpisodeState.allCases.map { episode($0) })
            for metric in [PC.MetricKind.hrvRmssd, .restingHeartRate] {
                texts += MeasurementContextSummary.build(day: day, metric: metric, locale: en).allText
                for stale in [false, true] {
                    texts += MeasurementContextDetailModel.build(day: day, metric: metric, isStale: stale,
                                                                 locale: en).allText
                }
            }
        }
        let bouts = PC.BoutStatus.allCases.flatMap { status in
            ["disconnect", "continued_movement", "next_bout", "cutoff_reached", "no_follow_up"].map {
                PC.ExertionBout(id: "\(status)-\($0)", interval: support, day: day, kind: "walking", status: status,
                                durationS: 300, reasons: [PC.ReasonCode($0)])
            }
        }
        let history = PhysiologyContextHistory(from: "2026-09-02", to: day, deviceId: "d", mode: nil,
                                               episodes: PC.EpisodeState.allCases.map { episode($0) },
                                               bouts: bouts, dailyValues: [], undecodedElements: 0, fetchedAtMs: 0)
        texts += PhysiologyContextHistoryModel.build(history, metric: .hrvRmssd, zone: .current, locale: en).allText
        texts += MeasurementContextSummary.stale().allText

        XCTAssertGreaterThan(texts.count, 500)
        for text in texts {
            if let term = W.containsForbiddenTerm(text) {
                XCTFail("\"\(text)\" uses the forbidden term \"\(term)\"")
            }
        }
        // The required wording is actually used.
        let joined = texts.joined(separator: "\n")
        for required in ["Stable awake measurement", "Recent walking", "Insufficient context",
                         "Persistent change from historical reference", "Provisional", "Unverified"] {
            XCTAssertTrue(joined.contains(required), "missing \"\(required)\"")
        }
    }
}

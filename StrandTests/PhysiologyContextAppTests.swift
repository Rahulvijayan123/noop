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
                          lastActivity: String? = nil, finality: PC.Finality = .final,
                          decoder: PC.ActivityComposition? = nil,
                          exposureCoverage: [PC.ExposureCategoryStatus]? = nil) -> PC.MeasurementEnvelope {
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
            regimeKey: "r1", activity: comp, decoderActivity: decoder,
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
                exposureCoverage: exposureCoverage
                    ?? [PC.ExposureCategoryStatus(kind: .caffeine, status: "recorded"),
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
                         series: String = "hrv_rmssd.stable_awake_5min", detector: String = "",
                         reasons: [PC.ReasonCode] = ["insufficient_history"]) -> PC.ChangeEpisode {
        PC.ChangeEpisode(id: "ep-\(state.rawValue)-\(series)-\(detector)", seriesKey: series, regimeKey: "r1",
                         state: state, direction: -1, startDay: "2026-09-24", lastDay: day, ongoing: ongoing,
                         durationDays: 8, finality: finality, reasons: reasons, detector: detector)
    }

    /// A day value carrying `envelopes` (and `episodes`) in an otherwise engine-built document.
    private func contextDay(envelopes: [PC.MeasurementEnvelope], episodes: [PC.ChangeEpisode] = [],
                            mode: PC.ProcessingMode = .retrospective, finality: PC.Finality = .final,
                            consistent: Bool? = true, exposures: PC.ExposureDaySummary? = nil,
                            availability: [PC.AvailabilityEntry] = [],
                            comparisons: [PC.ReferenceComparison]? = nil) throws -> PhysiologyContextDay {
        var doc = builtDocument()
        doc.envelopes = envelopes
        doc.episodes = episodes
        if let comparisons { doc.comparisons = comparisons }
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

    func testTheStoredFormSummaryPlusEnvelopeTablesRebuildsTheDocument() async throws {
        let doc = builtDocument()
        let (summary, tables) = PC.StoredDocument.split(doc)
        XCTAssertTrue(summary.envelopes.isEmpty)
        var body = contextBody(document: try jsonObject(summary))
        var context = try XCTUnwrap(body["context"] as? [String: Any])
        context["envelope_tables"] = try tables.map { try JSONSerialization.jsonObject(with: PC.encoder().encode($0)) }
        body["context"] = context
        ContextStub.body = body
        let read = try await repository().dayContext(day: day, deviceIds: ["whoop-TEST"], metric: .hrvRmssd)
        guard case .loaded(let value) = read else { return XCTFail("expected a context, got \(read)") }
        XCTAssertEqual(value.document?.full, doc, "summary + every table rebuilds the engine's document")
        XCTAssertEqual(value.document?.envelopes, doc.envelopes)
        XCTAssertEqual(value.document?.undecodedElements, 0)

        // A summary with only some tables keeps those envelopes and nothing else.
        context["envelope_tables"] = try tables.filter { $0.metric == .heartRate }
            .map { try JSONSerialization.jsonObject(with: PC.encoder().encode($0)) }
        body["context"] = context
        ContextStub.body = body
        let partial = try await repository().dayContext(day: day, deviceIds: ["whoop-TEST"], metric: .heartRate)
        guard case .loaded(let p) = partial else { return XCTFail("expected a context") }
        XCTAssertEqual(p.document?.envelopes, doc.envelopes.filter { $0.metric == .heartRate })
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
        ContextStub.status = 502
        await s.load(key)
        XCTAssertEqual(s.state(for: key), .unavailable(.noData), "a failed re-read keeps the server's last answer")
        ContextStub.status = 200

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
        // RC-19: the state alone never claims a historical reference.
        XCTAssertEqual(W.episodeState(.persistentShift), "Persistent change from your recent usual range")
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
        let day = try contextDay(envelopes: [e], episodes: [episode(.persistentShift, detector: "frozen_persistence")],
                                 finality: .provisional)
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
                               verdicts: [verdict(.stableAwakeRest, .ineligible, ["movement_in_support"])])
        XCTAssertEqual(PhysiologyContextWording.statePhrase(walking), "Recent walking")
        let afterWalk = envelope(support: support, verdicts: [verdict(.stableAwakeRest, .ineligible)],
                                 sinceActivity: 240, lastActivity: "walking")
        XCTAssertEqual(PhysiologyContextWording.statePhrase(afterWalk), "Recent walking")
        let summary = MeasurementContextSummary.build(day: try contextDay(envelopes: [walking]), metric: .hrvRmssd, locale: gb)
        XCTAssertEqual(summary.eligibilityText,
                       "Does not qualify for the stable awake comparison: movement during the measurement")
        XCTAssertEqual(summary.referenceText, "No reference comparison for this measurement yet")

        let unknown = envelope(support: support,
                               verdicts: [verdict(.stableAwakeRest, .unknown, ["awake_evidence_unknown"])])
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
                         verdicts: [verdict(.stableAwakeRest, .unknown, ["wear_evidence_unknown"]),
                                    verdict(.sleepMeasurement, .ineligible, ["not_asleep"])],
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
        XCTAssertEqual(row("eligibility", "eligibility-sleep_measurement")?.note, "It was not during sleep")
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
            episodes: [episode(.persistentShift, reasons: ["frozen_and_rolling_agree"]),
                       episode(.transientDeviation, series: "resp_rate.sleep_night")],
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

    // MARK: - Review repairs (review-contract RC-05/06/14/16/19/22, review-statistics P6)

    private func bout(_ id: String, status: PC.BoutStatus, reasons: [PC.ReasonCode],
                      censoring: [PC.ReasonCode]?) -> PC.ExertionBout {
        let w = dayWindow
        let interval = PC.Interval(w.start + 7 * 3600, w.start + 7 * 3600 + 1800)
        var b = PC.ExertionBout(id: id, interval: interval, day: day, kind: "walking", status: status,
                                durationS: 1800, reasons: reasons)
        if let censoring {
            let none = PC.BoutChannel(channel: "hrv", state: .unsupported, reasons: [])
            b.recovery = PC.BoutRecovery(followUp: PC.Interval(interval.end, interval.end + 300), anchorHrBpm: 120,
                                         referenceBpm: 80, observations: [], truncatedAt: interval.end + 90,
                                         censoring: censoring, timeToReturnS: nil, hrv: none, respiratory: none,
                                         reasons: [])
        }
        return b
    }

    /// RC-06: the follow-up line names what cut the follow-up short, not the alphabetically first reason.
    func testACensoredBoutNamesItsCensoringCause() {
        typealias W = PhysiologyContextWording
        // The engine sorts a bout's reasons, so "ended_at_evidence_gap" comes before the censoring code.
        let nextBout = bout("b1", status: .censored, reasons: ["ended_at_evidence_gap", "next_bout"],
                            censoring: ["next_bout", "disconnect"])
        XCTAssertEqual(W.boutStatus(nextBout), "Follow-up incomplete: another bout started")
        // An older document without the recovery: the censoring code among the reasons.
        let noRecovery = bout("b2", status: .censored, reasons: ["ended_at_evidence_gap", "next_bout"], censoring: nil)
        XCTAssertEqual(W.boutStatus(noRecovery), "Follow-up incomplete: another bout started")
        // Nothing truncated it, but the readings were too sparse.
        let sparse = bout("b3", status: .censored,
                          reasons: ["ended_at_evidence_gap", "insufficient_follow_up_samples"], censoring: [])
        XCTAssertEqual(W.boutStatus(sparse), "Follow-up incomplete: too little data afterwards")
        let unexplained = bout("b4", status: .censored, reasons: ["ended_at_evidence_gap"], censoring: [])
        XCTAssertEqual(W.boutStatus(unexplained), "Follow-up incomplete")
        let history = PhysiologyContextHistory(from: "2026-09-02", to: day, deviceId: "d", mode: nil, episodes: [],
                                               bouts: [nextBout], dailyValues: [], undecodedElements: 0,
                                               fetchedAtMs: 0)
        let model = PhysiologyContextHistoryModel.build(history, metric: .hrvRmssd, zone: TimeZone(identifier: tz)!,
                                                        locale: gb)
        XCTAssertEqual(model.bouts.first?.status, "Follow-up incomplete: another bout started")
    }

    /// RC-14: one "no" that covers a third of the window is not "none" for the whole window.
    func testAPartialDenialIsNotNoneForTheWholePeriod() throws {
        typealias W = PhysiologyContextWording
        let w = dayWindow
        let e = envelope(support: PC.Interval(w.start + 9 * 3600, w.start + 9 * 3600 + 300),
                         verdicts: [verdict(.stableAwakeRest, .eligible)],
                         exposureCoverage: [PC.ExposureCategoryStatus(kind: .caffeine, status: "denied",
                                                                      deniedCoverage: 1.0 / 3.0),
                                            PC.ExposureCategoryStatus(kind: .alcohol, status: "denied",
                                                                      deniedCoverage: 1.0),
                                            PC.ExposureCategoryStatus(kind: .meal, status: "denied",
                                                                      deniedCoverage: 0.999),
                                            PC.ExposureCategoryStatus(kind: .heat, status: "unrecorded")])
        let model = MeasurementContextDetailModel.build(day: try contextDay(envelopes: [e]), metric: .hrvRmssd,
                                                        isStale: false, locale: gb)
        func row(_ id: String) -> ContextDetailRow? {
            model.sections.first { $0.id == "exposures" }?.rows.first { $0.id == id }
        }
        XCTAssertEqual(row("exposure-status-caffeine")?.value, "Recorded as none for part of this period")
        XCTAssertEqual(row("exposure-status-caffeine")?.note, "33% of this period; the rest is not recorded")
        XCTAssertEqual(row("exposure-status-alcohol")?.value, "Recorded as none")
        XCTAssertNil(row("exposure-status-alcohol")?.note)
        XCTAssertEqual(row("exposure-status-meal")?.value, "Recorded as none for part of this period")
        XCTAssertEqual(row("exposure-status-meal")?.note, "99% of this period; the rest is not recorded",
                       "a near-complete denial never rounds up to the whole period")
        XCTAssertEqual(row("exposure-status-heat")?.value, "Not recorded")
        XCTAssertTrue(model.sections.first { $0.id == "exposures" }?.footnote?
            .contains("Recording status covers the days before this measurement.") ?? false)
        // A denial whose coverage was not reported is not claimed for the whole period either.
        XCTAssertEqual(W.exposureCategoryStatus(PC.ExposureCategoryStatus(kind: .caffeine, status: "denied")),
                       "Recorded as none for part of this period")
    }

    /// RC-16: a 5-minute window that fed today's stable-awake median carries no comparison of its own. The card
    /// may show the day's comparison, but only as the median's.
    func testAWindowShowsTodaysMedianComparisonOnlyAsTheMedians() throws {
        let w = dayWindow
        let window = envelope(support: PC.Interval(w.start + 14 * 3600 + 300, w.start + 14 * 3600 + 600),
                              verdicts: [verdict(.stableAwakeRest, .eligible)], comparisons: [])
        let median = reference(series: "hrv_rmssd.stable_awake_5min")
        let band = reference(diff: 11, series: "hrv_rmssd.stable_awake_5min.band_12_18")
        let nightlySeries = reference(diff: -9, series: "hrv_rmssd.sleep_night")
        let day = try contextDay(envelopes: [window], episodes: [episode(.transientDeviation)],
                                 comparisons: [nightlySeries, band, median])
        let summary = MeasurementContextSummary.build(day: day, metric: .hrvRmssd, locale: gb)
        XCTAssertEqual(summary.referenceText, "Today's stable awake median: +6 ms vs your 28-day reference")
        XCTAssertEqual(summary.episodeText, "Transient deviation from reference")

        let detail = MeasurementContextDetailModel.build(day: day, metric: .hrvRmssd, isStale: false, locale: gb)
        let rows = detail.sections.first { $0.id == "references" }?.rows ?? []
        XCTAssertEqual(rows.map(\.id), ["day-reference-0"])
        XCTAssertEqual(rows.first?.value, "+6 ms")
        XCTAssertTrue(rows.first?.note?.hasPrefix("Today's stable awake median, not this window alone") ?? false)

        // Without a day comparison nothing is borrowed; a window's own comparison is its own.
        let alone = try contextDay(envelopes: [window], comparisons: [nightlySeries, band])
        XCTAssertEqual(MeasurementContextSummary.build(day: alone, metric: .hrvRmssd, locale: gb).referenceText,
                       "No reference comparison for this measurement yet")
        let single = envelope(support: window.support, verdicts: [verdict(.stableAwakeRest, .eligible)],
                              comparisons: [reference(diff: 3)])
        let own = try contextDay(envelopes: [single], comparisons: [median])
        XCTAssertEqual(MeasurementContextSummary.build(day: own, metric: .hrvRmssd, locale: gb).referenceText,
                       "+3 ms vs your 28-day reference")
        // A nightly value never takes the stable-awake comparison.
        let nightly = envelope(nightly: true, support: PC.Interval(w.start - 3000, w.start + 24_000))
        XCTAssertTrue(MeasurementContextSelection.dayStableAwakeComparisons(for: nightly, in: [median]).isEmpty)
        let status = PhysiologyContextWording.stableAwakeMedianLine(reference(status: .insufficient, diff: nil),
                                                                    units: "ms", locale: gb)
        XCTAssertEqual(status, "Today's stable awake median: not enough comparable days for a reference yet")
    }

    /// RC-19: "historical reference" only when the frozen reference found or confirmed the shift.
    func testPersistentChangeNamesTheReferenceItWasDetectedAgainst() throws {
        typealias W = PhysiologyContextWording
        let historical = "Persistent change from historical reference"
        let recent = "Persistent change from your recent usual range"
        XCTAssertEqual(W.episodeState(episode(.persistentShift, detector: "frozen_persistence",
                                              reasons: ["frozen_reference_deviation", "gradual_drift"])), historical)
        XCTAssertEqual(W.episodeState(episode(.persistentShift, detector: "cusum",
                                              reasons: ["detector_cusum", "frozen_and_rolling_agree"])), historical)
        XCTAssertEqual(W.episodeState(episode(.persistentShift, detector: "cusum",
                                              reasons: ["detector_cusum", "rolling_adapted_frozen_deviation_persists"])),
                       historical)
        XCTAssertEqual(W.episodeState(episode(.persistentShift, detector: "cusum",
                                              reasons: ["detector_cusum", "frozen_unavailable"])), recent)
        XCTAssertEqual(W.episodeState(episode(.persistentShift, detector: "persistence",
                                              reasons: ["detector_persistence", "frozen_and_rolling_disagree"])), recent)
        XCTAssertEqual(W.episodeState(episode(.transientDeviation, detector: "frozen_persistence")),
                       "Transient deviation from reference")

        let w = dayWindow
        let e = envelope(support: PC.Interval(w.start + 14 * 3600, w.start + 14 * 3600 + 300),
                         verdicts: [verdict(.stableAwakeRest, .eligible)], comparisons: [reference()])
        let rolling = episode(.persistentShift, detector: "cusum", reasons: ["detector_cusum", "frozen_unavailable"])
        let summary = MeasurementContextSummary.build(day: try contextDay(envelopes: [e], episodes: [rolling]),
                                                      metric: .hrvRmssd, locale: gb)
        XCTAssertEqual(summary.episodeText, recent)
        let history = PhysiologyContextHistory(from: "2026-09-02", to: day, deviceId: "d", mode: nil,
                                               episodes: [rolling], bouts: [], dailyValues: [], undecodedElements: 0,
                                               fetchedAtMs: 0)
        let model = PhysiologyContextHistoryModel.build(history, metric: .hrvRmssd, zone: TimeZone(identifier: tz)!,
                                                        locale: gb)
        XCTAssertEqual(model.metricEpisodes.first?.state, recent)
        XCTAssertEqual(model.metricEpisodes.first?.reasons, "No historical reference yet",
                       "the detector's name stays in diagnostics")
    }

    /// P6: the reference centre's ± is an approximation and says so.
    func testTheReferenceUncertaintyIsMarkedApproximate() throws {
        typealias W = PhysiologyContextWording
        XCTAssertEqual(W.referenceCenter(reference(), units: "ms", locale: gb), "Reference 52 ms \u{00B1} 2 ms (approx.)")
        var noSpread = reference()
        noSpread.centerUncertainty = nil
        XCTAssertEqual(W.referenceCenter(noSpread, units: "ms", locale: gb), "Reference 52 ms")
        let w = dayWindow
        let e = envelope(support: PC.Interval(w.start + 14 * 3600, w.start + 14 * 3600 + 300),
                         verdicts: [verdict(.stableAwakeRest, .eligible)], comparisons: [reference()])
        let model = MeasurementContextDetailModel.build(day: try contextDay(envelopes: [e]), metric: .hrvRmssd,
                                                        isStale: false, locale: gb)
        let note = model.sections.first { $0.id == "references" }?.rows.first?.note ?? ""
        XCTAssertTrue(note.contains("Reference 52 ms \u{00B1} 2 ms (approx.)"), note)
    }

    /// RC-22: posture classes are likelihoods, never confirmed posture.
    func testDecoderPostureIsShownAsALikelihood() throws {
        typealias W = PhysiologyContextWording
        XCTAssertEqual(W.activityLabel("standing"), "Likely standing")
        XCTAssertEqual(W.activityLabel("sitting_desk"), "Likely sitting")
        XCTAssertEqual(W.activityLabel("lying_down"), "Likely lying down")
        XCTAssertEqual(W.likelyActivity("standing"), "Likely standing")
        XCTAssertEqual(W.likelyActivity("walking"), "Likely walking")
        let w = dayWindow
        let support = PC.Interval(w.start + 14 * 3600, w.start + 14 * 3600 + 300)
        var decoder = composition(support, labels: [("standing", 300)], source: .decoderIntervals)
        decoder.heartRateDependent = true
        let e = envelope(support: support, verdicts: [verdict(.stableAwakeRest, .eligible)], decoder: decoder)
        let availability = [PC.AvailabilityEntry(metric: nil, assessment: "posture", source: "strap_gravity_orientation",
                                                 state: .unverified, comparability: "not_applicable",
                                                 reasons: ["wrist_orientation_likelihood_only"])]
        let model = MeasurementContextDetailModel.build(day: try contextDay(envelopes: [e], availability: availability),
                                                        metric: .hrvRmssd, isStale: false, locale: gb)
        let decoderRow = model.sections.first { $0.id == "activity" }?.rows.first { $0.id == "decoder" }
        XCTAssertEqual(decoderRow?.value, "Likely standing")
        XCTAssertTrue(decoderRow?.note?.contains("not a confirmed one") ?? false)
        let posture = model.sections.first { $0.id == "availability" }?.rows.first
        XCTAssertEqual(posture?.title, "Posture (likelihood only)")
        XCTAssertEqual(posture?.note, "Arm orientation gives only a likely posture, never a confirmed one")
        for text in model.allText {
            XCTAssertNil(text.range(of: #"^(Standing|Sitting|Lying down)$"#, options: .regularExpression),
                         "\"\(text)\" presents a posture as confirmed")
        }
    }

    /// RC-15 (normal flow): diagnostics-only codes never reach the card, detail or history; Diagnostics keeps them
    /// raw. The card leads with the first shown reason (the engine lists deciding reasons first, RC-05).
    func testDiagnosticsOnlyCodesStayInDiagnostics() throws {
        typealias W = PhysiologyContextWording
        XCTAssertEqual(W.reasonList(["overlapping_records_resolved", "uncovered_time"]), "Part of it has no activity data")
        XCTAssertNil(W.reasonList(["detector_cusum", "log_transform"]))
        XCTAssertNil(W.topReason(["winsorized_mean_estimator"]))
        XCTAssertEqual(W.eligibilityLine(verdict(.stableAwakeRest, .ineligible,
                                                 ["movement_in_support", "signal_degraded"]), kind: .stableAwakeRest),
                       "Does not qualify for the stable awake comparison: movement during the measurement")
        XCTAssertEqual(W.eligibilityLine(verdict(.stableAwakeRest, .unknown, ["signal_degraded"]), kind: .stableAwakeRest),
                       "Can't tell whether it qualifies for the stable awake comparison: the signal is usable with limitations")

        let diagnosticsOnly = PhysiologyContextReasonRegistries.codes.filter {
            W.isDiagnosticsOnly(PC.ReasonCode($0))
        }.sorted().map { PC.ReasonCode($0) }
        XCTAssertFalse(diagnosticsOnly.isEmpty)
        let w = dayWindow
        var e = envelope(support: PC.Interval(w.start + 14 * 3600, w.start + 14 * 3600 + 300),
                         verdicts: [verdict(.stableAwakeRest, .ineligible, diagnosticsOnly + ["movement_in_support"]),
                                    verdict(.sleepMeasurement, .unknown, diagnosticsOnly)],
                         comparisons: [reference()])
        e.validity.reasons = diagnosticsOnly
        e.activity.reasons = diagnosticsOnly
        e.sleepWear.reasons = diagnosticsOnly
        e.comparisons[0].reasons = diagnosticsOnly
        let day = try contextDay(envelopes: [e], episodes: [episode(.persistentShift, detector: "cusum",
                                                                    reasons: diagnosticsOnly)])
        let card = MeasurementContextSummary.build(day: day, metric: .hrvRmssd, locale: gb)
        XCTAssertEqual(card.eligibilityText,
                       "Does not qualify for the stable awake comparison: movement during the measurement")
        let detail = MeasurementContextDetailModel.build(day: day, metric: .hrvRmssd, isStale: false, locale: gb)
        let history = PhysiologyContextHistoryModel.build(
            PhysiologyContextHistory(from: "2026-09-02", to: self.day, deviceId: "d", mode: nil,
                                     episodes: day.document?.episodes ?? [], bouts: [], dailyValues: [],
                                     undecodedElements: 0, fetchedAtMs: 0),
            metric: .hrvRmssd, zone: TimeZone(identifier: tz)!, locale: gb)
        let shown = (card.allText + detail.allText + history.allText).joined(separator: "\n").lowercased()
        for code in diagnosticsOnly {
            XCTAssertFalse(shown.contains(W.humanized(code.rawValue)), "\(code) reached the normal flow")
            XCTAssertFalse(shown.contains(code.rawValue), "\(code) reached the normal flow raw")
        }
        let raw = detail.diagnostics.first { $0.id == "d-codes" }?.value ?? ""
        for code in diagnosticsOnly { XCTAssertTrue(raw.contains(code.rawValue), "\(code) missing from Diagnostics") }
    }

    // MARK: - Integration review repairs (R8, R9, R11)

    /// R9: a new edge function without its migration answers 404 (the read RPC does not exist). That is the same
    /// "not available from the server" state as an old server's 405, never an error, and it is server-wide.
    @MainActor
    func testAMissingContextMigrationsFourOhFourIsUnsupportedNotAnError() async throws {
        ContextStub.status = 404
        ContextStub.body = ["error": "request_rejected"]
        let repo = repository()
        let day = try await repo.dayContext(day: self.day, deviceIds: ["whoop-A", "my-whoop"])
        XCTAssertEqual(day, .unsupportedServer)
        XCTAssertEqual(ContextStub.requestCount, 1, "a 404 is server-wide: the other candidates are not asked")
        let history = try await repo.history(from: "2026-09-02", to: self.day, deviceIds: ["whoop-A"])
        XCTAssertEqual(history, .unsupportedServer)

        let s = store(repository: repo)
        let key = PhysiologyContextStore.Key(day: self.day, metric: .hrvRmssd)
        await s.load(key)
        XCTAssertEqual(s.state(for: key), .unavailable(.unsupportedServer))
        let range = PhysiologyContextStore.HistoryKey(from: "2026-09-02", to: self.day)
        await s.loadHistory(range)
        XCTAssertEqual(s.historyState(for: range), .unavailable(.unsupportedServer))
    }

    /// R8: a dead-lettered job is decoded, and its day reads "Context unavailable for this day", never "on its
    /// way"; it is not polled.
    @MainActor
    func testADeadLetteredJobIsUnavailableNotOnItsWay() async throws {
        let doc = try jsonObject(builtDocument())
        func body(_ status: String, document: Any?, consistent: Bool?) -> [String: Any] {
            var b = contextBody(document: document, status: status, consistent: consistent)
            var context = b["context"] as? [String: Any] ?? [:]
            context["job"] = ["pending": false, "dirty_at": "2026-10-02T03:00:00Z", "dead_letter": true,
                              "leased": false, "input_revision": 5, "completed_revision": 4,
                              "reasons": ["worker_failed"]]
            b["context"] = context
            return b
        }
        let repo = repository()
        ContextStub.body = body("available", document: doc, consistent: false)
        guard case .loaded(let stale) = try await repo.dayContext(day: self.day, deviceId: "whoop-A") else {
            return XCTFail("expected a loaded day")
        }
        XCTAssertEqual(stale.job, PhysiologyContextDay.Job(pending: false, dirtyAt: "2026-10-02T03:00:00Z",
                                                           deadLetter: true, leased: false, inputRevision: "5",
                                                           completedRevision: "4", reasons: ["worker_failed"]))
        XCTAssertEqual(PhysiologyContextStore.classify(stale), .unavailable(.processingFailed),
                       "an earlier result's context whose update was given up is not \"on its way\"")
        XCTAssertFalse(PhysiologyContextStore.State.unavailable(.processingFailed).wantsPolling)
        XCTAssertEqual(MeasurementContextCopy.unavailable(.processingFailed), "Context unavailable for this day.")

        ContextStub.body = body("none", document: nil, consistent: nil)
        guard case .loaded(let none) = try await repo.dayContext(day: self.day, deviceId: "whoop-A") else {
            return XCTFail("expected a loaded day")
        }
        XCTAssertEqual(PhysiologyContextStore.classify(none), .unavailable(.processingFailed))

        // A current context stays current; the detail says the latest data could not be added.
        ContextStub.body = body("available", document: doc, consistent: true)
        guard case .loaded(let current) = try await repo.dayContext(day: self.day, deviceId: "whoop-A") else {
            return XCTFail("expected a loaded day")
        }
        guard case .available = PhysiologyContextStore.classify(current) else { return XCTFail("expected available") }
        let detail = MeasurementContextDetailModel.build(day: current, metric: .hrvRmssd, isStale: false, locale: gb)
        XCTAssertEqual(detail.sections.first { $0.id == "processing" }?.rows.first { $0.id == "job" }?.value,
                       "Couldn't be updated with the latest data")
        XCTAssertEqual(detail.diagnostics.first { $0.id == "d-job" }?.value, "dead_letter")

        let s = store(repository: repo)
        s.setReadCandidates(["whoop-A"])
        let key = PhysiologyContextStore.Key(day: self.day, metric: .hrvRmssd)
        ContextStub.body = body("available", document: doc, consistent: false)
        await s.load(key)
        XCTAssertEqual(s.state(for: key), .unavailable(.processingFailed))
        ContextStub.status = 503
        await s.load(key)
        XCTAssertEqual(s.state(for: key), .unavailable(.processingFailed), "a failed re-read keeps the server's answer")
    }

    /// R8: the card re-reads on a bounded backoff long enough to see the server's next attempt (it waits at
    /// least 10 minutes before re-queueing), and afterwards says to check back later instead of "on its way".
    func testPollingCoversTheServersCadenceAndThenSaysCheckBackLater() {
        let delays = PhysiologyContextStore.pollDelaysS
        let total = delays.reduce(0, +)
        XCTAssertGreaterThanOrEqual(total, 15 * 60 - 60, "covers about 15 minutes")
        XCTAssertLessThanOrEqual(total, 20 * 60, "bounded")
        XCTAssertLessThanOrEqual(delays.first ?? .max, 30, "the first re-read comes soon")
        XCTAssertEqual(delays, delays.sorted(), "a backoff never shortens")
        XCTAssertLessThanOrEqual(delays.count, 12)

        XCTAssertEqual(MeasurementContextSummary.stale().note,
                       "This day's results changed after its context was built. Updated context is on its way.")
        let late = MeasurementContextSummary.stale(checkBackLater: true)
        XCTAssertEqual(late.statePhrase, "Context updating")
        XCTAssertEqual(late.note, "This day's results changed after its context was built. The update is taking longer than usual. Check back later.")
        XCTAssertEqual(MeasurementContextCopy.pending(.computing, checkBackLater: true),
                       "Measurement context for this day is being prepared. Check back later.")
        XCTAssertEqual(MeasurementContextCopy.pending(.computing), "Measurement context for this day is being prepared.")
    }

    /// R11: "Local day" is the day that owns the document (a night belongs to the day it ends on), not the date
    /// the night started; the start and end dates are shown separately.
    func testTheDetailsLocalDayIsTheDayThatOwnsTheDocument() throws {
        typealias W = PhysiologyContextWording
        let w = dayWindow
        let night = envelope(nightly: true, support: PC.Interval(w.start - 50 * 60, w.start + 6 * 3600 + 42 * 60),
                             verdicts: [verdict(.sleepMeasurement, .eligible)])
        XCTAssertEqual(night.localTime.localDay, "2026-09-30", "the night starts the evening before")
        let model = MeasurementContextDetailModel.build(day: try contextDay(envelopes: [night]), metric: .hrvRmssd,
                                                        isStale: false, locale: gb)
        let row = model.sections.first { $0.id == "measurement" }?.rows.first { $0.id == "day" }
        XCTAssertEqual(row?.value, W.day(day, locale: gb))
        XCTAssertNotEqual(row?.value, W.day("2026-09-30", locale: gb))
        let zone = TimeZone(identifier: tz)!
        XCTAssertEqual(row?.note, "From \(W.dayAndTime(night.support.start, zone: zone, locale: gb)) to \(W.dayAndTime(night.support.end, zone: zone, locale: gb))")
        // A window inside one date needs no dates.
        let window = envelope(support: PC.Interval(w.start + 9 * 3600, w.start + 9 * 3600 + 300))
        let windowModel = MeasurementContextDetailModel.build(day: try contextDay(envelopes: [window]),
                                                              metric: .hrvRmssd, isStale: false, locale: gb)
        let windowRow = windowModel.sections.first { $0.id == "measurement" }?.rows.first { $0.id == "day" }
        XCTAssertEqual(windowRow?.value, W.day(day, locale: gb))
        XCTAssertNil(windowRow?.note)
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

        // Every code of every registry, plus unknown codes a newer server might send.
        let codes: [String] = PhysiologyContextReasonRegistries.codes.sorted()
            + ["stress_index_high", "recovered_fully", "illness_flag", "brand_new_code"]
        texts += codes.map { W.reason(PC.ReasonCode($0)) }
        texts += codes.compactMap { W.reasonList([PC.ReasonCode($0)]) }

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
        for coverage in [nil, 0.0, 0.33, 0.999, 1.0] as [Double?] {
            let status = PC.ExposureCategoryStatus(kind: .caffeine, status: "denied", deniedCoverage: coverage)
            texts.append(W.exposureCategoryStatus(status))
            texts += [W.exposureCategoryNote(status, locale: en)].compactMap { $0 }
        }
        let boutKinds = ["walking", "running", "stepping", "workout", "mixed_locomotion"]
        texts += boutKinds.map(W.boutKind)
        let seriesKeys = ["hrv_rmssd.sleep_night", "resting_hr.sleep_night", "resp_rate.sleep_night",
                          "skin_temp.sleep_night", "hrv_rmssd.stable_awake_5min", "heart_rate.stable_awake_5min",
                          "hr_response.walk", "functional.locomotion_s_per_worn_hour", "coverage.motion_observed_s"]
        texts += seriesKeys.map(W.series)
        let labels: Set<String> = PC.MotionVocabulary.stationary.union(PC.MotionVocabulary.locomotion)
            .union(PC.MotionVocabulary.otherMovement)
        texts += labels.map(W.activityLabel)
        texts += labels.map(W.likelyActivity)
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
                texts.append(W.stableAwakeMedianLine(reference(view: view, status: status), units: "ms", locale: en))
                texts.append(W.stableAwakeMedianLine(reference(view: view, status: status, diff: nil), units: "bpm",
                                                     locale: en))
            }
        }
        texts += [W.referenceCenter(reference(), units: "ms", locale: en)].compactMap { $0 }
        // A window with no comparison of its own, on a day whose stable-awake median has one.
        envelopes.append(envelope(support: support, verdicts: [verdict(.stableAwakeRest, .eligible)]))
        let episodes = PC.EpisodeState.allCases.map { episode($0) }
            + [episode(.persistentShift, detector: "frozen_persistence", reasons: ["frozen_reference_deviation"]),
               episode(.persistentShift, detector: "cusum", reasons: ["detector_cusum", "frozen_unavailable"])]
        for e in envelopes {
            let day = try contextDay(envelopes: [e], episodes: episodes,
                                     comparisons: PC.ReferenceStatus.allCases.map { reference(status: $0) })
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
                                               episodes: episodes,
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

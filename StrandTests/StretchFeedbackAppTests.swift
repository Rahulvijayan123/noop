import XCTest
import StrandAnalytics
@testable import Strand

/// Verdicts on stretches of the day, on the phone: the local store, the upload to the `scores` function, and the
/// day-state cache behind the "Through the day" list.
final class StretchFeedbackAppTests: XCTestCase {

    // MARK: Fixtures

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("stretch-feedback-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        StretchFeedbackStub.reset()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func makeStore() -> StretchFeedbackStore {
        StretchFeedbackStore(fileURL: tempDir.appendingPathComponent("stretch-feedback.json"))
    }

    private func verdict(start: Int, end: Int = 0, kind: StretchKind = .activityContext,
                         _ answer: StretchVerdict = .correct, at now: Date = Date()) -> StretchFeedback {
        StretchFeedback(kind: kind, startTs: start, endTs: end == 0 ? start + 600 : end, deviceId: "my-whoop",
                        predictedLabel: "Sitting quietly", predictedClass: "sitting", predictedConfidence: 0.7,
                        verdict: answer, correctedLabel: answer == .incorrect ? .walking : nil, note: "  tea  ",
                        appVersion: "1.2.3", appBuild: "45", tzOffsetS: 3600, now: now)
    }

    private func sync(_ store: StretchFeedbackStore, signedIn: Bool = true) -> StretchFeedbackCloudSync {
        StretchFeedbackCloudSync(
            store: store,
            session: StretchFeedbackStub.session(),
            endpoint: { URL(string: "https://example.invalid/functions/v1/scores")! },
            identity: {
                signedIn ? CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
                                             sourceId: "22222222-2222-4222-8222-222222222222",
                                             tokenId: "t", uploadToken: "noop_x") : nil
            })
    }

    // MARK: Local store

    func testVerdictsSurviveRelaunch() {
        let first = makeStore()
        let saved = verdict(start: 1_000, .incorrect)
        first.upsert(saved)

        let reopened = makeStore().all()
        XCTAssertEqual(reopened.count, 1)
        XCTAssertEqual(reopened.first?.id, saved.id)
        XCTAssertEqual(reopened.first?.verdict, .incorrect)
        XCTAssertEqual(reopened.first?.correctedLabel, .walking)
        XCTAssertEqual(reopened.first?.note, "tea")
        XCTAssertEqual(reopened.first?.predictedLabel, "Sitting quietly")
        XCTAssertTrue(reopened.first?.needsSync ?? false)
    }

    func testUpsertReplacesTheAnswerForTheSameStretch() {
        let store = makeStore()
        let first = verdict(start: 1_000, .correct)
        store.upsert(first)
        let changed = verdict(start: 1_000, .incorrect, at: Date().addingTimeInterval(5)).continuing(first)
        store.upsert(changed)

        let rows = store.all()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows[0].id, first.id)
        XCTAssertEqual(rows[0].verdict, .incorrect)
    }

    func testMarkSyncedClearsOnlyWhatWasSent() throws {
        let store = makeStore()
        let a = verdict(start: 1_000), b = verdict(start: 2_000)
        store.upsert(a); store.upsert(b)

        store.markSynced([(id: a.id, updatedAt: a.updatedAt)])

        XCTAssertEqual(store.pending().map(\.id), [b.id])
    }

    func testAnswerEditedAfterItWasSentStaysPending() {
        let store = makeStore()
        let sent = verdict(start: 1_000, .correct)
        store.upsert(sent)
        let edited = verdict(start: 1_000, .incorrect, at: sent.updatedAt.addingTimeInterval(30)).continuing(sent)
        store.upsert(edited)

        store.markSynced([(id: sent.id, updatedAt: sent.updatedAt)])

        XCTAssertEqual(store.pending().map(\.verdict), [.incorrect])
    }

    func testPendingGoesOldestFirst() {
        let store = makeStore()
        let now = Date()
        store.upsert(verdict(start: 3_000, at: now.addingTimeInterval(20)))
        store.upsert(verdict(start: 1_000, at: now))
        store.upsert(verdict(start: 2_000, at: now.addingTimeInterval(10)))

        XCTAssertEqual(store.pending().map(\.startTs), [1_000, 2_000, 3_000])
    }

    func testOldSyncedVerdictsAreDroppedButUnsentOnesNever() {
        let store = makeStore()
        let longAgo = Date().addingTimeInterval(-Double(StretchFeedbackStore.keepSyncedDays + 5) * 86_400)
        let oldSent = verdict(start: 1_000, at: longAgo)
        let oldUnsent = verdict(start: 2_000, at: longAgo)
        store.upsert(oldSent); store.upsert(oldUnsent)

        store.markSynced([(id: oldSent.id, updatedAt: oldSent.updatedAt)])

        XCTAssertEqual(store.all().map(\.id), [oldUnsent.id])
    }

    func testUnreadableFileReadsAsEmptyInsteadOfCrashing() throws {
        let url = tempDir.appendingPathComponent("stretch-feedback.json")
        try Data("not json".utf8).write(to: url)
        XCTAssertTrue(StretchFeedbackStore(fileURL: url).all().isEmpty)
    }

    private func setAsideFiles() throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(StretchFeedbackStore.unreadablePrefix) }
    }

    func testAnUnreadableFileIsKeptAsideNotWrittenOver() throws {
        let url = tempDir.appendingPathComponent("stretch-feedback.json")
        try Data("not json".utf8).write(to: url)
        let store = StretchFeedbackStore(fileURL: url)

        store.upsert(verdict(start: 1_000, .incorrect))

        let kept = try setAsideFiles()
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(try String(contentsOf: kept[0], encoding: .utf8), "not json")
        XCTAssertEqual(StretchFeedbackStore(fileURL: url).all().count, 1, "the new answer is saved as usual")
    }

    func testOneUnreadableEntryDoesNotCostTheAnswersAroundIt() throws {
        let url = tempDir.appendingPathComponent("stretch-feedback.json")
        let first = makeStore()
        first.upsert(verdict(start: 1_000, .incorrect))
        first.upsert(verdict(start: 2_000, .correct))
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [[String: Any]])
        entries.insert(["id": "not-a-uuid", "verdict": 7], at: 1)
        try JSONSerialization.data(withJSONObject: entries).write(to: url)

        let reopened = StretchFeedbackStore(fileURL: url)

        XCTAssertEqual(Set(reopened.all().map(\.startTs)), [1_000, 2_000])
        XCTAssertEqual(try setAsideFiles().count, 1, "the original is copied aside, bad entry included")
    }

    func testAFileThatCannotBeOpenedRightNowIsNotRememberedAsEmpty() throws {
        let url = tempDir.appendingPathComponent("stretch-feedback.json")
        makeStore().upsert(verdict(start: 1_000, .incorrect))
        let store = StretchFeedbackStore(fileURL: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        try XCTSkipIf((try? Data(contentsOf: url)) != nil, "this account can read a file with no permissions")

        XCTAssertTrue(store.all().isEmpty)

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(store.all().map(\.startTs), [1_000], "reads the real file once it can be opened")
        XCTAssertTrue(try setAsideFiles().isEmpty)
    }

    func testAReadableFileLeavesNothingSetAside() throws {
        makeStore().upsert(verdict(start: 1_000))
        _ = makeStore().all()
        XCTAssertTrue(try setAsideFiles().isEmpty)
    }

    func testOnlyTheNewestSetAsideCopiesAreKept() throws {
        let url = tempDir.appendingPathComponent("stretch-feedback.json")
        for n in 0..<(StretchFeedbackStore.keepUnreadableCopies + 3) {
            let stale = tempDir.appendingPathComponent("\(StretchFeedbackStore.unreadablePrefix)\(1_000 + n).json")
            try Data("old \(n)".utf8).write(to: stale)
        }
        try Data("not json".utf8).write(to: url)

        _ = StretchFeedbackStore(fileURL: url).all()

        let names = try setAsideFiles().map(\.lastPathComponent).sorted()
        XCTAssertEqual(names.count, StretchFeedbackStore.keepUnreadableCopies)
        XCTAssertFalse(names.contains("\(StretchFeedbackStore.unreadablePrefix)1000.json"), "the oldest copy goes first")
    }

    // MARK: Reading the server's reply

    func testSavedAndIgnoredCountAsDeliveredRejectedDoesNot() {
        let a = verdict(start: 1_000), b = verdict(start: 2_000), c = verdict(start: 3_000), d = verdict(start: 4_000)
        let reply = """
        {"saved":[{"stretch_key":"\(a.stretchKey)"}],
         "ignored":[{"stretch_key":"\(b.stretchKey)","reason":"older"}],
         "rejected":[{"stretch_key":"\(c.stretchKey)","reason":"bad"}]}
        """
        let result = StretchFeedbackCloudSync.accepted(in: Data(reply.utf8), batch: [a, b, c, d])

        XCTAssertEqual(Set(result.accepted.map(\.id)), [a.id, b.id])
        XCTAssertEqual(result.rejected, 1)
    }

    func testAnUnreadableReplyTakesNothing() {
        let a = verdict(start: 1_000)
        XCTAssertTrue(StretchFeedbackCloudSync.accepted(in: Data("oops".utf8), batch: [a]).accepted.isEmpty)
        XCTAssertTrue(StretchFeedbackCloudSync.accepted(in: Data("{}".utf8), batch: [a]).accepted.isEmpty)
    }

    // MARK: Upload

    func testPushSendsTheWireContractAndClearsTheQueue() async throws {
        let store = makeStore()
        let a = verdict(start: 1_000, .incorrect)
        store.upsert(a)
        StretchFeedbackStub.reply = .saved

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome, .init(uploaded: 1, rejected: 0))
        XCTAssertTrue(store.pending().isEmpty)
        let request = try XCTUnwrap(StretchFeedbackStub.requests.first)
        XCTAssertEqual(request.url?.path, "/functions/v1/scores/stretch-feedback")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer noop_x")

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: StretchFeedbackStub.bodies[0]) as? [String: Any])
        let items = try XCTUnwrap(body["feedback"] as? [[String: Any]])
        let item = try XCTUnwrap(items.first)
        XCTAssertEqual(item["stretch_key"] as? String, "activity_context:1000")
        XCTAssertEqual(item["kind"] as? String, "activity_context")
        XCTAssertEqual(item["verdict"] as? String, "incorrect")
        XCTAssertEqual(item["corrected_label"] as? String, "walking")
        XCTAssertEqual(item["predicted_label"] as? String, "Sitting quietly")
        XCTAssertEqual(item["device_id"] as? String, "my-whoop")
        XCTAssertEqual(item["note"] as? String, "tea")
        XCTAssertEqual(item["start_ts"] as? Int, 1_000)
        XCTAssertEqual(item["end_ts"] as? Int, 1_600)
        XCTAssertEqual(item["id"] as? String, a.id.uuidString.lowercased())
        XCTAssertNotNil(item["client_updated_at"] as? String)
        XCTAssertNotNil(item["model_context"] as? [String: Any])
    }

    func testPushSplitsLargeQueuesIntoBatches() async throws {
        let store = makeStore()
        let total = StretchFeedbackCloudSync.batchSize * 2 + 3
        for i in 0..<total { store.upsert(verdict(start: 1_000 + i * 700, at: Date().addingTimeInterval(Double(i)))) }
        StretchFeedbackStub.reply = .echo

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome.uploaded, total)
        XCTAssertEqual(StretchFeedbackStub.requests.count, 3)
        XCTAssertTrue(store.pending().isEmpty)
    }

    func testRejectedVerdictsStayQueued() async throws {
        let store = makeStore()
        let a = verdict(start: 1_000)
        store.upsert(a)
        StretchFeedbackStub.reply = .rejected

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome.uploaded, 0)
        XCTAssertEqual(outcome.rejected, 1)
        XCTAssertNil(outcome.blocked)
        XCTAssertEqual(store.pending().map(\.id), [a.id])
    }

    func testTheServersReasonForARefusalComesBack() async throws {
        let store = makeStore()
        let a = verdict(start: 1_000)
        store.upsert(a)
        StretchFeedbackStub.reply = .rejectedWithReason

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome.refusals, [a.stretchKey: "invalid_model_context"])
        XCTAssertEqual(store.pending().map(\.id), [a.id])
    }

    func testAVerdictTheReplyNeverMentionsIsReportedAsUnconfirmed() async throws {
        let store = makeStore()
        let a = verdict(start: 1_000)
        store.upsert(a)
        StretchFeedbackStub.reply = .silent

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome.uploaded, 0)
        XCTAssertEqual(outcome.refusals, [a.stretchKey: "not_confirmed"])
        XCTAssertEqual(store.pending().count, 1)
    }

    func testACredentialTheServerRefusesIsReportedAsSignedOutNotSwallowed() async throws {
        let store = makeStore()
        store.upsert(verdict(start: 1_000))
        StretchFeedbackStub.status = 401

        let outcome = try await sync(store).pushPending()

        XCTAssertEqual(outcome.blocked, .signedOut)
        XCTAssertEqual(store.pending().count, 1)
    }

    func testAReplyThatIsNotTheRoutesJSONIsTriedAgainNotTrusted() async {
        let store = makeStore()
        store.upsert(verdict(start: 1_000))
        StretchFeedbackStub.reply = .garbage

        do {
            _ = try await sync(store).pushPending()
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertTrue(error is StretchFeedbackSyncError)
        }
        XCTAssertEqual(store.pending().count, 1)
    }

    func testNoCloudAddressIsReportedAsSuch() async throws {
        let store = makeStore()
        store.upsert(verdict(start: 1_000))
        let noAddress = StretchFeedbackCloudSync(
            store: store, session: StretchFeedbackStub.session(), endpoint: { nil },
            identity: {
                CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
                                  sourceId: "22222222-2222-4222-8222-222222222222",
                                  tokenId: "t", uploadToken: "noop_x")
            })

        let outcome = try await noAddress.pushPending()

        XCTAssertEqual(outcome.blocked, .noServer)
        XCTAssertTrue(StretchFeedbackStub.requests.isEmpty)
    }

    func testNothingWaitingIsNeverReportedAsBlocked() async throws {
        let outcome = try await sync(makeStore(), signedIn: false).pushPending()
        XCTAssertEqual(outcome, .init())
    }

    func testServerErrorKeepsEverythingQueued() async {
        let store = makeStore()
        store.upsert(verdict(start: 1_000))
        StretchFeedbackStub.status = 500

        do {
            _ = try await sync(store).pushPending()
            XCTFail("expected a thrown error")
        } catch {
            XCTAssertTrue(error is StretchFeedbackSyncError)
        }
        XCTAssertEqual(store.pending().count, 1)
    }

    func testNothingIsSentWhileSignedOut() async throws {
        let store = makeStore()
        store.upsert(verdict(start: 1_000))

        let outcome = try await sync(store, signedIn: false).pushPending()

        XCTAssertEqual(outcome, .init(blocked: .signedOut))
        XCTAssertTrue(StretchFeedbackStub.requests.isEmpty)
        XCTAssertEqual(store.pending().count, 1)
    }

    @MainActor
    func testCenterSavesAtOnceAndShowsTheAnswerOnAMovedStretch() {
        let store = makeStore()
        let center = StretchFeedbackCenter(store: store, sync: sync(store, signedIn: false))
        center.save(verdict(start: 1_000, end: 1_600, .incorrect))

        XCTAssertEqual(center.waitingToUpload, 1)
        // The same stretch after a re-decode moved its edges by a few seconds.
        XCTAssertEqual(center.feedback(kind: .activityContext, start: 1_004, end: 1_610)?.verdict, .incorrect)
        XCTAssertNil(center.feedback(kind: .strapState, start: 1_000, end: 1_600))
        XCTAssertNil(center.feedback(kind: .activityContext, start: 5_000, end: 5_600))
    }

    @MainActor
    func testCenterSendsAnAnswerAndSaysSo() async {
        let store = makeStore()
        let center = StretchFeedbackCenter(store: store, sync: sync(store))
        center.save(verdict(start: 1_000, .incorrect))

        await center.flushAndWait()

        XCTAssertEqual(center.waitingToUpload, 0)
        XCTAssertEqual(center.delivery, .idle)
        XCTAssertEqual(center.standing(of: center.records[0]), .sent)
        XCTAssertTrue(store.pending().isEmpty)
    }

    @MainActor
    func testCenterSaysSignInWhenNobodyIsSignedIn() async {
        let store = makeStore()
        let center = StretchFeedbackCenter(store: store, sync: sync(store, signedIn: false))
        center.save(verdict(start: 1_000, .incorrect))

        await center.flushAndWait()

        XCTAssertEqual(center.delivery, .needsSignIn)
        XCTAssertEqual(center.standing(of: center.records[0]), .needsSignIn)
        XCTAssertEqual(center.waitingToUpload, 1, "the answer is kept, not dropped")
        XCTAssertTrue(StretchFeedbackStub.requests.isEmpty)
    }

    @MainActor
    func testCenterKeepsARefusedAnswerAndSaysWhy() async {
        let store = makeStore()
        let center = StretchFeedbackCenter(store: store, sync: sync(store))
        StretchFeedbackStub.reply = .rejectedWithReason
        center.save(verdict(start: 1_000, .incorrect))

        await center.flushAndWait()

        XCTAssertEqual(center.delivery, .refused)
        XCTAssertEqual(center.standing(of: center.records[0]), .refused(reason: "invalid_model_context"))
        XCTAssertEqual(center.waitingToUpload, 1)
    }

    @MainActor
    func testCenterTriesAgainOnItsOwnAfterAServerError() async throws {
        let store = makeStore()
        let center = StretchFeedbackCenter(store: store, sync: sync(store), retryDelays: [0.05])
        StretchFeedbackStub.status = 500
        center.save(verdict(start: 1_000, .incorrect))
        await center.flushAndWait()
        XCTAssertEqual(center.delivery, .willRetry)
        XCTAssertEqual(center.standing(of: center.records[0]), .willRetry)
        XCTAssertEqual(center.waitingToUpload, 1)

        StretchFeedbackStub.status = 200
        let deadline = Date().addingTimeInterval(5)
        while center.waitingToUpload > 0 && Date() < deadline { try await Task.sleep(nanoseconds: 25_000_000) }

        XCTAssertEqual(center.waitingToUpload, 0, "no app relaunch or new answer was needed")
        XCTAssertEqual(center.delivery, .idle)
    }

    @MainActor
    func testCenterGoesBackToSendingWhenSignInReturns() async {
        let store = makeStore()
        let signedIn = SignInSwitch()
        let identity = CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
                                         sourceId: "22222222-2222-4222-8222-222222222222",
                                         tokenId: "t", uploadToken: "noop_x")
        let toggled = StretchFeedbackCloudSync(
            store: store, session: StretchFeedbackStub.session(),
            endpoint: { URL(string: "https://example.invalid/functions/v1/scores")! },
            identity: { signedIn.isOn ? identity : nil })
        let center = StretchFeedbackCenter(store: store, sync: toggled)
        center.save(verdict(start: 1_000, .incorrect))
        await center.flushAndWait()
        XCTAssertEqual(center.delivery, .needsSignIn)

        signedIn.isOn = true
        await center.flushAndWait()

        XCTAssertEqual(center.waitingToUpload, 0)
        XCTAssertEqual(center.delivery, .idle)
    }

    // MARK: Day-state cache

    func testDayStatesRoundTripThroughTheCacheFile() {
        let cache = DayStateFileStore(directory: tempDir.appendingPathComponent("states", isDirectory: true))
        let segments = [
            DayStateSegment(state: .sleeping, basis: .sleepSession, start: 1_000, end: 5_000,
                            avgHr: 52, minHr: 48, maxHr: 60, motionG: 0.01, locomotionShare: nil, workoutSport: nil),
            DayStateSegment(state: .walking, basis: .strapActivityClass, start: 5_000, end: 6_800,
                            avgHr: 105, minHr: 90, maxHr: 120, motionG: 0.3, locomotionShare: 0.8,
                            stepTicks: 2_000, workoutSport: nil)
        ]
        cache.save(segments: segments, source: "my-whoop", dayStart: 0, dayEnd: 86_400)

        let loaded = cache.load(source: "my-whoop", dayStart: 0)
        XCTAssertEqual(loaded?.segments, segments)
        XCTAssertEqual(loaded?.dayEnd, 86_400)
        XCTAssertNil(cache.load(source: "other-strap", dayStart: 0))
        XCTAssertNil(cache.load(source: "my-whoop", dayStart: 86_400))
    }

    func testSavingDropsDaysOlderThanTheRetentionWindow() {
        let cache = DayStateFileStore(directory: tempDir.appendingPathComponent("states", isDirectory: true))
        let now = Date()
        let today = Int(now.timeIntervalSince1970) / 86_400 * 86_400
        let stale = today - (DayStateFileStore.retentionDays + 3) * 86_400
        cache.save(segments: [], source: "my-whoop", dayStart: stale, dayEnd: stale + 86_400, now: now)
        cache.save(segments: [], source: "my-whoop", dayStart: today - 86_400, dayEnd: today, now: now)
        XCTAssertNotNil(cache.load(source: "my-whoop", dayStart: today - 86_400))

        cache.save(segments: [], source: "my-whoop", dayStart: today, dayEnd: today + 600, now: now)

        XCTAssertNil(cache.load(source: "my-whoop", dayStart: stale))
        XCTAssertNotNil(cache.load(source: "my-whoop", dayStart: today))
        XCTAssertNotNil(cache.load(source: "my-whoop", dayStart: today - 86_400))
    }

    func testAnUnreadableDayStateFileIsAMiss() throws {
        let dir = tempDir.appendingPathComponent("states", isDirectory: true)
        let cache = DayStateFileStore(directory: dir)
        try Data("garbage".utf8).write(to: cache.fileURL(source: "my-whoop", dayStart: 0))
        XCTAssertNil(cache.load(source: "my-whoop", dayStart: 0))
    }

    func testRemoveEverythingEmptiesTheDayStateCache() {
        let cache = DayStateFileStore(directory: tempDir.appendingPathComponent("states", isDirectory: true))
        cache.save(segments: [], source: "my-whoop", dayStart: 0, dayEnd: 100)
        cache.removeEverything()
        XCTAssertNil(cache.load(source: "my-whoop", dayStart: 0))
    }
}

/// Stands in for "is anyone signed in", flipped by a test while a sync object that reads it is already built.
private final class SignInSwitch: @unchecked Sendable {
    var isOn = false
}

/// Answers the stretch-feedback route from memory so the real request path runs with no network.
private final class StretchFeedbackStub: URLProtocol {
    enum Reply { case saved, rejected, echo, rejectedWithReason, silent, garbage }

    static var status = 200
    static var reply = Reply.saved
    static var requests: [URLRequest] = []
    static var bodies: [Data] = []

    static func reset() {
        status = 200; reply = .saved; requests = []; bodies = []
    }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StretchFeedbackStub.self]
        return URLSession(configuration: config)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(of: request)
        Self.requests.append(request)
        Self.bodies.append(body)

        let keys = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])
            .flatMap { $0["feedback"] as? [[String: Any]] }?
            .compactMap { $0["stretch_key"] as? String } ?? []
        let rows = keys.map { ["stretch_key": $0] }
        let payload: [String: Any]
        switch Self.reply {
        case .saved, .echo: payload = ["saved": rows, "ignored": [], "rejected": []]
        case .rejected: payload = ["saved": [], "ignored": [], "rejected": rows]
        case .rejectedWithReason:
            payload = ["saved": [], "ignored": [],
                       "rejected": keys.map { ["stretch_key": $0, "reason": "invalid_model_context"] }]
        case .silent: payload = ["saved": [], "ignored": [], "rejected": []]
        case .garbage: payload = [:]
        }
        let data = Self.reply == .garbage
            ? Data("<html>sign in to the wifi</html>".utf8)
            : (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let http = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1",
                                   headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var out = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            out.append(buffer, count: read)
        }
        return out
    }
}

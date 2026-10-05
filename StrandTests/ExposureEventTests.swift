import XCTest
import StrandAnalytics
import WhoopStore
@testable import Strand

/// Exposure events on the phone: the immutable revision store, the journal and caffeine bridges, the editor draft
/// and the upload / reconcile path against a stubbed `scores` route.
final class ExposureEventTests: XCTestCase {
    typealias PC = PhysiologyContext
    typealias Revision = PhysiologyContext.ExposureEventRevision

    private let ownerA = "11111111-1111-4111-8111-111111111111"
    private let ownerB = "33333333-3333-4333-8333-333333333333"
    private let la = TimeZone(identifier: "America/Los_Angeles")!
    /// 2026-10-01 00:00 America/Los_Angeles.
    private let d0 = 1_790_838_000

    override func setUp() {
        super.setUp()
        ExposureStub.reset()
    }

    private func makeStore() async throws -> ExposureEventStore {
        let whoop = try await WhoopStore.inMemory()
        return try ExposureEventStore(dbQueue: whoop.registryWriter)
    }

    private func rev(_ id: String = "e1", _ revision: Int = 1, at start: Int? = nil, label: String = "ibuprofen",
                     dose: Double? = nil, confirmation: PC.ExposureConfirmation = .confirmed,
                     recordedAt: Int? = nil) -> Revision {
        let s = start ?? d0 + 8 * 3600
        return Revision(eventId: id, revision: revision, kind: .medication, label: label,
                        occurred: PC.Interval(s, s + 1), timePrecision: .exact, recordedAt: recordedAt ?? s + 60,
                        source: .userEntered, confirmation: confirmation, doseAmount: dose,
                        doseUnit: dose == nil ? nil : "mg", doseProvenance: dose == nil ? nil : "user_entered")
    }

    /// Raw SQL against the store's database (proves the table-level guards, not just the Swift API).
    private func execute(_ store: ExposureEventStore, _ sql: String) throws {
        try store.executeForTesting(sql)
    }

    private func client(_ store: ExposureEventStore, owner: String? = nil, isOwner: Bool = true,
                        signedIn: Bool = true) -> ExposureEventSyncClient {
        let id = owner ?? ownerA
        return ExposureEventSyncClient(
            store: store, session: ExposureStub.session(),
            endpoint: { URL(string: "https://example.invalid/functions/v1/scores")! },
            identity: {
                signedIn ? CloudPushIdentity(ownerId: id, sourceId: "22222222-2222-4222-8222-222222222222",
                                             tokenId: "t", uploadToken: "noop_x") : nil
            },
            isOwner: { _ in isOwner },
            now: { Date(timeIntervalSince1970: 1_790_900_000) })
    }

    // MARK: - Store

    func testRevisionsAreImmutableAndRecordingIsIdempotent() async throws {
        let store = try await makeStore()
        XCTAssertTrue(try store.record(rev(), owner: ownerA))
        XCTAssertFalse(try store.record(rev(), owner: ownerA), "the identical revision is a no-op")
        XCTAssertThrowsError(try store.record(rev(dose: 200), owner: ownerA)) { error in
            XCTAssertEqual(error as? ExposureEventStore.StoreError, .revisionConflict(eventId: "e1", revision: 1))
        }
        XCTAssertThrowsError(try store.record(rev("bad", 0), owner: ownerA))
        // The table itself refuses to rewrite a revision.
        XCTAssertThrowsError(try execute(store, "UPDATE exposureEventRevision SET label = 'other' WHERE eventId = 'e1'"))
        // receivedAt is the server's and is written once.
        try execute(store, "UPDATE exposureEventRevision SET receivedAt = 5 WHERE eventId = 'e1'")
        XCTAssertThrowsError(try execute(store, "UPDATE exposureEventRevision SET receivedAt = 6 WHERE eventId = 'e1'"))
        // An edit is a new revision; a delete is a retraction; history keeps all three.
        try store.record(rev("e1", 2, dose: 400), owner: ownerA)
        let retraction = try XCTUnwrap(try store.retract(owner: ownerA, eventId: "e1", recordedAt: d0 + 9 * 3600))
        XCTAssertEqual(retraction.revision, 3)
        XCTAssertNil(try store.retract(owner: ownerA, eventId: "e1", recordedAt: d0 + 9 * 3600))
        XCTAssertEqual(try store.revisions(owner: ownerA, eventId: "e1").map(\.revision), [1, 2, 3])
        XCTAssertTrue(try store.current(owner: ownerA, from: d0, to: d0 + 86_400).isEmpty)
    }

    func testCurrentStateUsesTheLatestRevisionAndCountsHistory() async throws {
        let store = try await makeStore()
        try store.record(rev(dose: 200), owner: ownerA)
        try store.record(rev("e1", 2, at: d0 + 10 * 3600, dose: 400), owner: ownerA)
        let current = try store.current(owner: ownerA, from: d0, to: d0 + 86_400)
        XCTAssertEqual(current.count, 1)
        XCTAssertEqual(current[0].revision, 2)
        XCTAssertEqual(current[0].revisionCount, 2)
        XCTAssertEqual(current[0].doseAmount, 400)
        // The event moved out of [08:00, 09:00): an older revision there does not resurrect it.
        XCTAssertTrue(try store.current(owner: ownerA, from: d0 + 8 * 3600, to: d0 + 9 * 3600).isEmpty)
    }

    func testRowsAreScopedToTheirOwner() async throws {
        let store = try await makeStore()
        try store.record(rev(), owner: ownerA.uppercased())
        XCTAssertEqual(try store.current(owner: ownerA, from: d0, to: d0 + 86_400).count, 1)
        XCTAssertTrue(try store.current(owner: ownerB, from: d0, to: d0 + 86_400).isEmpty)
        XCTAssertTrue(try store.pending(owner: ownerB).isEmpty)
        XCTAssertEqual(try store.pending(owner: ownerA).count, 1)
        // The same event id under another owner is another event.
        XCTAssertTrue(try store.record(rev(dose: 1), owner: ownerB))
    }

    func testUnclaimedRevisionsAreAdoptedWithJournalIdsRekeyed() async throws {
        let store = try await makeStore()
        let unclaimed = ExposureEventStore.unclaimedOwner
        let first = try XCTUnwrap(try ExposureJournalBridge.apply(
            journal: .yes, day: "2026-10-01", question: "Did you take magnesium?", unit: nil, owner: unclaimed,
            zone: la, now: Date(timeIntervalSince1970: TimeInterval(d0 + 3600)), store: store))
        XCTAssertEqual(first.eventId, ExposureEventIds.journal(owner: unclaimed, day: "2026-10-01",
                                                               canonicalQuestion: "did you take magnesium?"))
        XCTAssertEqual(try store.adoptUnclaimed(owner: ownerA), 1)
        XCTAssertTrue(try store.stored(owner: unclaimed).isEmpty)
        let adopted = try store.stored(owner: ownerA)
        XCTAssertEqual(adopted.map(\.revision.eventId),
                       [ExposureEventIds.journal(owner: ownerA, day: "2026-10-01",
                                                 canonicalQuestion: "did you take magnesium?")])
        // The owner's next answer continues the same event.
        let next = try XCTUnwrap(try ExposureJournalBridge.apply(
            journal: .no, day: "2026-10-01", question: "did you take  MAGNESIUM?", unit: nil, owner: ownerA,
            zone: la, now: Date(timeIntervalSince1970: TimeInterval(d0 + 7200)), store: store))
        XCTAssertEqual(next.revision, 2)
        XCTAssertEqual(next.confirmation, .denied)
    }

    // MARK: - Journal bridge

    func testJournalAnswersBecomeDayOnlyRevisionsOfOneEvent() async throws {
        let store = try await makeStore()
        let day = "2026-10-01"
        let q = "Did you drink any alcohol?"
        func answer(_ a: ExposureJournalBridge.JournalAnswer, unit: String? = nil, minute: Int) throws -> Revision? {
            try ExposureJournalBridge.apply(journal: a, day: day, question: q, unit: unit, owner: ownerA, zone: la,
                                            now: Date(timeIntervalSince1970: TimeInterval(d0 + 20 * 3600 + minute * 60)),
                                            store: store)
        }
        let yes = try XCTUnwrap(try answer(.yes, minute: 0))
        XCTAssertEqual(yes.kind, .alcohol)
        XCTAssertEqual(yes.label, q)
        XCTAssertEqual(yes.confirmation, .confirmed)
        XCTAssertEqual(yes.source, .journalDayAnswer)
        XCTAssertEqual(yes.timePrecision, .dayOnly)
        XCTAssertEqual(yes.occurred, PC.Interval(d0, d0 + 86_400))
        XCTAssertEqual(yes.revision, 1)
        XCTAssertEqual(yes.recordedAt, d0 + 20 * 3600)
        XCTAssertNil(yes.doseAmount)

        let no = try XCTUnwrap(try answer(.no, minute: 1))
        XCTAssertEqual(no.eventId, yes.eventId)
        XCTAssertEqual(no.revision, 2)
        XCTAssertEqual(no.confirmation, .denied)
        XCTAssertNil(try answer(.no, minute: 2), "the same answer again is not a new revision")

        let numeric = try XCTUnwrap(try answer(.numeric(2), unit: "drinks", minute: 3))
        XCTAssertEqual(numeric.revision, 3)
        XCTAssertEqual(numeric.confirmation, .confirmed)
        XCTAssertEqual(numeric.doseAmount, 2)
        XCTAssertEqual(numeric.doseUnit, "drinks")
        XCTAssertEqual(numeric.doseProvenance, "catalog_default")
        let zero = try XCTUnwrap(try answer(.numeric(0), unit: "drinks", minute: 4))
        XCTAssertEqual(zero.confirmation, .denied)
        XCTAssertEqual(zero.doseAmount, 0)

        let cleared = try XCTUnwrap(try answer(.cleared, minute: 5))
        XCTAssertEqual(cleared.revision, 5)
        XCTAssertEqual(cleared.confirmation, .retracted)
        XCTAssertNil(try answer(.cleared, minute: 6))
        XCTAssertEqual(try store.revisions(owner: ownerA, eventId: yes.eventId).count, 5)
        XCTAssertTrue(try store.current(owner: ownerA, from: d0, to: d0 + 86_400).isEmpty)
        // A cleared answer that was never recorded writes nothing.
        XCTAssertNil(try ExposureJournalBridge.apply(journal: .cleared, day: day, question: "Did you use a sauna?",
                                                     unit: nil, owner: ownerA, zone: la, now: Date(), store: store))
    }

    func testJournalHookRecordsWithoutBlockingTheJournalWrite() async throws {
        let whoop = try await WhoopStore.inMemory()
        await MainActor.run {
            ExposureJournalBridge.journalAnswered(day: "2026-10-02", question: "Did you use a sauna?", answer: .yes,
                                                  writer: whoop.registryWriter)
        }
        ExposureJournalBridge.waitForPendingWork()
        let store = try ExposureEventStore(dbQueue: whoop.registryWriter)
        let owner = ExposureJournalBridge.currentOwner()
        let rows = try store.stored(owner: owner)
        XCTAssertEqual(rows.map(\.revision.kind), [.heat])
        XCTAssertEqual(rows.first?.revision.timePrecision, .dayOnly)
    }

    func testJournalIdsAreDeterministicUUIDs() {
        let a = ExposureEventIds.journal(owner: ownerA, day: "2026-10-01", canonicalQuestion: "did you take magnesium?")
        XCTAssertEqual(a, ExposureEventIds.journal(owner: ownerA.uppercased(), day: "2026-10-01",
                                                   canonicalQuestion: "did you take magnesium?"))
        XCTAssertNotEqual(a, ExposureEventIds.journal(owner: ownerB, day: "2026-10-01",
                                                      canonicalQuestion: "did you take magnesium?"))
        XCTAssertNotEqual(a, ExposureEventIds.journal(owner: ownerA, day: "2026-10-02",
                                                      canonicalQuestion: "did you take magnesium?"))
        XCTAssertNotNil(UUID(uuidString: a))
        XCTAssertEqual(a, a.lowercased())
        let chars = Array(a)
        XCTAssertEqual(chars[14], "8", "RFC 9562 version 8 (SHA-256 name-based)")
        XCTAssertTrue("89ab".contains(chars[19]), "RFC variant")
        // Known vector: first 16 bytes of SHA-256("journal|a|2026-10-01|q") with version/variant bits applied.
        XCTAssertEqual(ExposureEventIds.journal(owner: "A", day: "2026-10-01", canonicalQuestion: "q"),
                       ExposureEventIds.nameBased("journal|a|2026-10-01|q"))
    }

    func testJournalQuestionsMapToKindsByTheDocumentedTable() {
        let cases: [(String, PC.ExposureKind)] = [
            ("Did you drink any alcohol?", .alcohol),
            ("Did you have caffeine late in the day?", .caffeine),
            ("Did you view a screen in bed?", .other),
            ("Did you eat close to bedtime?", .meal),
            ("Did you feel stressed?", .other),
            ("Did you use a sauna?", .heat),
            ("Did you share your bed?", .other),
            ("Did you feel sick or ill?", .symptom),
            ("Did you take magnesium?", .supplement),
            ("Did you read before bed?", .other),
            ("Took a sleeping pill", .medication),
            ("Melatonin", .supplement),
            ("Did you travel across time zones?", .travel),
            ("Cold shower", .other),
            ("Did you have a cold?", .symptom),
            ("Coffee (cups)", .caffeine),
            ("Something unusual", .other),
        ]
        for (question, kind) in cases {
            XCTAssertEqual(JournalExposureMapping.kind(for: question), kind, question)
        }
    }

    // MARK: - Caffeine bridge

    func testCaffeineIntakesBecomeExactRevisionsAndRemovalRetracts() async throws {
        let store = try await makeStore()
        let at = Date(timeIntervalSince1970: TimeInterval(d0 + 9 * 3600))
        let intake = CaffeineIntake(at: at, mg: 95)
        let now = Date(timeIntervalSince1970: TimeInterval(d0 + 9 * 3600 + 120))
        let logged = try XCTUnwrap(try ExposureJournalBridge.apply(caffeine: .logged(intake), owner: ownerA, now: now,
                                                                   store: store))
        XCTAssertEqual(logged.eventId, intake.id.uuidString.lowercased())
        XCTAssertEqual(logged.occurred, PC.Interval(d0 + 9 * 3600, d0 + 9 * 3600 + 1))
        XCTAssertEqual(logged.timePrecision, .exact)
        XCTAssertEqual(logged.source, .userEntered)
        XCTAssertEqual(logged.doseAmount, 95)
        XCTAssertEqual(logged.doseUnit, "mg")
        XCTAssertNil(try ExposureJournalBridge.apply(caffeine: .logged(intake), owner: ownerA, now: now, store: store))
        let removed = try XCTUnwrap(try ExposureJournalBridge.apply(caffeine: .removed(intake), owner: ownerA,
                                                                    now: now, store: store))
        XCTAssertEqual(removed.revision, 2)
        XCTAssertEqual(removed.confirmation, .retracted)

        let health = CaffeineIntake(id: UUID(), at: at, mg: 64, externalId: "hk-1")
        let imported = try XCTUnwrap(try ExposureJournalBridge.apply(caffeine: .logged(health), owner: ownerA,
                                                                     now: now, store: store))
        XCTAssertEqual(imported.source, .imported)
        XCTAssertEqual(imported.doseProvenance, "imported")
        // Unknown amount stays unknown.
        let plain = ExposureJournalBridge.caffeineRevision(CaffeineIntake(at: at), previous: nil, now: now)
        XCTAssertNil(plain?.doseAmount)
        XCTAssertNil(plain?.doseUnit)
    }

    @MainActor
    func testCaffeineStoreReportsChangesButNotPruning() {
        let suite = UserDefaults(suiteName: "exposure.caffeine.\(UUID().uuidString)")!
        let now = Date(timeIntervalSince1970: TimeInterval(d0 + 12 * 3600))
        let store = CaffeineLogStore(defaults: suite, now: { now })
        var seen: [ExposureJournalBridge.CaffeineChange] = []
        store.exposureSink = { seen += $0 }
        store.log(at: now.addingTimeInterval(-600), mg: 80)
        let logged = store.intakes[0]
        XCTAssertEqual(seen, [.logged(logged)])
        store.remove(logged.id)
        XCTAssertEqual(seen.last, .removed(logged))
        store.log(at: now, mg: nil)
        store.clearAll()
        XCTAssertEqual(seen.count, 4)

        let recent = CaffeineIntake(id: UUID(), at: now.addingTimeInterval(-3600), mg: 50, externalId: "a")
        let old = CaffeineIntake(id: UUID(), at: now.addingTimeInterval(-47.5 * 3600), mg: 50, externalId: "b")
        store.replaceImported([recent, old])
        XCTAssertEqual(Array(seen.suffix(2)), [.logged(old), .logged(recent)])
        seen = []
        // `recent` deleted in the source app → removed; `old` gone because it aged out of the read window → not.
        store.replaceImported([])
        XCTAssertEqual(seen, [.removed(recent)])
        // A reopened store prunes on load and reports nothing.
        let reopened = CaffeineLogStore(defaults: suite, now: { now.addingTimeInterval(72 * 3600) })
        var none: [ExposureJournalBridge.CaffeineChange] = []
        reopened.exposureSink = { none += $0 }
        XCTAssertTrue(none.isEmpty)
    }

    // MARK: - Editor draft

    func testDraftTurnsIntoRevisions() {
        let t = Date(timeIntervalSince1970: TimeInterval(d0 + 8 * 3600))
        var draft = ExposureEventDraft(start: t)
        draft.kind = .medication
        draft.label = "  ibuprofen "
        draft.doseText = "200"
        draft.doseUnit = "mg"
        let r1 = draft.revision(eventId: "x", previous: nil, recordedAt: t)
        XCTAssertEqual(r1?.occurred, PC.Interval(d0 + 8 * 3600, d0 + 8 * 3600 + 1))
        XCTAssertEqual(r1?.timePrecision, .exact)
        XCTAssertEqual(r1?.label, "ibuprofen")
        XCTAssertEqual(r1?.doseAmount, 200)
        XCTAssertEqual(r1?.source, .userEntered)
        XCTAssertNil(draft.revision(eventId: "x", previous: r1, recordedAt: t.addingTimeInterval(60)),
                     "saving unchanged is not a new revision")
        draft.precision = .approximate
        XCTAssertEqual(draft.revision(eventId: "x", previous: r1, recordedAt: t)?.occurred,
                       PC.Interval(d0 + 8 * 3600 - 1800, d0 + 8 * 3600 + 1800))
        draft.end = t.addingTimeInterval(-60)
        XCTAssertEqual(draft.problems, [.endBeforeStart])
        XCTAssertNil(draft.revision(eventId: "x", previous: r1, recordedAt: t))
        draft.end = t.addingTimeInterval(2 * 3600)
        draft.doseText = "2,5"
        let r2 = draft.revision(eventId: "x", previous: r1, recordedAt: t)
        XCTAssertEqual(r2?.revision, 2)
        XCTAssertEqual(r2?.doseAmount, 2.5)
        XCTAssertEqual(r2?.occurred, PC.Interval(d0 + 8 * 3600, d0 + 10 * 3600))
        draft.doseText = "a lot"
        XCTAssertEqual(draft.problems, [.doseNotANumber])
        // Editing round-trips through the event shape.
        let event = PC.Exposures.current([r2!], mode: .retrospective, cutoff: 0)[0]
        let back = ExposureEventDraft(event: event)
        XCTAssertEqual(back.end, t.addingTimeInterval(2 * 3600))
        XCTAssertEqual(back.doseText, "2.5")
    }

    // MARK: - Upload and reconcile

    func testUploadSendsTheWireContractInBatchesAndMarksSaved() async throws {
        let store = try await makeStore()
        for i in 0..<30 { try store.record(rev("e\(i)", at: d0 + i * 60, dose: 100), owner: ownerA) }
        let outcome = await client(store).sync()
        XCTAssertNil(outcome.stopped)
        XCTAssertEqual(outcome.uploaded, 30)
        let posts = ExposureStub.requests.filter { $0.method == "POST" }
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts.map(\.url.path), ["/functions/v1/scores/exposures", "/functions/v1/scores/exposures"])
        let get = try XCTUnwrap(ExposureStub.requests.first { $0.method == "GET" })
        let query = URLComponents(url: get.url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first { $0.name == "history" }?.value, "1")
        XCTAssertEqual(query.first { $0.name == "from" }?.value, String(1_790_900_000 - 30 * 86_400))
        XCTAssertEqual(posts[0].authorization, "Bearer noop_x")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: posts[0].body) as? [String: Any])
        let events = try XCTUnwrap(body["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 25)
        let first = events[0]
        XCTAssertEqual(first["event_id"] as? String, "e0")
        XCTAssertEqual(first["revision"] as? Int, 1)
        XCTAssertEqual(first["time_precision"] as? String, "exact")
        XCTAssertEqual(first["source"] as? String, "user_entered")
        XCTAssertEqual(first["dose_amount"] as? Double, 100)
        XCTAssertEqual((first["occurred"] as? [String: Any])?["start"] as? Int, d0)
        XCTAssertNil(first["received_at"], "the server sets received_at")
        XCTAssertNotNil(first["recorded_at"])
        XCTAssertTrue(try store.pending(owner: ownerA).isEmpty)
        // Nothing left: a second flush sends nothing.
        ExposureStub.requests = []
        _ = await client(store).sync()
        XCTAssertTrue(ExposureStub.requests.filter { $0.method == "POST" }.isEmpty)
    }

    func testAnOldServerKeepsEverythingPending() async throws {
        let store = try await makeStore()
        try store.record(rev(), owner: ownerA)
        ExposureStub.handler = { _, _ in (405, ["error": "method not allowed"]) }
        let outcome = await client(store).sync()
        XCTAssertEqual(outcome.stopped, .unsupported)
        XCTAssertEqual(try store.pendingCount(owner: ownerA), 1)
        XCTAssertTrue(ExposureStub.requests.filter { $0.method == "POST" }.isEmpty)
        ExposureStub.handler = { request, _ in request.httpMethod == "POST" ? (401, [String: Any]()) : (200, ["events": [Any]()]) }
        do { let o = await client(store).sync(); XCTAssertEqual(o.stopped, .unauthorized) }
        XCTAssertEqual(try store.pendingCount(owner: ownerA), 1)
        ExposureStub.handler = { request, _ in request.httpMethod == "POST" ? (500, [String: Any]()) : (200, ["events": [Any]()]) }
        do { let o = await client(store).sync(); XCTAssertEqual(o.stopped, .serverError) }
        XCTAssertEqual(try store.pendingCount(owner: ownerA), 1)
    }

    func testNothingIsSentForAnotherAccountOrWhileSignedOut() async throws {
        let store = try await makeStore()
        try store.record(rev(), owner: ownerA)
        try store.record(rev("b1"), owner: ownerB)
        do { let o = await client(store, isOwner: false).sync(); XCTAssertEqual(o.stopped, .notLocalOwner) }
        do { let o = await client(store, signedIn: false).sync(); XCTAssertEqual(o.stopped, .signedOut) }
        XCTAssertTrue(ExposureStub.requests.isEmpty)
        // Signed in as B (who owns the data here): only B's row goes out, A's stays on the phone.
        _ = await client(store, owner: ownerB).sync()
        let posted = ExposureStub.requests.filter { $0.method == "POST" }
            .flatMap { ((try? JSONSerialization.jsonObject(with: $0.body)) as? [String: Any])?["events"] as? [[String: Any]] ?? [] }
            .compactMap { $0["event_id"] as? String }
        XCTAssertEqual(posted, ["b1"])
        XCTAssertEqual(try store.pendingCount(owner: ownerA), 1)
        // A reply that names a different account marks nothing.
        try store.record(rev("b2"), owner: ownerB)
        ExposureStub.handler = { request, body in
            request.httpMethod == "POST" ? (200, ExposureStub.echo(body, identity: self.ownerA))
                                         : (200, ["events": [Any](), "identity": ["userId": self.ownerB]])
        }
        do { let o = await client(store, owner: ownerB).sync(); XCTAssertEqual(o.stopped, .identityMismatch) }
        XCTAssertEqual(try store.pendingCount(owner: ownerB), 1)
    }

    func testRejectedRevisionsStayLocalAndAreNotRetried() async throws {
        let store = try await makeStore()
        try store.record(rev(), owner: ownerA)
        ExposureStub.handler = { request, body in
            request.httpMethod == "POST" ? (200, ExposureStub.echo(body, status: "rejected", reason: "invalid_label"))
                                         : (200, ["events": [Any]()])
        }
        let outcome = await client(store).sync()
        XCTAssertEqual(outcome.rejected, 1)
        let row = try XCTUnwrap(try store.stored(owner: ownerA).first)
        XCTAssertFalse(row.synced)
        XCTAssertEqual(row.serverStatus, "rejected")
        XCTAssertEqual(row.serverReason, "invalid_label")
        XCTAssertEqual(try store.pendingCount(owner: ownerA), 0)
    }

    func testReconcileRenumbersAPendingRevisionAnotherPhoneAlreadyUsed() async throws {
        let store = try await makeStore()
        try store.record(rev("e1", 1, dose: 100), owner: ownerA)
        // The account's other phone already published revision 1 (and 2) of the same event.
        let theirs1 = rev("e1", 1, dose: 50, recordedAt: d0 + 8 * 3600 + 10)
        var theirs2 = rev("e1", 2, dose: 75, recordedAt: d0 + 8 * 3600 + 20)
        theirs2.receivedAt = d0 + 8 * 3600 + 30
        let serverRows = [theirs1, theirs2].map { try! JSONSerialization.jsonObject(with: PC.encoder().encode($0)) }
        ExposureStub.handler = { request, body in
            request.httpMethod == "POST" ? (200, ExposureStub.echo(body)) : (200, ["events": serverRows])
        }
        let outcome = await client(store).sync()
        XCTAssertEqual(outcome.rebased, 1)
        XCTAssertEqual(outcome.uploaded, 1)
        let rows = try store.stored(owner: ownerA)
        XCTAssertEqual(rows.map(\.revision.revision), [1, 2, 3])
        XCTAssertEqual(rows.map(\.revision.doseAmount), [50, 75, 100], "the local edit is kept, after theirs")
        XCTAssertEqual(rows[1].revision.receivedAt, d0 + 8 * 3600 + 30)
        XCTAssertTrue(rows.allSatisfy(\.synced))
        let posted = try XCTUnwrap(ExposureStub.requests.last { $0.method == "POST" })
        let events = (try JSONSerialization.jsonObject(with: posted.body) as? [String: Any])?["events"] as? [[String: Any]]
        XCTAssertEqual(events?.map { $0["revision"] as? Int }, [3])
        // The reconciled current state is the local edit.
        XCTAssertEqual(try store.current(owner: ownerA, from: d0, to: d0 + 86_400).first?.doseAmount, 100)
        // A reconcile never deletes a pending revision that the server simply does not list.
        try store.record(rev("e9"), owner: ownerA)
        try store.replaceFromServer(owner: ownerA, revisions: [])
        XCTAssertEqual(try store.pendingCount(owner: ownerA), 1)
    }

    func testUnclaimedRevisionsUploadOnlyOnceTheLocalOwnerAdoptsThem() async throws {
        let store = try await makeStore()
        try store.record(rev("caf-1"), owner: ExposureEventStore.unclaimedOwner)
        do { let o = await client(store, isOwner: false).sync(); XCTAssertEqual(o.stopped, .notLocalOwner) }
        XCTAssertEqual(try store.stored(owner: ExposureEventStore.unclaimedOwner).count, 1)
        let outcome = await client(store).sync()
        XCTAssertEqual(outcome.adopted, 1)
        XCTAssertEqual(outcome.uploaded, 1)
        XCTAssertTrue(try store.stored(owner: ExposureEventStore.unclaimedOwner).isEmpty)
    }

    func testServerRepliesAreReadDefensively() {
        let reply = #"{"results":[{"event_id":"a","revision":1,"status":"saved"},{"event_id":"b","revision":2,"status":"weird"},{"revision":3}]}"#
        XCTAssertEqual(ExposureEventSyncClient.results(in: Data(reply.utf8)).map(\.key),
                       [ExposureEventStore.Key(eventId: "a", revision: 1)])
        XCTAssertTrue(ExposureEventSyncClient.results(in: Data("not json".utf8)).isEmpty)
        let good = try! PC.encoder().encode(rev())
        let list = "{\"events\":[\(String(decoding: good, as: UTF8.self)),{\"event_id\":\"broken\"}]}"
        XCTAssertEqual(ExposureEventSyncClient.revisions(in: Data(list.utf8)).map(\.eventId), ["e1"])
    }
}

// MARK: - URL stub

private final class ExposureStub: URLProtocol {
    struct Seen {
        let method: String
        let url: URL
        let body: Data
        let authorization: String?
    }

    static var handler: ((URLRequest, Data) -> (Int, Any))?
    static var requests: [Seen] = []

    static func reset() { handler = nil; requests = [] }

    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ExposureStub.self]
        return URLSession(configuration: config)
    }

    /// A POST reply naming every revision of `body` with `status`.
    static func echo(_ body: Data, status: String = "saved", reason: String? = nil,
                     identity: String? = nil) -> [String: Any] {
        let events = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any])?["events"]
            as? [[String: Any]] ?? []
        var out: [String: Any] = ["results": events.map { e -> [String: Any] in
            var r: [String: Any] = ["event_id": e["event_id"] ?? "", "revision": e["revision"] ?? 0, "status": status]
            if let reason { r["reason"] = reason }
            return r
        }]
        if let identity { out["identity"] = ["userId": identity] }
        return out
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = Self.bodyData(of: request)
        Self.requests.append(Seen(method: request.httpMethod ?? "GET", url: request.url!, body: body,
                                  authorization: request.value(forHTTPHeaderField: "Authorization")))
        let reply: (Int, Any)
        if let handler = Self.handler {
            reply = handler(request, body)
        } else if request.httpMethod == "POST" {
            reply = (200, Self.echo(body))
        } else {
            reply = (200, ["events": [Any]()])
        }
        let (status, payload) = reply
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let http = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
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

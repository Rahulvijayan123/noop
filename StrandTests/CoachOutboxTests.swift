import XCTest
@testable import Strand

/// The persistent per-owner outbox (`docs/COACH_MEMORY.md` §7.1): field-by-field merge, one-thread chunks of at
/// most 20, retry, bisect-and-quarantine for refused rows, and 410 / `thread_deleted` dropping the row.
final class CoachOutboxTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let threadA = "aaaaaaaa-0000-4000-8000-00000000000a"
    private let threadB = "bbbbbbbb-0000-4000-8000-00000000000b"
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("coach-outbox-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func entry(_ i: Int, thread: String? = nil, owner: String? = nil, content: String = "text",
                       meta: CoachMessageMeta? = nil) -> CoachOutboxEntry {
        CoachOutboxEntry(ownerId: owner ?? self.owner, threadId: thread ?? threadA, clientId: String(format: "c%03d", i),
                         role: i % 2 == 0 ? "user" : "assistant", content: content, meta: meta,
                         createdAt: CoachDates.string(Date(timeIntervalSince1970: 1_790_000_000 + Double(i))))
    }

    /// Records every batch and answers through `respond`.
    private actor Server {
        var batches: [[CoachStoredMessage]] = []
        var inFlight = 0
        var maxInFlight = 0
        let respond: @Sendable ([CoachStoredMessage]) throws -> CoachSaveResult
        let pause: UInt64

        init(pause: TimeInterval = 0, respond: @escaping @Sendable ([CoachStoredMessage]) throws -> CoachSaveResult) {
            self.respond = respond
            self.pause = UInt64(pause * 1_000_000_000)
        }

        func save(_ rows: [CoachStoredMessage]) async throws -> CoachSaveResult {
            batches.append(rows)
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            defer { inFlight -= 1 }
            if pause > 0 { try? await Task.sleep(nanoseconds: pause) }
            return try respond(rows)
        }
    }

    // MARK: Queue

    func testMergeIsFieldByField() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue([entry(1, content: "answer", meta: CoachMessageMeta(toolNames: ["Sleep"], hadImage: true))])
        var later = entry(1, content: "answer", meta: CoachMessageMeta(followUps: ["What next?"]))
        later.threadTitle = "Sleep check"
        await outbox.enqueue([later])
        let all = await outbox.all
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all[0].meta?.toolNames, ["Sleep"])
        XCTAssertEqual(all[0].meta?.hadImage, true)
        XCTAssertEqual(all[0].meta?.followUps, ["What next?"])
        XCTAssertEqual(all[0].threadTitle, "Sleep check")
        XCTAssertEqual(all[0].createdAt, entry(1).createdAt, "the first createdAt stays")
    }

    func testRefusesAnotherOwnersRowsAndRowsWithoutAThread() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue([entry(1, owner: "22222222-2222-4222-8222-222222222222"), entry(2, thread: "")])
        let count = await outbox.pendingCount
        XCTAssertEqual(count, 0)
    }

    func testChunksAreAtMostTwentyRowsOfOneThread() {
        let rows = (0..<45).map { entry($0) } + (45..<48).map { entry($0, thread: threadB) }
        let chunks = CoachOutbox.chunks(rows)
        XCTAssertEqual(chunks.map(\.count), [20, 20, 5, 3])
        for chunk in chunks { XCTAssertEqual(Set(chunk.map(\.threadId)).count, 1) }
    }

    // MARK: Flush

    func testFlushSendsEverythingAndEmptiesTheQueue() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue((0..<25).map { entry($0) } + [entry(30, thread: threadB)])
        let server = Server { CoachSaveResult(saved: $0.count) }
        let saved = await outbox.flush(ownerId: owner) { try await server.save($0) }
        XCTAssertEqual(saved.count, 26)
        let pending = await outbox.pendingCount
        XCTAssertEqual(pending, 0)
        let batches = await server.batches
        XCTAssertEqual(batches.map(\.count), [20, 5, 1])
        XCTAssertEqual(batches[2].first?.threadId, threadB)
    }

    func testFlushForAnotherOwnerSendsNothing() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue([entry(1)])
        let server = Server { CoachSaveResult(saved: $0.count) }
        let saved = await outbox.flush(ownerId: "22222222-2222-4222-8222-222222222222") { try await server.save($0) }
        XCTAssertTrue(saved.isEmpty)
        let none = await outbox.flush(ownerId: nil) { try await server.save($0) }
        XCTAssertTrue(none.isEmpty)
        let batches = await server.batches
        XCTAssertTrue(batches.isEmpty)
        let pending = await outbox.pendingCount
        XCTAssertEqual(pending, 1)
    }

    func testListedRejectionsAreQuarantinedAndDeletedThreadsDropped() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue([entry(1), entry(2), entry(3)])
        let server = Server { rows in
            CoachSaveResult(saved: rows.count - 2, rejected: [.init(clientId: "c001", reason: "thread_conflict"),
                                                              .init(clientId: "c002", reason: "thread_deleted")])
        }
        let saved = await outbox.flush(ownerId: owner) { try await server.save($0) }
        XCTAssertEqual(saved, ["c003"])
        let all = await outbox.all
        XCTAssertEqual(all.map(\.clientId), ["c001"])
        XCTAssertTrue(all[0].quarantined)
        let pending = await outbox.pendingCount
        XCTAssertEqual(pending, 0, "a quarantined row is never sent again")
    }

    func testA400IsBisectedDownToTheBadRow() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue((0..<8).map { entry($0) })
        let server = Server { rows in
            if rows.contains(where: { $0.clientId == "c005" }) { throw CoachRouteError(status: 400, code: "invalid_message") }
            return CoachSaveResult(saved: rows.count)
        }
        let saved = await outbox.flush(ownerId: owner) { try await server.save($0) }
        XCTAssertEqual(saved.count, 7)
        XCTAssertFalse(saved.contains("c005"))
        let all = await outbox.all
        XCTAssertEqual(all.map(\.clientId), ["c005"])
        XCTAssertTrue(all[0].quarantined)
    }

    func testA410DropsTheRow() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue([entry(1)])
        let server = Server { _ in throw CoachRouteError(status: 410, code: "thread_deleted") }
        let saved = await outbox.flush(ownerId: owner) { try await server.save($0) }
        XCTAssertTrue(saved.isEmpty)
        let all = await outbox.all
        XCTAssertTrue(all.isEmpty)
    }

    func testTransientErrorsRetryThenKeepTheRows() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil, retryDelays: [0, 0])
        await outbox.enqueue([entry(1), entry(2)])
        let server = Server { _ in throw CoachRouteError(status: 503, code: nil) }
        let saved = await outbox.flush(ownerId: owner) { try await server.save($0) }
        XCTAssertTrue(saved.isEmpty)
        let batches = await server.batches
        XCTAssertEqual(batches.count, 3, "one try and two retries")
        let pending = await outbox.pendingCount
        XCTAssertEqual(pending, 2)
    }

    func testOnlyOneFlushRunsAtATime() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue([entry(1)])
        let server = Server(pause: 0.1) { CoachSaveResult(saved: $0.count) }
        async let first = outbox.flush(ownerId: owner) { try await server.save($0) }
        await outbox.enqueue([entry(2)])
        async let second = outbox.flush(ownerId: owner) { try await server.save($0) }
        let (a, b) = await (first, second)
        XCTAssertTrue(a.contains("c001"))
        XCTAssertEqual(b, ["c001", "c002"], "a flush that waited reports what the running one saved too")
        let maxInFlight = await server.maxInFlight
        XCTAssertEqual(maxInFlight, 1)
    }

    func testAMergeDuringAFlushKeepsTheNewerCopy() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue([entry(1, meta: CoachMessageMeta(toolNames: ["A"]))])
        let server = Server(pause: 0.15) { CoachSaveResult(saved: $0.count) }
        async let flushed = outbox.flush(ownerId: owner) { try await server.save($0) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await outbox.enqueue([entry(1, meta: CoachMessageMeta(followUps: ["Next?"]))])
        _ = await flushed
        let all = await outbox.all
        XCTAssertEqual(all.count, 1, "the copy merged while the older one was in flight stays to be sent")
        XCTAssertEqual(all.first?.meta?.followUps, ["Next?"])
        XCTAssertEqual(all.first?.meta?.toolNames, ["A"])
    }

    func testAPurgeWhileAChunkWaitsToRetryKeepsItsCopyFromBeingSent() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil, retryDelays: [0.3])
        await outbox.enqueue([entry(1), entry(2)])
        let server = Server { _ in throw CoachRouteError(status: 503, code: nil) }
        async let flushed = outbox.flush(ownerId: owner) { try await server.save($0) }
        try? await Task.sleep(nanoseconds: 100_000_000)
        // The user deletes the chat while the first attempt's retry is waiting.
        await outbox.purge(threadId: threadA)
        let saved = await flushed
        XCTAssertTrue(saved.isEmpty)
        let batches = await server.batches
        XCTAssertEqual(batches.count, 1, "the chunk taken before the purge is not retried")
        let pending = await outbox.pendingCount
        XCTAssertEqual(pending, 0)
    }

    func testTheReportNamesEachSavedRowsThreadAndTheThreadsTheServerDeleted() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue([entry(1), entry(2, thread: threadB)])
        let deleted = threadB
        let server = Server { rows in
            CoachSaveResult(saved: 1, rejected: rows.filter { $0.threadId == deleted }
                .map { .init(clientId: $0.clientId, reason: "thread_deleted") })
        }
        let report = await outbox.flushReport(ownerId: owner) { try await server.save($0) }
        XCTAssertEqual(report.saved, ["c001": threadA], "rows queued in any session map to their thread")
        XCTAssertEqual(report.deletedThreads, [threadB])
        let all = await outbox.all
        XCTAssertTrue(all.isEmpty)
    }

    func testAnAccountSwitchMidFlushStopsThePassWithTheRestStillQueued() async {
        let outbox = CoachOutbox(ownerId: owner, fileURL: nil)
        await outbox.enqueue((0..<25).map { entry($0) })
        // `saveMessages(_:asOwner:)` throws `.unauthorized` once the live credential is another account's.
        let server = Server { rows in
            if rows.contains(where: { $0.clientId == "c020" }) { throw CoachAPIError.unauthorized }
            return CoachSaveResult(saved: rows.count)
        }
        let saved = await outbox.flush(ownerId: owner) { try await server.save($0) }
        XCTAssertEqual(saved.count, 20)
        let all = await outbox.all
        XCTAssertEqual(all.count, 5)
        XCTAssertFalse(all.contains(where: \.quarantined), "nothing is quarantined: the rows wait for their own account")
    }

    func testARetiredOutboxSendsNothingAndADiscardedOneNeverWritesItsFile() async throws {
        let url = directory.appendingPathComponent("outbox.json")
        let outbox = CoachOutbox(ownerId: owner, fileURL: url)
        await outbox.enqueue([entry(1)])
        await outbox.retire()
        let server = Server { CoachSaveResult(saved: $0.count) }
        let saved = await outbox.flush(ownerId: owner) { try await server.save($0) }
        XCTAssertTrue(saved.isEmpty)
        let batches = await server.batches
        XCTAssertTrue(batches.isEmpty)
        let kept = await CoachOutbox(ownerId: owner, fileURL: url).all
        XCTAssertEqual(kept.count, 1, "a retired outbox keeps its rows on disk")

        try FileManager.default.removeItem(at: url)
        await outbox.discard()
        await outbox.enqueue([entry(2)])
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a signed-out account's outbox is never written again")
    }

    // MARK: Storage

    func testPersistsPerOwnerAndPurgesAThread() async {
        let url = directory.appendingPathComponent("outbox.json")
        let first = CoachOutbox(ownerId: owner, fileURL: url)
        await first.enqueue([entry(1), entry(2, thread: threadB)])
        let reopened = CoachOutbox(ownerId: owner, fileURL: url)
        let count = await reopened.pendingCount
        XCTAssertEqual(count, 2)
        let other = CoachOutbox(ownerId: "22222222-2222-4222-8222-222222222222", fileURL: url)
        let foreign = await other.pendingCount
        XCTAssertEqual(foreign, 0, "a file stamped with another owner is never sent with this credential")

        await reopened.purge(threadId: threadA.uppercased())
        let left = await reopened.pending(threadId: threadB)
        XCTAssertEqual(left.map(\.clientId), ["c002"])
        let gone = await reopened.pending(threadId: threadA)
        XCTAssertTrue(gone.isEmpty)
    }

    func testFileIsCappedAtTwoMegabytes() async throws {
        let url = directory.appendingPathComponent("outbox.json")
        let outbox = CoachOutbox(ownerId: owner, fileURL: url)
        let big = String(repeating: "x", count: 100_000)
        await outbox.enqueue((0..<30).map { entry($0, content: big) })
        let size = try XCTUnwrap(try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int)
        XCTAssertLessThanOrEqual(size, CoachOutbox.byteCap)
        let all = await outbox.all
        XCTAssertEqual(all.last?.clientId, "c029", "the oldest rows go first")
    }
}

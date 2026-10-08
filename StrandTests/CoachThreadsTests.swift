import XCTest
@testable import Strand

/// Thread models and caches (`docs/COACH_MEMORY.md` §7.1): sidebar sections, the fallback title, date parsing,
/// lenient decoding, the launch choice, and the per-owner local store.
final class CoachThreadsTests: XCTestCase {
    private var base: URL!
    private let ownerA = "11111111-1111-4111-8111-111111111111"
    private let ownerB = "22222222-2222-4222-8222-222222222222"

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("coach-threads-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: base)
    }

    private var utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        return c
    }()

    private func thread(_ id: String, at: String, pinned: Bool = false, folder: String? = nil, title: String? = nil) -> CoachThread {
        CoachThread(id: id, title: title ?? id, folderId: folder, pinned: pinned, lastMessageAt: at)
    }

    // MARK: Sections

    func testSectionsRunPinnedThenFoldersThenDateGroups() {
        let now = CoachDates.parse("2026-10-07T12:00:00Z")!
        let threads = [
            thread("a", at: "2026-10-07T09:00:00Z", pinned: true),
            thread("i", at: "2026-10-05T09:00:00Z", pinned: true, folder: "f1"),
            thread("b", at: "2026-10-01T09:00:00Z", folder: "f1"),
            thread("c", at: "2026-10-07T08:00:00Z"),
            thread("h", at: "2026-10-07T07:00:00Z", folder: "gone"),
            thread("d", at: "2026-10-06T20:00:00Z"),
            thread("e", at: "2026-10-04T10:00:00Z"),
            thread("f", at: "2026-09-17T10:00:00Z"),
            thread("g", at: "2026-08-08T10:00:00Z"),
        ]
        let folders = [CoachFolder(id: "f1", name: "Running", sortOrder: 1), CoachFolder(id: "f2", name: "Food", sortOrder: 0)]
        let sections = CoachThreadSections.sections(threads: threads, folders: folders, now: now, calendar: utc)

        XCTAssertEqual(sections.map(\.id), ["pinned", "folder.f2", "folder.f1", "today", "yesterday", "previous7", "previous30", "older"])
        XCTAssertEqual(sections[0].threads.map(\.id), ["a", "i"], "a pinned thread shows only under Pinned, newest first")
        XCTAssertEqual(sections[1].threads.map(\.id), [], "an empty folder still shows")
        XCTAssertEqual(sections[2].threads.map(\.id), ["b"])
        XCTAssertEqual(sections[3].threads.map(\.id), ["c", "h"], "a thread in a folder that no longer exists falls back to its date")
        XCTAssertEqual(sections[4].threads.map(\.id), ["d"])
        XCTAssertEqual(sections[5].threads.map(\.id), ["e"])
        XCTAssertEqual(sections[6].threads.map(\.id), ["f"])
        XCTAssertEqual(sections[7].threads.map(\.id), ["g"])
    }

    func testEmptyDateGroupsAreLeftOut() {
        let now = CoachDates.parse("2026-10-07T12:00:00Z")!
        let sections = CoachThreadSections.sections(threads: [thread("c", at: "2026-10-07T08:00:00Z")], folders: [], now: now, calendar: utc)
        XCTAssertEqual(sections.map(\.id), ["today"])
    }

    // MARK: Titles and dates

    func testFallbackTitleIsTheFirstSixWords() {
        XCTAssertEqual(CoachThreadTitle.fallback(from: "How did I   sleep last night compared with last week?"), "How did I sleep last night")
        XCTAssertEqual(CoachThreadTitle.fallback(from: "Is my HRV ok?"), "Is my HRV ok")
        XCTAssertEqual(CoachThreadTitle.fallback(from: "  \n "), "Photo")
        XCTAssertLessThanOrEqual(CoachThreadTitle.fallback(from: String(repeating: "supercalifragilistic ", count: 6)).count, 60)
    }

    func testDatesParseWithAndWithoutFractionalSeconds() {
        let whole = CoachDates.parse("2026-10-07T12:00:00Z")
        XCTAssertNotNil(whole)
        XCTAssertEqual(CoachDates.parse("2026-10-07T12:00:00.000Z"), whole)
        XCTAssertEqual(CoachDates.parse("2026-10-07T12:00:00+00:00"), whole)
        XCTAssertEqual(CoachDates.parse("2026-10-07T12:00:00.123456+00:00")?.timeIntervalSince(whole!) ?? 0, 0.123, accuracy: 0.001)
        XCTAssertEqual(CoachDates.parse("2026-10-07 12:00:00+00:00"), whole, "Postgres' space separator")
        XCTAssertNil(CoachDates.parse("yesterday"))
        XCTAssertNil(CoachDates.parse(nil))
        XCTAssertEqual(CoachDates.parse(CoachDates.string(whole!)), whole)
    }

    // MARK: Decoding

    func testThreadPageDecodesRowByRow() throws {
        let json = """
        {"threads":[
          {"id":"AAAAAAAA-0000-4000-8000-000000000001","title":"Knee plan","pinned":true,"messageCount":4,"pendingMessages":2,"topics":["injury"]},
          {"title":"no id"},
          {"id":"aaaaaaaa-0000-4000-8000-000000000002","pinned":"yes","messageCount":"many","title":""}
        ],
        "folders":[{"id":"F1","name":"Running"},{"name":"no id"}],
        "hasMore":true,"nextCursor":"abc"}
        """
        let page = try JSONDecoder().decode(CoachThreadPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.threads.map(\.id), ["aaaaaaaa-0000-4000-8000-000000000001", "aaaaaaaa-0000-4000-8000-000000000002"])
        XCTAssertTrue(page.threads[0].pinned)
        XCTAssertEqual(page.threads[0].pendingMessages, 2)
        XCTAssertFalse(page.threads[1].pinned, "a malformed field falls back instead of dropping the row")
        XCTAssertEqual(page.threads[1].messageCount, 0)
        XCTAssertNil(page.threads[1].title)
        XCTAssertEqual(page.folders.map(\.id), ["f1"])
        XCTAssertTrue(page.hasMore)
        XCTAssertEqual(page.nextCursor, "abc")
    }

    func testNeedsMaintenanceDecodesAndFallsBackToPendingMessages() throws {
        let json = """
        {"threads":[{"id":"t1","pendingMessages":2,"needsMaintenance":false},{"id":"t2","pendingMessages":0,"needsMaintenance":true},
                    {"id":"t3","pendingMessages":3},{"id":"t4","pendingMessages":0}]}
        """
        let page = try JSONDecoder().decode(CoachThreadPage.self, from: Data(json.utf8))
        XCTAssertEqual(page.threads.map(\.wantsMaintenance), [false, true, true, false],
                       "the server's flag wins; an older server's pendingMessages is the fallback")
        let cached = try JSONDecoder().decode(CoachThread.self, from: JSONEncoder().encode(page.threads[0]))
        XCTAssertEqual(cached.needsMaintenance, false, "the flag survives the threads.json cache")
    }

    func testMessageMetaDecodesFieldByField() throws {
        let json = #"{"toolNames":["Sleep"],"viz":{"type":"line"},"followUps":["Why?", 3],"blocked":true,"imageContext":"oats"}"#
        let meta = try JSONDecoder().decode(CoachMessageMeta.self, from: Data(json.utf8))
        XCTAssertEqual(meta.toolNames, ["Sleep"])
        XCTAssertEqual(meta.blocked, true)
        XCTAssertEqual(meta.imageContext, "oats")
        XCTAssertNil(meta.followUps, "a malformed list drops alone")
        let merged = CoachMessageMeta(toolNames: ["A"], hadImage: true).merged(with: CoachMessageMeta(followUps: ["Q?"]))
        XCTAssertEqual(merged.toolNames, ["A"])
        XCTAssertEqual(merged.hadImage, true)
        XCTAssertEqual(merged.followUps, ["Q?"])
    }

    // MARK: Launch

    func testLaunchPicksTheNewestThreadOnlyWhenItWasActiveToday() {
        let now = CoachDates.parse("2026-10-07T15:00:00Z")!
        let today = thread("t", at: "2026-10-07T01:00:00Z")
        let older = thread("o", at: "2026-10-06T23:00:00Z")
        XCTAssertEqual(CoachThreadLaunch.pick(threads: [older, today], now: now, calendar: utc)?.id, "t")
        XCTAssertNil(CoachThreadLaunch.pick(threads: [older], now: now, calendar: utc))
        XCTAssertNil(CoachThreadLaunch.pick(threads: [], now: now, calendar: utc))
    }

    // MARK: Local store

    func testLocalStoreRoundTripsEachCache() throws {
        let store = try XCTUnwrap(CoachLocalStore(ownerId: ownerA.uppercased(), base: base))
        XCTAssertEqual(store.root.lastPathComponent, ownerA, "the owner folder is lowercased")
        XCTAssertTrue(store.root.path.hasSuffix("OpenWhoop/Coach/\(ownerA)"))

        let threads = CoachThreadsSnapshot(threads: [thread("aaaaaaaa-0000-4000-8000-000000000001", at: "2026-10-07T01:00:00Z")],
                                           folders: [CoachFolder(id: "f1", name: "Running")], nextCursor: "c",
                                           hasMore: true, features: CoachFeatures(threads: true, context: true))
        store.saveThreads(threads)
        XCTAssertEqual(store.loadThreads()?.threads, threads.threads)
        XCTAssertEqual(store.loadThreads()?.features, CoachFeatures(threads: true, context: true))

        let row = CoachStoredMessage(clientId: "bbbbbbbb-0000-4000-8000-000000000001", role: "user", content: "hi",
                                     meta: CoachMessageMeta(blocked: true), createdAt: "2026-10-07T01:00:00.000Z")
        store.saveMessages([row], threadId: "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(store.loadMessages(threadId: "AAAAAAAA-0000-4000-8000-000000000001"), [row])

        let manifest = CoachContextManifest(memories: [CoachMemory(id: "m1", content: "User runs", topic: "training", importance: 3)],
                                            memoryCount: 1)
        store.saveManifest(manifest, threadId: "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(store.loadManifest(threadId: "aaaaaaaa-0000-4000-8000-000000000001"), manifest)
        XCTAssertEqual(store.latestManifest(), manifest)
        store.updateManifests { $0.removingMemory(id: "m1") }
        XCTAssertEqual(store.loadManifest(threadId: "aaaaaaaa-0000-4000-8000-000000000001")?.memories, [])

        let suggestions = CoachCachedSuggestions(suggestions: [CoachStarterSuggestion(text: "How did I sleep?", kind: .state)],
                                                 day: "2026-10-07", source: "model", savedAt: Date(timeIntervalSince1970: 1))
        store.saveSuggestions(suggestions)
        XCTAssertEqual(store.loadSuggestions(), suggestions)

        store.removeThread(id: "aaaaaaaa-0000-4000-8000-000000000001")
        XCTAssertEqual(store.loadMessages(threadId: "aaaaaaaa-0000-4000-8000-000000000001"), [])
    }

    func testOwnersNeverSeeEachOthersCaches() throws {
        let a = try XCTUnwrap(CoachLocalStore(ownerId: ownerA, base: base))
        let b = try XCTUnwrap(CoachLocalStore(ownerId: ownerB, base: base))
        a.saveThreads(CoachThreadsSnapshot(threads: [thread("aaaaaaaa-0000-4000-8000-000000000001", at: "2026-10-07T01:00:00Z")]))
        a.saveMessages([CoachStoredMessage(clientId: "c1", role: "user", content: "hi", meta: nil, createdAt: "")], threadId: "t1")
        XCTAssertNil(b.loadThreads())
        XCTAssertEqual(b.loadMessages(threadId: "t1"), [])
        XCTAssertNotEqual(a.outboxURL, b.outboxURL)

        CoachLocalStore.removeAll(ownerId: ownerA, base: base)
        XCTAssertNil(a.loadThreads())
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.root.path))
        XCTAssertNil(CoachLocalStore(ownerId: "../escape", base: base), "an owner id can't name a path outside the coach folder")
        XCTAssertNil(CoachLocalStore(ownerId: "", base: base))
    }

    func testLocalStoreKeepsTheNewestSixtyMessagesOfTenThreads() throws {
        let store = try XCTUnwrap(CoachLocalStore(ownerId: ownerA, base: base))
        let rows = (0..<75).map { i in
            CoachStoredMessage(clientId: String(format: "c%03d", i), role: i % 2 == 0 ? "user" : "assistant", content: "m\(i)",
                               meta: nil, createdAt: "")
        }
        store.saveMessages(rows, threadId: "t0")
        let kept = store.loadMessages(threadId: "t0")
        XCTAssertEqual(kept.count, CoachLocalStore.messagesPerThread)
        XCTAssertEqual(kept.first?.content, "m15")
        XCTAssertEqual(kept.last?.content, "m74")

        for i in 1...12 { store.saveMessages(Array(rows.prefix(2)), threadId: "t\(i)") }
        let files = try FileManager.default.contentsOfDirectory(atPath: store.root.appendingPathComponent("messages").path)
        XCTAssertEqual(files.count, CoachLocalStore.threadsWithMessages)
        XCTAssertTrue(files.contains("t12.json"), "the most recently written thread is always kept")
    }

    func testRewritingManifestsKeepsTheNewestOneNewest() throws {
        let store = try XCTUnwrap(CoachLocalStore(ownerId: ownerA, base: base))
        store.saveManifest(CoachContextManifest(memoryCount: 1), threadId: "t1")
        store.saveManifest(CoachContextManifest(memoryCount: 2), threadId: "t2")
        let dir = store.root.appendingPathComponent("manifests")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)],
                                              ofItemAtPath: dir.appendingPathComponent("t1.json").path)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2_000)],
                                              ofItemAtPath: dir.appendingPathComponent("t2.json").path)
        XCTAssertEqual(store.latestManifest()?.memoryCount, 2)
        store.updateManifests { $0.removingMemory(id: "gone") }
        XCTAssertEqual(store.latestManifest()?.memoryCount, 2, "a forget never makes the oldest manifest the newest")
    }

    func testCorruptCacheReadsAsEmpty() throws {
        let store = try XCTUnwrap(CoachLocalStore(ownerId: ownerA, base: base))
        try FileManager.default.createDirectory(at: store.root, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.root.appendingPathComponent("threads.json"))
        XCTAssertNil(store.loadThreads())
    }

    // MARK: Thread store

    @MainActor
    func testThreadStoreTouchesOptimisticallyAndFiltersSearchLocally() throws {
        let local = try XCTUnwrap(CoachLocalStore(ownerId: ownerA, base: base))
        let api = CoachAPI(session: CoachURLProtocolStub.session(), endpoint: { nil }, identity: { nil })
        let store = CoachThreadStore(api: api)
        store.reset(local: local, features: CoachFeatures(threads: true, context: true))
        let id = "aaaaaaaa-0000-4000-8000-000000000009"
        store.touch(id: id, title: "Knee pain after runs", titleSource: "fallback", preview: "My knee hurts", at: Date())
        XCTAssertEqual(store.threads.first?.localOnly, true)
        XCTAssertEqual(store.sections.first?.id, "today")
        store.touch(id: id, title: "Ignored", preview: "Sana's answer", at: Date())
        XCTAssertEqual(store.threads.count, 1)
        XCTAssertEqual(store.threads[0].title, "Knee pain after runs", "a later touch never replaces a title")
        XCTAssertEqual(store.threads[0].messageCount, 2)

        store.query = "KNEE"
        XCTAssertEqual(store.searchResults?.map(\.id), [id])
        store.query = ""
        XCTAssertNil(store.searchResults)

        store.setTitle(id: id, title: "Knee Rehab Plan")
        XCTAssertEqual(store.threads[0].title, "Knee Rehab Plan")
        store.flushWrites()
        XCTAssertEqual(local.loadThreads()?.threads.first?.title, "Knee Rehab Plan", "the list is cached per owner")

        let other = CoachThreadStore(api: api)
        other.reset(local: CoachLocalStore(ownerId: ownerB, base: base), features: CoachFeatures(threads: true, context: true))
        XCTAssertTrue(other.threads.isEmpty)
    }

    /// A store on the URLProtocol stub; `handler` answers every request.
    @MainActor
    private func stubbedStore(_ handler: @escaping (CoachURLProtocolStub.Recorded) -> CoachURLProtocolStub.Reply) throws
        -> (CoachThreadStore, CoachLocalStore, CoachAPI) {
        CoachURLProtocolStub.reset()
        CoachURLProtocolStub.handler = handler
        let owner = ownerA
        let api = CoachURLProtocolStub.api(owner: { owner })
        let local = try XCTUnwrap(CoachLocalStore(ownerId: ownerA, base: base))
        let store = CoachThreadStore(api: api)
        store.reset(local: local, features: CoachFeatures(threads: true, context: true))
        return (store, local, api)
    }

    @MainActor
    func testRefreshKeepsANewThreadWhoseSaveLandedWhileThePageWasInFlight() async throws {
        defer { CoachURLProtocolStub.reset() }
        let (store, _, _) = try stubbedStore { r in
            r.route == "threads" ? .json(["threads": [], "folders": [], "hasMore": false], delay: 0.4) : .json([:])
        }
        let id = "aaaaaaaa-0000-4000-8000-000000000009"
        store.touch(id: id, title: "Knee pain", titleSource: "fallback", preview: "My knee hurts", at: Date().addingTimeInterval(-5))
        let refresh = Task { await store.refresh() }
        try await Task.sleep(nanoseconds: 150_000_000)
        // The first save returns (and clears localOnly) after the server read its list, before the list arrives.
        store.markSaved(id: id)
        await refresh.value
        XCTAssertEqual(store.threads.map(\.id), [id], "the row stays until a page lists it")
    }

    @MainActor
    func testALocalOnlyChatIsDeletedOnTheServerTooAndAFailedDeleteIsRetriedNotRevived() async throws {
        defer { CoachURLProtocolStub.reset() }
        let id = "aaaaaaaa-0000-4000-8000-000000000009"
        final class Status: @unchecked Sendable { var delete = 503 }
        let status = Status()
        // The server has the chat: its first save landed even though the phone never heard back.
        let (store, local, api) = try stubbedStore { r in
            switch (r.method, r.route) {
            case ("DELETE", "threads/\(id)"): return .json(["deleted": true], status: status.delete)
            case ("GET", "threads"): return .json(["threads": [["id": id, "title": "Knee pain", "lastMessageAt": CoachDates.string(Date())]],
                                                   "folders": [], "hasMore": false])
            default: return .json([:])
            }
        }
        store.touch(id: id, title: "Knee pain", titleSource: "fallback", preview: "My knee hurts", at: Date())
        XCTAssertEqual(store.thread(id: id)?.localOnly, true)
        let gone = await store.delete(id: id)
        XCTAssertTrue(gone, "the chat is gone for the user")
        XCTAssertEqual(CoachURLProtocolStub.requests("DELETE", "threads/\(id)").count, 1, "a local-only chat is deleted on the server too")
        XCTAssertEqual(store.pendingDeletes, [id])
        store.touch(id: id, title: nil, preview: "A late answer", at: Date())
        XCTAssertNil(store.thread(id: id), "a deleted chat is never brought back")
        store.flushWrites()
        XCTAssertEqual(local.loadThreads()?.pendingDeletes, [id])

        // The next launch: the server still lists it until the retried DELETE lands.
        let next = CoachThreadStore(api: api)
        next.reset(local: local, features: CoachFeatures(threads: true, context: true))
        await next.refresh()
        XCTAssertNil(next.thread(id: id), "a pending delete is kept out of every page")
        status.delete = 200
        await next.retryPendingDeletes()
        XCTAssertTrue(next.pendingDeletes.isEmpty)
        XCTAssertEqual(CoachURLProtocolStub.requests("DELETE", "threads/\(id)").count, 2)
        next.flushWrites()
        XCTAssertNil(local.loadThreads()?.pendingDeletes)
    }

    @MainActor
    func testTheSidebarsRenameGoesThroughTheHookWhenOneIsSet() async throws {
        let api = CoachAPI(session: CoachURLProtocolStub.session(), endpoint: { nil }, identity: { nil })
        let store = CoachThreadStore(api: api)
        var renamed: [(String, String)] = []
        store.onRename = { renamed.append(($0, $1)) }
        store.requestRename(id: "AAAA", title: "Race prep")
        XCTAssertEqual(renamed.map(\.0), ["aaaa"])
        XCTAssertEqual(renamed.map(\.1), ["Race prep"])
    }

    func testSectionsParseEachDateOnce() {
        // 2,000 threads used to cost seconds per rebuild (two ISO parses per comparison).
        let base = CoachDates.parse("2026-10-07T12:00:00Z")!
        let threads = (0..<2_000).map { i in
            CoachThread(id: String(format: "t%04d", i), lastMessageAt: CoachDates.string(base.addingTimeInterval(Double(-i * 3_600))))
        }
        let started = Date()
        let sections = CoachThreadSections.sections(threads: threads.shuffled(), folders: [], now: base, calendar: utc)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertEqual(sections.flatMap(\.threads).map(\.id), threads.map(\.id), "newest first, as before")
    }
}

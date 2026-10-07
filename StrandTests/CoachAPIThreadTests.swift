import XCTest
@testable import Strand

/// The new `coach` routes as the phone calls them (`docs/COACH_MEMORY.md` §4, §7.1), against a URLProtocol stub on
/// a private session: request shapes, per-route timeouts, lossy decoding, features, an old server answering 404,
/// and the DEBUG environment seam.
final class CoachAPIThreadTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let thread = "aaaaaaaa-0000-4000-8000-00000000000a"
    private var api: CoachAPI!

    override func setUp() {
        super.setUp()
        CoachURLProtocolStub.reset()
        let owner = self.owner
        api = CoachURLProtocolStub.api(owner: { owner })
    }

    override func tearDown() {
        CoachURLProtocolStub.reset()
        super.tearDown()
    }

    private func route(_ answers: [String: CoachURLProtocolStub.Reply]) {
        CoachURLProtocolStub.handler = { request in
            answers["\(request.method) \(request.route)"] ?? CoachURLProtocolStub.Reply(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))
        }
    }

    // MARK: Status and features

    func testStatusReadsFeaturesAndAnOldServerHasNone() async throws {
        route(["GET status": .json(["ok": true, "configured": true, "features": ["threads": 1, "context": 1]])])
        let status = try await api.status()
        XCTAssertEqual(status.features, CoachFeatures(threads: true, context: true))
        XCTAssertTrue(status.ok && status.configured)

        route(["GET status": .json(["ok": true, "configured": true, "dailyCallLimit": 100])])
        let old = try await api.status()
        XCTAssertEqual(old.features, .none)
        let reachable = try await api.isReachable()
        XCTAssertTrue(reachable)

        route(["GET status": .json(["ok": true, "configured": false, "features": ["threads": true, "context": "0"]])])
        let partial = try await api.status()
        XCTAssertEqual(partial.features, CoachFeatures(threads: true, context: false))
    }

    func testAnOldServerAnswers404OnTheNewRoutes() async {
        route([:])
        do {
            _ = try await api.threads()
            XCTFail("expected a 404")
        } catch let error as CoachRouteError {
            XCTAssertEqual(error.status, 404)
            XCTAssertEqual(error.code, "not_found")
            XCTAssertFalse(error.isTransient)
            XCTAssertEqual(error.mapped, .unavailable)
        } catch {
            XCTFail("unexpected \(error)")
        }
        let followUps = try? await api.followUps(threadId: thread, question: "q", answer: "a")
        XCTAssertNil(followUps)
    }

    // MARK: Threads

    func testThreadListSendsPagingAndDecodesLossily() async throws {
        route(["GET threads": .json([
            "threads": [["id": thread.uppercased(), "title": "Knee plan", "pinned": true, "pendingMessages": 3],
                        ["title": "no id"],
                        ["id": "bbbbbbbb-0000-4000-8000-00000000000b", "messageCount": "lots"]],
            "folders": [["id": "f1", "name": "Running", "sortOrder": 2]],
            "hasMore": true, "nextCursor": "next-1",
        ])])
        let page = try await api.threads(limit: 500, cursor: "c0", folderId: "none")
        XCTAssertEqual(page.threads.map(\.id), [thread, "bbbbbbbb-0000-4000-8000-00000000000b"])
        XCTAssertEqual(page.threads[0].pendingMessages, 3)
        XCTAssertEqual(page.folders.first?.sortOrder, 2)
        XCTAssertEqual(page.nextCursor, "next-1")
        let sent = try XCTUnwrap(CoachURLProtocolStub.requests("GET", "threads").first)
        XCTAssertEqual(sent.query, ["limit": "100", "cursor": "c0", "folderId": "none"], "limit is clamped to 100")
        XCTAssertEqual(sent.timeout, CoachAPI.Timeout.standard)
    }

    func testSearchRecordsOnlyWhenAsked() async throws {
        route(["GET threads": .json(["threads": [["id": thread, "title": "Knee plan", "snippet": "my «knee» hurts"]], "query": "knee"])])
        let hits = try await api.searchThreads(query: "knee", record: true)
        XCTAssertEqual(hits.first?.snippet, "my «knee» hurts")
        let sent = try XCTUnwrap(CoachURLProtocolStub.requests("GET", "threads").last)
        XCTAssertEqual(sent.query, ["q": "knee", "record": "1"])
        XCTAssertEqual(sent.timeout, CoachAPI.Timeout.search)
    }

    func testThreadEditsSendOnlyWhatChanged() async throws {
        route(["PATCH threads/\(thread)": .json(["thread": ["id": thread, "title": "Mine", "titleSource": "user"]]),
               "POST threads": .json(["thread": ["id": thread]]),
               "DELETE threads/\(thread)": .json(["deleted": true])])
        let renamed = try await api.updateThread(id: thread.uppercased(), title: "Mine")
        XCTAssertEqual(renamed.titleSource, "user")
        _ = try await api.updateThread(id: thread, folderId: .some(nil))
        _ = try await api.updateThread(id: thread, pinned: true)
        let patches = CoachURLProtocolStub.requests("PATCH", "threads/\(thread)").map(\.json)
        XCTAssertEqual(patches[0] as NSDictionary, ["title": "Mine"])
        XCTAssertTrue(patches[1]["folderId"] is NSNull, "folderId nil takes the thread out of its folder")
        XCTAssertEqual(patches[2] as NSDictionary, ["pinned": true])
        _ = try await api.createThread(id: thread.uppercased(), title: "T")
        XCTAssertEqual(CoachURLProtocolStub.requests("POST", "threads").first?.json["id"] as? String, thread)
        try await api.deleteThread(id: thread)
    }

    func testThreadMessagesPageDecodesAndDropsUnusableRows() async throws {
        route(["GET messages": .json([
            "messages": [
                ["id": 1, "clientId": "cccccccc-0000-4000-8000-000000000001", "threadId": thread.uppercased(), "role": "user",
                 "content": "How did I sleep?", "meta": ["imageContext": "a bed"], "createdAt": "2026-10-07T08:00:00.000Z"],
                ["id": 2, "role": "assistant", "content": "no client id"],
                ["id": 3, "clientId": "cccccccc-0000-4000-8000-000000000003", "role": "assistant", "content": "Well.",
                 "meta": ["viz": "not a visual", "followUps": ["Why so short?"], "blocked": false], "createdAt": "2026-10-07T08:00:01Z"],
            ],
            "hasMore": true, "nextCursor": "cur",
        ])])
        let page = try await api.messages(threadId: thread, limit: 0, cursor: "prev")
        XCTAssertEqual(page.messages.count, 2)
        XCTAssertEqual(page.messages[0].threadId, thread)
        XCTAssertEqual(page.messages[0].meta?.imageContext, "a bed")
        XCTAssertNil(page.messages[1].meta?.viz)
        XCTAssertEqual(page.messages[1].meta?.followUps, ["Why so short?"], "a bad field never drops the rest of the meta")
        XCTAssertTrue(page.hasMore)
        let sent = try XCTUnwrap(CoachURLProtocolStub.requests("GET", "messages").first)
        XCTAssertEqual(sent.query, ["threadId": thread, "limit": "1", "cursor": "prev"])
    }

    func testSaveReportsRejectionsAndRefusalsKeepTheirStatus() async throws {
        route(["POST messages": .json(["saved": 1, "rejected": [["clientId": "c2", "reason": "thread_deleted"]]])])
        let row = CoachStoredMessage(clientId: "c1", role: "user", content: "hi", meta: CoachMessageMeta(blocked: true),
                                     createdAt: "2026-10-07T08:00:00.000Z", threadId: thread, threadTitle: "Hi")
        let result = try await api.saveMessages([row])
        XCTAssertEqual(result.saved, 1)
        XCTAssertEqual(result.rejected, [.init(clientId: "c2", reason: "thread_deleted")])
        let body = try XCTUnwrap(CoachURLProtocolStub.requests("POST", "messages").first?.json["messages"] as? [[String: Any]])
        XCTAssertEqual(body.first?["threadId"] as? String, thread)
        XCTAssertEqual(body.first?["threadTitle"] as? String, "Hi")
        XCTAssertEqual((body.first?["meta"] as? [String: Any])?["blocked"] as? Bool, true)

        route(["POST messages": .json(["error": "thread_deleted"], status: 410)])
        do {
            try await api.saveMessages([row])
            XCTFail("expected a 410")
        } catch let error as CoachRouteError {
            XCTAssertEqual(error.status, 410)
            XCTAssertEqual(error.code, "thread_deleted")
        }

        route(["POST messages": .json(["saved": 1])])
        let legacy = try await api.saveMessages([row])
        XCTAssertEqual(legacy, CoachSaveResult(saved: 1), "an old server's reply has no rejections")
    }

    // MARK: Memory

    func testMemoryListQueryAndLenientRows() async throws {
        route(["GET memories": .json(["memories": [
            ["id": "m1", "content": "User runs", "topic": "training", "importance": 3, "source": "curator", "confirmations": 2, "pinned": false],
            ["id": "m2", "content": "broken"],
        ]])])
        let memories = try await api.memories(query: " knee ", topic: "injury", limit: 500)
        XCTAssertEqual(memories.map(\.id), ["m1"])
        XCTAssertEqual(memories.first?.source, "curator")
        XCTAssertEqual(memories.first?.confirmations, 2)
        XCTAssertEqual(CoachURLProtocolStub.requests("GET", "memories").first?.query, ["q": "knee", "topic": "injury", "limit": "200"])
        _ = try await api.memories()
        XCTAssertEqual(CoachURLProtocolStub.requests("GET", "memories").last?.query, [:], "the default list is unchanged")
    }

    // MARK: Side calls and context

    func testSideCallsAndContextRoutesUseTheirTimeoutsAndShapes() async throws {
        route([
            "POST followups": .json(["followUps": ["What next?", 4], "title": "Sleep Check"]),
            "POST suggestions": .json(["suggestions": [["text": "Plan my week", "kind": "goal"]], "source": "cache"]),
            "POST threads/\(thread)/maintain": .json(["status": "queued"], status: 202),
            "POST threads/\(thread)/title": .json(["title": "Sleep Check", "titleSource": "auto", "generated": true]),
            "POST context": .json(["memories": ["memories": [["id": "m1", "content": "User runs", "topic": "training", "importance": 3]],
                                                "total": 9, "topics": ["training": 9]],
                                   "thread": ["id": thread, "summary": "s", "messageCount": 40, "openLoops": [["text": "book physio"]]],
                                   "library": ["threadCount": 12, "recent": [["id": "x"]], "relevant": [["threadId": "y", "title": "Y"]]],
                                   "openLoops": [["threadId": "z", "title": "Z", "text": "decide"]], "memoryRevision": 4]),
            "POST context/search": .json(["terms": ["knee"], "droppedTerms": [], "totalHits": 3, "months": [["month": "2026-08", "hits": 3]],
                                          "hits": [["threadId": thread, "title": "Knee", "at": "2026-08-14T08:00:00Z", "role": "user", "snippet": "«knee»"]],
                                          "threads": [["threadId": thread, "title": "Knee", "hits": 3, "summary": "Knee rehab"]]]),
            "POST context/thread": .json(["thread": ["id": thread, "title": "Knee", "messageCount": 9],
                                          "messages": [["role": "user", "at": "2026-08-14T08:00:00Z", "content": "My knee hurts"]],
                                          "window": "recent", "hasMore": true, "nextCursor": "k2"]),
            "POST context/recall": .json(["answer": "2026-08-14: User started physio.", "sources": [["threadId": thread, "title": "Knee"]],
                                          "coverage": ["threadsMatched": 5, "threadsExamined": 4, "totalHits": 11, "truncated": true],
                                          "status": "partial"]),
        ])
        let follow = try await api.followUps(threadId: thread, question: "q", answer: "a", asked: ["x"], locale: "en", wantTitle: true)
        XCTAssertEqual(follow.followUps, ["What next?"])
        XCTAssertEqual(follow.title, "Sleep Check")
        let suggestions = try await api.suggestions(state: CoachUserStateSnapshot.make(days: []), fallback: ["A"], refresh: true)
        XCTAssertEqual(suggestions.suggestions.first?.kind, .goal)
        let maintained = try await api.maintain(threadId: thread)
        XCTAssertEqual(maintained.status, "queued")
        let title = try await api.generateTitle(threadId: thread, question: "q")
        XCTAssertEqual(title.title, "Sleep Check")
        let manifest = try await api.context(threadId: thread, question: "knee")
        XCTAssertEqual(manifest.memories.map(\.id), ["m1"])
        XCTAssertEqual(manifest.memoryCount, 9)
        XCTAssertEqual(manifest.memoryTopics, ["training": 9])
        XCTAssertEqual(manifest.thread?.openLoops, ["book physio"])
        XCTAssertEqual(manifest.library.relevant.first?.id, "y")
        XCTAssertEqual(manifest.openLoops.first?.text, "decide")
        XCTAssertEqual(manifest.memoryRevision, 4)
        let search = try await api.contextSearch(query: "knee", days: 90, limit: 20, excludeThreadId: thread.uppercased())
        XCTAssertEqual(search.threads.first?.hits, 3)
        let read = try await api.contextThread(threadId: thread, query: "knee", cursor: "k1")
        XCTAssertEqual(read.nextCursor, "k2")
        let recall = try await api.contextRecall(question: "what have we tried?", keywords: "knee physio", threadId: thread)
        XCTAssertEqual(recall.status, "partial")
        XCTAssertEqual(recall.coverage?.truncated, true)

        func sent(_ route: String) -> CoachURLProtocolStub.Recorded? { CoachURLProtocolStub.requests("POST", route).last }
        XCTAssertEqual(sent("followups")?.timeout, CoachAPI.Timeout.followUps)
        XCTAssertEqual(sent("followups")?.json["wantTitle"] as? Bool, true)
        XCTAssertEqual(sent("followups")?.json["asked"] as? [String], ["x"])
        XCTAssertEqual(sent("suggestions")?.timeout, CoachAPI.Timeout.suggestions)
        XCTAssertEqual(sent("suggestions")?.json["refresh"] as? Bool, true)
        XCTAssertNotNil(sent("suggestions")?.json["state"] as? [String: Any])
        XCTAssertEqual(sent("threads/\(thread)/maintain")?.timeout, CoachAPI.Timeout.maintain)
        XCTAssertEqual(sent("context")?.json["question"] as? String, "knee")
        XCTAssertEqual(sent("context")?.timeout, CoachAPI.Timeout.standard)
        XCTAssertEqual(sent("context/search")?.timeout, CoachAPI.Timeout.search)
        XCTAssertEqual(sent("context/search")?.json["excludeThreadId"] as? String, thread)
        XCTAssertEqual(sent("context/search")?.json["days"] as? Int, 90)
        XCTAssertEqual(sent("context/thread")?.timeout, CoachAPI.Timeout.read)
        XCTAssertEqual(sent("context/thread")?.json["cursor"] as? String, "k1")
        XCTAssertEqual(sent("context/recall")?.timeout, CoachAPI.Timeout.recall)
        XCTAssertEqual(sent("context/recall")?.json["keywords"] as? String, "knee physio")
        XCTAssertEqual(CoachAPI.Timeout.recall, 30)
        XCTAssertEqual(CoachAPI.Timeout.search, 10)
        XCTAssertEqual(CoachAPI.Timeout.followUps, 12)
        XCTAssertEqual(CoachAPI.Timeout.maintain, 10)
        XCTAssertEqual(CoachAPI.Timeout.standard, 15)
    }

    func testToolTextNamesChatsByRefAndUUIDAndSaysAtLeast() throws {
        let search = try JSONDecoder().decode(CoachContextSearchResult.self, from: Data("""
        {"terms":["knee"],"droppedTerms":["run"],"totalHits":40,"months":[{"month":"2026-08","hits":30}],
         "hits":[],"threads":[{"threadId":"\(thread)","title":"Knee plan","lastMessageAt":"2026-08-14T08:00:00Z","hits":6,"summary":"Physio twice a week."}]}
        """.utf8))
        let refs = CoachThreadRefs()
        let text = CoachContextToolText.search(search, query: "knee", currentThreadId: nil, refs: refs, userAge: 30)
        XCTAssertTrue(text.contains("[t1 \(thread)] \"Knee plan\", last 2026-08-14, 6 hits"), text)
        XCTAssertTrue(text.contains("too common to search: run"))
        XCTAssertTrue(text.contains("Results are capped"))
        XCTAssertEqual(refs.resolve("t1"), thread)

        let recall = try JSONDecoder().decode(CoachRecallResult.self, from: Data("""
        {"answer":"2026-08-14: User started physio.","sources":[{"threadId":"\(thread)","title":"Knee plan","at":"2026-08-14T08:00:00Z"}],
         "coverage":{"threadsMatched":5,"threadsExamined":4,"totalHits":11,"truncated":true},"status":"partial"}
        """.utf8))
        let recalled = CoachContextToolText.recall(recall, refs: refs, userAge: 30)
        XCTAssertTrue(recalled.contains("not a reply to copy"))
        XCTAssertTrue(recalled.contains("[t1 \(thread)] \"Knee plan\" (2026-08-14)"))
        XCTAssertTrue(recalled.contains("examined 4 of 5 matching chats"))
        XCTAssertTrue(recalled.contains("say \"at least\""))
        let nothing = try JSONDecoder().decode(CoachRecallResult.self, from: Data(#"{"status":"nothing_found"}"#.utf8))
        XCTAssertEqual(CoachContextToolText.recall(nothing, refs: refs, userAge: 30), "Nothing in earlier chats covers that.")
    }

    // MARK: DEBUG seam

    func testDebugSeamAcceptsOnlyLoopbackHostsAndNoopTokens() {
        #if DEBUG
        let ok = CoachAPI.debugSeam(environment: ["NARA_COACH_URL": "http://127.0.0.1:54321/functions/v1/coach",
                                                  "NARA_COACH_TOKEN": "noop_local", "NARA_COACH_OWNER": owner.uppercased()])
        XCTAssertEqual(ok?.endpoint.host, "127.0.0.1")
        XCTAssertEqual(ok?.identity.ownerId, owner)
        XCTAssertNotNil(CoachAPI.debugSeam(environment: ["NARA_COACH_URL": "http://mac-mini.local:8000/coach", "NARA_COACH_TOKEN": "noop_x"]))
        XCTAssertNotNil(CoachAPI.debugSeam(environment: ["NARA_COACH_URL": "http://localhost:8000/coach", "NARA_COACH_TOKEN": "noop_x"])?.identity.ownerId)
        XCTAssertNil(CoachAPI.debugSeam(environment: ["NARA_COACH_URL": "https://abc.supabase.co/functions/v1/coach", "NARA_COACH_TOKEN": "noop_x"]))
        XCTAssertNil(CoachAPI.debugSeam(environment: ["NARA_COACH_URL": "http://127.0.0.1:54321/coach", "NARA_COACH_TOKEN": "sk_live"]))
        XCTAssertNil(CoachAPI.debugSeam(environment: ["NARA_COACH_URL": "http://127.0.0.1:54321/coach"]))
        XCTAssertNil(CoachAPI.debugSeam(environment: [:]))
        #endif
    }
}

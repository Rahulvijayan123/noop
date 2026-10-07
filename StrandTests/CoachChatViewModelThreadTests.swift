import XCTest
@testable import Strand

/// The thread-aware view model (`docs/COACH_MEMORY.md` §7.3) against a scripted coach on a URLProtocol stub and a
/// temporary cache directory: the launch decision, streaming into the right message by id, the immediate save
/// of the question, titles and follow-ups, refusing to switch while generating, queued prompts, blocked turns,
/// the single-thread behaviour an old server keeps, owner changes and deletion.
final class CoachChatViewModelThreadTests: XCTestCase {
    private let ownerA = "11111111-1111-4111-8111-111111111111"
    private let ownerB = "22222222-2222-4222-8222-222222222222"
    private let thread = "aaaaaaaa-0000-4000-8000-00000000000a"
    private let other = "bbbbbbbb-0000-4000-8000-00000000000b"
    private var base: URL!
    private var owner: OwnerBox!
    private var fake: FakeCoach!

    final class OwnerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _value: String?
        init(_ value: String?) { _value = value }
        var value: String? {
            get { lock.lock(); defer { lock.unlock() }; return _value }
            set { lock.lock(); _value = newValue; lock.unlock() }
        }
    }

    /// A scripted `coach` function.
    final class FakeCoach: @unchecked Sendable {
        var features = true
        var chat: CoachURLProtocolStub.Reply = .sse("Your HRV averaged 52 ms this week.")
        var followUps: [String: Any] = ["followUps": ["How does that compare with last month?", "What should I change this week?"],
                                        "title": "HRV Weekly Check"]
        var followUpsDelay: TimeInterval = 0
        var threadList: [[String: Any]] = []
        /// `threadId|cursor` → page.
        var pages: [String: [String: Any]] = [:]
        var suggestions: [[String: Any]] = []

        func handle(_ r: CoachURLProtocolStub.Recorded) -> CoachURLProtocolStub.Reply {
            let missing = CoachURLProtocolStub.Reply(status: 404, body: Data(#"{"error":"not_found"}"#.utf8))
            switch (r.method, r.route) {
            case ("GET", "status"):
                return .json(features ? ["ok": true, "configured": true, "features": ["threads": 1, "context": 1]]
                                      : ["ok": true, "configured": true])
            case ("POST", "chat"): return chat
            case ("POST", "visual"): return .json(["outcome": "skipped"])
            case ("POST", "messages"): return .json(["saved": (r.json["messages"] as? [Any])?.count ?? 0])
            case ("GET", "memories"): return .json(["memories": [["id": "m1", "content": "User runs", "topic": "training", "importance": 3]]])
            case ("GET", "messages"):
                guard features else { return .json(["messages": []]) }
                let key = (r.query["threadId"] ?? "") + "|" + (r.query["cursor"] ?? "")
                return .json(pages[key] ?? ["messages": [], "hasMore": false])
            default: break
            }
            guard features else { return missing }
            switch (r.method, r.route) {
            case ("GET", "threads"): return .json(["threads": threadList, "folders": [], "hasMore": false])
            case ("POST", "followups"): return .json(followUps, delay: followUpsDelay)
            case ("POST", "suggestions"): return .json(["suggestions": suggestions, "source": "model"])
            case ("POST", "context"):
                return .json(["memories": ["memories": [["id": "m1", "content": "User runs", "topic": "training", "importance": 3]],
                                           "total": 1, "topics": ["training": 1]],
                              "library": ["threadCount": 3, "relevant": []], "openLoops": [], "memoryRevision": 1])
            case ("DELETE", _): return .json(["deleted": true])
            case ("POST", let route) where route.hasSuffix("/maintain"): return .json(["status": "queued"], status: 202)
            default: return missing
            }
        }
    }

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("coach-vm-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        owner = OwnerBox(ownerA)
        fake = FakeCoach()
        CoachURLProtocolStub.reset()
        let fake = self.fake!
        CoachURLProtocolStub.handler = { fake.handle($0) }
    }

    override func tearDownWithError() throws {
        CoachURLProtocolStub.reset()
        try? FileManager.default.removeItem(at: base)
    }

    // MARK: Helpers

    private struct Harness {
        let vm: CoachChatViewModel
        let repo: Repository
        let engine: AICoachEngine
        let profile: ProfileStore
    }

    @MainActor
    private func makeVM(fallbackDelay: TimeInterval = 0.3) -> Harness {
        let box = owner!
        let api = CoachURLProtocolStub.api(owner: { box.value })
        let vm = CoachChatViewModel(api: api, baseDirectory: base, followUpFallbackDelay: fallbackDelay, readsDeviceHistory: false)
        let repo = Repository(deviceId: "test-coach-vm")
        let engine = AICoachEngine(repo: repo)
        let profile = ProfileStore()
        vm.attach(repo: repo, engine: engine, profile: profile)
        return Harness(vm: vm, repo: repo, engine: engine, profile: profile)
    }

    @MainActor
    private func reattach(_ h: Harness) { h.vm.attach(repo: h.repo, engine: h.engine, profile: h.profile) }

    private func client(_ n: Int) -> String { String(format: "cccccccc-0000-4000-8000-%012d", n) }

    private func row(_ n: Int, _ role: String, _ content: String, at date: Date, meta: [String: Any] = [:]) -> [String: Any] {
        ["id": n, "clientId": client(n), "threadId": thread, "role": role, "content": content, "meta": meta,
         "createdAt": CoachDates.string(date)]
    }

    private func stored(_ n: Int, _ role: String, _ content: String, at date: Date) -> CoachStoredMessage {
        CoachStoredMessage(clientId: client(n), role: role, content: content, meta: nil, createdAt: CoachDates.string(date),
                           threadId: thread)
    }

    /// Owner A's caches: one thread last active at `lastActive`, with two cached messages.
    private func seedCache(lastActive: Date, owner: String? = nil) {
        let local = CoachLocalStore(ownerId: owner ?? ownerA, base: base)!
        let t = CoachThread(id: thread, title: "Sleep Check", titleSource: "auto", lastMessageAt: CoachDates.string(lastActive),
                            messageCount: 2)
        local.saveThreads(CoachThreadsSnapshot(threads: [t], features: CoachFeatures(threads: true, context: true)))
        local.saveMessages([stored(1, "user", "How did I sleep?", at: lastActive.addingTimeInterval(-60)),
                            stored(2, "assistant", "You slept 7 h.", at: lastActive)], threadId: thread)
        fake.threadList = [["id": thread, "title": "Sleep Check", "titleSource": "auto",
                            "lastMessageAt": CoachDates.string(lastActive), "messageCount": 2]]
    }

    @MainActor
    private func waitUntil(_ what: String, timeout: TimeInterval = 6, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("timed out waiting for \(what)"); return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private var savedRows: [[String: Any]] {
        CoachURLProtocolStub.requests("POST", "messages").flatMap { ($0.json["messages"] as? [[String: Any]]) ?? [] }
    }

    private var chatRequests: [[String: Any]] {
        CoachURLProtocolStub.requests("POST", "chat").map(\.json).filter { ($0["stream"] as? Bool) == true }
    }

    private func toolNames(_ chat: [String: Any]) -> Set<String> {
        Set(((chat["tools"] as? [[String: Any]]) ?? []).compactMap { ($0["function"] as? [String: Any])?["name"] as? String })
    }

    private func systemPrompt(_ chat: [String: Any]) -> String {
        ((chat["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
    }

    // MARK: Launch

    @MainActor
    func testLaunchReopensTodaysThreadThenMergesTheServerPage() async throws {
        let now = Date()
        seedCache(lastActive: now)
        fake.pages["\(thread)|"] = ["messages": [row(0, "user", "An older question", at: now.addingTimeInterval(-3_600)),
                                                 row(1, "user", "How did I sleep?", at: now.addingTimeInterval(-60)),
                                                 row(2, "assistant", "You slept 7 h.", at: now, meta: ["followUps": ["Why only 7?"]])],
                                    "hasMore": true, "nextCursor": "p2"]
        fake.pages["\(thread)|p2"] = ["messages": [row(9, "assistant", "Oldest answer", at: now.addingTimeInterval(-7_200))], "hasMore": false]
        let h = makeVM()
        let vm = h.vm

        XCTAssertEqual(vm.threadId.uuidString.lowercased(), thread, "today's thread opens on launch")
        XCTAssertEqual(vm.messages.map(\.content), ["How did I sleep?", "You slept 7 h."], "cached messages show at once")
        XCTAssertEqual(vm.threadPhase, .loading)
        XCTAssertEqual(vm.threadTitle, "Sleep Check")

        await vm.start()
        try await waitUntil("the server page") { vm.threadPhase == .ready }
        XCTAssertEqual(vm.messages.map(\.clientId), [client(0), client(1), client(2)])
        XCTAssertTrue(vm.hasEarlier)
        XCTAssertEqual(vm.followUps(for: vm.messages[2]), ["Why only 7?"], "stored follow-ups come back with the answer")

        await vm.loadEarlier()
        XCTAssertEqual(vm.messages.first?.clientId, client(9))
        XCTAssertFalse(vm.hasEarlier)
        XCTAssertEqual(vm.features, CoachFeatures(threads: true, context: true))
    }

    @MainActor
    func testLaunchStartsANewChatWhenTheNewestThreadIsOld() {
        seedCache(lastActive: Date().addingTimeInterval(-3 * 86_400))
        let vm = makeVM().vm
        XCTAssertNotEqual(vm.threadId.uuidString.lowercased(), thread)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertEqual(vm.threadPhase, .ready)
        XCTAssertNil(vm.threadTitle)
        XCTAssertEqual(vm.starterSuggestions.count, CoachStarterSuggestions.limit, "the local set shows straight away")
        XCTAssertEqual(vm.threadStore.threads.map(\.id), [thread], "the sidebar still lists it")
    }

    // MARK: Turns

    @MainActor
    func testANewChatSavesTheQuestionAtOnceThenTitlesAndFollowsUp() async throws {
        let vm = makeVM().vm
        await vm.start()
        XCTAssertTrue(vm.send("How is my HRV trending this month?"))
        XCTAssertEqual(vm.threadTitle, "How is my HRV trending this", "the fallback title shows at send")
        let id = vm.threadId.uuidString.lowercased()

        try await waitUntil("the question to be saved") { savedRows.contains { $0["content"] as? String == "How is my HRV trending this month?" } }
        let first = try XCTUnwrap(savedRows.first)
        XCTAssertEqual(first["threadId"] as? String, id)
        XCTAssertEqual(first["threadTitle"] as? String, "How is my HRV trending this")

        try await waitUntil("the answer") { !vm.isGenerating }
        XCTAssertEqual(vm.messages.map(\.content), ["How is my HRV trending this month?", "Your HRV averaged 52 ms this week."])
        try await waitUntil("the generated title") { vm.threadTitle == "HRV Weekly Check" }
        XCTAssertEqual(vm.followUps(for: vm.messages[1]), ["How does that compare with last month?", "What should I change this week?"])
        XCTAssertEqual(vm.threadStore.thread(id: id)?.title, "HRV Weekly Check")
        XCTAssertEqual(CoachURLProtocolStub.requests("POST", "followups").first?.json["wantTitle"] as? Bool, true)
        try await waitUntil("the answer to be saved") { savedRows.contains { $0["content"] as? String == "Your HRV averaged 52 ms this week." } }
        try await waitUntil("maintain") { !CoachURLProtocolStub.requests("POST", "threads/\(id)/maintain").isEmpty }
        try await waitUntil("the follow-ups to be saved") {
            savedRows.contains { (($0["meta"] as? [String: Any])?["followUps"] as? [String])?.count == 2 }
        }

        let chat = try XCTUnwrap(chatRequests.first)
        XCTAssertTrue(systemPrompt(chat).contains(CoachContextPrompt.libraryHeader))
        XCTAssertTrue(toolNames(chat).isSuperset(of: ["search_conversations", "read_conversation", "recall_context",
                                                      "query_metric_history", "find_days"]))
        XCTAssertFalse(CoachURLProtocolStub.requests("POST", "context").isEmpty, "the turn asked for the manifest")

        await vm.refreshMemories()
        XCTAssertEqual(CoachURLProtocolStub.requests("GET", "memories").last?.query["limit"], "200")
        XCTAssertEqual(vm.memories.map(\.id), ["m1"])
    }

    @MainActor
    func testStreamingLandsInItsOwnMessageWhileOlderMessagesArriveAndSwitchingIsRefused() async throws {
        let now = Date()
        seedCache(lastActive: now)
        fake.pages["\(thread)|"] = ["messages": [row(1, "user", "How did I sleep?", at: now.addingTimeInterval(-60)),
                                                 row(2, "assistant", "You slept 7 h.", at: now)],
                                    "hasMore": true, "nextCursor": "p2"]
        fake.pages["\(thread)|p2"] = ["messages": [row(0, "user", "An older question", at: now.addingTimeInterval(-3_600))], "hasMore": false]
        fake.chat = .sse("Your HRV averaged 52 ms this week.", delay: 0.8)
        let vm = makeVM().vm
        await vm.start()
        try await waitUntil("the server page") { vm.threadPhase == .ready }

        XCTAssertTrue(vm.send("And my HRV?"))
        XCTAssertTrue(vm.isGenerating)
        XCTAssertFalse(vm.canSwitchThreads)
        XCTAssertFalse(vm.threadStore.canSwitchThreads)
        let open = vm.threadId
        vm.newChat()
        XCTAssertEqual(vm.threadId, open, "no new chat while a reply streams")
        await vm.open(CoachThread(id: other))
        XCTAssertEqual(vm.threadId, open, "no switching while a reply streams")
        XCTAssertFalse(vm.send("A second question"))

        await vm.loadEarlier()
        XCTAssertEqual(vm.messages.first?.content, "An older question", "an older page lands in front mid-stream")

        try await waitUntil("the answer") { !vm.isGenerating }
        XCTAssertEqual(vm.messages.map(\.content), ["An older question", "How did I sleep?", "You slept 7 h.", "And my HRV?",
                                                    "Your HRV averaged 52 ms this week."])
        XCTAssertTrue(vm.canSwitchThreads)
        try await waitUntil("the follow-ups request") { !CoachURLProtocolStub.requests("POST", "followups").isEmpty }
        XCTAssertNil(CoachURLProtocolStub.requests("POST", "followups").first?.json["wantTitle"],
                     "only a thread's first answer asks for a title")
        let history = (chatRequests.first?["messages"] as? [[String: Any]])?.compactMap { $0["content"] as? String } ?? []
        XCTAssertEqual(Array(history.suffix(3)), ["How did I sleep?", "You slept 7 h.", "And my HRV?"])
    }

    @MainActor
    func testAQueuedPromptWaitsForTheReplyThenGoesToANewChat() async throws {
        fake.chat = .sse("Your HRV averaged 52 ms this week.", delay: 0.5)
        let vm = makeVM().vm
        await vm.start()
        XCTAssertTrue(vm.send("First question about HRV?"))
        let first = vm.threadId
        XCTAssertTrue(vm.queuePrompt("Plan my training week"))
        XCTAssertEqual(vm.messages.first?.content, "First question about HRV?", "the running reply is not interrupted")

        try await waitUntil("the queued prompt") { vm.threadId != first && vm.messages.first?.content == "Plan my training week" }
        try await waitUntil("its answer") { !vm.isGenerating }
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertTrue(savedRows.contains { $0["threadId"] as? String == first.uuidString.lowercased() && $0["role"] as? String == "assistant" },
                      "the first chat's answer was still saved")
        XCTAssertFalse(vm.queuePrompt("   "))
    }

    @MainActor
    func testABlockedTurnIsStoredAsBlockedAndGetsNoFollowUps() async throws {
        let vm = makeVM().vm
        await vm.start()
        XCTAssertTrue(vm.send("I want to kill myself"))
        XCTAssertFalse(vm.isGenerating)
        XCTAssertEqual(vm.messages.count, 2)
        XCTAssertTrue(vm.messages.allSatisfy(\.blocked))
        XCTAssertTrue(vm.messages[1].content.contains("988"))
        XCTAssertEqual(vm.followUps(for: vm.messages[1]), [])
        try await waitUntil("both rows saved") { savedRows.count == 2 }
        XCTAssertTrue(savedRows.allSatisfy { ($0["meta"] as? [String: Any])?["blocked"] as? Bool == true })
        XCTAssertTrue(chatRequests.isEmpty, "a refused question never reaches the model")
    }

    @MainActor
    func testFollowUpFallbackAppearsOnlyAfterTheTimeout() async throws {
        fake.followUpsDelay = 3
        let vm = makeVM(fallbackDelay: 0.3).vm
        await vm.start()
        vm.send("How did I sleep this week?")
        try await waitUntil("the answer") { !vm.isGenerating }
        let answer = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(vm.followUps(for: answer), [], "nothing while the model's follow-ups are on their way")
        try await waitUntil("the fallback") { !vm.followUps(for: answer).isEmpty }
        XCTAssertEqual(vm.followUps(for: answer), CoachFollowUps.forAnswer(answer.content))
    }

    // MARK: Old server

    @MainActor
    func testAnOldServerKeepsTheSingleThreadBehaviour() async throws {
        fake.features = false
        let vm = makeVM().vm
        await vm.start()
        XCTAssertEqual(vm.features, .none)
        XCTAssertTrue(vm.send("How did I sleep?"))
        try await waitUntil("the answer") { !vm.isGenerating }
        try await waitUntil("the answer to be saved") { savedRows.count == 2 }

        let chat = try XCTUnwrap(chatRequests.first)
        XCTAssertFalse(systemPrompt(chat).contains(CoachContextPrompt.libraryHeader))
        XCTAssertTrue(systemPrompt(chat).contains("REMEMBERED CONTEXT (from previous sessions):\n• [training] User runs"))
        XCTAssertTrue(toolNames(chat).isDisjoint(with: ["search_conversations", "read_conversation", "recall_context",
                                                        "query_metric_history", "find_days"]))
        let answer = try XCTUnwrap(vm.messages.last)
        XCTAssertEqual(vm.followUps(for: answer), CoachFollowUps.forAnswer(answer.content), "the keyword pills show at once")
        try await Task.sleep(nanoseconds: 300_000_000)
        let routes = Set(CoachURLProtocolStub.requests.map(\.route))
        for route in ["followups", "suggestions", "context", "threads"] { XCTAssertFalse(routes.contains(route), route) }
        XCTAssertFalse(routes.contains { $0.hasSuffix("/maintain") })
        XCTAssertNil(vm.threadTitle, "an old server has no titles")
        XCTAssertNil(CoachLocalStore(ownerId: ownerA, base: base)?.loadThreads(), "no thread list is cached for an old server")
    }

    // MARK: Owner and deletion

    @MainActor
    func testAnotherAccountSigningInResetsEverything() async throws {
        seedCache(lastActive: Date())
        let h = makeVM()
        XCTAssertEqual(h.vm.messages.count, 2)
        XCTAssertEqual(h.vm.threadStore.threads.count, 1)
        owner.value = ownerB
        reattach(h)
        XCTAssertTrue(h.vm.messages.isEmpty, "B never sees A's chat")
        XCTAssertTrue(h.vm.threadStore.threads.isEmpty)
        XCTAssertNotEqual(h.vm.threadId.uuidString.lowercased(), thread)
        owner.value = ownerA
        reattach(h)
        XCTAssertEqual(h.vm.threadId.uuidString.lowercased(), thread, "A's own caches come back with A")
    }

    @MainActor
    func testDeletingTheOpenThreadStartsANewChatAndRemovesItEverywhere() async throws {
        let now = Date()
        seedCache(lastActive: now)
        fake.pages["\(thread)|"] = ["messages": [row(1, "user", "How did I sleep?", at: now.addingTimeInterval(-60))], "hasMore": false]
        let vm = makeVM().vm
        await vm.start()
        try await waitUntil("the server page") { vm.threadPhase == .ready }
        await vm.deleteThread(id: thread.uppercased())
        XCTAssertNotEqual(vm.threadId.uuidString.lowercased(), thread)
        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertNil(vm.threadStore.thread(id: thread))
        XCTAssertFalse(CoachURLProtocolStub.requests("DELETE", "threads/\(thread)").isEmpty)
        XCTAssertEqual(CoachLocalStore(ownerId: ownerA, base: base)?.loadMessages(threadId: thread), [])
    }

    // MARK: Starter suggestions

    @MainActor
    func testTheServerSetReplacesTheLocalOneWhenItArrivesInTime() async throws {
        seedCache(lastActive: Date().addingTimeInterval(-3 * 86_400))
        fake.suggestions = [["text": "Pick up my sleep plan", "kind": "continue", "threadId": thread],
                            ["text": "Plan a lighter week", "kind": "state"]]
        let vm = makeVM().vm
        await vm.start()
        try await waitUntil("the server set") { vm.starterSuggestions.first?.text == "Pick up my sleep plan" }
        XCTAssertEqual(vm.starterSuggestions.first?.kind, .continue)
        XCTAssertEqual(vm.starterSuggestions.first?.threadId, thread)
        XCTAssertEqual(vm.starterSuggestions.count, CoachStarterSuggestions.limit)
        XCTAssertEqual(CoachLocalStore(ownerId: ownerA, base: base)?.loadSuggestions()?.suggestions.first?.text, "Pick up my sleep plan")
        let state = CoachURLProtocolStub.requests("POST", "suggestions").first?.json["state"] as? [String: Any]
        XCTAssertNotNil(state?["dayPart"])
    }
}

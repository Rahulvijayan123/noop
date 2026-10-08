import XCTest
@testable import Strand

/// "Ask Sana" from another screen (`docs/COACH_MEMORY.md` §7.4, "Screen handoff"): the handoff's own trimming, the
/// `screenContext` meta field (lossy decode, merge, never written when absent), the prompt block (an empty context
/// leaves both system prompts byte-identical) and its leak marker. The view model's side is in
/// `CoachChatViewModelThreadTests`.
final class CoachScreenHandoffTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_791_374_400)  // 2026-10-07 12:00 UTC
    private let context = """
    Screen: Heart rate variability, RMSSD side. Showing the last 30 nights.
    Last night (Tue 6 Oct 2026): 48 ms, within the usual range of 42–61 ms.
    """

    // MARK: Handoff

    func testTheHandoffTrimsAndCapsWhatItCarries() {
        let long = String(repeating: "a", count: CoachHandoff.contextCap + 50)
        let h = CoachHandoff(prompt: "  Help me understand my HRV.\n", screenContext: "\n" + long, memory: "   ")
        XCTAssertEqual(h.prompt, "Help me understand my HRV.")
        XCTAssertEqual(h.screenContext.count, CoachHandoff.contextCap)
        XCTAssertNil(h.memory, "a blank memory saves nothing")
        let note = CoachHandoff(prompt: "Q", screenContext: "", memory: String(repeating: "b", count: 600))
        XCTAssertEqual(note.memory?.count, CoachHandoff.memoryCap, "the server refuses a memory over 500 characters")
    }

    // MARK: Meta

    func testScreenContextRoundTripsAndAnOldRowEncodesExactlyAsBefore() throws {
        let meta = CoachMessageMeta(hadImage: true, screenContext: context)
        let decoded = try JSONDecoder().decode(CoachMessageMeta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(decoded, meta)

        let old = CoachMessageMeta(toolNames: ["Sleep"], followUps: ["Why?"])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        XCTAssertNil(json["screenContext"], "a message without a screen writes no key")
    }

    func testAMalformedScreenContextCostsOnlyItself() throws {
        let data = Data(#"{"toolNames":["Sleep"],"screenContext":42,"imageContext":"Oats"}"#.utf8)
        let meta = try JSONDecoder().decode(CoachMessageMeta.self, from: data)
        XCTAssertNil(meta.screenContext)
        XCTAssertEqual(meta.toolNames, ["Sleep"])
        XCTAssertEqual(meta.imageContext, "Oats")
    }

    func testAReSaveWithoutTheScreenKeepsIt() {
        let first = CoachMessageMeta(screenContext: context)
        XCTAssertEqual(first.merged(with: CoachMessageMeta(followUps: ["Next?"])).screenContext, context)
        XCTAssertEqual(first.merged(with: CoachMessageMeta(screenContext: "Newer")).screenContext, "Newer")
    }

    func testAStoredQuestionBringsItsScreenBackAndTheServerCopyKeepsIt() {
        let id = UUID()
        let row = CoachStoredMessage(clientId: id.uuidString.lowercased(), role: "user", content: "Help me understand my HRV.",
                                     meta: CoachMessageMeta(screenContext: context), createdAt: CoachDates.string(now),
                                     threadId: "aaaaaaaa-0000-4000-8000-00000000000a")
        let restored = CoachChatMessage(stored: row)
        XCTAssertEqual(restored?.screenContext, context)
        XCTAssertEqual(restored?.meta.screenContext, context)

        var local = CoachChatMessage(id: id, role: .user, content: "Help me understand my HRV.")
        local.screenContext = context
        let server = CoachChatMessage(id: id, role: .user, content: "Help me understand my HRV.")
        XCTAssertEqual(local.merged(withServer: server).screenContext, context, "a server row without it never blanks it")
    }

    // MARK: Prompt

    func testAnEmptyScreenLeavesBothPromptsByteIdentical() {
        let memories = [CoachMemory(id: "m1", content: "User runs", topic: "training", importance: 3)]
        XCTAssertEqual(CoachPrompt.system(memories: memories, imageContext: "Oats", screenContext: "", userAge: 30, now: now),
                       CoachPrompt.system(memories: memories, imageContext: "Oats", userAge: 30, now: now))
        let turn = CoachTurnContext(manifest: nil, memories: memories, messageCount: 0, isFirstTurn: true)
        XCTAssertEqual(CoachPrompt.system(context: turn, imageContext: "", screenContext: "", userAge: 30, now: now),
                       CoachPrompt.system(context: turn, imageContext: "", userAge: 30, now: now))
    }

    func testTheScreenBlockComesAfterTheContextAndBeforeThePhoto() throws {
        let memories = [CoachMemory(id: "m1", content: "User runs", topic: "training", importance: 3)]
        let block = CoachPrompt.screenBlock(context)
        XCTAssertTrue(block.hasPrefix("SCREEN CONTEXT: The user opened this chat from a screen in the app."))
        XCTAssertTrue(block.contains(context))

        let single = CoachPrompt.system(memories: memories, imageContext: "Oats", screenContext: context, userAge: 30, now: now)
        let remembered = try XCTUnwrap(single.range(of: "REMEMBERED CONTEXT"))
        let screen = try XCTUnwrap(single.range(of: block))
        let image = try XCTUnwrap(single.range(of: "IMAGE CONTEXT:"))
        XCTAssertTrue(remembered.lowerBound < screen.lowerBound && screen.upperBound < image.lowerBound)

        let turn = CoachTurnContext(manifest: nil, memories: memories, messageCount: 0, isFirstTurn: true)
        let threaded = CoachPrompt.system(context: turn, imageContext: "", screenContext: context, userAge: 30, now: now)
        XCTAssertTrue(threaded.hasSuffix(block))
    }

    func testAReplyThatEchoesTheScreenBlockIsCaught() {
        let leak = "Sure. The user opened this chat from a screen in the app, and it showed 48 ms."
        XCTAssertFalse(CoachSafety.screenOutput(leak, userAge: 30).clean)
        XCTAssertTrue(CoachSafety.screenStored(leak))
        XCTAssertTrue(CoachSafety.screenOutput("Your HRV last night was 48 ms, inside your usual range.", userAge: 30).clean)
    }
}

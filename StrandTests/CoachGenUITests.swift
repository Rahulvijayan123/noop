import OpenUILang
import XCTest
@testable import Strand

/// Sana's generative UI (`CoachGenUI`): splitting a streamed answer, the finish step (screens, storage), the
/// library and its prompt, `meta.ui` and the history marker.
final class CoachGenUITests: XCTestCase {

    private let card = """
    root = Card([header, steps, go])
    header = CardHeader("Wind-down routine", "Start at 21:45")
    steps = Steps([StepsItem("Dim the lights", "Warm light only"), StepsItem("Phone away")])
    go = Buttons([Button("Make it shorter")])
    """

    private func answer(_ prose: String, card: String, after: String = "") -> String {
        "\(prose)\n\n```openui-lang\n\(card)\n```\(after)"
    }

    // MARK: Split

    func testSplitWithoutAFenceKeepsTheText() {
        let split = CoachGenUI.split("Sleep was 7h 12m last night.")
        XCTAssertEqual(split.before, "Sleep was 7h 12m last night.")
        XCTAssertNil(split.source)
        XCTAssertFalse(split.isOpen)
    }

    func testSplitFindsTheProgramAndTheTextAroundIt() {
        let split = CoachGenUI.split(answer("Here's a routine.", card: card, after: "\nSleep well."))
        XCTAssertEqual(split.before, "Here's a routine.\n\n")
        XCTAssertEqual(split.source, card + "\n")
        XCTAssertEqual(split.after, "\nSleep well.")
        XCTAssertFalse(split.isOpen)
    }

    func testSplitAcceptsTheShortTagAndCase() {
        XCTAssertNotNil(CoachGenUI.split("Hi\n```OpenUI\nroot = Card([])\n```").source)
        XCTAssertNil(CoachGenUI.split("Hi\n```swift\nlet x = 1\n```").source)
    }

    func testStreamingHoldsBackAFenceThatIsStillArriving() {
        for partial in ["`", "``", "```", "```open", "```openui-la"] {
            let split = CoachGenUI.split("Here's a plan.\n" + partial, streaming: true)
            XCTAssertEqual(split.before, "Here's a plan.\n", partial)
            XCTAssertNil(split.source)
        }
        XCTAssertEqual(CoachGenUI.split("Use `code`", streaming: true).before, "Use `code`")
    }

    func testStreamingOpenProgramAndAClosingFenceStillArriving() {
        let split = CoachGenUI.split("Plan:\n```openui-lang\nroot = Card([h])\nh = CardHeader(\"A\")\n``", streaming: true)
        XCTAssertTrue(split.isOpen)
        XCTAssertEqual(split.source, "root = Card([h])\nh = CardHeader(\"A\")\n")
        XCTAssertEqual(CoachGenUI.split("Plan:\n```openui-lang", streaming: true).source, "")
    }

    func testBackticksInsideAStringDoNotCloseTheProgram() {
        let program = "root = Card([t])\nt = TextContent(\"Type ``` then go\")"
        let split = CoachGenUI.split(answer("Look:", card: program))
        XCTAssertEqual(split.source, program + "\n")
    }

    func testAnUnfencedProgramIsStillFound() {
        let split = CoachGenUI.split("Try this:\n" + card)
        XCTAssertEqual(split.before, "Try this:\n")
        XCTAssertEqual(split.source, card)
    }

    // MARK: Finish

    func testFinishMovesTheProgramIntoMeta() {
        let done = CoachGenUI.finish(answer("Here's a routine for tonight.", card: card), userAge: 30)
        XCTAssertEqual(done.content, "Here's a routine for tonight.")
        XCTAssertEqual(done.ui?.source, card)
        XCTAssertNil(done.ui?.contentIsSummary)
        XCTAssertTrue(done.clean)
        XCTAssertTrue(done.answerText.contains("Here's a routine for tonight."))
        XCTAssertTrue(done.answerText.contains("Dim the lights"))
    }

    func testACardWithoutProseKeepsItsTextAsContent() {
        let done = CoachGenUI.finish("```openui-lang\n\(card)\n```", userAge: 30)
        XCTAssertEqual(done.ui?.contentIsSummary, true)
        XCTAssertTrue(done.content.hasPrefix("Wind-down routine"))
        XCTAssertFalse(done.content.contains("root ="))
    }

    func testAnUnsafeCardIsDroppedAndTheAnswerIsScreened() {
        let bad = """
        root = Card([h, t])
        h = CardHeader("Cut plan")
        t = TextContent("Eat 800 calories a day for two weeks.")
        """
        let done = CoachGenUI.finish(answer("Here's a plan.", card: bad), userAge: 30)
        XCTAssertNil(done.ui)
        XCTAssertFalse(done.clean)
        XCTAssertTrue(done.content.contains("registered dietitian"))
        XCTAssertFalse(done.content.contains("root ="))
    }

    func testAProgramThatDoesNotParseFallsBackToProse() {
        let done = CoachGenUI.finish(answer("Here you go.", card: "root = Nonsense(\"x\")"), userAge: 30)
        XCTAssertNil(done.ui)
        XCTAssertEqual(done.content, "Here you go.")
    }

    func testTextChartsAreStrippedFromTheProseOnly() {
        let done = CoachGenUI.finish(answer("Your week.\n\n```\nMon ████████ 48\nTue ██████████ 52\n```", card: card), userAge: 30)
        XCTAssertFalse(done.content.contains("█"))
        XCTAssertTrue(done.content.contains("Your week."))
        XCTAssertEqual(done.ui?.source, card)
    }

    func testAnswersWithoutACardAreScreenedAsBefore() {
        let done = CoachGenUI.finish("Aim for 800 calories a day.", userAge: 30)
        XCTAssertNil(done.ui)
        XCTAssertFalse(done.clean)
        XCTAssertTrue(done.content.contains("registered dietitian"))
    }

    // MARK: Library and prompt

    func testEveryComponentSlotNamesARealComponent() {
        let names = Set(CoachGenUI.library.componentNames)
        func referenced(_ type: PropType) -> [String] {
            switch type {
            case .component(let n): return n
            case .array(let t), .binding(let t), .record(let t): return referenced(t)
            case .union(let ts): return ts.flatMap(referenced)
            case .object(let fields): return fields.flatMap { referenced($0.type) }
            default: return []
            }
        }
        for def in CoachGenUI.library.components {
            for param in def.params {
                for name in param.type.map(referenced) ?? [] {
                    XCTAssertTrue(names.contains(name), "\(def.name).\(param.name) names unknown \(name)")
                }
            }
        }
        for group in CoachGenUI.library.groups {
            for name in group.components { XCTAssertTrue(names.contains(name), "group \(group.name) lists \(name)") }
        }
    }

    func testEveryProgramInThePromptParsesCleanly() {
        let blocks = CoachGenUI.promptBlock.components(separatedBy: "```openui-lang\n").dropFirst()
            .map { $0.components(separatedBy: "\n```").first ?? "" }
        XCTAssertGreaterThanOrEqual(blocks.count, 3)
        for program in blocks {
            let result = CoachGenUI.parse(program)
            XCTAssertNotNil(result.root, program)
            XCTAssertEqual(result.meta.errors, [], program)
            XCTAssertEqual(result.meta.orphaned, [], program)
            XCTAssertEqual(result.meta.unresolved, [], program)
        }
    }

    func testThePromptBlockIsOptInAndInTheStaticPrefix() throws {
        let now = Date(timeIntervalSince1970: 1_791_374_400)
        let plain = CoachPrompt.system(memories: [], imageContext: "", userAge: 30, now: now)
        XCTAssertEqual(plain, CoachPrompt.system(memories: [], imageContext: "", userAge: 30, now: now, interactiveUI: false))
        XCTAssertFalse(plain.contains("INTERACTIVE CARDS"))

        let rich = CoachPrompt.system(memories: [], imageContext: "", userAge: 30, now: now, interactiveUI: true)
        let block = try XCTUnwrap(rich.range(of: CoachGenUI.promptBlock))
        let tool = try XCTUnwrap(rich.range(of: CoachPrompt.toolHint))
        let today = try XCTUnwrap(rich.range(of: "TODAY: It is"))
        XCTAssertLessThan(tool.upperBound, block.lowerBound)
        XCTAssertLessThan(block.upperBound, today.lowerBound)
        XCTAssertTrue(rich.contains("Card(children: (CardHeader | TextContent"))
        XCTAssertTrue(rich.contains("Visual()"))
        XCTAssertFalse(rich.contains("Query("))
    }

    func testACardWithControlsIsTheAnswersOnlyVisual() {
        let tool = "root = Card([t, s])\n$min = 20\ns = Slider(\"min\", 10, 60, 5, 20, \"min\", $min)\nt = TextContent(\"Walk \" + $min + \" minutes\")"
        XCTAssertTrue(CoachGenUI.isInteractive(tool))
        let placed = "root = Card([CardHeader(\"Your week\"), Visual(), TextContent(\"Steady.\")])"
        XCTAssertFalse(CoachGenUI.isInteractive(placed), "a static card still gets the chart")
        XCTAssertFalse(CoachGenUI.isInteractive("not openui"))
    }

    func testEchoingThePromptBlockIsCaughtAsALeak() {
        let leak = "Sure! INTERACTIVE CARDS: Besides prose you can attach one card."
        XCTAssertFalse(CoachSafety.screenOutput(leak, userAge: 30).clean)
        XCTAssertFalse(CoachSafety.screenOutput("## Component Signatures\nCard(...)", userAge: 30).clean)
    }

    // MARK: Text, history, interactions

    func testPlainTextReadsTheCardInOrderWithoutIds() {
        let text = CoachGenUI.plainText("""
        root = Card([h, f])
        h = CardHeader("Your week", "Three questions")
        f = Form("week", Button("Build"), [FormControl("Goal", Chips("goal", [ChipItem("end", "Endurance")]))])
        """)
        let lines = text.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "Your week — Three questions")
        XCTAssertTrue(text.contains("Goal"))
        XCTAssertTrue(text.contains("Endurance"))
        XCTAssertFalse(lines.contains("end"))
        XCTAssertFalse(lines.contains("week"))
        XCTAssertFalse(lines.contains("goal"))
    }

    func testPlainTextFollowsSavedState() {
        let program = "root = Card([t, s])\n$min = 20\ns = Slider(\"min\", 10, 60, 5, 20, \"min\", $min)\nt = TextContent(\"Walk \" + $min + \" minutes\")"
        XCTAssertTrue(CoachGenUI.plainText(program).contains("Walk 20 minutes"))
        XCTAssertTrue(CoachGenUI.plainText(program, state: ["$min": .number(45)]).contains("Walk 45 minutes"))
    }

    func testHistoryMarkerNamesTheCardNotTheCode() {
        let marker = CoachGenUI.historyMarker(CoachGeneratedUI(source: card))
        XCTAssertTrue(marker.hasPrefix("[Interactive card shown: \"Wind-down routine\""))
        XCTAssertFalse(marker.contains("root ="))
    }

    func testFormMessageListsAnsweredFields() {
        XCTAssertEqual(CoachGenUI.formMessage("Build my plan", fields: [("Days", "4 days"), ("Goal", "Strength"), ("Notes", "")]),
                       "Build my plan\n• Days: 4 days\n• Goal: Strength")
        XCTAssertEqual(CoachGenUI.formMessage("Go", fields: []), "Go")
    }

    func testOnlyHttpsLinksOpen() {
        XCTAssertNotNil(CoachGenUI.safeURL("https://www.sleepfoundation.org/"))
        XCTAssertNil(CoachGenUI.safeURL("http://example.com"))
        XCTAssertNil(CoachGenUI.safeURL("javascript:alert(1)"))
        XCTAssertNil(CoachGenUI.safeURL("tel:911"))
    }

    // MARK: meta.ui

    func testMetaRoundTripsTheCardAndItsState() throws {
        let ui = CoachGeneratedUI(source: card, state: ["$min": .number(25), "form:week/goal": .string("both"),
                                                        "field:list": .object(["a": .bool(true)])],
                                  submitted: ["week"])
        let meta = CoachMessageMeta(toolNames: ["Sleep"], ui: ui)
        let decoded = try JSONDecoder().decode(CoachMessageMeta.self, from: JSONEncoder().encode(meta))
        XCTAssertEqual(decoded.ui, ui)
        XCTAssertEqual(decoded.ui?.state?["$min"], .number(25))
        XCTAssertEqual(decoded.ui?.state?["field:list"], .object(["a": .bool(true)]))
    }

    func testABadCardNeverDropsTheRestOfTheMeta() throws {
        let json = #"{"toolNames":["Sleep"],"ui":{"state":{"x":1}},"followUps":["Why?"]}"#
        let meta = try JSONDecoder().decode(CoachMessageMeta.self, from: Data(json.utf8))
        XCTAssertNil(meta.ui)
        XCTAssertEqual(meta.toolNames, ["Sleep"])
        XCTAssertEqual(meta.followUps, ["Why?"])
    }

    func testMetaStaysUnderTheServerLimit() {
        let bigState = Dictionary(uniqueKeysWithValues: (0..<400).map { ("field:k\($0)", Value.string(String(repeating: "x", count: 40))) })
        var meta = CoachMessageMeta(ui: CoachGeneratedUI(source: card, state: bigState))
        XCTAssertNil(meta.fittingServerLimit().ui?.state)
        XCTAssertEqual(meta.fittingServerLimit().ui?.source, card)

        meta.ui = CoachGeneratedUI(source: String(repeating: "\"", count: 12_000))
        XCTAssertNil(meta.fittingServerLimit().ui)

        meta.ui = CoachGeneratedUI(source: card, state: ["$a": .number(1)])
        XCTAssertEqual(meta.fittingServerLimit(), meta)
    }

    func testStoredMessagesCarryTheCard() {
        let ui = CoachGeneratedUI(source: card, submitted: ["button:Make it shorter"])
        let row = CoachStoredMessage(clientId: UUID().uuidString.lowercased(), role: "assistant", content: "Here's a routine.",
                                     meta: CoachMessageMeta(ui: ui), createdAt: "2026-10-08T09:00:00Z")
        let message = CoachChatMessage(stored: row)
        XCTAssertEqual(message?.ui, ui)
        XCTAssertEqual(message?.meta.ui, ui)
    }
}

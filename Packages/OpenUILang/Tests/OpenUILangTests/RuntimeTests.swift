import XCTest
@testable import OpenUILang

/// Typed validation, evaluation, actions and state: upstream's `materialize.validation.test.ts` behaviours
/// this port keeps, plus the lenient coercions it adds on purpose.
final class RuntimeTests: XCTestCase {
    let lib = Library(components: [
        ComponentDef("Card", [ParamDef("children", .array(.component(["Text", "Button", "Slider", "Row"])), required: true)]),
        ComponentDef("Text", [ParamDef("text", .string, required: true), ParamDef("size", .literal(["small", "large"]))]),
        ComponentDef("Row", [ParamDef("label", .string, required: true), ParamDef("value", .number)]),
        ComponentDef("Button", [ParamDef("label", .string, required: true), ParamDef("action", .action),
                                ParamDef("variant", .literal(["primary", "secondary"]), defaultValue: .string("primary"))]),
        ComponentDef("Slider", [ParamDef("name", .string, required: true), ParamDef("min", .number), ParamDef("max", .number),
                                ParamDef("value", .binding(.number))]),
        ComponentDef("Info", [ParamDef("info", .object([.init("author", .string, required: true), .init("views", .number)]))]),
    ], root: "Card")

    func root(_ src: String) -> Element? { parse(src, library: lib).root }

    // MARK: validation

    func testObjectRequiredKeysAndPaths() {
        XCTAssertTrue(parse(#"root = Info({author: "ann", views: 3})"#, library: lib).meta.errors.isEmpty)
        let missing = parse("root = Info({views: 3})", library: lib).meta.errors.first
        XCTAssertEqual(missing?.code, .missingRequired)
        XCTAssertEqual(missing?.path, "/info/author")
        XCTAssertEqual(parse("root = Info({author: null})", library: lib).meta.errors.first?.code, .nullRequired)
        let mismatch = parse(#"root = Info({author: "a", views: "lots"})"#, library: lib).meta.errors.first
        XCTAssertEqual(mismatch?.code, .typeMismatch)
        XCTAssertEqual(mismatch?.path, "/info/views")
        XCTAssertTrue(parse(#"root = Info("hello")"#, library: lib).meta.errors.first?.message.contains("expects object but got string") == true)
    }

    func testEnumMismatchFallsBackToDefaultOrDrops() {
        let button = root(#"root = Card([Button("Go", null, "loud")])"#)?["children"].arrayValue?.first?.elementValue
        XCTAssertEqual(button?["variant"], .string("primary"))
        let text = root(#"root = Card([Text("Hi", "huge")])"#)?["children"].arrayValue?.first?.elementValue
        XCTAssertEqual(text?["text"], .string("Hi"))
        XCTAssertNil(text?.props["size"])
    }

    func testEnumCheckDefersWhileStreaming() {
        let r = StreamParser(library: lib).push(#"root = Card([Text("Hi", "sma"#)
        XCTAssertFalse(r.meta.errors.contains { $0.code == .typeMismatch })
    }

    func testRequiredInvalidDropsComponentWithOneError() {
        let r = parse("root = Card([Text([1, 2])])", library: lib)
        XCTAssertEqual(r.meta.errors.map(\.code), [.typeMismatch])
        XCTAssertEqual(r.root?["children"].arrayValue?.count, 0)
    }

    func testDataInComponentSlotIsPruned() {
        let r = parse(#"root = Card(["just text", Text("ok")])"#, library: lib)
        XCTAssertEqual(r.root?["children"].arrayValue?.count, 1)
        XCTAssertTrue(r.meta.errors.contains { $0.code == .typeMismatch && $0.path == "/children/0" })
    }

    // MARK: Nara leniency

    func testNumberCoercesIntoStringSlot() {
        let row = root(#"root = Card([Row(42, "7")])"#)?["children"].arrayValue?.first?.elementValue
        XCTAssertEqual(row?["label"], .string("42"))
        XCTAssertEqual(row?["value"], .number(7))
    }

    func testLoneComponentWrapsIntoArraySlot() {
        let r = parse(#"root = Card(Text("solo"))"#, library: lib)
        XCTAssertTrue(r.meta.errors.isEmpty)
        XCTAssertEqual(r.root?["children"].arrayValue?.first?.elementValue?["text"], .string("solo"))
    }

    // MARK: evaluation

    func testStateBindingAndExpressions() {
        let src = """
        root = Card([slider, label])
        $reps = 8
        slider = Slider("reps", 1, 20, $reps)
        label = Text("Reps: " + $reps + (" " + ($reps > 10 ? "hard" : "easy")))
        """
        let r = parse(src, library: lib)
        XCTAssertEqual(r.stateDeclarations["$reps"], .number(8))
        var store = StateStore()
        store.initialize(defaults: r.stateDeclarations)
        var tree = Evaluator(library: lib, store: store).evaluate(r.root!)
        var kids = tree["children"].arrayValue ?? []
        XCTAssertEqual(kids[0].elementValue?["value"], .binding("$reps"))
        XCTAssertEqual(kids[1].elementValue?["text"], .string("Reps: 8 easy"))

        store.set("$reps", .number(12))
        tree = Evaluator(library: lib, store: store).evaluate(r.root!)
        kids = tree["children"].arrayValue ?? []
        XCTAssertEqual(kids[1].elementValue?["text"], .string("Reps: 12 hard"))
    }

    func testBuiltinsAndEach() {
        let src = """
        root = Card(@Each(rows, "r", Row(r.name, r.min)))
        rows = [{name: "Walk", min: 20}, {name: "Run", min: 35}, {name: "Swim", min: 15}]
        total = @Sum(rows.min)
        """
        let r = parse(src, library: lib)
        let tree = Evaluator(library: lib, getState: { _ in .null }).evaluate(r.root!)
        let kids = tree["children"].arrayValue ?? []
        XCTAssertEqual(kids.compactMap { $0.elementValue?["label"].stringValue }, ["Walk", "Run", "Swim"])
        XCTAssertEqual(kids.compactMap { $0.elementValue?["value"].numberValue }, [20, 35, 15])

        let eval = Evaluator(library: lib, getState: { _ in .null })
        let rows = ASTNode.arr([.obj([.init("m", .num(3))]), .obj([.init("m", .num(9))])])
        XCTAssertEqual(eval.evaluate(.comp(name: "Sum", args: [.member(rows, "m")], mapped: nil)), .number(12))
        XCTAssertEqual(eval.evaluate(.comp(name: "Round", args: [.num(2.345), .num(1)], mapped: nil)), .number(2.3))
        XCTAssertEqual(eval.evaluate(.comp(name: "Round", args: [.num(-2.5)], mapped: nil)), .number(-2))
        XCTAssertEqual(eval.evaluate(.binOp("/", .num(4), .num(0))), .number(0))
        XCTAssertEqual(eval.evaluate(.binOp("==", .num(5), .str("5"))), .bool(true))
        XCTAssertEqual(eval.evaluate(.binOp("==", .str("abc"), .bool(false))), .bool(false))
    }

    func testActionPlansRunLocalStepsAndReturnTheRest() {
        let src = """
        root = Card([go, reset])
        $level = "easy"
        go = Button("Harder", Action([@Set($level, "hard"), @ToAssistant("Make it " + $level)]))
        reset = Button("Reset", Action([@Reset($level), @OpenUrl("https://example.com")]))
        """
        let r = parse(src, library: lib)
        var store = StateStore()
        store.initialize(defaults: r.stateDeclarations)
        let tree = Evaluator(library: lib, store: store).evaluate(r.root!)
        guard case .action(let plan)? = tree["children"].arrayValue?.first?.elementValue?["action"] else {
            return XCTFail("expected an action plan")
        }
        let external = store.apply(plan) { Evaluator(library: self.lib, store: $0) }
        XCTAssertEqual(store.get("$level"), .string("hard"))
        // The message was built when the plan was evaluated, before @Set ran.
        XCTAssertEqual(external, [.continueConversation(message: "Make it easy", context: nil)])

        guard case .action(let resetPlan)? = tree["children"].arrayValue?.last?.elementValue?["action"] else {
            return XCTFail("expected an action plan")
        }
        XCTAssertEqual(store.apply(resetPlan) { Evaluator(library: self.lib, store: $0) }, [.openURL("https://example.com")])
        XCTAssertEqual(store.get("$level"), .string("easy"))
    }

    func testEachCapturesLoopValueInDeferredSet() {
        let src = #"root = Card(@Each(["a", "b"], "t", Button(t, Action([@Set($pick, t)]))))"#
        let r = parse(src, library: lib)
        var store = StateStore()
        store.initialize(defaults: r.stateDeclarations)
        let tree = Evaluator(library: lib, store: store).evaluate(r.root!)
        guard case .action(let plan)? = tree["children"].arrayValue?.last?.elementValue?["action"] else {
            return XCTFail("expected an action plan")
        }
        _ = store.apply(plan) { Evaluator(library: self.lib, store: $0) }
        XCTAssertEqual(store.get("$pick"), .string("b"))
    }

    func testStoreInitializeKeepsUserValues() {
        var store = StateStore()
        store.initialize(defaults: ["$a": .number(1)])
        store.set("$a", .number(5))
        store.initialize(defaults: ["$a": .number(1), "$b": .string("x")])
        XCTAssertEqual(store.get("$a"), .number(5))
        XCTAssertEqual(store.get("$b"), .string("x"))
        store.initialize(defaults: [:], persisted: ["$a": .number(9)])
        XCTAssertEqual(store.get("$a"), .number(9))
    }

    // MARK: lexer edge cases

    func testLexerHandlesEscapesNegativesAndBuiltins() {
        let toks = tokenize(#"x = @Count([-2, 3 - 1]) + "a\"b" + 'c\'d'"#)
        XCTAssertTrue(toks.contains { $0.t == .builtinCall && $0.s == "Count" })
        XCTAssertTrue(toks.contains { $0.t == .num && $0.n == -2 })
        XCTAssertTrue(toks.contains { $0.t == .minus })
        XCTAssertTrue(toks.contains { $0.t == .str && $0.s == "a\"b" })
        XCTAssertTrue(toks.contains { $0.t == .str && $0.s == "c'd" })
    }

    func testTernaryContinuesAcrossLines() {
        let src = "root = Card([t])\n$on = true\nt = $on\n  ? Text(\"yes\")\n  : Text(\"no\")"
        let r = parse(src, library: lib)
        var store = StateStore()
        store.initialize(defaults: r.stateDeclarations)
        let tree = Evaluator(library: lib, store: store).evaluate(r.root!)
        XCTAssertEqual(tree["children"].arrayValue?.first?.elementValue?["text"], .string("yes"))
    }

    // MARK: prompt

    func testPromptListsSignaturesAndSections() {
        let prompt = generateSystemPrompt(library: lib, options: PromptOptions(preamble: "PRE", bindings: true, inlineMode: true,
                                                                             additionalRules: ["Be brief."]))
        XCTAssertTrue(prompt.hasPrefix("PRE\n"))
        XCTAssertTrue(prompt.contains("root = Card(...)"))
        XCTAssertTrue(prompt.contains(#"Button(label: string, action?: ActionExpression, variant?: "primary" | "secondary")"#))
        XCTAssertTrue(prompt.contains("Slider(name: string, min?: number, max?: number, value?: $binding<number>)"))
        XCTAssertTrue(prompt.contains("Card(children: (Text | Button | Slider | Row)[])"))
        XCTAssertTrue(prompt.contains("@Count(array) → number — Returns array length"))
        XCTAssertTrue(prompt.contains("## Action — Button Behavior"))
        XCTAssertTrue(prompt.contains("@Set($variable, value)"))
        XCTAssertTrue(prompt.contains("## Inline Mode"))
        XCTAssertTrue(prompt.hasSuffix("- Be brief."))
        XCTAssertFalse(prompt.contains("Query("))
    }

    func testPromptWithoutBindingsOmitsStateSections() {
        let prompt = generateSystemPrompt(library: lib)
        XCTAssertFalse(prompt.contains("## Built-in Functions"))
        XCTAssertFalse(prompt.contains("@Set("))
        XCTAssertTrue(prompt.contains("## Hoisting & Streaming (CRITICAL)"))
    }
}

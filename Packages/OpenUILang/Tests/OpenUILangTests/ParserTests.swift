import XCTest
@testable import OpenUILang

/// Ported from upstream `parser/__tests__/parser.test.ts` (same schema, same cases).
final class ParserTests: XCTestCase {
    let schema = Library(components: [
        ComponentDef("Stack", [ParamDef("children", required: true)]),
        ComponentDef("Title", [ParamDef("text", required: true)]),
        ComponentDef("Table", [ParamDef("columns", required: true), ParamDef("rows", required: true)]),
    ], root: "Stack")

    func errors(_ input: String) -> [ValidationError] { parse(input, library: schema).meta.errors }
    func codes(_ input: String) -> [ValidationCode] { errors(input).map(\.code) }
    func children(_ r: ParseResult) -> [Value] { r.root?["children"].arrayValue ?? [] }

    // MARK: unknown-component

    func testUnknownComponentReportedAndDropped() {
        let r = parse(#"root = DataTable("col")"#, library: schema)
        XCTAssertEqual(r.meta.errors.count, 1)
        XCTAssertEqual(r.meta.errors.first?.code, .unknownComponent)
        XCTAssertEqual(r.meta.errors.first?.component, "DataTable")
        XCTAssertNil(r.root)
    }

    func testUnknownComponentInTree() {
        XCTAssertTrue(codes("root = Stack([Ghost(\"a\")])\n").contains(.unknownComponent))
    }

    func testKnownComponentsHaveNoErrors() {
        XCTAssertTrue(errors(#"root = Stack(["hello"])"#).isEmpty)
    }

    // MARK: excess-args

    func testExcessArgsStillRenders() {
        let r = parse(#"root = Title("hello", "extra")"#, library: schema)
        XCTAssertTrue(r.meta.errors.map(\.code).contains(.excessArgs))
        XCTAssertEqual(r.root?["text"], .string("hello"))
    }

    func testExcessArgsMessageCountsDropped() {
        let e = errors(#"root = Title("hello", "extra", "more")"#).first { $0.code == .excessArgs }
        XCTAssertTrue(e?.message.contains("2 excess dropped") == true)
    }

    func testNoExcessWhenCountsMatchOrFewer() {
        XCTAssertFalse(codes(#"root = Title("hello")"#).contains(.excessArgs))
        XCTAssertFalse(codes("root = Table([], [])").contains(.excessArgs))
    }

    // MARK: unresolved

    func testUnresolvedOneShot() {
        let r = parse("root = Stack([tbl])", library: schema)
        XCTAssertTrue(r.meta.unresolved.contains("tbl"))
        XCTAssertTrue(r.meta.errors.isEmpty)
        XCTAssertTrue(parse("root = Stack([tbl])\ntbl = Title(\"hello\")", library: schema).meta.unresolved.isEmpty)
    }

    func testUnresolvedStreaming() {
        let p = StreamParser(library: schema)
        let mid = p.push("root = Stack([tbl])\n")
        XCTAssertTrue(mid.meta.unresolved.contains("tbl"))
        XCTAssertTrue(mid.meta.errors.isEmpty)
        XCTAssertTrue(p.result().meta.unresolved.contains("tbl"))
        XCTAssertTrue(p.push("tbl = Title(\"hello\")\n").meta.unresolved.isEmpty)
    }

    // MARK: required

    func testMissingAndNullRequired() {
        let missing = errors("root = Stack()")
        XCTAssertEqual(missing.count, 1)
        XCTAssertEqual(missing.first?.code, .missingRequired)
        XCTAssertEqual(missing.first?.component, "Stack")
        let null = errors("root = Stack(null)")
        XCTAssertEqual(null.count, 1)
        XCTAssertEqual(null.first?.code, .nullRequired)
    }

    // MARK: array null-dropping

    func testArraysDropUnresolvedInvalidAndUnknown() {
        var kids = children(parse("root = Stack([missing, t1])\nt1 = Title(\"ok\")", library: schema))
        XCTAssertEqual(kids.count, 1)
        XCTAssertEqual(kids.first?.elementValue?.typeName, "Title")

        kids = children(parse("root = Stack([bad, good])\nbad = Title()\ngood = Title(\"ok\")", library: schema))
        XCTAssertEqual(kids.count, 1)
        XCTAssertEqual(kids.first?.elementValue?["text"], .string("ok"))

        kids = children(parse("root = Stack([u, t1])\nu = Ghost(\"x\")\nt1 = Title(\"ok\")", library: schema))
        XCTAssertEqual(kids.map { $0.elementValue?.typeName }, ["Title"])
    }

    func testNullLiteralsSurviveInArrays() {
        XCTAssertEqual(children(parse("root = Stack([null, null])", library: schema)), [.null, .null])
    }

    func testStreamingFillsInLaterDefinitions() {
        let p = StreamParser(library: schema)
        XCTAssertEqual(children(p.push("root = Stack([t1, t2])\nt1 = Title(\"first\")\n")).count, 1)
        XCTAssertEqual(children(p.push("t2 = Title(\"second\")\n")).count, 2)
    }

    // MARK: orphaned

    func testOrphans() {
        var r = parse("root = Stack([t1])\nt1 = Title(\"used\")\norphan = Title(\"unused\")", library: schema)
        XCTAssertEqual(r.meta.orphaned, ["orphan"])
        r = parse("root = Stack([t1, t2])\nt1 = Title(\"a\")\nt2 = Title(\"b\")", library: schema)
        XCTAssertTrue(r.meta.orphaned.isEmpty)
        r = parse("root = Stack([t1])\nt1 = Title(\"used\")\na = Title(\"x\")\nb = Title(\"y\")", library: schema)
        XCTAssertEqual(Set(r.meta.orphaned), ["a", "b"])
        r = parse("root = Stack([t1])\nt1 = Table([col], rows)\ncol = Title(\"Name\")\nrows = [[\"Alice\"]]", library: schema)
        XCTAssertTrue(r.meta.orphaned.isEmpty)
        let p = StreamParser(library: schema)
        XCTAssertEqual(p.push("root = Stack([t1])\nt1 = Title(\"a\")\norphan = Title(\"stray\")\n").meta.orphaned, ["orphan"])
    }

    // MARK: fences and comments inside strings

    func testFencesInsideStringsArePreserved() {
        var r = parse(#"root = Title("```js\nconsole.log(\"Hello World\");\n```")"#, library: schema)
        XCTAssertTrue(r.meta.errors.isEmpty)
        XCTAssertEqual(r.root?["text"], .string("```js\nconsole.log(\"Hello World\");\n```"))
        r = parse(#"root = Title("```python\nprint('hi')\n```")"#, library: schema)
        XCTAssertEqual(r.root?["text"], .string("```python\nprint('hi')\n```"))
    }

    func testCommentMarkersInsideMultilineStrings() {
        var r = parse("root = Title(\"\nHello // World\nhttps://example.com/\n\")", library: schema)
        XCTAssertEqual(r.root?["text"], .string("\nHello // World\nhttps://example.com/\n"))
        r = parse("root = Title(\"\nHello # World\nhttps://example.com/\n\")", library: schema)
        XCTAssertEqual(r.root?["text"], .string("\nHello # World\nhttps://example.com/\n"))
    }

    func testApostropheBeforeFenceIsNotAString() {
        let r = parse("Here's the code:\n\n```js\nroot = Title(\"hello\")\n```", library: schema)
        XCTAssertTrue(r.meta.errors.isEmpty)
        XCTAssertEqual(r.root?["text"], .string("hello"))
    }

    // MARK: redefined statement ids

    let withNewline = "root = Stack([a])\na = Title(\"x\")\na = Title(\"y\")\n"
    let withoutNewline = "root = Stack([a])\na = Title(\"x\")\na = Title(\"y\")"

    func titleText(_ r: ParseResult) -> String? { children(r).first?.elementValue?["text"].stringValue }

    func testRedefinitionLastWins() {
        XCTAssertEqual(titleText(parse(withNewline, library: schema)), "y")
        XCTAssertEqual(titleText(parse(withoutNewline, library: schema)), "y")
        for text in [withNewline, withoutNewline] {
            let one = StreamParser(library: schema)
            XCTAssertEqual(titleText(one.push(text)), "y")
            let chars = StreamParser(library: schema)
            for ch in text { chars.push(String(ch)) }
            XCTAssertEqual(titleText(chars.result()), "y")
            XCTAssertEqual(titleText(StreamParser(library: schema).set(text)), "y")
        }
        let lines = StreamParser(library: schema)
        for line in withNewline.split(separator: "\n", omittingEmptySubsequences: true) { lines.push(line + "\n") }
        XCTAssertEqual(titleText(lines.result()), "y")
    }

    func testRedefinitionAcrossChunks() {
        var p = StreamParser(library: schema)
        p.push("root = Stack([a])\na = Title(\"x\")\n")
        XCTAssertEqual(titleText(p.push("a = Title(\"y\")\n")), "y")
        p = StreamParser(library: schema)
        p.push("root = Stack([a])\na = Title(\"x\")\n")
        XCTAssertEqual(titleText(p.push("a = Title(\"y\")")), "y")
    }

    func testIncompleteRedefinitionDoesNotClobber() {
        let p = StreamParser(library: schema)
        p.push("root = Stack([a])\na = Title(\"x\")\n")
        XCTAssertEqual(titleText(p.push("a = Title(\"y")), "x")
        XCTAssertEqual(titleText(p.push("\")\n")), "y")
    }

    // MARK: streaming shape

    func testPartialInputAutoCloses() {
        let p = StreamParser(library: schema)
        let r = p.push("root = Stack([Title(\"Hel")
        XCTAssertTrue(r.meta.incomplete)
        XCTAssertEqual(titleText(r), "Hel")
    }

    func testSetResetsWhenTextIsReplaced() {
        let p = StreamParser(library: schema)
        p.set("root = Stack([Title(\"one\")])\n")
        XCTAssertEqual(titleText(p.set("root = Stack([Title(\"two\")])\n")), "two")
    }
}

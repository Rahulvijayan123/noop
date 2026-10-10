import Foundation
import OpenUILang

// CoachGenUI — Sana's generative UI. Besides prose an answer may carry one OpenUI Lang program in a fenced
// ```openui-lang block (`Packages/OpenUILang`), which the app renders as a native interactive card: plans,
// checklists, choices, short forms, timers, calculators. Charts of logged data stay with the fact-checked visual
// pipeline (`CoachViz`); a card places that visual with `Visual()`.
//
// The block streams in with the answer and renders progressively. When the answer finishes, the program moves out
// of `content` into `meta.ui`, so summaries, curation, titles, search and follow-ups only ever see prose.

/// The generated card saved with a message (`meta.ui`).
struct CoachGeneratedUI: Codable, Equatable, Sendable {
    /// The OpenUI Lang program, fences stripped.
    var source: String
    /// The card's state: `$variables` and form field values, keyed as the renderer keys them.
    var state: [String: Value]?
    /// Forms (by name) and standalone buttons whose message was already sent; they show as sent.
    var submitted: [String]?
    /// True when the answer had no prose and `content` holds the card's text instead; the bubble then shows the
    /// card alone.
    var contentIsSummary: Bool?

    init(source: String, state: [String: Value]? = nil, submitted: [String]? = nil, contentIsSummary: Bool? = nil) {
        self.source = source
        self.state = state
        self.submitted = submitted
        self.contentIsSummary = contentIsSummary
    }

    private enum CodingKeys: String, CodingKey { case source, state, submitted, contentIsSummary }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        state = c.lossy([String: Value].self, .state)
        submitted = c.lossy([String].self, .submitted)
        contentIsSummary = c.lossy(Bool.self, .contentIsSummary)
    }
}

enum CoachGenUI {
    /// Programs longer than this are not kept: the server refuses a message whose meta passes 20,000 characters,
    /// and the visual shares that budget.
    static let sourceCap = 8_000
    /// The serialized meta must stay under the server's 20,000-character limit; the card's state goes first, then
    /// the card.
    static let metaBudget = 19_000
    static let fenceTags = ["openui-lang", "openui"]

    // MARK: Library

    static let contentComponents = [
        "CardHeader", "TextContent", "Callout", "Separator", "TagBlock", "Visual", "StatGrid", "ProgressBar", "Table",
        "ListBlock", "Steps", "Tabs", "Accordion", "Buttons", "Button", "Form", "FormControl", "CheckBoxGroup", "Timer",
    ]
    static let inputComponents = ["Input", "TextArea", "Select", "Slider", "Stepper", "CheckBoxGroup", "RadioGroup", "Chips"]

    private static let rules = PropType.object([
        .init("required", .boolean), .init("min", .number), .init("max", .number), .init("minLength", .number),
        .init("maxLength", .number), .init("email", .boolean), .init("numeric", .boolean),
    ])

    static let library: Library = {
        let content = PropType.array(.component(contentComponents))
        return Library(components: [
            ComponentDef("Card", [ParamDef("children", content, required: true)],
                         description: "The card; every program's root"),
            ComponentDef("CardHeader", [ParamDef("title", .string), ParamDef("subtitle", .string)]),
            ComponentDef("TextContent", [ParamDef("text", .string, required: true),
                                         ParamDef("size", .literal(["small", "default", "large"]))],
                         description: "A paragraph; inline **bold** and *italic* allowed"),
            ComponentDef("Callout", [ParamDef("variant", .literal(["info", "tip", "success", "warning"]), required: true,
                                              defaultValue: .string("info")),
                                     ParamDef("title", .string, required: true), ParamDef("description", .string)]),
            ComponentDef("Separator", []),
            ComponentDef("TagBlock", [ParamDef("tags", .array(.string), required: true)]),
            ComponentDef("Visual", [],
                         description: "Where the app's fact-checked chart of the user's logged data goes (at most once)"),

            ComponentDef("StatGrid", [ParamDef("items", .array(.component(["Stat"])), required: true)]),
            ComponentDef("Stat", [ParamDef("label", .string, required: true), ParamDef("value", .string, required: true),
                                  ParamDef("detail", .string),
                                  ParamDef("tone", .literal(["neutral", "good", "caution", "bad"]))]),
            ComponentDef("ProgressBar", [ParamDef("label", .string, required: true), ParamDef("value", .number, required: true),
                                         ParamDef("target", .number, required: true), ParamDef("unit", .string)]),
            ComponentDef("Table", [ParamDef("columns", .array(.component(["Col"])), required: true)],
                         description: "Plans and option comparisons only"),
            ComponentDef("Col", [ParamDef("label", .string, required: true), ParamDef("data", .array(.string), required: true)]),

            ComponentDef("ListBlock", [ParamDef("items", .array(.component(["ListItem"])), required: true)]),
            ComponentDef("ListItem", [ParamDef("title", .string, required: true), ParamDef("subtitle", .string),
                                      ParamDef("action", .action)],
                         description: "With an action the row is tappable"),
            ComponentDef("Steps", [ParamDef("items", .array(.component(["StepsItem"])), required: true)]),
            ComponentDef("StepsItem", [ParamDef("title", .string, required: true), ParamDef("details", .string)]),
            ComponentDef("Tabs", [ParamDef("items", .array(.component(["TabItem"])), required: true)]),
            ComponentDef("TabItem", [ParamDef("value", .string, required: true), ParamDef("trigger", .string, required: true),
                                     ParamDef("content", content, required: true)]),
            ComponentDef("Accordion", [ParamDef("items", .array(.component(["AccordionItem"])), required: true)]),
            ComponentDef("AccordionItem", [ParamDef("value", .string, required: true), ParamDef("trigger", .string, required: true),
                                           ParamDef("content", content, required: true)]),

            ComponentDef("Button", [ParamDef("label", .string, required: true), ParamDef("action", .action),
                                    ParamDef("variant", .literal(["primary", "secondary", "tertiary"]))]),
            ComponentDef("Buttons", [ParamDef("buttons", .array(.component(["Button"])), required: true),
                                     ParamDef("direction", .literal(["row", "column"]))]),

            ComponentDef("Form", [ParamDef("name", .string, required: true),
                                  ParamDef("buttons", .component(["Buttons", "Button"]), required: true),
                                  ParamDef("fields", .array(.component(["FormControl"])), required: true)],
                         description: "Its submit button sends the answers to you as the user's next message"),
            ComponentDef("FormControl", [ParamDef("label", .string, required: true),
                                         ParamDef("input", .component(inputComponents), required: true),
                                         ParamDef("hint", .string)]),
            ComponentDef("Input", [ParamDef("name", .string, required: true), ParamDef("placeholder", .string),
                                   ParamDef("type", .literal(["text", "email", "number", "time"])),
                                   ParamDef("rules", rules), ParamDef("value", .binding(.string))]),
            ComponentDef("TextArea", [ParamDef("name", .string, required: true), ParamDef("placeholder", .string),
                                      ParamDef("rules", rules), ParamDef("value", .binding(.string))]),
            ComponentDef("Select", [ParamDef("name", .string, required: true),
                                    ParamDef("items", .array(.component(["SelectItem"])), required: true),
                                    ParamDef("placeholder", .string), ParamDef("rules", rules),
                                    ParamDef("value", .binding(.string))]),
            ComponentDef("SelectItem", [ParamDef("value", .string, required: true), ParamDef("label", .string, required: true)]),
            ComponentDef("Slider", [ParamDef("name", .string, required: true), ParamDef("min", .number, required: true),
                                    ParamDef("max", .number, required: true), ParamDef("step", .number),
                                    ParamDef("defaultValue", .number), ParamDef("unit", .string),
                                    ParamDef("value", .binding(.number))]),
            ComponentDef("Stepper", [ParamDef("name", .string, required: true), ParamDef("min", .number, required: true),
                                     ParamDef("max", .number, required: true), ParamDef("step", .number),
                                     ParamDef("defaultValue", .number), ParamDef("unit", .string),
                                     ParamDef("value", .binding(.number))]),
            ComponentDef("CheckBoxGroup", [ParamDef("name", .string, required: true),
                                           ParamDef("items", .array(.component(["CheckBoxItem"])), required: true),
                                           ParamDef("rules", rules)],
                         description: "Also a standalone checklist the user ticks off"),
            ComponentDef("CheckBoxItem", [ParamDef("name", .string, required: true), ParamDef("label", .string, required: true),
                                          ParamDef("description", .string), ParamDef("defaultChecked", .boolean)]),
            ComponentDef("RadioGroup", [ParamDef("name", .string, required: true),
                                        ParamDef("items", .array(.component(["RadioItem"])), required: true),
                                        ParamDef("defaultValue", .string), ParamDef("rules", rules),
                                        ParamDef("value", .binding(.string))]),
            ComponentDef("RadioItem", [ParamDef("value", .string, required: true), ParamDef("label", .string, required: true),
                                       ParamDef("description", .string)]),
            ComponentDef("Chips", [ParamDef("name", .string, required: true),
                                   ParamDef("items", .array(.component(["ChipItem"])), required: true),
                                   ParamDef("type", .literal(["single", "multiple"])), ParamDef("defaultValue", .string),
                                   ParamDef("value", .binding(.string))]),
            ComponentDef("ChipItem", [ParamDef("value", .string, required: true), ParamDef("label", .string, required: true)]),

            ComponentDef("Timer", [ParamDef("label", .string, required: true), ParamDef("seconds", .number, required: true),
                                   ParamDef("rounds", .number)],
                         description: "A countdown with start, pause and reset; rounds repeat it (intervals, breathing)"),
        ], root: "Card", groups: [
            ComponentGroup("Content", ["Card", "CardHeader", "TextContent", "Callout", "Separator", "TagBlock", "Visual"]),
            ComponentGroup("Numbers", ["StatGrid", "Stat", "ProgressBar", "Table", "Col"],
                           notes: ["- Numbers come from the user's data or the conversation, never invented. Stat values are short strings (\"7h 12m\", \"62 ms\")."]),
            ComponentGroup("Lists & layout", ["ListBlock", "ListItem", "Steps", "StepsItem", "Tabs", "TabItem", "Accordion", "AccordionItem"]),
            ComponentGroup("Buttons", ["Button", "Buttons"]),
            ComponentGroup("Forms & inputs", ["Form", "FormControl", "Input", "TextArea", "Select", "SelectItem", "Slider", "Stepper",
                                              "CheckBoxGroup", "CheckBoxItem", "RadioGroup", "RadioItem", "Chips", "ChipItem"],
                           notes: ["- An input with a $binding outside a Form updates live: use it for calculators (`TextContent(\"About \" + @Round($kg * 0.033, 1) + \" L a day\")`)."]),
            ComponentGroup("Health", ["Timer"]),
        ])
    }()

    // MARK: Prompt

    private static let preamble = """
    INTERACTIVE CARDS: Besides prose you can attach ONE interactive card to an answer, written in openui-lang (below) \
    and rendered natively in the app. Use one only when it helps the user act more than reading would: a plan or \
    routine to follow, a checklist, options to pick from, a short form that tailors your advice, a timer for \
    breathing or intervals, a small calculator. Most answers need no card — conversation, explanations and quick \
    facts stay prose.
    Write your prose first (at least one sentence), then the card in a fenced block, and nothing after the fence:
    ```openui-lang
    root = Card([header, steps])
    header = CardHeader("Wind-down routine", "Start 45 minutes before bed")
    steps = Steps([StepsItem("Dim the lights", "Warm, low light from 9:15"), StepsItem("Screens away", "Phone charging outside the bedroom")])
    ```
    The user never sees the code. Never mention openui-lang, components or the fence.
    """

    private static let examples = [
        """
        Example — a form that tailors the next answer:
        ```openui-lang
        root = Card([header, form])
        header = CardHeader("Build your week", "Three quick questions")
        form = Form("week", Button("Build my plan", null, "primary"), [days, goal, minutes])
        days = FormControl("Training days", Stepper("days", 2, 6, 1, 4, "days"))
        goal = FormControl("Main goal", Chips("goal", [ChipItem("endurance", "Endurance"), ChipItem("strength", "Strength"), ChipItem("both", "Both")], "single", "both"))
        minutes = FormControl("Time per session", Slider("minutes", 20, 90, 5, 45, "min"))
        ```
        """,
        """
        Example — live state:
        ```openui-lang
        root = Card([header, breath, timer, done])
        header = CardHeader("Box breathing")
        $pace = 4
        breath = FormControl("Seconds per side", Slider("pace", 3, 6, 1, 4, "s", $pace))
        timer = Timer("Inhale · hold · exhale · hold", $pace * 4, 6)
        done = Buttons([Button("That helped", Action([@ToAssistant("The box breathing helped. What next?")]), "secondary")])
        ```
        """,
    ]

    private static let rulesForSana = [
        "Never repeat the prose in the card: the card holds what is easier to use than to read (steps, options, inputs, targets to track).",
        "Never chart or tabulate the user's logged data (sleep, charge, effort, HRV, heart rate, workouts): the app draws a fact-checked chart for that beneath your answer. To place that chart inside the card, add Visual(); otherwise leave charts out entirely.",
        "Only use numbers from tool results or the conversation. Never invent the user's data.",
        "No follow-up question buttons: the app already suggests follow-ups under every answer. Buttons act on the card (\"Make it 20 minutes\", \"Swap the run\").",
        "A Form's submit button sends the user's answers to you as their next message; reply to that with the tailored result.",
        "Keep a card small: about 12 components at most, short labels, no markdown headers or tables inside text.",
        "Every safety rule above applies inside a card too.",
    ]

    /// The block `CoachPrompt.system(..., interactiveUI: true)` adds after the tool guidance. Static, so the prompt
    /// prefix still caches.
    static let promptBlock: String = generateSystemPrompt(
        library: library,
        options: PromptOptions(preamble: preamble, bindings: true, examples: examples, additionalRules: rulesForSana))

    // MARK: Splitting

    struct Split: Equatable {
        var before: String
        /// The program inside the fence; nil when there is none.
        var source: String?
        var after: String
        /// The closing fence has not arrived (still streaming, or the model never closed it).
        var isOpen: Bool
    }

    /// Splits answer text around the first ```openui-lang block. A trailing line that could still become the
    /// opening fence is held back while streaming, so "```open" never flashes as text.
    static func split(_ text: String, streaming: Bool = false) -> Split {
        guard let open = openingFence(in: text) else {
            if let start = bareProgramStart(in: text) {
                return Split(before: String(text[..<start]), source: String(text[start...]), after: "", isOpen: streaming)
            }
            return Split(before: streaming ? holdingBackPartialFence(text) : text, source: nil, after: "", isOpen: false)
        }
        let body = text[open.upperBound...]
        if let close = closingFence(in: body) {
            return Split(before: String(text[..<open.lowerBound]), source: String(body[..<close.lowerBound]),
                         after: String(body[close.upperBound...]), isOpen: false)
        }
        var source = String(body)
        if streaming {
            // A closing fence still arriving: "`" or "``" at the start of the last line.
            if let nl = source.lastIndex(of: "\n") {
                let tail = source[source.index(after: nl)...]
                if !tail.isEmpty, tail.allSatisfy({ $0 == "`" }) { source = String(source[...nl]) }
            }
        }
        return Split(before: String(text[..<open.lowerBound]), source: source, after: "", isOpen: true)
    }

    /// The range of "```openui-lang\n" (any listed tag, case-insensitive) at the start of a line.
    private static func openingFence(in text: String) -> Range<String.Index>? {
        var search = text.startIndex
        while let fence = text.range(of: "```", range: search..<text.endIndex) {
            defer { search = fence.upperBound }
            let atLineStart = fence.lowerBound == text.startIndex || text[text.index(before: fence.lowerBound)] == "\n"
            guard atLineStart else { continue }
            let lineEnd = text[fence.upperBound...].firstIndex(of: "\n") ?? text.endIndex
            let tag = text[fence.upperBound..<lineEnd].trimmingCharacters(in: .whitespaces).lowercased()
            guard fenceTags.contains(tag) else { continue }
            // While the tag line is still streaming there is no newline yet; the program starts after it.
            let bodyStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : lineEnd
            return fence.lowerBound..<bodyStart
        }
        return nil
    }

    /// The closing ``` of a program: at the start of a line and outside double-quoted strings.
    private static func closingFence(in body: Substring) -> Range<String.Index>? {
        var inString = false
        var escaped = false
        var i = body.startIndex
        var lineStart = true
        while i < body.endIndex {
            let c = body[i]
            if inString {
                if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { inString = false }
            } else if c == "\"" {
                inString = true
            } else if c == "`", lineStart, body[i...].hasPrefix("```") {
                let end = body.index(i, offsetBy: 3)
                return i..<end
            }
            if !c.isWhitespace || c == "\n" { lineStart = c == "\n" }
            i = body.index(after: i)
        }
        return nil
    }

    /// A program the model wrote without its fence: a line starting `root = Card(`.
    private static func bareProgramStart(in text: String) -> String.Index? {
        guard let r = text.range(of: #"(?m)^root\s*=\s*Card\("#, options: .regularExpression) else { return nil }
        return r.lowerBound
    }

    private static func holdingBackPartialFence(_ text: String) -> String {
        let lastLineStart = text.lastIndex(of: "\n").map { text.index(after: $0) } ?? text.startIndex
        let tail = text[lastLineStart...].lowercased()
        guard !tail.isEmpty, tail.hasPrefix("`") else { return text }
        let candidates = fenceTags.map { "```" + $0 }
        let couldOpen = candidates.contains { $0.hasPrefix(tail) || tail.hasPrefix($0) }
        return couldOpen ? String(text[..<lastLineStart]) : text
    }

    // MARK: Reading a program

    /// Parses a program, with state defaults applied, ready to evaluate.
    static func parse(_ source: String) -> ParseResult {
        OpenUILang.parse(source, library: library)
    }

    /// The card's text in reading order: what the fact-check, the safety screen and history see of it.
    static func plainText(_ source: String, state: [String: Value]? = nil) -> String {
        let result = parse(source)
        guard let root = result.root else { return "" }
        var store = StateStore()
        store.initialize(defaults: result.stateDeclarations, persisted: state ?? [:])
        let tree = Evaluator(library: library, store: store).evaluate(root)
        var lines: [String] = []
        collectText(.element(tree), into: &lines)
        return lines.joined(separator: "\n")
    }

    private static let skippedProps: Set<String> = ["name", "variant", "size", "type", "direction", "tone", "rules", "action",
                                                    "defaultChecked", "step", "defaultValue", "min", "max"]
    private static let idValueTypes: Set<String> = ["SelectItem", "RadioItem", "ChipItem", "TabItem", "AccordionItem"]

    private static func collectText(_ value: Value, into lines: inout [String]) {
        switch value {
        case .element(let el):
            guard let def = library.component(el.typeName) else { return }
            if el.typeName == "Col" {
                let data = (el["data"].arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", ")
                lines.append([el["label"].stringValue, data].compactMap { $0 }.joined(separator: ": "))
                return
            }
            var inline: [String] = []
            for param in def.params where !skippedProps.contains(param.name) {
                if param.name == "value", idValueTypes.contains(el.typeName) { continue }
                switch el[param.name] {
                case .string(let s) where !s.isEmpty: inline.append(s)
                case .number(let n) where param.name != "value" || el.typeName == "ProgressBar":
                    inline.append(JS.format(n) + (param.name == "seconds" ? " s" : ""))
                case .array(let items) where items.allSatisfy({ $0.stringValue != nil }):
                    inline.append(items.compactMap(\.stringValue).joined(separator: ", "))
                default: break
                }
            }
            if !inline.isEmpty { lines.append(inline.joined(separator: " — ")) }
            for param in def.params {
                let v = el[param.name]
                if case .element = v { collectText(v, into: &lines) }
                if case .array(let items) = v { items.forEach { collectText($0, into: &lines) } }
            }
        case .array(let items):
            items.forEach { collectText($0, into: &lines) }
        default:
            break
        }
    }

    /// The card's name for history and previews: its header, else its first line.
    static func title(_ source: String) -> String? {
        guard let root = parse(source).root else { return nil }
        func header(_ v: Value) -> String? {
            switch v {
            case .element(let el):
                if el.typeName == "CardHeader", let t = el["title"].stringValue, !t.isEmpty { return t }
                for value in el.props.values { if let t = header(value) { return t } }
                return nil
            case .array(let items): return items.lazy.compactMap(header).first
            default: return nil
            }
        }
        return header(.element(root)) ?? plainText(source).components(separatedBy: "\n").first.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// How an earlier card reads in the model's history: a one-line marker, never the program.
    static func historyMarker(_ ui: CoachGeneratedUI) -> String {
        let text = plainText(ui.source, state: ui.state).replacingOccurrences(of: "\n", with: "; ")
        let excerpt = text.count > 300 ? String(text.prefix(300)) + "…" : text
        let name = title(ui.source).map { "\"\($0)\"" } ?? "card"
        return "[Interactive card shown: \(name)\(excerpt.isEmpty ? "" : " — \(excerpt)")]"
    }

    // MARK: Interactions

    /// The message a form submit sends: the button's message, then one line per answered field.
    static func formMessage(_ message: String, fields: [(label: String, value: String)]) -> String {
        let answered = fields.filter { !$0.value.isEmpty }
        guard !answered.isEmpty else { return message }
        return ([message] + answered.map { "• \($0.label): \($0.value)" }).joined(separator: "\n")
    }

    /// Only https links leave the app.
    static func safeURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host?.isEmpty == false else { return nil }
        return url
    }

    // MARK: Finishing an answer

    struct Finished: Equatable {
        /// What `content` becomes.
        var content: String
        var ui: CoachGeneratedUI?
        /// False when a screen changed anything; the visual and the follow-ups then skip the answer.
        var clean: Bool
        /// The prose plus the card's text: what the visual's fact-check and the follow-ups read.
        var answerText: String
    }

    /// The finish step for an answer that may carry a card. The prose and the card's text are screened
    /// separately; a card whose text a screen would change is dropped and the whole answer falls back to the
    /// screened plain text. Text charts are stripped from the prose only.
    static func finish(_ raw: String, userAge: Int?) -> Finished {
        let parts = split(raw)
        guard let source = parts.source?.trimmingCharacters(in: .whitespacesAndNewlines), !source.isEmpty else {
            let screen = CoachSafety.screenOutput(CoachVisualEvidence.stripTextCharts(raw), userAge: userAge)
            return Finished(content: screen.text, ui: nil, clean: screen.clean, answerText: screen.text)
        }
        let prose = CoachVisualEvidence.stripTextCharts(
            [parts.before, parts.after].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }.joined(separator: "\n\n"))
        let cardText = plainText(source)
        let parsed = parse(source)
        let usable = parsed.root != nil && source.count <= sourceCap && !cardText.isEmpty

        guard usable else {
            let screen = CoachSafety.screenOutput(prose.isEmpty ? cardText : prose, userAge: userAge)
            return Finished(content: screen.text, ui: nil, clean: screen.clean, answerText: screen.text)
        }
        let cardScreen = CoachSafety.screenOutput(cardText, userAge: userAge)
        guard cardScreen.clean else {
            let screen = CoachSafety.screenOutput([prose, cardText].filter { !$0.isEmpty }.joined(separator: "\n\n"), userAge: userAge)
            return Finished(content: screen.text, ui: nil, clean: false, answerText: screen.text)
        }
        if prose.isEmpty {
            return Finished(content: cardText, ui: CoachGeneratedUI(source: source, contentIsSummary: true), clean: true,
                            answerText: cardText)
        }
        let proseScreen = CoachSafety.screenOutput(prose, userAge: userAge)
        return Finished(content: proseScreen.text, ui: CoachGeneratedUI(source: source), clean: proseScreen.clean,
                        answerText: proseScreen.text + "\n\n" + cardText)
    }
}

extension CoachMessageMeta {
    /// Within the server's meta limit: the card's state is dropped first, then a custom interactive visual (the
    /// largest kind of visual, and never the answer itself), then the card.
    func fittingServerLimit() -> CoachMessageMeta {
        func size(_ m: CoachMessageMeta) -> Int {
            (try? JSONEncoder().encode(m)).map { String(decoding: $0, as: UTF8.self).utf16.count } ?? 0
        }
        guard ui != nil || viz?.custom != nil, size(self) > CoachGenUI.metaBudget else { return self }
        var out = self
        out.ui?.state = nil
        if size(out) > CoachGenUI.metaBudget, out.viz?.custom != nil { out.viz = nil }
        if size(out) > CoachGenUI.metaBudget { out.ui = nil }
        return out
    }
}

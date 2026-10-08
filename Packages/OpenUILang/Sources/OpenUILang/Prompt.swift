import Foundation

/// Options for `generateSystemPrompt` (upstream `PromptSpec` minus tools: this port does not run Query/Mutation).
public struct PromptOptions: Sendable {
    public var preamble: String?
    /// `$variables`, `@Set`, `@Reset`, expressions and forms with bindings.
    public var bindings: Bool
    public var inlineMode: Bool
    public var examples: [String]
    public var additionalRules: [String]

    public init(preamble: String? = nil, bindings: Bool = false, inlineMode: Bool = false, examples: [String] = [],
                additionalRules: [String] = []) {
        self.preamble = preamble
        self.bindings = bindings
        self.inlineMode = inlineMode
        self.examples = examples
        self.additionalRules = additionalRules
    }
}

private let defaultPreamble = "You are an AI assistant that responds using openui-lang, a declarative UI language. Your ENTIRE response must be valid openui-lang code — no markdown, no explanations, just openui-lang."

/// Renders the system prompt that teaches a model the language and the library, section for section as
/// upstream's `generatePrompt` with tool calls off.
public func generateSystemPrompt(library: Library, options: PromptOptions = PromptOptions()) -> String {
    let root = library.root
    let bindings = options.bindings
    let usesAction = library.components.contains { $0.signature.contains("ActionExpression") }

    var parts: [String] = []
    parts.append(options.preamble ?? defaultPreamble)
    parts.append("")
    parts.append(syntaxRules(root, bindings: bindings))
    parts.append("")
    parts.append(componentSignatures(library, bindings: bindings, usesAction: usesAction))
    if bindings {
        parts.append("")
        parts.append(builtinSection())
    }
    if usesAction {
        parts.append("")
        parts.append(actionSection(bindings: bindings))
    }
    if bindings {
        parts.append("")
        parts.append(formsSection())
    }
    parts.append("")
    parts.append(streamingRules(root, expressions: bindings))
    if !options.examples.isEmpty {
        parts.append("")
        parts.append("## Examples")
        parts.append("")
        for example in options.examples {
            parts.append(example)
            parts.append("")
        }
    }
    if options.inlineMode {
        parts.append("")
        parts.append(inlineModeSection())
    }
    parts.append(importantRules(root, bindings: bindings))
    if !options.additionalRules.isEmpty {
        parts.append("")
        for rule in options.additionalRules { parts.append("- \(rule)") }
    }
    return parts.joined(separator: "\n")
}

private func syntaxRules(_ root: String, bindings: Bool) -> String {
    var lines = [
        "## Syntax Rules",
        "",
        "1. Each statement is on its own line: `identifier = Expression`",
        "2. `root` is the entry point — every program must define `root = \(root)(...)`",
        "3. Expressions are: strings (\"...\"), numbers, booleans (true/false), null, arrays ([...]), objects ({...}), or component calls TypeName(arg1, arg2, ...)",
        "4. Use references for readability: define `name = ...` on one line, then use `name` later",
        "5. EVERY variable (except root) MUST be referenced by at least one other variable. Unreferenced variables are silently dropped and will NOT render. Always include defined variables in their parent's children/items array.",
        "6. Arguments are POSITIONAL (order matters, not names). Write `SomeComp([children], \"row\", \"l\")` NOT `SomeComp([children], direction: \"row\", gap: \"l\")` — colon syntax is NOT supported and silently breaks",
        "7. Optional arguments can be omitted from the end",
    ]
    var n = 8
    func rule(_ text: String) { lines.append("\(n). \(text)"); n += 1 }
    if bindings {
        rule("Declare mutable state with `$varName = defaultValue`. Components marked with `$binding` can read/write these. Undeclared $variables are auto-created with null default.")
        rule("String concatenation: `\"text\" + $var + \"more\"`")
        rule("Dot member access: `query.field` reads a field; on arrays it extracts that field from every element")
        rule("Index access: `arr[0]`, `data[index]`")
        rule("Arithmetic operators: +, -, *, /, % (work on numbers; + is string concat when either side is a string)")
        rule("Comparison: ==, !=, >, <, >=, <=")
        rule("Logical: &&, ||, ! (prefix)")
        rule("Ternary: `condition ? valueIfTrue : valueIfFalse`")
        rule("Parentheses for grouping: `(a + b) * c`")
    }
    lines.append("- Strings use double quotes with backslash escaping")
    return lines.joined(separator: "\n")
}

private func componentSignatures(_ library: Library, bindings: Bool, usesAction: Bool) -> String {
    var lines = [
        "## Component Signatures",
        "",
        "Arguments marked with ? are optional. Sub-components can be inline or referenced; prefer references for better streaming.",
    ]
    if usesAction {
        let steps = ["@ToAssistant", "@OpenUrl"] + (bindings ? ["@Set", "@Reset"] : [])
        lines.append("Props typed `ActionExpression` accept an Action([@steps...]) expression. See the Action section for available steps (\(steps.joined(separator: ", "))).")
    }
    if bindings || library.components.contains(where: { $0.signature.contains("$binding") }) {
        lines.append("Props marked `$binding<type>` accept a `$variable` reference for two-way binding.")
    }
    func format(_ c: ComponentDef) -> String { c.description.map { "\(c.signature) — \($0)" } ?? c.signature }

    if library.groups.isEmpty {
        lines.append("")
        lines.append(contentsOf: library.components.map(format))
    } else {
        var grouped: Set<String> = []
        for group in library.groups {
            lines.append("")
            lines.append("### \(group.name)")
            for name in group.components where !grouped.contains(name) {
                guard let c = library.component(name) else { continue }
                grouped.insert(name)
                lines.append(format(c))
            }
            lines.append(contentsOf: group.notes)
        }
        let rest = library.components.filter { !grouped.contains($0.name) }
        if !rest.isEmpty {
            lines.append("")
            lines.append("### Other")
            lines.append(contentsOf: rest.map(format))
        }
    }
    return lines.joined(separator: "\n")
}

private func builtinSection() -> String {
    let lines = Builtins.ordered.map { "@\($0.signature) — \($0.description)" }
        + Builtins.lazyDocs.map { "@\($0.signature) — \($0.description)" }
    return """
    ## Built-in Functions

    Data functions prefixed with `@` to distinguish from components. These are the ONLY functions available — do NOT invent new ones.
    Use @-prefixed built-in functions (@Count, @Sum, @Avg, @Min, @Max, @Round) to derive values from data in the program — do NOT hardcode computed values.

    \(lines.joined(separator: "\n"))

    Builtins compose — output of one is input to the next:
    `@Count(@Filter(data.rows, "field", "==", "val"))` for KPIs/chart values, `@Round(@Avg(data.rows.score), 1)`, `@Each(data.rows, "item", Comp(item.field))` for per-item rendering.
    Array pluck: `data.rows.field` extracts a field from every row → use with @Sum, @Avg, charts, tables.

    IMPORTANT @Each rule: The loop variable (e.g. "item") is ONLY available inside the @Each template expression. Always inline the template — do NOT extract it to a separate statement.
    CORRECT: `Col("Actions", @Each(rows, "t", Button("Edit", Action([@Set($id, t.id)]))))`
    WRONG: `myBtn = Button("Edit", Action([@Set($id, t.id)]))` then `Col("Actions", @Each(rows, "t", myBtn))` — t is undefined in myBtn.
    """
}

private func actionSection(bindings: Bool) -> String {
    var steps = [
        "- @ToAssistant(\"message\") — Send a message to the assistant (for conversational buttons like \"Tell me more\", \"Explain this\")",
        "- @OpenUrl(\"https://...\") — Navigate to a URL",
    ]
    if bindings {
        steps.append("- @Set($variable, value) — Set a $variable to a specific value")
        steps.append("- @Reset($var1, $var2, ...) — Reset $variables to their declared defaults (e.g. @Reset($title, $priority) restores $title=\"\" and $priority=\"medium\")")
    }
    return """
    ## Action — Button Behavior

    Action([@steps...]) wires button clicks to operations. Steps are @-prefixed built-in actions. Steps execute in order.
    Buttons without an explicit Action prop automatically send their label to the assistant (equivalent to Action([@ToAssistant(label)])).

    Available steps:
    \(steps.joined(separator: "\n"))

    Example — simple nav:
    ```
    viewBtn = Button("View", Action([@OpenUrl("https://example.com")]))
    ```

    - Action can be assigned to a variable or inlined: Button("Go", onSubmit) and Button("Go", Action([...])) both work
    """
}

private func formsSection() -> String {
    """
    ## Forms

    Simple form — no $bindings needed. Field values are managed internally by the Form via the name prop:
    ```
    contactForm = Form("contact", submitBtn, [nameField, emailField])
    nameField = FormControl("Name", Input("name", "Your name", "text", {required: true}))
    emailField = FormControl("Email", Input("email", "your@email.com", "email", {required: true, email: true}))
    submitBtn = Button("Submit")
    ```

    Use $bindings when you need to read field values elsewhere (in Action context or conditionals). They are auto-declared:
    ```
    $role = "engineer"
    contactForm = Form("contact", submitBtn, [nameField, roleField])
    nameField = FormControl("Name", Input("name", "Enter your name", "text", {required: true}, $name))
    roleField = FormControl("Role", Select("role", [SelectItem("engineer", "Engineer"), SelectItem("designer", "Designer")], null, {required: true}, $role))
    submitBtn = Button("Submit")
    ```

    Rules for $variables:
    - $variables hold simple values (strings or numbers), NOT arrays or objects
    - $variables must be bound to an input component via the value argument (last positional arg) to be interactive
    - Use OBJECT syntax for validation rules: {required: true, email: true, minLength: 8}. The renderer shows error messages automatically and blocks submit when validation fails.
    """
}

private func streamingRules(_ root: String, expressions: Bool) -> String {
    let steps = expressions
        ? ["1. `root = \(root)(...)` — UI shell appears immediately", "2. $variable declarations — state ready for bindings",
           "3. Component definitions — fill in with data already available", "4. Data values — leaf content last"]
        : ["1. `root = \(root)(...)` — UI shell appears immediately", "2. Component definitions — fill in as they stream",
           "3. Data values — leaf content last"]
    return """
    ## Hoisting & Streaming (CRITICAL)

    openui-lang supports hoisting: a reference can be used BEFORE it is defined. The parser resolves all references after the full input is parsed.

    During streaming, the output is re-parsed on every chunk. Undefined references are temporarily unresolved and appear once their definitions stream in. This creates a progressive top-down reveal — structure first, then data fills in.

    **Recommended statement order for optimal streaming:**
    \(steps.joined(separator: "\n"))

    Always write the root = \(root)(...) statement first so the UI shell appears immediately, even before child data has streamed in.
    """
}

private func inlineModeSection() -> String {
    """
    ## Inline Mode

    You are in inline mode. You can respond in two ways:

    ### 1. Code response (when the user wants to CREATE or CHANGE the UI)
    Wrap openui-lang code in triple-backtick fences. You can include explanatory text before/after:

    Here's your dashboard:

    ```openui-lang
    root = RootComp([header, content])
    header = SomeHeader("Title")
    content = SomeContent("Hello world")
    ```

    I created a simple layout with a header.

    ### 2. Text-only response (when the user asks a QUESTION)
    If the user asks "what is this?", "explain the chart", "how does this work", etc. — respond with plain text. Do NOT output any openui-lang code. The existing dashboard stays unchanged.

    ### Rules
    - When the user asks for changes, output ONLY the changed/new statements in a fenced block
    - When the user asks a question, respond with text only — NO code. The dashboard stays unchanged.
    - The parser extracts code from fences automatically. Text outside fences is shown as chat.
    """
}

private func importantRules(_ root: String, bindings: Bool) -> String {
    var verify = [
        "1. root = \(root)(...) is the FIRST line (for optimal streaming).",
        "2. Every referenced name is defined. Every defined name (other than root) is reachable from root.",
    ]
    if bindings { verify.append("3. Every $binding appears in at least one component or expression.") }
    return """
    ## Important Rules
    - Choose components that best represent the content (tables for comparisons, charts for trends, forms for input, etc.)

    ## Final Verification
    Before finishing, walk your output and verify:
    \(verify.joined(separator: "\n"))
    """
}

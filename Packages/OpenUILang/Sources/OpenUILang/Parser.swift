import Foundation

public struct ParseMeta: Equatable, Sendable {
    /// True while the input still needed brackets or a string closed: more is streaming.
    public var incomplete: Bool
    /// References that never resolved (forward references not yet streamed, or typos).
    public var unresolved: [String]
    /// Statements defined but never reached from the root.
    public var orphaned: [String]
    public var statementCount: Int
    public var errors: [ValidationError]
}

public struct ParseResult: Sendable {
    public var root: Element?
    public var meta: ParseMeta
    /// `$variable` defaults, materialized. Variables used but never declared default to null.
    public var stateDeclarations: [String: Value]

    static func empty(incomplete: Bool = true) -> ParseResult {
        ParseResult(root: nil,
                    meta: ParseMeta(incomplete: incomplete, unresolved: [], orphaned: [], statementCount: 0, errors: []),
                    stateDeclarations: [:])
    }
}

private func classify(_ raw: RawStatement, _ expr: ASTNode) -> Statement {
    if case .comp(let name, let args, _) = expr {
        if name == "Query" { return .query(id: raw.id, args: args, expr: expr) }
        if name == "Mutation" { return .mutation(id: raw.id, args: args, expr: expr) }
    }
    if raw.idKind == .stateVar { return .state(id: raw.id, initial: expr) }
    return .value(id: raw.id, expr: expr)
}

/// An insertion-ordered statement table where redefining an id replaces it in place (JS `Map.set`).
struct StatementTable {
    private(set) var order: [String] = []
    private(set) var byId: [String: Statement] = [:]

    mutating func set(_ stmt: Statement) {
        if byId[stmt.id] == nil { order.append(stmt.id) }
        byId[stmt.id] = stmt
    }
    mutating func removeAll() { order.removeAll(); byId.removeAll() }
    var statements: [Statement] { order.compactMap { byId[$0] } }
    var count: Int { order.count }
    func has(_ id: String) -> Bool { byId[id] != nil }
}

private func isComponentStatement(_ stmt: Statement) -> String? {
    guard case .value(_, let expr) = stmt, case .comp(let name, _, _) = expr,
          !Builtins.isBuiltin(name), !Builtins.isReservedCall(name) else { return nil }
    return name
}

private func pickEntry(_ table: StatementTable, firstId: String, rootName: String?) -> String {
    if table.has("root") { return "root" }
    if let rootName, table.has(rootName) { return rootName }
    let stmts = table.statements
    if let rootName, let preferred = stmts.first(where: { isComponentStatement($0) == rootName }) { return preferred.id }
    return stmts.first(where: { isComponentStatement($0) != nil })?.id ?? firstId
}

private func buildResult(_ table: StatementTable, firstId: String, incomplete: Bool, count: Int,
                         library: Library?, rootName: String?) -> ParseResult {
    let entry = pickEntry(table, firstId: firstId, rootName: rootName)
    guard table.has(entry) else { return .empty(incomplete: incomplete) }

    var syms: [String: ASTNode] = [:]
    var unreached: Set<String> = []
    for stmt in table.statements {
        syms[stmt.id] = stmt.node
        if stmt.id == entry { continue }
        if case .value = stmt { unreached.insert(stmt.id) }
    }
    let ctx = MaterializeContext(syms: syms, library: library, partial: incomplete, currentStatementId: entry,
                                 unreached: unreached)
    var root: Element?
    if case .element(var el) = materializeValue(syms[entry]!, ctx) {
        el.statementId = entry
        root = el
    }

    var states: [String: Value] = [:]
    for stmt in table.statements {
        if case .state(let id, let initial) = stmt { states[id] = materializeValue(initial, ctx) }
    }
    for stmt in table.statements {
        let nodes: [ASTNode]
        switch stmt {
        case .state(_, let initial): nodes = [initial]
        case .value(_, let expr): nodes = [expr]
        case .query(_, let args, _), .mutation(_, let args, _): nodes = args
        }
        for node in nodes {
            for dep in node.stateRefs where states[dep] == nil { states[dep] = .null }
        }
    }

    // Upstream reports orphans in Set insertion order (statement order).
    let orphaned = table.statements.map(\.id).filter { ctx.unreached.contains($0) }
    return ParseResult(root: root,
                       meta: ParseMeta(incomplete: incomplete, unresolved: ctx.unresolved, orphaned: orphaned,
                                       statementCount: count, errors: ctx.errors),
                       stateDeclarations: states)
}

// MARK: - Preprocessing

private func skipString(_ s: [Unicode.Scalar], _ start: Int) -> Int {
    guard start < s.count, s[start] == "\"" else { return start }
    var i = start + 1
    while i < s.count {
        if s[i] == "\\" { i += 2 } else if s[i] == "\"" { return i + 1 } else { i += 1 }
    }
    return i
}

private func isFence(_ s: [Unicode.Scalar], _ i: Int) -> Bool {
    i + 2 < s.count && s[i] == "`" && s[i + 1] == "`" && s[i + 2] == "`"
}

private func text(_ s: [Unicode.Scalar], _ from: Int, _ to: Int) -> String {
    var out = String.UnicodeScalarView()
    if from < to { out.append(contentsOf: s[max(0, from)..<min(to, s.count)]) }
    return String(out)
}

/// Extracts code from markdown fences, or returns the input as-is when there are none. A ``` inside a
/// double-quoted string is not a fence.
public func stripFences(_ input: String) -> String {
    let s = Array(input.unicodeScalars)
    var blocks: [String] = []
    var i = 0
    outer: while i < s.count {
        var fenceStart = -1
        while i < s.count {
            let next = skipString(s, i)
            if next > i { i = next; continue }
            if isFence(s, i) { fenceStart = i; break }
            i += 1
        }
        if fenceStart == -1 { break }

        var j = fenceStart + 3
        while j < s.count, s[j] != "\n" { j += 1 }
        if j >= s.count {
            // Streaming: the fence's language tag line has not ended yet.
            let rest = text(s, fenceStart + 3, s.count)
            if let nl = rest.firstIndex(of: "\n") { blocks.append(String(rest[rest.index(after: nl)...])) } else { blocks.append("") }
            break outer
        }
        j += 1

        var close = -1
        var k = j
        while k < s.count {
            let next = skipString(s, k)
            if next > k { k = next; continue }
            if isFence(s, k) { close = k; break }
            k += 1
        }
        if close != -1 {
            blocks.append(text(s, j, close))
            i = close + 3
        } else {
            blocks.append(text(s, j, s.count))
            break outer
        }
    }
    if !blocks.isEmpty { return blocks.joined(separator: "\n") }

    if input.hasPrefix("```") {
        var j = 3
        while j < s.count, s[j] != "\n" { j += 1 }
        let start = j < s.count ? j + 1 : 3
        let body = text(s, start, s.count)
        if let trailing = body.range(of: "```", options: .backwards) { return String(body[..<trailing.lowerBound]) }
        return body
    }
    return input
}

/// Strips `//` and `#` line comments outside strings; string state carries across lines like upstream.
func stripComments(_ input: String) -> String {
    var inStr: Unicode.Scalar?
    return input.components(separatedBy: "\n").map { line -> String in
        let s = Array(line.unicodeScalars)
        var i = 0
        while i < s.count {
            let c = s[i]
            if let quote = inStr {
                if c == "\\", i + 1 < s.count { i += 2; continue }
                if c == quote { inStr = nil }
                i += 1
                continue
            }
            if c == "\"" || c == "'" { inStr = c; i += 1; continue }
            if (c == "/" && i + 1 < s.count && s[i + 1] == "/") || c == "#" {
                var kept = text(s, 0, i)
                while kept.last?.isWhitespace == true { kept.removeLast() }
                return kept
            }
            i += 1
        }
        return line
    }.joined(separator: "\n")
}

func preprocess(_ input: String) -> String {
    stripComments(stripFences(input.trimmingCharacters(in: .whitespacesAndNewlines)))
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

// MARK: - Public API

/// Parses a complete (or partial) OpenUI Lang program in one pass.
public func parse(_ input: String, library: Library?, rootName: String? = nil) -> ParseResult {
    let trimmed = preprocess(input)
    guard !trimmed.isEmpty else { return .empty() }
    let (closed, incomplete) = autoClose(trimmed)
    let stmts = split(tokenize(closed))
    guard !stmts.isEmpty else { return .empty(incomplete: incomplete) }

    var table = StatementTable()
    var firstId = ""
    for raw in stmts {
        table.set(classify(raw, parseExpression(raw.tokens)))
        if firstId.isEmpty { firstId = raw.id }
    }
    return buildResult(table, firstId: firstId, incomplete: incomplete, count: table.count, library: library,
                       rootName: rootName ?? library?.root)
}

/// Incremental parser for streamed output: completed statements are cached behind a watermark so each chunk
/// only re-parses the pending tail.
public final class StreamParser {
    private let library: Library?
    private let rootName: String?
    private var buf = ""
    private var cleaned: [Unicode.Scalar] = []
    private var completedEnd = 0
    private var completed = StatementTable()
    private var completedCount = 0
    private var firstId = ""

    public init(library: Library?, rootName: String? = nil) {
        self.library = library
        self.rootName = rootName ?? library?.root
    }

    /// Appends a chunk and returns the latest result.
    @discardableResult
    public func push(_ chunk: String) -> ParseResult {
        buf += chunk
        return result()
    }

    /// Sets the full text so far; resets when the text was replaced rather than extended.
    @discardableResult
    public func set(_ fullText: String) -> ParseResult {
        if !fullText.hasPrefix(buf) { reset() }
        buf = fullText
        return result()
    }

    public func result() -> ParseResult {
        refreshCleaned()
        let pendingStart = scanNewCompleted()
        let pending = text(cleaned, pendingStart, cleaned.count).trimmingCharacters(in: .whitespacesAndNewlines)

        if pending.isEmpty {
            if completedCount == 0 { return .empty() }
            return buildResult(completed, firstId: firstId, incomplete: false, count: completedCount,
                               library: library, rootName: rootName)
        }

        let (closed, incomplete) = autoClose(pending)
        let stmts = split(tokenize(closed))
        if stmts.isEmpty {
            if completedCount == 0 { return .empty(incomplete: incomplete) }
            return buildResult(completed, firstId: firstId, incomplete: incomplete, count: completedCount,
                               library: library, rootName: rootName)
        }

        var all = completed
        for raw in stmts {
            if completed.has(raw.id), incomplete { continue }
            all.set(classify(raw, parseExpression(raw.tokens)))
        }
        return buildResult(all, firstId: firstId.isEmpty ? stmts[0].id : firstId, incomplete: incomplete,
                           count: completedCount + stmts.count, library: library, rootName: rootName)
    }

    private func reset() {
        buf = ""
        cleaned = []
        completedEnd = 0
        completed.removeAll()
        completedCount = 0
        firstId = ""
    }

    private func refreshCleaned() {
        let next = Array(preprocess(buf).unicodeScalars)
        if next.count < completedEnd || Array(next[0..<completedEnd]) != Array(cleaned[0..<min(completedEnd, cleaned.count)]) {
            completedEnd = 0
            completed.removeAll()
            completedCount = 0
            firstId = ""
        }
        cleaned = next
    }

    private func addStatements(_ source: String) {
        let t = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        for raw in split(tokenize(t)) {
            completed.set(classify(raw, parseExpression(raw.tokens)))
            completedCount += 1
            if firstId.isEmpty { firstId = raw.id }
        }
    }

    private func scanNewCompleted() -> Int {
        var depth = 0, ternaryDepth = 0
        var inStr: Unicode.Scalar?
        var esc = false
        var stmtStart = completedEnd
        var i = completedEnd
        while i < cleaned.count {
            defer { i += 1 }
            let c = cleaned[i]
            if esc { esc = false; continue }
            if c == "\\", inStr != nil { esc = true; continue }
            if let quote = inStr { if c == quote { inStr = nil }; continue }
            if c == "\"" || c == "'" { inStr = c; continue }
            if c == "(" || c == "[" || c == "{" { depth += 1 }
            else if c == ")" || c == "]" || c == "}" { depth = max(0, depth - 1) }
            else if c == "?", depth == 0 { ternaryDepth += 1 }
            else if c == ":", depth == 0, ternaryDepth > 0 { ternaryDepth -= 1 }
            else if c == "\n", depth <= 0, ternaryDepth <= 0 {
                var peek = i + 1
                while peek < cleaned.count, [" ", "\t", "\r", "\n"].contains(cleaned[peek]) { peek += 1 }
                if peek < cleaned.count, cleaned[peek] == "?" || (cleaned[peek] == ":" && ternaryDepth > 0) { continue }
                addStatements(text(cleaned, stmtStart, i))
                stmtStart = i + 1
                completedEnd = i + 1
            }
        }
        return stmtStart
    }
}

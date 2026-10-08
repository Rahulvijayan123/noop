import Foundation

struct RawStatement {
    let id: String
    /// The identifier's token kind, which decides whether this is a `$state` declaration.
    let idKind: T
    let tokens: [Token]
}

/// Upstream `autoClose`: closes an unterminated string and any open brackets so partial input still parses.
func autoClose(_ input: String) -> (text: String, wasIncomplete: Bool) {
    var stack: [Unicode.Scalar] = []
    var inStr: Unicode.Scalar?
    var esc = false
    for c in input.unicodeScalars {
        if esc { esc = false; continue }
        if c == "\\", inStr != nil { esc = true; continue }
        if let quote = inStr {
            if c == quote { inStr = nil }
            continue
        }
        if c == "\"" || c == "'" { inStr = c; continue }
        if c == "(" || c == "[" || c == "{" { stack.append(c) }
        else if c == ")", stack.last == "(" { stack.removeLast() }
        else if c == "]", stack.last == "[" { stack.removeLast() }
        else if c == "}", stack.last == "{" { stack.removeLast() }
    }
    let incomplete = inStr != nil || !stack.isEmpty
    guard incomplete else { return (input, false) }
    var out = input
    if let quote = inStr {
        if esc { out += "\\" }
        out.unicodeScalars.append(quote)
    }
    for open in stack.reversed() {
        out += open == "(" ? ")" : open == "[" ? "]" : "}"
    }
    return (out, true)
}

/// Upstream `split`: `identifier = expression` statements, separated by newlines at bracket depth 0. A
/// newline followed by `?` or `:` continues a ternary. Lines that are not statements are skipped.
func split(_ tokens: [Token]) -> [RawStatement] {
    var stmts: [RawStatement] = []
    var pos = 0
    let count = tokens.count

    func skipLine() {
        while pos < count, tokens[pos].t != .newline, tokens[pos].t != .eof { pos += 1 }
    }

    while pos < count {
        while pos < count, tokens[pos].t == .newline { pos += 1 }
        if pos >= count || tokens[pos].t == .eof { break }

        let tok = tokens[pos]
        guard tok.t == .ident || tok.t == .type || tok.t == .stateVar else { skipLine(); continue }
        pos += 1
        guard pos < count, tokens[pos].t == .equals else { skipLine(); continue }
        pos += 1

        var expr: [Token] = []
        var depth = 0
        var ternaryDepth = 0
        while pos < count, tokens[pos].t != .eof {
            let tt = tokens[pos].t
            if tt == .newline, depth <= 0, ternaryDepth <= 0 {
                var peek = pos + 1
                while peek < count, tokens[peek].t == .newline { peek += 1 }
                let nextT = peek < count ? tokens[peek].t : .eof
                if nextT == .question || (nextT == .colon && ternaryDepth > 0) {
                    pos += 1
                    continue
                }
                break
            }
            if tt == .newline { pos += 1; continue }
            if tt == .lParen || tt == .lBrack || tt == .lBrace { depth += 1 }
            else if tt == .rParen || tt == .rBrack || tt == .rBrace, depth > 0 { depth -= 1 }
            else if tt == .question, depth == 0 { ternaryDepth += 1 }
            else if tt == .colon, depth == 0, ternaryDepth > 0 { ternaryDepth -= 1 }
            expr.append(tokens[pos])
            pos += 1
        }
        if !expr.isEmpty { stmts.append(RawStatement(id: tok.s, idKind: tok.t, tokens: expr)) }
    }
    return stmts
}

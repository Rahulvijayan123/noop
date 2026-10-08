import Foundation

enum T: Equatable {
    case newline, lParen, rParen, lBrack, rBrack, lBrace, rBrace, comma, colon, equals
    case `true`, `false`, null, eof
    case str, num, ident, type, stateVar
    case dot, plus, minus, star, slash, percent
    case eqEq, notEq, greater, less, greaterEq, lessEq, and, or, not, question
    case builtinCall
}

struct Token: Equatable {
    let t: T
    var s: String = ""
    var n: Double = 0
}

/// Upstream `tokenize`: one pass over the source; newlines are significant, unknown characters are skipped.
func tokenize(_ src: String) -> [Token] {
    let c = Array(src.unicodeScalars)
    let n = c.count
    var tokens: [Token] = []
    var i = 0

    func isLower(_ s: Unicode.Scalar) -> Bool { s >= "a" && s <= "z" }
    func isUpper(_ s: Unicode.Scalar) -> Bool { s >= "A" && s <= "Z" }
    func isDigit(_ s: Unicode.Scalar) -> Bool { s >= "0" && s <= "9" }
    func isIdentStart(_ s: Unicode.Scalar) -> Bool { isLower(s) || isUpper(s) || s == "_" }
    func isIdentPart(_ s: Unicode.Scalar) -> Bool { isIdentStart(s) || isDigit(s) }
    func text(_ from: Int, _ to: Int) -> String { String(String.UnicodeScalarView(c[from..<to])) }
    func next(_ offset: Int = 1) -> Unicode.Scalar? { i + offset < n ? c[i + offset] : nil }

    while i < n {
        while i < n, c[i] == " " || c[i] == "\t" || c[i] == "\r" { i += 1 }
        if i >= n { break }
        let ch = c[i]

        switch ch {
        case "\n": tokens.append(Token(t: .newline)); i += 1; continue
        case "(": tokens.append(Token(t: .lParen)); i += 1; continue
        case ")": tokens.append(Token(t: .rParen)); i += 1; continue
        case "[": tokens.append(Token(t: .lBrack)); i += 1; continue
        case "]": tokens.append(Token(t: .rBrack)); i += 1; continue
        case "{": tokens.append(Token(t: .lBrace)); i += 1; continue
        case "}": tokens.append(Token(t: .rBrace)); i += 1; continue
        case ",": tokens.append(Token(t: .comma)); i += 1; continue
        case ":": tokens.append(Token(t: .colon)); i += 1; continue
        case "=":
            if next() == "=" { tokens.append(Token(t: .eqEq)); i += 2 } else { tokens.append(Token(t: .equals)); i += 1 }
            continue
        case "!":
            if next() == "=" { tokens.append(Token(t: .notEq)); i += 2 } else { tokens.append(Token(t: .not)); i += 1 }
            continue
        case ">":
            if next() == "=" { tokens.append(Token(t: .greaterEq)); i += 2 } else { tokens.append(Token(t: .greater)); i += 1 }
            continue
        case "<":
            if next() == "=" { tokens.append(Token(t: .lessEq)); i += 2 } else { tokens.append(Token(t: .less)); i += 1 }
            continue
        case "&":
            tokens.append(Token(t: .and)); i += next() == "&" ? 2 : 1; continue
        case "|":
            tokens.append(Token(t: .or)); i += next() == "|" ? 2 : 1; continue
        case ".": tokens.append(Token(t: .dot)); i += 1; continue
        case "?": tokens.append(Token(t: .question)); i += 1; continue
        case "+": tokens.append(Token(t: .plus)); i += 1; continue
        case "*": tokens.append(Token(t: .star)); i += 1; continue
        case "/": tokens.append(Token(t: .slash)); i += 1; continue
        case "%": tokens.append(Token(t: .percent)); i += 1; continue
        default: break
        }

        // Double-quoted string: JSON escapes; an unclosed string (streaming) yields what has arrived.
        if ch == "\"" {
            let start = i
            i += 1
            var closed = false
            while i < n {
                if c[i] == "\\" { i += 2 } else if c[i] == "\"" { i += 1; closed = true; break } else { i += 1 }
            }
            let end = min(i, n)
            let inner = text(start + 1, closed ? end - 1 : end)
            tokens.append(Token(t: .str, s: jsonUnescape(inner) ?? inner))
            continue
        }

        if ch == "'" {
            i += 1
            var result = String.UnicodeScalarView()
            while i < n {
                if c[i] == "\\" {
                    i += 1
                    if i < n {
                        switch c[i] {
                        case "n": result.append("\n")
                        case "t": result.append("\t")
                        default: result.append(c[i])
                        }
                        i += 1
                    }
                } else if c[i] == "'" {
                    i += 1
                    break
                } else {
                    result.append(c[i]); i += 1
                }
            }
            tokens.append(Token(t: .str, s: String(result)))
            continue
        }

        if ch == "-" {
            let afterValue: Bool = {
                guard let prev = tokens.last?.t else { return false }
                return [.num, .str, .ident, .type, .rParen, .rBrack, .true, .false, .null, .stateVar, .builtinCall].contains(prev)
            }()
            if !(!afterValue && next().map(isDigit) == true) {
                tokens.append(Token(t: .minus)); i += 1; continue
            }
        }

        if isDigit(ch) || (ch == "-" && next().map(isDigit) == true) {
            let start = i
            if c[i] == "-" { i += 1 }
            while i < n, isDigit(c[i]) { i += 1 }
            if i < n, c[i] == ".", i + 1 < n, isDigit(c[i + 1]) {
                i += 1
                while i < n, isDigit(c[i]) { i += 1 }
            }
            if i < n, c[i] == "e" || c[i] == "E" {
                i += 1
                if i < n, c[i] == "+" || c[i] == "-" { i += 1 }
                while i < n, isDigit(c[i]) { i += 1 }
            }
            tokens.append(Token(t: .num, n: Double(text(start, i)) ?? 0))
            continue
        }

        if ch == "$", let s = next(), isIdentStart(s) {
            let start = i
            i += 1
            while i < n, isIdentPart(c[i]) { i += 1 }
            tokens.append(Token(t: .stateVar, s: text(start, i)))
            continue
        }

        if isIdentStart(ch) {
            let start = i
            while i < n, isIdentPart(c[i]) { i += 1 }
            let word = text(start, i)
            switch word {
            case "true": tokens.append(Token(t: .true))
            case "false": tokens.append(Token(t: .false))
            case "null": tokens.append(Token(t: .null))
            default: tokens.append(Token(t: isUpper(ch) ? .type : .ident, s: word))
            }
            continue
        }

        if ch == "@", let s = next(), isIdentStart(s) {
            i += 1
            let start = i
            while i < n, isIdentPart(c[i]) { i += 1 }
            tokens.append(Token(t: .builtinCall, s: text(start, i)))
            continue
        }

        i += 1
    }
    tokens.append(Token(t: .eof))
    return tokens
}

/// The body of a JSON string literal unescaped, as `JSON.parse` does; nil when an escape is malformed.
func jsonUnescape(_ body: String) -> String? {
    guard body.contains("\\") else { return body }
    let c = Array(body.unicodeScalars)
    var out = String.UnicodeScalarView()
    var i = 0
    var pendingHigh: UInt32?
    while i < c.count {
        let ch = c[i]
        guard ch == "\\" else {
            if pendingHigh != nil { return nil }
            out.append(ch); i += 1; continue
        }
        guard i + 1 < c.count else { return nil }
        let e = c[i + 1]
        i += 2
        if pendingHigh != nil, e != "u" { return nil }
        switch e {
        case "\"": out.append("\"")
        case "\\": out.append("\\")
        case "/": out.append("/")
        case "b": out.append("\u{08}")
        case "f": out.append("\u{0C}")
        case "n": out.append("\n")
        case "r": out.append("\r")
        case "t": out.append("\t")
        case "u":
            guard i + 4 <= c.count, let code = UInt32(String(String.UnicodeScalarView(c[i..<i + 4])), radix: 16) else { return nil }
            i += 4
            if let high = pendingHigh {
                guard (0xDC00...0xDFFF).contains(code) else { return nil }
                let scalar = 0x10000 + ((high - 0xD800) << 10) + (code - 0xDC00)
                guard let s = Unicode.Scalar(scalar) else { return nil }
                out.append(s)
                pendingHigh = nil
            } else if (0xD800...0xDBFF).contains(code) {
                pendingHigh = code
            } else {
                guard let s = Unicode.Scalar(code) else { return nil }
                out.append(s)
            }
        default: return nil
        }
    }
    return pendingHigh == nil ? String(out) : nil
}

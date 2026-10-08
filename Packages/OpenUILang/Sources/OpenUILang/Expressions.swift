import Foundation

private let precTernary = 1, precOr = 2, precAnd = 3, precEq = 4, precCmp = 5, precAdd = 6, precMul = 7,
            precUnary = 8, precMember = 9

/// Upstream `parseExpression`: a Pratt parser over one statement's tokens. It never throws; an unexpected token
/// becomes `null` so a half-streamed expression still yields a tree.
func parseExpression(_ tokens: [Token]) -> ASTNode {
    var pos = 0
    let eofToken = Token(t: .eof)

    func cur() -> Token { pos < tokens.count ? tokens[pos] : eofToken }
    func peek(_ offset: Int) -> Token { pos + offset < tokens.count ? tokens[pos + offset] : eofToken }
    @discardableResult func adv() -> Token { let t = cur(); pos += 1; return t }
    func eat(_ kind: T) { if cur().t == kind { pos += 1 } }

    func infixPrec(_ tok: Token) -> Int {
        switch tok.t {
        case .question: return precTernary
        case .or: return precOr
        case .and: return precAnd
        case .eqEq, .notEq: return precEq
        case .greater, .less, .greaterEq, .lessEq: return precCmp
        case .plus, .minus: return precAdd
        case .star, .slash, .percent: return precMul
        case .dot, .lBrack: return precMember
        default: return 0
        }
    }

    func parseExpr(_ minPrec: Int = 0) -> ASTNode {
        var left = parsePrefix()
        while infixPrec(cur()) > minPrec {
            left = parseInfix(left)
        }
        return left
    }

    func parsePrefix() -> ASTNode {
        let tok = cur()
        switch tok.t {
        case .str: adv(); return .str(tok.s)
        case .num: adv(); return .num(tok.n)
        case .true: adv(); return .bool(true)
        case .false: adv(); return .bool(false)
        case .null: adv(); return .null
        case .lBrack: return parseArr()
        case .lBrace: return parseObj()
        case .stateVar:
            adv()
            if cur().t == .equals {
                adv()
                return .assign(tok.s, parseExpr(0))
            }
            return .stateRef(tok.s)
        case .type:
            // Built-ins need the @ prefix; only Action is written bare.
            if peek(1).t == .lParen, !Builtins.isBuiltin(tok.s) || tok.s == "Action" { return parseComp() }
            adv()
            return .ref(tok.s)
        case .builtinCall:
            if peek(1).t == .lParen { return parseComp() }
            adv()
            return .ref(tok.s)
        case .ident: adv(); return .ref(tok.s)
        case .not: adv(); return .unaryOp("!", parseExpr(precUnary))
        case .minus: adv(); return .unaryOp("-", parseExpr(precUnary))
        case .lParen:
            adv()
            let inner = parseExpr(0)
            eat(.rParen)
            return inner
        default:
            adv()
            return .null
        }
    }

    func binary(_ op: String, _ left: ASTNode, _ prec: Int) -> ASTNode {
        adv()
        return .binOp(op, left, parseExpr(prec))
    }

    func parseInfix(_ left: ASTNode) -> ASTNode {
        let tok = cur()
        switch tok.t {
        case .plus: return binary("+", left, precAdd)
        case .minus: return binary("-", left, precAdd)
        case .star: return binary("*", left, precMul)
        case .slash: return binary("/", left, precMul)
        case .percent: return binary("%", left, precMul)
        case .eqEq: return binary("==", left, precEq)
        case .notEq: return binary("!=", left, precEq)
        case .greater: return binary(">", left, precCmp)
        case .less: return binary("<", left, precCmp)
        case .greaterEq: return binary(">=", left, precCmp)
        case .lessEq: return binary("<=", left, precCmp)
        case .and: return binary("&&", left, precAnd)
        case .or: return binary("||", left, precOr)
        case .question:
            adv()
            let then = parseExpr(0)
            eat(.colon)
            let otherwise = parseExpr(0)
            return .ternary(left, then, otherwise)
        case .dot:
            adv()
            let fieldTok = cur()
            adv()
            switch fieldTok.t {
            case .ident, .type, .str: return .member(left, fieldTok.s)
            case .num: return .member(left, JS.format(fieldTok.n))
            case .stateVar: return .member(left, String(fieldTok.s.dropFirst()))
            default: return .member(left, "?")
            }
        case .lBrack:
            adv()
            let index = parseExpr(0)
            eat(.rBrack)
            return .index(left, index)
        default:
            return left
        }
    }

    func parseComp() -> ASTNode {
        let name = cur().s
        adv()
        eat(.lParen)
        var args: [ASTNode] = []
        while cur().t != .rParen, cur().t != .eof {
            args.append(parseExpr(0))
            if cur().t == .comma { adv() }
        }
        eat(.rParen)
        return .comp(name: name, args: args, mapped: nil)
    }

    func parseArr() -> ASTNode {
        adv()
        var els: [ASTNode] = []
        while cur().t != .rBrack, cur().t != .eof {
            els.append(parseExpr(0))
            if cur().t == .comma { adv() }
        }
        eat(.rBrack)
        return .arr(els)
    }

    func parseObj() -> ASTNode {
        adv()
        var entries: [ASTNode.ObjectEntry] = []
        while cur().t != .rBrace, cur().t != .eof {
            let kt = cur()
            adv()
            let key: String
            switch kt.t {
            case .ident, .str, .type: key = kt.s
            case .num: key = JS.format(kt.n)
            case .stateVar: key = String(kt.s.dropFirst())
            default: key = "?"
            }
            eat(.colon)
            entries.append(.init(key, parseExpr(0)))
            if cur().t == .comma { adv() }
        }
        eat(.rBrace)
        return .obj(entries)
    }

    return parseExpr(0)
}

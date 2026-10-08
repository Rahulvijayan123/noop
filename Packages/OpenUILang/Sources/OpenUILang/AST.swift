import Foundation

public enum RuntimeRefType: String, Equatable, Sendable { case query, mutation }

/// Every value that can appear in an OpenUI Lang expression (upstream `ASTNode`, discriminated by `k`).
public indirect enum ASTNode: Equatable, Sendable {
    /// A component or built-in call. `mapped` is filled by the materializer for catalog components used inside
    /// runtime expressions, so the evaluator can build their props by name.
    case comp(name: String, args: [ASTNode], mapped: [String: ASTNode]?)
    case str(String)
    case num(Double)
    case bool(Bool)
    case null
    case arr([ASTNode])
    case obj([ObjectEntry])
    /// A reference to another statement.
    case ref(String)
    /// A reference that could not be resolved (yet).
    case ph(String)
    case stateRef(String)
    case runtimeRef(String, RuntimeRefType)
    case binOp(String, ASTNode, ASTNode)
    case unaryOp(String, ASTNode)
    case ternary(ASTNode, ASTNode, ASTNode)
    case member(ASTNode, String)
    case index(ASTNode, ASTNode)
    case assign(String, ASTNode)

    public struct ObjectEntry: Equatable, Sendable {
        public var key: String
        public var value: ASTNode
        public init(_ key: String, _ value: ASTNode) { self.key = key; self.value = value }
    }

    /// Nodes that survive lowering and are resolved by the evaluator (upstream `isRuntimeExpr`).
    var isRuntimeExpr: Bool {
        switch self {
        case .stateRef, .runtimeRef, .binOp, .unaryOp, .ternary, .member, .index, .assign: return true
        default: return false
        }
    }

    func walk(_ visit: (ASTNode) -> Void) {
        visit(self)
        switch self {
        case .comp(_, let args, let mapped):
            args.forEach { $0.walk(visit) }
            mapped?.values.forEach { $0.walk(visit) }
        case .arr(let els): els.forEach { $0.walk(visit) }
        case .obj(let entries): entries.forEach { $0.value.walk(visit) }
        case .binOp(_, let l, let r): l.walk(visit); r.walk(visit)
        case .unaryOp(_, let o): o.walk(visit)
        case .ternary(let c, let t, let e): c.walk(visit); t.walk(visit); e.walk(visit)
        case .member(let o, _): o.walk(visit)
        case .index(let o, let i): o.walk(visit); i.walk(visit)
        case .assign(_, let v): v.walk(visit)
        default: break
        }
    }

    /// The `$variables` referenced anywhere inside (upstream `collectQueryDeps`).
    var stateRefs: [String] {
        var seen: [String] = []
        walk { node in
            if case .stateRef(let n) = node, !seen.contains(n) { seen.append(n) }
        }
        return seen
    }
}

/// A typed statement, classified at parse time from the identifier token and the expression's shape.
enum Statement {
    case value(id: String, expr: ASTNode)
    case state(id: String, initial: ASTNode)
    case query(id: String, args: [ASTNode], expr: ASTNode)
    case mutation(id: String, args: [ASTNode], expr: ASTNode)

    var id: String {
        switch self {
        case .value(let id, _), .state(let id, _), .query(let id, _, _), .mutation(let id, _, _): return id
        }
    }

    /// The node the symbol table holds for this statement.
    var node: ASTNode {
        switch self {
        case .value(_, let expr), .query(_, _, let expr), .mutation(_, _, let expr): return expr
        case .state(_, let initial): return initial
        }
    }
}

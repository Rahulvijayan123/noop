import Foundation

public enum ValidationCode: String, Equatable, Sendable {
    case missingRequired = "missing-required"
    case nullRequired = "null-required"
    case unknownComponent = "unknown-component"
    case inlineReserved = "inline-reserved"
    case excessArgs = "excess-args"
    case typeMismatch = "type-mismatch"
}

public struct ValidationError: Equatable, Sendable {
    public let code: ValidationCode
    public let component: String
    /// JSON-pointer path inside the props ("/title", "" for the component itself).
    public let path: String
    public let message: String
    public let statementId: String?
}

final class MaterializeContext {
    var syms: [String: ASTNode]
    let library: Library?
    var errors: [ValidationError] = []
    var unresolved: [String] = []
    var visited: Set<String> = []
    let partial: Bool
    var currentStatementId: String?
    var unreached: Set<String>

    init(syms: [String: ASTNode], library: Library?, partial: Bool, currentStatementId: String?, unreached: Set<String>) {
        self.syms = syms
        self.library = library
        self.partial = partial
        self.currentStatementId = currentStatementId
        self.unreached = unreached
    }

    enum Issue {
        case typeMismatch(expected: String, actual: String)
        case missingRequired(signature: String?)
        case nullRequired(signature: String?)
        case unknownComponent(available: [String]?)
        case inlineReserved
        case excessArgs(declared: Int, got: Int)
    }

    func push(_ component: String, _ path: String, _ issue: Issue) {
        let code: ValidationCode
        let message: String
        switch issue {
        case .typeMismatch(let expected, let actual):
            code = .typeMismatch
            message = "field \"\(path)\" expects \(expected) but got \(actual)"
        case .missingRequired(let sig):
            code = .missingRequired
            message = "missing required field \"\(path)\"" + (sig.map { " — signature: \($0)" } ?? "")
        case .nullRequired(let sig):
            code = .nullRequired
            message = "required field \"\(path)\" cannot be null" + (sig.map { " — signature: \($0)" } ?? "")
        case .unknownComponent(let available):
            code = .unknownComponent
            let list = available.flatMap { $0.isEmpty ? nil : ". Available components: " + $0.joined(separator: ", ") } ?? ""
            message = "Unknown component \"\(component)\" — not found in catalog or builtins\(list)"
        case .inlineReserved:
            code = .inlineReserved
            message = "\(component)() must be declared as a top-level statement, not used inline as a value"
        case .excessArgs(let declared, let got):
            code = .excessArgs
            message = "\(component) takes \(declared) arg(s), got \(got) (\(got - declared) excess dropped)"
        }
        errors.append(ValidationError(code: code, component: component, path: path, message: message,
                                      statementId: currentStatementId))
    }
}

// MARK: - References

private enum Mode { case value, expr }

private enum Resolved {
    case value(Value)
    case node(ASTNode)
}

/// Inlines a statement from the symbol table, detecting cycles, and turns Query/Mutation declarations into
/// runtime references.
private func resolveRef(_ name: String, _ ctx: MaterializeContext, _ mode: Mode) -> Resolved {
    guard !ctx.visited.contains(name), let target = ctx.syms[name] else {
        ctx.unresolved.append(name)
        return mode == .expr ? .node(.ph(name)) : .value(.null)
    }
    ctx.unreached.remove(name)
    if case .comp(let callee, _, _) = target, Builtins.isReservedCall(callee) {
        let node = ASTNode.runtimeRef(name, callee == "Mutation" ? .mutation : .query)
        return mode == .expr ? .node(node) : .value(.expr(node))
    }
    ctx.visited.insert(name)
    let previous = ctx.currentStatementId
    ctx.currentStatementId = name
    defer {
        ctx.currentStatementId = previous
        ctx.visited.remove(name)
    }
    switch mode {
    case .value:
        var result = materializeValue(target, ctx)
        if case .element(var el) = result {
            el.statementId = name
            result = .element(el)
        }
        return .value(result)
    case .expr:
        return .node(materializeExpr(target, ctx))
    }
}

// MARK: - Runtime expressions

private func materializeLazy(_ name: String, _ args: [ASTNode], _ ctx: MaterializeContext, _ scoped: Set<String>) -> ASTNode? {
    guard Builtins.lazy.contains(name), args.count >= 3 else { return nil }
    let varName: String?
    switch args[1] {
    case .ref(let n): varName = n
    case .str(let s): varName = s
    default: varName = nil
    }
    guard let varName else { return nil }
    let inner = scoped.union([varName])
    let recursed = args.enumerated().map { i, a in i == 1 ? a : materializeExprInternal(a, ctx, inner) }
    return .comp(name: name, args: recursed, mapped: nil)
}

private func materializeExprInternal(_ node: ASTNode, _ ctx: MaterializeContext, _ scoped: Set<String>) -> ASTNode {
    switch node {
    case .ref(let n):
        if scoped.contains(n) { return node }
        if case .node(let resolved) = resolveRef(n, ctx, .expr) { return resolved }
        return .ph(n)
    case .ph:
        return node
    case .comp(let name, let args, _):
        if let lazy = materializeLazy(name, args, ctx, scoped) { return lazy }
        let recursed = args.map { materializeExprInternal($0, ctx, scoped) }
        if Builtins.isBuiltin(name) || Builtins.isReservedCall(name) {
            return .comp(name: name, args: recursed, mapped: nil)
        }
        if let def = ctx.library?.component(name) {
            var mapped: [String: ASTNode] = [:]
            for (i, param) in def.params.enumerated() where i < recursed.count {
                mapped[param.name] = recursed[i]
            }
            return .comp(name: name, args: recursed, mapped: mapped)
        }
        ctx.push(name, "", .unknownComponent(available: ctx.library?.componentNames))
        return .comp(name: name, args: recursed, mapped: nil)
    case .arr(let els):
        return .arr(els.map { materializeExprInternal($0, ctx, scoped) })
    case .obj(let entries):
        return .obj(entries.map { .init($0.key, materializeExprInternal($0.value, ctx, scoped)) })
    case .binOp(let op, let l, let r):
        return .binOp(op, materializeExprInternal(l, ctx, scoped), materializeExprInternal(r, ctx, scoped))
    case .unaryOp(let op, let o):
        return .unaryOp(op, materializeExprInternal(o, ctx, scoped))
    case .ternary(let c, let t, let e):
        return .ternary(materializeExprInternal(c, ctx, scoped), materializeExprInternal(t, ctx, scoped),
                        materializeExprInternal(e, ctx, scoped))
    case .member(let o, let f):
        return .member(materializeExprInternal(o, ctx, scoped), f)
    case .index(let o, let i):
        return .index(materializeExprInternal(o, ctx, scoped), materializeExprInternal(i, ctx, scoped))
    case .assign(let target, let v):
        return .assign(target, materializeExprInternal(v, ctx, scoped))
    default:
        return node
    }
}

/// Resolves references and maps catalog components' positional args to names, keeping the expression for the
/// evaluator.
func materializeExpr(_ node: ASTNode, _ ctx: MaterializeContext) -> ASTNode {
    materializeExprInternal(node, ctx, [])
}

// MARK: - Values

/// True when a value still holds something the evaluator must resolve.
func containsDynamicValue(_ v: Value) -> Bool {
    switch v {
    case .expr: return true
    case .array(let a): return a.contains(where: containsDynamicValue)
    case .object(let o): return o.values.contains(where: containsDynamicValue)
    case .element(let e): return e.props.values.contains(where: containsDynamicValue)
    default: return false
    }
}

/// Upstream `materializeValue`: one recursive pass that resolves references, maps positional args to named props,
/// validates them, applies defaults, lowers literals to plain values and keeps runtime expressions as AST.
/// Components missing a required prop, and unknown components, come back as `.null` with an error recorded.
func materializeValue(_ node: ASTNode, _ ctx: MaterializeContext) -> Value {
    switch node {
    case .ref(let n):
        if case .value(let v) = resolveRef(n, ctx, .value) { return v }
        return .null
    case .str(let s): return .string(s)
    case .num(let n): return .number(n)
    case .bool(let b): return .bool(b)
    case .null, .ph: return .null

    case .arr(let els):
        var items: [Value] = []
        for e in els {
            if case .ph = e { continue }
            let value = materializeValue(e, ctx)
            if value.isNull {
                switch e {
                case .comp, .ref: continue
                default: break
                }
            }
            items.append(value)
        }
        return .array(items)

    case .obj(let entries):
        var o: [String: Value] = [:]
        for entry in entries { o[entry.key] = materializeValue(entry.value, ctx) }
        return .object(o)

    case .comp(let name, let args, _):
        if Builtins.isBuiltin(name) {
            if let lazy = materializeLazy(name, args, ctx, []) { return .expr(lazy) }
            return .expr(.comp(name: name, args: args.map { materializeExpr($0, ctx) }, mapped: nil))
        }
        if Builtins.isReservedCall(name) {
            ctx.push(name, "", .inlineReserved)
            return .null
        }
        guard let def = ctx.library?.component(name) else {
            ctx.push(name, "", .unknownComponent(available: ctx.library?.componentNames))
            return .null
        }
        var props: [String: Value] = [:]
        var dropComponent = false
        for (i, param) in def.params.enumerated() where i < args.count {
            var value = materializeValue(args[i], ctx)
            let invalid = param.type.map { validate(&value, $0, name, "/\(param.name)", ctx) } ?? false
            props[param.name] = value
            if invalid, resolveInvalid(&props, param) { dropComponent = true }
        }
        if args.count > def.params.count {
            ctx.push(name, "", .excessArgs(declared: def.params.count, got: args.count))
        }
        let missing = def.params.filter { p in p.required && (props[p.name] ?? .null).isNull }
        var stillMissing: [ParamDef] = []
        for p in missing {
            if let fallback = p.defaultValue { props[p.name] = fallback } else { stillMissing.append(p) }
        }
        if !stillMissing.isEmpty {
            for p in stillMissing {
                ctx.push(name, "/\(p.name)", props[p.name] != nil ? .nullRequired(signature: def.errorSignature)
                                                                  : .missingRequired(signature: def.errorSignature))
            }
            return .null
        }
        if dropComponent { return .null }
        let dynamic = props.values.contains(where: containsDynamicValue)
        return .element(Element(typeName: name, props: props, partial: ctx.partial, hasDynamicProps: dynamic))

    default:
        if node.isRuntimeExpr { return .expr(materializeExpr(node, ctx)) }
        return .expr(node)
    }
}

/// Upstream `resolveInvalidValue`: substitute the default when there is one, propagate when the prop is
/// required, otherwise drop it. Returns true when the component itself must be dropped.
private func resolveInvalid(_ props: inout [String: Value], _ param: ParamDef) -> Bool {
    if let fallback = param.defaultValue {
        props[param.name] = fallback
        return false
    }
    if param.required { return true }
    props.removeValue(forKey: param.name)
    return false
}

// MARK: - Validation

private func jsType(_ v: Value) -> String {
    switch v {
    case .null: return "null"
    case .bool: return "boolean"
    case .number: return "number"
    case .string: return "string"
    case .array: return "array"
    case .object: return "object"
    case .element(let e): return "component \"\(e.typeName)\""
    default: return "object"
    }
}

private func isComponentOnly(_ type: PropType) -> Bool {
    switch type {
    case .component: return true
    case .union(let members): return !members.isEmpty && members.allSatisfy(isComponentOnly)
    default: return false
    }
}

private func admitsComponents(_ type: PropType) -> Bool {
    switch type {
    case .component, .any: return true
    case .union(let members): return members.contains(where: admitsComponents)
    case .binding(let inner): return admitsComponents(inner)
    default: return false
    }
}

/// Validates (and, where safe, coerces) a materialized value against a prop type, pruning what cannot be
/// salvaged. Returns true when the value is invalid at this edge. Coercions beyond upstream: a number in a
/// string slot becomes its text, a numeric string in a number slot becomes the number, and a lone value in an
/// array slot is wrapped, because models make those slips often and the intent is unambiguous.
@discardableResult
func validate(_ value: inout Value, _ type: PropType, _ component: String, _ path: String, _ ctx: MaterializeContext) -> Bool {
    if value.isNull { return false }
    if case .expr = value { return false }

    switch type {
    case .any, .action, .record:
        return false

    case .binding(let inner):
        return validate(&value, inner, component, path, ctx)

    case .component, .union:
        if case .element = value { return false }
        guard isComponentOnly(type) else { return false }
        let actual: String
        switch value {
        case .array: actual = "array"
        case .object: actual = "plain object"
        default: actual = jsType(value)
        }
        ctx.push(component, path, .typeMismatch(expected: type.signature, actual: actual))
        return true

    case .array(let item):
        if case .array = value {} else {
            if case .element = value, !admitsComponents(item) {
                ctx.push(component, path, .typeMismatch(expected: "array", actual: jsType(value)))
                return true
            }
            value = .array([value])
        }
        guard case .array(var items) = value else { return false }
        var invalid: [Int] = []
        for i in items.indices where validate(&items[i], item, component, "\(path)/\(i)", ctx) {
            invalid.append(i)
        }
        for i in invalid.reversed() { items.remove(at: i) }
        value = .array(items)
        return false

    case .object(let fields):
        guard case .object(var o) = value else {
            ctx.push(component, path, .typeMismatch(expected: "object", actual: jsType(value)))
            return true
        }
        var invalid = false
        if !ctx.partial {
            for field in fields where field.required && (o[field.name] ?? .null).isNull {
                ctx.push(component, "\(path)/\(field.name)", o[field.name] == nil ? .missingRequired(signature: nil)
                                                                                 : .nullRequired(signature: nil))
                invalid = true
            }
        }
        for field in fields {
            guard var sub = o[field.name] else { continue }
            if validate(&sub, field.type, component, "\(path)/\(field.name)", ctx) {
                if field.required { invalid = true }
                o.removeValue(forKey: field.name)
            } else {
                o[field.name] = sub
            }
        }
        value = .object(o)
        return invalid

    case .string:
        switch value {
        case .string: return false
        case .number(let n): value = .string(JS.format(n)); return false
        default:
            ctx.push(component, path, .typeMismatch(expected: "string", actual: jsType(value)))
            return true
        }

    case .number:
        switch value {
        case .number: return false
        case .string(let s):
            if let n = JS.number(fromString: s), !s.trimmingCharacters(in: .whitespaces).isEmpty {
                value = .number(n)
                return false
            }
            ctx.push(component, path, .typeMismatch(expected: "number", actual: "string"))
            return true
        default:
            ctx.push(component, path, .typeMismatch(expected: "number", actual: jsType(value)))
            return true
        }

    case .boolean:
        if case .bool = value { return false }
        ctx.push(component, path, .typeMismatch(expected: "boolean", actual: jsType(value)))
        return true

    case .literal(let allowed):
        if ctx.partial { return false }
        switch value {
        case .string(let s):
            if allowed.contains(s) { return false }
            ctx.push(component, path, .typeMismatch(expected: "one of [" + allowed.map { "\"\($0)\"" }.joined(separator: ", ") + "]",
                                                    actual: "\"\(s)\""))
            return true
        case .number, .bool:
            ctx.push(component, path, .typeMismatch(expected: "one of [" + allowed.map { "\"\($0)\"" }.joined(separator: ", ") + "]",
                                                    actual: JS.string(value)))
            return true
        case .element:
            ctx.push(component, path, .typeMismatch(expected: "a literal value", actual: jsType(value)))
            return true
        default:
            return false
        }
    }
}

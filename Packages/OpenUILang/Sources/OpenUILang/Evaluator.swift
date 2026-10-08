import Foundation

/// Resolves runtime expressions against state (upstream `evaluate` + `evaluateElementProps`). Bindable props
/// that hold a bare `$variable` evaluate to `.binding(name)` so the renderer can write back to the store.
public struct Evaluator {
    public let library: Library?
    public let getState: (String) -> Value
    /// Query/Mutation results. Nara does not run tools from generated UI, so this defaults to null.
    public let resolveRef: (String) -> Value

    public init(library: Library?, getState: @escaping (String) -> Value,
                resolveRef: @escaping (String) -> Value = { _ in .null }) {
        self.library = library
        self.getState = getState
        self.resolveRef = resolveRef
    }

    public init(library: Library?, store: StateStore) {
        self.init(library: library, getState: { store.get($0) })
    }

    // MARK: Trees

    /// Evaluates every dynamic prop of an element tree into concrete values.
    public func evaluate(_ element: Element) -> Element {
        guard element.hasDynamicProps else { return element }
        var out = element
        for (key, value) in element.props {
            out.props[key] = evaluateProp(value, library?.propType(element.typeName, key), scope: [:])
        }
        return out
    }

    private func evaluateProp(_ value: Value, _ type: PropType?, scope: [String: Value]) -> Value {
        switch value {
        case .expr(let node):
            if case .stateRef(let name) = node, type.map(acceptsBinding) == true { return .binding(name) }
            let result = evaluate(node, scope: scope)
            switch result {
            case .element(let el): return .element(evaluate(el))
            case .array(let items):
                return .array(items.map { if case .element(let el) = $0 { return .element(evaluate(el)) } else { return $0 } })
            default: return result
            }
        case .array(let items):
            let itemType: PropType? = { if case .array(let t) = type { return t } else { return type } }()
            return .array(items.map { evaluateProp($0, itemType, scope: scope) })
        case .element(let el):
            return .element(evaluate(el))
        case .object(let o):
            var out: [String: Value] = [:]
            for (k, v) in o {
                let fieldType: PropType? = {
                    if case .object(let fields) = type { return fields.first { $0.name == k }?.type }
                    return nil
                }()
                out[k] = evaluateProp(v, fieldType, scope: scope)
            }
            return .object(out)
        default:
            return value
        }
    }

    private func acceptsBinding(_ type: PropType) -> Bool {
        switch type {
        case .binding: return true
        case .union(let members): return members.contains(where: acceptsBinding)
        default: return false
        }
    }

    // MARK: Expressions

    public func evaluate(_ node: ASTNode, scope: [String: Value] = [:]) -> Value {
        switch node {
        case .str(let s): return .string(s)
        case .num(let n): return .number(n)
        case .bool(let b): return .bool(b)
        case .null, .ph: return .null
        case .stateRef(let n): return scope[n] ?? getState(n)
        case .ref(let n): return scope[n] ?? resolveRef(n)
        case .runtimeRef(let n, _): return resolveRef(n)
        case .arr(let els): return .array(els.map { evaluate($0, scope: scope) })
        case .obj(let entries):
            var o: [String: Value] = [:]
            for e in entries { o[e.key] = evaluate(e.value, scope: scope) }
            return .object(o)

        case .comp(let name, let args, let mapped):
            if Builtins.lazy.contains(name) { return evaluateEach(args, scope: scope) }
            if let builtin = Builtins.byName[name] { return builtin.fn(args.map { evaluate($0, scope: scope) }) }
            if Builtins.actionNames.contains(name) { return evaluateAction(name, args, scope: scope) }
            guard let mapped else { return .null }
            var props: [String: Value] = [:]
            for (key, val) in mapped {
                let type = library?.propType(name, key)
                if case .stateRef(let n) = val {
                    props[key] = type.map(acceptsBinding) == true ? .binding(n) : getState(n)
                } else {
                    var v = evaluate(val, scope: scope)
                    if case .element(let el) = v { v = .element(evaluate(el)) }
                    props[key] = v
                }
            }
            return .element(Element(typeName: name, props: props, partial: false, hasDynamicProps: false))

        case .binOp(let op, let l, let r):
            if op == "&&" {
                let left = evaluate(l, scope: scope)
                return JS.truthy(left) ? evaluate(r, scope: scope) : left
            }
            if op == "||" {
                let left = evaluate(l, scope: scope)
                return JS.truthy(left) ? left : evaluate(r, scope: scope)
            }
            let left = evaluate(l, scope: scope), right = evaluate(r, scope: scope)
            let a = JS.toNumber(left), b = JS.toNumber(right)
            switch op {
            case "+":
                if left.stringValue != nil || right.stringValue != nil {
                    return .string((left.isNull ? "" : JS.string(left)) + (right.isNull ? "" : JS.string(right)))
                }
                return .number(a + b)
            case "-": return .number(a - b)
            case "*": return .number(a * b)
            // Upstream's DSL choice: division or remainder by zero is 0, not Infinity/NaN.
            case "/": return .number(b == 0 ? 0 : a / b)
            case "%": return .number(b == 0 ? 0 : a.truncatingRemainder(dividingBy: b))
            case "==": return .bool(JS.looseEquals(left, right))
            case "!=": return .bool(!JS.looseEquals(left, right))
            case ">": return .bool(a > b)
            case "<": return .bool(a < b)
            case ">=": return .bool(a >= b)
            case "<=": return .bool(a <= b)
            default: return .null
            }

        case .unaryOp(let op, let operand):
            let v = evaluate(operand, scope: scope)
            if op == "!" { return .bool(!JS.truthy(v)) }
            if op == "-" { return .number(-JS.toNumber(v)) }
            return .null

        case .ternary(let c, let t, let e):
            return JS.truthy(evaluate(c, scope: scope)) ? evaluate(t, scope: scope) : evaluate(e, scope: scope)

        case .member(let objNode, let field):
            let obj = evaluate(objNode, scope: scope)
            switch obj {
            case .array(let items):
                if field == "length" { return .number(Double(items.count)) }
                return .array(items.map { $0[field] })
            case .object(let o): return o[field] ?? .null
            case .string(let s): return field == "length" ? .number(Double(s.utf16.count)) : .null
            case .element(let el): return el[field]
            default: return .null
            }

        case .index(let objNode, let idxNode):
            let obj = evaluate(objNode, scope: scope), idx = evaluate(idxNode, scope: scope)
            if obj.isNull || idx.isNull { return .null }
            if case .array(let items) = obj {
                let n = JS.toNumber(idx)
                guard n == n.rounded(), n >= 0, Int(n) < items.count else { return .null }
                return items[Int(n)]
            }
            if case .object(let o) = obj { return o[JS.string(idx)] ?? .null }
            return .null

        case .assign(let target, _):
            // Outside a bindable prop an assignment reads as the variable's current value.
            return getState(target)
        }
    }

    private func evaluateAction(_ name: String, _ args: [ASTNode], scope: [String: Value]) -> Value {
        switch name {
        case "Action":
            let stepsArg = args.first.map { evaluate($0, scope: scope) } ?? .array([])
            let steps = (stepsArg.arrayValue ?? []).compactMap { v -> ActionStep? in
                if case .step(let s) = v { return s } else { return nil }
            }
            return .action(ActionPlan(steps: steps))
        case "Run":
            guard case .runtimeRef(let id, let type)? = args.first else { return .null }
            return .step(.run(statementId: id, refType: type))
        case "ToAssistant":
            let message = args.first.map { evaluate($0, scope: scope) }.map { $0.isNull ? "" : JS.string($0) } ?? ""
            let context = args.count > 1 ? { let v = evaluate(args[1], scope: scope); return v.isNull ? "" : JS.string(v) }() : nil
            return .step(.continueConversation(message: message, context: context))
        case "OpenUrl":
            let url = args.first.map { evaluate($0, scope: scope) }.map { $0.isNull ? "" : JS.string($0) } ?? ""
            return .step(.openURL(url))
        case "Set":
            guard args.count >= 2, case .stateRef(let target) = args[0] else { return .null }
            let valueNode = scope.isEmpty ? args[1] : substitute(args[1], scope)
            return .step(.set(target: target, value: valueNode))
        case "Reset":
            let targets = args.compactMap { a -> String? in if case .stateRef(let n) = a { return n } else { return nil } }
            return targets.isEmpty ? .null : .step(.reset(targets: targets))
        default:
            return .null
        }
    }

    // MARK: @Each

    private func evaluateEach(_ args: [ASTNode], scope: [String: Value]) -> Value {
        guard args.count >= 3, case .array(let items) = evaluate(args[0], scope: scope) else { return .array([]) }
        let varName: String
        switch args[1] {
        case .ref(let n): varName = n
        case .str(let s): varName = s
        default: return .array([])
        }
        return .array(items.map { item in
            var inner = scope
            inner[varName] = item
            let substituted = Evaluator.substituteRef(args[2], varName, item)
            let result = evaluate(substituted, scope: inner)
            if case .element(let el) = result { return .element(evaluate(el)) }
            return result
        })
    }

    private func substitute(_ node: ASTNode, _ scope: [String: Value]) -> ASTNode {
        scope.reduce(node) { Evaluator.substituteRef($0, $1.key, $1.value) }
    }

    /// Replaces a loop variable with its literal value so deferred expressions (a `@Set` evaluated on tap)
    /// keep the item they were built for.
    static func substituteRef(_ node: ASTNode, _ name: String, _ value: Value) -> ASTNode {
        func sub(_ n: ASTNode) -> ASTNode { substituteRef(n, name, value) }
        switch node {
        case .ref(let n): return n == name ? literal(value) : node
        case .member(let obj, let field):
            let subObj = sub(obj)
            if case .obj(let entries) = subObj, let hit = entries.first(where: { $0.key == field }) { return hit.value }
            return .member(subObj, field)
        case .index(let o, let i): return .index(sub(o), sub(i))
        case .binOp(let op, let l, let r): return .binOp(op, sub(l), sub(r))
        case .unaryOp(let op, let o): return .unaryOp(op, sub(o))
        case .ternary(let c, let t, let e): return .ternary(sub(c), sub(t), sub(e))
        case .arr(let els): return .arr(els.map(sub))
        case .obj(let entries): return .obj(entries.map { .init($0.key, sub($0.value)) })
        case .comp(let n, let args, let mapped): return .comp(name: n, args: args.map(sub), mapped: mapped?.mapValues(sub))
        case .assign(let t, let v): return .assign(t, sub(v))
        default: return node
        }
    }

    static func literal(_ value: Value) -> ASTNode {
        switch value {
        case .string(let s): return .str(s)
        case .number(let n): return .num(n)
        case .bool(let b): return .bool(b)
        case .array(let a): return .arr(a.map(literal))
        case .object(let o): return .obj(o.keys.sorted().map { .init($0, literal(o[$0]!)) })
        default: return .null
        }
    }
}

/// Reactive state for one generated UI (upstream `createStore`). A value type so a SwiftUI model can publish it.
/// Keys are `$variables` and form field paths.
public struct StateStore: Equatable, Sendable {
    public private(set) var values: [String: Value] = [:]
    private var defaults: [String: Value] = [:]

    public init(values: [String: Value] = [:]) { self.values = values }

    public func get(_ name: String) -> Value { values[name] ?? .null }

    /// Returns false when nothing changed.
    @discardableResult
    public mutating func set(_ name: String, _ value: Value) -> Bool {
        guard values[name] != value else { return false }
        values[name] = value
        return true
    }

    /// Applies persisted values, then defaults for keys not set yet. Never deletes: while streaming, a
    /// declaration can briefly disappear and the user's input must survive it.
    public mutating func initialize(defaults newDefaults: [String: Value], persisted: [String: Value] = [:]) {
        for (k, v) in persisted { values[k] = v }
        for (k, v) in newDefaults {
            defaults[k] = v
            if values[k] == nil { values[k] = v }
        }
    }

    public mutating func reset(_ names: [String]) {
        for n in names { values[n] = defaults[n] ?? .null }
    }

    /// Runs the local steps of a plan (`@Set`, `@Reset`) and returns the ones the host must handle.
    public mutating func apply(_ plan: ActionPlan, evaluator: (StateStore) -> Evaluator) -> [ActionStep] {
        var external: [ActionStep] = []
        for step in plan.steps {
            switch step {
            case .set(let target, let node):
                let value = evaluator(self).evaluate(node)
                set(target, value)
            case .reset(let targets):
                reset(targets)
            default:
                external.append(step)
            }
        }
        return external
    }
}

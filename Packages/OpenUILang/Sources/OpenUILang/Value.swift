import Foundation

/// A materialized or evaluated value. Upstream passes plain JavaScript values around (`unknown`); this is the
/// same set made explicit, plus the runtime-only shapes the evaluator produces.
public indirect enum Value: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Value])
    case object([String: Value])
    case element(Element)
    /// A runtime expression the materializer kept for the evaluator (`$var`, `@Count(...)`, a ternary...).
    case expr(ASTNode)
    case action(ActionPlan)
    case step(ActionStep)
    /// Upstream's `ReactiveAssign`: a prop bound two-way to the `$variable` named here.
    case binding(String)

    public var isNull: Bool { if case .null = self { return true } else { return false } }

    public var stringValue: String? { if case .string(let s) = self { return s } else { return nil } }
    public var numberValue: Double? { if case .number(let n) = self { return n } else { return nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { return b } else { return nil } }
    public var arrayValue: [Value]? { if case .array(let a) = self { return a } else { return nil } }
    public var objectValue: [String: Value]? { if case .object(let o) = self { return o } else { return nil } }
    public var elementValue: Element? { if case .element(let e) = self { return e } else { return nil } }

    public subscript(key: String) -> Value {
        if case .object(let o) = self { return o[key] ?? .null }
        return .null
    }
}

/// A component invocation with its positional arguments mapped to named props (upstream `ElementNode`).
public struct Element: Equatable, Sendable {
    public var typeName: String
    public var props: [String: Value]
    /// The statement that defined it (`header` in `header = CardHeader(...)`); nil for inline components.
    public var statementId: String?
    /// True while the parser has not seen all of its tokens yet.
    public var partial: Bool
    /// False when every prop is a static literal, so evaluation can be skipped.
    public var hasDynamicProps: Bool

    public init(typeName: String, props: [String: Value], statementId: String? = nil, partial: Bool = false,
                hasDynamicProps: Bool = true) {
        self.typeName = typeName
        self.props = props
        self.statementId = statementId
        self.partial = partial
        self.hasDynamicProps = hasDynamicProps
    }

    public subscript(prop: String) -> Value { props[prop] ?? .null }
}

/// One step of an `Action([...])` plan (upstream `ActionStep`).
public enum ActionStep: Equatable, Sendable {
    case run(statementId: String, refType: RuntimeRefType)
    /// `@ToAssistant("message", "context")`: send a message to the assistant.
    case continueConversation(message: String, context: String?)
    case openURL(String)
    /// `@Set($var, value)`. The value is evaluated when the step runs, not when the plan is built.
    case set(target: String, value: ASTNode)
    case reset(targets: [String])
}

public struct ActionPlan: Equatable, Sendable {
    public var steps: [ActionStep]
    public init(steps: [ActionStep]) { self.steps = steps }
}

// MARK: - JavaScript semantics

/// The evaluator follows the JavaScript rules upstream relies on: truthiness, `toNumber`, loose `==`, and
/// `String(x)` for concatenation.
public enum JS {
    public static func truthy(_ v: Value) -> Bool {
        switch v {
        case .null: return false
        case .bool(let b): return b
        case .number(let n): return n != 0 && !n.isNaN
        case .string(let s): return !s.isEmpty
        default: return true
        }
    }

    /// Upstream `toNumber`: numbers as-is, numeric strings parsed (else 0), booleans 1/0, everything else 0.
    public static func toNumber(_ v: Value) -> Double {
        switch v {
        case .number(let n): return n
        case .string(let s): return number(fromString: s) ?? 0
        case .bool(let b): return b ? 1 : 0
        default: return 0
        }
    }

    /// `Number(s)` for the cases that matter: trimmed decimal or exponent literals, "" is 0, anything else nil.
    public static func number(fromString s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return 0 }
        guard let d = Double(t), !t.lowercased().contains("nan"), !t.lowercased().contains("inf") else { return nil }
        return d
    }

    public static func string(_ v: Value) -> String {
        switch v {
        case .null: return "null"
        case .bool(let b): return b ? "true" : "false"
        case .number(let n): return format(n)
        case .string(let s): return s
        case .array(let a): return a.map { $0.isNull ? "" : string($0) }.joined(separator: ",")
        case .object: return "[object Object]"
        case .element(let e): return "[\(e.typeName)]"
        default: return ""
        }
    }

    /// `String(n)`: integers without a fraction, other values in their shortest round-trip form.
    public static func format(_ n: Double) -> String {
        if n.isNaN { return "NaN" }
        if n.isInfinite { return n > 0 ? "Infinity" : "-Infinity" }
        if n == n.rounded(), abs(n) < 1e21 {
            return n == 0 ? "0" : String(format: "%.0f", n)
        }
        return "\(n)"
    }

    /// Loose `==`: null only equals null; a number against a string or boolean compares numerically.
    public static func looseEquals(_ a: Value, _ b: Value) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.null, _), (_, .null): return false
        case (.number(let x), .number(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.bool(let x), .bool(let y)): return x == y
        case (.number(let x), .string(let s)), (.string(let s), .number(let x)):
            guard let y = number(fromString: s) else { return false }
            return x == y
        case (.bool(let x), _): return looseEquals(.number(x ? 1 : 0), b)
        case (_, .bool(let y)): return looseEquals(a, .number(y ? 1 : 0))
        default: return a == b
        }
    }
}

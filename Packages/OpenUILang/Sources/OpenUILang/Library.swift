import Foundation

/// A prop's type. Upstream derives this from each component's Zod schema (via JSON Schema); a Swift library
/// states it directly. It drives both validation and the signatures in the generated prompt.
public indirect enum PropType: Equatable, Sendable {
    case string, number, boolean, any
    /// One of these string literals.
    case literal([String])
    case array(PropType)
    case object([Field])
    /// One of these catalog components.
    case component([String])
    /// An `Action([...])` expression.
    case action
    /// A prop that accepts a `$variable` for two-way binding, else a value of the wrapped type.
    case binding(PropType)
    case union([PropType])
    case record(PropType)

    public struct Field: Equatable, Sendable {
        public var name: String
        public var type: PropType
        public var required: Bool
        public init(_ name: String, _ type: PropType, required: Bool = false) {
            self.name = name; self.type = type; self.required = required
        }
    }

    /// How the prompt writes the type, matching upstream's signature strings.
    public var signature: String {
        switch self {
        case .string: return "string"
        case .number: return "number"
        case .boolean: return "boolean"
        case .any: return "any"
        case .literal(let values): return values.map { "\"\($0)\"" }.joined(separator: " | ")
        case .array(let item):
            let inner = item.signature
            return item.needsParens ? "(\(inner))[]" : "\(inner)[]"
        case .object(let fields):
            return "{" + fields.map { "\($0.name)\($0.required ? "" : "?"): \($0.type.signature)" }.joined(separator: ", ") + "}"
        case .component(let names): return names.joined(separator: " | ")
        case .action: return "ActionExpression"
        case .binding(let inner): return "$binding<\(inner.signature)>"
        case .union(let types): return types.map(\.signature).joined(separator: " | ")
        case .record(let value): return "Record<string, \(value.signature)>"
        }
    }

    private var needsParens: Bool {
        switch self {
        case .literal(let v): return v.count > 1
        case .component(let n): return n.count > 1
        case .union(let t): return t.count > 1
        default: return false
        }
    }

    var isBinding: Bool { if case .binding = self { return true } else { return false } }
}

public struct ParamDef: Equatable, Sendable {
    public var name: String
    public var type: PropType?
    public var required: Bool
    /// Used when a required value is missing or null, and when an invalid value is dropped.
    public var defaultValue: Value?

    public init(_ name: String, _ type: PropType? = nil, required: Bool = false, defaultValue: Value? = nil) {
        self.name = name; self.type = type; self.required = required; self.defaultValue = defaultValue
    }
}

public struct ComponentDef: Equatable, Sendable {
    public var name: String
    public var params: [ParamDef]
    public var description: String?

    public init(_ name: String, _ params: [ParamDef], description: String? = nil) {
        self.name = name; self.params = params; self.description = description
    }

    /// `Card(children: (A | B)[], title?: string)`, the form the prompt lists.
    public var signature: String {
        "\(name)(" + params.map { "\($0.name)\($0.required ? "" : "?")\($0.type.map { ": " + $0.signature } ?? "")" }
            .joined(separator: ", ") + ")"
    }

    /// The compact signature errors quote: `Header(title*: string, variant: "a"|"b")`.
    var errorSignature: String {
        "\(name)(" + params.map { p in
            let marked = p.required ? "\(p.name)*" : p.name
            return p.type.map { "\(marked): \($0.errorSignature)" } ?? marked
        }.joined(separator: ", ") + ")"
    }
}

private extension PropType {
    var errorSignature: String {
        switch self {
        case .literal(let v): return v.map { "\"\($0)\"" }.joined(separator: "|")
        case .component(let n): return n.joined(separator: "|")
        default: return signature
        }
    }
}

public struct ComponentGroup: Equatable, Sendable {
    public var name: String
    public var components: [String]
    public var notes: [String]
    public init(_ name: String, _ components: [String], notes: [String] = []) {
        self.name = name; self.components = components; self.notes = notes
    }
}

/// A component library: what the model may generate, in what order the prompt lists it, and the root component.
public struct Library: Sendable {
    public let components: [ComponentDef]
    public let root: String
    public let groups: [ComponentGroup]
    let byName: [String: ComponentDef]

    public init(components: [ComponentDef], root: String, groups: [ComponentGroup] = []) {
        self.components = components
        self.root = root
        self.groups = groups
        var map: [String: ComponentDef] = [:]
        for c in components where map[c.name] == nil { map[c.name] = c }
        byName = map
    }

    public func component(_ name: String) -> ComponentDef? { byName[name] }
    public var componentNames: [String] { components.map(\.name) }

    /// The type a component declares for one prop, if any.
    func propType(_ component: String, _ prop: String) -> PropType? {
        byName[component]?.params.first { $0.name == prop }?.type
    }
}

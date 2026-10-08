import Foundation

/// The shared built-in registry (upstream `builtins.ts`): data functions, the lazy `@Each`, action steps and the
/// reserved `Query`/`Mutation` calls. The prompt generator documents exactly these.
public enum Builtins {
    struct Def {
        let name: String
        let signature: String
        let description: String
        let fn: ([Value]) -> Value
    }

    private static func arg(_ args: [Value], _ i: Int) -> Value { i < args.count ? args[i] : .null }

    /// Field lookup with dot paths: "state.name" reads obj.state.name.
    static func field(_ value: Value, _ path: String) -> Value {
        guard !path.isEmpty else { return .null }
        var cur = value
        for part in path.split(separator: ".") {
            guard case .object(let o) = cur else { return .null }
            cur = o[String(part)] ?? .null
        }
        return cur
    }

    static let ordered: [Def] = [
        Def(name: "Count", signature: "Count(array) → number", description: "Returns array length") { args in
            .number(Double(arg(args, 0).arrayValue?.count ?? 0))
        },
        Def(name: "First", signature: "First(array) → element", description: "Returns first element of array") { args in
            arg(args, 0).arrayValue?.first ?? .null
        },
        Def(name: "Last", signature: "Last(array) → element", description: "Returns last element of array") { args in
            arg(args, 0).arrayValue?.last ?? .null
        },
        Def(name: "Sum", signature: "Sum(numbers[]) → number", description: "Sum of numeric array") { args in
            .number(arg(args, 0).arrayValue?.reduce(0) { $0 + JS.toNumber($1) } ?? 0)
        },
        Def(name: "Avg", signature: "Avg(numbers[]) → number", description: "Average of numeric array") { args in
            guard let a = arg(args, 0).arrayValue, !a.isEmpty else { return .number(0) }
            return .number(a.reduce(0) { $0 + JS.toNumber($1) } / Double(a.count))
        },
        Def(name: "Min", signature: "Min(numbers[]) → number", description: "Minimum value in array") { args in
            guard let a = arg(args, 0).arrayValue, let first = a.first else { return .number(0) }
            return .number(a.reduce(JS.toNumber(first)) { min($0, JS.toNumber($1)) })
        },
        Def(name: "Max", signature: "Max(numbers[]) → number", description: "Maximum value in array") { args in
            guard let a = arg(args, 0).arrayValue, let first = a.first else { return .number(0) }
            return .number(a.reduce(JS.toNumber(first)) { max($0, JS.toNumber($1)) })
        },
        Def(name: "Sort", signature: "Sort(array, field, direction?) → sorted array",
            description: "Sort array by field. Direction: \"asc\" (default) or \"desc\"") { args in
            guard let a = arg(args, 0).arrayValue else { return arg(args, 0) }
            let f = arg(args, 1).isNull ? "" : JS.string(arg(args, 1))
            let desc = (arg(args, 2).isNull ? "asc" : JS.string(arg(args, 2))) == "desc"
            func numeric(_ v: Value) -> Bool {
                if case .number = v { return true }
                if case .string(let s) = v { return !s.isEmpty && JS.number(fromString: s) != nil }
                return false
            }
            let sorted = a.enumerated().sorted { lhs, rhs in
                let av = f.isEmpty ? lhs.element : field(lhs.element, f)
                let bv = f.isEmpty ? rhs.element : field(rhs.element, f)
                let order: Double
                if numeric(av), numeric(bv) {
                    order = JS.toNumber(av) - JS.toNumber(bv)
                } else {
                    let x = av.isNull ? "" : JS.string(av), y = bv.isNull ? "" : JS.string(bv)
                    order = x == y ? 0 : (x.localizedCompare(y) == .orderedAscending ? -1 : 1)
                }
                let directed = desc ? -order : order
                return directed == 0 ? lhs.offset < rhs.offset : directed < 0
            }
            return .array(sorted.map(\.element))
        },
        Def(name: "Filter",
            signature: "Filter(array, field, operator: \"==\" | \"!=\" | \">\" | \"<\" | \">=\" | \"<=\" | \"contains\", value) → filtered array",
            description: "Filter array by field value") { args in
            guard let a = arg(args, 0).arrayValue else { return .array([]) }
            let f = arg(args, 1).isNull ? "" : JS.string(arg(args, 1))
            let op = arg(args, 2).isNull ? "==" : JS.string(arg(args, 2))
            let target = arg(args, 3)
            return .array(a.filter { item in
                let v = f.isEmpty ? item : field(item, f)
                switch op {
                case "==": return JS.looseEquals(v, target)
                case "!=": return !JS.looseEquals(v, target)
                case ">": return JS.toNumber(v) > JS.toNumber(target)
                case "<": return JS.toNumber(v) < JS.toNumber(target)
                case ">=": return JS.toNumber(v) >= JS.toNumber(target)
                case "<=": return JS.toNumber(v) <= JS.toNumber(target)
                case "contains": return (v.isNull ? "" : JS.string(v)).contains(target.isNull ? "" : JS.string(target))
                default: return false
                }
            })
        },
        Def(name: "Round", signature: "Round(number, decimals?) → number", description: "Round to N decimal places (default 0)") { args in
            let num = JS.toNumber(arg(args, 0))
            let d = arg(args, 1).isNull ? 0 : JS.toNumber(arg(args, 1))
            let factor = pow(10, d)
            return .number((num * factor + 0.5).rounded(.down) / factor)
        },
        Def(name: "Abs", signature: "Abs(number) → number", description: "Absolute value") { args in
            .number(abs(JS.toNumber(arg(args, 0))))
        },
        Def(name: "Floor", signature: "Floor(number) → number", description: "Round down to nearest integer") { args in
            .number(JS.toNumber(arg(args, 0)).rounded(.down))
        },
        Def(name: "Ceil", signature: "Ceil(number) → number", description: "Round up to nearest integer") { args in
            .number(JS.toNumber(arg(args, 0)).rounded(.up))
        },
    ]

    static let byName: [String: Def] = Dictionary(uniqueKeysWithValues: ordered.map { ($0.name, $0) })

    /// Built-ins that receive AST nodes and control their own evaluation.
    static let lazy: Set<String> = ["Each"]
    static let lazyDocs: [(signature: String, description: String)] = [
        ("Each(array, varName, template)",
         "Evaluate template for each element. varName is the loop variable — use it ONLY inside the template expression (inline). Do NOT create a separate statement for the template."),
    ]

    /// Parser-level action step names.
    static let actionSteps: Set<String> = ["Run", "ToAssistant", "OpenUrl", "Set", "Reset"]
    static let actionNames: Set<String> = actionSteps.union(["Action"])

    static let names: Set<String> = Set(byName.keys).union(lazy).union(actionNames)

    public static func isBuiltin(_ name: String) -> Bool { names.contains(name) }

    static let reservedCalls: Set<String> = ["Query", "Mutation"]
    static func isReservedCall(_ name: String) -> Bool { reservedCalls.contains(name) }
}

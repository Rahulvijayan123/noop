import Foundation

/// Typed visual the coach attaches beneath an answer. Produced by the coach function's
/// route → design → validate pipeline (`POST coach/visual`) in the canonical
/// shape decoded here, so the app never interprets free-form model output.
struct CoachViz: Codable, Equatable, Identifiable {
    struct Point: Codable, Equatable, Identifiable {
        var x: String?
        var y: Double
        var series: String?
        var size: Double?
        var label: String?
        var low: Double?
        var high: Double?
        var target: Double?
        /// Heatmap row category.
        var row: String?
        /// Numeric x for scatter and bubble charts.
        var xValue: Double?
        var total: Bool?
        var midpoint: Bool?

        var id: String {
            "\(x ?? "")|\(row ?? "")|\(series ?? "")|\(xValue.map { String($0) } ?? "")|\(y)"
        }
    }

    struct TimelineTask: Codable, Equatable, Identifiable {
        var id: String
        var name: String
        var start: String
        var end: String?
        var group: String?
    }

    struct Fact: Codable, Equatable, Identifiable {
        var label: String
        var value: String
        var detail: String?
        var tone: String?
        var id: String { "\(label)|\(value)" }
    }

    struct Option: Codable, Equatable, Identifiable {
        struct OptionFact: Codable, Equatable, Identifiable {
            var label: String
            var value: String
            var id: String { "\(label)|\(value)" }
        }
        var name: String
        var badge: String?
        var facts: [OptionFact]
        var id: String { name }
    }

    struct Item: Codable, Equatable, Identifiable {
        var title: String
        var detail: String?
        var tag: String?
        var id: String { "\(title)|\(detail ?? "")" }
    }

    struct Alert: Codable, Equatable, Identifiable {
        var tone: String?
        var title: String
        var detail: String?
        var id: String { "\(title)|\(detail ?? "")" }
    }

    enum Layout {
        case chart
        case progress
        case timeline
        case facts
        case table
        case comparison
        case list
        case alerts
        case unsupported
    }

    let type: String
    let title: String
    var subtitle: String?
    var source: String?
    var yLabel: String?
    var xLabel: String?
    var horizontal: Bool?
    var reference: Double?
    var points: [Point]?
    var tasks: [TimelineTask]?
    var facts: [Fact]?
    var columns: [String]?
    var rows: [[String]]?
    var options: [Option]?
    var items: [Item]?
    var alerts: [Alert]?

    var id: String { "\(type)|\(title)" }

    static let chartTypes: Set<String> = [
        "bar", "stacked_bar", "line", "area", "pie", "scatter", "bubble", "heatmap", "waterfall", "range"
    ]

    var layout: Layout {
        switch type {
        case _ where Self.chartTypes.contains(type):
            return (points?.count ?? 0) >= 2 ? .chart : .unsupported
        case "progress": return (points?.isEmpty ?? true) ? .unsupported : .progress
        case "gantt", "milestones": return (tasks?.isEmpty ?? true) ? .unsupported : .timeline
        case "facts": return (facts?.count ?? 0) >= 2 ? .facts : .unsupported
        case "table": return (columns?.count ?? 0) >= 2 && !(rows?.isEmpty ?? true) ? .table : .unsupported
        case "comparison": return (options?.count ?? 0) >= 2 ? .comparison : .unsupported
        case "list": return (items?.count ?? 0) >= 2 ? .list : .unsupported
        case "alerts": return alerts?.isEmpty == false ? .alerts : .unsupported
        default: return .unsupported
        }
    }

    /// True when the app can draw this visual. Anything else is dropped rather than shown half-built.
    var isRenderable: Bool { layout != .unsupported }
}

enum CoachVizPhase: Equatable {
    case none
    case generating
    case ready
}

/// What the router decided for an answer: the visual kind and the chart types to try, most wanted first.
struct CoachVisualRoute: Codable, Equatable {
    let kind: String
    let types: [String]
    var routedBy: String? = nil
}

struct CoachVisualResponse: Decodable {
    let visual: CoachViz?
    let outcome: String?
    let route: CoachVisualRoute?
}

/// Everything the visual pipeline needs about one finished turn.
struct CoachVisualRequest: Encodable {
    var question: String
    var answer: String
    var evidence: String
    var routeOnly: Bool = false
    var route: CoachVisualRoute? = nil

    enum CodingKeys: String, CodingKey {
        case question, answer, evidence, route
        case routeOnly = "route_only"
    }
}

enum CoachVisualEvidence {
    static let perToolCap = 3_500
    static let totalCap = 14_000

    /// Tools whose output is real user data the visual may be drawn from.
    static let dataTools: Set<String> = [
        "get_health_overview", "get_daily_metrics", "get_workouts", "get_readiness_analysis", "prepare_chart"
    ]

    /// Removes hand-drawn text charts (box/block characters) the model sometimes emits;
    /// the visual pipeline draws the real chart beneath the answer.
    static func stripTextCharts(_ input: String) -> String {
        func isDrawing(_ scalar: Unicode.Scalar) -> Bool { (0x2500...0x259F).contains(scalar.value) }
        func isBlock(_ scalar: Unicode.Scalar) -> Bool { (0x2580...0x259F).contains(scalar.value) }

        var text = input
        let fence = try? NSRegularExpression(pattern: "```[^\\n]*\\n[\\s\\S]*?(?:```|$)")
        if let fence {
            let ns = text as NSString
            let matches = fence.matches(in: text, range: NSRange(location: 0, length: ns.length)).reversed()
            for match in matches {
                let block = ns.substring(with: match.range)
                if block.unicodeScalars.contains(where: isDrawing) {
                    text = (text as NSString).replacingCharacters(in: match.range, with: "")
                }
            }
        }
        let kept = text.components(separatedBy: "\n").filter { line in
            var run = 0
            for scalar in line.unicodeScalars {
                run = isBlock(scalar) ? run + 1 : 0
                if run >= 2 { return false }
            }
            return true
        }
        return kept.joined(separator: "\n")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Plain-text rendering of a series so the model can quote the numbers and the designer can verify them.
    static func describe(_ chart: CoachChart, maxPoints: Int = 60) -> String {
        let shown = chart.points.suffix(maxPoints)
        let body = shown.map { point -> String in
            let key = point.dateISO
            let value = point.value.rounded() == point.value
                ? String(format: "%.0f", point.value)
                : String(format: "%.1f", point.value)
            return "\(key): \(value)"
        }.joined(separator: "; ")
        return "SERIES \(chart.title) (\(chart.unit.isEmpty ? "unitless" : chart.unit)): \(body)"
    }

    /// Tool output the visual may draw from, capped per tool and in total so a long history cannot crowd out the answer.
    static func compose(_ toolResults: [String]) -> String {
        var remaining = totalCap
        var parts: [String] = []
        for raw in toolResults {
            guard remaining > 0 else { break }
            let cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { continue }
            let piece = String(cleaned.prefix(min(perToolCap, remaining)))
            parts.append(piece)
            remaining -= piece.count
        }
        return parts.joined(separator: "\n\n")
    }
}

/// Turns raw model reasoning into a few short, user-relevant findings.
/// The raw chain of thought is mostly planning talk ("Let me call the tool…"); only sentences that
/// state something about the user's data or a conclusion drawn from it are kept, rewritten to "you/your".
enum CoachTraceSnippets {
    private static let selfTalk = try! NSRegularExpression(
        pattern: #"^(?:okay|ok|so|hmm+|wait|actually|alright|now|first|second|third|then|next|also|maybe|perhaps|let me|let's|let us|i(?:'ll| will| need| should| must| can| could| want| think| am going| have to| notice)|we(?:'ll| will| need| should| must| can| have to)|need to|should i|the (?:user(?!'s)|question|request|system|prompt|instructions?)\b|user (?:is|wants|asks|said|has|needs|might)|they (?:are asking|want|ask|need)|this is (?:a|an) (?:question|request)|to answer|for the answer|my (?:answer|response|plan))\b"#,
        options: .caseInsensitive
    )
    private static let leakedInternals = try! NSRegularExpression(
        pattern: #"[{}\[\]_<>|]|tool|function|json|api\b|prompt|instruction|system message|token|schema|endpoint"#,
        options: .caseInsensitive
    )
    private static let relevance = try! NSRegularExpression(
        pattern: #"\d|\b(?:hrv|sleep|recovery|resting|heart rate|strain|stress|volume|load|weight|reps?|sets?|rpe|rir|e1rm|pr|plateau|fatigue|trend|trending|progress|protein|calories|carbs|nutrition|bench|squat|deadlift|press|row|pull-?ups?|workout|session|week|weeks|average|averag\w+|higher|lower|increase\w*|decrease\w*|drop\w*|rose|fell|improv\w+|declin\w+|consistent|steady|suggests?|indicates?|means)\b"#,
        options: .caseInsensitive
    )

    /// Findings in the order the model reached them. While `isComplete` is false the trailing,
    /// still-arriving sentence is withheld, so the list only ever grows and earlier entries never change.
    static func extract(from raw: String, isComplete: Bool, limit: Int = 4) -> [String] {
        var text = raw
            .replacingOccurrences(of: "<think>", with: " ")
            .replacingOccurrences(of: "</think>", with: " ")
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "'")
        text = String(text.prefix(14_000))
        if !isComplete {
            text = completeSentences(in: text)
        }

        var seen: [String] = []
        var snippets: [String] = []
        for sentence in sentences(in: text) {
            guard let snippet = clean(sentence) else { continue }
            let key = snippet.lowercased()
            if seen.contains(where: { $0.hasPrefix(key.prefix(40)) || key.hasPrefix($0.prefix(40)) }) { continue }
            seen.append(key)
            snippets.append(snippet)
            if snippets.count == limit { break }
        }
        return snippets
    }

    /// Drops everything after the last sentence boundary (`. ` / `! ` / `? ` or a newline).
    private static func completeSentences(in text: String) -> String {
        guard let boundary = try? NSRegularExpression(pattern: #"[.!?](?=\s)|\n"#) else { return "" }
        let range = NSRange(text.startIndex..., in: text)
        guard let last = boundary.matches(in: text, range: range).last,
              let end = Range(last.range, in: text)?.upperBound else { return "" }
        return String(text[..<end])
    }

    private static func sentences(in text: String) -> [String] {
        var out: [String] = []
        for line in text.components(separatedBy: .newlines) {
            var line = line.trimmingCharacters(in: .whitespaces)
            line = line.replacingOccurrences(of: #"^(?:[-•*]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            guard !line.isEmpty else { continue }
            let parts = line.replacingOccurrences(
                of: #"(?<=[.!?])\s+(?=[A-Z0-9"“])"#,
                with: "\u{1F}",
                options: .regularExpression
            ).components(separatedBy: "\u{1F}")
            out.append(contentsOf: parts)
        }
        return out
    }

    private static func matches(_ regex: NSRegularExpression, _ text: String) -> Bool {
        regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func clean(_ sentence: String) -> String? {
        var s = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.count >= 24, !s.hasSuffix("?"), !matches(selfTalk, s) else { return nil }
        s = s.replacingOccurrences(of: #"(?i)\bthe user's\b"#, with: "your", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)\bthe user\b"#, with: "you", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)^(?:but|and|so|because|since|however|therefore|thus)[, ]+"#, with: "", options: .regularExpression)
        guard !matches(leakedInternals, s), matches(relevance, s) else { return nil }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-"))
        guard let first = s.first else { return nil }
        s = first.uppercased() + s.dropFirst()
        if s.count > 140 {
            let cut = s.prefix(140)
            let trimmed = cut.lastIndex(of: " ").map { String(cut[..<$0]) } ?? String(cut)
            s = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-")) + "…"
        } else if let last = s.last, !".!…".contains(last) {
            s += "."
        }
        return s
    }
}

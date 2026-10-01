import Foundation
import WhoopStore

/// Display labels for the "Looked at" badge under an answer.
enum CoachToolDisplayNames {
    static func label(for tool: String) -> String {
        switch tool {
        case "get_health_overview": return "Health overview"
        case "get_daily_metrics": return "Daily metrics"
        case "get_workouts": return "Recent workouts"
        case "get_readiness_analysis": return "Readiness"
        case "prepare_chart": return "Metric series"
        case "save_memory": return "Saved note"
        case "get_memories": return "Past context"
        default: return tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// The tools the model may call. Every read comes from the same rows the rest of the app shows, so the
/// coach can never quote a number the user cannot find on screen.
@MainActor
struct CoachToolExecutor {
    let repo: Repository
    let engine: AICoachEngine
    let api: CoachAPI

    // MARK: Schemas

    static let definitions: [[String: Any]] = [
        tool("get_health_overview",
             "Last 14 days of charge, effort, sleep, HRV and resting HR, 30-day averages, recent workouts. For broad 'how am I doing?' questions."),
        tool("get_daily_metrics",
             "Day-by-day charge, effort, sleep, HRV, resting HR over a longer window. For weekly and trend questions.",
             ["days": ("integer", "Days back (default 14, max 60)")]),
        tool("get_workouts",
             "Recent workouts: sport, duration, effort, avg HR, calories, distance.",
             ["limit": ("integer", "Max workouts (default 6, max 20)")]),
        tool("get_readiness_analysis",
             "Today's charge vs the 30-day baseline, HRV and resting-HR drift, acute vs chronic effort load, sleep debt. For 'should I train hard?' or 'am I overreaching?'."),
        tool("prepare_chart",
             "Fetch one metric as a day-by-day series to quote or plot. The app draws any chart itself after your answer.",
             ["metric": ("string", "charge|effort|sleepHours|hrv|rhr|spo2|respiration|skinTemp|steps|activeCalories"),
              "days": ("integer", "Days (default 30, max 120)")],
             required: ["metric"]),
        tool("save_memory",
             "Save a durable fact about the user (goal, injury, preference, routine), third person, e.g. 'User is training for a half marathon in March'. Not transient data.",
             ["content": ("string", "The fact, under 400 characters"),
              "topic": ("string", "goal|injury|preference|achievement|routine|general"),
              "importance": ("integer", "1-5 (5 = critical such as an injury)")],
             required: ["content"]),
        tool("get_memories", "Recall facts saved in earlier sessions."),
    ]

    /// Tools every turn keeps: memory and the series fetch the visual pipeline draws from.
    private static let coreTools: Set<String> = ["get_memories", "save_memory", "prepare_chart"]

    /// Per-intent bundle: the core plus the data tools the question can plausibly need. Deterministic keyword
    /// routing; an unrecognised question falls back to the full set so a tool is never withheld by a guess.
    static func definitions(for userText: String) -> [[String: Any]] {
        let t = userText.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        let extra: Set<String>
        if has(["workout", "session", "lift", "run ", "ran ", "ride", "swim", "exercise"]) {
            extra = ["get_workouts", "get_health_overview"]
        } else if has(["chart", "graph", "plot", "visuali"]) {
            extra = []
        } else if has(["remember", "preference", "about me"]) {
            extra = []
        } else if has(["should i train", "ready", "readiness", "overreach", "overtrain", "push", "rest day", "fatigue"]) {
            extra = ["get_readiness_analysis", "get_daily_metrics"]
        } else if has(["sleep", "hrv", "recovery", "charge", "resting", "heart rate", "trend", "average", "week"]) {
            extra = ["get_daily_metrics", "get_readiness_analysis"]
        } else {
            return definitions
        }
        let names = coreTools.union(extra)
        return definitions.filter { (($0["function"] as? [String: Any])?["name"] as? String).map(names.contains) ?? false }
    }

    private static func tool(_ name: String, _ description: String,
                             _ properties: [String: (String, String)] = [:],
                             required: [String] = []) -> [String: Any] {
        let props = properties.mapValues { ["type": $0.0, "description": $0.1] }
        return ["type": "function",
                "function": ["name": name, "description": description,
                             "parameters": ["type": "object", "properties": props, "required": required] as [String: Any]] as [String: Any]]
    }

    // MARK: Dispatch

    func execute(name: String, arguments: String) async -> String {
        let args = (try? JSONSerialization.jsonObject(with: Data(arguments.utf8)) as? [String: Any]) ?? [:]
        switch name {
        case "get_health_overview": return await healthOverview()
        case "get_daily_metrics": return dailyMetrics(days: Self.int(args["days"], default: 14, max: 60))
        case "get_workouts": return await engine.recentWorkoutsBlock(limit: Self.int(args["limit"], default: 6, max: 20))
        case "get_readiness_analysis": return await readiness()
        case "prepare_chart": return chart(args)
        case "save_memory": return await saveMemory(args)
        case "get_memories": return await memories()
        default: return "Unknown tool: \(name)"
        }
    }

    private static func int(_ raw: Any?, default fallback: Int, max cap: Int) -> Int {
        let n = (raw as? Int) ?? (raw as? Double).map { Int($0) } ?? (raw as? String).flatMap(Int.init) ?? fallback
        return min(max(n, 1), cap)
    }

    // MARK: Health data

    private func healthOverview() async -> String {
        var text = engine.buildContext() + "\n\n" + (await engine.recentWorkoutsBlock())
        if let stress = await engine.stressIndexLine() { text += "\n\n" + stress }
        return text
    }

    private func dailyMetrics(days: Int) -> String {
        let window = Array(repo.days.suffix(days).reversed())
        guard !window.isEmpty else { return "No wearable data is available yet." }
        let header = "Last \(window.count) days, newest first (charge 0-100, effort 0-100, rest in hours, stages in hours, efficiency %, HRV ms, RHR bpm; a dash means NOT MEASURED):"
        return ([header] + window.map { "  " + engine.dayLine($0) }).joined(separator: "\n")
    }

    private func readiness() async -> String {
        let all = repo.days
        guard let latest = all.last(where: { $0.recovery != nil }) ?? all.last else { return "No wearable data is available yet." }
        let last30 = Array(all.suffix(30)), last7 = Array(all.suffix(7)), last28 = Array(all.suffix(28))

        func mean(_ days: [DailyMetric], _ pick: (DailyMetric) -> Double?) -> Double? {
            let xs = days.compactMap(pick)
            return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
        func fmt(_ v: Double?, _ digits: Int = 0) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }
        func delta(_ now: Double?, _ base: Double?, _ digits: Int = 0) -> String {
            guard let now, let base else { return "—" }
            return String(format: "%+.\(digits)f", now - base)
        }

        var lines = ["READINESS (as of \(latest.day)):"]
        if let charge = latest.recovery {
            let zone = charge >= 67 ? "green (build/push)" : charge >= 34 ? "yellow (maintain)" : "red (recover)"
            lines.append("• Charge \(Int(charge.rounded())) — \(zone); 30-day average \(fmt(mean(last30) { $0.recovery })), 7-day \(fmt(mean(last7) { $0.recovery }))")
        } else {
            lines.append("• Charge not measured for \(latest.day).")
        }
        let hrvBase = mean(last30) { $0.avgHrv }
        lines.append("• HRV \(fmt(latest.avgHrv)) ms vs 30-day \(fmt(hrvBase)) ms (\(delta(latest.avgHrv, hrvBase)) ms); 7-day \(fmt(mean(last7) { $0.avgHrv })) ms")
        let rhrBase = mean(last30) { $0.restingHr.map(Double.init) }
        lines.append("• Resting HR \(latest.restingHr.map(String.init) ?? "—") bpm vs 30-day \(fmt(rhrBase)) bpm (\(delta(latest.restingHr.map(Double.init), rhrBase)) bpm); 7-day \(fmt(mean(last7) { $0.restingHr.map(Double.init) })) bpm")

        let acute = mean(last7) { $0.strain }, chronic = mean(last28) { $0.strain }
        if let acute, let chronic, chronic > 0 {
            let ratio = acute / chronic
            let band = ratio > 1.3 ? "well above your norm — overreaching risk" : ratio > 1.1 ? "slightly above your norm" : ratio < 0.8 ? "below your norm — room to build" : "in your normal range"
            lines.append("• Effort load: 7-day average \(fmt(acute, 1)) vs 28-day \(fmt(chronic, 1)) (ratio \(String(format: "%.2f", ratio)), \(band))")
        } else {
            lines.append("• Effort load: not enough effort data to compare.")
        }

        let nights = last7.compactMap { $0.totalSleepMin.map { $0 / 60 } }
        if nights.isEmpty {
            lines.append("• Sleep: no sleep recorded in the last 7 days.")
        } else {
            let debt = nights.reduce(0) { $0 + max(0, 8 - $1) }
            lines.append("• Sleep: 7-night average \(fmt(nights.reduce(0, +) / Double(nights.count), 1)) h over \(nights.count) nights with data; shortfall against an 8 h reference \(fmt(debt, 1)) h")
        }
        if let stress = await engine.stressIndexLine() { lines.append("• " + stress) }
        return lines.joined(separator: "\n")
    }

    private func chart(_ args: [String: Any]) -> String {
        guard let raw = args["metric"] as? String, let metric = CoachChartMetric(rawValue: raw) else {
            return "Unknown metric. Use one of: " + CoachChartMetric.allCases.map(\.rawValue).joined(separator: ", ")
        }
        let chart = metric.chart(from: repo.days, last: Self.int(args["days"], default: 30, max: 120))
        guard !chart.points.isEmpty else { return "No \(metric.title) data recorded in that window." }
        return CoachVisualEvidence.describe(chart)
    }

    // MARK: Memory

    private func saveMemory(_ args: [String: Any]) async -> String {
        guard let content = (args["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            return "Nothing to save: content was empty."
        }
        do {
            _ = try await api.saveMemory(content: String(content.prefix(500)),
                                         topic: (args["topic"] as? String) ?? "general",
                                         importance: (args["importance"] as? Int) ?? 3)
            return "Saved."
        } catch {
            return "Could not save that right now."
        }
    }

    private func memories() async -> String {
        guard let items = try? await api.memories(), !items.isEmpty else { return "No saved memories yet." }
        return items.map { "• [\($0.topic)] \($0.content)" }.joined(separator: "\n")
    }
}

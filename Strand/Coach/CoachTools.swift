import Foundation
import WhoopStore
import StrandAnalytics

/// Display labels for the "Looked at" badge under an answer.
enum CoachToolDisplayNames {
    static func label(for tool: String) -> String {
        switch tool {
        case "get_health_overview": return "Health overview"
        case "get_daily_metrics": return "Daily metrics"
        case "get_workouts": return "Recent workouts"
        case "get_readiness_analysis": return "Readiness"
        case "prepare_chart": return "Metric series"
        case "get_intraday_series": return "Readings through the day"
        case "get_activity_context": return "Activity context"
        case "get_measurement_context": return "Measurement context"
        case "get_sleep_details": return "Sleep details"
        case "get_baseline_status": return "Personal baseline"
        case "save_memory": return "Saved note"
        case "get_memories": return "Past context"
        case "search_conversations": return "Past chats"
        case "read_conversation": return "Earlier chat"
        case "recall_context": return "Recalled from past chats"
        case "query_metric_history": return "Long-term history"
        case "find_days": return "Matching days"
        default: return tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// The WATCHDOG signal lines of `get_baseline_status`, pure so they are testable without an executor.
enum CoachWatchdogText {
    /// One line per observed signal, each carrying what the Watchdog's own activity head said the wearer was
    /// doing (D6-09): a heart rate of 104 vs an expected 72 reads very differently while walking than while
    /// still, and the model must not mistake the first for stress. `activityLabel` is the head's label for
    /// the LATEST minute of the scored window (`WatchdogResult.activityLabel` is the last per-minute label),
    /// not a summary of the whole 30 minutes, so the line says exactly that.
    static func signalLines(_ signals: [WatchdogSignalEvidence], activityLabel: String,
                            activityDetail: String) -> [String] {
        func fmt(_ v: Double) -> String { abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
        let label = activityLabel.isEmpty ? WatchdogActivityClass.unknown.rawValue : activityLabel
        let doing = activityDetail.isEmpty || activityDetail == label ? label : "\(activityDetail) [\(label)]"
        var lines: [String] = []
        for s in signals {
            guard let now = s.observed else { continue }
            var line = "  \(s.name): \(fmt(now)) \(s.unit)"
            if let usual = s.reconstructed ?? s.usual {
                line += " vs expected \(fmt(usual))"
                if s.rangeHalf > 0 { line += " ± \(fmt(s.rangeHalf))" }
            }
            if s.trustPct > 0 { line += " (trust \(s.trustPct)%)" }
            line += label == WatchdogActivityClass.unknown.rawValue
                ? "; activity unknown (the reading may be from movement)"
                : "; activity in the latest minute: \(doing)"
            lines.append(line)
        }
        return lines
    }
}

/// The tools the model may call. Every read comes from the same rows the rest of the app shows, so the
/// coach can never quote a number the user cannot find on screen.
///
/// The calls of one round run concurrently (`CoachChatViewModel`), so `execute` keeps no state of its own; the
/// only shared object is `refs`, which is locked.
@MainActor
struct CoachToolExecutor {
    let repo: Repository
    let engine: AICoachEngine
    let api: CoachAPI
    /// The open thread, so a saved memory records where it came from and recall can skip the chat already in view.
    var threadId: String? = nil
    /// Short names for the chats this turn has seen (`[t1]` in the prompt, `[t1 <uuid>]` in results).
    var refs = CoachThreadRefs()
    /// Screens model-written lines (memories, titles, summaries) before they go back into the prompt.
    var userAge: Int? = nil
    var baseline: BaselineStore? { engine.baseline }

    // MARK: Schemas

    static let definitions: [[String: Any]] = [
        tool("get_health_overview",
             "Last 14 days of charge, effort, sleep, HRV and resting HR, 28-day usuals, recent workouts. For broad 'how am I doing?' questions."),
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
        tool("get_intraday_series",
             "Readings THROUGH THE DAY, every minute for respiratory rate, steps and calories and every 5 minutes for HRV and resting heart rate. The strap records these continuously and the server recomputes them as data syncs, so HRV is NOT a once-per-night value. Use this for any question about today, intraday curves, 'how has it changed since morning', or the last few hours.",
             ["metric": ("string", CoachIntraday.metricNames),
              "hours": ("integer", "Hours back from now (default: last 24 h, or the local day so far for steps and calories; max 72)")],
             required: ["metric"]),
        tool("get_activity_context",
             "What the wearer was doing (sitting at a desk, standing, walking, running, lying down, sleeping, fidgeting, strap off), from the activity classifier's saved output, with the heart rate, HRV, respiratory rate and steps measured during each activity. Use for questions about posture, movement or context: 'was my heart rate high while I was sitting?', 'how much did I walk today?', 'what was I doing when my HRV dropped?'. Sitting and standing cannot be told apart from a wrist, so a still stretch is often reported as 'Still (sitting or standing)'.",
             ["hours": ("integer", "Hours back from now (default 6, max 168)"),
              "activity": ("string", "Optional: list only one activity: " + CoachActivityContext.activityNames)]),
        tool("get_measurement_context",
             "The server's context for one day's measurement of a vital: when it was taken, what the wearer was doing during and just before it, whether the signal passed its checks, sleep or wake and wear, which comparisons it qualifies for and why not, and how it differs from a reference taken in the same state. For heart rate it also gives awake versus asleep heart rate and sustained high or low pulse episodes. Use before calling a reading high or low, and for 'why is my HRV low today?' or 'was that taken while I was moving?'.",
             ["metric": ("string", CoachServerContext.metricNames),
              "day": ("string", "Optional: YYYY-MM-DD (default today)")],
             required: ["metric"]),
        tool("get_sleep_details",
             "A night's sleep details from the server: regularity, heart rate by sleep stage, falling asleep, breathing estimated from the heart-rate rhythm (not airflow), temperature and rest-activity rhythm, rebound after short nights and secondary HRV statistics. Use for questions about how a night went beyond the totals in get_daily_metrics.",
             ["day": ("string", "Optional: the day the night ended, YYYY-MM-DD (default today)")]),
        tool("get_baseline_status",
             "The wearer's PERSONAL BASELINE: for each vital (resting HR, HRV, wrist temperature, respiration, SpO2, awake heart rate), their own 7-day usual and longer 60-day usual with the usual range and how last night compares, plus the live Watchdog check of the last 30 minutes against those usuals, today's daily log and whether a treatment course is logged. Use for 'is this normal for me?', 'am I getting sick?', 'is my HRV/RHR/temperature off?', 'what's my baseline?', or any question comparing now to their usual. Separate from Charge; never a diagnosis."),
        tool("save_memory",
             "Save a durable fact about the user (goal, injury, preference, routine), third person, e.g. 'User is training for a half marathon in March'. Not transient data.",
             ["content": ("string", "The fact, under 400 characters"),
              "topic": ("string", memoryTopics.joined(separator: "|")),
              "importance": ("integer", "1-5 (5 = critical such as an injury)")],
             required: ["content"]),
        tool("get_memories", "Recall facts saved in earlier sessions. Without arguments, the most important ones; with a query, the most relevant.",
             ["query": ("string", "Optional: what you need to know, in a few keywords"),
              "topic": ("string", "Optional: only one topic: " + memoryTopics.joined(separator: "|"))]),
    ] + contextDefinitions

    /// The tools over the user's whole history: earlier chats (on the server) and every synced day (on the phone).
    /// Offered only when the server has the context routes; an old server keeps exactly the tools above.
    static let contextDefinitions: [[String: Any]] = [
        tool("search_conversations",
             "Search earlier chats with the user. Ranked keyword search over every message, grouped by chat, with dates, hit counts and snippets. Pass distinctive keywords, not a sentence. An empty query with days, from or to lists the chats from that period instead.",
             ["query": ("string", "Distinctive keywords, e.g. 'knee physio'; empty to browse by date"),
              "days": ("integer", "Only the last N days"),
              "from": ("string", "Start date, YYYY-MM-DD"),
              "to": ("string", "End date, YYYY-MM-DD (inclusive)")]),
        tool("read_conversation",
             "Read one earlier chat: its summary and a capped window of its messages, the recent ones or those around a query. Page with the cursor a result gives.",
             ["thread_id": ("string", "The chat's id, e.g. t1 or the UUID from a search result"),
              "query": ("string", "Optional: show the messages around these keywords"),
              "cursor": ("string", "Optional: the cursor from a previous read, for more")],
             required: ["thread_id"]),
        tool("recall_context",
             "Answer a question that spans many earlier chats ('what have we tried for my knee?', 'how has my training changed since spring?'). Examines the matching chats or the summaries of a period and returns dated notes with their sources and how much was covered. Evidence to answer from, not a reply to copy.",
             ["question": ("string", "What you need to know from past chats"),
              "keywords": ("string", "Optional: distinctive keywords to find the chats"),
              "from": ("string", "Optional: start date, YYYY-MM-DD"),
              "to": ("string", "Optional: end date, YYYY-MM-DD (inclusive)")],
             required: ["question"]),
        tool("query_metric_history",
             "One metric over the long term, from every synced day (years of data): grouped by day, week, month or year, with coverage and the whole-window mean, min and max. For trends beyond the last few weeks and 'how does this year compare with last'.",
             ["metric": ("string", CoachMetricHistory.metricNames),
              "from": ("string", "Optional: start date, YYYY-MM-DD"),
              "to": ("string", "Optional: end date, YYYY-MM-DD"),
              "days": ("integer", "Days back from today when no from is given (default 365, max 4000)"),
              "group": ("string", "day|week|month|year (default month; coarsened automatically past 120 rows)"),
              "stat": ("string", "mean|min|max|sum (default mean)")],
             required: ["metric"]),
        tool("find_days",
             "Find particular days in the user's whole history: values below or above a threshold, or the lowest or highest days, each with that day's charge, sleep, HRV and effort.",
             ["metric": ("string", CoachMetricHistory.metricNames),
              "below": ("number", "Optional: only days below this value"),
              "above": ("number", "Optional: only days above this value"),
              "from": ("string", "Optional: start date, YYYY-MM-DD"),
              "to": ("string", "Optional: end date, YYYY-MM-DD"),
              "limit": ("integer", "Days to list (default 10, max 30)"),
              "order": ("string", "recent|lowest|highest (default recent)")],
             required: ["metric"]),
    ]

    /// The topics the server stores; anything else is saved as `general`.
    static let memoryTopics = ["goal", "injury", "preference", "achievement", "lifestyle", "routine", "health",
                               "training", "nutrition", "sleep", "general"]

    private static let contextToolNames: Set<String> = Set(contextDefinitions.compactMap(CoachToolExecutor.name))

    /// Tools every turn keeps: memory and the series fetch the visual pipeline draws from, plus the history
    /// tools when the server has the context routes.
    private static let coreTools: Set<String> = ["get_memories", "save_memory", "prepare_chart", "get_intraday_series",
                                                  "get_activity_context"]

    private static func name(_ definition: [String: Any]) -> String? {
        (definition["function"] as? [String: Any])?["name"] as? String
    }

    /// Per-intent bundle: the core plus the data tools the question can plausibly need. Deterministic keyword
    /// routing; an unrecognised question falls back to the full set so a tool is never withheld by a guess.
    /// Without `context` (an old server) the history tools are never offered.
    static func definitions(for userText: String, context: Bool = false) -> [[String: Any]] {
        let offered = context ? definitions : definitions.filter { !(name($0).map(contextToolNames.contains) ?? false) }
        let t = userText.lowercased()
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        let extra: Set<String>
        if has(["workout", "session", "lift", "run ", "ran ", "ride", "swim", "exercise"]) {
            extra = ["get_workouts", "get_health_overview"]
        } else if has(["chart", "graph", "plot", "visuali"]) {
            extra = []
        } else if has(["remember", "preference", "about me"]) {
            extra = []
        } else if has(["baseline", "usual", "normal for me", "watchdog", "sick", " ill", "unwell", "coming down",
                       "fever", "temperature", "off today", "feel off"]) {
            extra = ["get_baseline_status", "get_daily_metrics", "get_readiness_analysis", "get_measurement_context"]
        } else if has(["should i train", "ready", "readiness", "overreach", "overtrain", "push", "rest day", "fatigue"]) {
            extra = ["get_readiness_analysis", "get_daily_metrics", "get_baseline_status"]
        } else if has(["sleep", "hrv", "recovery", "charge", "resting", "heart rate", "trend", "average", "week"]) {
            extra = ["get_daily_metrics", "get_readiness_analysis", "get_baseline_status", "get_measurement_context",
                     "get_sleep_details"]
        } else {
            return offered
        }
        let names = coreTools.union(extra).union(context ? contextToolNames : [])
        return offered.filter { name($0).map(names.contains) ?? false }
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
        case "get_intraday_series": return await intraday(args)
        case "get_activity_context": return await activityContext(args)
        case "get_measurement_context": return await measurementContext(args)
        case "get_sleep_details": return await sleepDetails(args)
        case "get_baseline_status": return baselineStatus()
        case "save_memory": return await saveMemory(args)
        case "get_memories": return await memories(args)
        case "search_conversations": return await searchConversations(args)
        case "read_conversation": return await readConversation(args)
        case "recall_context": return await recallContext(args)
        case "query_metric_history": return metricHistory(args)
        case "find_days": return findDays(args)
        default: return "Unknown tool: \(name)"
        }
    }

    private static func int(_ raw: Any?, default fallback: Int, max cap: Int) -> Int {
        let n = (raw as? Int) ?? (raw as? Double).map { Int($0) } ?? (raw as? String).flatMap(Int.init) ?? fallback
        return min(max(n, 1), cap)
    }

    private static func optionalInt(_ raw: Any?) -> Int? {
        (raw as? Int) ?? (raw as? Double).map { Int($0) } ?? (raw as? String).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func number(_ raw: Any?) -> Double? {
        let n = (raw as? Double) ?? (raw as? Int).map(Double.init) ?? (raw as? String).flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return n.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func text(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
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
        let header = "Last \(window.count) days, newest first (charge 0-100, effort 0-100, rest in hours, stages in hours, efficiency %, HRV ms, RHR bpm; a dash means NOT MEASURED. HRV and RHR here are one summary per day; for readings through the day call get_intraday_series):"
        return ([header] + window.map { "  " + engine.dayLine($0) }).joined(separator: "\n")
    }

    private func readiness() async -> String {
        let all = repo.days
        guard let latest = all.last(where: { $0.recovery != nil }) ?? all.last else { return "No wearable data is available yet." }
        // BaselineStandard fix I (audit 2026-10-07): windows are CALENDAR days ending on `latest.day` (were the
        // last N ROWS, which stretch across any wear gap and ran past `latest` when newer rows existed), and the
        // HRV / resting-HR comparison is `PersonalUsual`: the causal 28-day median of the days BEFORE `latest`
        // (ln for HRV), with the night count stated.
        func window(_ n: Int) -> [DailyMetric] {
            let start = BaselineStandard.shift(latest.day, by: -n) ?? ""
            return all.filter { $0.day > start && $0.day <= latest.day }
        }
        let last30 = window(30), last7 = window(7), last28 = window(28)
        let context = BaselineStandard.Context.app()

        func mean(_ days: [DailyMetric], _ pick: (DailyMetric) -> Double?) -> Double? {
            let xs = days.compactMap(pick)
            return xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
        }
        func fmt(_ v: Double?, _ digits: Int = 0) -> String { v.map { String(format: "%.\(digits)f", $0) } ?? "—" }
        func delta(_ now: Double?, _ ref: BaselineStandard.Reference, _ digits: Int = 0) -> String {
            guard let now, ref.usable else { return "—" }
            return String(format: "%+.\(digits)f", now - ref.centerNative)
        }

        var lines = ["READINESS (as of \(latest.day)):"]
        if let charge = latest.recovery {
            let zone = charge >= 67 ? "green (build/push)" : charge >= 34 ? "yellow (maintain)" : "red (recover)"
            lines.append("• Charge \(Int(charge.rounded())) — \(zone); 30-day average \(fmt(mean(last30) { $0.recovery })), 7-day \(fmt(mean(last7) { $0.recovery }))")
        } else {
            lines.append("• Charge not measured for \(latest.day).")
        }
        let hrvUsual = PersonalUsual.usual(days: all, metric: .hrvRmssd, asOf: latest.day, context: context)
        lines.append("• HRV \(fmt(latest.avgHrv)) ms vs \(PersonalUsual.phrase(hrvUsual, unit: " ms")) (\(delta(latest.avgHrv, hrvUsual)) ms); 7-day \(fmt(mean(last7) { $0.avgHrv })) ms")
        let rhrUsual = PersonalUsual.usual(days: all, metric: .restingHR, asOf: latest.day, context: context)
        lines.append("• Resting HR \(latest.restingHr.map(String.init) ?? "—") bpm vs \(PersonalUsual.phrase(rhrUsual, unit: " bpm")) (\(delta(latest.restingHr.map(Double.init), rhrUsual)) bpm); 7-day \(fmt(mean(last7) { $0.restingHr.map(Double.init) })) bpm")

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

    /// Same evaluations Watchdog scores against and the Monitor tab draws, so a quoted usual matches the screen.
    private func baselineStatus() -> String {
        guard let baseline else { return "The personal baseline is not available in this context." }
        guard !repo.days.isEmpty else { return "No wearable data is available yet, so there is no personal baseline." }
        func fmt(_ v: Double) -> String { abs(v) >= 100 ? String(format: "%.0f", v) : String(format: "%.1f", v) }
        func signed(_ v: Double) -> String { (v >= 0 ? "+" : "") + fmt(v) }

        var lines = ["PERSONAL BASELINE (on-device day-and-night usuals; separate from Charge; not a diagnosis):"]
        for ev in baseline.watchdogPromptEvaluations(days: repo.days) {
            let unit = ev.series.planRow.unit
            var parts: [String] = []
            if ev.show7, let c = ev.copy7 {
                var part = "7-day usual \(fmt(c.centerDisplay)) \(unit) (range \(fmt(c.bandLoDisplay))–\(fmt(c.bandHiDisplay)), trust \(ev.usualTrustPct7)%)"
                if let d = c.deltaDisplay { part += ", last night \(signed(d)) vs usual" }
                parts.append(part)
            }
            if ev.showLong, let c = ev.copyLong {
                parts.append("60-day usual \(fmt(c.centerDisplay)) \(unit) (range \(fmt(c.bandLoDisplay))–\(fmt(c.bandHiDisplay))\(ev.stale ? ", stale" : ""))")
            }
            if parts.isEmpty { parts.append("still learning (\(ev.n7) usable nights this week)") }
            lines.append("• \(ev.series.planRow.planName): " + parts.joined(separator: "; "))
        }

        lines.append("")
        if let r = baseline.watchdogResult {
            let age = max(0, Int(Date().timeIntervalSince1970) - r.lastTickUnix) / 60
            lines.append("WATCHDOG (last 30 minutes vs the usual; checked \(age == 0 ? "just now" : "\(age) min ago")):")
            if let reason = r.unavailable {
                lines.append("• Not scoring right now (\(reason.rawValue)). Do not infer a reading for this stretch.")
            } else {
                lines.append("• \(r.headline) \(r.episodeLine)")
                lines += CoachWatchdogText.signalLines(r.signals, activityLabel: r.activityLabel,
                                                       activityDetail: r.activityDetail)
                if !r.contributing.isEmpty { lines.append("• Moving away from usual: " + r.contributing.joined(separator: ", ")) }
            }
        } else {
            lines.append("WATCHDOG: no live check yet this session (the strap may not be streaming).")
        }

        if let log = baseline.calendarTodayLog {
            lines.append("")
            lines.append("TODAY'S DAILY LOG: " + log.summaryLine)
        }
        if baseline.activeStart != nil {
            lines.append("A treatment course is logged; the long usual restarted at its start. Do not guess which treatment.")
        }
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

    private func intraday(_ args: [String: Any]) async -> String {
        guard let raw = args["metric"] as? String, let metric = CoachIntraday.metric(named: raw) else {
            return "Unknown metric. Use one of: " + CoachIntraday.metricNames
        }
        guard let repository = CloudPushRuntime.shared.scoreRepository() else {
            return "Intraday readings are not available on this install because cloud scoring is off. "
                + "Only the daily summaries from get_daily_metrics exist here; say so rather than assuming the strap records once a day."
        }
        let now = Date()
        let bounds: IntradayRange.Bounds
        if args["hours"] != nil {
            let hours = Self.int(args["hours"], default: 24, max: 72)
            let to = (Int(now.timeIntervalSince1970) / IntradayRange.bucketSeconds + 1) * IntradayRange.bucketSeconds
            bounds = IntradayRange.Bounds(from: to - hours * 3_600, to: to,
                                          key: "coach|\(metric.rawValue)|\(hours)h", isLive: true)
        } else {
            bounds = IntradayRange.bounds(for: metric, dayOffset: 0, now: now)
        }
        do {
            let window = try await repository.intradaySeries(
                from: bounds.from, to: bounds.to, deviceId: IntradaySeriesStore.shared.readDeviceId,
                metrics: [metric], cacheKey: bounds.key)
            return CoachIntraday.describe(window: window, metric: metric, now: now)
        } catch {
            if let cached = await repository.cachedIntradaySeries(cacheKey: bounds.key,
                                                                  deviceId: IntradaySeriesStore.shared.readDeviceId) {
                return "(Could not reach the server; these are the last saved readings.)\n"
                    + CoachIntraday.describe(window: cached, metric: metric, now: now)
            }
            return "Could not load intraday readings right now. Tell the user the live curve is unavailable, "
                + "and do not say the device records only one value per day."
        }
    }

    private func activityContext(_ args: [String: Any]) async -> String {
        var activity: ActivityClass?
        if let raw = (args["activity"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            guard let match = CoachActivityContext.activity(named: raw) else {
                return "Unknown activity. Use one of: " + CoachActivityContext.activityNames
            }
            activity = match
        }
        let now = Date()
        let to = Int(now.timeIntervalSince1970)
        let from = to - Self.int(args["hours"], default: 6, max: 168) * 3_600
        // With each day's ledger standing, so 'provisional' / 'from an older model' come from the ledger, and
        // with the user's stretch corrections applied (D9-07).
        // A look back over past days, never a baseline: finished days read their retrospective (smoothed) rows where
        // they have them (D8-10); today and any provisional day stay causal.
        let stored = await repo.storedActivityContextWithStatus(from: from, to: to, reading: .historical)
        return CoachActivityContext.describe(intervals: stored.intervals, from: from, to: to, activity: activity,
                                             storedThrough: stored.through, days: stored.days, now: now)
    }

    private func measurementContext(_ args: [String: Any]) async -> String {
        guard let raw = args["metric"] as? String, let metric = CoachServerContext.metric(named: raw) else {
            return "Unknown metric. Use one of: " + CoachServerContext.metricNames
        }
        let day = CoachServerContext.day(args["day"]) ?? Repository.localDayKey(Date())
        let key = PhysiologyContextStore.Key(day: day, metric: metric)
        await PhysiologyContextStore.shared.load(key)
        return CoachServerContext.describe(state: PhysiologyContextStore.shared.state(for: key), metric: metric, day: day)
    }

    /// The same read as the Sleep page's `SleepFeatureSection`: cache first, then the server.
    private func sleepDetails(_ args: [String: Any]) async -> String {
        guard CloudPushIdentityStore.current() != nil, let repository = CloudPushRuntime.shared.scoreRepository() else {
            return "Sleep details come from cloud scoring, which is not available on this install."
        }
        let day = CoachServerContext.day(args["day"]) ?? Repository.localDayKey(Date())
        let deviceIds = await IntradaySeriesStore.shared.readCandidates
        var hosted = await repository.cachedDay(day: day, deviceIds: deviceIds)?.hostedResult
        if hosted?.sleepFeatures == nil {
            hosted = (try? await repository.refresh(day: day, deviceIds: deviceIds))?.hostedResult
        }
        guard let document = hosted?.sleepFeatures, let night = document.night(matchingStart: nil, end: nil) else {
            return "The server has no sleep details for the night ending \(day)."
        }
        let model = SleepFeatureDisplayModel(document: document, night: night,
                                             analyticsPresent: hosted?.sleepAnalytics != nil)
        return CoachServerContext.describe(model, day: day)
    }

    // MARK: Memory

    private func saveMemory(_ args: [String: Any]) async -> String {
        guard let content = (args["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !content.isEmpty else {
            return "Nothing to save: content was empty."
        }
        let topic = Self.text(args["topic"])?.lowercased()
        do {
            _ = try await api.saveMemory(content: String(content.prefix(500)),
                                         topic: topic.flatMap { Self.memoryTopics.contains($0) ? $0 : nil } ?? "general",
                                         importance: min(max(Self.optionalInt(args["importance"]) ?? 3, 1), 5),
                                         threadId: threadId)
            return "Saved."
        } catch {
            return "Could not save that right now."
        }
    }

    /// Model-written memory lines feed back into the prompt, so each passes `CoachSafety.screenStored` first.
    private func memories(_ args: [String: Any]) async -> String {
        let query = Self.text(args["query"]), topic = Self.text(args["topic"])?.lowercased()
        let items = (try? await api.memories(query: query, topic: topic, limit: query == nil && topic == nil ? nil : 20)) ?? []
        let kept = items.filter { CoachContextPrompt.isSafe($0.content, userAge: userAge) }
        guard !kept.isEmpty else { return query == nil && topic == nil ? "No saved memories yet." : "No saved memories match that." }
        return kept.map { "• [\($0.topic)] \($0.content)" }.joined(separator: "\n")
    }

    // MARK: Earlier chats

    private func searchConversations(_ args: [String: Any]) async -> String {
        let query = Self.text(args["query"]) ?? ""
        let days = Self.optionalInt(args["days"]).map { min(max($0, 1), CoachMetricHistory.maxDays) }
        let from = Self.text(args["from"]), to = Self.text(args["to"])
        let result: CoachContextSearchResult
        do {
            result = try await api.contextSearch(query: query, from: from, to: to, days: days, limit: 20)
        } catch {
            return "Past chats can't be searched right now. Say so if the answer depends on them."
        }
        return CoachContextToolText.search(result, query: query, currentThreadId: threadId, refs: refs, userAge: userAge)
    }

    private func readConversation(_ args: [String: Any]) async -> String {
        guard let raw = Self.text(args["thread_id"]) ?? Self.text(args["threadId"]), let id = refs.resolve(raw) else {
            return "Unknown chat. Use a thread id from search_conversations (for example t1 or its UUID)."
        }
        do {
            let result = try await api.contextThread(threadId: id, query: Self.text(args["query"]),
                                                     cursor: Self.text(args["cursor"]))
            return CoachContextToolText.read(result, threadId: id, refs: refs, userAge: userAge)
        } catch let error as CoachRouteError where error.status == 404 {
            return "That chat no longer exists."
        } catch {
            return "That chat can't be read right now."
        }
    }

    private func recallContext(_ args: [String: Any]) async -> String {
        guard let question = Self.text(args["question"]) else { return "Nothing to recall: the question was empty." }
        do {
            let result = try await api.contextRecall(question: question, keywords: Self.text(args["keywords"]),
                                                     threadId: threadId, from: Self.text(args["from"]),
                                                     to: Self.text(args["to"]))
            return CoachContextToolText.recall(result, refs: refs, userAge: userAge)
        } catch {
            return "Past chats can't be recalled right now. Say so if the answer depends on them."
        }
    }

    // MARK: Long-term history

    private func metricHistory(_ args: [String: Any]) -> String {
        guard let metric = CoachMetricHistory.metric(named: args["metric"] as? String) else {
            return "Unknown metric. Use one of: " + CoachMetricHistory.metricNames
        }
        let group = Self.text(args["group"]).flatMap { CoachMetricHistory.Group(rawValue: $0.lowercased()) } ?? .month
        let stat = Self.text(args["stat"]).flatMap { CoachMetricHistory.Stat(rawValue: $0.lowercased()) } ?? .mean
        return CoachMetricHistory.history(days: repo.days, metric: metric, from: Self.text(args["from"]),
                                          to: Self.text(args["to"]), days: Self.optionalInt(args["days"]),
                                          group: group, stat: stat)
    }

    private func findDays(_ args: [String: Any]) -> String {
        guard let metric = CoachMetricHistory.metric(named: args["metric"] as? String) else {
            return "Unknown metric. Use one of: " + CoachMetricHistory.metricNames
        }
        let order = Self.text(args["order"]).flatMap { CoachMetricHistory.Order(rawValue: $0.lowercased()) } ?? .recent
        return CoachMetricHistory.findDays(days: repo.days, metric: metric, below: Self.number(args["below"]),
                                           above: Self.number(args["above"]), from: Self.text(args["from"]),
                                           to: Self.text(args["to"]), limit: Self.optionalInt(args["limit"]), order: order)
    }
}

// MARK: - Context tool results

/// The text the history tools hand back to the model: capped, dated, every chat named `[t1 <uuid>]`, and every
/// model-written line (titles, summaries, recall notes) passed through `CoachSafety.screenStored`.
enum CoachContextToolText {
    static func search(_ r: CoachContextSearchResult, query: String, currentThreadId: String?,
                       refs: CoachThreadRefs, userAge: Int?) -> String {
        let current = currentThreadId?.lowercased()
        guard !r.threads.isEmpty else {
            return query.isEmpty ? "No chats in that period." : "No earlier chat mentions \"\(query)\"."
        }
        var lines: [String] = []
        if query.isEmpty {
            lines.append("PAST CHATS in that period, newest first (\(r.threads.count) shown):")
        } else {
            var head = "PAST CHATS matching \"\(query)\": \(r.totalHits) matching messages across at least \(r.threads.count) chats"
            if !r.terms.isEmpty { head += " (terms: \(r.terms.joined(separator: ", "))" + (r.droppedTerms.isEmpty ? ")" : "; too common to search: \(r.droppedTerms.joined(separator: ", ")))") }
            lines.append(head + ".")
            let months = r.months.filter { $0.hits > 0 }.prefix(12).map { "\($0.month) \($0.hits)" }
            if !months.isEmpty { lines.append("Hits by month: " + months.joined(separator: ", ")) }
        }
        for t in r.threads {
            var line = "\(refs.label(for: t.threadId)) \"\(safeTitle(t.title, userAge: userAge))\""
            if let at = day(t.lastMessageAt) { line += ", last \(at)" }
            if let hits = t.hits, hits > 0 { line += ", \(hits) hits" }
            if t.threadId.lowercased() == current { line += " (this chat)" }
            lines.append(line)
            if let summary = safe(t.summary, userAge: userAge) { lines.append("  summary: " + summary) }
            if let snippet = t.snippet.map(CoachModelText.collapsed), !snippet.isEmpty { lines.append("  match: " + snippet) }
        }
        if r.threads.count >= 8 || r.totalHits > r.threads.reduce(0, { $0 + ($1.hits ?? 0) }) {
            lines.append("Results are capped; there may be more. Use read_conversation with a chat id for detail, or recall_context for a question across many chats.")
        } else {
            lines.append("Use read_conversation with a chat id to read one.")
        }
        return lines.joined(separator: "\n")
    }

    static func read(_ r: CoachContextThreadResult, threadId: String, refs: CoachThreadRefs, userAge: Int?) -> String {
        let info = r.thread
        var head = "EARLIER CHAT \(refs.label(for: info?.id ?? threadId)) \"\(safeTitle(info?.title, userAge: userAge))\""
        if let first = day(info?.createdAt), let last = day(info?.lastMessageAt) { head += ", \(first) to \(last)" }
        if let n = info?.messageCount { head += ", \(n) messages" }
        var lines = [head + "."]
        if let summary = safe(info?.summary, userAge: userAge) { lines.append("Summary: " + summary) }
        lines.append(r.window == "around_matches" ? "Messages around the matches:" : "Most recent messages:")
        // Raw messages, not model summaries: the server already leaves out blocked turns.
        for m in r.messages {
            let who = m.role == "user" ? "User" : "Sana"
            lines.append("[\(stamp(m.at))] \(who): \(CoachModelText.collapsed(m.content))")
        }
        if r.messages.isEmpty { lines.append("(no readable messages)") }
        if r.hasMore, let cursor = r.nextCursor {
            lines.append("More messages exist: call read_conversation with this thread_id and cursor \"\(cursor)\".")
        }
        return lines.joined(separator: "\n")
    }

    static func recall(_ r: CoachRecallResult, refs: CoachThreadRefs, userAge: Int?) -> String {
        switch r.status {
        case "nothing_found": return "Nothing in earlier chats covers that."
        case "unavailable": return "Past chats can't be recalled right now. Say so if the answer depends on them."
        default: break
        }
        var lines = ["RECALLED FROM PAST CHATS (evidence for your answer; not a reply to copy):"]
        let notes = CoachContextPrompt.sentences(r.answer).filter { CoachContextPrompt.isSafe($0, userAge: userAge) }
        lines.append(notes.isEmpty ? "(no usable notes)" : notes.joined(separator: " "))
        if !r.sources.isEmpty {
            lines.append("Sources: " + r.sources.prefix(8).map { s -> String in
                var item = "\(refs.label(for: s.threadId)) \"\(safeTitle(s.title, userAge: userAge))\""
                if let at = day(s.at) { item += " (\(at))" }
                return item
            }.joined(separator: "; "))
        }
        if let c = r.coverage {
            var line = "Coverage: examined \(c.threadsExamined ?? 0) of \(c.threadsMatched ?? 0) matching chats"
            if let hits = c.totalHits { line += ", \(hits) matching messages" }
            if c.truncated == true || r.status == "partial" || r.status == "budget" {
                line += ". Not everything was examined, so say \"at least\" for any count"
            }
            lines.append(line + ".")
        }
        if r.status == "budget" { lines.append("(Only keyword snippets were available this time.)") }
        return lines.joined(separator: "\n")
    }

    private static func safe(_ raw: String?, userAge: Int?) -> String? {
        guard let raw else { return nil }
        let kept = CoachContextPrompt.sentences(raw).filter { CoachContextPrompt.isSafe($0, userAge: userAge) }
        return kept.isEmpty ? nil : kept.joined(separator: " ")
    }

    private static func safeTitle(_ raw: String?, userAge: Int?) -> String {
        guard let raw, CoachContextPrompt.isSafe(raw, userAge: userAge) else { return "Untitled chat" }
        return CoachModelText.collapsed(raw).replacingOccurrences(of: "\"", with: "'")
    }

    private static func day(_ raw: String?) -> String? { CoachDates.parse(raw).map { CoachDates.day($0) } }

    private static func stamp(_ raw: String?) -> String {
        guard let date = CoachDates.parse(raw) else { return "?" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}

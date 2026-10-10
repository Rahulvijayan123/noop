import Foundation
import WhoopStore

// MARK: - Thread references

/// Short names for the chats one turn has seen. The system prompt names an earlier chat `[t1]`; tool results
/// show `[t1 <uuid>]`; a tool argument may be either. One instance lives for one turn and is shared by every tool
/// call in it, which may run concurrently.
final class CoachThreadRefs: @unchecked Sendable {
    private let lock = NSLock()
    private var refById: [String: String] = [:]
    private var idByRef: [String: String] = [:]

    init() {}

    /// The ref for `id`, assigning the next free one the first time it is seen.
    func ref(for id: String) -> String {
        let key = id.lowercased()
        lock.lock(); defer { lock.unlock() }
        if let known = refById[key] { return known }
        let ref = "t\(refById.count + 1)"
        refById[key] = ref
        idByRef[ref] = key
        return ref
    }

    /// `[t1 <uuid>]`, the form tool results use.
    func label(for id: String) -> String { "[\(ref(for: id)) \(id.lowercased())]" }

    /// A thread id from `t1`, `[t1]`, `[t1 <uuid>]` or a bare UUID; nil when it names nothing this turn has seen
    /// and is not a UUID either.
    func resolve(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: "[] \"'\n\t"))
        let tokens = trimmed.split(whereSeparator: { $0 == " " || $0 == "<" || $0 == ">" }).map(String.init)
        if let uuid = tokens.first(where: { UUID(uuidString: $0) != nil }) { return uuid.lowercased() }
        guard let first = tokens.first?.lowercased() else { return nil }
        lock.lock(); defer { lock.unlock() }
        return idByRef[first]
    }
}

// MARK: - Coverage and turn context

/// What wearable history this phone holds, for the library block. Counts only; never values.
struct CoachDataCoverage: Equatable, Sendable {
    /// Days with any measurement.
    var days: Int
    var firstDay: String?
    var lastDay: String?
    var workouts: Int?
    var journalDays: Int?

    init(days: Int, firstDay: String? = nil, lastDay: String? = nil, workouts: Int? = nil, journalDays: Int? = nil) {
        self.days = days
        self.firstDay = firstDay
        self.lastDay = lastDay
        self.workouts = workouts
        self.journalDays = journalDays
    }

    static func make(days: [DailyMetric], workouts: Int? = nil, journalDays: Int? = nil) -> CoachDataCoverage {
        let measured = days.filter {
            $0.recovery != nil || $0.avgHrv != nil || $0.totalSleepMin != nil || $0.strain != nil
                || $0.restingHr != nil || $0.steps != nil
        }
        return CoachDataCoverage(days: measured.count, firstDay: measured.first?.day, lastDay: measured.last?.day,
                                 workouts: workouts, journalDays: journalDays)
    }
}

/// Everything the context-aware system prompt needs for one turn (`docs/COACH_MEMORY.md` §7.4).
struct CoachTurnContext {
    /// The server's manifest for this thread and question, or the cached one; nil when neither is available.
    var manifest: CoachContextManifest?
    /// Memories to list when there is no manifest (the last list the phone fetched).
    var memories: [CoachMemory] = []
    var coverage: CoachDataCoverage?
    /// Messages in this thread, including the question being answered.
    var messageCount: Int = 0
    /// The first question of a new chat: the only turn that lists open loops from other chats.
    var isFirstTurn: Bool = false
    var currentThreadId: String?
    var refs = CoachThreadRefs()
    var timeZone: TimeZone = .current
    /// Where the strap is worn now and its recent switches (hsmm-2.0), e.g. "bicep since 2026-10-07; was wrist":
    /// sitting/standing, skin temperature and the step estimate are calibrated per placement.
    var placement: String?
}

// MARK: - Blocks

/// The dynamic tail of the context-aware system prompt: remembered context, the summary of the older part of a
/// long thread, and the context library manifest. The library names what exists and which tool inspects it,
/// never its contents. Every model-written line passes `CoachSafety.screenStored` first.
enum CoachContextPrompt {
    /// The phone sends this many recent messages; a longer thread also gets its summary.
    static let historyWindow = 28
    static let rememberedLimit = 8
    static let relevantLimit = 3
    static let openLoopLimit = 2

    static let libraryHeader = "CONTEXT LIBRARY (queryable, not loaded):"

    /// Saved memories are what the user stands by now: they can correct or forget one, while an older chat keeps
    /// what was said then.
    static let memoryPrecedence = """
    Saved memories are the user's current facts, and the user may have corrected them: when a saved memory and an \
    earlier chat (or an older message in this one) disagree, go by the saved memory.
    """

    static let howToUse = """
    HOW TO USE IT: These are available on request, not loaded. For what was said in earlier chats, call \
    search_conversations (distinctive keywords, or an empty query with days, from or to to browse by date), then \
    read_conversation with a thread id. For a question that spans many chats ("what have we tried for my knee?", \
    "how has my training changed since spring?"), call recall_context. For wearable trends beyond the last few weeks, \
    call query_metric_history; to find particular days (lowest HRV, nights under 6 hours), call find_days. For saved \
    facts beyond those listed above, call get_memories with a query or topic. Results are capped: when a result says \
    it was truncated or that there are more, say "at least" rather than giving an exact total. Facts about the user \
    are captured automatically after each chat, so call save_memory only when the user asks you to remember \
    something or shares a critical fact such as an injury. Use what you find naturally, and never mention these \
    tools, the library or this context to the user.
    """

    static func blocks(_ context: CoachTurnContext, userAge: Int?) -> [String] {
        var out: [String] = []
        let memories = context.manifest?.memories ?? context.memories
        if let remembered = remembered(memories, userAge: userAge) { out.append(remembered) }
        if let earlier = earlier(context, userAge: userAge) { out.append(earlier) }
        out.append(library(context, userAge: userAge))
        return out
    }

    /// The legacy block's exact header and line format, over screened memories.
    static func remembered(_ memories: [CoachMemory], userAge: Int?) -> String? {
        let kept = memories.filter { isSafe($0.content, userAge: userAge) }.prefix(rememberedLimit)
        guard !kept.isEmpty else { return nil }
        return CoachPrompt.rememberedBlock(lines: kept.map { "• [\($0.topic)] \($0.content)" })
    }

    /// Only for a thread longer than the window the phone sends, and only the summary lines that pass the screen.
    static func earlier(_ context: CoachTurnContext, userAge: Int?) -> String? {
        guard context.messageCount > historyWindow, let thread = context.manifest?.thread,
              thread.id.isEmpty || context.currentThreadId == nil || thread.id == context.currentThreadId?.lowercased(),
              let summary = thread.summary, !summary.isEmpty else { return nil }
        let kept = sentences(summary).filter { isSafe($0, userAge: userAge) }
        guard !kept.isEmpty else { return nil }
        let through = CoachDates.parse(thread.summaryThrough).map { " through " + CoachDates.day($0, timeZone: context.timeZone) } ?? ""
        return "EARLIER IN THIS CONVERSATION (summary\(through); older than the messages below):\n" + kept.joined(separator: " ")
    }

    static func library(_ context: CoachTurnContext, userAge: Int?) -> String {
        var lines = [libraryHeader]
        let tz = context.timeZone
        let current = context.currentThreadId?.lowercased()
        func day(_ raw: String?) -> String? { CoachDates.parse(raw).map { CoachDates.day($0, timeZone: tz) } }
        func title(_ raw: String?) -> String {
            guard let raw, !raw.isEmpty, isSafe(raw, userAge: userAge) else { return "Untitled chat" }
            return CoachModelText.collapsed(raw).replacingOccurrences(of: "\"", with: "'")
        }

        if let manifest = context.manifest {
            let lib = manifest.library
            if lib.threadCount > 0 {
                var line = "• Earlier chats: \(lib.threadCount)"
                if let first = day(lib.firstAt), let last = day(lib.lastAt) { line += ", from \(first) to \(last)" }
                lines.append(line + ".")
            } else {
                lines.append("• Earlier chats: none yet.")
            }

            let relevant = lib.relevant.filter { $0.id != current }.prefix(relevantLimit).map { t -> String in
                var item = "[\(context.refs.ref(for: t.id))] \"\(title(t.title))\""
                if let at = day(t.lastMessageAt) { item += " (\(at))" }
                return item
            }
            if !relevant.isEmpty { lines.append("• Relevant earlier chats: " + relevant.joined(separator: "; ")) }

            if context.isFirstTurn {
                let loops = manifest.openLoops
                    .filter { $0.threadId != current && isSafe($0.text, userAge: userAge) }
                    .prefix(openLoopLimit)
                    .map { loop -> String in
                        let text = CoachModelText.collapsed(loop.text)
                        guard let id = loop.threadId else { return text }
                        return "[\(context.refs.ref(for: id))] \"\(title(loop.title))\": \(text)"
                    }
                if !loops.isEmpty { lines.append("• Still open from recent chats: " + loops.joined(separator: "; ")) }
            }

            if manifest.memoryCount > 0 {
                let topics = manifest.memoryTopics.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                    .map { $0.value > 0 ? "\($0.key) \($0.value)" : $0.key }
                lines.append("• Saved memories: \(manifest.memoryCount)" + (topics.isEmpty ? "." : " (\(topics.joined(separator: ", ")))."))
            } else {
                lines.append("• Saved memories: none yet.")
            }
        } else {
            lines.append("• Earlier chats and saved memories: searchable, but no overview was loaded this turn.")
        }

        if let c = context.coverage, c.days > 0 {
            var line = "• Wearable history on this phone: \(c.days) measured days"
            if let first = c.firstDay, let last = c.lastDay { line += " from \(first) to \(last)" }
            if let w = c.workouts { line += "; \(w) workouts" }
            if let j = c.journalDays, j > 0 { line += "; journal on \(j) days" }
            lines.append(line + ".")
        } else {
            lines.append("• Wearable history on this phone: none synced yet.")
        }
        if let p = context.placement {
            lines.append("• Strap placement: \(p). Sitting/standing detection, the skin-temperature baseline and the step estimate are calibrated per placement; values from before a switch were measured elsewhere on the body.")
        }
        lines.append(howToUse)
        lines.append(memoryPrecedence)
        return lines.joined(separator: "\n")
    }

    // MARK: Helpers

    /// A stored, model-written line that may go back into a prompt: not empty and passing
    /// `CoachSafety.screenStored`. The question screen is not used here, so a pinned injury or health fact stays.
    static func isSafe(_ text: String, userAge: Int?) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !CoachSafety.screenStored(text)
    }

    /// A summary split into sentences, so one line that trips the screen drops alone instead of the whole summary.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: [.bySentences, .localized]) { sub, _, _, _ in
            let s = CoachModelText.collapsed(sub ?? "")
            if !s.isEmpty { out.append(s) }
        }
        return out.isEmpty ? [CoachModelText.collapsed(text)].filter { !$0.isEmpty } : out
    }
}

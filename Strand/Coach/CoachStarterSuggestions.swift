import Foundation
import StrandAnalytics
import WhoopStore

// MARK: - Suggestion

/// One chip on the empty-chat screen. `continue` reopens an earlier chat (`threadId`) and asks there; the other
/// kinds start in the open chat.
struct CoachStarterSuggestion: Codable, Equatable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case `continue`, state, goal, explore
    }

    var text: String
    var kind: Kind
    var threadId: String?

    init(text: String, kind: Kind, threadId: String? = nil) {
        self.text = text
        self.kind = kind
        self.threadId = threadId?.lowercased()
    }

    private enum CodingKeys: String, CodingKey { case text, kind, threadId }

    /// An unknown kind reads as `explore`, so a newer server can add kinds without emptying the screen.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        text = try c.decode(String.self, forKey: .text)
        kind = c.lossy(String.self, .kind).flatMap(Kind.init(rawValue:)) ?? .explore
        threadId = c.lossy(String.self, .threadId)?.lowercased()
    }

    var id: String { kind.rawValue + "|" + text }

    /// The SF Symbol drawn beside the chip.
    var symbol: String { Self.symbol(for: kind) }

    static func symbol(for kind: Kind) -> String {
        switch kind {
        case .continue: return "bubble.left.and.bubble.right"
        case .state: return "waveform.path.ecg"
        case .goal: return "target"
        case .explore: return "sparkles"
        }
    }
}

/// The server set as last fetched, kept per owner in `suggestions.json`. It is shown straight away only on the
/// local day it was fetched.
struct CoachCachedSuggestions: Codable, Equatable, Sendable {
    var suggestions: [CoachStarterSuggestion]
    /// `yyyy-MM-dd`, local.
    var day: String
    var source: String?
    var savedAt: Date
}

// MARK: - State snapshot

/// A workout as the snapshot needs it: when it started and what it was.
struct CoachWorkoutStamp: Equatable, Sendable {
    let startTs: Int
    let sport: String
}

/// The phone's coarse state, sent as `state` to `POST suggestions` (`docs/COACH_MEMORY.md` §7.5). Everything is
/// a band, a rounded value or a flag, so the server's cache fingerprint stays stable through the day. Charge and
/// effort are left out: the app does not compute them, so no starter may be built on them.
struct CoachUserStateSnapshot: Codable, Equatable, Sendable {
    /// The newest day with data, `yyyy-MM-dd`.
    var day: String?
    /// Overnight HRV (RMSSD, asleep) against the 30-night mean: `down | normal | up`.
    var hrv: String?
    /// Last night: `short | ok | long`.
    var sleep: String?
    /// Last night's sleep rounded to the nearest half hour.
    var sleepHours: Double?
    /// The live Watchdog severity (`withinLimits`, `note`, `candidate`, `active`, `severe`), when it is scoring.
    var watchdog: String?
    /// The Watchdog headline, only when it carries no readings.
    var watchdogHeadline: String?
    var daysSinceWorkout: Int?
    var lastSport: String?
    /// Days with any measurement.
    var dataDays: Int
    /// `Monday`…`Sunday`, local.
    var weekday: String
    /// `morning | afternoon | evening | night`, local.
    var dayPart: String
    /// Notable states the suggestions should ground at least one chip in.
    var flags: [String]

    static func make(days: [DailyMetric], workouts: [CoachWorkoutStamp] = [], watchdogSeverity: String? = nil,
                     watchdogHeadline: String? = nil, now: Date = Date(), calendar: Calendar = .current) -> CoachUserStateSnapshot {
        let measured = days.filter { $0.avgHrv != nil || $0.totalSleepMin != nil }
        let latest = measured.last
        var flags: [String] = []

        var hrv: String?
        if let latest, let latestHrv = latest.avgHrv {
            let base = measured.filter { $0.day != latest.day }.suffix(30).compactMap(\.avgHrv)
            if base.count >= 7 {
                let mean = base.reduce(0, +) / Double(base.count)
                hrv = latestHrv < 0.85 * mean ? "down" : latestHrv > 1.15 * mean ? "up" : "normal"
                if hrv == "down" { flags.append("hrv_down") }
            }
        }

        var sleep: String?
        var sleepHours: Double?
        if let minutes = latest?.totalSleepMin {
            sleep = minutes < 360 ? "short" : minutes > 540 ? "long" : "ok"
            sleepHours = (minutes / 30).rounded() / 2
            if sleep == "short" { flags.append("short_sleep") }
        }

        var watchdog: String?
        if let severity = watchdogSeverity, severity != "dataUnavailable" {
            watchdog = severity
            if ["candidate", "active", "severe"].contains(severity) { flags.append("watchdog_" + severity) }
        }
        let headline = watchdogHeadline.flatMap { $0.rangeOfCharacter(from: .decimalDigits) == nil && !$0.isEmpty ? $0 : nil }

        var daysSinceWorkout: Int?
        var lastSport: String?
        if let newest = workouts.max(by: { $0.startTs < $1.startTs }) {
            let start = calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(newest.startTs)))
            daysSinceWorkout = max(0, calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: now)).day ?? 0)
            lastSport = newest.sport
            if (daysSinceWorkout ?? 0) > 7 { flags.append("no_recent_workout") }
        }

        let weekdayIndex = calendar.component(.weekday, from: now) - 1
        let weekdays = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let hour = calendar.component(.hour, from: now)
        let dayPart = (5..<12).contains(hour) ? "morning" : (12..<17).contains(hour) ? "afternoon"
            : (17..<22).contains(hour) ? "evening" : "night"

        return CoachUserStateSnapshot(day: latest?.day, hrv: hrv, sleep: sleep,
                                      sleepHours: sleepHours, watchdog: watchdog, watchdogHeadline: headline,
                                      daysSinceWorkout: daysSinceWorkout, lastSport: lastSport, dataDays: measured.count,
                                      weekday: weekdays[max(0, min(6, weekdayIndex))], dayPart: dayPart, flags: flags)
    }
}

// MARK: - Sets

enum CoachStarterSuggestions {
    static let limit = 4
    static let maxContinue = 2

    /// The shared banding's chips that stand on Charge or Effort, which the app does not compute.
    static let scoreChips: Set<String> = [
        "Low energy today — how should I pace myself?", "A steady day — how should I pace it?",
        "I'm feeling good today — how can I make the most of it?", "Have I done enough today, or should I rest?",
    ]

    /// The phone's own chips: the banded `CoachSuggestions` first (contextual when there is data), then the
    /// generic `CoachPrompts`.
    static func local(today: DailyMetric?, recent: [DailyMetric], userAge: Int? = nil) -> [CoachStarterSuggestion] {
        let banded = CoachSuggestions.suggestions(for: today, recent: recent).filter { !scoreChips.contains($0) }
        // Only the stable generic chip left means nothing contextual fired.
        let contextual = banded.count > 1 && banded != CoachSuggestions.fallback
        let items = banded.map { CoachStarterSuggestion(text: $0, kind: contextual ? .state : .explore) }
            + CoachPrompts.suggestions.map { CoachStarterSuggestion(text: $0, kind: .explore) }
        return screened(items, userAge: userAge)
    }

    /// Server items first, topped up from `local`, deduplicated and screened.
    static func merge(server: [CoachStarterSuggestion], local: [CoachStarterSuggestion], userAge: Int?) -> [CoachStarterSuggestion] {
        screened(screened(server, userAge: userAge, limit: limit) + local, userAge: userAge, limit: limit)
    }

    /// Drops anything `CoachSafety` would not let through, anything empty or overlong, and duplicates; a
    /// `continue` without a thread becomes `explore`, and at most two `continue` chips stay.
    static func screened(_ items: [CoachStarterSuggestion], userAge: Int?, limit: Int = limit) -> [CoachStarterSuggestion] {
        var out: [CoachStarterSuggestion] = []
        var seen = Set<String>()
        var continues = 0
        for item in items {
            let text = CoachModelText.collapsed(item.text)
            guard !text.isEmpty, text.count <= 80, !CoachModelText.isTrainingTalk(text),
                  !CoachModelText.mentionsUncomputedScore(text),
                  CoachModelText.isSafe(text, userAge: userAge) else { continue }
            let key = CoachModelText.normalized(text)
            guard !key.isEmpty, seen.insert(key).inserted else { continue }
            var kind = item.kind
            if kind == .continue {
                if item.threadId == nil || continues >= maxContinue { kind = .explore } else { continues += 1 }
            }
            out.append(CoachStarterSuggestion(text: text, kind: kind, threadId: kind == .continue ? item.threadId : nil))
            if out.count >= limit { break }
        }
        return out
    }

    /// The local set shows first. The server set replaces it whenever it arrives while the welcome screen is up and
    /// before the user has touched anything (tapped, typed, scrolled, opened or started a chat): the model call
    /// takes seconds, so a fixed window after the screen appeared would almost never personalise the day's first
    /// welcome screen.
    static func shouldSwap(userTouched: Bool, welcomeShowing: Bool) -> Bool {
        !userTouched && welcomeShowing
    }

    /// The chips that can still be followed: a `continue` chip for a deleted chat is dropped (its text may quote
    /// it); one for a chat `known` does not hold becomes `explore` and asks in the open chat. `known` nil (no list
    /// yet) checks deletions only.
    static func live(_ items: [CoachStarterSuggestion], known: Set<String>?, deleted: Set<String>) -> [CoachStarterSuggestion] {
        items.compactMap { item in
            guard item.kind == .continue, let id = item.threadId?.lowercased() else { return item }
            if deleted.contains(id) { return nil }
            if let known, !known.contains(id) { return CoachStarterSuggestion(text: item.text, kind: .explore) }
            return item
        }
    }
}

// MARK: - Model text

/// Every model-written string the phone shows or feeds back into a prompt passes through here first: titles,
/// follow-ups, starters, memory and summary lines.
enum CoachModelText {
    /// Passes the input screen and comes out of the output screen unchanged.
    static func isSafe(_ text: String, userAge: Int?) -> Bool {
        !CoachSafety.screenInput(text, userAge: userAge).blocked && CoachSafety.screenOutput(text, userAge: userAge).clean
    }

    /// Sana is a wellbeing companion for people living with a rare disease, not a training coach: a starter about
    /// lifting, programmes, sessions or pushing harder is dropped, whoever wrote it.
    static func isTrainingTalk(_ text: String) -> Bool {
        text.range(of: #"\b(strength|lift(?:ing|s)?|gym|hypertrophy|overload|deload|reps?|sets?|one[- ]rep max|1rm|pr|personal (?:best|record)|training (?:plan|programme|program|session|load|block)|workout (?:plan|programme|program)|plan my session|push (?:harder|more|myself)|how hard (?:can|should) i push)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// Charge, effort or strain, and the recovery or readiness scores behind them: the app does not compute these,
    /// so a suggested question about them is dropped, whoever wrote it.
    static func mentionsUncomputedScore(_ text: String) -> Bool {
        text.range(of: #"\b(charge|strain|effort|readiness|recovery (?:score|trend\w*)|my recovery|training load)\b"#,
                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    static func collapsed(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Lowercased letters and digits only, for duplicate checks.
    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// A generated title as the header shows it: quotes and trailing punctuation stripped, whitespace collapsed,
    /// at most 48 characters, and nil when it is empty or unsafe.
    static func title(_ raw: String?, userAge: Int?) -> String? {
        guard let raw else { return nil }
        var t = collapsed(raw).trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`*"))
        while let last = t.last, ".,;:!?…".contains(last) { t.removeLast() }
        t = t.trimmingCharacters(in: .whitespaces)
        if t.count > 48 {
            let cut = String(t.prefix(48))
            t = cut.range(of: " ", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut
        }
        guard !t.isEmpty, isSafe(t, userAge: userAge) else { return nil }
        return t
    }

    /// Model follow-ups as the list shows them: 8–80 characters, screened, deduplicated against each other and
    /// the questions already asked, at most three.
    static func followUps(_ raw: [String], asked: [String], userAge: Int?) -> [String] {
        var seen = Set(asked.map(normalized))
        var out: [String] = []
        for item in raw {
            let text = collapsed(item)
            guard (8...80).contains(text.count), !mentionsUncomputedScore(text), isSafe(text, userAge: userAge),
                  seen.insert(normalized(text)).inserted else { continue }
            out.append(text)
            if out.count == 3 { break }
        }
        return out
    }
}

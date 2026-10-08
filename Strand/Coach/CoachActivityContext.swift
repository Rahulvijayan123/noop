import Foundation
import StrandAnalytics

/// The coach's view of the saved activity context: what the wearer was doing, and the heart rate, HRV,
/// respiration and steps measured during it, turned into text a model can quote.
///
/// This is the stored classifier output (`activityContextInterval`), read back as it was saved. Nothing is
/// derived here, so what the coach says matches what a query over the same rows would return.
enum CoachActivityContext {

    static let activityNames = ActivityClass.allCases.map(\.rawValue).joined(separator: "|")

    /// Tool-argument spellings for an activity, mapped to the canonical class.
    static func activity(named raw: String) -> ActivityClass? {
        let key = raw.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "-", with: "_")
        if let exact = ActivityClass(rawValue: key) { return exact }
        switch key {
        case "desk", "desk_sitting", "sitting_at_desk", "sitting_at_a_desk", "working": return .sittingDesk
        case "lying", "lie_down", "lying_still", "resting": return .lyingDown
        case "asleep", "sleep", "in_bed": return .sleeping
        case "still", "sitting_or_standing": return .stationary
        case "light", "light_movement", "moving_around": return .lightActivity
        case "walk": return .walking
        case "brisk", "brisk_walk", "fast_walking": return .briskWalking
        case "run", "jogging": return .running
        case "cycle", "bike", "biking", "bicycling": return .cycling
        case "vigorous", "high_intensity", "higher_intensity", "hiit", "intense": return .vigorousActivity
        case "off", "not_worn", "strap_off": return .offWrist
        default: return nil
        }
    }

    /// - Parameter days: each saved day's standing (`Repository.storedActivityContextWithStatus`). When given,
    ///   a stretch is `provisional` when it overlaps a day the ledger has not finalised, and `from an older model` when it overlaps a day that is being re-derived
    ///   (`.refreshing`); days of another rule set (`.stale`) serve no intervals and are named in one line.
    ///   nil (no ledger read) falls back to the heuristic: today's stretches ending within `provisionalTailS`
    ///   of the saved horizon.
    static func describe(intervals: [ActivityContextInterval], from: Int, to: Int,
                         activity: ActivityClass? = nil, storedThrough: Int? = nil,
                         days: [Repository.StoredActivityContextDay]? = nil,
                         timeZone: TimeZone = .current, now: Date = Date(), maxStretches: Int = 16,
                         provisionalTailS: Int = 300) -> String {
        let span = "\(stamp(from, timeZone)) to \(stamp(to, timeZone)) (\(timeZone.identifier))"
        guard !intervals.isEmpty else {
            return "No saved activity context between \(span). The classifier's output is saved after each sync, "
                + "so this means the strap was off, not yet synced, not yet processed, or the period is older than "
                + "the saved history. Do not guess what the user was doing."
        }

        let all = ActivityContextAggregator.summarize(intervals, from: from, to: to)
        let scoped = activity.map { wanted in intervals.filter { $0.activityClass == wanted } } ?? intervals

        var lines = ["Activity context, \(span)."]
        lines.append("Saved classifier output: what the wearer was doing, stored beside the heart rate, HRV, respiratory rate and steps measured at the same time. Confidence is the classifier's own 0-1 estimate, not a measured accuracy.")

        var coverage = "Classified \(duration(all.coveredSeconds)) of the \(duration(all.windowSeconds)) window (\(percent(all.coverage))); the rest has no saved context (strap off, not yet synced, or not yet processed)."
        if let through = storedThrough {
            let ago = Int(now.timeIntervalSince1970) - through
            coverage += " Saved through \(clock(through, timeZone))" + (ago > 90 ? " (\(duration(ago)) ago)." : ".")
        }
        lines.append(coverage)
        if let days {
            let stale = days.filter { $0.status == .stale && $0.dayEnd > from && $0.dayStart < to }.map(\.day)
            if !stale.isEmpty {
                lines.append("Saved context for \(Set(stale).sorted().joined(separator: ", ")) came from an older classifier with different labels and is not shown until it is processed again; treat that time as unknown, not as off-wrist.")
            }
        }
        let correctedS = intervals.filter { $0.provenance == ActivityContextProvenance.userCorrection }
            .reduce(0) { $0 + max(0, min($1.end, to) - max($1.start, from)) }
        if correctedS > 0 {
            lines.append("\(duration(correctedS)) of this window is labelled from the user's own corrections of the classifier (marked 'corrected by the user'), which take precedence over the classifier.")
        }

        if let activity, scoped.isEmpty {
            let others = all.classes.prefix(4).map { "\($0.activityClass.displayName) \(duration($0.seconds))" }
            lines.append("None of that time was classified as \(activity.displayName). It was spent as: " + others.joined(separator: ", ") + ".")
            lines.append(notes)
            return lines.joined(separator: "\n")
        }

        let summary = activity == nil ? all : ActivityContextAggregator.summarize(scoped, from: from, to: to)
        lines.append(activity.map { "Only \($0.displayName) is listed (share of all classified time):" }
            ?? "Time by activity (share of classified time):")
        for aggregate in summary.classes {
            lines.append("• " + describe(aggregate, of: all.coveredSeconds))
        }

        let stretches = self.stretches(scoped)
        let shown = stretches.suffix(maxStretches)
        let heading = stretches.count > shown.count
            ? "Stretches, oldest first (the latest \(shown.count) of \(stretches.count)):"
            : "Stretches, oldest first:"
        lines.append(heading)
        let horizon = storedThrough ?? intervals.map(\.end).max() ?? to
        let tailIsToday = sameLocalDay(horizon, Int(now.timeIntervalSince1970), timeZone)
        let standing = days.map { DayStanding($0) }
        for stretch in shown {
            let detail = ActivityContextAggregator.summarize(stretch.intervals, from: stretch.start, to: stretch.end)
                .classes.first
            var line = "  \(clock(stretch.start, timeZone))-\(clock(stretch.end, timeZone)) \(stretch.activityClass.displayName), \(duration(stretch.end - stretch.start))"
            if let hr = detail?.hrMean { line += ", heart rate \(Int(hr.rounded())) bpm" }
            if let detail, let hrv = hrvPhrase(detail) { line += ", \(hrv)" }
            line += ", confidence \(String(format: "%.2f", stretch.meanConfidence))"
            if stretch.intervals.contains(where: { $0.provenance == ActivityContextProvenance.userCorrection }) {
                line += ", corrected by the user"
            }
            if let standing {
                // The ledger's own word on each day (WP3): not final yet, or derived by an older configuration.
                if standing.isProvisional(stretch) { line += ", provisional" }
                if standing.isFromOlderModel(stretch) { line += ", from an older model" }
            } else if tailIsToday, stretch.end >= horizon - provisionalTailS {
                // No ledger read: today's newest stretch is still being decided.
                line += ", provisional"
            }
            lines.append(line)
        }
        lines.append(notes)
        return lines.joined(separator: "\n")
    }

    private static let notes = "Notes: sitting and standing cannot be told apart from a wrist, so 'Still (sitting or standing)' means the strap could not say and 'Sitting' / 'Standing' are best guesses. A stretch marked provisional comes from a day that is not final yet (today, or a night whose sleep had not settled) and can still be extended or relabelled when it is processed again; 'from an older model' means it was derived by an earlier classifier configuration and is queued to be processed again; a low confidence means the label is a weak guess. Cycling is only reported when the strap or a logged workout names it. HRV and respiratory rate are read only while the wrist is still, so a missing value means none could be read, not zero."

    /// Per-day ledger standing, looked up by a stretch's span.
    private struct DayStanding {
        let days: [Repository.StoredActivityContextDay]
        init(_ days: [Repository.StoredActivityContextDay]) { self.days = days.filter { $0.status != .stale } }

        private func overlapping(_ s: Stretch) -> [Repository.StoredActivityContextDay] {
            days.filter { $0.dayStart < s.end && $0.dayEnd > s.start }
        }

        /// Overlaps a day the ledger has not finalised.
        func isProvisional(_ s: Stretch) -> Bool {
            overlapping(s).contains(where: \.isProvisional)
        }

        func isFromOlderModel(_ s: Stretch) -> Bool {
            overlapping(s).contains { $0.status == .refreshing }
        }
    }

    private static func describe(_ a: ActivityClassAggregate, of covered: Int) -> String {
        var parts = ["\(a.activityClass.displayName), \(duration(a.seconds)) (\(percent(covered > 0 ? Double(a.seconds) / Double(covered) : 0)))"]
        parts.append("confidence \(String(format: "%.2f", a.meanConfidence))")
        if let mean = a.hrMean {
            var hr = "heart rate mean \(Int(mean.rounded())) bpm"
            if let low = a.hrMin, let high = a.hrMax { hr += " (range \(low)-\(high))" }
            parts.append(hr)
        } else {
            parts.append("no heart rate")
        }
        if let hrv = hrvPhrase(a) { parts.append(hrv) }
        if let resp = a.respRateBpm { parts.append("respiratory rate \(String(format: "%.1f", resp)) breaths/min") }
        if a.rmssd == nil && a.respRateBpm == nil { parts.append("no HRV or respiratory rate") }
        if a.stepTicks > 0 {
            var steps = "\(a.stepTicks) steps"
            if let cadence = a.cadenceSpm { steps += " at about \(Int(cadence.rounded())) steps/min" }
            parts.append(steps)
        }
        return parts.joined(separator: "; ")
    }

    // MARK: Stretches

    struct Stretch {
        let activityClass: ActivityClass
        let sleep: SleepContextState
        let wear: WearContextState
        var start: Int
        var end: Int
        var intervals: [ActivityContextInterval]

        /// Duration-weighted mean of the intervals' own classifier confidence.
        var meanConfidence: Double {
            let weight = intervals.reduce(0) { $0 + max(0, $1.end - $1.start) }
            guard weight > 0 else { return intervals.first?.confidence ?? 0 }
            return intervals.reduce(0.0) { $0 + $1.confidence * Double(max(0, $1.end - $1.start)) } / Double(weight)
        }
    }

    /// Consecutive intervals of the same class AND the same sleep and wear context, with at most a few
    /// seconds between them, as one stretch. A change of sleep state or wear is a different situation even
    /// under the same label (lying awake vs asleep, worn vs not), so it splits the stretch.
    static func stretches(_ intervals: [ActivityContextInterval], maxGapS: Int = 10) -> [Stretch] {
        var out: [Stretch] = []
        for iv in intervals.sorted(by: { $0.start < $1.start }) {
            if var last = out.last, last.activityClass == iv.activityClass, last.sleep == iv.sleep,
               last.wear == iv.wear, iv.start - last.end <= maxGapS {
                last.end = max(last.end, iv.end)
                last.intervals.append(iv)
                out[out.count - 1] = last
            } else {
                out.append(Stretch(activityClass: iv.activityClass, sleep: iv.sleep, wear: iv.wear,
                                   start: iv.start, end: iv.end, intervals: [iv]))
            }
        }
        return out
    }

    /// The per-activity RMSSD, honestly defined: the value plus how many windows it came from and the
    /// dominant recording duration, so a 60-s window is never presented as comparable to a 15-min one
    /// (spec §9.5). Intervals are cut between `minVariabilityIntervalS` (60 s) and `maxIntervalS` (900 s).
    private static func hrvPhrase(_ a: ActivityClassAggregate) -> String? {
        guard let hrv = a.rmssd else { return nil }
        var phrase = "HRV (RMSSD) \(Int(hrv.rounded())) ms from \(a.rmssdIntervals) window"
        if a.rmssdIntervals != 1 { phrase += "s" }
        if let duration = a.rmssdWindowDominantS {
            phrase += a.rmssdIntervals == 1 ? " (\(duration) s)" : " (dominant \(duration) s)"
        }
        return phrase
    }

    // MARK: Wording

    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return "\(s) s" }
        let minutes = (s + 30) / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }

    private static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }

    private static func sameLocalDay(_ a: Int, _ b: Int, _ zone: TimeZone) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar.isDate(Date(timeIntervalSince1970: TimeInterval(a)),
                               inSameDayAs: Date(timeIntervalSince1970: TimeInterval(b)))
    }

    private static func stamp(_ ts: Int, _ zone: TimeZone) -> String { format(ts, zone, "EEE MMM d HH:mm") }
    private static func clock(_ ts: Int, _ zone: TimeZone) -> String { format(ts, zone, "HH:mm") }

    private static func format(_ ts: Int, _ zone: TimeZone, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

import Foundation
import StrandAnalytics

// KeyMetricScreenModel.swift — the pure rules behind the key-metric screen's period control, its shaded range,
// its 24-hour view and its words (`KeyMetricDetailView`). Nothing here reads a store or draws.
//
// Two kinds of shaded range sit behind the readings, never mixed:
//   • the person's USUAL range (Layer 1, `LongitudinalBaseline.vitalVerdict`): the same band the Monitor list, the
//     Home ring and the server's explanations use, for each night or day it was computed on. Only the metrics the
//     app has a usual for (docs/METRIC_INSIGHTS.md) get one.
//   • the RECENT range: the middle 80% of the person's previous 30 measured nights or days, for the metrics the
//     app shows no usual for (SDNN, blood oxygen, stable awake heart rate, calories). It is never called "usual".
// Neither is a safety range, and the screen says so.
//
// The 24-hour view shows the server's 5-minute window estimates (the physiology context layer), each with the
// context it was taken in. A window without an accepted estimate is left out, never drawn as zero.

// MARK: - Periods

/// What the period control offers: the 5-minute windows of one day, or a range of measured nights or days.
enum KeyMetricPeriod: Hashable, Sendable {
    case hours24
    case range(ExploreRange)

    var range: ExploreRange? {
        if case .range(let r) = self { return r }
        return nil
    }
}

extension MetricInsightMetric {
    /// The context-layer metric whose 5-minute windows History's 24-hour view shows; nil when the screen has no
    /// such view. Resting heart rate and breathing have windows of another grain (a rolling hourly low, 2-minute
    /// windows), which only the Today chart draws.
    var windowMetric: PhysiologyContext.MetricKind? {
        switch self {
        case .hrvRmssd: return .hrvRmssd
        case .hrvSdnn: return .hrvSdnn
        case .heartRate: return .heartRate
        default: return nil
        }
    }

    /// What the Today chart draws for today: the server's windows, or the readings the phone banked from the
    /// strap; nil for the day totals (steps, calories), whose Today chart is the last seven days.
    var todaySource: KeyMetricTodaySource? {
        // SDNN has no 5-minute windows on the server (only one value per night), so the phone computes them from
        // the strap's R-R intervals, one per 5 minutes beside RMSSD's.
        if self == .hrvSdnn { return .banked(.hrvSdnn) }
        if let kind = windowMetric { return .windows(kind) }
        switch self {
        case .respRate: return .windows(.respiratoryRate)
        case .restingHeartRate: return .windows(.restingHeartRate)
        case .skinTemp: return .banked(.skinTemp)
        case .spo2: return .banked(.spo2)
        default: return nil
        }
    }

    /// The Layer 1 series that is this metric's usual (docs/METRIC_INSIGHTS.md, "the person's usual"); nil for
    /// the metrics the app shows no usual for, which compare with recent periods instead.
    var usualSeries: LBSeries? {
        switch self {
        case .restingHeartRate: return .sleepRHR
        case .hrvRmssd: return .sleepHRVLn
        case .skinTemp: return .sleepTemp
        case .respRate: return .sleepResp
        case .steps: return .wakingSteps
        case .hrvSdnn, .spo2, .heartRate, .calories: return nil
        }
    }

    /// The 24-hour view's starting context: sleep for the night metrics, stable awake for the day one.
    var defaultWindowContext: KeyMetricWindowFilter {
        period == .night ? .sleep : .stableAwake
    }
}

enum KeyMetricTodaySource: Equatable, Sendable {
    case windows(PhysiologyContext.MetricKind)
    case banked(KeyMetricBankedSignal)
}

enum KeyMetricBankedSignal: Equatable, Sendable {
    /// 5-minute means of the strap's per-second wrist temperature.
    case skinTemp
    /// Each in-band SpO₂ reading; the strap writes them only while its wearer sleeps still.
    case spo2
    /// SDNN of each 5-minute window of the strap's R-R intervals, computed on the phone.
    case hrvSdnn

    var seconds: Int { self == .spo2 ? 1 : 300 }
}

enum KeyMetricPeriods {
    /// The period chips for a metric, shortest first: the 24-hour view where there is one, then ranges a source
    /// can serve (the context history serves 120 days, so stable awake heart rate stops at 90).
    static func periods(for metric: MetricInsightMetric) -> [KeyMetricPeriod] {
        let longest: ExploreRange = (metric.historyDays ?? .max) >= 365 ? .year : .quarter
        if metric.windowMetric != nil {
            return [.hours24, .range(.week), .range(.month), .range(longest)]
        }
        return [.range(.week), .range(.month), .range(.quarter), .range(longest)].uniqued()
    }

    /// The period a screen opens on: 30 nights or days, the view that shows the shaded range best.
    static let defaultPeriod: KeyMetricPeriod = .range(.month)

    /// The chip's label: "24 hours", "7 nights", "30 days", "1 year".
    static func label(_ period: KeyMetricPeriod, _ p: MetricInsightPeriod) -> String {
        switch period {
        case .hours24: return String(localized: "24 hours")
        case .range(let r):
            switch r {
            case .year: return String(localized: "1 year")
            default:
                let n = r.days ?? 0
                return p == .night ? String(localized: "\(n) nights") : String(localized: "\(n) days")
            }
        }
    }

    /// Whether a period chip can be chosen. The 24-hour view always can (it says when it has nothing); a range
    /// follows the #943 rule the history card used (`KeyMetricHistory.isUnlocked`).
    static func isUnlocked(_ period: KeyMetricPeriod, spanDays: Int, hasHistory: Bool) -> Bool {
        switch period {
        case .hours24: return true
        case .range(let r):
            return KeyMetricHistory.isUnlocked(r, spanDays: spanDays, hasHistory: hasHistory,
                                               among: [.week, .month, .quarter, .year])
        }
    }

    /// A locked choice shows as the longest unlocked period below it, without overwriting the choice.
    static func coerced(_ period: KeyMetricPeriod, among periods: [KeyMetricPeriod],
                        isUnlocked: (KeyMetricPeriod) -> Bool) -> KeyMetricPeriod {
        guard !isUnlocked(period), let index = periods.firstIndex(of: period) else { return period }
        return periods[..<index].last(where: isUnlocked) ?? periods.first(where: isUnlocked) ?? period
    }
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

// MARK: - Shaded range

/// The range drawn behind the multi-day readings.
struct KeyMetricBand: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        /// Layer 1: the person's usual for each night or day.
        case usual
        /// The middle 80% of the previous `KeyMetricBands.recentCount` measured periods.
        case recent
    }

    /// One period's range, in stored units.
    struct Span: Equatable, Sendable {
        let day: String
        let date: Date
        let low: Double
        let high: Double
    }

    let kind: Kind
    /// Ascending. A usual band has one span per period it was computed for; a recent band one span per drawn day
    /// edge (it is the same range across the chart).
    let spans: [Span]

    /// The range on the latest span.
    var latest: Span? { spans.last }
}

/// Where a reading sits against the shaded range.
enum KeyMetricPlacement: Equatable, Sendable {
    case within, above, below
    /// A usual that is not trusted yet (Layer 1 "learning").
    case learning
    /// No range to compare with.
    case none

    static func of(_ value: Double, low: Double, high: Double) -> KeyMetricPlacement {
        value > high ? .above : value < low ? .below : .within
    }
}

enum KeyMetricBands {
    /// How many earlier measured periods the recent range is built from, and the fewest it needs.
    static let recentCount = 30
    static let recentMinimum = 7

    /// The 10th and 90th percentiles (linear interpolation), nil for fewer than `recentMinimum` values.
    static func middle80(_ values: [Double]) -> (low: Double, high: Double)? {
        let sorted = values.filter(\.isFinite).sorted()
        guard sorted.count >= recentMinimum else { return nil }
        func quantile(_ q: Double) -> Double {
            let position = q * Double(sorted.count - 1)
            let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
            let fraction = position - Double(lower)
            return sorted[lower] + (sorted[upper] - sorted[lower]) * fraction
        }
        return (quantile(0.1), quantile(0.9))
    }

    /// The recent range of a window: the middle 80% of the `recentCount` measured periods before the window's
    /// latest reading (never including it), drawn flat across the window. Nil without enough history.
    static func recent(_ readings: [KeyMetricHistory.Reading],
                       window: [KeyMetricHistory.Reading]) -> KeyMetricBand? {
        guard let last = window.last, let first = window.first else { return nil }
        let earlier = readings.filter { $0.day < last.day }.suffix(recentCount)
        guard let range = middle80(earlier.map(\.value)) else { return nil }
        let spans = [first, last].map { KeyMetricBand.Span(day: $0.day, date: $0.date, low: range.low, high: range.high) }
        return KeyMetricBand(kind: .recent, spans: first.day == last.day ? [spans[0]] : spans)
    }

    /// The usual band from each period's Layer 1 verdict, ascending; periods without a trusted usual are left out
    /// (the band has a gap there rather than a guess). Every key metric is a positive quantity, so a band whose
    /// centre minus its spread falls below zero (thin step history, say) is drawn from zero.
    static func usual(_ verdicts: [String: LBVitalVerdict]) -> KeyMetricBand? {
        let spans = verdicts.compactMap { day, v -> KeyMetricBand.Span? in
            guard v.state != .learning, let lo = v.bandLo, let hi = v.bandHi, lo.isFinite, hi.isFinite, hi >= lo,
                  hi > 0, let date = PhysiologyContextDates.date(day) else { return nil }
            return KeyMetricBand.Span(day: day, date: date, low: max(0, lo), high: hi)
        }.sorted { $0.day < $1.day }
        return spans.isEmpty ? nil : KeyMetricBand(kind: .usual, spans: spans)
    }

    /// The periods to compute a usual for: every measured one in a short window; in a long one about
    /// `maxEvaluations` evenly spread, always including the latest (each costs a Layer 1 replay).
    static let maxEvaluations = 45
    static func usualDays(_ window: [KeyMetricHistory.Reading]) -> [String] {
        guard window.count > maxEvaluations else { return window.map(\.day) }
        let stride = Int((Double(window.count) / Double(maxEvaluations)).rounded(.up))
        var days = Swift.stride(from: window.count - 1, through: 0, by: -stride).map { window[$0].day }
        days.reverse()
        return days
    }

    /// Where `value` on `day` sits: against that day's usual span when the band is a usual, else the recent range.
    static func placement(_ value: Double, day: String, band: KeyMetricBand?,
                          verdicts: [String: LBVitalVerdict]) -> KeyMetricPlacement {
        guard let band else { return .none }
        switch band.kind {
        case .usual:
            guard let v = verdicts[day] else { return .none }
            if v.state == .learning { return .learning }
            guard let lo = v.bandLo, let hi = v.bandHi else { return .none }
            return .of(value, low: lo, high: hi)
        case .recent:
            guard let span = band.latest else { return .none }
            return .of(value, low: span.low, high: span.high)
        }
    }
}

// MARK: - Summary

enum KeyMetricSummary {
    /// The median of `values` (the mean of the middle two for an even count); nil when empty.
    static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }
}

// MARK: - 24-hour view

/// What the wearer was doing during a window, from the server's wear and sleep detection and the activity
/// classifier's labels (strap motion, then the decoder's posture where the motion only says "still"). An
/// estimate, and the screen labels it so.
enum KeyMetricWindowContext: String, CaseIterable, Sendable {
    case sleep
    case lyingDown
    case sitting
    case standing
    case still
    case moving
    case offWrist
    case unclear

    var name: String {
        switch self {
        case .sleep: return String(localized: "Sleeping")
        case .lyingDown: return String(localized: "Lying down")
        case .sitting: return String(localized: "Sitting")
        case .standing: return String(localized: "Standing")
        case .still: return String(localized: "Still")
        case .moving: return String(localized: "Moving")
        case .offWrist: return String(localized: "Off wrist")
        case .unclear: return String(localized: "Unclear")
        }
    }

    /// Activity labels that mean the wrist was moving (PhysiologyContextWording.activityLabel's set).
    static let movingLabels: Set<String> = [
        "walking", "brisk_walking", "running", "stepping", "cycling", "other_movement", "light_activity",
        "vigorous_activity",
    ]
    /// Labels that say the wrist was still without saying how the body was placed.
    static let stillLabels: Set<String> = ["stationary", "still", "low_movement"]

    /// Off the wrist first (the server's wear evidence), then asleep (the sleep detector), then a partly asleep
    /// window as unclear, then the dominant activity label; a window with no single label is unclear.
    static func of(_ e: PhysiologyContext.MeasurementEnvelope) -> KeyMetricWindowContext {
        if e.sleepWear.wearState == .notWorn { return .offWrist }
        switch e.sleepWear.sleepState {
        case .asleep: return .sleep
        case .mixed: return .unclear
        case .awake, .unknown: break
        }
        var label = e.activity.dominantLabel
        if label == nil || stillLabels.contains(label!), let posture = e.decoderActivity?.dominantLabel,
           ["sitting", "sitting_desk", "standing", "lying_down"].contains(posture) {
            label = posture
        }
        guard let label else { return .unclear }
        if movingLabels.contains(label) { return .moving }
        switch label {
        case "sitting", "sitting_desk": return .sitting
        case "standing": return .standing
        case "lying_down": return .lyingDown
        case "sleeping": return e.sleepWear.sleepState == .unknown ? .sleep : .still
        default: return stillLabels.contains(label) ? .still : .unclear
        }
    }

    /// The server's own stable-awake-rest eligibility, outside sleep.
    static func isStableAwake(_ e: PhysiologyContext.MeasurementEnvelope) -> Bool {
        e.sleepWear.sleepState != .asleep && e.verdict(.stableAwakeRest)?.state == .eligible
    }
}

/// The 24-hour view's context chips.
enum KeyMetricWindowFilter: String, CaseIterable, Hashable, Sendable {
    case all, sleep, stableAwake

    var name: String {
        switch self {
        case .all: return String(localized: "All")
        case .sleep: return String(localized: "Sleep")
        case .stableAwake: return String(localized: "Stable awake")
        }
    }

    func admits(_ context: KeyMetricWindowContext, stableAwake: Bool) -> Bool {
        switch self {
        case .all: return true
        case .sleep: return context == .sleep
        case .stableAwake: return stableAwake
        }
    }

    func admits(_ r: KeyMetricWindowReading) -> Bool { admits(r.context, stableAwake: r.stableAwake) }

    func admits(_ e: PhysiologyContext.MeasurementEnvelope) -> Bool {
        admits(KeyMetricWindowContext.of(e), stableAwake: KeyMetricWindowContext.isStableAwake(e))
    }
}

/// One accepted estimate: a 5-minute (or shorter) window, a phone-banked strap reading, or a night's value
/// drawn across the sleep it covers.
struct KeyMetricWindowReading: Equatable, Identifiable, Sendable {
    let id: String
    let start: Int
    let end: Int
    let value: Double
    let context: KeyMetricWindowContext
    /// The observed share of the window's input signal, when the server reported one.
    let coverage: Double?
    var stableAwake: Bool = false

    var mid: Date { Date(timeIntervalSince1970: TimeInterval(start + end) / 2) }
    /// A value that stands for a whole session (a night), drawn as a span rather than a point.
    var isSpan: Bool { end - start > 1_800 }
}

/// A stretch of the activity lane: consecutive windows with one context.
struct KeyMetricContextSpan: Equatable, Identifiable, Sendable {
    let start: Int
    let end: Int
    let context: KeyMetricWindowContext
    var id: Int { start }
}

enum KeyMetricWindows {
    /// The 5-minute window envelopes of `metric`: window aggregates (never a nightly or session value), inside
    /// `interval`, one per window id (the first document's wins), ascending by start.
    static func envelopes(_ documents: [PhysiologyContextDocument], metric: PhysiologyContext.MetricKind,
                          in interval: PhysiologyContext.Interval) -> [PhysiologyContext.MeasurementEnvelope] {
        var seen = Set<String>()
        return documents.flatMap(\.envelopes).filter { e in
            e.metric == metric && e.method.aggregation != .day && !MeasurementContextSelection.isNightly(e)
                && interval.contains(slot(e).start) && seen.insert(e.id).inserted
        }.sorted { (slot($0).start, $0.id) < (slot($1).start, $1.id) }
    }

    /// Where a window sits on the time axis: its display bucket when the server gave one (a rolling estimate's
    /// support reaches back further than the moment it describes), else its support.
    static func slot(_ e: PhysiologyContext.MeasurementEnvelope) -> PhysiologyContext.Interval {
        e.displayBucket ?? e.support
    }

    /// The accepted estimates: a finite positive value whose signal passed the quality checks (fully, or with
    /// stated limitations). A window that failed them, or had no signal, is a gap.
    static func readings(_ envelopes: [PhysiologyContext.MeasurementEnvelope]) -> [KeyMetricWindowReading] {
        envelopes.compactMap { e in
            guard isAccepted(e), let v = e.value else { return nil }
            let at = slot(e)
            return KeyMetricWindowReading(id: e.id, start: at.start, end: at.end, value: v,
                                          context: KeyMetricActivityLanes.filled(KeyMetricWindowContext.of(e),
                                                                                 start: at.start, end: at.end),
                                          coverage: e.validity.coverage,
                                          stableAwake: KeyMetricWindowContext.isStableAwake(e))
        }
    }

    /// The accepted nightly (session) values of `metric` that overlap `interval`, each drawn across the sleep
    /// it covers: what a metric the server measures once a night shows on a day's chart.
    static func sessions(_ documents: [PhysiologyContextDocument], metric: PhysiologyContext.MetricKind,
                         overlapping interval: PhysiologyContext.Interval) -> [KeyMetricWindowReading] {
        var seen = Set<String>()
        return documents.flatMap(\.envelopes).filter { e in
            e.metric == metric && MeasurementContextSelection.isNightly(e) && isAccepted(e)
                && e.support.end > interval.start && e.support.start < interval.end && seen.insert(e.id).inserted
        }.sorted { $0.support.start < $1.support.start }.compactMap { e in
            e.value.map {
                KeyMetricWindowReading(id: e.id, start: e.support.start, end: e.support.end, value: $0,
                                       context: KeyMetricWindowContext.of(e), coverage: e.validity.coverage)
            }
        }
    }

    /// Readings the phone banked from the strap (one per point), each in the context of the lane span it falls
    /// in (unclear where the lane says nothing).
    static func banked(_ points: [(ts: Int, value: Double)], seconds: Int,
                       lane: [KeyMetricContextSpan]) -> [KeyMetricWindowReading] {
        points.map { p in
            let found = lane.first { p.ts >= $0.start && p.ts < $0.end }?.context ?? .unclear
            let context = KeyMetricActivityLanes.filled(found, start: p.ts, end: p.ts + max(1, seconds))
            return KeyMetricWindowReading(id: "\(p.ts)", start: p.ts, end: p.ts + max(1, seconds), value: p.value,
                                          context: context, coverage: nil)
        }
    }

    /// The stretches of at least `minimumUnrecorded` seconds between banked readings, up to `now`; where the
    /// lane says the strap was off the wrist for most of a stretch, that is the reason. `within` limits them to
    /// the lane spans of those contexts (blood oxygen is only measured asleep, so its daytime is not a gap).
    static func bankedGaps(_ readings: [KeyMetricWindowReading], interval: PhysiologyContext.Interval,
                           lane: [KeyMetricContextSpan], within: Set<KeyMetricWindowContext>? = nil,
                           now: Date = Date(), minimumUnrecorded: Int = 900) -> [KeyMetricGap] {
        let limit = min(interval.end, Int(now.timeIntervalSince1970))
        var holes: [(Int, Int)] = []
        var cursor = interval.start
        for r in readings where r.start < limit {
            if r.start - cursor >= minimumUnrecorded { holes.append((cursor, r.start)) }
            cursor = max(cursor, r.end)
        }
        if limit - cursor >= minimumUnrecorded { holes.append((cursor, limit)) }
        if let within {
            let allowed = lane.filter { within.contains($0.context) }
            holes = holes.flatMap { hole in
                allowed.compactMap { span -> (Int, Int)? in
                    let a = max(hole.0, span.start), b = min(hole.1, span.end)
                    return b - a >= minimumUnrecorded ? (a, b) : nil
                }
            }
        }
        return holes.map { a, b in
            let off = lane.filter { $0.context == .offWrist }
                .reduce(0) { $0 + max(0, min(b, $1.end) - max(a, $1.start)) }
            let cause: KeyMetricGap.Cause = off * 2 >= b - a ? .rejected(KeyMetricScreenCopy.gapOffWrist) : .unrecorded
            return KeyMetricGap(startS: a, endS: b, cause: cause)
        }
    }

    /// Everything a day chart draws from `source` over `interval`: the readings, the stretches without one, and
    /// the activity lane (the metric's own windows', else heart rate's, which cover the whole worn day). When
    /// the day has no reading, a metric the server measures per night shows that night across its sleep
    /// (`sessions`). `banked` is nil while the phone's strap readings are still being read.
    struct DayReadings {
        var readings: [KeyMetricWindowReading] = []
        var gaps: [KeyMetricGap] = []
        var lane: [KeyMetricContextSpan] = []
        var sessions = false
    }

    static func day(_ source: KeyMetricTodaySource, night: PhysiologyContext.MetricKind?,
                    interval: PhysiologyContext.Interval,
                    documents: (PhysiologyContext.MetricKind) -> [PhysiologyContextDocument],
                    banked: KeyMetricReadings.BankedSeries?, now: Date = Date()) -> DayReadings {
        let heartRate = envelopes(documents(.heartRate), metric: .heartRate, in: interval)
        var out = DayReadings(lane: lane(heartRate))
        if out.lane.isEmpty {
            // No server windows yet: the phone's own classification still says what the day was.
            out.lane = KeyMetricActivityLanes.all.filter { $0.end > interval.start && $0.start < interval.end }
        }
        switch source {
        case .windows(let kind):
            let own = kind == .heartRate ? heartRate : envelopes(documents(kind), metric: kind, in: interval)
            out.readings = readings(own)
            out.gaps = gaps(own, interval: interval, filter: .all, now: now)
            if !own.isEmpty { out.lane = lane(own) }
        case .banked(let signal):
            guard let banked else { return out }
            let points = banked.points.filter { $0.ts >= interval.start && $0.ts < interval.end }
            out.readings = self.banked(points.map { ($0.ts, $0.value) }, seconds: signal.seconds, lane: out.lane)
            out.gaps = bankedGaps(out.readings, interval: interval, lane: out.lane,
                                  within: signal == .spo2 ? [.sleep] : nil, now: now)
        }
        if out.readings.isEmpty, let night {
            out.readings = sessions(documents(night), metric: night, overlapping: interval)
            out.sessions = !out.readings.isEmpty
            if out.sessions { out.gaps = [] }
        }
        return out
    }

    /// Today's chart: local midnight up to now.
    static func today(_ day: String, timeZone: TimeZone, now: Date = Date()) -> PhysiologyContext.Interval? {
        guard let whole = span(day: day, period: .day, timeZone: timeZone)?.interval else { return nil }
        let end = min(whole.end, Int(now.timeIntervalSince1970))
        return PhysiologyContext.Interval(whole.start, max(whole.start + 60, end))
    }

    /// The activity lane: every window's context (accepted or not, so the lane shows where the strap knew the
    /// context even when the estimate was rejected), joined where adjacent windows share one.
    static func lane(_ envelopes: [PhysiologyContext.MeasurementEnvelope]) -> [KeyMetricContextSpan] {
        KeyMetricActivityLanes.filled(rawLane(envelopes))
    }

    private static func rawLane(_ envelopes: [PhysiologyContext.MeasurementEnvelope]) -> [KeyMetricContextSpan] {
        var spans: [KeyMetricContextSpan] = []
        for e in envelopes {
            let context = KeyMetricWindowContext.of(e)
            let at = slot(e)
            if let last = spans.last, last.context == context, at.start - last.end <= 60 {
                spans[spans.count - 1] = KeyMetricContextSpan(start: last.start, end: max(last.end, at.end),
                                                              context: context)
            } else if let last = spans.last, at.start < last.end {
                // Overlapping slots: the later window takes over from where it starts.
                spans[spans.count - 1] = KeyMetricContextSpan(start: last.start, end: at.start, context: last.context)
                if spans[spans.count - 1].end <= spans[spans.count - 1].start { spans.removeLast() }
                spans.append(KeyMetricContextSpan(start: at.start, end: at.end, context: context))
            } else {
                spans.append(KeyMetricContextSpan(start: at.start, end: at.end, context: context))
            }
        }
        return spans
    }

    /// The local days whose documents a 24-hour view reads, and its interval. A night metric shows noon to noon
    /// around the night ending on `day` (the documents of the day before and the day); a day metric shows `day`
    /// itself, midnight to midnight.
    static func span(day: String, period: MetricInsightPeriod,
                     timeZone: TimeZone) -> (days: [String], interval: PhysiologyContext.Interval)? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let utc = PhysiologyContextDates.date(day) else { return nil }
        let parts = PhysiologyContextDates.calendar.dateComponents([.year, .month, .day], from: utc)
        guard let midnight = calendar.date(from: parts) else { return nil }
        switch period {
        case .night:
            guard let previous = PhysiologyContextDates.key(day, minusDays: 1),
                  let start = calendar.date(byAdding: .hour, value: -12, to: midnight),
                  let end = calendar.date(byAdding: .hour, value: 12, to: midnight) else { return nil }
            return ([previous, day], PhysiologyContext.Interval(Int(start.timeIntervalSince1970),
                                                                Int(end.timeIntervalSince1970)))
        case .day:
            guard let end = calendar.date(byAdding: .day, value: 1, to: midnight) else { return nil }
            return ([day], PhysiologyContext.Interval(Int(midnight.timeIntervalSince1970),
                                                      Int(end.timeIntervalSince1970)))
        }
    }

    /// The x range the chart shows for `filter`: the whole interval, except sleep, which zooms to the sleep
    /// windows (half an hour of air either side) when there are any.
    static func domain(interval: PhysiologyContext.Interval, readings: [KeyMetricWindowReading],
                       filter: KeyMetricWindowFilter) -> ClosedRange<Date> {
        let whole = Date(timeIntervalSince1970: TimeInterval(interval.start))...Date(timeIntervalSince1970: TimeInterval(interval.end))
        guard filter == .sleep else { return whole }
        let sleep = readings.filter { $0.context == .sleep }
        guard let first = sleep.first, let last = sleep.last else { return whole }
        let lo = max(interval.start, first.start - 1_800), hi = min(interval.end, last.end + 1_800)
        return Date(timeIntervalSince1970: TimeInterval(lo))...Date(timeIntervalSince1970: TimeInterval(hi))
    }

    /// The person's reference for the day's stable-awake median of `metric` (the server's comparison of
    /// `<metric>.stable_awake_5min`), when one is ready. The 24-hour view draws its centre as a line beside the
    /// stable-awake windows; sleep windows have no window-level reference, so they get none.
    static func stableAwakeReference(_ documents: [PhysiologyContextDocument],
                                     metric: PhysiologyContext.MetricKind)
        -> PhysiologyContext.ReferenceComparison? {
        guard let series = PhysiologyContext.ContextReferences.stableAwakeSeriesKey(
            metric: metric, config: PhysiologyContext.ReferenceConfig()) else { return nil }
        let comparisons = documents.flatMap(\.comparisons).filter { $0.seriesKey == series }
        guard let reference = MeasurementContextSelection.headlineReference(comparisons),
              reference.status == .ready || reference.status == .provisional,
              let center = reference.center, center.isFinite, center > 0 else { return nil }
        return reference
    }

    /// Whether the window's estimate is one the chart draws (the rule `readings` applies).
    static func isAccepted(_ e: PhysiologyContext.MeasurementEnvelope) -> Bool {
        guard let v = e.value, v.isFinite, v > 0 else { return false }
        return e.validity.state == .valid || e.validity.state == .degraded
    }

    /// The stretches without a reading, up to `now`: the windows the server rejected (in a context `filter`
    /// admits) with the server's own leading reason, and stretches of at least `minimumUnrecorded` seconds with no
    /// window at all. Adjacent stretches with the same reason are joined.
    static func gaps(_ envelopes: [PhysiologyContext.MeasurementEnvelope], interval: PhysiologyContext.Interval,
                     filter: KeyMetricWindowFilter, now: Date = Date(),
                     minimumUnrecorded: Int = 900) -> [KeyMetricGap] {
        var gaps: [KeyMetricGap] = []
        func add(_ start: Int, _ end: Int, _ cause: KeyMetricGap.Cause) {
            guard end > start else { return }
            if let last = gaps.last, last.cause == cause, start - last.endS <= 60 {
                gaps[gaps.count - 1] = KeyMetricGap(startS: last.startS, endS: max(last.endS, end), cause: cause)
            } else {
                gaps.append(KeyMetricGap(startS: start, endS: end, cause: cause))
            }
        }
        let limit = min(interval.end, Int(now.timeIntervalSince1970))
        var cursor = interval.start
        for e in envelopes where slot(e).start < limit {
            let at = slot(e)
            if at.start - cursor >= minimumUnrecorded { add(cursor, at.start, .unrecorded) }
            cursor = max(cursor, at.end)
            guard !isAccepted(e), filter.admits(e) else { continue }
            add(max(at.start, gaps.last?.endS ?? at.start), min(at.end, limit), KeyMetricGap.cause(e.validity))
        }
        if !envelopes.isEmpty, limit - cursor >= minimumUnrecorded { add(cursor, limit, .unrecorded) }
        return gaps
    }

    /// Why a night has no value of `metric`, in the server's words: only when the day's document holds nightly
    /// (session) envelopes and the server rejected every one of them, from the longest. Nil otherwise, including a
    /// night the server never scored.
    static func nightlyGapReason(_ documents: [PhysiologyContextDocument],
                                 metric: PhysiologyContext.MetricKind) -> String? {
        let nights = documents.flatMap(\.envelopes).filter {
            $0.metric == metric && MeasurementContextSelection.isNightly($0)
        }
        guard !nights.contains(where: isAccepted),
              let longest = nights.max(by: { $0.support.end - $0.support.start < $1.support.end - $1.support.start }),
              longest.validity.state == .invalid || longest.validity.state == .missing else { return nil }
        return KeyMetricGap.cause(longest.validity).words(seconds: longest.support.end - longest.support.start)
    }
}

extension KeyMetricHistory {
    /// The days in `domain` without a reading, as gaps half a day either side of the day's position.
    static func missingDays(_ window: [Reading], domain: ClosedRange<Date>) -> [KeyMetricGap] {
        let measured = Set(window.map(\.day))
        var gaps: [KeyMetricGap] = []
        var date = domain.lowerBound
        while date <= domain.upperBound, gaps.count < 400 {
            let day = PhysiologyContextDates.key(date)
            if !measured.contains(day) {
                let t = Int(date.timeIntervalSince1970)
                gaps.append(KeyMetricGap(startS: t - 43_200, endS: t + 43_200, cause: .noValue, day: day))
            }
            date = date.addingTimeInterval(86_400)
        }
        return gaps
    }
}

extension MetricInsightMetric {
    /// The context-layer metric whose nightly (session) envelope can say why a night has no value; nil for the
    /// metrics without one (stable awake heart rate is built from windows, steps and calories are not measured
    /// there).
    var nightlyContextMetric: PhysiologyContext.MetricKind? {
        switch self {
        case .restingHeartRate: return .restingHeartRate
        case .hrvRmssd: return .hrvRmssd
        case .hrvSdnn: return .hrvSdnn
        case .skinTemp: return .skinTemperature
        case .respRate: return .respiratoryRate
        case .spo2: return .spo2Candidate
        case .heartRate, .steps, .calories: return nil
        }
    }
}

/// A stretch of a chart without a reading, and what the server said about it.
struct KeyMetricGap: Identifiable, Equatable, Sendable {
    enum Cause: Equatable, Sendable {
        /// The server rejected the estimate; its leading reason in plain words when it gave one.
        case rejected(String?)
        /// The server's validity check found no signal at all.
        case noSignal
        /// No window was recorded here.
        case unrecorded
        /// A night or day without a value; any reason comes from that night's own envelope.
        case noValue
    }

    let startS: Int
    let endS: Int
    let cause: Cause
    /// The night or day (`yyyy-MM-dd`) of a `noValue` gap.
    var day: String? = nil

    var id: Int { startS }

    /// The cause in words (lower case, no full stop); nil when nothing more than "no reading" is known.
    var words: String? { cause.words(seconds: endS - startS) }
    var start: Date { Date(timeIntervalSince1970: TimeInterval(startS)) }
    var end: Date { Date(timeIntervalSince1970: TimeInterval(endS)) }

    func contains(_ date: Date) -> Bool {
        let t = Int(date.timeIntervalSince1970)
        return t >= startS && t < endS
    }
}

extension KeyMetricGap.Cause {
    func words(seconds: Int) -> String? {
        switch self {
        case .rejected(let reason): return reason ?? KeyMetricScreenCopy.gapFailedChecks
        case .noSignal: return KeyMetricScreenCopy.gapNoSignal
        case .unrecorded: return KeyMetricScreenCopy.unrecordedFragment(PhysiologyContextWording.duration(seconds))
        case .noValue: return nil
        }
    }
}

extension KeyMetricGap {
    /// The cause a rejected or missing estimate's validity states.
    static func cause(_ validity: PhysiologyContext.SignalValidity) -> Cause {
        if let reason = PhysiologyContextWording.topReason(validity.reasons) { return .rejected(reason) }
        return validity.state == .missing ? .noSignal : .rejected(nil)
    }

    /// One short line under a chart: the leading reasons by time lost, then the unrecorded time. Nil when there is
    /// no gap in `domain`.
    static func note(_ gaps: [KeyMetricGap], in domain: ClosedRange<Date>) -> String? {
        let lo = Int(domain.lowerBound.timeIntervalSince1970), hi = Int(domain.upperBound.timeIntervalSince1970)
        var byReason: [String: Int] = [:]
        var order: [String] = []
        var unrecorded = 0
        for g in gaps {
            let seconds = min(g.endS, hi) - max(g.startS, lo)
            guard seconds > 0 else { continue }
            if g.cause == .unrecorded { unrecorded += seconds; continue }
            guard let reason = g.cause.words(seconds: seconds) else { continue }
            if byReason[reason] == nil { order.append(reason) }
            byReason[reason, default: 0] += seconds
        }
        // Longest first; a tie keeps the order the reasons appeared in.
        let top = order.enumerated().sorted {
            let a = byReason[$0.element, default: 0], b = byReason[$1.element, default: 0]
            return a != b ? a > b : $0.offset < $1.offset
        }.prefix(2).map(\.element)
        let reasons = top.map { "\($0) (\(PhysiologyContextWording.duration(byReason[$0, default: 0])))" }
        var parts: [String] = []
        if !reasons.isEmpty { parts.append(KeyMetricScreenCopy.gapsBecause(reasons.joined(separator: "; "))) }
        if unrecorded > 0 { parts.append(KeyMetricScreenCopy.unrecorded(PhysiologyContextWording.duration(unrecorded))) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

// MARK: - Copy

/// Every string the key-metric screen adds, in one place so the wording checks can read them all.
enum KeyMetricScreenCopy {

    static func median(count: Int, _ period: MetricInsightPeriod) -> String {
        switch period {
        case .night:
            return count == 1 ? String(localized: "1 measured night")
                : String(localized: "Median of \(count) measured nights")
        case .day:
            return count == 1 ? String(localized: "1 measured day")
                : String(localized: "Median of \(count) measured days")
        }
    }

    static func windowMedian(count: Int, filter: KeyMetricWindowFilter) -> String {
        switch filter {
        case .all: return String(localized: "Median of \(count) readings, all contexts")
        case .sleep: return String(localized: "Median of \(count) sleep readings")
        case .stableAwake: return String(localized: "Median of \(count) stable awake readings")
        }
    }

    static func usualNow(_ range: String) -> String { String(localized: "Your usual range: \(range)") }
    static func recentRange(_ range: String, _ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Your recent range: \(range) (previous 30 nights)")
        case .day: return String(localized: "Your recent range: \(range) (previous 30 days)")
        }
    }
    static func usualLearning(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Your usual range appears after a few more measured nights")
        case .day: return String(localized: "Your usual range appears after a few more measured days")
        }
    }
    static func recentLearning(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "A recent range appears after 7 measured nights")
        case .day: return String(localized: "A recent range appears after 7 measured days")
        }
    }

    static func placement(_ p: KeyMetricPlacement, kind: KeyMetricBand.Kind) -> String? {
        switch (p, kind) {
        case (.within, .usual): return String(localized: "Within your usual range")
        case (.above, .usual): return String(localized: "Above your usual range")
        case (.below, .usual): return String(localized: "Below your usual range")
        case (.within, .recent): return String(localized: "Within your recent range")
        case (.above, .recent): return String(localized: "Above your recent range")
        case (.below, .recent): return String(localized: "Below your recent range")
        case (.learning, _): return String(localized: "Usual range still being learned")
        case (.none, _): return nil
        }
    }

    static func bandLegend(_ kind: KeyMetricBand.Kind) -> String {
        switch kind {
        case .usual: return String(localized: "Your usual range")
        case .recent: return String(localized: "Your recent range")
        }
    }

    static var reading: String { String(localized: "Reading") }
    static var noReading: String { String(localized: "No reading") }
    static var gapNote: String { String(localized: "not drawn as zero") }
    static var activityLane: String { String(localized: "Activity context · estimated") }
    static var stableAwakeReference: String { String(localized: "Your usual stable awake median") }

    static func windowCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 usable reading · gaps stay visible")
            : String(localized: "\(count) usable readings · gaps stay visible")
    }

    static func measuredCount(_ count: Int, of total: Int, _ period: MetricInsightPeriod) -> String {
        String(localized: "\(KeyMetricCopy.measured(count, of: total, period)) · gaps stay visible")
    }

    static func noWindows(_ filter: KeyMetricWindowFilter) -> String {
        switch filter {
        case .all: return String(localized: "No 5-minute readings for this day yet.")
        case .sleep: return String(localized: "No sleep readings for this night yet.")
        case .stableAwake: return String(localized: "No stable awake readings for this day yet.")
        }
    }

    static func windowsSummaryEmpty(_ filter: KeyMetricWindowFilter) -> String {
        switch filter {
        case .all: return String(localized: "No 5-minute readings to summarise")
        case .sleep: return String(localized: "No sleep readings to summarise")
        case .stableAwake: return String(localized: "No stable awake readings to summarise")
        }
    }

    static var windowsNeedCloud: String {
        String(localized: "The 24-hour view needs cloud sync: its 5-minute readings are prepared on the server.")
    }
    static var windowsLoading: String { String(localized: "Reading the day's 5-minute windows…") }
    static var windowsPending: String { String(localized: "The day's 5-minute readings are still being prepared.") }

    static func usableSignal(_ share: Double) -> String {
        String(localized: "\(PhysiologyContextWording.percent(share)) usable signal")
    }

    // Disclosures and their rows.
    static var method: String { String(localized: "Data & method") }
    static var readings: String { String(localized: "Readings") }
    static var compareHeartRate: String { String(localized: "Compare heart rate") }
    static var compareRestingHeartRate: String { String(localized: "Compare resting heart rate") }
    static var heartRateMatching: String { String(localized: "Heart rate · matching windows") }
    static var restingHeartRateNights: String { String(localized: "Resting heart rate · same nights") }

    static var rowTime: String { String(localized: "Time") }
    static var rowNight: String { String(localized: "Night") }
    static var rowDay: String { String(localized: "Day") }

    static var windowsComparisonOther: String {
        String(localized: "Single windows have no usual range; compare nights in the 7- and 30-night views")
    }
    static var windowsAllNoRange: String {
        String(localized: "Contexts are shown below the chart; there is no combined range")
    }
    static var localTime: String { String(localized: "Local time") }
    static var heartRateAxis: String { String(localized: "Heart rate (bpm)") }
    static var fiveMinute: String { String(localized: "5-minute windows") }

    /// The Today chart's grain, by what it draws.
    static func todayGrain(_ source: KeyMetricTodaySource, sessions: Bool) -> String {
        if sessions { return String(localized: "Last night's value") }
        switch source {
        case .windows(.respiratoryRate): return String(localized: "2-minute windows")
        case .windows(.restingHeartRate): return String(localized: "Hourly low, every 5 minutes")
        case .windows: return fiveMinute
        case .banked(.skinTemp): return String(localized: "5-minute means from your strap")
        case .banked(.spo2): return String(localized: "Every strap reading")
        case .banked(.hrvSdnn): return String(localized: "5-minute windows from your strap's beats")
        }
    }
    static var today: String { String(localized: "Today") }
    static func todayCount(_ count: Int) -> String {
        count == 1 ? String(localized: "1 reading so far today") : String(localized: "\(count) readings so far today")
    }
    static var noReadingsToday: String { String(localized: "No readings yet today.") }
    static var spo2SleepOnly: String {
        String(localized: "Your strap measures blood oxygen only while you sleep still, so the day has no readings.")
    }
    static var gapOffWrist: String { String(localized: "the strap was off your wrist") }

    /// The reading's grain on the panel: one value per night or per day.
    static func grain(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Nightly")
        case .day: return String(localized: "Daily")
        }
    }

    /// The chart's value-axis name, before its unit.
    static func chartName(_ metric: MetricInsightMetric) -> String {
        switch metric {
        case .restingHeartRate: return String(localized: "Resting heart rate")
        case .hrvRmssd, .hrvSdnn: return String(localized: "HRV")
        case .skinTemp: return String(localized: "Wrist temperature")
        case .respRate: return String(localized: "Breathing rate")
        case .spo2: return String(localized: "Blood oxygen")
        case .heartRate: return String(localized: "Heart rate")
        case .steps: return String(localized: "Steps")
        case .calories: return String(localized: "Calories")
        }
    }

    /// How the remembered interest names the metric: HRV as a whole, whichever side was open.
    static func memoryName(_ metric: MetricInsightMetric) -> String {
        switch metric {
        case .hrvRmssd, .hrvSdnn: return String(localized: "heart rate variability (HRV)")
        default: return metric.title
        }
    }

    /// "Data & method" in two sentences: what one reading is, then what the shading and the gaps mean. HRV shows
    /// both of its measures, so it gets one text for the pair.
    static func methodSummary(_ metrics: [MetricInsightMetric]) -> String {
        if Set(metrics) == [.hrvRmssd, .hrvSdnn] {
            return String(localized: "HRV is measured from your pulse as RMSSD and SDNN, one value per night and one per 5-minute window. RMSSD is shaded with your usual range and SDNN with the middle 80% of your previous 30 measured nights (neither is a safety range); missing nights and rejected windows stay as gaps, never zero.")
        }
        guard let metric = metrics.first else { return "" }
        return "\(methodWhat(metric)) \(methodBand(metric))"
    }

    static func methodWhat(_ metric: MetricInsightMetric) -> String {
        switch metric {
        case .restingHeartRate: return String(localized: "Resting heart rate is one value per night from your strap; through the day it is the lowest 5 minutes of each rolling hour.")
        case .hrvRmssd: return String(localized: "HRV (RMSSD) is measured from your pulse, one value per night and one per 5-minute window.")
        case .hrvSdnn: return String(localized: "HRV (SDNN) is the night's 5-minute SDNN values averaged, from your pulse.")
        case .skinTemp: return String(localized: "Wrist skin temperature is one value per night during sleep, and your strap's readings through the day; it is not core temperature.")
        case .respRate: return String(localized: "Breathing rate is estimated from heartbeat timing, one value per night and one per 2-minute window.")
        case .spo2: return String(localized: "Blood oxygen is a not-yet-verified estimate your strap takes only while you sleep, one value per night.")
        case .heartRate: return String(localized: "Stable awake heart rate is the day's median of 5-minute windows taken at rest; Today shows every 5-minute window.")
        case .steps: return String(localized: "Steps are counted by your strap, one total per full day.")
        case .calories: return String(localized: "Calories are an estimate of the energy you used, one value per full day.")
        }
    }

    static func methodBand(_ metric: MetricInsightMetric) -> String {
        switch (metric.usualSeries != nil, metric.period, metric.windowMetric != nil) {
        case (true, .night, _):
            return String(localized: "The shaded band is your usual range from your own history, not a safety range; a night without a reading stays a gap, never zero.")
        case (true, .day, _):
            return String(localized: "The shaded band is your usual range from your own history, not a safety range; a day without a reading stays a gap, never zero.")
        case (false, .night, _):
            return String(localized: "The shaded band is the middle 80% of your previous 30 measured nights, not a safety range; a night without a reading stays a gap, never zero.")
        case (false, .day, true):
            return String(localized: "The shaded band is the middle 80% of your previous 30 measured days, not a safety range; a day or window without an accepted reading stays a gap, never zero.")
        case (false, .day, false):
            return String(localized: "The shaded band is the middle 80% of your previous 30 measured days, not a safety range; a day without a reading stays a gap, never zero.")
        }
    }

    // Missing data: the server's own reasons, never a guess.
    static var gapNoSignal: String { String(localized: "no signal was recorded") }
    static var gapFailedChecks: String { String(localized: "the signal did not pass the quality checks") }
    static func gapsBecause(_ reasons: String) -> String { String(localized: "Gaps: \(reasons).") }
    static func unrecorded(_ duration: String) -> String { String(localized: "Nothing was recorded for \(duration).") }
    static func unrecordedFragment(_ duration: String) -> String { String(localized: "nothing was recorded for \(duration)") }
    static func missingBecause(_ reason: String, _ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "No reading for this night: \(reason).")
        case .day: return String(localized: "No reading for this day: \(reason).")
        }
    }

    /// Every fixed string above for both periods (for the copy checks).
    static var allFixedText: [String] {
        let periods = MetricInsightPeriod.allCases
        let fixed: [String] = [
            usualNow("45–62 ms"), reading, noReading, gapNote, activityLane, stableAwakeReference,
            windowCount(1), windowCount(64), windowsNeedCloud, windowsLoading, windowsPending, usableSignal(0.8),
            method, readings, compareHeartRate, compareRestingHeartRate, heartRateMatching,
            restingHeartRateNights, rowTime, rowNight, rowDay, windowsComparisonOther,
            windowsAllNoRange, localTime, heartRateAxis, fiveMinute, today, todayCount(1), todayCount(140),
            noReadingsToday, spo2SleepOnly, gapOffWrist,
        ]
        let sources: [KeyMetricTodaySource] = [.windows(.hrvRmssd), .windows(.respiratoryRate),
                                               .windows(.restingHeartRate), .banked(.skinTemp), .banked(.spo2)]
        let grains = (sources + [.banked(.hrvSdnn)]).map { todayGrain($0, sessions: false) }
            + [todayGrain(.windows(.hrvSdnn), sessions: true)]
        let perPeriod = periods.flatMap { p in
            [median(count: 1, p), median(count: 26, p), recentRange("38–55 ms", p), usualLearning(p),
             recentLearning(p), measuredCount(5, of: 7, p)]
                + [KeyMetricPeriod.hours24, .range(.week), .range(.month), .range(.quarter), .range(.year)]
                    .map { KeyMetricPeriods.label($0, p) }
        }
        let windows = KeyMetricWindowFilter.allCases.flatMap {
            [windowMedian(count: 12, filter: $0), noWindows($0), windowsSummaryEmpty($0), $0.name]
        }
        let contexts = KeyMetricWindowContext.allCases.map(\.name)
        let placements = [KeyMetricPlacement.within, .above, .below, .learning].flatMap { p in
            [KeyMetricBand.Kind.usual, .recent].compactMap { placement(p, kind: $0) }
        }
        let names = MetricInsightMetric.allCases.flatMap { [chartName($0), memoryName($0)] }
        let methods = MetricInsightMetric.allCases.map { methodSummary([$0]) } + [methodSummary([.hrvRmssd, .hrvSdnn])]
        let gaps = [gapNoSignal, gapFailedChecks, gapsBecause("movement affected the signal (25 min)"),
                    unrecorded("2 h 10 min"), unrecordedFragment("45 min")]
            + periods.map { missingBecause("too many beats were rejected", $0) }
        return fixed + grains + perPeriod + windows + contexts + placements + names + methods + gaps
            + periods.map(grain) + [bandLegend(.usual), bandLegend(.recent)]
    }
}

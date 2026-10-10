import SwiftUI
import StrandDesign

// MARK: - Events presentation helpers
//
// The pure pieces the Events screens share: the All / Reported / Detected filter, day grouping, the
// Before / During / After phase statistics and the text formats. Nothing here reads a store or computes a
// metric; the phase means and changes are the same arithmetic the old PhysiologyCard did, moved here so
// the root card, the event page and the tests read one copy.

// MARK: Filter

/// All / Reported / Detected.
enum EventFilter: String, CaseIterable, Hashable {
    case all, reported, detected

    var title: String {
        switch self {
        case .all: return String(localized: "All")
        case .reported: return String(localized: "Reported")
        case .detected: return String(localized: "Detected")
        }
    }

    func includes(_ event: HealthEvent) -> Bool {
        switch self {
        case .all: return true
        case .reported: return event.origin == .reported
        case .detected: return event.origin == .detected
        }
    }

    /// The quiet line when nothing matches: a filter that matches nothing is not "no events yet".
    var emptyText: LocalizedStringKey {
        switch self {
        case .all: return "No events yet"
        case .reported: return "No reported events"
        case .detected: return "No detected events"
        }
    }
}

/// The timeline filter, shared by the Events root and All events so a choice made on one carries to the
/// other (each used to own its own `@State`, so "Detected" reset to "All" on "See all").
@MainActor
final class EventFilterState: ObservableObject {
    static let shared = EventFilterState()
    @Published var filter: EventFilter = .all
}

// MARK: Grouping

/// One day of the timeline, newest event first.
struct EventDay: Identifiable {
    let day: Date
    let events: [HealthEvent]
    var id: Date { day }
}

/// One month of the full list, newest day first.
struct EventMonth: Identifiable {
    let month: Date
    let days: [EventDay]
    var id: Date { month }
}

enum EventGrouping {
    /// The filtered events grouped by local day, newest day first, each day newest first; `limit` keeps the
    /// newest that many days. The same rule the timeline always used.
    static func days(_ events: [HealthEvent], filter: EventFilter, limit: Int? = nil,
                     calendar: Calendar = .current) -> [EventDay] {
        let all = Dictionary(grouping: events.filter { filter.includes($0) }) { calendar.startOfDay(for: $0.date) }
            .map { EventDay(day: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
        return limit.map { Array(all.prefix($0)) } ?? all
    }

    /// `days` grouped by calendar month, newest month first.
    static func months(_ days: [EventDay], calendar: Calendar = .current) -> [EventMonth] {
        var out: [EventMonth] = []
        for day in days {
            let month = calendar.dateInterval(of: .month, for: day.day)?.start ?? day.day
            if let last = out.last, last.month == month {
                out[out.count - 1] = EventMonth(month: month, days: last.days + [day])
            } else {
                out.append(EventMonth(month: month, days: [day]))
            }
        }
        return out
    }

    /// "Today", "Yesterday", or "Monday, Oct 5".
    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return String(localized: "Today") }
        if calendar.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    /// "October 2026".
    static func monthTitle(_ month: Date) -> String {
        month.formatted(.dateTime.month(.wide).year())
    }
}

// MARK: Phases

enum EventPhase: CaseIterable {
    case before, during, after

    var title: String {
        switch self {
        case .before: return String(localized: "Before")
        case .during: return String(localized: "During")
        case .after: return String(localized: "After")
        }
    }
}

extension EventPhysiology {
    func range(_ phase: EventPhase) -> ClosedRange<Date> {
        switch phase {
        case .before: return windowStart...eventStart
        case .during: return eventStart...eventEnd
        case .after: return eventEnd...windowEnd
        }
    }

    func phase(of time: Date) -> EventPhase {
        time < eventStart ? .before : (time <= eventEnd ? .during : .after)
    }
}

/// The phase statistics of one metric around one event: the mean of each phase and its change against the
/// "before" mean. Moved unchanged from the old PhysiologyCard (the numbers on screen are the same).
struct EventPhaseStats {
    let physiology: EventPhysiology
    let metric: PhysiologyMetric

    /// A reading within this many percent of the "before" mean counts as back at baseline.
    static let nearBaseline = 5.0

    func mean(_ phase: EventPhase) -> Double? {
        let window = physiology.range(phase)
        let supported = metric.points.compactMap { point -> (Double, Double)? in
            guard let support = point.supportSeconds else { return nil }
            let end = point.time.addingTimeInterval(support)
            let overlap = min(end, window.upperBound).timeIntervalSince(max(point.time, window.lowerBound))
            return overlap > 0 ? (point.value, overlap) : nil
        }
        if !supported.isEmpty {
            return supported.reduce(0) { $0 + $1.0 * $1.1 } / supported.reduce(0) { $0 + $1.1 }
        }
        let values = metric.points.filter { $0.supportSeconds == nil && window.contains($0.time) }.map(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Percent change of a phase against the "before" mean, or nil with no usable baseline.
    func change(_ phase: EventPhase) -> Double? {
        guard let base = mean(.before), base > 0, let value = mean(phase) else { return nil }
        return (value - base) / base * 100
    }

    /// Percent change of one reading against the "before" mean (the scrubbed readout's context line).
    func change(of value: Double) -> Double? {
        guard let base = mean(.before), base > 0 else { return nil }
        return (value - base) / base * 100
    }

    /// Whether changes read in the metric's own unit: wrist movement rests near zero, where a percentage
    /// explodes ("+1400 %"), so it shows the difference in milli-g instead.
    var changesInUnits: Bool { metric.unit.lowercased() == "mg" }

    /// The change of a phase or a reading against the "before" mean, as shown: a percentage, or a signed
    /// difference in the metric's unit for movement.
    func changeText(_ phase: EventPhase) -> String? {
        guard let value = mean(phase) else { return nil }
        return changeText(of: value)
    }

    func changeText(of value: Double) -> String? {
        if changesInUnits {
            guard let base = mean(.before) else { return nil }
            let delta = Int((value - base).rounded())
            return "\(delta > 0 ? "+" : delta < 0 ? "−" : "")\(abs(delta)) \(metric.unit)"
        }
        return change(of: value).map(EventFormat.percentChange)
    }

    /// The reading furthest in the unhealthy direction during the event (the lowest HRV, the highest heart
    /// rate), or after it for a point event with no readings inside it.
    func extreme() -> (point: PhysiologyPoint, phase: EventPhase)? {
        let higherIsBetter = metric.higherIsBetter ?? true
        for phase in [EventPhase.during, .after] {
            let window = physiology.range(phase)
            let points = metric.points.filter { window.contains($0.time) }
            let pick = higherIsBetter ? points.min { $0.value < $1.value } : points.max { $0.value < $1.value }
            if let pick { return (pick, phase) }
        }
        return nil
    }
}

// MARK: Formats

enum EventFormat {
    /// Whole numbers, as the phase readouts always showed them.
    static func value(_ v: Double) -> String { String(Int(v.rounded())) }

    /// "−53 %" / "+18 %": the signed change with a true minus sign and the unit after a space.
    static func percentChange(_ delta: Double) -> String {
        let magnitude = Int(abs(delta).rounded())
        if magnitude == 0 { return "0 %" }
        return "\(delta < 0 ? "−" : "+")\(magnitude) %"
    }

    /// "87" for a 0...1 share.
    static func share(_ fraction: Double) -> String { String(Int((fraction * 100).rounded())) }

    /// "2 h 48 m", "3 h", "45 min".
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return String(localized: "\(minutes) min") }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(m) m")
    }

    /// "1:32 PM".
    static func time(_ date: Date) -> String { date.formatted(.dateTime.hour().minute()) }

    /// "Today, 1:32 PM", "Yesterday, 8:05 AM", "Mon 5 Oct, 9:10 AM".
    static func dayAndTime(_ date: Date, calendar: Calendar = .current) -> String {
        let day: String
        if calendar.isDateInToday(date) {
            day = String(localized: "Today")
        } else if calendar.isDateInYesterday(date) {
            day = String(localized: "Yesterday")
        } else {
            day = ReadoutContent.dateLine(date, period: .day, calendar: calendar)
        }
        return "\(day), \(time(date))"
    }

    /// "10 AM – 1 PM" for a span inside one day.
    static func span(_ range: ClosedRange<Date>) -> String {
        "\(range.lowerBound.formatted(.dateTime.hour().minute())) – \(range.upperBound.formatted(.dateTime.hour().minute()))"
    }

    /// The data colour of a physiology metric: HRV in its metric colour, heart rate in its own.
    static func color(for metric: PhysiologyMetric) -> Color {
        switch metric.unit.lowercased() {
        case "ms": return StrandPalette.metricPurple
        case "bpm": return StrandPalette.metricRose
        default: return StrandPalette.metricCyan
        }
    }

    /// The value axis' minimum span (20 ms, 20 bpm), so a small wobble does not fill the card.
    static let minSpan: Double = 20
}

/// A `LocalizedStringKey` that renders `text` verbatim (a "%@" key with the text as its argument), for kit
/// components that only take a key: event titles come from the event, not the string catalog.
func verbatimKey(_ text: String) -> LocalizedStringKey { "\(text)" }

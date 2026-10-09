import SwiftUI
import StrandDesign

// MARK: - Model
//
// The Events tab renders `[HealthEvent]`. Anything that can fill that array (the backend, the local
// store, manual logging) drives the whole screen: grouping by day, the All / Reported / Detected filter,
// the timeline, the latest-reaction card, the full list, the per-event page and the recovery history.
// Events the wearer logged feed it (ManualEventPresentation, with curves from each event's server context);
// `HealthEvent.current` adds nothing in a release build.
// `HealthEvent.sample` (fabricated events, including a made-up medication) exists in DEBUG builds only and
// appears only under `--demo-seed` or `--demo-events`, labelled as sample data. Models are `Codable` so a
// backend payload can decode straight into them.

enum EventTone: String, Codable, Hashable {
    case positive, warning, detected, alert, normal

    /// The icon tint: the state colours for states, the events colour for detections, and plain secondary
    /// text for a routine reading (nothing happened, so it is not a state).
    var color: Color {
        switch self {
        case .positive: return StrandPalette.statusPositive
        case .warning: return StrandPalette.statusWarning
        case .detected: return StrandPalette.metricPurple
        case .alert: return StrandPalette.statusCritical
        case .normal: return StrandPalette.textSecondary
        }
    }
}

enum EventOrigin: String, Codable, Hashable {
    /// Entered by the wearer.
    case reported
    /// Picked up by the strap or the backend.
    case detected
}

struct PhysiologyPoint: Hashable, Codable {
    var time: Date
    var value: Double
    var supportSeconds: Double? = nil
}

struct PhysiologyMetric: Hashable, Codable {
    var name: String
    var unit: String
    /// Whether a higher reading is the healthy direction. Nil reads as true (HRV); heart rate sets false.
    var higherIsBetter: Bool?
    var points: [PhysiologyPoint]
}

/// Metric traces around one event: `windowStart…eventStart` is "before", `eventStart…eventEnd` is
/// "during" and `eventEnd…windowEnd` is "after".
struct EventPhysiology: Hashable, Codable {
    var metrics: [PhysiologyMetric]
    var windowStart: Date
    var eventStart: Date
    var eventEnd: Date
    var windowEnd: Date
}

struct EventRecovery: Hashable, Codable {
    var timeToRecover: TimeInterval?
    /// 0...1 (can exceed 1) share of baseline HRV regained.
    var hrvReturn: Double?
    var activityReturn: TimeInterval?
}

struct HealthEvent: Identifiable, Hashable, Codable {
    let id: String
    var date: Date
    var title: String
    var detail: String?
    var symbol: String
    var tone: EventTone
    var origin: EventOrigin
    var physiology: EventPhysiology?
    var recovery: EventRecovery?
    var typeId: UUID? = nil
    var ownerId: String? = nil
    var deviceId: String? = nil
    var endDate: Date? = nil

    func hasSameType(as other: HealthEvent) -> Bool {
        guard let typeId, let otherType = other.typeId else { return false }
        return typeId == otherType && ownerId == other.ownerId
    }
}

// MARK: - Sample data (DEBUG only, never shown as the wearer's own events)

#if DEBUG
extension EventPhysiology {
    /// A drop that starts at `start`, then climbs back after `end` (hours since local midnight).
    static func sample(day: Date, start: Double, end: Double) -> EventPhysiology {
        func at(_ hour: Double) -> Date { day.addingTimeInterval(hour * 3600) }
        func smooth(_ x: Double) -> Double { let t = max(0, min(1, x)); return t * t * (3 - 2 * t) }
        func trace(_ value: (Double) -> Double) -> [PhysiologyPoint] {
            stride(from: start - 3, through: end + 3, by: 0.25).map { PhysiologyPoint(time: at($0), value: value($0)) }
        }
        let hrv = trace { h in
            78 - 44 * smooth((h - start + 0.25) / 0.5) + 30 * smooth((h - end) / 1.5)
                + 4 * sin(h * 5) + 2 * sin(h * 11)
        }
        let heart = trace { h in
            62 + 30 * smooth((h - start + 0.25) / 0.5) - 20 * smooth((h - end) / 1.5)
                + 2 * sin(h * 5) + sin(h * 11)
        }
        return EventPhysiology(
            metrics: [PhysiologyMetric(name: "HRV", unit: "ms", higherIsBetter: true, points: hrv),
                      PhysiologyMetric(name: "Heart rate", unit: "bpm", higherIsBetter: false, points: heart)],
            windowStart: at(start - 3), eventStart: at(start), eventEnd: at(end), windowEnd: at(end + 3))
    }
}

extension HealthEvent {
    static var sample: [HealthEvent] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        func day(_ ago: Int) -> Date { cal.date(byAdding: .day, value: -ago, to: today) ?? today }
        func event(_ id: String, _ ago: Int, _ hour: Int, _ minute: Int, _ title: String, _ detail: String?,
                   _ symbol: String, _ tone: EventTone, _ origin: EventOrigin,
                   trace: (start: Double, end: Double)? = nil, recovery: EventRecovery? = nil) -> HealthEvent {
            let date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day(ago)) ?? day(ago)
            return HealthEvent(id: id, date: date, title: title, detail: detail, symbol: symbol, tone: tone,
                               origin: origin,
                               physiology: trace.map { EventPhysiology.sample(day: day(ago), start: $0.start, end: $0.end) },
                               recovery: recovery, typeId: sampleType(title))
        }
        /// Same-kind comparisons match on type ids: samples of one title share a stable one (FNV-1a of it).
        func sampleType(_ title: String) -> UUID {
            var a: UInt64 = 0xcbf29ce484222325, b: UInt64 = 0x84222325cbf29ce4
            for byte in title.utf8 { a = (a ^ UInt64(byte)) &* 0x100000001b3; b = (b ^ UInt64(byte)) &* 0x100000001b3 }
            let bytes = withUnsafeBytes(of: a.bigEndian, Array.init) + withUnsafeBytes(of: b.bigEndian, Array.init)
            return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                               bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        }
        func recovery(_ minutes: Double, _ hrv: Double, _ activityMinutes: Double) -> EventRecovery {
            EventRecovery(timeToRecover: minutes * 60, hrvReturn: hrv, activityReturn: activityMinutes * 60)
        }

        var events: [HealthEvent] = []
        events.append(event("ev-1", 0, 10, 14, "Medication taken", "Methotrexate 15 mg", "pills.fill", .positive, .reported))
        events.append(event("ev-2", 0, 13, 32, "Fatigue episode", "Moderate severity", "doc.text.fill", .warning, .reported,
                            trace: (13, 15), recovery: recovery(168, 0.87, 195)))
        events.append(event("ev-3", 0, 14, 5, "Tremor review", "Increased movement detected", "waveform.path.ecg", .detected, .detected))
        events.append(event("ev-4", 1, 8, 5, "Medication taken", "Methotrexate 15 mg", "pills.fill", .positive, .reported))
        events.append(event("ev-5", 1, 15, 48, "HR above usual", "91 bpm (↑ 18%)", "heart.fill", .alert, .detected,
                            trace: (15.5, 16.5), recovery: recovery(95, 0.92, 130)))
        events.append(event("ev-6", 1, 21, 12, "Respiratory rate", "14 br/min", "lungs.fill", .normal, .detected))
        events.append(event("ev-7", 2, 9, 10, "Medication taken", "Methotrexate 15 mg", "pills.fill", .positive, .reported))
        events.append(event("ev-8", 2, 17, 40, "Headache", "Mild severity", "doc.text.fill", .warning, .reported))
        events.append(event("ev-9", 3, 19, 42, "HRV below usual", "29 ms (↓ 31%)", "waveform.path.ecg", .alert, .detected,
                            trace: (19.5, 21), recovery: recovery(122, 0.9, 160)))
        events.append(event("ev-10", 4, 8, 30, "Medication taken", "Methotrexate 15 mg", "pills.fill", .positive, .reported))
        events.append(event("ev-11", 4, 14, 52, "Tremor review", "Increased movement detected", "waveform.path.ecg", .detected, .detected))
        events.append(event("ev-12", 5, 19, 3, "Fatigue episode", "Moderate severity", "doc.text.fill", .warning, .reported,
                            trace: (18.5, 20), recovery: recovery(142, 0.81, 170)))
        events.append(event("ev-13", 6, 11, 26, "HR above usual", "88 bpm (↑ 14%)", "heart.fill", .alert, .detected,
                            trace: (11, 12), recovery: recovery(74, 0.95, 105)))
        events.append(event("ev-14", 8, 9, 0, "Medication taken", "Methotrexate 15 mg", "pills.fill", .positive, .reported))
        events.append(event("ev-15", 8, 16, 45, "Respiratory rate", "15 br/min", "lungs.fill", .normal, .detected))
        events.append(event("ev-16", 10, 13, 10, "Nausea", "Mild severity", "doc.text.fill", .warning, .reported))
        events.append(event("ev-17", 11, 21, 35, "Sleep disturbance", "Woke 3 times", "moon.fill", .warning, .reported))
        return events
    }
}
#endif

extension HealthEvent {
    /// Events beyond the logged ones. A release build adds none; the fabricated samples are reachable only
    /// from a DEBUG demo launch.
    static var current: [HealthEvent] {
        #if DEBUG
        if DemoLaunch.showsSampleEvents { return sample }
        #endif
        return []
    }
}


// MARK: - Screens

/// The Events tab: the latest event the body reacted to, then the newest days of the timeline.
struct EventsView: View {
    var extraEvents: [HealthEvent] = HealthEvent.current
    @ObservedObject var manualEventCenter: ManualEventCenter = .shared
    @ObservedObject private var filterState = EventFilterState.shared

    /// The wearer's logged events with their strap context, newest first, plus any DEBUG samples.
    private var events: [HealthEvent] {
        (ManualEventPresentation.events(manualEventCenter) + extraEvents).sorted { $0.date > $1.date }
    }

    /// The most recent event that carries a physiology trace.
    private func featured(_ events: [HealthEvent]) -> HealthEvent? {
        events.filter { $0.physiology != nil }.max { $0.date < $1.date }
    }

    var body: some View {
        let events = events
        let featured = featured(events)
        ScreenScaffold(title: "Events", trailing: { HeaderSettingsButton() }) {
            ManualEventLoggingSection(center: manualEventCenter)
            if let featured, let physiology = featured.physiology, !physiology.metrics.isEmpty {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("Latest reaction")
                    NavigationLink(value: TabRoute.event(featured, history: events)) {
                        LatestReactionCard(event: featured, physiology: physiology)
                    }
                    .buttonStyle(StrandPressableButtonStyle())
                }
            }
            if events.isEmpty {
                // Nothing logged yet: say so once, with no filter to operate on an empty list.
                ComingSoon(what: "No events yet.")
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("Timeline")
                    EventFilterControl(filter: $filterState.filter)
                }
                let days = EventGrouping.days(events, filter: filterState.filter, limit: 3)
                if days.isEmpty {
                    ComingSoon(what: filterState.filter.emptyText)
                }
                ForEach(days) { day in
                    EventDaySection(day: day, history: events)
                }
            }
            #if DEBUG
            if DemoLaunch.showsSampleEvents {
                Text("Sample events for a demo build. Not your data.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            #endif
            if !events.isEmpty {
                NoopListSection {
                    NavigationLink(value: TabRoute.allEvents(events)) {
                        NoopListRow(icon: nil, title: "All events", value: "\(events.count)")
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// The newest event with physiology, named, with a compact before / during / after chart and one line:
/// the change during it and the time to recover. The whole card opens the event.
private struct LatestReactionCard: View {
    let event: HealthEvent
    let physiology: EventPhysiology

    /// The first metric, the one the event page opens on.
    private var metric: PhysiologyMetric { physiology.metrics[0] }

    private var summary: String {
        let stats = EventPhaseStats(physiology: physiology, metric: metric)
        var parts: [String] = []
        if let change = stats.change(.during) {
            parts.append(String(localized: "\(metric.name) \(EventFormat.percentChange(change)) during"))
        }
        if let time = event.recovery?.timeToRecover {
            parts.append(String(localized: "recovered in \(EventFormat.duration(time))"))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.space3) {
                    Image(systemName: event.symbol)
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(event.tone.color)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    Text(verbatim: event.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(verbatim: EventFormat.dayAndTime(event.date))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.icon(.inline))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                EventWindowChart(physiology: physiology, metric: metric, eventDate: event.date, compact: true,
                                 selection: .constant(nil))
                    .naraChartScrubDisabled()
                Text(verbatim: summary.isEmpty ? " " : summary)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// All / Reported / Detected, full width.
struct EventFilterControl: View {
    @Binding var filter: EventFilter

    var body: some View {
        SegmentedPillControl(EventFilter.allCases, selection: $filter, fillsAvailableWidth: true) { $0.title }
            .accessibilityLabel("Filter")
    }
}

/// One day of the timeline: the day as the group's label and its events as rows in one card.
struct EventDaySection: View {
    let day: EventDay
    let history: [HealthEvent]

    var body: some View {
        NoopListSection(verbatimKey(EventGrouping.dayTitle(day.day))) {
            ForEach(Array(day.events.enumerated()), id: \.element.id) { index, event in
                if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                NavigationLink(value: TabRoute.event(event, history: history)) {
                    NoopListRow(icon: event.symbol, iconColor: event.tone.color, title: verbatimKey(event.title),
                                subtitle: event.detail, value: EventFormat.time(event.date))
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// Every event, grouped by month and day, with the same filter as the tab.
struct AllEventsView: View {
    let events: [HealthEvent]
    @ObservedObject private var filterState = EventFilterState.shared

    var body: some View {
        let months = EventGrouping.months(EventGrouping.days(events, filter: filterState.filter))
        ScreenScaffold(title: "All events", titleDisplay: .navigationBar, lazy: true) {
            EventFilterControl(filter: $filterState.filter)
            if months.isEmpty {
                ComingSoon(what: filterState.filter.emptyText)
            }
            ForEach(months) { month in
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader(verbatimKey(EventGrouping.monthTitle(month.month)))
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        ForEach(month.days) { day in
                            EventDaySection(day: day, history: events)
                        }
                    }
                }
            }
        }
    }
}

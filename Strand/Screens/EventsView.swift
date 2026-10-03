import SwiftUI
import StrandDesign

// MARK: - Model
//
// The Events tab renders `[HealthEvent]`. Anything that can fill that array (the backend, the local
// store, manual logging) drives the whole screen: grouping by day, the All / Reported / Detected filter,
// the timeline, the featured physiology and recovery cards, the full list, and the per-event detail.
// `HealthEvent.sample` only fills the screen until real data is wired in. Models are `Codable` so a
// backend payload can decode straight into them.

enum EventTone: String, Codable, Hashable {
    case positive, warning, detected, alert, normal

    var color: Color {
        switch self {
        case .positive: return Color(red: 0.25, green: 0.86, blue: 0.5)
        case .warning: return Color(red: 1.0, green: 0.72, blue: 0.25)
        case .detected: return StrandPalette.metricPurple
        case .alert: return StrandPalette.metricRose
        case .normal: return Color(red: 0.25, green: 0.85, blue: 0.78)
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
}

// MARK: - Sample data (replace with the backend feed)

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
                               recovery: recovery)
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

// MARK: - Screens

struct EventsView: View {
    var events: [HealthEvent] = HealthEvent.sample

    /// The most recent event that carries a physiology trace.
    private var featured: HealthEvent? {
        events.filter { $0.physiology != nil }.max { $0.date < $1.date }
    }

    var body: some View {
        ScreenScaffold(title: "Events", subtitle: "Your health timeline",
                       trailing: { HeaderSettingsButton() }) {
            VStack(alignment: .leading, spacing: 26) {
                if let featured, let physiology = featured.physiology {
                    PhysiologyCard(physiology: physiology, eventDate: featured.date)
                    if let recovery = featured.recovery {
                        RecoveryCard(recovery: recovery, event: featured, history: events)
                    }
                }
                EventTimeline(events: events, dayLimit: 3)
            }
        }
    }
}

/// Every event, not just the latest few days.
struct AllEventsView: View {
    let events: [HealthEvent]

    var body: some View {
        ScreenScaffold(title: "All events", subtitle: "Your health timeline") {
            EventTimeline(events: events)
        }
    }
}

private enum EventFilter: CaseIterable {
    case all, reported, detected

    var title: LocalizedStringKey {
        switch self {
        case .all: return "All"
        case .reported: return "Reported"
        case .detected: return "Detected"
        }
    }

    func includes(_ event: HealthEvent) -> Bool {
        switch self {
        case .all: return true
        case .reported: return event.origin == .reported
        case .detected: return event.origin == .detected
        }
    }
}

/// The All / Reported / Detected filter and the day-grouped timeline under it. `dayLimit` trims the
/// timeline to the latest days and adds a "See all" link to the full list.
private struct EventTimeline: View {
    let events: [HealthEvent]
    var dayLimit: Int? = nil
    @State private var filter: EventFilter = .all

    private static let railWidth: CGFloat = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            filterBar
            timeline
        }
    }

    private var filterBar: some View {
        HStack(spacing: 4) {
            ForEach(EventFilter.allCases, id: \.self) { option in
                Button { withAnimation(.easeOut(duration: 0.2)) { filter = option } } label: {
                    Text(option.title)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(filter == option ? Color.white : StrandPalette.textSecondary)
                        .frame(maxWidth: .infinity, minHeight: 36)
                        .background(Capsule().fill(filter == option ? StrandPalette.metricPurple : Color.clear))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(StrandPalette.surfaceInset))
    }

    private var groups: [(day: Date, events: [HealthEvent])] {
        let cal = Calendar.current
        let all = Dictionary(grouping: events.filter { filter.includes($0) }) { cal.startOfDay(for: $0.date) }
            .map { (day: $0.key, events: $0.value.sorted { $0.date > $1.date }) }
            .sorted { $0.day > $1.day }
        return dayLimit.map { Array(all.prefix($0)) } ?? all
    }

    private func dayTitle(_ day: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(day) { return String(localized: "Today") }
        if cal.isDateInYesterday(day) { return String(localized: "Yesterday") }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 26) {
            ForEach(Array(groups.enumerated()), id: \.element.day) { index, group in
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Color.clear.frame(width: Self.railWidth, height: 1)
                        NaraSectionHeader(title: dayTitle(group.day),
                                          seeAll: index == 0 && dayLimit != nil ? TabRoute.allEvents(events) : nil)
                    }
                    ForEach(group.events) { event in
                        HStack(spacing: 12) {
                            Circle()
                                .fill(event.tone.color)
                                .frame(width: 10, height: 10)
                                .background(Circle().fill(StrandPalette.surfaceBase).frame(width: 18, height: 18))
                                .frame(width: Self.railWidth)
                            NavigationLink(value: TabRoute.event(event, history: events)) { eventCard(event) }
                                .buttonStyle(LiquidPressStyle())
                        }
                    }
                }
            }
            if groups.isEmpty {
                Text("No events yet")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            }
        }
        .background(alignment: .leading) {
            Rectangle()
                .fill(StrandPalette.hairlineStrong.opacity(0.6))
                .frame(width: 1)
                .padding(.leading, Self.railWidth / 2)
        }
    }

    private func eventCard(_ e: HealthEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: e.symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(e.tone.color)
                .frame(width: 40, height: 40)
                .background(Circle().fill(e.tone.color.opacity(0.18)))
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                if let detail = e.detail {
                    Text(detail)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            Text(e.date.formatted(.dateTime.hour().minute()))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .naraCard()
    }
}

// MARK: - Event detail

struct EventDetailView: View {
    let event: HealthEvent
    var history: [HealthEvent] = []

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(event.title),
                       subtitle: LocalizedStringKey(event.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))) {
            VStack(alignment: .leading, spacing: 24) {
                if let physiology = event.physiology {
                    PhysiologyCard(physiology: physiology, eventDate: event.date)
                }
                if let recovery = event.recovery {
                    RecoveryCard(recovery: recovery, event: event, history: history)
                }
                if event.physiology == nil && event.recovery == nil {
                    Text("No physiology recorded around this event")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }
}

private enum EventPhase {
    case before, during, after

    var color: Color {
        switch self {
        case .before: return Color(red: 0.25, green: 0.85, blue: 0.78)
        case .during: return Color(red: 1.0, green: 0.80, blue: 0.25)
        case .after: return StrandPalette.metricPurple
        }
    }

    var title: LocalizedStringKey {
        switch self {
        case .before: return "Before"
        case .during: return "During"
        case .after: return "After"
        }
    }
}

private extension EventPhysiology {
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

private struct PhysiologyCard: View {
    let physiology: EventPhysiology
    let eventDate: Date
    @State private var selected = 0

    /// A reading within this many percent of the "before" mean counts as back at baseline.
    private static let nearBaseline = 5.0

    private var metric: PhysiologyMetric {
        physiology.metrics[min(selected, max(0, physiology.metrics.count - 1))]
    }

    var body: some View {
        if physiology.metrics.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Physiology around event")
                        .font(StrandFont.rounded(17))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1).minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    metricPicker
                }
                PhysiologyChart(metric: metric, physiology: physiology, eventDate: eventDate)
                    .frame(height: 200)
                HStack(alignment: .top, spacing: 0) {
                    ForEach([EventPhase.before, .during, .after], id: \.self) { phase in
                        phaseColumn(phase)
                    }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .naraCard()
        }
    }

    @ViewBuilder
    private var metricPicker: some View {
        if physiology.metrics.count > 1 {
            Menu {
                ForEach(Array(physiology.metrics.enumerated()), id: \.offset) { index, m in
                    Button(m.name) { selected = index }
                }
            } label: { pickerLabel }
        } else {
            pickerLabel
        }
    }

    private var pickerLabel: some View {
        HStack(spacing: 5) {
            Text(metric.name).font(StrandFont.caption.weight(.semibold))
            if physiology.metrics.count > 1 {
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
            }
        }
        .foregroundStyle(StrandPalette.textPrimary)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Capsule().fill(StrandPalette.surfaceInset))
    }

    // MARK: Phase read-outs

    private func mean(_ phase: EventPhase) -> Double? {
        let window = physiology.range(phase)
        let values = metric.points.filter { window.contains($0.time) }.map(\.value)
        return values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
    }

    /// Percent change of a phase against the "before" mean, or nil with no usable baseline.
    private func change(_ phase: EventPhase) -> Double? {
        guard let base = mean(.before), base > 0, let value = mean(phase) else { return nil }
        return (value - base) / base * 100
    }

    /// Green when the move is in the healthy direction, within tolerance, or (after the event) closer
    /// to baseline than the low point was.
    private func isGood(_ phase: EventPhase, _ delta: Double) -> Bool {
        if (delta >= 0) == (metric.higherIsBetter ?? true) || abs(delta) < Self.nearBaseline { return true }
        guard phase == .after, let during = change(.during) else { return false }
        return abs(delta) < abs(during)
    }

    private func caption(_ phase: EventPhase, _ delta: Double?) -> LocalizedStringKey {
        guard let delta else { return phase == .before ? "Baseline" : "" }
        switch phase {
        case .before:
            return "Baseline"
        case .during:
            if abs(delta) < Self.nearBaseline { return "Near baseline" }
            return delta < 0 ? "Below baseline" : "Above baseline"
        case .after:
            if abs(delta) < Self.nearBaseline { return "Recovered" }
            return abs(delta) < abs(change(.during) ?? .infinity) ? "Recovering" : "Not recovered"
        }
    }

    private func pill(_ delta: Double, good: Bool) -> some View {
        let tint = good ? StrandPalette.statusPositive : StrandPalette.statusCritical
        return Text("\(delta < 0 ? "↓" : "↑") \(Int(abs(delta).rounded()))%")
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.18)))
    }

    private func phaseColumn(_ phase: EventPhase) -> some View {
        let window = physiology.range(phase)
        let value = mean(phase)
        let delta = phase == .before ? nil : change(phase)
        return VStack(alignment: .leading, spacing: 5) {
            Text(phase.title)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(phase.color)
            Text("\(window.lowerBound.formatted(.dateTime.hour().minute())) – \(window.upperBound.formatted(.dateTime.hour().minute()))")
                .font(.system(size: 10))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.6)
            (Text(value.map { String(Int($0.rounded())) } ?? "–").font(StrandFont.rounded(24)).monospacedDigit()
                + Text(" \(metric.unit)").font(StrandFont.caption))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            if let delta {
                pill(delta, good: isGood(phase, delta))
            }
            Text(caption(phase, delta))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Line chart coloured by phase, with the event window shaded and the event time marked.
private struct PhysiologyChart: View {
    let metric: PhysiologyMetric
    let physiology: EventPhysiology
    let eventDate: Date

    private static let left = 30.0, right = 8.0, top = 24.0, bottom = 22.0
    private static let steps: [Double] = [5, 10, 20, 25, 40, 50, 100, 200, 500]

    var body: some View {
        Canvas { context, size in
            let points = metric.points.sorted { $0.time < $1.time }
            let t0 = physiology.windowStart.timeIntervalSinceReferenceDate
            let span = max(1, physiology.windowEnd.timeIntervalSinceReferenceDate - t0)
            let baseY = size.height - Self.bottom
            let plotWidth = size.width - Self.left - Self.right
            func x(_ date: Date) -> CGFloat {
                Self.left + CGFloat((date.timeIntervalSinceReferenceDate - t0) / span) * plotWidth
            }

            // Four whole-number gridlines (0 plus three steps) that always cover the data.
            let maxValue = points.map(\.value).max() ?? 1
            let step = Self.steps.first { $0 >= maxValue / 3 } ?? (maxValue / 3).rounded(.up)
            let axisMax = step * 3
            func y(_ v: Double) -> CGFloat {
                baseY - CGFloat(v / axisMax) * (baseY - Self.top)
            }

            let label = StrandPalette.textTertiary
            let dotted = StrokeStyle(lineWidth: 0.6, lineCap: .round, dash: [1.5, 3.5])
            var grid = Path()
            for i in 0...3 {
                let v = step * Double(i)
                grid.move(to: CGPoint(x: Self.left, y: y(v)))
                grid.addLine(to: CGPoint(x: size.width - Self.right, y: y(v)))
                context.draw(Text("\(Int(v))").font(.system(size: 10)).foregroundColor(label),
                             at: CGPoint(x: 0, y: y(v)), anchor: .leading)
            }
            context.stroke(grid, with: .color(StrandPalette.hairline.opacity(0.7)), style: dotted)

            let during = EventPhase.during.color
            let shadeLeft = x(physiology.eventStart), shadeRight = x(physiology.eventEnd)
            context.fill(Path(CGRect(x: shadeLeft, y: Self.top, width: shadeRight - shadeLeft, height: baseY - Self.top)),
                         with: .color(during.opacity(0.12)))

            for i in 0...4 {
                let date = physiology.windowStart.addingTimeInterval(span * Double(i) / 4)
                let anchor: UnitPoint = i == 0 ? .topLeading : (i == 4 ? .topTrailing : .top)
                context.draw(Text(date.formatted(.dateTime.hour().minute())).font(.system(size: 10)).foregroundColor(label),
                             at: CGPoint(x: x(date), y: baseY + 6), anchor: anchor)
            }

            // One stroke per phase. Each run reaches one point into the next phase so the colours join.
            var start = 0
            while start < points.count {
                let phase = physiology.phase(of: points[start].time)
                var end = start
                while end + 1 < points.count, physiology.phase(of: points[end + 1].time) == phase { end += 1 }
                let upper = min(points.count - 1, end + 1)
                if upper > start {
                    let run = points[start...upper].map { CGPoint(x: x($0.time), y: y($0.value)) }
                    context.stroke(naraSmoothPath(run), with: .color(phase.color),
                                   style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
                start = end + 1
            }

            let markerX = x(eventDate)
            var marker = Path()
            marker.move(to: CGPoint(x: markerX, y: Self.top))
            marker.addLine(to: CGPoint(x: markerX, y: baseY))
            context.stroke(marker, with: .color(during), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            context.fill(Path(ellipseIn: CGRect(x: markerX - 4, y: Self.top - 4, width: 8, height: 8)),
                         with: .color(during))
            context.draw(Text("Event").font(.system(size: 10, weight: .semibold)).foregroundColor(during),
                         at: CGPoint(x: markerX, y: Self.top - 8), anchor: .bottom)
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Recovery

private struct RecoveryCard: View {
    let recovery: EventRecovery
    let event: HealthEvent
    let history: [HealthEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            NaraSectionHeader(title: String(localized: "Recovery"),
                              subtitle: String(localized: "Time to return toward baseline"),
                              seeAll: .recoveryDetails(event, history: history),
                              seeAllLabel: "See details")
            RecoveryTiles(recovery: recovery, timeNote: Self.range(from: event.date, lasting: recovery.timeToRecover))
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .naraCard()
    }

    /// "1:32 PM – 4:20 PM" for a recovery that starts at the event.
    static func range(from start: Date, lasting duration: TimeInterval?) -> String? {
        guard let duration else { return nil }
        let end = start.addingTimeInterval(duration)
        return "\(start.formatted(.dateTime.hour().minute())) – \(end.formatted(.dateTime.hour().minute()))"
    }
}

/// The three recovery tiles: time to recover, HRV return and activity return.
private struct RecoveryTiles: View {
    let recovery: EventRecovery
    var timeNote: String?

    var body: some View {
        HStack(spacing: 10) {
            tile("clock", "Time to recover", recovery.timeToRecover.map(naraDurationText), timeNote)
            tile("waveform.path.ecg", "HRV return", recovery.hrvReturn.map { "\(Int(($0 * 100).rounded()))%" },
                 String(localized: "of baseline"))
            tile("figure.run", "Activity return", recovery.activityReturn.map(naraDurationText),
                 String(localized: "after event"))
        }
    }

    private func tile(_ icon: String, _ title: LocalizedStringKey, _ value: String?, _ note: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(2).minimumScaleFactor(0.8)
                .frame(minHeight: 30, alignment: .topLeading)
            Text(value ?? "–")
                .font(StrandFont.rounded(22))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
            Text(note ?? " ")
                .font(.system(size: 10))
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1).minimumScaleFactor(0.6)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(StrandPalette.surfaceInset)
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(StrandPalette.hairline, lineWidth: 0.5))
        )
    }
}

/// Recovery for one event, the averages across every event that has one, and the per-event history.
struct RecoveryDetailsView: View {
    let event: HealthEvent
    let history: [HealthEvent]

    private var past: [HealthEvent] {
        history.filter { $0.recovery != nil }.sorted { $0.date > $1.date }
    }

    private var average: EventRecovery {
        func mean(_ values: [Double]) -> Double? {
            values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        }
        let recoveries = past.compactMap(\.recovery)
        return EventRecovery(timeToRecover: mean(recoveries.compactMap(\.timeToRecover)),
                             hrvReturn: mean(recoveries.compactMap(\.hrvReturn)),
                             activityReturn: mean(recoveries.compactMap(\.activityReturn)))
    }

    var body: some View {
        ScreenScaffold(title: "Recovery", subtitle: LocalizedStringKey(event.title)) {
            VStack(alignment: .leading, spacing: 26) {
                if let recovery = event.recovery {
                    VStack(alignment: .leading, spacing: 16) {
                        NaraSectionHeader(title: event.title,
                                          subtitle: event.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                        RecoveryTiles(recovery: recovery,
                                      timeNote: RecoveryCard.range(from: event.date, lasting: recovery.timeToRecover))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .naraCard()
                }
                if !past.isEmpty {
                    VStack(alignment: .leading, spacing: 16) {
                        NaraSectionHeader(title: String(localized: "Average"),
                                          subtitle: String(localized: "Across \(past.count) events"))
                        RecoveryTiles(recovery: average, timeNote: String(localized: "per event"))
                    }
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .naraCard()
                    VStack(alignment: .leading, spacing: 16) {
                        NaraSectionHeader(title: String(localized: "History"))
                        VStack(spacing: 0) {
                            ForEach(Array(past.enumerated()), id: \.element.id) { index, item in
                                if index > 0 { Divider().overlay(StrandPalette.hairline) }
                                NavigationLink(value: TabRoute.event(item, history: history)) { row(item) }
                                    .buttonStyle(.plain)
                            }
                        }
                        .naraCard()
                    }
                }
            }
        }
    }

    private func row(_ e: HealthEvent) -> some View {
        HStack(spacing: 12) {
            Image(systemName: e.symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(e.tone.color)
                .frame(width: 38, height: 38)
                .background(Circle().fill(e.tone.color.opacity(0.18)))
            VStack(alignment: .leading, spacing: 3) {
                Text(e.title)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Text(e.date.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                Text(e.recovery?.timeToRecover.map(naraDurationText) ?? "–")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(e.recovery?.hrvReturn.map { "HRV \(Int(($0 * 100).rounded()))%" } ?? " ")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }
}

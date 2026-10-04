import SwiftUI
import Charts
import StrandDesign
import WhoopStore
import WhoopProtocol

/// "Through the day": the server's dense intraday series for one metric.
///
/// The hosted worker recomputes HRV, resting heart rate, respiratory rate, steps and calories as the
/// phone uploads new strap data and publishes one value per bucket (a minute for respiratory rate, steps
/// and calories, five for HRV and resting heart rate); this card reads those buckets back and re-reads
/// them every half minute while it is on screen, so the line grows as the day goes on. Heart rate
/// variability and respiratory rate need a still wrist, so they leave gaps while you move, and the card
/// shows those gaps as gaps.
///
/// Line metrics (HRV, resting heart rate, respiratory rate) show the last 24 hours; additive metrics
/// (steps, calories) show a running total since local midnight, which lands on the day's number. The
/// chevrons step back through earlier days.
struct IntradaySeriesSection: View {
    let metric: IntradayMetric
    let accent: Color

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var store: IntradaySeriesStore
    @State private var dayOffset = 0
    /// Local placement intervals for the active strap (G4), loaded for the visible range.
    @State private var placementIntervals: [PlacementInterval] = []
    /// Local WRIST_ON/OFF event rows (G3) for the visible range.
    @State private var wearEvents: [(ts: Int, kind: String)] = []
    /// Persisted standard-BLE sensor-contact transitions (G3/F4) for the visible range.
    @State private var contactSamples: [(ts: Int, state: ContactEligibility)] = []

    private static let refreshSeconds: UInt64 = 30

    init(metric: IntradayMetric, accent: Color, store: IntradaySeriesStore = .shared) {
        self.metric = metric
        self.accent = accent
        _store = ObservedObject(wrappedValue: store)
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            card(now: context.date)
        }
        .task(id: dayOffset) {
            await loadEligibilityEvidence(dayOffset)
            await keepFresh(dayOffset)
        }
    }

    private func keepFresh(_ offset: Int) async {
        await store.loadCached(IntradayRange.bounds(for: metric, dayOffset: offset, now: Date()))
        while !Task.isCancelled {
            let bounds = IntradayRange.bounds(for: metric, dayOffset: offset, now: Date())
            await store.refresh(metric, bounds: bounds)
            guard bounds.isLive else { return }
            try? await Task.sleep(nanoseconds: Self.refreshSeconds * 1_000_000_000)
        }
    }

    /// Loads the local evidence the eligibility context line derives from: the active strap's
    /// placement intervals plus WRIST and contact events inside the visible range. Best-effort and
    /// non-blocking; any failure just leaves the context line absent (never a guessed state).
    private func loadEligibilityEvidence(_ offset: Int) async {
        let bounds = IntradayRange.bounds(for: metric, dayOffset: offset, now: Date())
        guard let store = await repo.storeHandle() else { return }
        let device = repo.deviceId
        if let placement = try? PlacementStore(dbQueue: store.registryWriter) {
            placementIntervals = (try? placement.intervals(deviceId: device)) ?? []
        }
        let events = (try? await store.events(deviceId: device, from: bounds.from, to: bounds.to, limit: 5000)) ?? []
        wearEvents = events
            .filter { $0.kind.hasPrefix("WRIST_ON") || $0.kind.hasPrefix("WRIST_OFF") }
            .map { ($0.ts, $0.kind) }
        let contacts = (try? await store.standardHRContacts(deviceId: device, from: bounds.from, to: bounds.to, limit: 2000)) ?? []
        contactSamples = contacts.compactMap { sample in
            ContactEligibility(raw: sample.contact.rawValue).map { (sample.ts, $0) }
        }
    }

    // MARK: Card

    private func card(now: Date) -> some View {
        let bounds = IntradayRange.bounds(for: metric, dayOffset: dayOffset, now: now)
        let window = store.windows[bounds.key]
        let failed = store.failures[bounds.key] != nil
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                header(bounds: bounds)
                readout(window: window, bounds: bounds, failed: failed, now: now)
                eligibilityLine(window: window)
                chart(window: window, bounds: bounds)
                footer(window: window, failed: failed)
            }
        }
    }

    /// A one-line per-metric context annotation (G3/G4/G7 consumer surface): placement, wear and
    /// contact eligibility for THIS metric's visible window, derived from the local evidence when
    /// the server has not published bucket flags. Shown only when there is something honest to say;
    /// never a guessed whole-window label (a mixed window says it is mixed).
    @ViewBuilder
    private func eligibilityLine(window: IntradaySeriesWindow?) -> some View {
        if let window = window {
            let width = window.bucketSeconds(for: metric)
            let context = IntradaySeriesContextBuilder.summarize(
                points: window.points(metric), width: width,
                placementIntervals: placementIntervals,
                wearEvents: wearEvents,
                contactSamples: contactSamples)
            if context.hasAny {
                Text(context.lines.joined(separator: " · "))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(Text(context.lines.joined(separator: ", ")))
            }
        }
    }

    private func header(bounds: IntradayRange.Bounds) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Through the day").strandOverline()
                Text(dayTitle(bounds))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Spacer(minLength: 0)
            HStack(spacing: 0) {
                stepButton(symbol: "chevron.left", label: "Earlier day",
                           enabled: dayOffset < IntradayRange.maxDayOffset) { dayOffset += 1 }
                stepButton(symbol: "chevron.right", label: "Later day", enabled: dayOffset > 0) { dayOffset -= 1 }
            }
        }
    }

    private func stepButton(symbol: String, label: LocalizedStringKey, enabled: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(enabled ? StrandPalette.textSecondary : StrandPalette.textTertiary.opacity(0.4))
                .frame(width: 40, height: 40)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    private func dayTitle(_ bounds: IntradayRange.Bounds) -> String {
        switch dayOffset {
        case 0: return metric.isCumulative ? String(localized: "Today") : String(localized: "Last 24 hours")
        case 1: return String(localized: "Yesterday")
        default:
            return Date(timeIntervalSince1970: TimeInterval(bounds.from))
                .formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
        }
    }

    // MARK: Read-out

    private func readout(window: IntradaySeriesWindow?, bounds: IntradayRange.Bounds,
                         failed: Bool, now: Date) -> some View {
        let reading = headline(window)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(reading ?? "—")
                    .font(StrandFont.number(40))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                if reading != nil {
                    Text(metric.unit)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Text(subtitle(window: window, bounds: bounds, failed: failed, now: now))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// The latest reading for a line metric, the running total for an additive one; nil with no points.
    private func headline(_ window: IntradaySeriesWindow?) -> String? {
        guard let window, let latest = window.latest(metric) else { return nil }
        return metric.format(metric.isCumulative ? window.total(metric) : latest.value)
    }

    private func subtitle(window: IntradaySeriesWindow?, bounds: IntradayRange.Bounds,
                          failed: Bool, now: Date) -> String {
        guard let window else {
            return failed ? String(localized: "Can't reach the server right now.") : String(localized: "Loading…")
        }
        guard let last = window.latest(metric) else {
            return String(localized: "No readings in this period yet.")
        }
        var parts: [String] = []
        if metric.isCumulative {
            let through = Date(timeIntervalSince1970: TimeInterval(last.start + window.bucketSeconds(for: metric)))
                .formatted(date: .omitted, time: .shortened)
            parts.append(bounds.isLive
                ? String(localized: "So far today, through \(through)")
                : String(localized: "Total for the day"))
        } else {
            parts.append(String(localized: "Latest at \(last.date.formatted(date: .omitted, time: .shortened))"))
        }
        if bounds.isLive, let computed = window.latestComputedAt {
            parts.append(String(localized: "updated \(IntradayFormat.age(from: computed, to: now))"))
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Chart

    private struct Run: Identifiable {
        let id: Int
        let points: [IntradaySeriesPoint]
    }

    private func chart(window: IntradaySeriesWindow?, bounds: IntradayRange.Bounds) -> some View {
        let lower = Date(timeIntervalSince1970: TimeInterval(window?.from ?? bounds.from))
        let upper = Date(timeIntervalSince1970: TimeInterval(window?.to ?? bounds.to))
        let span = lower ... upper
        let points = window?.points(metric) ?? []
        let stairs = metric.isCumulative ? (window?.staircase(metric) ?? []) : []
        let grouped: [[IntradaySeriesPoint]] = metric.isCumulative ? [] : (window?.runs(metric) ?? [])
        let runs: [Run] = grouped.enumerated().map { Run(id: $0.offset, points: $0.element) }
        let spoken = headline(window).map { "\($0) \(metric.unit)" } ?? ""
        return Chart {
            if metric.isCumulative {
                runningTotalMarks(stairs)
            } else {
                lineMarks(runs: runs, points: points)
            }
        }
        .chartXScale(domain: span)
        .chartYScale(domain: .automatic(includesZero: metric.isCumulative))
        .chartYAxis { AxisMarks(position: .leading) }
        .chartXAxis {
            AxisMarks(values: Self.axisTicks(in: span)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        .frame(height: 150)
        .overlay {
            if points.isEmpty, window != nil {
                Text("No readings yet")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(metric.unit) through the day"))
        .accessibilityValue(Text(spoken))
    }

    /// Local midnight, 6 AM, noon and 6 PM inside the span, so a rolling 24-hour window is labelled at clock
    /// times people recognise instead of every sixth hour counted from whenever the window happens to start.
    static func axisTicks(in span: ClosedRange<Date>, calendar: Calendar = .current) -> [Date] {
        var ticks: [Date] = []
        var day = calendar.startOfDay(for: span.lowerBound)
        while day <= span.upperBound {
            for hour in stride(from: 0, to: 24, by: 6) {
                if let tick = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: day),
                   tick >= span.lowerBound, tick < span.upperBound {
                    ticks.append(tick)
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return ticks
    }

    @ChartContentBuilder
    private func runningTotalMarks(_ stairs: [IntradayCumulativePoint]) -> some ChartContent {
        let unit = metric.unit
        let fill = LinearGradient(colors: [accent.opacity(0.32), accent.opacity(0.03)],
                                  startPoint: .top, endPoint: .bottom)
        ForEach(Array(stairs.enumerated()), id: \.offset) { _, step in
            AreaMark(x: .value("Time", step.date), y: .value(unit, step.total))
                .foregroundStyle(fill)
                .interpolationMethod(.linear)
            LineMark(x: .value("Time", step.date), y: .value(unit, step.total))
                .foregroundStyle(accent)
                .interpolationMethod(.linear)
        }
    }

    @ChartContentBuilder
    private func lineMarks(runs: [Run], points: [IntradaySeriesPoint]) -> some ChartContent {
        let unit = metric.unit
        let dot: CGFloat = points.count > 150 ? 8 : 16
        ForEach(runs) { run in
            ForEach(run.points, id: \.start) { point in
                LineMark(x: .value("Time", point.date), y: .value(unit, point.value),
                         series: .value("Run", run.id))
                    .foregroundStyle(accent)
                    .interpolationMethod(.monotone)
            }
        }
        ForEach(points, id: \.start) { point in
            PointMark(x: .value("Time", point.date), y: .value(unit, point.value))
                .foregroundStyle(accent)
                .symbolSize(dot)
        }
    }

    // MARK: Footer

    private func footer(window: IntradaySeriesWindow?, failed: Bool) -> some View {
        let count = window?.points(metric).count ?? 0
        return VStack(alignment: .leading, spacing: 4) {
            if count > 0 {
                Text(count == 1 ? String(localized: "1 reading") : String(localized: "\(count) readings"))
            }
            Text(note)
            if failed, window != nil {
                Text("Showing saved readings. The server can't be reached right now.")
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var note: String {
        switch metric {
        case .hrv:
            return String(localized: "Heart rate variability needs a still wrist, so readings fill in mostly while you rest and sleep.")
        case .restingHeartRate:
            return String(localized: "Your lowest calm 5-minute heart rate over the past hour.")
        case .respiratoryRate:
            return String(localized: "Breaths per minute, estimated from your heartbeat over the last 2 minutes and refreshed every minute. It needs a still wrist, so it fills in mostly while you rest.")
        case .steps:
            return String(localized: "Counted every minute and added up from midnight.")
        case .calories:
            return String(localized: "Energy burned, estimated every minute and added up from midnight.")
        }
    }
}

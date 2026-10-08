import SwiftUI
import Charts
import StrandDesign
import WhoopStore
import WhoopProtocol

/// "Today" on a metric page: the server's dense intraday series for one metric.
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
    /// The time under the finger; nil reads the newest bucket.
    @State private var selected: Date?

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
        .onChangeCompat(of: dayOffset) { _ in selected = nil }
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
        let samples = self.samples(window)
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                header(bounds: bounds, window: window, samples: samples)
                eligibilityLine(window: window)
                chart(window: window, bounds: bounds, samples: samples, failed: failed)
                if failed, window != nil {
                    Text("Showing saved readings. The server can't be reached right now.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
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

    /// The card title (the day) with the value under the finger, or the latest, on the line below, and the
    /// steps back through earlier days.
    private func header(bounds: IntradayRange.Bounds, window: IntradaySeriesWindow?,
                        samples: [IntradayChart.Sample]) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(dayTitle(bounds))
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(readoutLine(samples: samples, window: window))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .transaction { $0.animation = nil }
            }
            .accessibilityElement(children: .combine)
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
        Button {
            StrandHaptic.selection.play()
            action()
        } label: {
            Image(systemName: symbol)
                .font(StrandFont.icon(.inline).weight(.semibold))
                .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary)
                .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
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

    /// "62 ms at 09:12" for a line metric, "4,210 steps by 09:12" for a running total: the sample under
    /// the finger, else the newest.
    private func readoutLine(samples: [IntradayChart.Sample], window: IntradaySeriesWindow?) -> String {
        guard window != nil else { return " " }
        let sample = selected.flatMap { ChartSelection.sample(for: $0, in: samples) } ?? samples.last
        guard let sample else { return String(localized: "No readings yet") }
        let value = "\(metric.format(sample.value)) \(metric.unit)"
        let time = sample.time.formatted(date: .omitted, time: .shortened)
        return metric.isCumulative ? String(localized: "\(value) by \(time)") : String(localized: "\(value) at \(time)")
    }

    // MARK: Chart

    /// The buckets as chart samples: the value for a line metric, the running total (held flat across a
    /// stretch with no buckets) for an additive one.
    private func samples(_ window: IntradaySeriesWindow?) -> [IntradayChart.Sample] {
        guard let window else { return [] }
        if metric.isCumulative {
            return window.staircase(metric).map { IntradayChart.Sample(time: $0.date, value: $0.total) }
        }
        return window.points(metric).map { IntradayChart.Sample(time: $0.date, value: $0.value) }
    }

    private func chart(window: IntradaySeriesWindow?, bounds: IntradayRange.Bounds,
                       samples: [IntradayChart.Sample], failed: Bool) -> some View {
        let lower = Date(timeIntervalSince1970: TimeInterval(window?.from ?? bounds.from))
        let upper = Date(timeIntervalSince1970: TimeInterval(window?.to ?? bounds.to))
        let state: ChartState = {
            guard let window else {
                return failed ? .empty(String(localized: "Can't reach the server right now")) : .loading
            }
            return window.points(metric).isEmpty ? .empty(String(localized: "No readings yet")) : .ready
        }()
        // A line breaks where more than three buckets are missing (the same rule `IntradaySeriesWindow.runs`
        // applies); a running total is held flat across a hole, so it never breaks.
        let width = window?.bucketSeconds(for: metric) ?? IntradayRange.bucketSeconds
        let gap = metric.isCumulative ? 86_400 : max(3 * width, 300)
        return IntradayChart(samples: samples, bucketSeconds: gap, color: accent,
                             interpolation: metric.isCumulative ? .linear : .monotone,
                             live: bounds.isLive, state: state, window: lower...upper,
                             y: ChartValueAxis(unit: metric.unit, domain: axisDomain,
                                               format: metric.fractionDigits > 0 ? ChartValueAxis.decimals(1) : ChartValueAxis.integer),
                             selection: $selected, height: NoopMetrics.chartHeightSecondary,
                             accessibilityTitle: String(localized: "\(metric.unit) through the day"))
    }

    private var axisDomain: ChartDomain {
        switch metric {
        case .hrv: return .fitted(minSpan: 20)
        case .restingHeartRate: return .fitted(minSpan: 10)
        case .respiratoryRate: return .fitted(minSpan: 3)
        case .steps: return .fitted(minSpan: 500, includeZero: true)
        case .calories: return .fitted(minSpan: 100, includeZero: true)
        }
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

    /// What the series is, for the detail page's About card.
    static func note(for metric: IntradayMetric) -> String {
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

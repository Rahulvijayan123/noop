import SwiftUI
import StrandDesign
import StrandAnalytics

// KeyMetricDetailView.swift — the drill-down for a key metric (`KeyMetricCatalog`: the strap's resting heart rate,
// HRV, wrist temperature, respiratory rate, blood oxygen, stable awake heart rate, steps and calories), in the
// owner-approved concept's style (nara-hrv.html, `KeyMetricStyle`). Top to bottom:
//
//   1. the title, the RMSSD | SDNN switch on HRV, the period control (24 hours where the metric has 5-minute
//      windows, then 7 / 30 / 90 nights or days and a year) and, in the 24-hour view, the context chips,
//   2. the period's value with what it is and how it compares (the usual or recent range),
//   3. one panel: the readings as dots over the shaded range, the activity lane in the 24-hour view, a legend, and
//      the selected reading with previous / next,
//   4. how many periods were measured, an optional heart-rate comparison on HRV, and "Data & method" and
//      "Readings" disclosures,
//   5. the server's explanation (`MetricInsightCard`) with an "Ask Sana" button that opens Sana on this screen's
//      context and remembers that the person cared about this metric.
//
// The values and charts come from the phone's own data (stable awake heart rate and the 5-minute windows from the
// server's context layer, which the phone does not store), so they draw whatever the explanation service does.
// A night, day or window without a reading is a gap, never a zero.

struct KeyMetricDetailView: View {
    let metric: MetricDescriptor
    let entry: KeyMetricCatalog.Entry

    @EnvironmentObject var repo: Repository
    /// The Layer 1 usuals behind the shaded range (`BaselineStore.usualVerdicts`).
    @EnvironmentObject private var baseline: BaselineStore
    @EnvironmentObject private var coach: AICoachEngine
    @EnvironmentObject private var router: NavRouter
    @ObservedObject private var insights = MetricInsightStore.shared
    /// The context history stable awake heart rate is read from, and the day documents the 24-hour view reads. Its
    /// `epoch` moves when the account, or the device ids the server holds the strap under, change; the screen then
    /// reads again.
    @ObservedObject private var context = PhysiologyContextStore.shared

    // The reader's unit preferences, exactly as `MetricDetailView` reads them (display only).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    /// The Sana tab's switch (RootTabView); the Ask Sana button goes with it.
    @AppStorage("noop.coachEnabled") private var coachEnabled = true

    /// The switch side the reader picked; nil shows the entry's first.
    @State private var picked: MetricInsightMetric?
    @State private var period: KeyMetricPeriod = KeyMetricPeriods.defaultPeriod
    /// The 24-hour view's context chip, per side (each side opens on its own default).
    @State private var windowFilters: [MetricInsightMetric: KeyMetricWindowFilter] = [:]
    /// Every measured night or day of each side, ascending (`KeyMetricHistory.measured` of its series).
    @State private var readings: [MetricInsightMetric: [KeyMetricHistory.Reading]] = [:]
    @State private var loaded = false
    /// Each side's latest reading at the last load. When a newer one arrives the explanation is asked for again.
    @State private var loadedLatestDays: [MetricInsightMetric: String] = [:]
    @State private var insightRequest = 0
    /// Each side's Layer 1 verdicts by day, for the days the shown range needs.
    @State private var usual: [MetricInsightMetric: [String: LBVitalVerdict]] = [:]
    /// The data the cached verdicts were computed from (`repo.refreshSeq` and the history's size): new nights can
    /// move every later day's usual, so a change drops the cache.
    @State private var usualSource: [MetricInsightMetric: String] = [:]
    @State private var selection: Selection = .latest
    @State private var comparing = false
    /// Resting heart rate per night, for HRV's comparison chart.
    @State private var restingHeartRate: [KeyMetricHistory.Reading] = []
    @State private var plotInset = KeyMetricPlotInsetKey.defaultValue

    /// What the guide marks: the latest reading (on arrival), a chosen one, or a place with no reading.
    private enum Selection: Equatable {
        case latest
        case reading(String)
        case gap(Date)
    }

    /// The side on screen.
    private var side: MetricInsightMetric { picked ?? entry.metrics.first ?? .restingHeartRate }

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }

    private func formatter(_ side: MetricInsightMetric) -> KeyMetricFormatter {
        KeyMetricFormatter(metric: side, descriptor: metric, system: unitSystem, temperature: temperatureUnit)
    }

    private var windowFilter: KeyMetricWindowFilter { windowFilters[side] ?? side.defaultWindowContext }

    // MARK: Body

    var body: some View {
        let side = self.side
        let shown = readings[side] ?? []
        let periods = KeyMetricPeriods.periods(for: side)
        let span = KeyMetricHistory.spanDays(shown)
        let hasHistory = loaded && !shown.isEmpty
        let unlocked: (KeyMetricPeriod) -> Bool = {
            KeyMetricPeriods.isUnlocked($0, spanDays: span, hasHistory: hasHistory)
        }
        let effective = KeyMetricPeriods.coerced(periods.contains(period) ? period : KeyMetricPeriods.defaultPeriod,
                                                 among: periods, isUnlocked: unlocked)
        let insightState = insights.state(for: side)
        let model: Shown = effective == .hours24
            ? .windows(windowModel(side, shown: shown))
            : .range(rangeModel(side, shown: shown, period: effective))
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title)
                    .font(KeyMetricStyle.title)
                    .foregroundStyle(KeyMetricStyle.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 16)
                VStack(alignment: .leading, spacing: KeyMetricStyle.gap) {
                    if entry.metrics.count > 1 {
                        KeyMetricSegments(items: entry.metrics,
                                          selection: Binding(get: { side }, set: { picked = $0; selection = .latest }),
                                          label: { $0.switchLabel })
                    }
                    KeyMetricSegments(items: periods,
                                      selection: Binding(get: { effective }, set: { period = $0; selection = .latest }),
                                      isEnabled: unlocked,
                                      label: { KeyMetricPeriods.label($0, side.period) })
                    if effective == .hours24 {
                        KeyMetricChips(items: KeyMetricWindowFilter.allCases,
                                       selection: Binding(get: { windowFilter },
                                                          set: { windowFilters[side] = $0; selection = .latest }),
                                       label: \.name)
                    }
                }
                summary(side, model: model)
                    .padding(.top, 24)
                    .padding(.bottom, 20)
                panel(side, model: model)
                below(side, model: model)
                    .padding(.top, 10)
                if insightState?.phase != .hidden {
                    MetricInsightCard(state: insightState, latestMeasuredDay: shown.last?.day, period: side.period,
                                      onAskSana: coachEnabled ? { askSana(side, model: model) } : nil)
                        .padding(.top, 24)
                }
                // The gait model runs on the server, so the row is offered only where there is one.
                if side == .steps, let day = shown.last?.day, CloudPushSettings.isEnabled, CloudPushSettings.isConfigured {
                    walkingLink(day: day)
                        .padding(.top, 16)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
            .frame(maxWidth: 560, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        // Same horizontal-bounce guard as `MetricDetailView` (#697): this screen builds its own ScrollView.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .navigationBarTitleDisplayMode(.inline)
        // The title is the page's own heading; the bar keeps only the back button.
        .toolbar { ToolbarItem(placement: .principal) { Text(verbatim: "") } }
        #endif
        .background(KeyMetricStyle.background.ignoresSafeArea())
        .navigationTitle(entry.title)
        .onPreferenceChange(KeyMetricPlotInsetKey.self) { plotInset = $0 }
        // Read again on new data, a new account or read ids (the context epoch), and a new local day: a day metric's
        // latest full day moves at midnight.
        .task(id: "\(metric.id)|\(repo.refreshSeq)|\(context.epoch)|\(Repository.localDayKey(Date()))") {
            await load()
        }
        // The explanation is asked for on appear, for each side the switch shows, again when a newer night or day
        // lands, and again for the next account after one ends (`epoch`); leaving the screen cancels the request and
        // its polling.
        .task(id: "\(side.rawValue)|\(insightRequest)|\(insights.epoch)") { await insights.refresh(side) }
        // The usual band for the days the shown range needs.
        .task(id: usualTaskKey(side, model: model)) { await loadUsual(side, model: model) }
        // The 24-hour view's day documents (and heart rate's, while comparing).
        .task(id: windowTaskKey(side, model: model)) { await loadWindows(side, model: model) }
        .task(id: "\(side.rawValue)|\(comparing)|\(repo.refreshSeq)") { await loadComparison(side) }
    }

    // MARK: Models

    private enum Shown {
        case range(RangeModel)
        case windows(WindowModel)
    }

    /// A range of measured nights or days.
    private struct RangeModel {
        let period: KeyMetricPeriod
        let domain: ClosedRange<Date>?
        let window: [KeyMetricHistory.Reading]
        let band: KeyMetricBand?
        let verdicts: [String: LBVitalVerdict]
    }

    /// One day's 5-minute windows.
    private struct WindowModel {
        enum Status: Equatable { case needsCloud, loading, pending, ready }
        let status: Status
        /// The night (or day) the view shows.
        let day: String
        let interval: PhysiologyContext.Interval?
        let zone: TimeZone
        /// Accepted estimates in every context, and those the chip admits.
        let all: [KeyMetricWindowReading]
        let shown: [KeyMetricWindowReading]
        let lane: [KeyMetricContextSpan]
        let domain: ClosedRange<Date>
        /// The stable awake median reference, only on the stable awake chip.
        let reference: PhysiologyContext.ReferenceComparison?
        /// Heart rate by window start, while comparing.
        let heartRate: [Int: Double]
    }

    private func rangeModel(_ side: MetricInsightMetric, shown: [KeyMetricHistory.Reading],
                            period: KeyMetricPeriod) -> RangeModel {
        let range = period.range ?? .month
        let domain = KeyMetricHistory.domain(shown, range: range)
        let window = KeyMetricHistory.window(shown, domain: domain)
        let verdicts = usual[side] ?? [:]
        let band: KeyMetricBand?
        if side.usualSeries != nil {
            let inWindow = verdicts.filter { day, _ in window.contains { $0.day == day } }
            band = KeyMetricBands.usual(inWindow)
        } else {
            band = KeyMetricBands.recent(shown, window: window)
        }
        return RangeModel(period: period, domain: domain, window: window, band: band, verdicts: verdicts)
    }

    /// The day the 24-hour view shows: the latest measured night or full day, else last night or yesterday.
    private func windowDay(_ side: MetricInsightMetric, shown: [KeyMetricHistory.Reading]) -> String {
        if let last = shown.last?.day { return last }
        let today = Repository.localDayKey(Date())
        return side.period == .night ? today : (PhysiologyContextDates.key(today, minusDays: 1) ?? today)
    }

    private func windowModel(_ side: MetricInsightMetric, shown: [KeyMetricHistory.Reading]) -> WindowModel {
        let day = windowDay(side, shown: shown)
        guard let kind = side.windowMetric else {
            return emptyWindows(day: day, status: .ready)
        }
        let probeZone = TimeZone.current
        guard let probe = KeyMetricWindows.span(day: day, period: side.period, timeZone: probeZone) else {
            return emptyWindows(day: day, status: .ready)
        }
        let states = probe.days.map { context.state(for: .init(day: $0, metric: kind)) }
        let documents = states.compactMap { $0?.shownDay?.document }
        let zone = PhysiologyContextWording.zone(documents.compactMap(\.timezoneId).first)
        let interval = KeyMetricWindows.span(day: day, period: side.period, timeZone: zone)?.interval ?? probe.interval
        let status: WindowModel.Status
        if documents.isEmpty {
            if states.contains(where: { Self.needsCloud($0) }) {
                status = .needsCloud
            } else if states.contains(where: { $0 == nil || $0 == .loading }) {
                status = .loading
            } else if states.contains(where: { if case .pending = $0 { return true } else { return false } }) {
                status = .pending
            } else {
                status = .ready
            }
        } else {
            status = .ready
        }
        let envelopes = KeyMetricWindows.envelopes(documents, metric: kind, in: interval)
        let all = KeyMetricWindows.readings(envelopes)
        let filter = windowFilter
        let shownWindows = all.filter { filter.admits($0.context) }
        var heartRate: [Int: Double] = [:]
        if comparing, side.windowMetric != .heartRate {
            let hrDocs = probe.days.compactMap { context.state(for: .init(day: $0, metric: .heartRate))?.shownDay?.document }
            for r in KeyMetricWindows.readings(KeyMetricWindows.envelopes(hrDocs, metric: .heartRate, in: interval)) {
                heartRate[r.start] = r.value
            }
        }
        return WindowModel(status: status, day: day, interval: interval, zone: zone, all: all, shown: shownWindows,
                           lane: KeyMetricWindows.lane(envelopes),
                           domain: KeyMetricWindows.domain(interval: interval, readings: all, filter: filter),
                           reference: filter == .stableAwake
                               ? KeyMetricWindows.stableAwakeReference(documents, metric: kind) : nil,
                           heartRate: heartRate)
    }

    private func emptyWindows(day: String, status: WindowModel.Status) -> WindowModel {
        let now = Date()
        return WindowModel(status: status, day: day, interval: nil, zone: .current, all: [], shown: [], lane: [],
                           domain: now.addingTimeInterval(-86_400)...now, reference: nil, heartRate: [:])
    }

    private static func needsCloud(_ state: PhysiologyContextStore.State?) -> Bool {
        guard case .unavailable(let reason)? = state else { return false }
        return reason == .cloudOff || reason == .signedOut || reason == .accountNotReady
            || reason == .unsupportedServer
    }

    // MARK: Loading (usual, windows, comparison)

    private func usualTaskKey(_ side: MetricInsightMetric, model: Shown) -> String {
        guard case .range(let r) = model, side.usualSeries != nil else { return "none" }
        return "\(side.rawValue)|\(r.window.first?.day ?? "")|\(r.window.last?.day ?? "")|\(r.window.count)|\(repo.refreshSeq)|\(repo.days.count)"
    }

    /// Each needed day's Layer 1 verdict, merged into what the side already has (a longer range reuses them).
    private func loadUsual(_ side: MetricInsightMetric, model: Shown) async {
        guard case .range(let r) = model, let series = side.usualSeries else { return }
        let source = "\(repo.refreshSeq)|\(repo.days.count)|\(repo.days.last?.day ?? "")"
        let have = usualSource[side] == source ? (usual[side] ?? [:]) : [:]
        let needed = KeyMetricBands.usualDays(r.window).filter { have[$0] == nil }
        guard !needed.isEmpty else { return }
        let computed = await baseline.usualVerdicts(series: series, days: repo.days, on: needed)
        guard !Task.isCancelled else { return }
        usual[side] = have.merging(computed) { _, new in new }
        usualSource[side] = source
    }

    private func windowTaskKey(_ side: MetricInsightMetric, model: Shown) -> String {
        guard case .windows(let w) = model, let kind = side.windowMetric else { return "none" }
        return "\(kind.rawValue)|\(w.day)|\(comparing)|\(context.epoch)"
    }

    private func loadWindows(_ side: MetricInsightMetric, model: Shown) async {
        guard case .windows(let w) = model, let kind = side.windowMetric,
              let span = KeyMetricWindows.span(day: w.day, period: side.period, timeZone: w.zone) else { return }
        var kinds = [kind]
        if comparing, kind != .heartRate { kinds.append(.heartRate) }
        for k in kinds {
            for day in span.days {
                guard !Task.isCancelled else { return }
                await context.load(.init(day: day, metric: k))
            }
        }
    }

    /// HRV's comparison: resting heart rate per night, read once the reader opens it.
    private func loadComparison(_ side: MetricInsightMetric) async {
        guard comparing, side == .hrvRmssd || side == .hrvSdnn else { return }
        let series = await repo.exploreSeries(key: "rhr", source: metric.source)
        guard !Task.isCancelled else { return }
        restingHeartRate = KeyMetricHistory.measured(series)
    }

    // MARK: 2. Summary

    private struct SummaryText {
        var value: Double?
        var meaning: String?
        var rangeLine: String?
    }

    private func summaryText(_ side: MetricInsightMetric, model: Shown) -> SummaryText {
        let format = formatter(side)
        switch model {
        case .range(let r):
            let value = KeyMetricSummary.median(r.window.map(\.value))
            let meaning = r.window.isEmpty ? nil : KeyMetricScreenCopy.median(count: r.window.count, side.period)
            return SummaryText(value: value, meaning: meaning, rangeLine: rangeLine(side, band: r.band, format: format))
        case .windows(let w):
            let value = KeyMetricSummary.median(w.shown.map(\.value))
            let meaning = w.shown.isEmpty ? nil : KeyMetricScreenCopy.windowMedian(count: w.shown.count,
                                                                                 filter: windowFilter)
            let line: String?
            switch windowFilter {
            case .all: line = KeyMetricScreenCopy.windowsAllNoRange
            case .sleep: line = KeyMetricScreenCopy.windowsComparisonOther
            case .stableAwake:
                line = w.reference?.center.map {
                    "\(KeyMetricScreenCopy.stableAwakeReference): \(format.text($0))"
                } ?? KeyMetricScreenCopy.windowsComparisonOther
            }
            return SummaryText(value: value, meaning: meaning, rangeLine: line)
        }
    }

    /// "Your usual range: 45–62 ms", "Your recent range: …", or why there is none yet.
    private func rangeLine(_ side: MetricInsightMetric, band: KeyMetricBand?, format: KeyMetricFormatter) -> String? {
        if let latest = band?.latest, let band {
            let text = rangeText(latest.low, latest.high, format: format)
            return band.kind == .usual ? KeyMetricScreenCopy.usualNow(text)
                : KeyMetricScreenCopy.recentRange(text, side.period)
        }
        guard loaded, !(readings[side] ?? []).isEmpty else { return nil }
        return side.usualSeries != nil ? KeyMetricScreenCopy.usualLearning(side.period)
            : KeyMetricScreenCopy.recentLearning(side.period)
    }

    /// "45–62 ms" in the reader's units.
    private func rangeText(_ low: Double, _ high: Double, format: KeyMetricFormatter) -> String {
        let a = format.parts(low), b = format.parts(high)
        guard let unit = b.unit else { return "\(format.text(low))–\(format.text(high))" }
        return unit == "%" ? "\(a.number)–\(b.number)%" : "\(a.number)–\(b.number) \(unit)"
    }

    private func summary(_ side: MetricInsightMetric, model: Shown) -> some View {
        let text = summaryText(side, model: model)
        let format = formatter(side)
        return VStack(alignment: .leading, spacing: 4) {
            if let value = text.value {
                let parts = format.parts(value)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(parts.number)
                        .font(KeyMetricStyle.value)
                        .tracking(-1.5)
                        .foregroundStyle(KeyMetricStyle.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    if let unit = parts.unit {
                        Text(unit)
                            .font(KeyMetricStyle.valueUnit)
                            .foregroundStyle(KeyMetricStyle.secondary)
                    }
                }
            }
            Text(text.meaning ?? emptyMeaning(side, model: model))
                .font(KeyMetricStyle.label)
                .foregroundStyle(KeyMetricStyle.secondary)
            if text.value != nil, let line = text.rangeLine {
                Text(line)
                    .font(KeyMetricStyle.range)
                    .foregroundStyle(KeyMetricStyle.text)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func emptyMeaning(_ side: MetricInsightMetric, model: Shown) -> String {
        switch model {
        case .range:
            return loaded ? KeyMetricCopy.noneYet(side.period) : KeyMetricCopy.reading(side.period)
        case .windows(let w):
            // The panel says why; the summary only says there is nothing to summarise.
            return w.status == .loading ? KeyMetricScreenCopy.windowsLoading
                : KeyMetricScreenCopy.windowsSummaryEmpty(windowFilter)
        }
    }

    /// Why the 24-hour panel has no readings.
    private func windowsEmptyText(_ w: WindowModel) -> String? {
        switch w.status {
        case .needsCloud: return KeyMetricScreenCopy.windowsNeedCloud
        case .loading: return nil
        case .pending: return KeyMetricScreenCopy.windowsPending
        case .ready: return KeyMetricScreenCopy.noWindows(windowFilter)
        }
    }

    // MARK: 3. Panel

    /// The panel's left label: the dates the chart spans.
    private func dateLabel(_ side: MetricInsightMetric, model: Shown) -> String {
        switch model {
        case .range(let r):
            guard let d = r.domain else { return "" }
            let years = PhysiologyContextDates.calendar.component(.year, from: d.lowerBound)
                != PhysiologyContextDates.calendar.component(.year, from: d.upperBound)
            let template = years ? "MMMdyyyy" : "MMMd"
            return "\(KeyMetricDates.format(d.lowerBound, template: template)) – \(KeyMetricDates.format(d.upperBound, template: template))"
        case .windows(let w):
            guard let date = PhysiologyContextDates.date(w.day) else { return w.day }
            if side.period == .night, let previous = PhysiologyContextDates.key(w.day, minusDays: 1),
               let start = PhysiologyContextDates.date(previous) {
                return "\(KeyMetricDates.format(start, template: "MMMd")) – \(KeyMetricDates.format(date, template: "MMMd"))"
            }
            return KeyMetricDates.format(date, template: "EEEMMMd")
        }
    }

    /// The panel's right label: the switch side, the estimate label, and the reading's grain.
    private func typeLabel(_ side: MetricInsightMetric, model: Shown) -> String {
        var parts: [String] = []
        if entry.metrics.count > 1 { parts.append(side.switchLabel) }
        if let label = side.measurement.label { parts.append(label) }
        switch model {
        case .range: parts.append(KeyMetricScreenCopy.grain(side.period))
        case .windows: parts.append(KeyMetricScreenCopy.fiveMinute)
        }
        return parts.joined(separator: " · ")
    }

    /// "HRV (ms)", "Steps".
    private func yTitle(_ side: MetricInsightMetric) -> String {
        let name = KeyMetricScreenCopy.chartName(side)
        guard side != .steps else { return name }
        let unit = metric.displayUnit(system: unitSystem, temperature: temperatureUnit)
        return unit.isEmpty ? name : "\(name) (\(unit))"
    }

    @ViewBuilder
    private func panel(_ side: MetricInsightMetric, model: Shown) -> some View {
        KeyMetricPanel {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(dateLabel(side, model: model))
                    Spacer(minLength: 8)
                    Text(typeLabel(side, model: model))
                        .multilineTextAlignment(.trailing)
                }
                .font(KeyMetricStyle.label)
                .foregroundStyle(KeyMetricStyle.secondary)
                .padding(.horizontal, 2)
                switch model {
                case .range(let r): rangeChart(side, r)
                case .windows(let w): windowChart(side, w)
                }
                if hasReadings(model) {
                    legend(model: model)
                    selectionRow(side, model: model)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func hasReadings(_ model: Shown) -> Bool {
        switch model {
        case .range(let r): return !r.window.isEmpty
        case .windows(let w): return !w.shown.isEmpty
        }
    }

    // MARK: Range chart

    private func rangeChart(_ side: MetricInsightMetric, _ r: RangeModel) -> some View {
        let format = formatter(side)
        let plotDomain = Self.airy(r.domain)
        let ticks = r.domain.map {
            ChartAxisDays.spanning([$0.lowerBound, $0.upperBound], targetLabels: 4, calendar: PhysiologyContextDates.calendar)
        } ?? []
        let needsYear = ChartAxisDays.needsYear(ticks, calendar: PhysiologyContextDates.calendar)
        let dots = r.window.map { KeyMetricDot(id: $0.day, x: $0.date, y: format.plotted($0.value)) }
        let band = (r.band?.spans ?? []).map {
            KeyMetricBandPoint(x: $0.date, low: format.plotted($0.low), high: format.plotted($0.high))
        }
        let guide = rangeGuide(r)
        return Group {
            if r.window.isEmpty {
                emptyPlot(loaded ? KeyMetricCopy.nothingToChart(side.period) : nil)
            } else {
                KeyMetricDotChart(dots: dots, domain: plotDomain, band: band, yTitle: yTitle(side),
                                  xTitle: KeyMetricCopy.axis(side.period), xTicks: ticks,
                                  xLabel: { KeyMetricDates.format($0, template: needsYear ? "MMMdyy" : "MMMd") },
                                  dotSize: r.window.count > 120 ? 14 : r.window.count > 45 ? 22 : 40,
                                  minimumPad: side.minimumPad, floorsAtZero: true, height: 210,
                                  guideX: guide.x, selectedID: guide.id,
                                  onSelect: { selectReading(at: $0, in: r.window) })
            }
        }
    }

    /// Half a day of air either side so the first and last dots are not clipped by the plot edge.
    private static func airy(_ domain: ClosedRange<Date>?) -> ClosedRange<Date> {
        guard let domain else { let now = Date(); return now.addingTimeInterval(-6 * 86_400)...now }
        return domain.lowerBound.addingTimeInterval(-43_200)...domain.upperBound.addingTimeInterval(43_200)
    }

    private func selectedReading(_ r: RangeModel) -> KeyMetricHistory.Reading? {
        switch selection {
        case .latest: return r.window.last
        case .reading(let day): return r.window.first { $0.day == day } ?? r.window.last
        case .gap: return nil
        }
    }

    private func rangeGuide(_ r: RangeModel) -> (x: Date?, id: String?) {
        if case .gap(let x) = selection { return (x, nil) }
        let reading = selectedReading(r)
        return (reading?.date, reading?.day)
    }

    /// The nearest reading within half a day of the touch; otherwise the touched day, as a gap.
    private func selectReading(at date: Date, in window: [KeyMetricHistory.Reading]) {
        guard let nearest = window.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
        else { return }
        if abs(nearest.date.timeIntervalSince(date)) <= 43_200 {
            if selection != .reading(nearest.day) { StrandHaptic.selection.play() }
            selection = .reading(nearest.day)
        } else {
            let day = PhysiologyContextDates.calendar.startOfDay(for: date.addingTimeInterval(43_200))
            selection = .gap(day)
        }
    }

    // MARK: Window chart

    @ViewBuilder
    private func windowChart(_ side: MetricInsightMetric, _ w: WindowModel) -> some View {
        let format = formatter(side)
        let ticks = Self.hourTicks(w.domain, zone: w.zone)
        let dots = w.shown.map { KeyMetricDot(id: $0.id, x: $0.mid, y: format.plotted($0.value)) }
        let guide = windowGuide(w)
        if w.shown.isEmpty {
            emptyPlot(windowsEmptyText(w))
        } else {
            KeyMetricDotChart(dots: dots, domain: w.domain,
                              referenceLine: w.reference?.center.map(format.plotted),
                              yTitle: yTitle(side), xTitle: KeyMetricScreenCopy.localTime, xTicks: ticks,
                              xLabel: { Self.hourLabel($0, zone: w.zone) },
                              dotSize: 16, minimumPad: side.minimumPad, height: 210,
                              guideX: guide.x, selectedID: guide.id,
                              onSelect: { selectWindow(at: $0, in: w.shown) })
        }
        if !w.lane.isEmpty {
            KeyMetricActivityLane(spans: w.lane, domain: w.domain, inset: plotInset, guideX: guide.x)
                .padding(.top, 4)
        }
    }

    private func selectedWindow(_ w: WindowModel) -> KeyMetricWindowReading? {
        switch selection {
        case .latest: return w.shown.last
        case .reading(let id): return w.shown.first { $0.id == id } ?? w.shown.last
        case .gap: return nil
        }
    }

    private func windowGuide(_ w: WindowModel) -> (x: Date?, id: String?) {
        if case .gap(let x) = selection { return (x, nil) }
        let reading = selectedWindow(w)
        return (reading?.mid, reading?.id)
    }

    /// The window under the touch (within 7½ minutes of its middle); otherwise that moment, as a gap.
    private func selectWindow(at date: Date, in windows: [KeyMetricWindowReading]) {
        let nearest = windows.min { abs($0.mid.timeIntervalSince(date)) < abs($1.mid.timeIntervalSince(date)) }
        if let nearest, abs(nearest.mid.timeIntervalSince(date)) <= 450 {
            if selection != .reading(nearest.id) { StrandHaptic.selection.play() }
            selection = .reading(nearest.id)
        } else {
            selection = .gap(date)
        }
    }

    /// Whole hours in `zone`, every 6 hours across a day, every 2 or 3 across a night's sleep.
    static func hourTicks(_ domain: ClosedRange<Date>, zone: TimeZone) -> [Date] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let hours = domain.upperBound.timeIntervalSince(domain.lowerBound) / 3_600
        let step = hours > 14 ? 6 : hours > 7 ? 3 : 2
        guard var t = calendar.dateInterval(of: .hour, for: domain.lowerBound)?.start else { return [] }
        if t < domain.lowerBound { t = t.addingTimeInterval(3_600) }
        while calendar.component(.hour, from: t) % step != 0 { t = t.addingTimeInterval(3_600) }
        var ticks: [Date] = []
        while t <= domain.upperBound, ticks.count < 8 {
            ticks.append(t)
            t = t.addingTimeInterval(TimeInterval(step) * 3_600)
        }
        return ticks
    }

    static func hourLabel(_ date: Date, zone: TimeZone, locale: Locale = AppLanguage.activeLocale) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = zone
        f.setLocalizedDateFormatFromTemplate("j")
        return f.string(from: date)
    }

    private func emptyPlot(_ text: String?) -> some View {
        Group {
            if let text {
                Text(text)
                    .font(KeyMetricStyle.range)
                    .foregroundStyle(KeyMetricStyle.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .padding(.horizontal, 12)
    }

    // MARK: Legend and selection

    private func legend(model: Shown) -> some View {
        let band: KeyMetricBand.Kind?
        var reference = false
        switch model {
        case .range(let r): band = r.band?.kind
        case .windows(let w): band = nil; reference = w.reference != nil && !w.shown.isEmpty
        }
        return FlowLayout(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(KeyMetricStyle.accent).frame(width: 7, height: 7)
                Text(KeyMetricScreenCopy.reading)
            }
            if let band {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(KeyMetricStyle.band)
                        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(KeyMetricStyle.border, lineWidth: 1))
                        .frame(width: 15, height: 9)
                    Text(KeyMetricScreenCopy.bandLegend(band))
                }
            }
            if reference {
                HStack(spacing: 6) {
                    Rectangle()
                        .fill(KeyMetricStyle.teal)
                        .frame(width: 15, height: 1.5)
                    Text(KeyMetricScreenCopy.stableAwakeReference)
                }
            }
        }
        .font(KeyMetricStyle.small)
        .foregroundStyle(KeyMetricStyle.secondary)
        .padding(.horizontal, 2)
        .padding(.top, 2)
        .accessibilityElement(children: .combine)
    }

    /// The selected reading's two lines, or why there is none at the guide.
    private func selectionText(_ side: MetricInsightMetric, model: Shown) -> (value: String, meta: String)? {
        let format = formatter(side)
        switch model {
        case .range(let r):
            if case .gap(let x) = selection {
                return ("\(KeyMetricScreenCopy.noReading) · \(KeyMetricDates.short(x, includeYear: false))",
                        KeyMetricScreenCopy.gapNote)
            }
            guard let reading = selectedReading(r) else { return nil }
            let placement = KeyMetricBands.placement(reading.value, day: reading.day, band: r.band, verdicts: r.verdicts)
            let meta = r.band.flatMap { KeyMetricScreenCopy.placement(placement, kind: $0.kind) }
                ?? KeyMetricCopy.latest(side.period)
            return ("\(format.text(reading.value)) · \(KeyMetricDates.short(reading.date, includeYear: false))", meta)
        case .windows(let w):
            if case .gap(let x) = selection {
                return ("\(KeyMetricScreenCopy.noReading) · \(Self.timeText(x, zone: w.zone))",
                        KeyMetricScreenCopy.gapNote)
            }
            guard let reading = selectedWindow(w) else { return nil }
            let time = PhysiologyContextWording.timeRange(.init(reading.start, reading.end), zone: w.zone,
                                                          locale: AppLanguage.activeLocale)
            var meta = [reading.context.name]
            if let coverage = reading.coverage { meta.append(KeyMetricScreenCopy.usableSignal(coverage)) }
            return ("\(format.text(reading.value)) · \(time)", meta.joined(separator: " · "))
        }
    }

    static func timeText(_ date: Date, zone: TimeZone) -> String {
        PhysiologyContextWording.time(Int(date.timeIntervalSince1970), zone: zone, locale: AppLanguage.activeLocale)
    }

    private func selectionRow(_ side: MetricInsightMetric, model: Shown) -> some View {
        let text = selectionText(side, model: model)
        return VStack(spacing: 0) {
            Rectangle().fill(KeyMetricStyle.border).frame(height: 1)
            HStack(spacing: 3) {
                stepButton(-1, model: model)
                VStack(spacing: 3) {
                    Text(text?.value ?? " ")
                        .font(KeyMetricStyle.selectedValue)
                        .foregroundStyle(KeyMetricStyle.text)
                    Text(text?.meta ?? " ")
                        .font(KeyMetricStyle.small)
                        .foregroundStyle(KeyMetricStyle.secondary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                stepButton(1, model: model)
            }
            .padding(.top, 8)
        }
        .padding(.top, 4)
    }

    private func stepButton(_ step: Int, model: Shown) -> some View {
        Button { move(step, model: model) } label: {
            Image(systemName: step < 0 ? "chevron.left" : "chevron.right")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(KeyMetricStyle.secondary)
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(step < 0 ? "Previous reading" : "Next reading"))
    }

    /// Steps through the readings shown, from the selected one (or from where a gap was touched).
    private func move(_ step: Int, model: Shown) {
        let ids: [String]
        let xs: [Date]
        let current: String?
        switch model {
        case .range(let r):
            ids = r.window.map(\.day); xs = r.window.map(\.date); current = selectedReading(r)?.day
        case .windows(let w):
            ids = w.shown.map(\.id); xs = w.shown.map(\.mid); current = selectedWindow(w)?.id
        }
        guard !ids.isEmpty else { return }
        let index: Int
        if case .gap(let x) = selection {
            let after = xs.firstIndex { $0 > x } ?? xs.count
            index = step > 0 ? min(after, ids.count - 1) : max(after - 1, 0)
        } else {
            let at = current.flatMap { ids.firstIndex(of: $0) } ?? ids.count - 1
            index = min(max(at + step, 0), ids.count - 1)
        }
        selection = .reading(ids[index])
    }

    // MARK: 4. Below the panel

    @ViewBuilder
    private func below(_ side: MetricInsightMetric, model: Shown) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let count = countLine(side, model: model) {
                Text(count)
                    .font(KeyMetricStyle.small)
                    .foregroundStyle(KeyMetricStyle.secondary)
                    .padding(.bottom, 4)
            }
            if side == .hrvRmssd || side == .hrvSdnn { comparison(side, model: model) }
            KeyMetricDisclosure(title: KeyMetricScreenCopy.method) {
                KeyMetricFacts(rows: methodRows(side, model: model))
            }
            KeyMetricDisclosure(title: KeyMetricScreenCopy.readings) {
                readingsTable(side, model: model)
            }
        }
    }

    private func countLine(_ side: MetricInsightMetric, model: Shown) -> String? {
        switch model {
        case .range(let r):
            guard let d = r.domain, !r.window.isEmpty else { return nil }
            return KeyMetricScreenCopy.measuredCount(r.window.count, of: KeyMetricHistory.dayCount(d), side.period)
        case .windows(let w):
            return w.shown.isEmpty ? nil : KeyMetricScreenCopy.windowCount(w.shown.count)
        }
    }

    // Heart rate beside HRV: resting heart rate on the same nights, or heart rate in the same 5-minute windows.
    @ViewBuilder
    private func comparison(_ side: MetricInsightMetric, model: Shown) -> some View {
        let title: String = {
            if case .windows = model { return KeyMetricScreenCopy.compareHeartRate }
            return KeyMetricScreenCopy.compareRestingHeartRate
        }()
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { comparing.toggle() }
        } label: {
            HStack {
                Text(title).font(KeyMetricStyle.control)
                Spacer(minLength: 8)
                Image(systemName: comparing ? "minus" : "plus").font(.system(size: 13))
            }
            .foregroundStyle(KeyMetricStyle.text)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(comparing ? "Expanded" : "Collapsed"))
        Rectangle().fill(KeyMetricStyle.border).frame(height: 1)
        if comparing { comparisonChart(model: model).padding(.top, 12).padding(.bottom, 4) }
    }

    @ViewBuilder
    private func comparisonChart(model: Shown) -> some View {
        let hr = MetricCatalog.metric(key: "rhr", source: metric.source)
        let bpm: (Double) -> String = { v in hr?.format(v, system: unitSystem, temperature: temperatureUnit) ?? "\(Int(v.rounded())) bpm" }
        switch model {
        case .range(let r):
            let lo = r.domain?.lowerBound ?? .distantPast, hi = r.domain?.upperBound ?? .distantFuture
            let nights = restingHeartRate.filter { $0.date >= lo && $0.date <= hi }
            let guide = rangeGuide(r)
            let at = guide.id.flatMap { day in nights.first { $0.day == day } }
            comparisonHeader(KeyMetricScreenCopy.restingHeartRateNights, value: at.map { bpm($0.value) })
            KeyMetricDotChart(dots: nights.map { KeyMetricDot(id: $0.day, x: $0.date, y: $0.value) },
                              domain: Self.airy(r.domain), yTitle: KeyMetricScreenCopy.heartRateAxis,
                              xTitle: KeyMetricCopy.axis(.night),
                              xTicks: r.domain.map { ChartAxisDays.spanning([$0.lowerBound, $0.upperBound], targetLabels: 4,
                                                                             calendar: PhysiologyContextDates.calendar) } ?? [],
                              xLabel: { KeyMetricDates.format($0, template: "MMMd") }, color: KeyMetricStyle.teal,
                              dotSize: 26, minimumPad: 3, height: 130, guideX: guide.x)
        case .windows(let w):
            let guide = windowGuide(w)
            let dots = w.shown.compactMap { r in w.heartRate[r.start].map { KeyMetricDot(id: r.id, x: r.mid, y: $0) } }
            let at = selectedWindow(w).flatMap { w.heartRate[$0.start] }
            comparisonHeader(KeyMetricScreenCopy.heartRateMatching, value: at.map(bpm))
            KeyMetricDotChart(dots: dots, domain: w.domain, yTitle: KeyMetricScreenCopy.heartRateAxis,
                              xTitle: KeyMetricScreenCopy.localTime, xTicks: Self.hourTicks(w.domain, zone: w.zone),
                              xLabel: { Self.hourLabel($0, zone: w.zone) }, color: KeyMetricStyle.teal,
                              dotSize: 12, minimumPad: 3, height: 130, guideX: guide.x)
        }
    }

    private func comparisonHeader(_ title: String, value: String?) -> some View {
        HStack {
            Text(title)
            Spacer(minLength: 8)
            if let value { Text(value).monospacedDigit() }
        }
        .font(KeyMetricStyle.label)
        .foregroundStyle(KeyMetricStyle.secondary)
        .padding(.bottom, 6)
    }

    private func methodRows(_ side: MetricInsightMetric, model: Shown) -> [(label: String, value: String)] {
        switch model {
        case .range(let r):
            var rows: [(label: String, value: String)] = [
                (KeyMetricScreenCopy.rowMetric, KeyMetricScreenCopy.metricDescription(side, windows: false)),
                (KeyMetricScreenCopy.rowSource, side.series.isServerOnly ? KeyMetricScreenCopy.sourceServer
                    : KeyMetricScreenCopy.sourceStrap),
            ]
            if let label = side.measurement.label { rows.append((KeyMetricScreenCopy.rowMeasurement, label)) }
            switch r.band?.kind ?? (side.usualSeries != nil ? .usual : .recent) {
            case .usual:
                rows.append((KeyMetricScreenCopy.rowShaded, KeyMetricScreenCopy.shadedUsual))
                rows.append((KeyMetricScreenCopy.rowComparison, KeyMetricScreenCopy.comparisonUsual))
            case .recent:
                rows.append((KeyMetricScreenCopy.rowShaded, KeyMetricScreenCopy.shadedRecent(side.period)))
                rows.append((KeyMetricScreenCopy.rowComparison, KeyMetricScreenCopy.comparisonRecent))
            }
            rows.append((KeyMetricScreenCopy.rowMissing, KeyMetricScreenCopy.missing(side.period)))
            return rows
        case .windows:
            return [
                (KeyMetricScreenCopy.rowMetric, KeyMetricScreenCopy.metricDescription(side, windows: true)),
                (KeyMetricScreenCopy.rowSource, KeyMetricScreenCopy.sourceServer),
                (KeyMetricScreenCopy.rowContext, KeyMetricScreenCopy.windowsContext),
                (KeyMetricScreenCopy.rowComparison, windowFilter == .stableAwake
                    ? KeyMetricScreenCopy.windowsComparisonStableAwake : KeyMetricScreenCopy.windowsComparisonOther),
                (KeyMetricScreenCopy.rowMissing, KeyMetricScreenCopy.windowsMissing),
            ]
        }
    }

    /// Five rows around the selected reading.
    @ViewBuilder
    private func readingsTable(_ side: MetricInsightMetric, model: Shown) -> some View {
        let format = formatter(side)
        let rows: [(String, String, String)] = {
            switch model {
            case .range(let r):
                let at = selectedReading(r).flatMap { s in r.window.firstIndex { $0.day == s.day } } ?? r.window.count - 1
                let lo = max(0, min(at - 2, r.window.count - 5))
                return r.window.dropFirst(lo).prefix(5).map { reading in
                    let p = KeyMetricBands.placement(reading.value, day: reading.day, band: r.band, verdicts: r.verdicts)
                    return (KeyMetricDates.short(reading.date, includeYear: false), format.text(reading.value),
                            r.band.flatMap { KeyMetricScreenCopy.placement(p, kind: $0.kind) } ?? "")
                }
            case .windows(let w):
                let at = selectedWindow(w).flatMap { s in w.shown.firstIndex { $0.id == s.id } } ?? w.shown.count - 1
                let lo = max(0, min(at - 2, w.shown.count - 5))
                return w.shown.dropFirst(lo).prefix(5).map { reading in
                    (Self.timeText(Date(timeIntervalSince1970: TimeInterval(reading.start)), zone: w.zone),
                     format.text(reading.value), reading.context.name)
                }
            }
        }()
        let firstColumn: String = {
            if case .windows = model { return KeyMetricScreenCopy.rowTime }
            return side.period == .night ? KeyMetricScreenCopy.rowNight : KeyMetricScreenCopy.rowDay
        }()
        VStack(spacing: 0) {
            tableRow(firstColumn, KeyMetricScreenCopy.chartName(side), "", header: true)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in tableRow(row.0, row.1, row.2, header: false) }
        }
    }

    private func tableRow(_ a: String, _ b: String, _ c: String, header: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(a).frame(maxWidth: .infinity, alignment: .leading)
                Text(b).frame(maxWidth: .infinity, alignment: .leading)
                Text(c).frame(maxWidth: .infinity, alignment: .leading).lineLimit(2)
            }
            .font(KeyMetricStyle.small)
            .monospacedDigit()
            .foregroundStyle(header ? KeyMetricStyle.secondary : KeyMetricStyle.text)
            .padding(.vertical, 9)
            .padding(.horizontal, 4)
            Rectangle().fill(KeyMetricStyle.border).frame(height: 1)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: 5. Ask Sana

    /// Opens a new Sana chat on this screen: the question in the person's voice, what the screen showed as hidden
    /// context, and a memory that this metric matters to them.
    private func askSana(_ side: MetricInsightMetric, model: Shown) {
        let screen = handoffScreen(side, model: model)
        coach.pendingHandoff = CoachHandoff(prompt: KeyMetricHandoff.prompt(metricName: screen.metricName),
                                            screenContext: KeyMetricHandoff.context(screen),
                                            memory: KeyMetricHandoff.memory(metricName: KeyMetricScreenCopy.memoryName(side)))
        router.openCoach()
    }

    private func handoffScreen(_ side: MetricInsightMetric, model: Shown) -> KeyMetricHandoff.Screen {
        let format = formatter(side)
        let text = summaryText(side, model: model)
        let selected = selectionText(side, model: model)
        var screen = KeyMetricHandoff.Screen(
            metricName: entry.metrics.count > 1 ? "\(entry.title) (\(side.switchLabel))" : entry.title,
            periodLabel: KeyMetricPeriods.label(periodOf(model), side.period),
            contextFilter: { if case .windows = model { return windowFilter.name } else { return nil } }(),
            headline: text.value.map(format.text), headlineMeaning: text.meaning, rangeLine: text.rangeLine,
            selection: selected?.value, selectionMeaning: selected?.meta, measurement: side.measurement.label)
        switch model {
        case .range(let r):
            screen.recent = r.window.suffix(10).map { (KeyMetricDates.format($0.date, template: "MMMd"), format.text($0.value)) }
            if let d = r.domain {
                screen.countLine = KeyMetricCopy.measured(r.window.count, of: KeyMetricHistory.dayCount(d), side.period)
            }
        case .windows(let w):
            screen.countLine = w.shown.isEmpty ? nil : KeyMetricScreenCopy.windowCount(w.shown.count)
        }
        if let insight = insights.state(for: side)?.insight {
            screen.explanationHeadline = insight.headline
            screen.explanationSentences = insight.observed + insight.interpretation + insight.uncertainty
            screen.explanationBasis = MetricInsightCopy.basis(insight)
        }
        return screen
    }

    private func periodOf(_ model: Shown) -> KeyMetricPeriod {
        switch model {
        case .range(let r): return r.period
        case .windows: return .hours24
        }
    }

    // MARK: Load

    /// Each side's own series (`KeyMetricSeries`), with missing, placeholder and non-finite values left out, and for
    /// a day metric only the complete local days (`KeyMetricHistory.measured(_:for:today:)`).
    private func load() async {
        let today = Repository.localDayKey(Date())
        var loadedReadings: [MetricInsightMetric: [KeyMetricHistory.Reading]] = [:]
        for side in entry.metrics {
            let series = await series(side, today: today)
            guard !Task.isCancelled else { return }
            loadedReadings[side] = KeyMetricHistory.measured(series, for: side, today: today)
        }
        let latestDays = loadedReadings.compactMapValues { $0.last?.day }
        if loaded, latestDays != loadedLatestDays { insightRequest &+= 1 }
        loadedLatestDays = latestDays
        readings = loadedReadings
        loaded = true
    }

    /// One side's whole series, unfiltered (docs/METRIC_INSIGHTS.md, "value the screen shows").
    private func series(_ side: MetricInsightMetric, today: String) async -> [(day: String, value: Double)] {
        switch side.series {
        case .explore:
            return await repo.exploreSeries(key: metric.key, source: metric.source)
        case .sdnn:
            return KeyMetricValues.sdnn(repo.days)
        case .absoluteSkinTemp:
            return KeyMetricValues.absoluteSkinTemp(repo.days)
        case .spo2WithCandidate:
            let measured = await repo.exploreSeries(key: metric.key, source: metric.source)
            // The descriptor is the strap's own (`KeyMetricCatalog`), the only one with a candidate behind it.
            guard PuffinExperiment.spo2CandidateDisplayEnabled else { return measured }
            let candidate = await repo.exploreSeries(key: "spo2_candidate", source: metric.source)
            return KeyMetricValues.filling(measured, from: candidate)
        case .contextHistory(let seriesKey):
            return await contextSeries(side, seriesKey: seriesKey, today: today)
        case .resolved:
            return await repo.resolvedSeries(key: metric.key, source: metric.source).values
        }
    }

    /// The daily values of `seriesKey` from the server's context history, through yesterday (the latest complete
    /// day), read with the running account's own credential (`PhysiologyContextStore.runningAccountRepository`).
    /// The phone's copy of the same reads draws first; then the server's answer replaces it, and a read the server
    /// does not answer keeps its copy. Local-only, signed out, an older server or no context give nothing: the
    /// screen's own empty state.
    ///
    /// Read here rather than through `PhysiologyContextStore.loadHistory`, which returns at once while the same
    /// range is in flight: a load that restarts mid-read would then find nothing and stay empty.
    private func contextSeries(_ side: MetricInsightMetric, seriesKey: String,
                               today: String) async -> [(day: String, value: Double)] {
        guard CloudPushSettings.isEnabled, CloudPushSettings.isConfigured,
              let scope = CloudPushRuntime.shared.runningScope,
              let repository = PhysiologyContextStore.runningAccountRepository(),
              let lastDay = PhysiologyContextDates.key(today, minusDays: 1) else { return [] }
        let candidates = context.readCandidates
        let reads = KeyMetricValues.contextReads(through: lastDay)
        // An answer read for one account never lands on the next one's screen.
        func current() -> Bool { !Task.isCancelled && CloudPushRuntime.shared.runningScope == scope }

        var copies: [[PhysiologyContext.DailyValue]] = []
        for read in reads {
            let cached = await repository.cachedHistory(from: read.from, to: read.to, deviceIds: candidates,
                                                        mode: read.mode)
            copies.append(cached?.dailyValues ?? [])
        }
        guard current() else { return [] }
        if readings[side] == nil {
            let instant = KeyMetricHistory.measured(KeyMetricValues.contextDaily(copies.flatMap { $0 },
                                                                                 seriesKey: seriesKey),
                                                    for: side, today: today)
            if !instant.isEmpty { readings[side] = instant }
        }

        var values: [PhysiologyContext.DailyValue] = []
        for (read, copy) in zip(reads, copies) {
            let answer = try? await repository.history(from: read.from, to: read.to, deviceIds: candidates,
                                                       mode: read.mode)
            guard current() else { return [] }
            if case .loaded(let history)? = answer { values += history.dailyValues } else { values += copy }
        }
        return KeyMetricValues.contextDaily(values, seriesKey: seriesKey)
    }

    // MARK: Walking

    /// The Steps page's "How you walked" card, one tap away instead of inline: it brings its own day stepper, an
    /// hourly chart and a list of walks, which would put a second chart and a second date on a screen built around
    /// one of each. It opens on the day the headline shows.
    private func walkingLink(day: String) -> some View {
        NavigationLink {
            WalkingDetailScreen(day: day)
        } label: {
            KeyMetricPanel(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16)) {
                HStack(spacing: 14) {
                    Image(systemName: "figure.walk")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(ActivityFamily.walking.color)
                        .frame(width: 24)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("How you walked")
                            .font(KeyMetricStyle.control)
                            .fontWeight(.medium)
                            .foregroundStyle(KeyMetricStyle.text)
                        Text("Walking time, pace and each walk, from your strap's motion.")
                            .font(KeyMetricStyle.label)
                            .foregroundStyle(KeyMetricStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(KeyMetricStyle.secondary)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
        }
        .buttonStyle(LiquidPressStyle())
    }
}

/// The Steps page's "How you walked" card on a page of its own, opened from the key-metric Steps screen, the
/// day page's Walking card and the day Steps page.
struct WalkingDetailScreen: View {
    /// The local calendar day (`yyyy-MM-dd`) to open on.
    let day: String

    var body: some View {
        ScrollView {
            WalkingInsightsSection(day: day)
                .padding(NoopMetrics.screenPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        #if os(iOS)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        .modifier(MetricDetailBackdrop())
        .navigationTitle(Text("Walking"))
    }
}

// MARK: - Backdrop

/// The metric detail screens' backdrop (#430 parity): the SAME backdrop as the screen that pushed them — the day-cycle
/// sky when the setting is on (full-viewport with the softer settle when "Sky behind cards" is also on, so the
/// transparent cards reveal it the whole way down), the custom background image when one is set, the plain canvas
/// otherwise. Shared by `MetricDetailView` and `KeyMetricDetailView`; same keys TodayView / LiquidTodayView gate on.
struct MetricDetailBackdrop: ViewModifier {
    @AppStorage(SceneBackgroundPrefs.enabledKey) private var showDayCycleBackground = true
    @AppStorage(SkyBehindCardsPrefs.enabledKey) private var skyBehindCards = true
    /// Custom background image (#custom-background): when active it overrides the sky.
    @ObservedObject private var backgroundStore = BackgroundImageStore.shared

    func body(content: Content) -> some View {
        content
            .background(alignment: .top) {
                ZStack(alignment: .top) {
                    StrandPalette.surfaceBase
                    if backgroundStore.isActive {
                        BackgroundImageBackdrop()
                    } else if showDayCycleBackground {
                        LiquidSkyStatic(hour: nil, settleStrength: skyBehindCards ? 0.78 : 1)
                            .frame(maxWidth: .infinity)
                            .frame(height: skyBehindCards ? nil : 240, alignment: .top)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .ignoresSafeArea()
            }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Key metric — resting HR") {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    let metric = MetricCatalog.metric(key: "rhr", source: "my-whoop")!
    return NavigationStack {
        KeyMetricDetailView(metric: metric, entry: KeyMetricCatalog.entry(for: metric)!)
    }
    .environmentObject(repo)
    .environmentObject(BaselineStore())
    .environmentObject(AICoachEngine(repo: repo))
    .environmentObject(NavRouter())
    .frame(width: 900, height: 820)
    .preferredColorScheme(.dark)
}

#Preview("Key metric — HRV switch") {
    let repo = Repository(deviceId: "preview")
    repo.loaded = true
    let metric = MetricCatalog.metric(key: "hrv", source: "my-whoop")!
    return NavigationStack {
        KeyMetricDetailView(metric: metric, entry: KeyMetricCatalog.entry(for: metric)!)
    }
    .environmentObject(repo)
    .environmentObject(BaselineStore())
    .environmentObject(AICoachEngine(repo: repo))
    .environmentObject(NavRouter())
    .frame(width: 900, height: 820)
    .preferredColorScheme(.dark)
}
#endif

import SwiftUI
import StrandDesign
import StrandAnalytics

// KeyMetricDetailView.swift — the drill-down for a key metric (`KeyMetricCatalog`: the strap's resting heart rate,
// HRV, wrist temperature, respiratory rate, blood oxygen, stable awake heart rate, steps and calories), in the
// owner-approved concept's style (nara-hrv.html, `KeyMetricStyle`). Top to bottom:
//
//   1. the title, Today | History and, in History, the period control (24 hours where the metric has 5-minute
//      windows, then 7 / 30 / 90 nights or days and a year) and, in the 24-hour view, the context chips,
//   2. for each side (HRV shows RMSSD and then SDNN, one under the other): in Today the value now, a chart of
//      every reading since midnight (coloured by what the wearer was doing, with the activity lane and the
//      gaps) and the comparisons; in History the period's value, one panel (the readings as dots over the shaded range,
//      gaps shaded with the server's reasons, the activity lane in the 24-hour view, a legend, and the selected
//      reading with previous / next), how many periods were measured, and a "Readings" disclosure,
//   3. the server's explanation (`MetricInsightCard`) with an "Ask Sana" button that opens Sana on this screen's
//      context and remembers that the person cared about this metric,
//   4. "Data & method" in two sentences.
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
    /// The phone's own activity labels, which fill in a reading the server's window left unclear.
    @ObservedObject private var lanes = KeyMetricActivityLanes.shared
    /// The context history stable awake heart rate is read from, and the day documents the 24-hour view reads. Its
    /// `epoch` moves when the account, or the device ids the server holds the strap under, change; the screen then
    /// reads again.
    @ObservedObject private var context = PhysiologyContextStore.shared

    // The reader's unit preferences, exactly as `MetricDetailView` reads them (display only).
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    /// The Sana tab's switch (RootTabView); the Ask Sana button goes with it.
    @AppStorage("noop.coachEnabled") private var coachEnabled = true

    @State private var period: KeyMetricPeriod = KeyMetricPeriods.defaultPeriod
    /// Today (the value now against the person's own baselines) or the history charts. The screen opens on Today.
    @State private var mode: ScreenMode = .today
    /// A day metric's value so far today (steps, calories). The charts leave today out because it is still running;
    /// the Today view shows it.
    @State private var todayValues: [MetricInsightMetric: Double] = [:]
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
    /// Each side's chart selection (HRV shows both of its measures, each with its own chart).
    @State private var selections: [MetricInsightMetric: Selection] = [:]
    @State private var comparing = false
    /// Resting heart rate per night, for HRV's comparison chart.
    @State private var restingHeartRate: [KeyMetricHistory.Reading] = []
    @State private var plotInset = KeyMetricPlotInsetKey.defaultValue
    /// Today's strap readings the phone banked, for the sides whose Today chart draws them.
    @State private var banked: [MetricInsightMetric: KeyMetricReadings.BankedSeries] = [:]

    private enum ScreenMode: Hashable { case today, history }

    /// What the guide marks: the latest reading (on arrival), a chosen one, or a place with no reading.
    private enum Selection: Equatable {
        case latest
        case reading(String)
        case gap(Date)
    }

    /// The entry's first side: it leads the period control and the explanation. HRV's two measures are shown one
    /// under the other, never behind a switch.
    private var primary: MetricInsightMetric { entry.metrics.first ?? .restingHeartRate }

    private func selection(_ side: MetricInsightMetric) -> Selection { selections[side] ?? .latest }

    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .metric }
    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: unitSystem, override: temperatureRaw)
    }

    private func formatter(_ side: MetricInsightMetric) -> KeyMetricFormatter {
        KeyMetricFormatter(metric: side, descriptor: metric, system: unitSystem, temperature: temperatureUnit)
    }

    private func windowFilter(_ side: MetricInsightMetric) -> KeyMetricWindowFilter {
        windowFilters[side] ?? side.defaultWindowContext
    }

    /// The period a side shows in History: the chosen one, or the longest unlocked one below it.
    private func effectivePeriod(_ side: MetricInsightMetric) -> KeyMetricPeriod {
        let periods = KeyMetricPeriods.periods(for: side)
        return KeyMetricPeriods.coerced(periods.contains(period) ? period : KeyMetricPeriods.defaultPeriod,
                                        among: periods, isUnlocked: { isUnlocked($0, side) })
    }

    private func isUnlocked(_ period: KeyMetricPeriod, _ side: MetricInsightMetric) -> Bool {
        let shown = readings[side] ?? []
        return KeyMetricPeriods.isUnlocked(period, spanDays: KeyMetricHistory.spanDays(shown),
                                           hasHistory: loaded && !shown.isEmpty)
    }

    // MARK: Body

    var body: some View {
        let primary = self.primary
        let shown = readings[primary] ?? []
        let effective = effectivePeriod(primary)
        let insightState = insights.state(for: primary)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title)
                    .font(KeyMetricStyle.title)
                    .foregroundStyle(KeyMetricStyle.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 16)
                VStack(alignment: .leading, spacing: KeyMetricStyle.gap) {
                    KeyMetricSegments(items: [ScreenMode.today, .history],
                                      selection: Binding(get: { mode }, set: { mode = $0; selections = [:] }),
                                      label: { $0 == .today ? KeyMetricTodayCopy.today : KeyMetricTodayCopy.history })
                    if mode == .history {
                        KeyMetricSegments(items: KeyMetricPeriods.periods(for: primary),
                                          selection: Binding(get: { effective }, set: { period = $0; selections = [:] }),
                                          isEnabled: { isUnlocked($0, primary) },
                                          label: { KeyMetricPeriods.label($0, primary.period) })
                        if effective == .hours24 {
                            KeyMetricChips(items: KeyMetricWindowFilter.allCases,
                                           selection: Binding(get: { windowFilter(primary) }, set: { filter in
                                               for side in entry.metrics { windowFilters[side] = filter }
                                               selections = [:]
                                           }),
                                           label: \.name)
                        }
                    }
                }
                ForEach(entry.metrics, id: \.self) { side in
                    sideSection(side, models: sideModels(side))
                        .padding(.top, 24)
                }
                if mode == .today {
                    seeHistoryButton
                        .padding(.top, 8)
                }
                if insightState?.phase != .hidden {
                    MetricInsightCard(state: insightState, latestMeasuredDay: shown.last?.day, period: primary.period,
                                      onAskSana: coachEnabled ? { askSana(primary, model: sideModels(primary).main) } : nil,
                                      onRegenerate: {
                                          StrandHaptic.selection.play()
                                          insights.requestRegeneration(primary)
                                          insightRequest &+= 1
                                      })
                        .padding(.top, 24)
                }
                // The gait model runs on the server, so the row is offered only where there is one.
                if primary == .steps, let day = shown.last?.day, CloudPushSettings.isEnabled, CloudPushSettings.isConfigured {
                    walkingLink(day: day)
                        .padding(.top, 16)
                }
                methodNote
                    .padding(.top, 16)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            // The floating tab bar sits over the bottom of the screen: leave its height as scroll room so the last
            // line of the explanation can be scrolled clear of it.
            .padding(.bottom, 32 + Self.tabBarRoom)
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
        // The explanation (of the first side) is asked for on appear, again when a newer night or day
        // lands, and again for the next account after one ends (`epoch`); leaving the screen cancels the request and
        // its polling.
        .task(id: "\(primary.rawValue)|\(insightRequest)|\(insights.epoch)") { await insights.refresh(primary) }
        // The usual band for the days the shown ranges need.
        .task(id: usualTaskKey) { await loadUsual() }
        // The 5-minute views' day documents (and heart rate's, while comparing).
        .task(id: windowTaskKey) { await loadWindows() }
        .task(id: bankedTaskKey) { await loadBanked() }
        .task(id: "\(repo.refreshSeq)|\(Repository.localDayKey(Date()))") { await loadActivityLanes() }
        // The documents that can say why a night has no value.
        .task(id: nightlyTaskKey) { await loadNightly() }
        .task(id: "\(comparing)|\(repo.refreshSeq)") { await loadComparison() }
    }

    // MARK: Sides

    /// What one side shows. Today: the 30-period range behind the headline and comparisons (`main`) and the chart
    /// of today's readings (`today`). History: the chosen period (`main`).
    private struct SideModels {
        let main: Shown
        let today: Shown?
    }

    private func sideModels(_ side: MetricInsightMetric) -> SideModels {
        let shown = readings[side] ?? []
        switch mode {
        case .today:
            let month = rangeModel(side, shown: shown, period: KeyMetricPeriods.defaultPeriod)
            let chart: Shown
            if let source = side.todaySource {
                chart = .windows(todayModel(side, source: source))
            } else {
                chart = .range(rangeModel(side, shown: shown, period: .range(.week), endingAt: latestExpectedDay(side)))
            }
            return SideModels(main: .range(month), today: chart)
        case .history:
            let effective = effectivePeriod(side)
            let main: Shown = effective == .hours24
                ? .windows(windowModel(side, shown: shown, filter: windowFilter(side)))
                : .range(rangeModel(side, shown: shown, period: effective))
            return SideModels(main: main, today: nil)
        }
    }

    /// The latest night or day that could have a value: last night, or yesterday for a day metric (today is still
    /// running).
    private func latestExpectedDay(_ side: MetricInsightMetric) -> String {
        let today = Repository.localDayKey(Date())
        return side.period == .night ? today : (PhysiologyContextDates.key(today, minusDays: 1) ?? today)
    }

    @ViewBuilder
    private func sideSection(_ side: MetricInsightMetric, models: SideModels) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.metrics.count > 1 {
                Text(side.switchLabel)
                    .font(KeyMetricStyle.headline)
                    .foregroundStyle(KeyMetricStyle.text)
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 12)
            }
            if mode == .today, case .range(let r) = models.main {
                todayContent(side, shown: readings[side] ?? [], range: r, chart: models.today)
            } else {
                summary(side, model: models.main)
                    .padding(.bottom, 20)
                panel(side, model: models.main)
                below(side, model: models.main)
                    .padding(.top, 10)
            }
        }
    }

    /// "Data & method": two sentences at the foot of the page, the same for Today and History.
    private var methodNote: some View {
        KeyMetricDisclosure(title: KeyMetricScreenCopy.method) {
            Text(KeyMetricScreenCopy.methodSummary(entry.metrics))
                .font(KeyMetricStyle.label)
                .foregroundStyle(KeyMetricStyle.secondary)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var seeHistoryButton: some View {
        Button { mode = .history; selections = [:] } label: {
            HStack(spacing: 6) {
                Text(KeyMetricTodayCopy.seeHistory)
                Image(systemName: "chart.dots.scatter")
                    .accessibilityHidden(true)
            }
            .font(KeyMetricStyle.control)
            .foregroundStyle(KeyMetricStyle.accent)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("keyMetric.seeHistory")
    }

    /// The height of the floating tab bar that overlays this screen on iPhone; none on Mac.
    private static var tabBarRoom: CGFloat {
        #if os(iOS)
        NoopMetrics.tabBarClearance
        #else
        0
        #endif
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
        /// The nights or days in `domain` without a reading.
        let gaps: [KeyMetricGap]
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
        let filter: KeyMetricWindowFilter
        /// Rejected windows (with the server's reasons) and stretches with no window, up to now.
        let gaps: [KeyMetricGap]
        /// The stable awake median reference, only on the stable awake chip.
        let reference: PhysiologyContext.ReferenceComparison?
        /// Heart rate by window start, while comparing.
        let heartRate: [Int: Double]
        /// The day documents the view reads.
        var loads: [PhysiologyContextStore.Key] = []
        /// Today's chart: every reading since midnight, from `source`; `sessions` when the only value today is
        /// last night's.
        var today: KeyMetricTodaySource? = nil
        var sessions = false
    }

    /// `endingAt` pins the range's last day (Today's chart ends at last night even when it has no reading);
    /// otherwise the range ends at the latest reading.
    private func rangeModel(_ side: MetricInsightMetric, shown: [KeyMetricHistory.Reading],
                            period: KeyMetricPeriod, endingAt: String? = nil) -> RangeModel {
        let range = period.range ?? .month
        var domain = KeyMetricHistory.domain(shown, range: range)
        if let endingAt, let end = PhysiologyContextDates.date(endingAt), let days = range.days {
            domain = end.addingTimeInterval(-Double(days - 1) * 86_400)...end
        }
        let window = KeyMetricHistory.window(shown, domain: domain)
        let verdicts = usual[side] ?? [:]
        let band: KeyMetricBand?
        if side.usualSeries != nil {
            let inWindow = verdicts.filter { day, _ in window.contains { $0.day == day } }
            band = KeyMetricBands.usual(inWindow)
        } else {
            band = KeyMetricBands.recent(shown, window: window)
        }
        return RangeModel(period: period, domain: domain, window: window, band: band, verdicts: verdicts,
                          gaps: domain.map { KeyMetricHistory.missingDays(window, domain: $0) } ?? [])
    }

    /// The day the 24-hour view shows: the latest measured night or full day, else last night or yesterday.
    private func windowDay(_ side: MetricInsightMetric, shown: [KeyMetricHistory.Reading]) -> String {
        if let last = shown.last?.day { return last }
        let today = Repository.localDayKey(Date())
        return side.period == .night ? today : (PhysiologyContextDates.key(today, minusDays: 1) ?? today)
    }

    /// One night's or day's 5-minute windows: `day`, or else the latest measured one.
    private func windowModel(_ side: MetricInsightMetric, shown: [KeyMetricHistory.Reading], day: String? = nil,
                             filter: KeyMetricWindowFilter) -> WindowModel {
        let day = day ?? windowDay(side, shown: shown)
        guard let kind = side.windowMetric else {
            return emptyWindows(day: day, status: .ready, filter: filter)
        }
        let probeZone = TimeZone.current
        guard let probe = KeyMetricWindows.span(day: day, period: side.period, timeZone: probeZone) else {
            return emptyWindows(day: day, status: .ready, filter: filter)
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
        let shownWindows = all.filter { filter.admits($0) }
        var kinds = [kind]
        if comparing, kind != .heartRate { kinds.append(.heartRate) }
        let loads = probe.days.flatMap { day in kinds.map { PhysiologyContextStore.Key(day: day, metric: $0) } }
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
                           filter: filter,
                           gaps: KeyMetricWindows.gaps(envelopes, interval: interval, filter: filter),
                           reference: filter == .stableAwake
                               ? KeyMetricWindows.stableAwakeReference(documents, metric: kind) : nil,
                           heartRate: heartRate, loads: loads)
    }

    /// Today's chart: every reading since local midnight, each in the context it was taken in. The server's
    /// windows where it keeps them; the strap readings the phone banked for temperature and blood oxygen; last
    /// night's value drawn across the sleep when that is all there is (SDNN). The lane comes from the metric's
    /// own windows, else from heart rate's, which cover the whole worn day.
    private func todayModel(_ side: MetricInsightMetric, source: KeyMetricTodaySource) -> WindowModel {
        let day = Repository.localDayKey(Date())
        let own: PhysiologyContext.MetricKind? = {
            if case .windows(let kind) = source { return kind }
            return side.nightlyContextMetric
        }()
        let kinds = [own, .heartRate].compactMap { $0 }.reduce(into: [PhysiologyContext.MetricKind]()) {
            if !$0.contains($1) { $0.append($1) }
        }
        let loads = kinds.map { PhysiologyContextStore.Key(day: day, metric: $0) }
        let states = loads.map { context.state(for: $0) }
        func documents(_ kind: PhysiologyContext.MetricKind?) -> [PhysiologyContextDocument] {
            guard let kind else { return [] }
            return [context.state(for: .init(day: day, metric: kind))?.shownDay?.document].compactMap { $0 }
        }
        let zone = PhysiologyContextWording.zone(states.compactMap { $0?.shownDay?.document?.timezoneId }.first)
        guard let interval = KeyMetricWindows.today(day, timeZone: zone) else {
            return emptyWindows(day: day, status: .ready, filter: .all)
        }
        var status: WindowModel.Status = .ready
        switch source {
        case .windows(let kind):
            if documents(kind).isEmpty {
                if states.contains(where: { Self.needsCloud($0) }) {
                    status = .needsCloud
                } else if states.contains(where: { $0 == nil || $0 == .loading }) {
                    status = .loading
                } else if states.contains(where: { if case .pending = $0 { return true } else { return false } }) {
                    status = .pending
                }
            }
        case .banked:
            if banked[side] == nil { status = .loading }
        }
        let shown = KeyMetricWindows.day(source, night: status == .ready ? side.nightlyContextMetric : nil,
                                         interval: interval, documents: { documents($0) }, banked: banked[side])
        let domain = Date(timeIntervalSince1970: TimeInterval(interval.start))...Date(timeIntervalSince1970: TimeInterval(interval.end))
        return WindowModel(status: status, day: day, interval: interval, zone: zone, all: shown.readings,
                           shown: shown.readings, lane: shown.lane, domain: domain, filter: .all, gaps: shown.gaps,
                           reference: nil, heartRate: [:], loads: loads, today: source, sessions: shown.sessions)
    }

    private func emptyWindows(day: String, status: WindowModel.Status, filter: KeyMetricWindowFilter) -> WindowModel {
        let now = Date()
        return WindowModel(status: status, day: day, interval: nil, zone: .current, all: [], shown: [], lane: [],
                           domain: now.addingTimeInterval(-86_400)...now, filter: filter, gaps: [],
                           reference: nil, heartRate: [:])
    }

    private static func needsCloud(_ state: PhysiologyContextStore.State?) -> Bool {
        guard case .unavailable(let reason)? = state else { return false }
        return reason == .cloudOff || reason == .signedOut || reason == .accountNotReady
            || reason == .unsupportedServer
    }

    // MARK: Loading (usual, windows, comparison)

    private var usualTaskKey: String {
        entry.metrics.map { side -> String in
            guard case .range(let r) = sideModels(side).main, side.usualSeries != nil else { return "none" }
            return "\(side.rawValue)|\(r.window.first?.day ?? "")|\(r.window.last?.day ?? "")|\(r.window.count)"
        }.joined(separator: ",") + "|\(repo.refreshSeq)|\(repo.days.count)"
    }

    private func loadUsual() async {
        for side in entry.metrics {
            await loadUsual(side, model: sideModels(side).main)
            guard !Task.isCancelled else { return }
        }
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

    /// Every 5-minute view on screen, with its side.
    private var shownWindows: [(side: MetricInsightMetric, model: WindowModel)] {
        entry.metrics.flatMap { side -> [(side: MetricInsightMetric, model: WindowModel)] in
            let models = sideModels(side)
            return [models.main, models.today].compactMap {
                if case .windows(let w)? = $0 { return (side, w) } else { return nil }
            }
        }
    }

    private var windowTaskKey: String {
        shownWindows.flatMap(\.model.loads).map { "\($0.day)|\($0.metric.rawValue)" }.joined(separator: ",")
            + "|\(context.epoch)|\(repo.refreshSeq)"
    }

    private func loadWindows() async {
        for key in shownWindows.flatMap(\.model.loads) {
            guard !Task.isCancelled else { return }
            await context.load(key)
        }
    }

    /// Today's banked strap readings (temperature, blood oxygen), read again on new data and at a new day.
    private var bankedTaskKey: String {
        guard mode == .today else { return "none" }
        let sides = entry.metrics.filter { if case .banked? = $0.todaySource { return true } else { return false } }
        return sides.map(\.rawValue).joined(separator: ",") + "|\(repo.refreshSeq)|\(Repository.localDayKey(Date()))"
    }

    /// The last few days' activity classification, from the phone's cache, so every reading can take the label of
    /// the stretch it falls in.
    private func loadActivityLanes() async {
        let start = Calendar.current.startOfDay(for: Date())
        for back in 0...3 {
            guard !Task.isCancelled,
                  let day = Calendar.current.date(byAdding: .day, value: -back, to: start) else { return }
            await lanes.load(dayStart: day, repo: repo)
        }
    }

    private func loadBanked() async {
        guard mode == .today,
              let interval = KeyMetricWindows.today(Repository.localDayKey(Date()), timeZone: .current) else { return }
        for side in entry.metrics {
            guard case .banked(let signal)? = side.todaySource else { continue }
            let series = await repo.bankedSeries(signal, from: interval.start, to: interval.end)
            guard !Task.isCancelled else { return }
            banked[side] = series
        }
    }

    /// The day documents whose nightly envelopes can explain a missing night: Today's chart's missing nights, and
    /// a missing night selected in History.
    private var nightlyKeys: [PhysiologyContextStore.Key] {
        entry.metrics.flatMap { side -> [PhysiologyContextStore.Key] in
            guard let kind = side.nightlyContextMetric else { return [] }
            let models = sideModels(side)
            var days: [String] = []
            if case .range(let r)? = models.today { days += r.gaps.compactMap(\.day) }
            if mode == .history, case .range = models.main, case .gap(let x) = selection(side) {
                days.append(PhysiologyContextDates.key(x))
            }
            return days.map { .init(day: $0, metric: kind) }
        }
    }

    private var nightlyTaskKey: String {
        nightlyKeys.map { "\($0.day)|\($0.metric.rawValue)" }.joined(separator: ",") + "|\(context.epoch)"
    }

    private func loadNightly() async {
        for key in nightlyKeys {
            guard !Task.isCancelled else { return }
            await context.load(key)
        }
    }

    /// The server's reason a night has no value, once its document is loaded; nil when it gave none.
    private func nightlyReason(_ side: MetricInsightMetric, day: String) -> String? {
        guard let kind = side.nightlyContextMetric,
              let document = context.state(for: .init(day: day, metric: kind))?.shownDay?.document else { return nil }
        return KeyMetricWindows.nightlyGapReason([document], metric: kind)
    }

    /// HRV's comparison: resting heart rate per night, read once the reader opens it.
    private func loadComparison() async {
        guard comparing, entry.metrics.contains(where: { $0 == .hrvRmssd || $0 == .hrvSdnn }) else { return }
        let series = await repo.exploreSeries(key: "rhr", source: metric.source)
        guard !Task.isCancelled else { return }
        restingHeartRate = KeyMetricHistory.measured(series)
    }

    // MARK: Today

    /// The Today view: the value now, where it sits against the person's usual range, and the same value against
    /// the median of the last 7, 30 and 90 nights or days.
    /// Today's chart is the History chart scoped to today: the 5-minute windows of last night (or today) where the
    /// metric has them, else the last 7 nights or days ending at the latest one that could have a value.
    @ViewBuilder
    private func todayContent(_ side: MetricInsightMetric, shown: [KeyMetricHistory.Reading], range r: RangeModel,
                              chart: Shown?) -> some View {
        let format = formatter(side)
        let today = Repository.localDayKey(Date())
        let model = KeyMetricToday.make(readings: shown, todayValue: todayValues[side], today: today)
        VStack(alignment: .leading, spacing: 0) {
            todayHeadline(side, model: model, range: r, format: format)
                .padding(.bottom, 16)
            if side == .steps || side == .calories {
                // A day total's Today chart is the day itself: the running total through the hours.
                StepsTodayChart(kind: side == .steps ? .steps : .calories, dayTotal: todayValues[side])
                    .padding(.bottom, 16)
            } else if let chart {
                panel(side, model: chart)
                    .padding(.bottom, 16)
            }
            todayComparison(side, model: model, range: r, format: format)
        }
    }

    private func todayHeadline(_ side: MetricInsightMetric, model: KeyMetricToday, range r: RangeModel,
                               format: KeyMetricFormatter) -> some View {
        var earlier: String?
        if case .earlier(let day) = model.freshness, let date = PhysiologyContextDates.date(day) {
            earlier = KeyMetricDates.short(date, includeYear: false)
        }
        let placement = model.value.flatMap { value in
            model.day.map { KeyMetricBands.placement(value, day: $0, band: r.band, verdicts: r.verdicts) }
        }
        return VStack(alignment: .leading, spacing: 4) {
            if let value = model.value {
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
            Text(loaded ? KeyMetricTodayCopy.caption(model.freshness, period: side.period, earlier: earlier)
                 : KeyMetricCopy.reading(side.period))
                .font(KeyMetricStyle.label)
                .foregroundStyle(KeyMetricStyle.secondary)
            if let placement, let kind = r.band?.kind, let line = KeyMetricScreenCopy.placement(placement, kind: kind) {
                Text(line)
                    .font(KeyMetricStyle.range)
                    .foregroundStyle(KeyMetricStyle.text)
                    .padding(.top, 4)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func todayComparison(_ side: MetricInsightMetric, model: KeyMetricToday, range r: RangeModel,
                                 format: KeyMetricFormatter) -> some View {
        let rangeValue: String? = r.band?.latest.map { rangeText($0.low, $0.high, format: format) }
        return KeyMetricPanel(padding: EdgeInsets(top: 14, leading: 16, bottom: 6, trailing: 16)) {
            VStack(alignment: .leading, spacing: 0) {
                Text(KeyMetricTodayCopy.compareTitle)
                    .font(KeyMetricStyle.label)
                    .foregroundStyle(KeyMetricStyle.secondary)
                    .padding(.bottom, 4)
                if let rangeValue, let band = r.band {
                    comparisonRow(title: band.kind == .usual ? KeyMetricTodayCopy.usualRange : KeyMetricTodayCopy.recentRange,
                                  detail: nil, trailing: rangeValue, divider: !model.baselines.isEmpty)
                }
                ForEach(Array(model.baselines.enumerated()), id: \.element.id) { index, baseline in
                    let median = format.text(baseline.median)
                    comparisonRow(title: KeyMetricTodayCopy.baselineTitle(days: baseline.days, period: side.period),
                                  detail: KeyMetricTodayCopy.baselineDetail(median: median, count: baseline.count,
                                                                            period: side.period),
                                  trailing: deltaText(baseline, side: side, format: format),
                                  divider: index < model.baselines.count - 1)
                }
                if model.baselines.isEmpty {
                    Text(loaded ? KeyMetricTodayCopy.noBaselines : " ")
                        .font(KeyMetricStyle.small)
                        .foregroundStyle(KeyMetricStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.vertical, 10)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func comparisonRow(title: String, detail: String?, trailing: String, divider: Bool) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(KeyMetricStyle.control)
                        .foregroundStyle(KeyMetricStyle.text)
                    if let detail {
                        Text(detail)
                            .font(KeyMetricStyle.small)
                            .foregroundStyle(KeyMetricStyle.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                Text(trailing)
                    .font(KeyMetricStyle.selectedValue)
                    .foregroundStyle(KeyMetricStyle.text)
                    .multilineTextAlignment(.trailing)
            }
            .padding(.vertical, 12)
            .accessibilityElement(children: .combine)
            if divider { Rectangle().fill(KeyMetricStyle.border).frame(height: 1) }
        }
    }

    /// "+3 bpm" or "-2 ms": the value minus the baseline, in the reader's units. A difference in temperature
    /// scales between units but does not shift, so it is converted as a difference, not as a reading.
    private func deltaText(_ baseline: KeyMetricToday.Baseline, side: MetricInsightMetric,
                           format: KeyMetricFormatter) -> String {
        var delta = baseline.delta
        if side == .skinTemp, temperatureUnit == .fahrenheit { delta *= 9.0 / 5.0 }
        let reference = format.parts(baseline.median)
        let places: Int = {
            switch side {
            case .steps, .calories: return 0
            default: return reference.number.contains(where: { $0 == "." || $0 == "," }) ? 1 : 0
            }
        }()
        let magnitude = String(format: "%.\(places)f", abs(delta))
        if Double(magnitude) == 0 { return KeyMetricTodayCopy.sameAsBaseline }
        let number = reference.unit == "%" ? "\(magnitude)%" : magnitude + (reference.unit.map { " \($0)" } ?? "")
        return KeyMetricTodayCopy.delta(number, positive: delta > 0)
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
                                                                                 filter: w.filter)
            let line: String?
            switch w.filter {
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
                : KeyMetricScreenCopy.windowsSummaryEmpty(w.filter)
        }
    }

    /// Why the 24-hour or Today panel has no readings.
    private func windowsEmptyText(_ w: WindowModel, side: MetricInsightMetric) -> String? {
        switch w.status {
        case .needsCloud: return KeyMetricScreenCopy.windowsNeedCloud
        case .loading: return nil
        case .pending: return KeyMetricScreenCopy.windowsPending
        case .ready:
            guard let today = w.today else { return KeyMetricScreenCopy.noWindows(w.filter) }
            return today == .banked(.spo2) ? KeyMetricScreenCopy.spo2SleepOnly : KeyMetricScreenCopy.noReadingsToday
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
            if w.today != nil {
                return "\(KeyMetricScreenCopy.today), \(KeyMetricDates.format(date, template: "MMMd"))"
            }
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
        case .windows(let w):
            if let today = w.today {
                parts.append(KeyMetricScreenCopy.todayGrain(today, sessions: w.sessions))
            } else if let kind = side.windowMetric {
                parts.append(KeyMetricScreenCopy.todayGrain(.windows(kind), sessions: false))
            } else {
                parts.append(KeyMetricScreenCopy.fiveMinute)
            }
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
                }
                if let note = gapNote(side, model: model) {
                    Text(note)
                        .font(KeyMetricStyle.small)
                        .foregroundStyle(KeyMetricStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 2)
                }
                if hasReadings(model) {
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
        let guide = rangeGuide(side, r)
        return Group {
            if r.window.isEmpty {
                emptyPlot(loaded ? KeyMetricCopy.nothingToChart(side.period) : nil)
            } else {
                KeyMetricDotChart(dots: dots, domain: plotDomain, band: band, gaps: r.gaps, yTitle: yTitle(side),
                                  xTitle: KeyMetricCopy.axis(side.period), xTicks: ticks,
                                  xLabel: { KeyMetricDates.format($0, template: needsYear ? "MMMdyy" : "MMMd") },
                                  dotSize: r.window.count > 120 ? 14 : r.window.count > 45 ? 22 : 40,
                                  minimumPad: side.minimumPad, floorsAtZero: true, height: 210,
                                  guideX: guide.x, selectedID: guide.id,
                                  onSelect: { selectReading(side, at: $0, in: r.window) })
            }
        }
    }

    /// Half a day of air either side so the first and last dots are not clipped by the plot edge.
    private static func airy(_ domain: ClosedRange<Date>?) -> ClosedRange<Date> {
        guard let domain else { let now = Date(); return now.addingTimeInterval(-6 * 86_400)...now }
        return domain.lowerBound.addingTimeInterval(-43_200)...domain.upperBound.addingTimeInterval(43_200)
    }

    private func selectedReading(_ side: MetricInsightMetric, _ r: RangeModel) -> KeyMetricHistory.Reading? {
        switch selection(side) {
        case .latest: return r.window.last
        case .reading(let day): return r.window.first { $0.day == day } ?? r.window.last
        case .gap: return nil
        }
    }

    private func rangeGuide(_ side: MetricInsightMetric, _ r: RangeModel) -> (x: Date?, id: String?) {
        if case .gap(let x) = selection(side) { return (x, nil) }
        let reading = selectedReading(side, r)
        return (reading?.date, reading?.day)
    }

    /// The nearest reading within half a day of the touch; otherwise the touched day, as a gap.
    private func selectReading(_ side: MetricInsightMetric, at date: Date, in window: [KeyMetricHistory.Reading]) {
        guard let nearest = window.min(by: { abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date)) })
        else { return }
        if abs(nearest.date.timeIntervalSince(date)) <= 43_200 {
            if selection(side) != .reading(nearest.day) { StrandHaptic.selection.play() }
            selections[side] = .reading(nearest.day)
        } else {
            let day = PhysiologyContextDates.calendar.startOfDay(for: date.addingTimeInterval(43_200))
            selections[side] = .gap(day)
        }
    }

    // MARK: Window chart

    @ViewBuilder
    private func windowChart(_ side: MetricInsightMetric, _ w: WindowModel) -> some View {
        let format = formatter(side)
        let ticks = Self.hourTicks(w.domain, zone: w.zone)
        let dots = w.shown.map { r in
            KeyMetricDot(id: r.id, x: r.mid, y: format.plotted(r.value), color: KeyMetricActivityLane.dotColor(r.context),
                         span: r.isSpan ? Date(timeIntervalSince1970: TimeInterval(r.start))...Date(timeIntervalSince1970: TimeInterval(r.end)) : nil)
        }
        let guide = windowGuide(side, w)
        if w.shown.isEmpty {
            emptyPlot(windowsEmptyText(w, side: side))
        } else {
            KeyMetricDotChart(dots: dots, domain: w.domain, gaps: w.gaps,
                              referenceLine: w.reference?.center.map(format.plotted),
                              yTitle: yTitle(side), xTitle: KeyMetricScreenCopy.localTime, xTicks: ticks,
                              xLabel: { Self.hourLabel($0, zone: w.zone) },
                              dotSize: w.shown.count > 400 ? 6 : w.shown.count > 160 ? 10 : 16,
                              minimumPad: side.minimumPad, height: 210,
                              guideX: guide.x, selectedID: guide.id,
                              onSelect: { selectWindow(side, at: $0, in: w.shown) })
        }
        if !w.lane.isEmpty {
            KeyMetricActivityLane(spans: w.lane, domain: w.domain, inset: plotInset, guideX: guide.x)
                .padding(.top, 4)
        }
    }

    private func selectedWindow(_ side: MetricInsightMetric, _ w: WindowModel) -> KeyMetricWindowReading? {
        switch selection(side) {
        case .latest: return w.shown.last
        case .reading(let id): return w.shown.first { $0.id == id } ?? w.shown.last
        case .gap: return nil
        }
    }

    private func windowGuide(_ side: MetricInsightMetric, _ w: WindowModel) -> (x: Date?, id: String?) {
        if case .gap(let x) = selection(side) { return (x, nil) }
        let reading = selectedWindow(side, w)
        return (reading?.mid, reading?.id)
    }

    /// The window under the touch (within 7½ minutes of its middle, or anywhere on a night's span); otherwise
    /// that moment, as a gap.
    private func selectWindow(_ side: MetricInsightMetric, at date: Date, in windows: [KeyMetricWindowReading]) {
        let nearest = windows.min { abs($0.mid.timeIntervalSince(date)) < abs($1.mid.timeIntervalSince(date)) }
        if let nearest, abs(nearest.mid.timeIntervalSince(date)) <= max(450, Double(nearest.end - nearest.start) / 2) {
            if selection(side) != .reading(nearest.id) { StrandHaptic.selection.play() }
            selections[side] = .reading(nearest.id)
        } else {
            selections[side] = .gap(date)
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
        let gaps: Bool
        switch model {
        case .range(let r): band = r.band?.kind; gaps = !r.gaps.isEmpty
        case .windows(let w):
            band = nil; reference = w.reference != nil && !w.shown.isEmpty
            gaps = w.gaps.contains { $0.end > w.domain.lowerBound && $0.start < w.domain.upperBound }
        }
        return FlowLayout(spacing: 14) {
            HStack(spacing: 6) {
                Circle().fill(KeyMetricStyle.accent).frame(width: 7, height: 7)
                Text(KeyMetricScreenCopy.reading)
            }
            if gaps {
                HStack(spacing: 6) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(KeyMetricStyle.gapFill)
                        .frame(width: 15, height: 9)
                    Text(KeyMetricScreenCopy.noReading)
                }
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
            if case .gap(let x) = selection(side) {
                let reason = nightlyReason(side, day: PhysiologyContextDates.key(x))
                return ("\(KeyMetricScreenCopy.noReading) · \(KeyMetricDates.short(x, includeYear: false))",
                        reason.map(PhysiologyContextWording.capitalizedFirst) ?? KeyMetricScreenCopy.gapNote)
            }
            guard let reading = selectedReading(side, r) else { return nil }
            let placement = KeyMetricBands.placement(reading.value, day: reading.day, band: r.band, verdicts: r.verdicts)
            let meta = r.band.flatMap { KeyMetricScreenCopy.placement(placement, kind: $0.kind) }
                ?? KeyMetricCopy.latest(side.period)
            return ("\(format.text(reading.value)) · \(KeyMetricDates.short(reading.date, includeYear: false))", meta)
        case .windows(let w):
            if case .gap(let x) = selection(side) {
                let reason = w.gaps.first { $0.contains(x) }?.words
                return ("\(KeyMetricScreenCopy.noReading) · \(Self.timeText(x, zone: w.zone))",
                        reason.map(PhysiologyContextWording.capitalizedFirst) ?? KeyMetricScreenCopy.gapNote)
            }
            guard let reading = selectedWindow(side, w) else { return nil }
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
                stepButton(-1, side: side, model: model)
                VStack(spacing: 3) {
                    Text(text?.value ?? " ")
                        .font(KeyMetricStyle.selectedValue)
                        .foregroundStyle(KeyMetricStyle.text)
                        .lineLimit(1)
                    // A gap's reason can need a second line.
                    Text(text?.meta ?? " ")
                        .font(KeyMetricStyle.small)
                        .foregroundStyle(KeyMetricStyle.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .combine)
                stepButton(1, side: side, model: model)
            }
            .padding(.top, 8)
        }
        .padding(.top, 4)
    }

    private func stepButton(_ step: Int, side: MetricInsightMetric, model: Shown) -> some View {
        Button { move(step, side: side, model: model) } label: {
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
    private func move(_ step: Int, side: MetricInsightMetric, model: Shown) {
        let ids: [String]
        let xs: [Date]
        let current: String?
        switch model {
        case .range(let r):
            ids = r.window.map(\.day); xs = r.window.map(\.date); current = selectedReading(side, r)?.day
        case .windows(let w):
            ids = w.shown.map(\.id); xs = w.shown.map(\.mid); current = selectedWindow(side, w)?.id
        }
        guard !ids.isEmpty else { return }
        let index: Int
        if case .gap(let x) = selection(side) {
            let after = xs.firstIndex { $0 > x } ?? xs.count
            index = step > 0 ? min(after, ids.count - 1) : max(after - 1, 0)
        } else {
            let at = current.flatMap { ids.firstIndex(of: $0) } ?? ids.count - 1
            index = min(max(at + step, 0), ids.count - 1)
        }
        selections[side] = .reading(ids[index])
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
            // Once, under the first of HRV's two charts: it follows that chart's guide.
            if side == primary, side == .hrvRmssd || side == .hrvSdnn { comparison(side, model: model) }
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

    /// The small line under a chart saying why readings are missing, only from what the server reported: the
    /// rejected windows' reasons and unrecorded time, or a missing night's own rejected envelope.
    private func gapNote(_ side: MetricInsightMetric, model: Shown) -> String? {
        switch model {
        case .windows(let w):
            guard w.status == .ready else { return nil }
            let note = KeyMetricGap.note(w.gaps, in: w.domain)
            guard w.today != nil, !w.shown.isEmpty, !w.sessions else { return note }
            return ["\(KeyMetricScreenCopy.todayCount(w.shown.count)).", note].compactMap { $0 }.joined(separator: " ")
        case .range(let r):
            // History names a selected missing night's reason in the row under the chart instead.
            guard mode == .today else { return nil }
            let explained = r.gaps.compactMap { gap -> String? in
                guard let day = gap.day, let reason = nightlyReason(side, day: day),
                      let date = PhysiologyContextDates.date(day) else { return nil }
                return "\(KeyMetricDates.short(date, includeYear: false)), \(reason)"
            }
            return explained.isEmpty ? nil : KeyMetricScreenCopy.gapsBecause(explained.suffix(2).joined(separator: "; "))
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
        if comparing { comparisonChart(side, model: model).padding(.top, 12).padding(.bottom, 4) }
    }

    @ViewBuilder
    private func comparisonChart(_ side: MetricInsightMetric, model: Shown) -> some View {
        let hr = MetricCatalog.metric(key: "rhr", source: metric.source)
        let bpm: (Double) -> String = { v in hr?.format(v, system: unitSystem, temperature: temperatureUnit) ?? "\(Int(v.rounded())) bpm" }
        switch model {
        case .range(let r):
            let lo = r.domain?.lowerBound ?? .distantPast, hi = r.domain?.upperBound ?? .distantFuture
            let nights = restingHeartRate.filter { $0.date >= lo && $0.date <= hi }
            let guide = rangeGuide(side, r)
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
            let guide = windowGuide(side, w)
            let dots = w.shown.compactMap { r in w.heartRate[r.start].map { KeyMetricDot(id: r.id, x: r.mid, y: $0) } }
            let at = selectedWindow(side, w).flatMap { w.heartRate[$0.start] }
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

    /// Five rows around the selected reading.
    @ViewBuilder
    private func readingsTable(_ side: MetricInsightMetric, model: Shown) -> some View {
        let format = formatter(side)
        let rows: [(String, String, String)] = {
            switch model {
            case .range(let r):
                let at = selectedReading(side, r).flatMap { s in r.window.firstIndex { $0.day == s.day } } ?? r.window.count - 1
                let lo = max(0, min(at - 2, r.window.count - 5))
                return r.window.dropFirst(lo).prefix(5).map { reading in
                    let p = KeyMetricBands.placement(reading.value, day: reading.day, band: r.band, verdicts: r.verdicts)
                    return (KeyMetricDates.short(reading.date, includeYear: false), format.text(reading.value),
                            r.band.flatMap { KeyMetricScreenCopy.placement(p, kind: $0.kind) } ?? "")
                }
            case .windows(let w):
                let at = selectedWindow(side, w).flatMap { s in w.shown.firstIndex { $0.id == s.id } } ?? w.shown.count - 1
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
            contextFilter: { if case .windows(let w) = model { return w.filter.name } else { return nil } }(),
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
        var loadedToday: [MetricInsightMetric: Double] = [:]
        for side in entry.metrics {
            let series = await series(side, today: today)
            guard !Task.isCancelled else { return }
            loadedReadings[side] = KeyMetricHistory.measured(series, for: side, today: today)
            // A day metric leaves today out of the charts; its value so far is the Today view's headline.
            if side.period == .day,
               let now = KeyMetricHistory.measured(series, keepsZero: side.keepsZero).first(where: { $0.day == today }) {
                loadedToday[side] = now.value
            }
        }
        todayValues = loadedToday
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
                .padding(.bottom, NoopMetrics.tabBarClearance)
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

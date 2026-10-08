import SwiftUI
import StrandAnalytics
import StrandDesign
import WhoopStore

// MARK: - Heart rate day and Deep Timeline (full-day, full-resolution metric viewer) — #575
//
// Two pages share this view and its reads.
//
// The Heart rate day page (`showsActivityTimeline: true`, Today's heart-rate card) is a glance: the day's
// heart rate on a real clock axis (kit `IntradayChart`: gaps break the line, sleep / workout / no-signal
// spans as bands, the resting rule, a scrub that drives the `ValueReadout`), the activity ribbon on the
// same axis inside the same card, the day's numbers, and rows into the deeper pages (`HeartRateDaySections`).
// Tapping a stretch's "Show on the heart rate graph" narrows the window to it.
//
// The Deep Timeline (`showsActivityTimeline: false`) is the zoomable whole-day line for one metric, down to
// the raw per-second signal. The hard problem — never drawing ~86k points for a worn 24h — is solved in
// the read layer (`Repository.timelineSeries` picks coarse SQL buckets at day scale and raw seconds when
// zoomed in), so this screen only ever receives ~targetPoints points regardless of zoom. It keeps
// `OverviewHRChart` for pinch/drag zoom (macOS adds scroll-to-zoom), with the main night's sleep band and a
// sport glyph at each workout (#979), and a touch-and-hold scrub that drives the page's readout.

struct FullDayChartView: View {
    @EnvironmentObject var repo: Repository

    /// The day this timeline is showing (its real calendar midnight). Defaults to the logical day so an
    /// after-midnight open still lands on the night the user is living, not an empty new calendar day (#144).
    /// Mutable so the user can step back through previous days (#597 — was today-only with no way back).
    @State private var dayStart: Date
    /// True once we've done the one-shot "open on the most recent day with data" jump (or the caller pinned
    /// an explicit day, in which case we never override it). Stops the jump from fighting manual navigation.
    @State private var didLandOnLatest: Bool

    /// True for the Heart rate day page: heart rate only, with the inferred-activity timeline beneath it.
    /// False keeps the multi-metric Deep Timeline exactly as it was.
    private let showsActivityTimeline: Bool

    /// `initialMetric` opens the timeline on a given signal (the Skin Temperature and Blood Oxygen pages link
    /// here to show every reading); heart rate stays the default.
    init(dayStart: Date? = nil, showsActivityTimeline: Bool = false,
         initialMetric: Repository.TimelineMetric = .hr) {
        _dayStart = State(initialValue: dayStart ?? Repository.logicalDayStart(Date()))
        _didLandOnLatest = State(initialValue: dayStart != nil)
        _metric = State(initialValue: initialMetric)
        self.showsActivityTimeline = showsActivityTimeline
    }

    /// What the Heart rate day page shows under the graph. Owns loading: stored results first, then the live
    /// read, coalescing refreshes (see `DayTimelineModel`).
    @StateObject private var timeline = DayTimelineModel()
    /// The stretch opened for a closer look and a verdict.
    @State private var openStretch: StretchSheetInput? = nil

    @State private var metric: Repository.TimelineMetric = .hr
    /// The pills offered for the active device. A WHOOP strap never fills the Oura ring's movement track, so
    /// it is only listed once the registry says the active device is a ring.
    @State private var availableMetrics: [Repository.TimelineMetric] =
        Repository.TimelineMetric.allCases.filter { $0 != .ouraMovement }
    // Imperial/Metric temperature preference (#101) — mirrors MetricExplorerView so skin temp here
    // respects the same °C/°F override instead of always showing Celsius.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    private var temperatureUnit: TemperatureUnit {
        let system = UnitSystem(rawValue: unitSystemRaw) ?? .metric
        return UnitPrefs.resolveTemperature(system: system, override: temperatureRaw)
    }
    /// "Owned only" scoped the empty-state copy to the active device (#574); it never swapped reads, so its
    /// toggle is gone (the "Other sources" disclosure is in the Deep Timeline's About). Kept in the read key.
    @State private var ownedOnly = true
    /// What the source row calls the owned source: the active device's registry display name (nickname,
    /// else "Brand Model"), so an active Oura ring reads "Oura …" over the ring's own series instead of
    /// the strap label this row shipped with. `nil` (no registry row) keeps the legacy "My WHOOP".
    @State private var sourceName: String? = nil
    /// True when the active strap is a 5.0/MG. Its SpO₂ track is the strap's own overnight estimate (#623
    /// used to call that track "unsupported", because it read only the 4.0's raw red/IR table), so an empty
    /// window there means the strap's sleep-only schedule, not a missing channel.
    @State private var strapIsWhoop5 = false

    @State private var series: Repository.TimelineSeries = .empty
    // #979 spin-off — day annotations, mirroring the classic Today's Overview HR markers: the main
    // night's band (labelled with its duration) and each workout's sport glyph. Day-scoped facts, so
    // they're loaded per shown day (NOT per zoom window — the chart clamps them into the visible
    // window itself), keeping the zoom/pan re-read path untouched.
    @State private var sleepSpan: OverviewHRChart.SleepSpan? = nil
    @State private var workoutSpans: [OverviewHRChart.WorkoutSpan] = []
    /// The visible window the chart's gestures mutate. nil → full day (the chart falls back to `dayBounds`).
    @State private var zoomDomain: ClosedRange<Date>? = nil
    @State private var loading = true

    /// The full clamp the zoom window can never escape — the selected calendar day.
    private var dayBounds: ClosedRange<Date> {
        dayStart...dayStart.addingTimeInterval(86_400)
    }

    /// #986: a continuous left-drag can scroll back to the shown day plus the two before it (a rolling
    /// 3-day window), so older HR is reachable by dragging, not only the day-stepper. Deliberately bounded
    /// so one drag can't fling through weeks. The default view is still exactly one day (xRange: dayBounds);
    /// this only widens the pan clamp, and the data reload keys on the visible window so panned-to days load.
    private var panBounds: ClosedRange<Date> {
        dayStart.addingTimeInterval(-2 * 86_400)...dayBounds.upperBound
    }

    /// The currently-visible window (zoomed or the whole day).
    private var visibleWindow: ClosedRange<Date> { zoomDomain ?? dayBounds }

    // MARK: Heart rate day state (presentation of reads made below)

    /// The decoded activity, derived once per document (`DayActivitySnapshot`).
    @State private var activity = DayActivitySnapshot.empty
    /// The day's 5-minute buckets with their lowest and highest sample (#2032), for the true Low / High and
    /// the faint min–max envelope at day scale. The same read the Today heart-rate card makes.
    @State private var hrDayBuckets: [HRBucket] = []
    /// The day's resting heart rate (the nightly score's own number).
    @State private var restingHr: Int?
    /// The server's walking and strap-signal readings for the shown day.
    @State private var walking: WalkingDayReading?
    @State private var walkingLoaded = false
    @State private var strap: StrapSignalDay?
    @State private var strapLoaded = false
    /// True once the open-on-latest-day decision is made, so the page never shows Today's empty state and
    /// then jumps to the day that has data.
    @State private var landingDecided = false
    /// Bumped by `zoomTo`, so the page scrolls back up to the graph it just narrowed.
    @State private var zoomRequest = 0
    /// The Deep Timeline's scrub selection (its readout follows it).
    @State private var deepSelection: Date?

    private static let chartAnchor = "fullDayChart.chart"

    var body: some View {
        Group {
            if showsActivityTimeline { heartRateDayPage } else { deepTimelinePage }
        }
        .task(id: taskKey) { await reload() }
        .task(id: annotationKey) { await reloadAnnotations() }
        .task(id: annotationKey) {
            guard showsActivityTimeline else { return }
            timeline.request(dayStart: dayStart, repo: repo)
        }
        .task(id: annotationKey) {
            guard showsActivityTimeline else { return }
            await reloadDayExtremes()
        }
        .task(id: Int(dayStart.timeIntervalSince1970)) {
            guard showsActivityTimeline else { return }
            await reloadWalking()
        }
        .task(id: Int(dayStart.timeIntervalSince1970)) {
            guard showsActivityTimeline else { return }
            await reloadStrapSignal()
        }
        .onReceive(timeline.$activityContext) { activity = DayActivitySnapshot(document: $0) }
        #if DEBUG
        .task(id: "\(timeline.statesBusy)|\(timeline.activityBusy)") {
            guard (try? await Task.sleep(nanoseconds: 5_000_000_000)) != nil else { return }
            demoAutoOpen()
        }
        #endif
        .sheet(item: $openStretch) { input in
            StretchDetailSheet(input: input, deviceId: repo.deviceId, onZoom: zoomTo)
                .environmentObject(repo)
        }
        .task { await landOnLatestDayIfNeeded() }
        .task(id: metric) { await resolveMetricUnsupported() }   // #623
        .task(id: repo.deviceId) {
            sourceName = repo.activeDeviceDisplayName()
            availableMetrics = repo.timelineMetrics()
            if !availableMetrics.contains(metric) { metric = .hr }
        }
        .onChangeCompat(of: metric) { _ in deepSelection = nil }
    }

    /// The real layout, redacted, until the landing decision and the shown day's first read are in.
    private var pageReady: Bool { landingDecided && !(loading && series.points.isEmpty) }

    private var statColumns: Int {
        #if os(macOS)
        return 4
        #else
        return 2
        #endif
    }

    // MARK: Heart rate day page

    private var heartRateDayPage: some View {
        ScreenScaffold(title: "Heart rate", titleDisplay: .navigationBar, isLoading: !pageReady,
                       lockHorizontalScroll: true) {
            ScrollViewReader { proxy in
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    dayNav
                    #if DEBUG
                    if !demoHidesGraph {
                        heartRateChartBlock.id(Self.chartAnchor)
                        StatGrid(hrStatItems, columns: statColumns, isLoading: !pageReady)
                    }
                    #else
                    heartRateChartBlock.id(Self.chartAnchor)
                    StatGrid(hrStatItems, columns: statColumns, isLoading: !pageReady)
                    #endif
                    #if DEBUG
                    if !DemoLayout.hidesActivity { activitySections }
                    #else
                    activitySections
                    #endif
                    AboutDisclosure("About heart rate", paragraphs: heartRateDayAbout)
                }
                .onChangeCompat(of: zoomRequest) { _ in
                    withAnimation(StrandMotion.interactive) { proxy.scrollTo(Self.chartAnchor, anchor: .top) }
                }
            }
        }
    }

    @ViewBuilder private var activitySections: some View {
        HeartRateDayActivitySection(snapshot: activity, isBusy: timeline.activityBusy, timeline: timeline,
                                    onZoom: zoomTo)
            .id(Int(dayStart.timeIntervalSince1970))
        HeartRateDayMoreSection(dayStart: dayStart, window: visibleWindow, snapshot: activity, timeline: timeline,
                                deviceId: repo.deviceId, walking: walking, walkingLoaded: walkingLoaded,
                                strap: strap, strapLoaded: strapLoaded, onZoom: zoomTo)
    }

    private var heartRateChartBlock: some View {
        let window = visibleWindow
        let samples = hrSamples
        let hasPoints = samples.contains { window.contains($0.time) }
        let state: ChartState = !pageReady ? .loading
            : hasPoints ? .ready
            : loading ? .loading
            : .empty(String(localized: "No heart rate recorded"))
        let snapshot = activity
        let workouts = workoutSpans
        let sleep = sleepSpan
        return HeartRateDayChartBlock(
            samples: samples,
            bucketSeconds: series.isRaw ? 5 : max(1, series.bucketSeconds),
            resolution: series.points.isEmpty ? nil : resolutionSubtitle,
            window: window,
            zoomed: zoomDomain != nil,
            bands: hrBands,
            // The resting rule is named in the legend rather than labelled in the plot, where its label sat on
            // the evening's line (the value itself is in the stat grid).
            references: restingHr.map { [ChartReference(Double($0))] } ?? [],
            state: state,
            lanes: ribbonLanes,
            legend: hrLegend,
            isLoading: !pageReady,
            context: { date in
                if workouts.contains(where: { $0.start <= date && date <= $0.end }) { return String(localized: "Workout") }
                if let ep = snapshot.episode(at: date) { return ep.label }
                if let sleep, sleep.start <= date, date <= sleep.end { return String(localized: "Asleep") }
                return nil
            },
            onRibbonTap: { _, date in
                if let ep = snapshot.episode(at: date) { open(.activity(ep)) }
            },
            onResetZoom: { withAnimation(StrandMotion.interactive) { zoomDomain = nil } }
        )
    }

    /// The line's samples; at day scale each 5-minute bucket carries its lowest and highest sample for the
    /// envelope (the same buckets the line averages, so the two never disagree).
    private var hrSamples: [IntradayChart.Sample] {
        let extremes: [Int: HRBucket] = (!series.isRaw && series.bucketSeconds == 300)
            ? Dictionary(hrDayBuckets.map { ($0.ts, $0) }, uniquingKeysWith: { a, _ in a }) : [:]
        return displayPoints.map { p in
            let b = extremes[Int(p.date.timeIntervalSince1970)]
            return IntradayChart.Sample(time: p.date, value: p.value, low: b?.minBpm, high: b?.maxBpm)
        }
    }

    /// Sleep, workouts and no-signal time as spans behind the line. No-signal time comes from the server's
    /// strap reading when there is one, else from the decoder's off-wrist stretches.
    private var hrBands: [IntradayChart.Band] {
        var bands: [IntradayChart.Band] = []
        if let s = sleepSpan {
            bands.append(.init(id: "sleep", start: s.start, end: s.end, color: ActivityFamily.asleep.color,
                               label: String(localized: "Asleep")))
        }
        for (i, w) in workoutSpans.enumerated() {
            bands.append(.init(id: "workout-\(i)", start: w.start, end: w.end, color: StrandPalette.effortColor,
                               label: String(localized: "Workout")))
        }
        if let strap, !strap.spans.isEmpty {
            for span in strap.spans where (span.state == .offWrist || span.state == .sensorDropout) && span.end - span.start >= 120 {
                bands.append(.init(id: "gap-\(span.start)", start: Date(timeIntervalSince1970: TimeInterval(span.start)),
                                   end: Date(timeIntervalSince1970: TimeInterval(span.end)),
                                   color: StrandPalette.textTertiary, label: span.state.displayName, hatched: true))
            }
        } else {
            for (i, span) in activity.offWristSpans().enumerated() {
                bands.append(.init(id: "off-\(i)", start: span.start, end: span.end, color: StrandPalette.textTertiary,
                                   label: ActivityFamily.offWrist.title, hatched: true))
            }
        }
        return bands
    }

    /// The activity lane, then a lane for walks and for strap signal when the server has read them.
    private var ribbonLanes: [TimelineRibbon.Lane] {
        // A document can exist and hold nothing (a day with no motion): that is the empty lane, not a blank one.
        let state: ChartState = !activity.segments.isEmpty ? .ready
            : timeline.activityBusy ? .loading
            : .empty(String(localized: "No motion data"))
        var lanes = [TimelineRibbon.Lane(id: "activity", symbol: "figure.walk", title: String(localized: "Activity"),
                                         segments: activity.segments, ticks: activity.ticks, state: state)]
        if let walking, !walking.bouts.isEmpty { lanes.append(WalkingLane.lane(walking, loaded: true)) }
        if let strap, !strap.spans.isEmpty { lanes.append(StrapSignalLane.lane(strap, loaded: true, quietGood: true)) }
        // One lane needs no glyph to say which it is.
        if lanes.count == 1 { lanes[0].symbol = nil }
        return lanes
    }

    /// One legend for the card: the kinds of activity on screen, then the spans behind the line that are not
    /// labelled inside it.
    private var hrLegend: [ChartLegendItem] {
        let window = visibleWindow
        var items = activity.families(in: window).map(\.legendItem)
        var seen = Set(items.map(\.label))
        func add(_ item: ChartLegendItem) {
            guard !seen.contains(item.label) else { return }
            seen.insert(item.label)
            items.append(item)
        }
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        for band in hrBands {
            let start = max(band.start, window.lowerBound), end = min(band.end, window.upperBound)
            guard end > start, let label = band.label else { continue }
            // The chart labels a band inside it when the band is wide enough for the word (IntradayChart's
            // rule, at its assumed 300 pt plot); only the others need the legend.
            let width = span > 0 ? end.timeIntervalSince(start) / span * 300 : 0
            let fitsInside = !band.hatched && width >= Double(label.count) * 6.5 + 12
            if !fitsInside { add(ChartLegendItem(band.hatched ? .hatched(band.color) : .band(band.color), label)) }
        }
        if restingHr != nil { add(ChartLegendItem(.line(NaraChartStyle.referenceColor, dashed: true), String(localized: "Resting"))) }
        return items
    }

    /// Resting, Average, Low and High for the visible window. Low and High are single samples (#2032), not
    /// the 5-minute means the line draws; the average is of the line's points.
    private var hrStatItems: [StatItem] {
        let window = visibleWindow
        let points = series.points.filter { window.contains($0.date) }
        let average = points.isEmpty ? nil : points.map(\.value).reduce(0, +) / Double(points.count)
        let buckets = hrDayBuckets.filter { window.contains(Date(timeIntervalSince1970: TimeInterval($0.ts))) }
        let low: (Double, Date)? = buckets.min(by: { $0.minBpm < $1.minBpm })
            .map { ($0.minBpm, Date(timeIntervalSince1970: TimeInterval($0.ts))) }
            ?? points.min(by: { $0.value < $1.value }).map { ($0.value, $0.date) }
        let high: (Double, Date)? = buckets.max(by: { $0.maxBpm < $1.maxBpm })
            .map { ($0.maxBpm, Date(timeIntervalSince1970: TimeInterval($0.ts))) }
            ?? points.max(by: { $0.value < $1.value }).map { ($0.value, $0.date) }
        let bpm = { (v: Double) in String(Int(v.rounded())) }
        return [
            StatItem(String(localized: "Resting"), value: restingHr.map(String.init), unit: "bpm"),
            StatItem(String(localized: "Average"), value: average.map(bpm), unit: "bpm"),
            StatItem(String(localized: "Low"), value: low.map { bpm($0.0) }, unit: "bpm",
                     detail: low.map { StretchFormat.clock($0.1) }),
            StatItem(String(localized: "High"), value: high.map { bpm($0.0) }, unit: "bpm",
                     detail: high.map { StretchFormat.clock($0.1) }),
        ]
    }

    private var heartRateDayAbout: [String] {
        [
            String(localized: "The line is your heart rate through the day: an average over a few minutes for the whole day, every second when you look closer. A break in the line is time the strap recorded nothing; hatched time had no trustworthy signal."),
            String(localized: "Low and high are the lowest and highest single readings, not the averages the line draws. Resting is your resting heart rate for the day."),
            String(localized: "The bar under the graph is what the strap's motion suggests you were doing. Hatched stretches are less sure, and ticks under the bar are position changes. A wrist can't see height, so sitting and standing are best guesses."),
            String(localized: "Tap the bar to see a stretch up close and say whether it is right. Show on the heart rate graph narrows the graph to that stretch."),
        ]
    }

    // MARK: Deep Timeline page

    private var deepTimelinePage: some View {
        ScreenScaffold(title: "Deep Timeline", titleDisplay: .navigationBar, isLoading: !landingDecided) {
            metricPills
            dayNav
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                #if DEBUG
                if !demoHidesGraph { deepReadout }
                #else
                deepReadout
                #endif
                chartCard
            }
            StatGrid(deepStatItems, columns: 3, isLoading: loading && series.points.isEmpty)
            AboutDisclosure("About the Deep Timeline", paragraphs: deepTimelineAbout)
        }
    }

    private var deepReadout: some View {
        let points = displayPoints
        let selected = deepSelection.flatMap { date in
            ChartSelection.nearestIndex(to: date, in: points.map(\.date)).map { points[$0] }
        }
        let shown = selected ?? points.last
        let source = sourceName ?? String(localized: "My WHOOP")
        let context = selected == nil
            ? (series.points.isEmpty ? source : "\(source) · \(resolutionSubtitle)")
            : nil
        let content = ReadoutContent(
            dateLine: shown.map { ReadoutContent.dateLine($0.date, period: .time) }
                ?? ReadoutContent.dateLine(dayStart, period: .day),
            value: shown.map { format($0.value) },
            unit: shown == nil ? nil : axisUnit,
            context: context)
        return ValueReadout(content, isScrubbing: selected != nil, isLoading: loading && series.points.isEmpty)
            .overlay(alignment: .bottomTrailing) {
                if zoomDomain != nil && selected == nil {
                    Button("Whole day") { withAnimation(StrandMotion.interactive) { zoomDomain = nil } }
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                        .buttonStyle(.plain)
                        .frame(minHeight: NoopMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
            }
    }

    private var deepStatItems: [StatItem] {
        let v = displayPoints.map(\.value)
        let unit = axisUnit
        guard !v.isEmpty else {
            return [StatItem(String(localized: "Low"), value: nil), StatItem(String(localized: "Average"), value: nil),
                    StatItem(String(localized: "High"), value: nil)]
        }
        return [
            StatItem(String(localized: "Low"), value: format(v.min() ?? 0), unit: unit),
            StatItem(String(localized: "Average"), value: format(v.reduce(0, +) / Double(max(1, v.count))), unit: unit),
            StatItem(String(localized: "High"), value: format(v.max() ?? 0), unit: unit),
        ]
    }

    private var deepTimelineAbout: [String] {
        var paragraphs: [String] = []
        #if os(macOS)
        paragraphs.append(String(localized: "Scroll to zoom and drag to pan. Double-click to go back to the whole day."))
        #else
        paragraphs.append(String(localized: "Pinch to zoom, drag to pan, and touch and hold to read a value. Double-tap to go back to the whole day."))
        #endif
        paragraphs.append(String(localized: "The line is averaged over a few minutes for a whole day and shows the raw seconds when you zoom in. A break in the line is time with no readings."))
        switch metric {
        case .spo2 where strapIsWhoop5:
            paragraphs.append(String(localized: "Your strap measures SpO₂ only while you sleep, so there are no readings for this part of the day. Check the night around it."))
        case .respiration:
            paragraphs.append(String(localized: "Breathing is estimated from your heartbeat rhythm, and nothing steady enough was recorded in this window. It reads best while you are still, such as asleep."))
        case .sdnn:
            paragraphs.append(String(localized: "SDNN needs several minutes of clean heartbeat timing, and this window doesn’t have enough."))
        default:
            break
        }
        paragraphs.append(String(localized: "Other sources don’t offload raw per-second data on-device."))
        return paragraphs
    }

    private func open(_ target: StretchTarget) {
        openStretch = StretchSheetInput(target: target, document: timeline.activityContext,
                                        segments: timeline.dayStates)
    }

    private func zoomTo(_ range: ClosedRange<Date>) {
        withAnimation(StrandMotion.interactive) { zoomDomain = range }
        zoomRequest += 1
    }

    #if DEBUG
    // Render hooks for simulator screenshots, where a page cannot be scrolled or tapped from outside the app.
    // `--demo-hr-sections` leaves the graph off, `--demo-lists-only` also drops the cards above each list,
    // `--demo-skip-activity` leaves out the whole activity section, and
    // `--demo-open-stretch=activity:2` (or `strap:0`) opens the nth newest stretch once the page has loaded.
    @State private var demoOpened = false

    private var demoHidesGraph: Bool {
        showsActivityTimeline && (CommandLine.arguments.contains("--demo-hr-sections") || DemoLayout.listsOnly)
    }

    private func demoAutoOpen() {
        let prefix = "--demo-open-stretch="
        guard showsActivityTimeline, !demoOpened,
              let arg = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }),
              !timeline.statesBusy, !timeline.activityBusy else { return }
        let parts = arg.dropFirst(prefix.count).split(separator: ":")
        let index = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        switch parts.first {
        case "activity":
            guard let doc = timeline.activityContext else { return }
            let stretches = ActivityContextEpisodes.build(doc.runs)
                .filter { $0.durationSeconds >= 60 }.reversed() as [ActivityEpisode]
            guard stretches.indices.contains(index) else { return }
            demoOpened = true
            open(.activity(stretches[index]))
        case "strap":
            let stretches = timeline.dayStates.sorted { $0.start > $1.start }
            guard stretches.indices.contains(index) else { return }
            demoOpened = true
            open(.strap(stretches[index]))
        default:
            return
        }
    }
    #endif

    /// Which strap family is active, so an empty SpO₂ window can be explained truthfully (#623). A 5.0/MG
    /// does send SpO₂, as its own estimate while the wearer sleeps, and the SpO₂ track plots it; it is never
    /// "unsupported". Respiration is likewise never called unsupported: a strap with no raw breathing
    /// channel gets a rate estimated from the heartbeat rhythm. Re-resolves when the metric changes.
    private func resolveMetricUnsupported() async {
        strapIsWhoop5 = await repo.activeStrapIsWhoop5WithEvidence()
    }

    /// Annotations re-read only when the shown day changes or fresh strap data lands — deliberately NOT
    /// on zoom (see `sleepSpan` above), so scrubbing/pinching never re-queries sleeps/workouts.
    private var annotationKey: String {
        "\(Int(dayStart.timeIntervalSince1970))|\(repo.refreshSeq)"
    }

    /// Re-read whenever the metric, the day, the source scope, the settled zoom window, or fresh strap
    /// data changes. The window is bucketed to whole seconds so micro-jitter during a drag doesn't thrash
    /// the DB — the chart redraws smoothly from the in-hand domain while the data settles.
    private var taskKey: String {
        let lo = Int(visibleWindow.lowerBound.timeIntervalSince1970)
        let hi = Int(visibleWindow.upperBound.timeIntervalSince1970)
        return "\(metric.rawValue)|\(Int(dayStart.timeIntervalSince1970))|\(ownedOnly)|\(lo)|\(hi)|\(repo.refreshSeq)"
    }

    // MARK: Controls

    private var metricPills: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            SegmentedPillControl(availableMetrics, selection: $metric) { $0.title }
                .padding(.vertical, NoopMetrics.spaceHalf)
        }
    }

    /// Day stepper — move the whole page back/forward a day so a user can reach the days that actually hold
    /// their data, not just today (#597). Forward is clamped at today (no future days).
    private var dayNav: some View {
        PeriodStepper(title: dayLabel, subtitle: daySubtitle,
                      canGoBack: true, canGoForward: !isOnLatestDay,
                      onBack: { stepDay(-1) }, onForward: { stepDay(1) })
    }

    private var isOnLatestDay: Bool { dayStart >= Repository.logicalDayStart(Date()) }

    /// Step the shown day by `delta` days, clamped so you can never go past today, and drop any zoom so the
    /// new day opens at full-day scale.
    private func stepDay(_ delta: Int) {
        let next = dayStart.addingTimeInterval(Double(delta) * 86_400)
        if delta > 0 && next > Repository.logicalDayStart(Date()) { return }
        withAnimation(StrandMotion.interactive) {
            dayStart = next
            zoomDomain = nil
        }
    }

    private var isTodayOrYesterday: Bool {
        let today = Repository.logicalDayStart(Date())
        return Calendar.current.isDate(dayStart, inSameDayAs: today)
            || Calendar.current.isDate(dayStart, inSameDayAs: today.addingTimeInterval(-86_400))
    }

    private var dayLabel: String {
        let today = Repository.logicalDayStart(Date())
        if Calendar.current.isDate(dayStart, inSameDayAs: today) { return String(localized: "Today") }
        if Calendar.current.isDate(dayStart, inSameDayAs: today.addingTimeInterval(-86_400)) { return String(localized: "Yesterday") }
        return ReadoutContent.dateLine(dayStart, period: .day)
    }

    /// The date beside "Today" / "Yesterday"; another day's title is already its date.
    private var daySubtitle: String? {
        isTodayOrYesterday ? ReadoutContent.dateLine(dayStart, period: .day) : nil
    }

    // MARK: Chart (Deep Timeline)

    @ViewBuilder private var chartCard: some View {
        NoopCard {
            Group {
                if loading && series.points.isEmpty {
                    ChartPlaceholder(height: NoopMetrics.chartHeightPrimary)
                } else if series.points.isEmpty {
                    EmptyChartMessage(String(localized: "Nothing recorded in this window"),
                                      height: NoopMetrics.chartHeightPrimary)
                } else {
                    chart
                }
            }
        }
    }

    /// `series.points` in the DISPLAYED unit (#101) — for every metric but skin temp this is just the raw
    /// points; skin temp is stored/read in °C, so when the user has °F selected the chart's line, y-axis
    /// domain AND gridlines (which plot the raw value, not `format`'s output) need the converted number,
    /// not just the readout label. The timeline series is the ABSOLUTE skin temp (`skinTempCelsius`), so
    /// the absolute °C→°F conversion (×9/5 + 32) is the right one here — not a deviation rescale.
    private var displayPoints: [TrendPoint] {
        guard metric == .skinTemp, temperatureUnit == .fahrenheit else { return series.points }
        return series.points.map {
            TrendPoint(date: $0.date, value: UnitFormatter.celsiusToFahrenheit($0.value))
        }
    }

    /// The displayed points with a segment per unbroken run, so the line lifts across a gap instead of
    /// drawing a straight ramp through time the strap recorded nothing.
    private var segmentedPoints: [TrendPoint] {
        let pts = displayPoints
        let ids = Self.gapSegments(dates: pts.map(\.date), bucketSeconds: series.bucketSeconds, isRaw: series.isRaw)
        return zip(pts, ids).map { TrendPoint(date: $0.date, value: $0.value, segment: $1) }
    }

    /// Run ids for a timeline series. Bucketed series break where a bucket is skipped (`hrGapSegments`). Raw
    /// series (one row per reading) break where a step is more than three times the series' typical step, and
    /// never under five seconds, so a dropped second of 1 Hz heart rate does not split the line. Pure.
    static func gapSegments(dates: [Date], bucketSeconds: Int, isRaw: Bool) -> [String] {
        let ts = dates.map { Int($0.timeIntervalSince1970.rounded()) }
        guard ts.count > 1 else { return ts.map { _ in "0" } }
        if !isRaw, bucketSeconds > 1 { return hrGapSegments(bucketTs: ts, bucketSeconds: bucketSeconds) }
        let steps = zip(ts.dropFirst(), ts).map { $0 - $1 }.filter { $0 > 0 }.sorted()
        let typical = steps.isEmpty ? 1 : steps[steps.count / 2]
        return hrGapSegments(bucketTs: ts, bucketSeconds: max(5, typical * 3))
    }

    /// How the Deep Timeline draws the current metric: a percentage read in short windows as points on a
    /// fixed axis, a non-negative magnitude (wrist motion, ring movement) as bars from zero, the band's sleep
    /// state codes as points (a code is a level, not a quantity to join), everything else as a line.
    private var chartMark: OverviewHRChart.Mark {
        switch metric {
        case .spo2: return Self.spo2IsPercent(displayPoints.last?.value) ? .points : .line
        case .motion, .ouraMovement: return .bars
        case .bandSleepState: return .points
        default: return .line
        }
    }

    private var chart: some View {
        OverviewHRChart(
            points: segmentedPoints,
            // #979 spin-off — the same sleep-band + workout-glyph layers the classic Today feeds. Passed
            // on EVERY metric track (they're time annotations, so "when was I asleep / training" reads
            // against skin temp or HRV just as it does against HR); the glyph anchors at the shown
            // metric's peak inside the workout window, and the chart clamps both into the zoom window.
            sleep: sleepSpan,
            workouts: workoutSpans,
            gradient: gradientFor(metric),
            valueRange: valueRange(displayPoints),
            xRange: dayBounds,
            height: NoopMetrics.chartHeightPrimary,
            // #979 spin-off — iPhone touch scrub: hold to pin the rule, drag to read values under the
            // finger; it drives the page's readout (the Mac pointer hover does the same).
            touchScrub: true,
            workoutTint: StrandPalette.effortColor,
            zoomDomain: $zoomDomain,
            // #986: Deep Timeline pans across a rolling 3-day window.
            zoomBounds: panBounds,
            valueFormat: { format($0) },
            dateFormat: { Self.timeFmt.string(from: $0) },
            mark: chartMark,
            unit: axisUnit,
            color: seriesColor(metric),
            accessibilityTitle: metric.title,
            selection: $deepSelection
        )
        #if os(macOS)
        // macOS has no pinch here, so wheel/trackpad scroll zooms about the cursor-agnostic centre.
        // (DeepTimeline owns the scroll handler; the chart's own gesture covers drag-pan.)
        .modifier(ScrollToZoomModifier(
            current: { visibleWindow },
            bounds: panBounds,   // #986: match the widened pan clamp
            apply: { zoomDomain = $0 }
        ))
        #endif
    }

    // MARK: Read

    /// One-shot on first open: if today has no data but an earlier day does (the classic just-synced-history
    /// case, #597), land the timeline on that most-recent day so the user sees their data instead of an empty
    /// today. Skipped when the caller pinned an explicit day, and never fights manual navigation afterwards.
    private func landOnLatestDayIfNeeded() async {
        defer { landingDecided = true }
        guard !didLandOnLatest else { return }
        didLandOnLatest = true
        if let latest = await repo.latestDataDayStart(), latest < dayStart {
            withAnimation(StrandMotion.interactive) { dayStart = latest }
        }
    }

    private func reload() async {
        loading = true
        let window = visibleWindow
        let result = await repo.timelineSeries(
            metric: metric,
            from: Int(window.lowerBound.timeIntervalSince1970),
            to: Int(window.upperBound.timeIntervalSince1970),
            targetPoints: 600
        )
        // Guard against a stale task landing after the user moved on.
        guard !Task.isCancelled else { return }
        series = result
        loading = false
    }

    /// #979 spin-off — load the shown day's sleep + workouts and scope them EXACTLY like the classic
    /// Today's Overview HR markers: `allSleepSessions` (imported AND on-device computed sources — a
    /// Bluetooth-only user's sleep lives under the computed source), longest overlapping block = the main
    /// night, never a nap; `workoutRows` (already dedup/dismiss-filtered) kept where they overlap the day.
    /// The band + duration use the EFFECTIVE onset so a hand-corrected bedtime shows the same band here as
    /// on the Sleep tab (#318). Both repo reads are today-relative, so `days:` walks back far enough from
    /// now to cover the shown day; the +2 pad mirrors TodayView's sleep read (the night straddles midnight).
    private func reloadAnnotations() async {
        let daysBack = max(0, Int(Date().timeIntervalSince(dayStart) / 86_400)) + 2

        let sleepCandidates: [OverviewHRChart.SleepSpan] = await repo.allSleepSessions(days: daysBack)
            .map { s in
                .init(start: Date(timeIntervalSince1970: TimeInterval(s.effectiveStartTs)),
                      end: Date(timeIntervalSince1970: TimeInterval(s.endTs)),
                      label: Self.hoursMinutes(s.endTs - s.effectiveStartTs))
            }
        let workoutCandidates: [OverviewHRChart.WorkoutSpan] = await repo.workoutRows(days: daysBack)
            .map { w in
                .init(start: Date(timeIntervalSince1970: TimeInterval(w.startTs)),
                      end: Date(timeIntervalSince1970: TimeInterval(w.endTs)),
                      symbol: sportSymbol(w.sport))
            }
        guard !Task.isCancelled else { return }
        // The pure, headless-tested selection (StrandDesignTests) — window = the shown DAY, not the zoom.
        sleepSpan = OverviewHRChart.mainSleep(sleepCandidates, overlapping: dayBounds)
        workoutSpans = OverviewHRChart.workouts(workoutCandidates, overlapping: dayBounds)
    }

    /// The Heart rate day page's true Low / High and envelope: the shown day's 5-minute buckets with the
    /// lowest and highest sample in each (#2032), the read the Today heart-rate card makes. Day-scoped, like
    /// the annotations, so a zoom never re-queries; the resting rate is the day's own nightly row.
    private func reloadDayExtremes() async {
        let key = Repository.localDayKey(dayStart)
        restingHr = repo.days.last(where: { $0.day == key })?.restingHr
        let buckets = await repo.hrBuckets(from: Int(dayBounds.lowerBound.timeIntervalSince1970),
                                           to: Int(dayBounds.upperBound.timeIntervalSince1970) - 1,
                                           bucketSeconds: 300)
        guard !Task.isCancelled else { return }
        hrDayBuckets = buckets
    }

    /// The server's walking reading for the shown day (`DayCloudReadings.walking`, the Walking card's load).
    private func reloadWalking() async {
        walking = nil
        walkingLoaded = false
        defer { if !Task.isCancelled { walkingLoaded = true } }
        let reading = await DayCloudReadings.walking(dayStart: dayStart)
        guard !Task.isCancelled else { return }
        walking = reading
    }

    /// The server's strap-signal reading for the shown day, cached copy first (the Strap signal card's load).
    private func reloadStrapSignal() async {
        strap = nil
        strapLoaded = false
        defer { if !Task.isCancelled { strapLoaded = true } }
        await DayCloudReadings.strapSignal(dayStart: dayStart) { reading in
            guard !Task.isCancelled else { return }
            strap = reading
        }
    }

    /// "H:MM" for a duration in seconds (e.g. a 6h06m night → "6:06") — mirrors TodayView.hoursMinutes
    /// so the band label reads identically on both whole-day charts.
    private static func hoursMinutes(_ seconds: Int) -> String {
        let h = max(0, seconds) / 3600, m = (max(0, seconds) % 3600) / 60
        return "\(h):\(String(format: "%02d", m))"
    }

    // MARK: Presentation helpers

    private var resolutionSubtitle: String {
        guard !series.points.isEmpty else { return "—" }
        if series.derivedFromRR { return String(localized: "Estimated from heartbeat timing") }
        if series.isRaw { return String(localized: "Raw · per second") }
        let m = series.bucketSeconds / 60
        return m >= 1 ? String(localized: "\(m)-minute average")
                      : String(localized: "\(series.bucketSeconds)-second average")
    }

    /// The unit above the value axis and beside the readout's value ("bpm", "°C", "%"); nil when unitless.
    private var axisUnit: String? {
        let u = unitSuffix.trimmingCharacters(in: .whitespaces)
        return u.isEmpty ? nil : u
    }

    private var unitSuffix: String {
        switch metric {
        case .hr: return " bpm"
        case .skinTemp: return UnitFormatter.temperatureUnit(temperatureUnit)   // #101: °C / °F per preference
        // A raw breathing channel (an Oura ring or a 4.0) is unitless on this axis; the rate estimated from
        // the heartbeat rhythm is in breaths per minute.
        case .respiration: return series.derivedFromRR ? " br/min" : ""
        case .hrv, .sdnn: return " ms"
        // Change in the gravity vector between records, in g (the vector's own length is a constant 1 g, so
        // that is not what this plots). spo2/bandSleepState stay unitless (a ratio / a named state).
        case .motion: return " g"
        // Seconds of movement per ~30 s window (the ring's OWN 0x47 activity), so tag it "s".
        case .ouraMovement: return " s"
        // A percentage (the 5/MG's own estimate, or an Oura ring's reading) reads "97%"; the 4.0's red/IR
        // ratio proxy stays unitless. The two never share a chart: a ratio is well under 10 and a percentage
        // is 50 or more (`spo2TimelineValue` gates a single-channel reading to 50...110).
        case .spo2: return Self.spo2IsPercent(displayPoints.last?.value) ? "%" : ""
        case .bandSleepState: return ""
        }
    }

    /// Whether an SpO₂ timeline value is a percentage rather than the 4.0's red/IR ratio proxy.
    static func spo2IsPercent(_ value: Double?) -> Bool { (value ?? 0) >= 50 }

    private func format(_ v: Double) -> String {
        switch metric {
        case .hr, .hrv, .sdnn, .ouraMovement: return String(Int(v.rounded()))
        case .respiration: return series.derivedFromRR ? String(format: "%.1f", v) : String(Int(v.rounded()))
        // `v` already arrives in the displayed unit — callers read from `displayPoints`, which converts
        // skin temp to °F upfront so the chart's own axis (plotted from the same points) agrees. (#101)
        case .skinTemp: return String(format: "%.1f", v)
        case .spo2: return Self.spo2IsPercent(v) ? String(Int(v.rounded())) : String(format: "%.2f", v)
        // Resting wrist motion is a few thousandths of a g; two decimals would read as a flat 0.00.
        case .motion: return String(format: "%.3f", v)
        // #175: name the band's own state at the nearest code so the readout reads "asleep", not "2.0".
        case .bandSleepState: return Self.bandStateLabel(v)
        }
    }

    /// #175: map the band's 0-3 sleep_state code to its word. A bucket-averaged fractional value (when
    /// zoomed out) is rounded to the nearest code — honest for a readout label; the track itself plots the
    /// numeric code. This names the BAND's own reported state, never a stage NOOP derives.
    static func bandStateLabel(_ v: Double) -> String {
        switch Int(v.rounded()) {
        case 0: return String(localized: "wake")
        case 1: return String(localized: "still")
        case 2: return String(localized: "asleep")
        case 3: return String(localized: "up")
        default: return String(Int(v.rounded()))
        }
    }

    /// The value axis's domain. Heart rate gets a floor and a minimum span so a calm day does not fill the
    /// plot like a hard one; SpO₂ as a percentage sits on its fixed 85–100 % scale; magnitudes start at
    /// zero; the band's state codes span their four levels. Everything else is padded so the line never sits
    /// flush against an edge (mirrors MetricExplorer/TodayView).
    private func valueRange(_ pts: [TrendPoint]) -> ClosedRange<Double> {
        let vals = pts.map(\.value)
        guard let lo = vals.min(), let hi = vals.max() else {
            return metric == .hr ? 40...120 : 0...1
        }
        switch metric {
        case .hr:
            let low = min(50, ((lo - 5) / 10).rounded(.down) * 10)
            let high = max(low + 60, ((hi + 5) / 10).rounded(.up) * 10)
            return max(30, low)...high
        case .spo2 where Self.spo2IsPercent(hi):
            return min(85, (lo - 1).rounded(.down))...max(100, hi.rounded(.up))
        case .motion, .ouraMovement:
            return 0...max(hi * 1.1, hi + 0.001)
        case .bandSleepState:
            return -0.3...3.3
        default:
            break
        }
        if hi <= lo { return (lo - 1)...(hi + 1) }
        let pad = (hi - lo) * 0.12
        return (lo - pad)...(hi + pad)
    }

    /// One flat colour per metric (the line's colour; no value gradient).
    private func seriesColor(_ m: Repository.TimelineMetric) -> Color {
        switch m {
        case .hr: return StrandPalette.metricRose
        case .skinTemp: return StrandPalette.metricAmber
        case .hrv: return StrandPalette.metricPurple
        case .spo2: return StrandPalette.metricCyan
        case .sdnn: return StrandPalette.metricCyan
        case .respiration, .motion, .ouraMovement: return StrandPalette.textSecondary
        // #175: the band-state track uses the deep-sleep hue so it reads as a distinct sleep track.
        case .bandSleepState: return StrandPalette.sleepDeep
        }
    }

    private func gradientFor(_ m: Repository.TimelineMetric) -> Gradient {
        switch m {
        case .hr:
            return Gradient(colors: [StrandPalette.metricRose.opacity(0.55), StrandPalette.metricRose])
        case .skinTemp:
            return Gradient(colors: [StrandPalette.strain033.opacity(0.55), StrandPalette.strain033])
        case .hrv, .spo2:
            return Gradient(colors: [StrandPalette.sleepLight.opacity(0.55), StrandPalette.sleepLight])
        case .sdnn:
            return Gradient(colors: [StrandPalette.metricCyan.opacity(0.55), StrandPalette.metricCyan])
        case .respiration, .motion, .ouraMovement:
            return Gradient(colors: [StrandPalette.textSecondary.opacity(0.5), StrandPalette.textSecondary])
        // #175: the band-state track uses the deep-sleep hue so it reads as a distinct sleep track.
        case .bandSleepState:
            return Gradient(colors: [StrandPalette.sleepDeep.opacity(0.55), StrandPalette.sleepDeep])
        }
    }

    /// The selected sample's time for VoiceOver, in the wearer's own clock format.
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.dateStyle = .none; f.timeStyle = .short; return f
    }()
}

#if os(macOS)
import AppKit
// MARK: - macOS scroll-to-zoom
//
// Scroll up (or trackpad pinch on macOS, which arrives as a magnify event the chart already handles) zooms
// in about the window centre; scroll down zooms out toward the day. Kept as a modifier so the platform
// split stays out of the screen body.
private struct ScrollToZoomModifier: ViewModifier {
    let current: () -> ClosedRange<Date>
    let bounds: ClosedRange<Date>
    let apply: (ClosedRange<Date>) -> Void

    func body(content: Content) -> some View {
        content.background(ScrollCatcher { deltaY in
            // Each notch scales by ~1.15; up (positive) zooms in, down zooms out.
            let scale = deltaY > 0 ? 1.15 : (1.0 / 1.15)
            let zoomed = OverviewHRChart.zoomed(current(), scale: scale, anchorFraction: 0.5, bounds: bounds)
            apply(zoomed.upperBound > zoomed.lowerBound ? zoomed : current())
        })
    }
}

/// A transparent NSView that reports scroll-wheel deltaY up the closure. AppKit-only.
private struct ScrollCatcher: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    func makeNSView(context: Context) -> NSView { CatcherView(onScroll: onScroll) }
    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CatcherView)?.onScroll = onScroll
    }
    final class CatcherView: NSView {
        var onScroll: (CGFloat) -> Void
        init(onScroll: @escaping (CGFloat) -> Void) {
            self.onScroll = onScroll
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func scrollWheel(with event: NSEvent) {
            if abs(event.scrollingDeltaY) > 0.5 { onScroll(event.scrollingDeltaY) }
        }
    }
}
#endif

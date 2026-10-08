import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Heart rate day: the pieces under the page shell
//
// The Heart rate day page (`FullDayChartView(showsActivityTimeline: true)`) is a glance: the day's heart rate
// on a real time axis with what the wearer was doing on a ribbon under it, the day's numbers, and rows into
// everything deeper. These are its parts. The data they show is loaded by the page (`DayTimelineModel`, the
// timeline read, the server readings); nothing here reads or writes.

// MARK: Activity snapshot

/// What the day's activity document says, derived once per document so a scrub (which re-renders the chart
/// block many times a second) never rebuilds episodes or totals.
struct DayActivitySnapshot {
    let document: ActivityContextDayDocument?
    /// Ascending by start.
    let episodes: [ActivityEpisode]
    let totals: [FamilyTotal]
    let layout: DayStretchLayout
    /// The activity lane: consecutive episodes of one family joined, low confidence hatched.
    let segments: [TimelineRibbon.Segment]
    let ticks: [Date]
    let positionChangeCount: Int

    static let empty = DayActivitySnapshot(document: nil)

    /// Below this an episode's family colour is drawn hatched: the decoder was not sure.
    static let confidentThreshold = 0.5

    init(document: ActivityContextDayDocument?) {
        self.document = document
        let episodes = document.map { ActivityContextEpisodes.build($0.runs) }?.sorted { $0.start < $1.start } ?? []
        self.episodes = episodes
        // A few seconds the decoder could not read is not a kind of activity worth a row.
        self.totals = (document.map { DayStretchTotals.familyTotals($0, episodes: episodes) } ?? [])
            .filter { !($0.family == .unclear && $0.seconds < 60) }
        self.layout = DayStretchLayout(episodes: episodes)
        self.ticks = (document.map { LanePositionChanges.ticks($0.events) } ?? [])
            .map { Date(timeIntervalSince1970: TimeInterval($0.ts)) }
        self.positionChangeCount = document.map { PositionChanges.all($0.events).count } ?? 0
        self.segments = Self.segments(episodes)
    }

    /// One segment per unbroken stretch of a family (joining across gaps under a minute), so a day is a few
    /// dozen marks rather than hundreds.
    static func segments(_ episodes: [ActivityEpisode]) -> [TimelineRibbon.Segment] {
        var out: [TimelineRibbon.Segment] = []
        var open: (family: ActivityFamily, hatched: Bool, start: Int, end: Int)?
        func close() {
            guard let o = open else { return }
            out.append(.init(id: "a-\(o.start)", start: Date(timeIntervalSince1970: TimeInterval(o.start)),
                             end: Date(timeIntervalSince1970: TimeInterval(o.end)), color: o.family.color,
                             hatched: o.hatched))
            open = nil
        }
        for ep in episodes {
            let family = ActivityFamily.of(ep.label)
            let hatched = family.isNoSignal || ep.confidence < confidentThreshold
            if let o = open, o.family == family, o.hatched == hatched, ep.start - o.end <= 60 {
                open = (family, hatched, o.start, max(o.end, ep.end))
            } else {
                close()
                open = (family, hatched, ep.start, ep.end)
            }
        }
        close()
        return out
    }

    /// The episode covering `date`, if any.
    func episode(at date: Date) -> ActivityEpisode? {
        let ts = Int(date.timeIntervalSince1970)
        var lo = 0, hi = episodes.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let ep = episodes[mid]
            if ts < ep.start { hi = mid - 1 } else if ts >= ep.end { lo = mid + 1 } else { return ep }
        }
        return nil
    }

    /// The families on screen in `window`, longest first, for the legend.
    func families(in window: ClosedRange<Date>, limit: Int = 3) -> [ActivityFamily] {
        let lo = Int(window.lowerBound.timeIntervalSince1970), hi = Int(window.upperBound.timeIntervalSince1970)
        var seconds: [ActivityFamily: Int] = [:]
        for ep in episodes {
            let s = max(ep.start, lo), e = min(ep.end, hi)
            if e > s { seconds[ActivityFamily.of(ep.label), default: 0] += e - s }
        }
        return seconds.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.title < $1.key.title }
            .prefix(limit).map(\.key)
    }

    /// Off-wrist time the decoder read, as spans of at least `minimum` seconds (for the graph's hatching).
    func offWristSpans(minimum: Int = 120) -> [(start: Date, end: Date)] {
        episodes.filter { ActivityFamily.of($0.label) == .offWrist && $0.durationSeconds >= minimum }
            .map { (Date(timeIntervalSince1970: TimeInterval($0.start)), Date(timeIntervalSince1970: TimeInterval($0.end))) }
    }
}

extension ActivityFamily {
    /// Time with no trustworthy reading: drawn hatched, never as a colour of its own.
    var isNoSignal: Bool { self == .offWrist || self == .unclear }

    var legendItem: ChartLegendItem {
        ChartLegendItem(isNoSignal ? .hatched(color) : .swatch(color), title)
    }
}

// MARK: Chart block

/// The readout and the heart-rate card: the graph, the activity ribbon on the same axis, and one legend.
/// Owns the scrub selection, so a scrub re-renders this block and nothing else on the page.
struct HeartRateDayChartBlock: View {
    let samples: [IntradayChart.Sample]
    let bucketSeconds: Int
    /// "5-minute average" / "Raw · per second", the readout's context at rest.
    let resolution: String?
    let window: ClosedRange<Date>
    let zoomed: Bool
    let bands: [IntradayChart.Band]
    let references: [ChartReference]
    let state: ChartState
    let lanes: [TimelineRibbon.Lane]
    let legend: [ChartLegendItem]
    let isLoading: Bool
    /// What the wearer was doing at a moment, for the readout while scrubbing.
    let context: (Date) -> String?
    let onRibbonTap: (String, Date) -> Void
    let onResetZoom: () -> Void

    @State private var selected: Date?

    static let axis = ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 40, clampTo: 30...230))

    private var windowed: [IntradayChart.Sample] {
        samples.filter { $0.value.isFinite && window.contains($0.time) }
    }

    /// The widest value-axis label the chart will print, so the ribbon's gutter matches it.
    private var gutterText: String {
        let values = windowed.flatMap { [$0.value] + [$0.low, $0.high].compactMap { $0 } } + references.map(\.value)
        return TimelineRibbon.gutterText(for: Self.axis, values: values)
    }

    var body: some View {
        // The readout's "latest" is the latest sample of THIS window: the window is closed at its end, which
        // for a whole day is the next day's midnight, and that bucket belongs to the next day.
        let inWindow = windowed.filter { $0.time < window.upperBound }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ValueReadout(readout(inWindow), isScrubbing: selected != nil, isLoading: isLoading)
                .overlay(alignment: .bottomTrailing) {
                    // Hidden while scrubbing, when the context line carries the activity under the finger.
                    if zoomed && selected == nil {
                        Button("Whole day", action: onResetZoom)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                            .buttonStyle(.plain)
                            .frame(minHeight: NoopMetrics.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                }
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    IntradayChart(samples: samples, bucketSeconds: bucketSeconds, bands: bands,
                                  references: references, legend: [], state: state, window: window,
                                  y: Self.axis, selection: $selected,
                                  accessibilityTitle: String(localized: "Heart rate"))
                    if !lanes.isEmpty {
                        TimelineRibbon(lanes: lanes, window: window, gutterText: gutterText, selection: selected,
                                       accessibilityLabel: String(localized: "Activity"),
                                       accessibilityValue: ribbonSummary,
                                       onTap: onRibbonTap)
                    }
                    if !legend.isEmpty {
                        ChartLegend(legend)
                    }
                }
            }
        }
        .onChangeCompat(of: window) { _ in selected = nil }
    }

    private func readout(_ inWindow: [IntradayChart.Sample]) -> ReadoutContent {
        let format: (Double) -> String = { String(Int($0.rounded())) }
        let contextLine: String?
        if let selected {
            contextLine = context(selected)
        } else if zoomed {
            contextLine = StretchFormat.clock(window.lowerBound) + " – " + StretchFormat.clock(window.upperBound)
        } else {
            contextLine = resolution
        }
        guard !inWindow.isEmpty else {
            // Nothing in the window: the day's date over a dash, so the line above the value is never blank.
            return ReadoutContent(dateLine: ReadoutContent.dateLine(window.lowerBound, period: .day),
                                  value: nil, unit: "bpm", context: nil)
        }
        return .intraday(selection: selected, in: inWindow, unit: "bpm", format: format, context: contextLine)
    }

    private var ribbonSummary: String {
        lanes.map(\.title).joined(separator: ", ")
    }
}

// MARK: Activity section

/// The day's time per kind of activity, each row opening that kind's stretches, then every stretch.
struct HeartRateDayActivitySection: View {
    let snapshot: DayActivitySnapshot
    let isBusy: Bool
    @ObservedObject var timeline: DayTimelineModel
    let onZoom: (ClosedRange<Date>) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Activity")
            if !snapshot.totals.isEmpty {
                NoopListSection {
                    ForEach(Array(snapshot.totals.enumerated()), id: \.element.id) { index, total in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        NavigationLink {
                            StretchFamilyView(scope: .family(total.family), timeline: timeline, onZoom: onZoom)
                        } label: {
                            NoopListRow(icon: total.family.symbol, iconColor: total.family.color,
                                        title: LocalizedStringKey(total.family.title),
                                        value: StretchFormat.duration(total.seconds))
                        }
                    }
                    if snapshot.layout.count > 0 {
                        NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                        NavigationLink {
                            DayStretchesListView(timeline: timeline, onZoom: onZoom)
                        } label: {
                            NoopListRow(icon: "list.bullet", title: "All stretches",
                                        value: "\(snapshot.layout.count)")
                        }
                    }
                }
                .buttonStyle(.plain)
            } else if isBusy {
                // The real rows' shape while the decoder reads the day, so the section does not pop in.
                NoopListSection {
                    ForEach(0..<3, id: \.self) { index in
                        if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                        NoopListRow(icon: "circle.fill", title: "Sitting", value: "0 h 00 m", showsChevron: false)
                    }
                }
                .loadingPlaceholder(true)
            } else {
                ComingSoon(what: "No motion data for this day yet.")
            }
        }
    }
}

// MARK: More

/// Rows into the day's deeper readings and the feedback surfaces, in one list card.
struct HeartRateDayMoreSection: View {
    let dayStart: Date
    let window: ClosedRange<Date>
    let snapshot: DayActivitySnapshot
    @ObservedObject var timeline: DayTimelineModel
    let deviceId: String?
    let walking: WalkingDayReading?
    let walkingLoaded: Bool
    let strap: StrapSignalDay?
    let strapLoaded: Bool
    let onZoom: (ClosedRange<Date>) -> Void

    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop5mg.rawValue
    @ObservedObject private var feedback = StretchFeedbackCenter.shared
    @StateObject private var improvement = ActivityImprovementCandidates()

    var body: some View {
        let candidates = improvement.candidates(episodes: snapshot.episodes, dayStart: dayStart, deviceId: deviceId)
        NoopListSection("More") {
            NavigationLink {
                WalkingDayView(dayStart: dayStart, reading: walking, loaded: walkingLoaded)
            } label: {
                NoopListRow(icon: "shoeprints.fill", iconColor: ActivityFamily.walking.color,
                            title: "Walking quality", value: walking?.summary)
            }
            NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
            NavigationLink {
                StrapSignalDayView(dayStart: dayStart, reading: strap, loaded: strapLoaded)
            } label: {
                NoopListRow(icon: "sensor.tag.radiowaves.forward", iconColor: StrandPalette.metricCyan,
                            title: "Strap signal", value: strap?.summary)
            }
            if snapshot.positionChangeCount > 0 {
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                NavigationLink {
                    StretchFamilyView(scope: .positionChanges, timeline: timeline, onZoom: onZoom)
                } label: {
                    NoopListRow(icon: ActivityFamily.changing.symbol, iconColor: StrandPalette.metricAmber,
                                title: "Position changes", value: "\(snapshot.positionChangeCount)")
                }
            }
            if !candidates.isEmpty {
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                NavigationLink {
                    ActivityImprovementListView(episodes: snapshot.episodes, dayStart: dayStart, deviceId: deviceId)
                } label: {
                    NoopListRow(icon: "questionmark.bubble", title: "Check stretches",
                                value: String(localized: "\(candidates.count) to check"))
                }
            }
            NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
            NavigationLink {
                StretchFeedbackHistoryView()
            } label: {
                NoopListRow(icon: "text.bubble", title: "Your answers", value: answersValue,
                            valueTone: feedback.waitingToUpload > 0 ? .warning : .neutral)
            }
            if ActivityCalibrationEntry.isAvailable(selectedModelRaw: selectedWhoopModelRaw) {
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                ActivityCalibrationEntry()
            }
            NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
            NavigationLink(value: TabRoute.fullDayChart) {
                NoopListRow(icon: "waveform.path.ecg.rectangle", title: "Deep Timeline")
            }
        }
        .buttonStyle(.plain)
    }

    private var answersValue: String {
        let saved = feedback.records.count
        if saved == 0 { return String(localized: "None yet") }
        let waiting = feedback.waitingToUpload
        return waiting == 0 ? String(localized: "\(saved) saved") : String(localized: "\(waiting) not sent yet")
    }
}

// MARK: All stretches

/// Every listed stretch of the day: the newest few, then the rest by part of the day. Each opens the
/// stretch sheet, where the wearer can say whether it is right; "Show on the heart rate graph" goes back to
/// the graph on the page this one was opened from.
struct DayStretchesListView: View {
    @ObservedObject var timeline: DayTimelineModel
    let onZoom: (ClosedRange<Date>) -> Void

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var feedback = StretchFeedbackCenter.shared
    @Environment(\.dismiss) private var dismiss
    @State private var openStretch: StretchSheetInput?

    private var layout: DayStretchLayout {
        DayStretchLayout(episodes: timeline.activityContext.map { ActivityContextEpisodes.build($0.runs) } ?? [])
    }

    var body: some View {
        let layout = self.layout
        ScreenScaffold(title: "All stretches", titleDisplay: .navigationBar, lazy: true) {
            if !layout.recent.isEmpty {
                section(String(localized: "Recent"), layout.recent)
            }
            ForEach(layout.earlier, id: \.part) { group in
                section(group.part.title, group.stretches)
            }
        }
        .sheet(item: $openStretch) { input in
            StretchDetailSheet(input: input, deviceId: repo.deviceId) { range in zoom(range) }
                .environmentObject(repo)
        }
    }

    private func section(_ title: String, _ stretches: [ActivityEpisode]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader(LocalizedStringKey(title), trailing: StretchFormat.count(stretches.count))
            NoopListSection {
                ForEach(Array(stretches.enumerated()), id: \.element.id) { index, ep in
                    if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                    Button {
                        openStretch = StretchSheetInput(target: .activity(ep), document: timeline.activityContext,
                                                        segments: timeline.dayStates)
                    } label: {
                        StretchListRow(episode: ep,
                                       verdict: feedback.feedback(kind: .activityContext, start: ep.start, end: ep.end))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// The graph is on the page this one was opened from: show the span there and go back to it.
    private func zoom(_ range: ClosedRange<Date>) {
        onZoom(range)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            dismiss()
        }
    }
}

/// One stretch as a list row: its label in the family's icon colour, the time span (with the wearer's
/// verdict when there is one) and the duration.
struct StretchListRow: View {
    let episode: ActivityEpisode
    let verdict: StretchFeedback?

    var body: some View {
        let family = ActivityFamily.of(episode.label)
        let short = episode.durationSeconds < 300
        let from = Date(timeIntervalSince1970: TimeInterval(episode.start))
        let to = Date(timeIntervalSince1970: TimeInterval(episode.end))
        let span = "\(StretchFormat.clock(from, seconds: short)) – \(StretchFormat.clock(to, seconds: short))"
        NoopListRow(icon: family.symbol, iconColor: family.color, title: LocalizedStringKey(episode.label),
                    subtitle: verdictText.map { "\(span) · \($0)" } ?? span,
                    value: StretchFormat.duration(episode.durationSeconds))
            .accessibilityHint(Text("Shows this stretch up close and lets you say whether it is right"))
    }

    private var verdictText: String? {
        guard let verdict else { return nil }
        if verdict.verdict == .correct { return String(localized: "You said right") }
        if let c = verdict.correctedLabel { return String(localized: "You said \(c.title)") }
        return String(localized: "You said wrong")
    }
}

#if DEBUG
/// DEBUG-only host for `--demo-screen allstretches` / `checkstretches` (pair with `--demo-intraday`): the
/// Heart rate page's two list pages on today's decoded activity, for screenshots, since a tour cannot tap.
struct HeartRateDayListsDemoHost: View {
    enum Page { case stretches, check }
    let page: Page
    @EnvironmentObject private var repo: Repository
    @StateObject private var timeline = DayTimelineModel()

    var body: some View {
        let day = Repository.logicalDayStart(Date())
        Group {
            switch page {
            case .stretches:
                DayStretchesListView(timeline: timeline, onZoom: { _ in })
            case .check:
                ActivityImprovementListView(
                    episodes: timeline.activityContext.map { ActivityContextEpisodes.build($0.runs) } ?? [],
                    dayStart: day, deviceId: repo.deviceId)
            }
        }
        .task { timeline.request(dayStart: day, repo: repo) }
    }
}
#endif

import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - The day's stretches under the heart-rate graph
//
// One section for what the wearer was doing. A lane across the day, a box for each kind of activity (tap one
// for its stretches and the position changes around them), the five newest stretches, and everything earlier
// folded into morning, midday and evening. The wording is kept to what a person needs to read; the evidence
// behind each stretch is one tap away in its own sheet.

// MARK: Formatting

enum StretchFormat {
    static func duration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 60 { return String(localized: "\(s) s") }
        let m = s / 60
        if m < 10, s % 60 != 0 { return String(localized: "\(m) min \(s % 60) s") }
        if m < 60 { return String(localized: "\(m) min") }
        let h = m / 60, r = m % 60
        return r == 0 ? String(localized: "\(h) h") : String(localized: "\(h) h \(r) m")
    }

    /// Short stretches show seconds, since "2:23 PM – 2:23 PM" says nothing about a 16 second walk.
    static func clock(_ d: Date, seconds: Bool = false) -> String {
        seconds ? d.formatted(.dateTime.hour().minute().second()) : d.formatted(.dateTime.hour().minute())
    }

    static func count(_ n: Int) -> String {
        n == 1 ? String(localized: "1 stretch") : String(localized: "\(n) stretches")
    }
}

extension StretchDayPart {
    var title: String {
        switch self {
        case .overnight: return String(localized: "Overnight")
        case .morning: return String(localized: "Morning")
        case .midday: return String(localized: "Midday")
        case .evening: return String(localized: "Evening")
        }
    }
}

// MARK: Totals by kind of activity

struct FamilyTotal: Identifiable, Equatable {
    let family: ActivityFamily
    let seconds: Int
    /// Stretches of a minute or longer, the ones the lists show.
    let stretches: Int
    /// The finer labels inside this family ("Brisk walking", "Taking stairs"), longest first.
    var breakdown: [FineLabelShare] = []
    var id: ActivityFamily { family }
}

enum DayStretchTotals {
    /// How long the day spent in each kind of activity, longest first. Time comes from the decoder's own tally
    /// (so it includes the short blips the lists leave out); the count is of the stretches the lists show.
    static func familyTotals(_ doc: ActivityContextDayDocument, episodes: [ActivityEpisode]) -> [FamilyTotal] {
        var seconds: [ActivityFamily: Int] = [:]
        for (label, s) in doc.summary.labelSeconds { seconds[ActivityFamily.of(label), default: 0] += s }
        if doc.summary.unclearSeconds > 0 { seconds[.unclear, default: 0] += doc.summary.unclearSeconds }
        var counts: [ActivityFamily: Int] = [:]
        for e in episodes where DayStretchLayout.isListed(e) {
            counts[ActivityFamily.of(e.label), default: 0] += 1
        }
        return seconds
            .filter { $0.value > 0 }
            .map { FamilyTotal(family: $0.key, seconds: $0.value, stretches: counts[$0.key] ?? 0,
                               breakdown: DayFineLabels.breakdown(doc, family: $0.key)) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.family.title < $1.family.title }
    }
}

// MARK: Section

struct DayStretchesSection: View {
    @ObservedObject var timeline: DayTimelineModel
    /// Visible x window, shared with the heart-rate graph above so the two stay lined up while zooming.
    let window: ClosedRange<Date>
    /// The local day the section speaks about; the improvement queue's prompt budget is keyed to it.
    let dayStart: Date
    /// Open a stretch up close, where the wearer can say whether it is right.
    let onOpen: (StretchTarget) -> Void
    /// Show a span on the heart-rate graph.
    let onZoom: (ClosedRange<Date>) -> Void

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var feedback = StretchFeedbackCenter.shared
    @State private var showsAllFamilies = false

    /// Boxes shown before "See all" opens the rest.
    private static let collapsedFamilyCount = 6

    var body: some View {
        let document = timeline.activityContext
        let episodes = document.map { ActivityContextEpisodes.build($0.runs) } ?? []
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            if let document, !episodes.isEmpty {
                content(document, episodes)
            } else {
                laneCardShell(hasDetails: false) {
                    if timeline.activityBusy {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Working out your day…")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, NoopMetrics.space4)
                    } else {
                        Text("No motion data for this day yet.")
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func content(_ doc: ActivityContextDayDocument, _ episodes: [ActivityEpisode]) -> some View {
        let layout = DayStretchLayout(episodes: episodes)
        #if DEBUG
        if !DemoLayout.listsOnly {
            laneCard(episodes, events: doc.events)
            familySummary(DayStretchTotals.familyTotals(doc, episodes: episodes))
        }
        #else
        laneCard(episodes, events: doc.events)
        familySummary(DayStretchTotals.familyTotals(doc, episodes: episodes))
        #endif
        recentList(layout)
        // The day's few uncertain stretches, one tap to answer. Empty (and invisible) when the day has nothing
        // worth asking or its question budget is used up.
        ActivityImprovementSection(episodes: episodes, dayStart: dayStart, deviceId: repo.deviceId,
                                   compactTitle: "Needs your input", inlineLimit: 4)
        WalkingQualityCard(dayStart: dayStart, window: window)
        positionChangesLink(doc)
        StrapSignalCard(dayStart: dayStart, window: window, compact: true)
        ActivityCalibrationEntry()
        footnote
    }

    // MARK: Lane

    private var dayDetails: some View {
        StretchFamilyView(scope: .day(window), timeline: timeline, onZoom: onZoom)
    }

    private func laneCard(_ episodes: [ActivityEpisode], events: [ActivityTransitionEvent]) -> some View {
        laneCardShell(hasDetails: true) {
            DayActivityLane(episodes: episodes, events: events, window: window, onOpen: onOpen,
                            height: 64, showsLabels: false)
            FineLabelLegend(shares: DayFineLabels.shares(episodes, in: window),
                            showsPositionChanges: !LanePositionChanges.ticks(events).isEmpty)
        }
    }

    /// The "Your day" card: its title row, the reading-progress line while the day is still being read, then `body`.
    private func laneCardShell<Body: View>(hasDetails: Bool, @ViewBuilder body: () -> Body) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricPurple)
                Text("Your day")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if timeline.activityBusy && timeline.activityContext != nil { ProgressView().controlSize(.small) }
                Spacer(minLength: 8)
                if hasDetails {
                    NavigationLink { dayDetails } label: { SeeAllLabel(text: "View details") }
                        .buttonStyle(.plain)
                }
            }
            if let reach = timeline.activityPartialReach {
                Text("Reading your day, up to \(StretchFormat.clock(reach)) so far…")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
            body()
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 20))
    }

    // MARK: Activity summary

    @ViewBuilder
    private func familySummary(_ totals: [FamilyTotal]) -> some View {
        if !totals.isEmpty {
            let collapsible = totals.count > Self.collapsedFamilyCount
            let shown = collapsible && !showsAllFamilies ? Array(totals.prefix(Self.collapsedFamilyCount)) : totals
            VStack(alignment: .leading, spacing: 10) {
                DaySectionHeader(title: "Activity summary") {
                    if collapsible {
                        Button {
                            withAnimation(StrandMotion.interactive) { showsAllFamilies.toggle() }
                        } label: {
                            SeeAllLabel(text: showsAllFamilies ? "Show less" : "See all",
                                        symbol: showsAllFamilies ? "chevron.up" : "chevron.right")
                        }
                        .buttonStyle(.plain)
                        .accessibilityValue(showsAllFamilies ? Text("Showing every kind") : Text("Showing the longest six"))
                    }
                }
                FamilyTileGrid(totals: shown) { family in
                    StretchFamilyView(scope: .family(family), timeline: timeline, onZoom: onZoom)
                }
            }
        }
    }

    // MARK: Lists

    @ViewBuilder
    private func recentList(_ layout: DayStretchLayout) -> some View {
        if !layout.recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                DaySectionHeader(title: "Recent activity") {
                    NavigationLink { dayDetails } label: { SeeAllLabel(text: "See all") }
                        .buttonStyle(.plain)
                }
                ForEach(layout.recent) { ep in
                    StretchRow(episode: ep, isLatest: ep.id == layout.recent.first?.id,
                               verdict: feedback.feedback(kind: .activityContext, start: ep.start, end: ep.end)) {
                        onOpen(.activity(ep))
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func positionChangesLink(_ doc: ActivityContextDayDocument) -> some View {
        let changes = PositionChanges.all(doc.events)
        if !changes.isEmpty {
            NavigationLink {
                StretchFamilyView(scope: .positionChanges, timeline: timeline, onZoom: onZoom)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "chart.bar.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(StrandPalette.metricPurple)
                        .frame(width: 24)
                    Text("Position changes")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text("\(changes.count)")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                    Image(systemName: "chevron.right")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, NoopMetrics.space3)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoopPanelSurface(cornerRadius: 18))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("Lists every position change flagged on this day")
        }
    }

    private var footnote: some View {
        Text("Fainter bars are less sure. Ticks under the bar are position changes. A wrist can't see height, so sitting and standing are best guesses.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, NoopMetrics.space1)
    }
}

// MARK: Lane

/// The day's stretches as coloured bars across `window`, with position changes as ticks underneath. Tapping a
/// bar opens that stretch.
struct DayActivityLane: View {
    let episodes: [ActivityEpisode]
    let events: [ActivityTransitionEvent]
    let window: ClosedRange<Date>
    let onOpen: (StretchTarget) -> Void
    var height: CGFloat = 84
    /// Name the stretches wide enough to hold their label. Off where a legend sits right under the lane.
    var showsLabels = true

    var body: some View {
        let marks = episodes.sorted { $0.durationSeconds > $1.durationSeconds }
        let ticks = LanePositionChanges.ticks(events)
        let span = max(1, window.upperBound.timeIntervalSince(window.lowerBound))
        Chart {
            ForEach(marks) { ep in
                let range = laneRange(ep)
                RectangleMark(
                    xStart: .value("Start", range.lowerBound),
                    xEnd: .value("End", range.upperBound),
                    yStart: .value("Bottom", 0.30),
                    yEnd: .value("Top", 1.0)
                )
                .cornerRadius(2)
                .foregroundStyle(ActivityFamily.of(ep.label).color.opacity(0.40 + 0.60 * ep.confidence))
                // A stretch wide enough on screen carries its own finer label.
                .annotation(position: .overlay, alignment: .center) {
                    if showsLabels, Double(ep.durationSeconds) / span >= 0.16 {
                        Text(ep.label)
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .shadow(color: .black.opacity(0.35), radius: 1)
                    }
                }
            }
            ForEach(Array(ticks.enumerated()), id: \.offset) { _, event in
                let at = Date(timeIntervalSince1970: TimeInterval(event.ts))
                let half = span * 0.0025
                RectangleMark(
                    xStart: .value("Start", at.addingTimeInterval(-half)),
                    xEnd: .value("End", at.addingTimeInterval(half)),
                    yStart: .value("Bottom", 0.0),
                    yEnd: .value("Top", 0.22)
                )
                .cornerRadius(1)
                .foregroundStyle(StrandPalette.metricAmber.opacity(0.45 + 0.55 * event.probability))
            }
        }
        // The lane runs the full width of its card.
        .chartXScale(domain: window)
        .chartYScale(domain: 0.0...1.0)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 5)) { _ in
                AxisTick()
                AxisValueLabel(format: axisFormat)
            }
        }
        .chartPlotStyle { $0.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                Rectangle()
                    .fill(Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let date: Date = proxy.value(atX: location.x - plot.minX) else { return }
                        let ts = Int(date.timeIntervalSince1970)
                        if let hit = episodes.first(where: { $0.start <= ts && ts < $0.end }) {
                            onOpen(.activity(hit))
                        }
                    }
            }
        }
        .frame(height: height)
        .accessibilityLabel(Text("Your day, as a timeline. The lists below have the same information."))
    }

    private var axisFormat: Date.FormatStyle {
        window.upperBound.timeIntervalSince(window.lowerBound) <= 6 * 3_600
            ? Date.FormatStyle().hour().minute()
            : Date.FormatStyle().hour()
    }

    /// A 15 second change of posture is a fraction of a point wide on a whole-day lane. Widen anything
    /// under 0.6% of the visible window, centred, so it still shows as a tick. Zooming shows its true width.
    private func laneRange(_ ep: ActivityEpisode) -> ClosedRange<Date> {
        let start = Date(timeIntervalSince1970: TimeInterval(ep.start))
        let end = Date(timeIntervalSince1970: TimeInterval(ep.end))
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let minWidth = span * 0.006
        let width = Double(ep.durationSeconds)
        guard width < minWidth else { return start...end }
        let mid = start.addingTimeInterval(width / 2)
        return mid.addingTimeInterval(-minWidth / 2)...mid.addingTimeInterval(minWidth / 2)
    }
}

// MARK: Pieces

/// One box per kind of activity. Each opens the stretches of that kind and the position changes around them.
struct FamilyTileGrid<Destination: View>: View {
    let totals: [FamilyTotal]
    let destination: (ActivityFamily) -> Destination

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(totals) { total in
                NavigationLink {
                    destination(total.family)
                } label: {
                    FamilyTile(total: total)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct FamilyTile: View {
    let total: FamilyTotal

    /// Worth listing only when the family holds more than one label, or a label more specific than its name.
    private var showsBreakdown: Bool {
        total.breakdown.count > 1 || (total.breakdown.first.map { $0.label != total.family.title } ?? false)
    }

    var body: some View {
        let family = total.family
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Image(systemName: family.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(family.color)
                Text(family.title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(StretchFormat.duration(total.seconds))
                .font(StrandFont.rounded(24))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            Text(total.stretches == 0 ? String(localized: "Brief moments") : StretchFormat.count(total.stretches))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            if showsBreakdown {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(total.breakdown.prefix(3)) { share in
                        HStack(spacing: 4) {
                            Text(share.label)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(StretchFormat.duration(share.seconds))
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .monospacedDigit()
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(family.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(family.color.opacity(0.35), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows these stretches and the position changes around them")
    }
}

/// One stretch in a list: what it was, when, for how long, and whether the wearer has judged it.
struct StretchRow: View {
    let episode: ActivityEpisode
    var isLatest = false
    let verdict: StretchFeedback?
    let action: () -> Void

    var body: some View {
        let family = ActivityFamily.of(episode.label)
        let color = family.color
        let short = episode.durationSeconds < 300
        let from = Date(timeIntervalSince1970: TimeInterval(episode.start))
        let to = Date(timeIntervalSince1970: TimeInterval(episode.end))
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: family.symbol)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(color.opacity(0.16)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(episode.label)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(2)
                        if isLatest { LatestTag() }
                        Spacer(minLength: 8)
                        Text(StretchFormat.duration(episode.durationSeconds))
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                        Image(systemName: "chevron.right")
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Text("\(StretchFormat.clock(from, seconds: short)) – \(StretchFormat.clock(to, seconds: short))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .monospacedDigit()
                    Text(EpisodeReading.summary(episode))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(2)
                    StretchVerdictBadge(feedback: verdict)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoopPanelSurface(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this stretch up close and lets you say whether it is right")
    }
}

/// A day-page section title with an optional trailing link ("See all", "View details").
struct DaySectionHeader<Trailing: View>: View {
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center) {
            Text(title)
                .font(StrandFont.rounded(19))
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, NoopMetrics.space1)
    }
}

/// The purple "See all ›" a section header links with. Sized to a full tap target.
struct SeeAllLabel: View {
    let text: LocalizedStringKey
    var symbol = "chevron.right"

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(StrandFont.subhead)
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
        }
        .foregroundStyle(StrandPalette.metricPurple)
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

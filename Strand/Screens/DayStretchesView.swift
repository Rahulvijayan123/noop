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
    /// Draw the day's lane here. A page that draws its own activity ribbon beside the heart rate passes false.
    var showsLane: Bool = true

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var feedback = StretchFeedbackCenter.shared
    @State private var openParts: Set<StretchDayPart> = []

    var body: some View {
        let document = timeline.activityContext
        let episodes = document.map { ActivityContextEpisodes.build($0.runs) } ?? []
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            SectionHeader("Your day",
                          trailing: timeline.activityPartialReach.map { String(localized: "Up to \(StretchFormat.clock($0))") })
            if let document, !episodes.isEmpty {
                content(document, episodes)
            } else if timeline.activityBusy {
                // The real layout at its final size, redacted, while the day is decoded.
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if showsLane { NoopCard { ChartPlaceholder(height: Self.laneHeight) } }
                    StretchRowsPlaceholder()
                }
                .loadingPlaceholder(true)
            } else {
                Text("No motion data for this day yet.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func content(_ doc: ActivityContextDayDocument, _ episodes: [ActivityEpisode]) -> some View {
        let layout = DayStretchLayout(episodes: episodes)
        #if DEBUG
        if !DemoLayout.listsOnly {
            if showsLane { laneCard(episodes, events: doc.events) }
            FamilyTileGrid(totals: DayStretchTotals.familyTotals(doc, episodes: episodes)) { family in
                StretchFamilyView(scope: .family(family), timeline: timeline, onZoom: onZoom)
            }
        }
        #else
        if showsLane { laneCard(episodes, events: doc.events) }
        FamilyTileGrid(totals: DayStretchTotals.familyTotals(doc, episodes: episodes)) { family in
            StretchFamilyView(scope: .family(family), timeline: timeline, onZoom: onZoom)
        }
        #endif
        recentList(layout)
        // "Help improve activity detection": the day's few uncertain stretches, one tap to answer.
        // Empty (and invisible) when the day has nothing worth asking or its question budget is used up.
        ActivityImprovementSection(episodes: episodes, dayStart: dayStart, deviceId: repo.deviceId)
        earlierList(layout, doc)
        WalkingQualityCard(dayStart: dayStart, window: window)
        StrapSignalCard(dayStart: dayStart, window: window)
        ActivityCalibrationEntry()
        AboutDisclosure("About your day", paragraphs: [
            String(localized: "Fainter bars are less sure. Ticks under the bar are position changes. A wrist can't see height, so sitting and standing are best guesses."),
        ])
    }

    // MARK: Lane

    static let laneHeight: CGFloat = 84

    private func laneCard(_ episodes: [ActivityEpisode], events: [ActivityTransitionEvent]) -> some View {
        let marks = episodes.sorted { $0.durationSeconds > $1.durationSeconds }
        let ticks = LanePositionChanges.ticks(events)
        let span = max(1, window.upperBound.timeIntervalSince(window.lowerBound))
        let axis = ChartAxis.layout(window, style: .hours)
        return NoopCard {
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
                    // Two strengths only: sure, and less sure (under 55 %). The family list below names the
                    // colours, so the bars carry no text of their own.
                    .foregroundStyle(ActivityFamily.of(ep.label).color.opacity(ep.confidence < 0.55 ? 0.45 : 1))
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
                    .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            // The lane runs the full width of its card, on the heart-rate graph's hour marks.
            .chartXScale(domain: window)
            .chartYScale(domain: 0.0...1.0)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: axis.grid) { _ in
                    AxisGridLine(stroke: NaraChartStyle.grid).foregroundStyle(NaraChartStyle.gridColor)
                }
                AxisMarks(values: axis.marks) { value in
                    if let date = value.as(Date.self), let i = axis.marks.firstIndex(of: date),
                       i < axis.labels.count, i < axis.anchors.count {
                        AxisValueLabel(anchor: axis.anchors[i] == .leading ? .topLeading
                                       : (axis.anchors[i] == .trailing ? .topTrailing : .top)) {
                            Text(axis.labels[i])
                                .font(NaraChartStyle.axisFont)
                                .foregroundStyle(NaraChartStyle.axisColor)
                        }
                    }
                }
            }
            .chartPlotStyle { $0.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
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
            .frame(height: Self.laneHeight)
            .accessibilityLabel(Text("Your day, as a timeline. The lists below have the same information."))
        }
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

    // MARK: Lists

    private func row(_ episode: ActivityEpisode) -> some View {
        StretchRow(episode: episode,
                   verdict: feedback.feedback(kind: .activityContext, start: episode.start, end: episode.end)) {
            onOpen(.activity(episode))
        }
    }

    @ViewBuilder
    private func recentList(_ layout: DayStretchLayout) -> some View {
        if !layout.recent.isEmpty {
            NoopListSection("Recent") {
                ForEach(Array(layout.recent.enumerated()), id: \.element.id) { index, ep in
                    if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                    row(ep)
                }
            }
        }
    }

    /// Overnight, morning, midday and evening, folded; each opens in place. Position changes sit at the end
    /// of the same card.
    @ViewBuilder
    private func earlierList(_ layout: DayStretchLayout, _ doc: ActivityContextDayDocument) -> some View {
        let changes = PositionChanges.all(doc.events)
        if !layout.earlier.isEmpty || !changes.isEmpty {
            NoopListSection(layout.earlier.isEmpty ? nil : "Earlier") {
                ForEach(Array(layout.earlier.enumerated()), id: \.element.part) { index, group in
                    if index > 0 { NoopListDivider(leadingInset: 0) }
                    partGroup(group)
                }
                if !changes.isEmpty {
                    if !layout.earlier.isEmpty { NoopListDivider(leadingInset: 0) }
                    NavigationLink {
                        StretchFamilyView(scope: .positionChanges, timeline: timeline, onZoom: onZoom)
                    } label: {
                        NoopListRow(icon: "arrow.up.arrow.down", title: "Position changes", value: "\(changes.count)")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func partGroup(_ group: DayStretchLayout.Group) -> some View {
        let open = openParts.contains(group.part)
        Button {
            withAnimation(StrandMotion.interactive) {
                if open { openParts.remove(group.part) } else { openParts.insert(group.part) }
            }
        } label: {
            HStack(spacing: NoopMetrics.space3) {
                Text(group.part.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.space2)
                Text(StretchFormat.count(group.stretches.count))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Image(systemName: "chevron.down")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .rotationEffect(.degrees(open ? 180 : 0))
            }
            .padding(.horizontal, NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
        if open {
            ForEach(group.stretches) { ep in
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                row(ep)
            }
        }
    }
}

// MARK: Pieces

/// One row per kind of activity, in one card. Each opens the stretches of that kind and the position changes
/// around them. (The type keeps its name from when these were tiles.)
struct FamilyTileGrid<Destination: View>: View {
    let totals: [FamilyTotal]
    let destination: (ActivityFamily) -> Destination

    var body: some View {
        NoopCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(Array(totals.enumerated()), id: \.element.id) { index, total in
                    if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
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
}

/// A kind of activity: its symbol in its colour, its name, what it held (the finer labels, or how many
/// stretches), and how long the day spent in it.
struct FamilyTile: View {
    let total: FamilyTotal

    /// Worth listing only when the family holds more than one label, or a label more specific than its name.
    private var showsBreakdown: Bool {
        total.breakdown.count > 1 || (total.breakdown.first.map { $0.label != total.family.title } ?? false)
    }

    private var subtitle: String {
        if showsBreakdown { return total.breakdown.prefix(3).map(\.label).joined(separator: ", ") }
        return total.stretches == 0 ? String(localized: "Brief moments") : StretchFormat.count(total.stretches)
    }

    var body: some View {
        let family = total.family
        HStack(spacing: NoopMetrics.space3) {
            Image(systemName: family.symbol)
                .font(StrandFont.icon(.row))
                .foregroundStyle(family.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(family.title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: NoopMetrics.space2)
            Text(StretchFormat.duration(total.seconds))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .fixedSize()
            Image(systemName: "chevron.right")
                .font(StrandFont.icon(.inline))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows these stretches and the position changes around them")
    }
}

/// One stretch in a list: what it was, when, for how long, and whether the wearer has judged it. A row for
/// a card of rows (the list draws the card and the dividers).
struct StretchRow: View {
    let episode: ActivityEpisode
    /// Kept for the call sites; the list's first row already is the latest, so nothing marks it.
    var isLatest = false
    let verdict: StretchFeedback?
    let action: () -> Void

    var body: some View {
        let family = ActivityFamily.of(episode.label)
        let short = episode.durationSeconds < 300
        let from = Date(timeIntervalSince1970: TimeInterval(episode.start))
        let to = Date(timeIntervalSince1970: TimeInterval(episode.end))
        Button(action: action) {
            HStack(spacing: NoopMetrics.space3) {
                Image(systemName: family.symbol)
                    .font(StrandFont.icon(.row))
                    .foregroundStyle(family.color)
                    .frame(width: 28)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(episode.label)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text("\(StretchFormat.clock(from, seconds: short)) – \(StretchFormat.clock(to, seconds: short)) · \(EpisodeReading.summary(episode))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .monospacedDigit()
                        .lineLimit(1)
                    StretchVerdictBadge(feedback: verdict)
                }
                Spacer(minLength: NoopMetrics.space2)
                Text(StretchFormat.duration(episode.durationSeconds))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, NoopMetrics.cardPadding)
            .padding(.vertical, NoopMetrics.space2)
            .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this stretch up close and lets you say whether it is right")
    }
}

/// Three stretch rows at their final size, for the loading state.
struct StretchRowsPlaceholder: View {
    var body: some View {
        NoopCard(padding: 0) {
            VStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    if i > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                    NoopListRow(icon: "figure.walk", title: "Activity name", subtitle: "00:00 – 00:00 · 00% sure",
                                value: "00 min")
                }
            }
        }
    }
}

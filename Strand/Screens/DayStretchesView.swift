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
        for e in episodes where e.durationSeconds >= DayStretchLayout.minimumSeconds {
            counts[ActivityFamily.of(e.label), default: 0] += 1
        }
        return seconds
            .filter { $0.value > 0 }
            .map { FamilyTotal(family: $0.key, seconds: $0.value, stretches: counts[$0.key] ?? 0) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.family.title < $1.family.title }
    }
}

// MARK: Section

struct DayStretchesSection: View {
    @ObservedObject var timeline: DayTimelineModel
    /// Visible x window, shared with the heart-rate graph above so the two stay lined up while zooming.
    let window: ClosedRange<Date>
    /// Open a stretch up close, where the wearer can say whether it is right.
    let onOpen: (StretchTarget) -> Void
    /// Show a span on the heart-rate graph.
    let onZoom: (ClosedRange<Date>) -> Void

    @ObservedObject private var feedback = StretchFeedbackCenter.shared
    @State private var openParts: Set<StretchDayPart> = []

    var body: some View {
        let document = timeline.activityContext
        let episodes = document.map { ActivityContextEpisodes.build($0.runs) } ?? []
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            header
            if let document, !episodes.isEmpty {
                content(document, episodes)
            } else if timeline.activityBusy {
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Working out your day…")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, NoopMetrics.space6)
            } else {
                Text("No motion data for this day yet.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Your day")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                if timeline.activityBusy && timeline.activityContext != nil { ProgressView().controlSize(.small) }
            }
            if let reach = timeline.activityPartialReach {
                Text("Reading your day, up to \(StretchFormat.clock(reach)) so far…")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, NoopMetrics.space1)
    }

    @ViewBuilder
    private func content(_ doc: ActivityContextDayDocument, _ episodes: [ActivityEpisode]) -> some View {
        let layout = DayStretchLayout(episodes: episodes)
        #if DEBUG
        if !DemoLayout.listsOnly {
            laneCard(episodes)
            FamilyTileGrid(totals: DayStretchTotals.familyTotals(doc, episodes: episodes)) { family in
                StretchFamilyView(scope: .family(family), timeline: timeline, onZoom: onZoom)
            }
        }
        #else
        laneCard(episodes)
        FamilyTileGrid(totals: DayStretchTotals.familyTotals(doc, episodes: episodes)) { family in
            StretchFamilyView(scope: .family(family), timeline: timeline, onZoom: onZoom)
        }
        #endif
        recentList(layout)
        earlierList(layout)
        positionChangesLink(doc)
        footnote
    }

    // MARK: Lane

    private func laneCard(_ episodes: [ActivityEpisode]) -> some View {
        let marks = episodes.sorted { $0.durationSeconds > $1.durationSeconds }
        return Chart {
            ForEach(marks) { ep in
                RectangleMark(
                    xStart: .value("Start", laneRange(ep).lowerBound),
                    xEnd: .value("End", laneRange(ep).upperBound),
                    yStart: .value("Bottom", 0.0),
                    yEnd: .value("Top", 1.0)
                )
                .cornerRadius(2)
                .foregroundStyle(ActivityFamily.of(ep.label).color.opacity(0.40 + 0.60 * ep.confidence))
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
        .frame(height: 68)
        .padding(.horizontal, NoopMetrics.space2)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 20))
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

    // MARK: Lists

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.horizontal, NoopMetrics.space1)
    }

    private func row(_ episode: ActivityEpisode, isLatest: Bool = false) -> some View {
        StretchRow(episode: episode, isLatest: isLatest,
                   verdict: feedback.feedback(kind: .activityContext, start: episode.start, end: episode.end)) {
            onOpen(.activity(episode))
        }
    }

    @ViewBuilder
    private func recentList(_ layout: DayStretchLayout) -> some View {
        if !layout.recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Recent")
                ForEach(layout.recent) { ep in
                    row(ep, isLatest: ep.id == layout.recent.first?.id)
                }
            }
        }
    }

    @ViewBuilder
    private func earlierList(_ layout: DayStretchLayout) -> some View {
        if !layout.earlier.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                sectionTitle("Earlier")
                ForEach(layout.earlier, id: \.part) { group in
                    partGroup(group)
                }
            }
        }
    }

    private func partGroup(_ group: DayStretchLayout.Group) -> some View {
        let open = openParts.contains(group.part)
        return VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(StrandMotion.interactive) {
                    if open { openParts.remove(group.part) } else { openParts.insert(group.part) }
                }
            } label: {
                HStack(spacing: 8) {
                    Text(group.part.title)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(StretchFormat.count(group.stretches.count))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(open ? 180 : 0))
                }
                .padding(.horizontal, NoopMetrics.space3)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoopPanelSurface(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(open ? Text("Expanded") : Text("Collapsed"))
            if open {
                ForEach(group.stretches) { ep in row(ep) }
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
                HStack(spacing: 8) {
                    Text("Position changes")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(changes.count)")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, NoopMetrics.space3)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoopPanelSurface(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var footnote: some View {
        Text("Fainter bars are less sure. A wrist can't see height, so sitting and standing are best guesses.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, NoopMetrics.space1)
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
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: family.symbol).foregroundStyle(color)
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
                    StretchVerdictBadge(feedback: verdict)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(0.30), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows this stretch up close and lets you say whether it is right")
    }
}

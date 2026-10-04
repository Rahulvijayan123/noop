import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Activity timeline under the day's heart-rate graph
//
// Coloured boxes for what the wearer was doing, inferred from the strap's own signals (see
// `DayStateTimeline`). Each box says where its label came from so the wearer can judge it. A wrist sensor
// cannot tell sitting from standing, so both are one "Still" state and the screen says so.

extension DayState {
    var title: String {
        switch self {
        case .sleeping: return String(localized: "Sleeping")
        case .offWrist: return String(localized: "Off wrist")
        case .running: return String(localized: "Running")
        case .walking: return String(localized: "Walking")
        case .workout: return String(localized: "Workout")
        case .active: return String(localized: "Moving")
        case .still: return String(localized: "Still")
        case .wornUnknown: return String(localized: "Worn, motion unknown")
        case .noData: return String(localized: "No data")
        }
    }

    var detail: String? {
        switch self {
        case .still: return String(localized: "Sitting or standing")
        case .active: return String(localized: "Light activity")
        case .offWrist: return String(localized: "No pulse detected")
        default: return nil
        }
    }

    var color: Color {
        switch self {
        case .sleeping: return StrandPalette.sleepDeep
        case .offWrist: return StrandPalette.textTertiary
        case .running: return StrandPalette.metricRose
        case .walking: return StrandPalette.accent
        case .workout: return StrandPalette.metricPurple
        case .active: return StrandPalette.metricAmber
        case .still: return StrandPalette.metricCyan
        case .wornUnknown: return StrandPalette.textSecondary
        case .noData: return StrandPalette.surfaceInset
        }
    }

    var symbol: String {
        switch self {
        case .sleeping: return "bed.double.fill"
        case .offWrist: return "applewatch.slash"
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .workout: return "figure.strengthtraining.traditional"
        case .active: return "figure.mixed.cardio"
        case .still: return "figure.stand"
        case .wornUnknown: return "questionmark.circle"
        case .noData: return "icloud.slash"
        }
    }

    static let displayOrder: [DayState] = [
        .sleeping, .still, .active, .walking, .running, .workout, .offWrist, .wornUnknown, .noData,
    ]
}

extension DayStateSegment {
    var basisText: String {
        switch basis {
        case .sleepSession:
            return String(localized: "From your logged sleep")
        case .wristEvent:
            return String(localized: "The strap reported the band came off")
        case .noPulseSignal:
            return String(localized: "No pulse for the whole stretch while the strap kept recording")
        case .loggedWorkout:
            return workoutSport.map { String(localized: "From a logged workout: \($0)") }
                ?? String(localized: "From a logged workout")
        case .strapActivityClass:
            let verb = state == .running ? String(localized: "running") : String(localized: "walking")
            guard let ticks = stepTicks, durationSeconds > 0 else {
                return String(localized: "The strap labelled this \(verb)")
            }
            let rate = String(format: "%.1f", Double(ticks) / Double(durationSeconds))
            return String(localized: "The strap labelled this \(verb) and its step counter ticked \(ticks) times, about \(rate) a second")
        case .motion:
            let g = motionG.map { String(format: "%.2f", $0) } ?? "–"
            return String(localized: "Wrist motion averaged \(g) g")
        case .noMotionData:
            return String(localized: "Heart rate only, no motion readings in this stretch")
        case .noRecords:
            return String(localized: "The strap recorded nothing here. Not synced yet, or it was off or charging.")
        }
    }

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(end)) }
}

struct DayStateTimelineSection: View {
    let segments: [DayStateSegment]
    let loading: Bool
    /// Visible x window, shared with the heart-rate graph above so the two stay lined up while zooming.
    let window: ClosedRange<Date>
    /// Widest y-axis label of the graph above, drawn invisibly so this lane's plot area starts at the same x.
    let axisLabelPlaceholder: String
    let onSelect: (ClosedRange<Date>) -> Void

    private var totals: [DayState: Int] { DayStateTimeline.totals(segments) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            header
            if loading && segments.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(.vertical, NoopMetrics.space6)
            } else if segments.isEmpty {
                Text("Nothing recorded for this day yet.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                laneCard
                summaryGrid
                episodes
            }
            limitations
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("What the strap reported")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Only the strap's own labels, your logged sleep and workouts, and wrist on and off. A cross-check on the activity context above. Tap a box to zoom the graph.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.space1)
    }

    private var laneCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Chart(laneSegments) { seg in
                RectangleMark(
                    xStart: .value("Start", laneRange(seg).lowerBound),
                    xEnd: .value("End", laneRange(seg).upperBound),
                    yStart: .value("Bottom", 0.0),
                    yEnd: .value("Top", 1.0)
                )
                .cornerRadius(2)
                .foregroundStyle(seg.state.color)
            }
            .chartXScale(domain: window)
            .chartYScale(domain: 0.0...1.0)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.5]) { _ in
                    AxisValueLabel {
                        Text(axisLabelPlaceholder)
                            .font(StrandFont.footnote)
                            .foregroundStyle(Color.clear)
                    }
                }
            }
            .chartPlotStyle { $0.clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous)) }
            .frame(height: 44)

            legend
        }
        .padding(NoopMetrics.space3)
        .background(NoopPanelSurface(cornerRadius: 20))
    }

    /// Longest first, so a short burst is drawn last and stays visible on top of the stretch around it.
    private var laneSegments: [DayStateSegment] {
        segments.sorted { $0.durationSeconds > $1.durationSeconds }
    }

    /// A 16 second walk is a fraction of a point wide on a whole-day lane. Widen anything under 0.6% of the
    /// visible window, centred, so it still shows as a tick. Zooming in shows its true width.
    private func laneRange(_ seg: DayStateSegment) -> ClosedRange<Date> {
        let span = window.upperBound.timeIntervalSince(window.lowerBound)
        let minWidth = span * 0.006
        let width = Double(seg.durationSeconds)
        guard width < minWidth else { return seg.startDate...seg.endDate }
        let mid = seg.startDate.addingTimeInterval(width / 2)
        return mid.addingTimeInterval(-minWidth / 2)...mid.addingTimeInterval(minWidth / 2)
    }

    private var legend: some View {
        let present = DayState.displayOrder.filter { (totals[$0] ?? 0) > 0 }
        return HStack(spacing: NoopMetrics.space3) {
            ForEach(present, id: \.self) { s in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2).fill(s.color).frame(width: 10, height: 10)
                    Text(s.title).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.7)
    }

    private var summaryGrid: some View {
        let present = DayState.displayOrder.filter { (totals[$0] ?? 0) > 0 }
        return LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                         spacing: 10) {
            ForEach(present, id: \.self) { s in
                summaryTile(s)
            }
        }
    }

    private func summaryTile(_ s: DayState) -> some View {
        let secs = totals[s] ?? 0
        let weighted = segments.filter { $0.state == s && $0.avgHr != nil }
        let weight = weighted.reduce(0) { $0 + $1.durationSeconds }
        let avg = weight > 0
            ? Int((Double(weighted.reduce(0) { $0 + ($1.avgHr ?? 0) * $1.durationSeconds }) / Double(weight)).rounded())
            : nil
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: s.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(s.color)
                Text(s.title).font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1).minimumScaleFactor(0.8)
            }
            Text(Self.duration(secs))
                .font(StrandFont.rounded(24))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            Text(avg.map { String(localized: "Avg \($0) bpm") } ?? s.detail ?? " ")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(s.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(s.color.opacity(0.35), lineWidth: 1))
    }

    private var episodes: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Through the day")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, NoopMetrics.space1)
            ForEach(segments) { seg in
                episodeBox(seg)
            }
        }
    }

    private func episodeBox(_ seg: DayStateSegment) -> some View {
        let color = seg.state.color
        return Button {
            let dur = Double(seg.durationSeconds)
            let pad: TimeInterval = dur < 600 ? max(90, dur * 2) : dur * 0.15
            onSelect(seg.startDate.addingTimeInterval(-pad)...seg.endDate.addingTimeInterval(pad))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: seg.state.symbol).foregroundStyle(color)
                        Text(seg.state.title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let sport = seg.workoutSport, seg.state == .workout {
                            Text(verbatim: "· \(sport)")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: 8)
                        Text(Self.duration(seg.durationSeconds))
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                    }
                    Text("\(Self.clock(seg.startDate, seconds: seg.durationSeconds < 300)) – \(Self.clock(seg.endDate, seconds: seg.durationSeconds < 300))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .monospacedDigit()
                    if let avg = seg.avgHr {
                        let range = (seg.minHr != nil && seg.maxHr != nil) ? " · \(seg.minHr!)–\(seg.maxHr!)" : ""
                        Text("Avg \(avg) bpm\(range)")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .monospacedDigit()
                    }
                    Text(seg.basisText)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(0.30), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Zooms the heart rate graph to this stretch")
    }

    private var limitations: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("This view has no way to tell sitting from standing, so both show as Still. The activity context above weighs how you moved just before and for how long.",
                  systemImage: "info.circle")
            Text("Walking and running show up from 10 seconds, when the strap labels it and its step counter agrees. Still and Moving are judged by the minute, and off wrist comes from the strap's own wrist on and off events.")
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.horizontal, NoopMetrics.space1)
    }

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
}

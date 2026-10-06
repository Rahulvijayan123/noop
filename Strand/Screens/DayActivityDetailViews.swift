import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - Finer detail for "Your day"
//
// The lane and the boxes group stretches into families (all walking is one colour). These pieces put the finer
// reading back: which kind of walk or sit it was, what the hands were doing, where the position changes fell,
// how well the strap could see, and a way to teach the detector with guided sessions.

// MARK: Fine labels

struct FineLabelShare: Identifiable, Equatable {
    let label: String
    let seconds: Int
    var id: String { label }
}

enum DayFineLabels {
    /// Time per published label inside the visible window, longest first. Episodes are clipped to the window
    /// so a zoomed lane's legend speaks only about what is on screen.
    static func shares(_ episodes: [ActivityEpisode], in window: ClosedRange<Date>) -> [FineLabelShare] {
        let lo = Int(window.lowerBound.timeIntervalSince1970), hi = Int(window.upperBound.timeIntervalSince1970)
        var seconds: [String: Int] = [:]
        for ep in episodes {
            let s = max(ep.start, lo), e = min(ep.end, hi)
            if e > s { seconds[ep.label, default: 0] += e - s }
        }
        return seconds
            .filter { $0.value > 0 && $0.key != ActivityDisplay.unclear }
            .map { FineLabelShare(label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label }
    }

    /// The labels that make up one family's time for the day, longest first.
    static func breakdown(_ doc: ActivityContextDayDocument, family: ActivityFamily) -> [FineLabelShare] {
        doc.summary.labelSeconds
            .filter { $0.value > 0 && ActivityFamily.of($0.key) == family }
            .map { FineLabelShare(label: $0.key, seconds: $0.value) }
            .sorted { $0.seconds != $1.seconds ? $0.seconds > $1.seconds : $0.label < $1.label }
    }
}

/// Coloured chips for the labels on screen, under the lane.
struct FineLabelLegend: View {
    let shares: [FineLabelShare]
    var showsPositionChanges = false

    var body: some View {
        let shown = Array(shares.prefix(8))
        FlowLayout(spacing: 6) {
            ForEach(shown) { share in
                let family = ActivityFamily.of(share.label)
                HStack(spacing: 5) {
                    Circle().fill(family.color).frame(width: 7, height: 7)
                    Text(share.label)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(StretchFormat.duration(share.seconds))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(family.color.opacity(0.12)))
            }
            if showsPositionChanges {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 1).fill(StrandPalette.metricAmber).frame(width: 3, height: 10)
                    Text("Position change")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(StrandPalette.metricAmber.opacity(0.10)))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Wraps its children onto as many rows as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let extra = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            if rows[rows.count - 1].width + extra > width, !rows[rows.count - 1].indices.isEmpty {
                rows.append(Row())
            }
            let added = rows[rows.count - 1].indices.isEmpty ? size.width : size.width + spacing
            rows[rows.count - 1].indices.append(index)
            rows[rows.count - 1].width += added
            rows[rows.count - 1].height = max(rows[rows.count - 1].height, size.height)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: Position changes on the lane

enum LanePositionChanges {
    /// The body-position changes worth a tick on the lane. Walk and run starts are already the lane's own edges.
    static func ticks(_ events: [ActivityTransitionEvent]) -> [ActivityTransitionEvent] {
        PositionChanges.all(events).filter {
            switch $0.kind {
            case .sitToStandLike, .standToSitLike, .lyingDownLike, .gettingUpLike: return true
            case .walkStart, .walkStop, .runStart, .runStop: return false
            }
        }
    }
}

// MARK: The reading behind one stretch

enum EpisodeReading {
    /// One line of what the decoder saw inside a stretch, finer than its label: the body position or kind of
    /// movement, what the hands were doing, and how sure it was.
    static func summary(_ ep: ActivityEpisode) -> String {
        var parts: [String] = []
        let locomotion = ep.locomotion.top(excluding: .unknown)
        let moving = locomotion.map { $0.0 != .stationary && $0.1 >= 0.3 } ?? false
        if moving, let (mode, _) = locomotion {
            if mode.displayName != ep.label { parts.append(mode.displayName) }
        } else if let (posture, p) = ep.posture.top(excluding: .unknown), p >= 0.3 {
            if posture.displayName != ep.label { parts.append(posture.displayName) }
        }
        if ep.inBed { parts.append(String(localized: "In bed")) }
        if let (arm, p) = ep.armBehavior.top(excluding: .unknown), p >= 0.35 {
            parts.append(handsPhrase(arm))
        }
        if let intensity = ep.intensity, moving {
            parts.append(intensity >= 0.66 ? String(localized: "Hard effort")
                         : intensity >= 0.33 ? String(localized: "Moderate effort")
                         : String(localized: "Easy effort"))
        }
        parts.append(String(localized: "\(Int((ep.confidence * 100).rounded()))% sure"))
        return parts.joined(separator: " · ")
    }

    static func handsPhrase(_ arm: ArmBehaviorClass) -> String {
        switch arm {
        case .quiet: return String(localized: "Hands still")
        case .deskLike: return String(localized: "Desk-like hand motion")
        case .fidgeting: return String(localized: "Fidgeting")
        case .repetitiveHandMotion: return String(localized: "Repetitive hand motion")
        case .activeGesturing: return String(localized: "Gesturing")
        case .exerciseMotion: return String(localized: "Exercise arm motion")
        case .other: return String(localized: "Other hand motion")
        case .unknown: return String(localized: "Hands unclear")
        }
    }
}

// MARK: Strap signal

extension WearSignalState {
    var displayName: String {
        switch self {
        case .onWristGood: return String(localized: "Good contact")
        case .onWristLoose: return String(localized: "Loose fit")
        case .motionArtifact: return String(localized: "Motion noise")
        case .offWrist: return String(localized: "Off wrist")
        case .sensorDropout: return String(localized: "Sensor gap")
        case .unknown: return String(localized: "Not assessed")
        }
    }

    var color: Color {
        switch self {
        case .onWristGood: return StrandPalette.statusPositive
        case .onWristLoose: return StrandPalette.statusWarning
        case .motionArtifact: return StrandPalette.metricRose
        case .offWrist: return StrandPalette.textTertiary
        case .sensorDropout: return StrandPalette.metricPurple
        case .unknown: return StrandPalette.surfaceInset
        }
    }

    static let displayOrder: [WearSignalState] = [.onWristGood, .onWristLoose, .motionArtifact, .sensorDropout,
                                                  .offWrist, .unknown]
}

/// The server's per-30-s strap reading for a day (from raw motion sessions it has processed).
struct StrapSignalDay: Equatable {
    struct Span: Identifiable, Equatable {
        let start: Int
        let end: Int
        let state: WearSignalState
        var id: Int { start }
    }
    let spans: [Span]
    let seconds: [WearSignalState: Int]

    var assessedSeconds: Int { seconds.filter { $0.key != .unknown }.values.reduce(0, +) }

    init(epochs: [ActivityEpoch]) {
        var spans: [Span] = []
        var seconds: [WearSignalState: Int] = [:]
        for e in epochs.sorted(by: { $0.startTs < $1.startTs }) {
            guard let state = e.wearSignal, e.endTs > e.startTs else { continue }
            seconds[state, default: 0] += e.endTs - e.startTs
            if let last = spans.last, last.state == state, last.end == e.startTs {
                spans[spans.count - 1] = Span(start: last.start, end: e.endTs, state: state)
            } else {
                spans.append(Span(start: e.startTs, end: e.endTs, state: state))
            }
        }
        self.spans = spans
        self.seconds = seconds
    }
}

struct StrapSignalCard: View {
    let dayStart: Date
    let window: ClosedRange<Date>

    @State private var reading: StrapSignalDay?
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(StrandPalette.metricCyan)
                Text("Strap signal")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                if !loaded { ProgressView().controlSize(.small) }
            }
            if let reading, !reading.spans.isEmpty {
                lane(reading)
                breakdown(reading)
                Text("How well the strap could read you, every 30 seconds, from the motion sessions the server has processed. Loose fit and motion noise make heart rate and activity less certain.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if loaded {
                Text("No strap-signal reading for this day yet. It appears once the server has processed a raw motion session from your strap.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 20))
        .task(id: dayStart) { await load() }
    }

    private func lane(_ reading: StrapSignalDay) -> some View {
        Chart(reading.spans) { span in
            RectangleMark(
                xStart: .value("Start", Date(timeIntervalSince1970: TimeInterval(span.start))),
                xEnd: .value("End", Date(timeIntervalSince1970: TimeInterval(span.end))),
                yStart: .value("Bottom", 0.0),
                yEnd: .value("Top", 1.0)
            )
            .foregroundStyle(span.state.color)
        }
        .chartXScale(domain: window)
        .chartYScale(domain: 0.0...1.0)
        .chartYAxis(.hidden)
        .chartXAxis(.hidden)
        .chartPlotStyle { $0.clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous)) }
        .frame(height: 18)
        .accessibilityLabel(Text("Strap signal across the day"))
    }

    private func breakdown(_ reading: StrapSignalDay) -> some View {
        let total = max(1, reading.seconds.values.reduce(0, +))
        return FlowLayout(spacing: 6) {
            ForEach(WearSignalState.displayOrder.filter { (reading.seconds[$0] ?? 0) > 0 }, id: \.self) { state in
                let s = reading.seconds[state] ?? 0
                HStack(spacing: 5) {
                    Circle().fill(state.color).frame(width: 7, height: 7)
                    Text(state.displayName)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(Int((Double(s) / Double(total) * 100).rounded()))%")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .monospacedDigit()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Capsule().fill(state.color.opacity(0.12)))
            }
        }
    }

    private func load() async {
        defer { loaded = true }
        guard CloudPushIdentityStore.current() != nil,
              let repository = CloudPushRuntime.shared.scoreRepository() else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: dayStart)
        let deviceIds = await IntradaySeriesStore.shared.readCandidates
        if let cached = await repository.cachedDay(day: day, deviceIds: deviceIds),
           let epochs = cached.hostedResult?.activityContext?.epochs {
            reading = StrapSignalDay(epochs: epochs)
        }
        if let fresh = try? await repository.refresh(day: day, deviceIds: deviceIds),
           let epochs = fresh.hostedResult?.activityContext?.epochs {
            reading = StrapSignalDay(epochs: epochs)
        }
    }
}

// MARK: Guided calibration

/// Entry to the guided sessions that give the detector labelled examples of the wearer's own movements.
struct ActivityCalibrationEntry: View {
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop5mg.rawValue
    @State private var labelledCount = 0

    var body: some View {
        if selectedWhoopModelRaw == WhoopModel.whoop5mg.rawValue {
            NavigationLink {
                ActivityCalibrationView()
            } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "figure.mind.and.body")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(StrandPalette.accent.opacity(0.14)))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Teach activity detection")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(subtitle)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
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
            .task {
                labelledCount = await Task.detached(priority: .utility) {
                    ActivityGroundTruthStore.shared.all().count
                }.value
            }
        }
    }

    private var subtitle: String {
        let n = labelledCount
        return n == 0
            ? String(localized: "A few guided minutes of sitting, standing and walking so Nara learns how you move.")
            : String(localized: "\(n) labelled examples so far. Add more to sharpen sitting, standing and position changes.")
    }
}

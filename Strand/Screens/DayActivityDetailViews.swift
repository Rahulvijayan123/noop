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

/// The labels on screen under a lane: a dot in the family colour, the label and its time. Plain text, no
/// tinted chips, so the colour belongs to the data.
struct FineLabelLegend: View {
    let shares: [FineLabelShare]
    var showsPositionChanges = false

    var body: some View {
        let shown = Array(shares.prefix(8))
        FlowLayout(spacing: NoopMetrics.space3) {
            ForEach(shown) { share in
                let family = ActivityFamily.of(share.label)
                HStack(spacing: NoopMetrics.space1) {
                    Circle().fill(family.color).frame(width: 7, height: 7)
                    Text(share.label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(StretchFormat.duration(share.seconds))
                        .font(StrandFont.footnote.monospacedDigit())
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            if showsPositionChanges {
                HStack(spacing: NoopMetrics.space1) {
                    RoundedRectangle(cornerRadius: 1).fill(StrandPalette.metricAmber).frame(width: 2, height: 9)
                    Text("Position change")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
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
        case .unknown: return StrandPalette.textTertiary.opacity(0.5)
        }
    }

    /// No trustworthy signal: drawn hatched on a lane and on the heart-rate graph.
    var isGap: Bool { self == .offWrist || self == .sensorDropout || self == .unknown }

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

// MARK: Server readings for a day
//
// The strap-signal and walking readings come from raw motion sessions the server has processed. These are
// the loads the day cards used to run from their own `.task`, moved here unchanged so the Heart rate page,
// its Walking and Strap signal pages and the older cards all read them the same way. Main-actor isolated, as
// the view methods they came from were, so `update` lands on the main actor between the same awaits.

@MainActor
enum DayCloudReadings {
    /// The day's per-30-s strap reading: the cached copy first (`update` is called with it at once), then
    /// the fresh one.
    static func strapSignal(dayStart: Date, update: (StrapSignalDay) -> Void) async {
        #if DEBUG
        if let demo = DemoActivityExtras.strapSignal(dayStart: dayStart) { update(demo); return }
        #endif
        guard CloudPushIdentityStore.current() != nil,
              let repository = CloudPushRuntime.shared.scoreRepository() else { return }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let day = formatter.string(from: dayStart)
        let deviceIds = await IntradaySeriesStore.shared.readCandidates
        if let cached = await repository.cachedDay(day: day, deviceIds: deviceIds),
           let epochs = cached.hostedResult?.activityContext?.epochs {
            update(StrapSignalDay(epochs: epochs))
        }
        if let fresh = try? await repository.refresh(day: day, deviceIds: deviceIds),
           let epochs = fresh.hostedResult?.activityContext?.epochs {
            update(StrapSignalDay(epochs: epochs))
        }
    }

    /// The day's walking as the server's gait model read it, or nil when nothing has been processed.
    static func walking(dayStart: Date) async -> WalkingDayReading? {
        #if DEBUG
        if let demo = DemoActivityExtras.walking(dayStart: dayStart) { return demo }
        #endif
        guard let identity = CloudPushIdentityStore.current(),
              let repository = CloudPushRuntime.shared.scoreRepository(),
              let device = await IntradaySeriesStore.shared.readCandidates.first else { return nil }
        let from = Int(dayStart.timeIntervalSince1970)
        let to = Int((Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400))
            .timeIntervalSince1970)
        let days = ActivityEncoderWindowStore.utcDays(from: from, to: to)
        guard let columns = try? await GaitWindowsCache.shared.columns(
            utcDays: days, deviceId: device, ownerId: identity.ownerId, repository: repository),
              !columns.isEmpty else { return nil }
        return WalkingDayReading(days: columns, from: from, to: to)
    }
}

extension StrapSignalDay {
    /// Share of the assessed time with good contact, 0...1, or nil when nothing was assessed.
    var goodShare: Double? {
        let assessed = assessedSeconds
        guard assessed > 0 else { return nil }
        return Double(seconds[.onWristGood] ?? 0) / Double(assessed)
    }

    /// "92 % good contact", for a list row.
    var summary: String? {
        goodShare.map { String(localized: "\(Int(($0 * 100).rounded())) % good contact") }
    }
}

extension WalkingDayReading {
    /// "42 min · 4,210 steps", for a list row.
    var summary: String? {
        guard !isEmpty else { return nil }
        let time = StretchFormat.duration(walkingSeconds)
        guard let steps else { return time }
        return "\(time) · \(String(localized: "\(Int(steps.rounded()).formatted()) steps"))"
    }
}

// MARK: Strap signal (compact card)

/// How well the strap could read the wearer through the day, as one lane and a legend. The full reading
/// (shares, the timeline on the day's axis, the method) is `StrapSignalDayView`.
struct StrapSignalCard: View {
    let dayStart: Date
    let window: ClosedRange<Date>

    @State private var reading: StrapSignalDay?
    @State private var loaded = false

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Strap signal")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                TimelineRibbon(lanes: [StrapSignalLane.lane(reading, loaded: loaded, height: TimelineRibbon.laneHeight, symbol: nil)],
                               window: window, gutterText: "",
                               accessibilityLabel: String(localized: "Strap signal across the day"))
                if let reading, !reading.spans.isEmpty {
                    ChartLegend(StrapSignalLane.legend(reading))
                }
            }
        }
        .task(id: dayStart) { await load() }
    }

    private func load() async {
        defer { loaded = true }
        await DayCloudReadings.strapSignal(dayStart: dayStart) { reading = $0 }
    }
}

/// The strap-signal states as one ribbon lane, shared by the card, the Heart rate page and its page.
enum StrapSignalLane {
    /// `quietGood` draws good contact as a neutral fill, so on the Heart rate page's ribbon only the time the
    /// strap read poorly stands out (and never in the same colour as a kind of activity above it).
    static func lane(_ reading: StrapSignalDay?, loaded: Bool, height: CGFloat = TimelineRibbon.thinLaneHeight,
                     symbol: String? = "sensor.tag.radiowaves.forward", quietGood: Bool = false) -> TimelineRibbon.Lane {
        let quiet = StrandPalette.textTertiary.opacity(0.35)
        let segments: [TimelineRibbon.Segment] = (reading?.spans ?? []).map { span in
            let color: Color = (quietGood && span.state == .onWristGood) ? quiet : span.state.color
            return TimelineRibbon.Segment(id: "strap-\(span.start)",
                                          start: Date(timeIntervalSince1970: TimeInterval(span.start)),
                                          end: Date(timeIntervalSince1970: TimeInterval(span.end)),
                                          color: color, hatched: span.state.isGap)
        }
        let state: ChartState = !loaded && reading == nil ? .loading
            : segments.isEmpty ? .empty(String(localized: "No reading")) : .ready
        return TimelineRibbon.Lane(id: "strap", symbol: symbol, title: String(localized: "Strap signal"),
                                   segments: segments, height: height, state: state)
    }

    /// The states the reading holds, in the fixed display order.
    static func legend(_ reading: StrapSignalDay) -> [ChartLegendItem] {
        WearSignalState.displayOrder
            .filter { (reading.seconds[$0] ?? 0) > 0 }
            .map { ChartLegendItem($0.isGap ? .hatched($0.color) : .swatch($0.color), $0.displayName) }
    }
}

// MARK: Walking (compact card)

/// The day's walking as the server's gait model read it, in brief. The full reading is `WalkingDayView`.
struct WalkingQualityCard: View {
    let dayStart: Date
    let window: ClosedRange<Date>

    @State private var reading: WalkingDayReading?
    @State private var loaded = false

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Walking")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(reading?.summary ?? "—")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .loadingPlaceholder(!loaded)
                }
                TimelineRibbon(lanes: [WalkingLane.lane(reading, loaded: loaded, height: TimelineRibbon.laneHeight, symbol: nil)],
                               window: window, gutterText: "",
                               accessibilityLabel: String(localized: "\(reading?.bouts.count ?? 0) walks across the day"))
            }
        }
        .task(id: dayStart) { await load() }
    }

    private func load() async {
        defer { loaded = true }
        reading = await DayCloudReadings.walking(dayStart: dayStart)
    }
}

/// Each walk as a ribbon segment, brisk walks in the full walking colour and slower ones lighter.
enum WalkingLane {
    static func lane(_ reading: WalkingDayReading?, loaded: Bool, height: CGFloat = TimelineRibbon.thinLaneHeight,
                     symbol: String? = "shoeprints.fill") -> TimelineRibbon.Lane {
        let segments = (reading?.bouts ?? []).map { bout in
            TimelineRibbon.Segment(id: "walk-\(bout.start)",
                                   start: Date(timeIntervalSince1970: TimeInterval(bout.start)),
                                   end: Date(timeIntervalSince1970: TimeInterval(bout.end)),
                                   color: isBrisk(bout) ? ActivityFamily.walking.color
                                                        : ActivityFamily.walking.color.opacity(0.45))
        }
        let state: ChartState = !loaded && reading == nil ? .loading
            : segments.isEmpty ? .empty(String(localized: "No walks")) : .ready
        return TimelineRibbon.Lane(id: "walks", symbol: symbol, title: String(localized: "Walks"),
                                   segments: segments, height: height, state: state)
    }

    static func isBrisk(_ bout: WalkingDayReading.Bout) -> Bool {
        (bout.cadenceSpm ?? 0) >= WalkingDayReading.briskCadenceSpm
    }
}

// MARK: Guided calibration

/// Entry to the guided sessions that give the detector labelled examples of the wearer's own movements: one
/// list row, with how many examples there are so far. The explanation lives on the calibration page.
struct ActivityCalibrationEntry: View {
    @AppStorage("selectedWhoopModel") private var selectedWhoopModelRaw = WhoopModel.whoop5mg.rawValue
    @State private var labelledCount: Int?

    /// Whether the entry applies (the guided sessions need a 5/MG's motion stream).
    static func isAvailable(selectedModelRaw: String) -> Bool {
        selectedModelRaw == WhoopModel.whoop5mg.rawValue
    }

    var body: some View {
        if Self.isAvailable(selectedModelRaw: selectedWhoopModelRaw) {
            NavigationLink {
                ActivityCalibrationView()
            } label: {
                NoopListRow(icon: "figure.mind.and.body", title: "Activity calibration",
                            value: labelledCount.flatMap(Self.examplesText))
            }
            .buttonStyle(.plain)
            .task {
                labelledCount = await Task.detached(priority: .utility) {
                    ActivityGroundTruthStore.shared.all().count
                }.value
            }
        }
    }

    /// "12 examples", or nil before the first one (the row then reads as its title alone).
    static func examplesText(_ n: Int) -> String? {
        n == 0 ? nil : n == 1 ? String(localized: "1 example") : String(localized: "\(n) examples")
    }
}

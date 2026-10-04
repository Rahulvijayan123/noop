import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - ActivityContext under the day's heart-rate graph
//
// The decoded state, not one label: three independent heads (posture, locomotion, arm behaviour), each a
// probability distribution, plus intensity, confidence and the wear and sleep context. Composite labels such
// as "Desk sitting" are a derived view of those heads. The lane is faded where confidence is low, so a guess
// looks like a guess. A wrist cannot see body height, so sitting and standing are only ever "likely".

// MARK: Wording

extension PostureClass {
    var displayName: String {
        switch self {
        case .recumbent: return String(localized: "Lying down")
        case .seatedLikely: return String(localized: "Seated (likely)")
        case .uprightStationary: return String(localized: "Upright, still")
        case .posturalTransition: return String(localized: "Changing position")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension LocomotionClass {
    var displayName: String {
        switch self {
        case .stationary: return String(localized: "Stationary")
        case .walking: return String(localized: "Walking")
        case .briskWalking: return String(localized: "Brisk walking")
        case .running: return String(localized: "Running")
        case .stairs: return String(localized: "Stairs")
        case .cycling: return String(localized: "Cycling")
        case .vehicleMotion: return String(localized: "Vehicle motion")
        case .other: return String(localized: "Other movement")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension ArmBehaviorClass {
    var displayName: String {
        switch self {
        case .quiet: return String(localized: "Quiet")
        case .deskLike: return String(localized: "Desk-like")
        case .fidgeting: return String(localized: "Fidgeting")
        case .repetitiveHandMotion: return String(localized: "Repetitive hand motion")
        case .activeGesturing: return String(localized: "Gesturing")
        case .exerciseMotion: return String(localized: "Exercise motion")
        case .other: return String(localized: "Other")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension ActivityTransitionKind {
    var displayName: String {
        switch self {
        case .sitToStandLike: return String(localized: "Sit-to-stand-like")
        case .standToSitLike: return String(localized: "Stand-to-sit-like")
        case .lyingDownLike: return String(localized: "Lying-down-like")
        case .gettingUpLike: return String(localized: "Getting-up-like")
        case .walkStart: return String(localized: "Started walking")
        case .walkStop: return String(localized: "Stopped walking")
        case .runStart: return String(localized: "Started running")
        case .runStop: return String(localized: "Stopped running")
        }
    }
}

extension SleepContextState {
    var displayName: String {
        switch self {
        case .asleep: return String(localized: "Asleep")
        case .awake: return String(localized: "Awake")
        case .unknown: return String(localized: "Not known")
        }
    }
}

extension WearContextState {
    var displayName: String {
        switch self {
        case .onWrist: return String(localized: "On wrist")
        case .offWrist: return String(localized: "Off wrist")
        case .unknown: return String(localized: "Not known")
        }
    }
}

/// The colour family a display label belongs to. Many labels ("Desk sitting", "Sitting quietly") are one
/// family on the lane; the label itself stays in the list and the detail card.
enum ActivityFamily: CaseIterable, Hashable {
    case asleep, sitting, standing, stillUnsure, walking, running, otherMovement, changing, offWrist, unclear

    static func of(_ label: String) -> ActivityFamily {
        switch label {
        case ActivityDisplay.offWrist: return .offWrist
        case ActivityDisplay.unclear: return .unclear
        case "Asleep", "Resting in bed", "Lying down": return .asleep
        case "Running": return .running
        case "Walking", "Brisk walking", "Taking stairs": return .walking
        case "Cycling", "In a vehicle", "Exercising", "Moving": return .otherMovement
        case "Changing position": return .changing
        case "Still, sitting or standing", "Hands busy, sitting or standing", "Stationary": return .stillUnsure
        default:
            if label.hasPrefix("Sitting") || label == "Desk sitting" { return .sitting }
            if label.hasPrefix("Standing") { return .standing }
            return .unclear
        }
    }

    var title: String {
        switch self {
        case .asleep: return String(localized: "Asleep or lying down")
        case .sitting: return String(localized: "Sitting")
        case .standing: return String(localized: "Standing")
        case .stillUnsure: return String(localized: "Still, sitting or standing")
        case .walking: return String(localized: "Walking")
        case .running: return String(localized: "Running")
        case .otherMovement: return String(localized: "Other movement")
        case .changing: return String(localized: "Changing position")
        case .offWrist: return String(localized: "Off wrist")
        case .unclear: return String(localized: "Unclear")
        }
    }

    var color: Color {
        switch self {
        case .asleep: return StrandPalette.sleepDeep
        case .sitting: return StrandPalette.metricCyan
        case .standing: return StrandPalette.metricPurple
        case .stillUnsure: return StrandPalette.metricCyan.opacity(0.5)
        case .walking: return StrandPalette.accent
        case .running: return StrandPalette.metricRose
        case .otherMovement: return StrandPalette.metricAmber
        case .changing: return StrandPalette.metricAmber.opacity(0.6)
        case .offWrist: return StrandPalette.textTertiary
        case .unclear: return StrandPalette.surfaceInset
        }
    }

    var symbol: String {
        switch self {
        case .asleep: return "bed.double.fill"
        case .sitting, .stillUnsure: return "chair.lounge.fill"
        case .standing: return "figure.stand"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .otherMovement: return "figure.mixed.cardio"
        case .changing: return "arrow.up.arrow.down"
        case .offWrist: return "applewatch.slash"
        case .unclear: return "questionmark.circle"
        }
    }

    static let displayOrder: [ActivityFamily] = [
        .asleep, .sitting, .stillUnsure, .standing, .changing, .walking, .running, .otherMovement, .offWrist, .unclear,
    ]
}

// MARK: Section

struct ActivityContextSection: View {
    let document: ActivityContextDayDocument?
    let loading: Bool
    /// Visible x window, shared with the heart-rate graph above so the two stay lined up while zooming.
    let window: ClosedRange<Date>
    /// Widest y-axis label of the graph above, drawn invisibly so this lane's plot area starts at the same x.
    let axisLabelPlaceholder: String
    let onSelect: (ClosedRange<Date>) -> Void

    @State private var selectedStart: Int? = nil
    @State private var showAllEpisodes = false
    @State private var showAllEvents = false

    /// Events below this are too weak to show as "happened" (they are still stored).
    private static let eventFloor = 0.40
    private static let episodeFloorS = 60
    private static let collapsedEpisodes = 14
    private static let collapsedEvents = 8

    var body: some View {
        let episodes = document.map { ActivityContextEpisodes.build($0.runs) } ?? []
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            header
            if let document, !episodes.isEmpty {
                laneCard(document, episodes)
                detailCard(document, episodes)
                summaryGrid(document)
                episodeList(episodes)
                eventList(document)
            } else if loading {
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
            limitations
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text("Activity context")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                if loading && document != nil { ProgressView().controlSize(.small) }
            }
            Text("Posture, movement and arm behaviour, each as a probability and read over the last several minutes. Tap the bar or a stretch to see why.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.space1)
    }

    // MARK: Lane

    private func laneCard(_ doc: ActivityContextDayDocument, _ episodes: [ActivityEpisode]) -> some View {
        let marks = episodes.sorted { $0.durationSeconds > $1.durationSeconds }
        let events = doc.events.filter { $0.probability >= Self.eventFloor }
        return VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Chart {
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
                ForEach(Array(events.enumerated()), id: \.offset) { _, e in
                    PointMark(x: .value("Event", Date(timeIntervalSince1970: TimeInterval(e.ts))),
                              y: .value("Lane", 0.5))
                        .symbol(.diamond)
                        .symbolSize(34)
                        .foregroundStyle(StrandPalette.textPrimary)
                }
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
                                withAnimation(StrandMotion.interactive) { selectedStart = hit.start }
                            }
                        }
                }
            }
            .frame(height: 44)
            .accessibilityLabel(Text("Activity context timeline. The list of stretches below has the same information."))

            legend(doc)
        }
        .padding(NoopMetrics.space3)
        .background(NoopPanelSurface(cornerRadius: 20))
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

    private func legend(_ doc: ActivityContextDayDocument) -> some View {
        let seconds = familySeconds(doc)
        let present = ActivityFamily.displayOrder.filter { (seconds[$0] ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: 6) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)],
                      alignment: .leading, spacing: 6) {
                ForEach(present, id: \.self) { f in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(f.color).frame(width: 10, height: 10)
                        Text(f.title).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                if doc.events.contains(where: { $0.probability >= Self.eventFloor }) {
                    HStack(spacing: 5) {
                        Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(StrandPalette.textPrimary)
                        Text("Position change").font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
            Text("Fainter means less sure.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func familySeconds(_ doc: ActivityContextDayDocument) -> [ActivityFamily: Int] {
        var out: [ActivityFamily: Int] = [:]
        for (label, s) in doc.summary.labelSeconds { out[ActivityFamily.of(label), default: 0] += s }
        if doc.summary.unclearSeconds > 0 { out[.unclear, default: 0] += doc.summary.unclearSeconds }
        return out
    }

    // MARK: Detail

    private struct Detail {
        var title: String
        var caption: String
        var family: ActivityFamily
        var posture: HeadProbabilities<PostureClass>
        var locomotion: HeadProbabilities<LocomotionClass>
        var arm: HeadProbabilities<ArmBehaviorClass>
        var intensity: Double?
        var confidence: Double
        var sleep: SleepContextState
        var wear: WearContextState
        var zoom: ClosedRange<Date>?
        var isLatest: Bool
    }

    private func detail(_ doc: ActivityContextDayDocument, _ episodes: [ActivityEpisode]) -> Detail? {
        if let start = selectedStart, let ep = episodes.first(where: { $0.start == start }) {
            let from = Date(timeIntervalSince1970: TimeInterval(ep.start))
            let to = Date(timeIntervalSince1970: TimeInterval(ep.end))
            let dur = Double(ep.durationSeconds)
            let pad: TimeInterval = dur < 600 ? max(90, dur * 2) : dur * 0.15
            return Detail(title: ep.label,
                          caption: "\(Self.clock(from, seconds: ep.durationSeconds < 300)) – \(Self.clock(to, seconds: ep.durationSeconds < 300)) · \(DayStateTimelineSection.duration(ep.durationSeconds))",
                          family: ActivityFamily.of(ep.label), posture: ep.posture, locomotion: ep.locomotion,
                          arm: ep.armBehavior, intensity: ep.intensity, confidence: ep.confidence,
                          sleep: ep.sleep, wear: ep.wear,
                          zoom: from.addingTimeInterval(-pad)...to.addingTimeInterval(pad), isLatest: false)
        }
        guard let s = doc.latest else { return nil }
        let at = Date(timeIntervalSince1970: TimeInterval(s.ts))
        var caption = String(localized: "As of \(Self.clock(at, seconds: true))")
        if s.history.stationaryForS >= 60 {
            caption += " · " + String(localized: "still for \(DayStateTimelineSection.duration(s.history.stationaryForS))")
        }
        let label = s.displayContext ?? ActivityDisplay.unclear
        return Detail(title: label, caption: caption, family: ActivityFamily.of(label), posture: s.posture,
                      locomotion: s.locomotion, arm: s.armBehavior, intensity: s.intensity,
                      confidence: s.overallConfidence, sleep: s.sleep.state, wear: s.wear.state,
                      zoom: nil, isLatest: true)
    }

    @ViewBuilder
    private func detailCard(_ doc: ActivityContextDayDocument, _ episodes: [ActivityEpisode]) -> some View {
        if let d = detail(doc, episodes) {
            let color = d.family.color
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: d.family.symbol).foregroundStyle(color)
                    Text(d.title)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(d.isLatest ? String(localized: "Latest") : String(localized: "Selected"))
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Text(d.caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()

                confidenceRow(d.confidence, tint: color)

                HeadBlock(title: String(localized: "Posture"), rows: Self.rows(d.posture, name: \.displayName), tint: color)
                HeadBlock(title: String(localized: "Movement"), rows: Self.rows(d.locomotion, name: \.displayName), tint: color)
                HeadBlock(title: String(localized: "Arm"), rows: Self.rows(d.arm, name: \.displayName), tint: color)

                HStack(spacing: 8) {
                    if let i = d.intensity {
                        chip(String(localized: "Intensity \(Int((i * 100).rounded()))%"))
                    }
                    chip(d.sleep.displayName)
                    chip(d.wear.displayName)
                }

                if d.confidence < 0.55 && d.family != .offWrist {
                    Text("Conflicting or thin evidence here, so treat this as a guess.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }

                HStack(spacing: 12) {
                    if let zoom = d.zoom {
                        Button {
                            onSelect(zoom)
                        } label: {
                            Label("Zoom the graph here", systemImage: "magnifyingglass")
                        }
                        Button {
                            withAnimation(StrandMotion.interactive) { selectedStart = nil }
                        } label: {
                            Label("Back to latest", systemImage: "arrow.uturn.backward")
                        }
                    }
                }
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.accent)
                .buttonStyle(.plain)
            }
            .padding(NoopMetrics.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(color.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(color.opacity(0.30), lineWidth: 1))
        }
    }

    private func confidenceRow(_ confidence: Double, tint: Color) -> some View {
        HStack(spacing: 10) {
            Text("Confidence")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            ProbabilityBar(value: confidence, tint: tint)
            Text("\(Int((confidence * 100).rounded()))%")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func chip(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Capsule().fill(StrandPalette.surfaceInset))
    }

    /// The strongest answers of a head, most likely first. Anything under 5% is noise at this resolution.
    private static func rows<C: RawRepresentable & Hashable & CaseIterable & Sendable>(
        _ head: HeadProbabilities<C>, name: KeyPath<C, String>, limit: Int = 3
    ) -> [(name: String, p: Double)] where C.RawValue == String {
        head.values
            .filter { $0.value >= 0.05 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .prefix(limit)
            .map { (name: $0.key[keyPath: name], p: $0.value) }
    }

    // MARK: Summary

    private func summaryGrid(_ doc: ActivityContextDayDocument) -> some View {
        let total = max(1, doc.summary.labelSeconds.values.reduce(0, +) + doc.summary.unclearSeconds)
        let ranked: [(label: String, seconds: Int)] = doc.summary.labelSeconds
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .map { (label: $0.key, seconds: $0.value) }
        let tiles = Array(ranked.prefix(6))
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        return VStack(alignment: .leading, spacing: 10) {
            LazyVGrid(columns: columns, spacing: 10) {
                ForEach(tiles, id: \.label) { tile in
                    SummaryTile(label: tile.label, seconds: tile.seconds, total: total)
                }
            }
            if doc.summary.unclearSeconds > 0 {
                unlabelledNote(doc.summary.unclearSeconds)
            }
        }
    }

    private func unlabelledNote(_ seconds: Int) -> some View {
        let span = DayStateTimelineSection.duration(seconds)
        return Text("Left unlabelled when the evidence was too thin: \(span).")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .padding(.horizontal, NoopMetrics.space1)
    }

    // MARK: Episodes and events

    private func episodeList(_ all: [ActivityEpisode]) -> some View {
        let shown = all.filter { $0.durationSeconds >= Self.episodeFloorS }.reversed() as [ActivityEpisode]
        let visible = showAllEpisodes ? shown : Array(shown.prefix(Self.collapsedEpisodes))
        return VStack(alignment: .leading, spacing: 10) {
            Text("Stretches")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, NoopMetrics.space1)
            Text("A minute or longer, newest first.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .padding(.horizontal, NoopMetrics.space1)
            ForEach(visible) { ep in episodeBox(ep) }
            if shown.count > Self.collapsedEpisodes {
                Button {
                    withAnimation(StrandMotion.interactive) { showAllEpisodes.toggle() }
                } label: {
                    Text(showAllEpisodes ? String(localized: "Show fewer") : String(localized: "Show all \(shown.count)"))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, NoopMetrics.space1)
            }
        }
    }

    private func episodeBox(_ ep: ActivityEpisode) -> some View {
        let family = ActivityFamily.of(ep.label)
        let color = family.color
        let from = Date(timeIntervalSince1970: TimeInterval(ep.start))
        let to = Date(timeIntervalSince1970: TimeInterval(ep.end))
        let short = ep.durationSeconds < 300
        let postureHint = ep.posture.values
            .filter { $0.key != .unknown && $0.value >= 0.15 }
            .sorted { $0.value > $1.value }
            .prefix(2)
            .map { "\($0.key.displayName) \(Int(($0.value * 100).rounded()))%" }
            .joined(separator: " · ")
        return Button {
            withAnimation(StrandMotion.interactive) { selectedStart = ep.start }
            let dur = Double(ep.durationSeconds)
            let pad: TimeInterval = dur < 600 ? max(90, dur * 2) : dur * 0.15
            onSelect(from.addingTimeInterval(-pad)...to.addingTimeInterval(pad))
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 6)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline) {
                        Image(systemName: family.symbol).foregroundStyle(color)
                        Text(ep.label)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(2)
                        Spacer(minLength: 8)
                        Text(DayStateTimelineSection.duration(ep.durationSeconds))
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                            .monospacedDigit()
                    }
                    Text("\(Self.clock(from, seconds: short)) – \(Self.clock(to, seconds: short)) · \(Int((ep.confidence * 100).rounded()))% sure")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .monospacedDigit()
                    if !postureHint.isEmpty {
                        Text(postureHint)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(color.opacity(0.10)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(color.opacity(0.30), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Shows the probabilities for this stretch and zooms the heart rate graph to it")
    }

    @ViewBuilder
    private func eventList(_ doc: ActivityContextDayDocument) -> some View {
        let events = doc.events
            .filter { $0.probability >= Self.eventFloor }
            .sorted { $0.ts > $1.ts }
        if !events.isEmpty {
            let visible = showAllEvents ? events : Array(events.prefix(Self.collapsedEvents))
            VStack(alignment: .leading, spacing: 8) {
                Text("Position changes spotted")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, NoopMetrics.space1)
                Text("Each is a weak signal from how the wrist moved, with the chance it really happened.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, NoopMetrics.space1)
                VStack(spacing: 0) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { i, e in
                        HStack {
                            Text(e.kind.displayName)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Spacer(minLength: 8)
                            Text(Self.clock(Date(timeIntervalSince1970: TimeInterval(e.ts)), seconds: true))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .monospacedDigit()
                            Text("\(Int((e.probability * 100).rounded()))%")
                                .font(StrandFont.subhead.weight(.semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .monospacedDigit()
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.vertical, 8)
                        if i < visible.count - 1 { Divider().opacity(0.4) }
                    }
                }
                .padding(.horizontal, NoopMetrics.space3)
                .background(NoopPanelSurface(cornerRadius: 16))
                if events.count > Self.collapsedEvents {
                    Button {
                        withAnimation(StrandMotion.interactive) { showAllEvents.toggle() }
                    } label: {
                        Text(showAllEvents ? String(localized: "Show fewer") : String(localized: "Show all \(events.count)"))
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, NoopMetrics.space1)
                }
            }
        }
    }

    private var limitations: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("A wrist can't see how tall you are. Sitting and standing are inferred from how still you are, how you moved just before, and for how long, so they are only ever \"likely\", and a thin read stays \"Still, sitting or standing\".",
                  systemImage: "info.circle")
            Text("\"Desk-like\" means small, steady hand movement. It doesn't know whether you are typing. Sitting up in bed with a phone can read as sitting. Specific exercises, cycling, stairs and being in a vehicle are only named when a logged workout or the motion model supports it.")
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .padding(.horizontal, NoopMetrics.space1)
    }

    static func clock(_ d: Date, seconds: Bool = false) -> String {
        DayStateTimelineSection.clock(d, seconds: seconds)
    }
}

// MARK: Pieces

private struct SummaryTile: View {
    let label: String
    let seconds: Int
    let total: Int

    var body: some View {
        let family = ActivityFamily.of(label)
        let share = Int((Double(seconds) / Double(total) * 100).rounded())
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: family.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(family.color)
                Text(label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            Text(DayStateTimelineSection.duration(seconds))
                .font(StrandFont.rounded(24))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            Text("\(share)% of the tracked day")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(family.color.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(family.color.opacity(0.35), lineWidth: 1))
    }
}

private struct ProbabilityBar: View {
    let value: Double
    let tint: Color
    var width: CGFloat = 96

    var body: some View {
        Capsule()
            .fill(tint.opacity(0.18))
            .frame(width: width, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: width * CGFloat(min(1, max(0, value))), height: 6)
            }
    }
}

private struct HeadBlock: View {
    let title: String
    let rows: [(name: String, p: Double)]
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .textCase(.uppercase)
            if rows.isEmpty {
                Text("No reading")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.name)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    ProbabilityBar(value: row.p, tint: tint)
                    Text("\(Int((row.p * 100).rounded()))%")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}

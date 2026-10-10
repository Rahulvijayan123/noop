import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Sleep stages explorer (the Sleep tab's interactive hypnogram)
//
// The night's stepped hypnogram with one lane per physiology series beneath it, every lane on the same clock
// axis, one scrubber across all of them and a tooltip reading every lane at the scrubbed minute. Each lane is
// a series the phone already banks or the server already publishes, read for the night's window when its
// chip is first switched on:
//
//   Heart rate   1-minute buckets (`Repository.hrBuckets`, the night page's call)
//   RMSSD        5-minute windows from the strap's R-R (`Repository.bankedHrv`, the Key Metric gates)
//   Skin temp    5-minute means (`Repository.bankedSkinTemp`), in the user's temperature unit
//   Breathing    the rate estimated from the R-R rhythm (`timelineSeries(.respiration)`), else the
//                server's intraday breathing rate; a raw breathing waveform is not a rate and is not drawn
//
// Each lane has its own scale, labelled in its own unit. A hole longer than the series' cadence breaks the
// line, and a scrubbed minute with no reading says so: nothing is joined or interpolated across missing data.

/// One physiology series drawn as a lane under the stages.
enum SleepOverlay: String, CaseIterable, Identifiable, Hashable {
    case heartRate, rmssd, skinTemp, respiration, spo2

    var id: String { rawValue }

    var title: String {
        switch self {
        case .heartRate: return String(localized: "Heart rate")
        case .rmssd: return "RMSSD"
        case .skinTemp: return String(localized: "Skin temp")
        case .respiration: return String(localized: "Breathing")
        case .spo2: return "SpO₂"
        }
    }

    /// The lane's gutter and chip label, short enough to fit both.
    var shortTitle: String {
        switch self {
        case .heartRate: return "HR"
        case .rmssd: return "RMSSD"
        case .skinTemp: return String(localized: "Temp")
        case .respiration: return String(localized: "Breath")
        case .spo2: return "SpO₂"
        }
    }

    func unit(_ temperature: TemperatureUnit) -> String {
        switch self {
        case .heartRate: return "bpm"
        case .rmssd: return "ms"
        case .skinTemp: return temperature == .fahrenheit ? "°F" : "°C"
        case .respiration: return "br/min"
        case .spo2: return "%"
        }
    }

    var fractionDigits: Int {
        switch self {
        case .skinTemp, .respiration: return 1
        default: return 0
        }
    }

    /// The smallest span a lane's scale may have, so a flat night is not stretched into noise.
    func minSpan(_ temperature: TemperatureUnit) -> Double {
        switch self {
        case .heartRate: return 15
        case .rmssd: return 20
        case .skinTemp: return temperature == .fahrenheit ? 1.8 : 1
        case .respiration: return 4
        case .spo2: return 6
        }
    }

    var color: Color {
        switch self {
        case .heartRate: return StrandPalette.metricRose
        case .rmssd: return Color(light: "#6D3FE0", dark: "#A47BFF")
        case .skinTemp: return Color(light: "#C2410C", dark: "#FF8A4C")
        case .respiration: return Color(light: "#0F8F82", dark: "#3DD6C3")
        case .spo2: return Color(light: "#1D64C8", dark: "#5AA9FF")
        }
    }

    func format(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }
}

/// One series' readings for the night, oldest first, in display units.
struct SleepOverlaySeries: Equatable {
    struct Point: Equatable {
        let ts: Int
        let value: Double
    }

    var points: [Point] = []
    /// A gap between two readings longer than this breaks the line.
    var gapSeconds: Int = 300
    /// The farthest a reading may sit from a scrubbed time and still be that time's value.
    var matchSeconds: Int = 180

    var isEmpty: Bool { points.isEmpty }

    /// The reading nearest `ts` within `matchSeconds`; nil in a gap.
    func value(at ts: Int) -> Double? {
        guard !points.isEmpty else { return nil }
        var lo = 0, hi = points.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if points[mid].ts < ts { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter { $0 >= 0 && $0 < points.count }
        guard let best = candidates.min(by: { abs(points[$0].ts - ts) < abs(points[$1].ts - ts) }),
              abs(points[best].ts - ts) <= matchSeconds else { return nil }
        return points[best].value
    }

    /// The lane's scale: the readings inside the window, padded, never narrower than `minSpan`.
    func domain(from: Int, to: Int, minSpan: Double) -> ClosedRange<Double>? {
        let values = points.filter { $0.ts >= from - 60 && $0.ts <= to + 60 }.map(\.value)
        guard let lo = values.min(), let hi = values.max() else { return nil }
        let mid = (lo + hi) / 2
        let half = max(hi - lo, minSpan) / 2 * 1.12
        return (mid - half)...(mid + half)
    }
}

/// The lanes switched on and the series read so far, for one night. Shared by the card and its full-screen
/// view so both show the same selection. Owned by the card, never by `SleepView`, so a load landing never
/// re-renders the page.
@MainActor
final class SleepOverlayStore: ObservableObject {
    enum Load: Equatable {
        case loading
        case loaded(SleepOverlaySeries)
    }

    @Published private(set) var enabled: [SleepOverlay]
    @Published private(set) var loads: [SleepOverlay: Load] = [:]
    private(set) var window: (from: Int, to: Int)?
    private var tasks: [SleepOverlay: Task<Void, Never>] = [:]

    private static let defaultsKey = "sleep.stages.lanes.v2"

    init() {
        if let saved = UserDefaults.standard.string(forKey: Self.defaultsKey) {
            enabled = saved.split(separator: ",").compactMap { SleepOverlay(rawValue: String($0)) }
        } else {
            enabled = SleepOverlay.allCases
        }
    }

    func isOn(_ overlay: SleepOverlay) -> Bool { enabled.contains(overlay) }

    /// Lanes in their fixed order, whatever order they were switched on in.
    var orderedEnabled: [SleepOverlay] { SleepOverlay.allCases.filter(enabled.contains) }

    /// Point the store at a night. A different window drops every read, and the enabled lanes reload.
    func show(from: Int, to: Int, repo: Repository, temperature: TemperatureUnit) {
        if let window, window.from == from, window.to == to { return }
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        loads = [:]
        window = (from, to)
        for overlay in enabled { load(overlay, repo: repo, temperature: temperature) }
    }

    func toggle(_ overlay: SleepOverlay, repo: Repository, temperature: TemperatureUnit) {
        if let i = enabled.firstIndex(of: overlay) {
            enabled.remove(at: i)
        } else {
            enabled.append(overlay)
            if loads[overlay] == nil { load(overlay, repo: repo, temperature: temperature) }
        }
        UserDefaults.standard.set(enabled.map(\.rawValue).joined(separator: ","), forKey: Self.defaultsKey)
    }

    /// Re-read every loaded lane (the repository refreshed, or the temperature unit changed).
    func reload(repo: Repository, temperature: TemperatureUnit) {
        for overlay in loads.keys { load(overlay, repo: repo, temperature: temperature) }
    }

    func series(_ overlay: SleepOverlay) -> SleepOverlaySeries? {
        if case .loaded(let s)? = loads[overlay] { return s }
        return nil
    }

    private func load(_ overlay: SleepOverlay, repo: Repository, temperature: TemperatureUnit) {
        guard let window else { return }
        tasks[overlay]?.cancel()
        if loads[overlay] == nil { loads[overlay] = .loading }
        tasks[overlay] = Task { [weak self] in
            let series = await SleepOverlayLoader.load(overlay, repo: repo, from: window.from, to: window.to,
                                                       temperature: temperature)
            guard !Task.isCancelled, let self, let current = self.window,
                  current.from == window.from, current.to == window.to else { return }
            self.loads[overlay] = .loaded(series)
        }
    }
}

/// Reads one series for a night window. Every source is an existing read; nothing here derives a new metric.
enum SleepOverlayLoader {
    @MainActor
    static func load(_ overlay: SleepOverlay, repo: Repository, from: Int, to: Int,
                     temperature: TemperatureUnit) async -> SleepOverlaySeries {
        switch overlay {
        case .heartRate:
            let buckets = await repo.hrBuckets(from: from, to: to, bucketSeconds: 60)
            return SleepOverlaySeries(points: buckets.map { .init(ts: $0.ts, value: $0.bpm) },
                                      gapSeconds: 300, matchSeconds: 120)
        case .rmssd:
            let banked = await repo.bankedHrv(sdnn: false, from: from, to: to)
            return SleepOverlaySeries(points: banked.points.map { .init(ts: $0.ts, value: $0.value) },
                                      gapSeconds: 450, matchSeconds: 300)
        case .skinTemp:
            let banked = await repo.bankedSkinTemp(from: from, to: to)
            let convert: (Double) -> Double = temperature == .fahrenheit ? { $0 * 9 / 5 + 32 } : { $0 }
            return SleepOverlaySeries(points: banked.points.map { .init(ts: $0.ts, value: convert($0.value)) },
                                      gapSeconds: 900, matchSeconds: 300)
        case .respiration:
            let local = await repo.timelineSeries(metric: .respiration, from: from, to: to, targetPoints: 240)
            if local.derivedFromRR, !local.points.isEmpty {
                let step = max(local.bucketSeconds, 60)
                return SleepOverlaySeries(
                    points: local.points.map { .init(ts: Int($0.date.timeIntervalSince1970), value: $0.value) },
                    gapSeconds: max(step * 3, 600), matchSeconds: max(step, 300))
            }
            return await serverRespiration(from: from, to: to)
        case .spo2:
            let banked = await repo.bankedSpo2(from: from, to: to)
            return SleepOverlaySeries(points: banked.points.map { .init(ts: $0.ts, value: $0.value) },
                                      gapSeconds: 900, matchSeconds: 300)
        }
    }

    /// The server's intraday breathing rate for the window, for a strap whose own channel is a waveform.
    @MainActor
    private static func serverRespiration(from: Int, to: Int) async -> SleepOverlaySeries {
        guard CloudPushIdentityStore.current() != nil,
              let repository = CloudPushRuntime.shared.scoreRepository(),
              let window = try? await repository.intradaySeries(
                from: from, to: to, deviceId: IntradaySeriesStore.shared.readDeviceId,
                metrics: [.respiratoryRate], cacheKey: "sleep-night-resp|\(from)|\(to)") else {
            return SleepOverlaySeries()
        }
        let bucket = window.bucketSeconds(for: .respiratoryRate)
        let points = (window.metrics[.respiratoryRate] ?? [])
            .filter { $0.coverage > 0 && $0.value.isFinite && $0.start >= from && $0.start <= to }
            .sorted { $0.start < $1.start }
            .map { SleepOverlaySeries.Point(ts: $0.start, value: $0.value) }
        return SleepOverlaySeries(points: points, gapSeconds: max(bucket * 2, 600), matchSeconds: max(bucket, 300))
    }
}

// MARK: - Card

/// The Sleep tab's stages card: header, the explorer (stages, lanes, scrubber, tooltip), the lane toggles,
/// the stage durations and the night's caveats. Expands to a full-screen view of the same explorer.
struct SleepStagesCard: View {
    let night: Night
    let isStub: Bool
    let caveats: [SleepCaveat]
    let isLoading: Bool

    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @StateObject private var store = SleepOverlayStore()
    @State private var highlighted: SleepStage?
    @State private var expanded = false
    @State private var caveatsOpen = false
    @Environment(\.colorScheme) private var colorScheme

    private var temperature: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .imperial, override: temperatureRaw)
    }

    private var model: SleepStagesModel { SleepStagesModel(night: night, isStub: isStub) }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                header
                if isLoading {
                    ChartPlaceholder(height: SleepStagesExplorer.compactHeight)
                } else {
                    SleepStagesExplorer(model: model, store: store, temperature: temperature,
                                        highlighted: $highlighted, layout: .compact)
                }
                SleepLaneToggles(store: store, temperature: temperature)
                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                SleepStageDurationRow(stages: isStub || isLoading ? nil : night.stages, highlighted: $highlighted)
                caveatRow
            }
        }
        .task(id: "\(night.session.effectiveStartTs)|\(night.session.endTs)|\(isLoading)") {
            guard !isLoading else { return }
            store.show(from: night.session.effectiveStartTs, to: night.session.endTs, repo: repo,
                       temperature: temperature)
        }
        .onChangeCompat(of: temperature) { _ in store.reload(repo: repo, temperature: temperature) }
        .onChangeCompat(of: repo.refreshSeq) { _ in store.reload(repo: repo, temperature: temperature) }
        .onChangeCompat(of: night.session.endTs) { _ in
            highlighted = nil
            caveatsOpen = false
        }
        #if os(iOS)
        .fullScreenCover(isPresented: $expanded) { fullScreen }
        #else
        .sheet(isPresented: $expanded) { fullScreen.frame(minWidth: 720, minHeight: 720) }
        #endif
    }

    private var header: some View {
        HStack(alignment: .top, spacing: NoopMetrics.space3) {
            Image(systemName: "moon.zzz.fill")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(StrandPalette.restBright)
                .frame(width: 30, height: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text("Sleep stages")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(model.subtitle)
                    .font(StrandFont.footnote.monospacedDigit())
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            Spacer(minLength: 0)
            if !isLoading {
                Button { expanded = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, -NoopMetrics.space2)
                .padding(.trailing, -NoopMetrics.space3)
                .accessibilityLabel("Expand sleep stages")
            }
        }
    }

    /// The night's caveats: the first badge, opening every note in place.
    @ViewBuilder
    private var caveatRow: some View {
        if let first = caveats.first {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { caveatsOpen.toggle() }
                } label: {
                    HStack(spacing: NoopMetrics.space2) {
                        SleepCaveatBadge(caveat: first)
                        if caveats.count > 1 {
                            Text("+\(caveats.count - 1)")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(StrandFont.icon(.inline))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(caveatsOpen ? 180 : 0))
                            .accessibilityHidden(true)
                    }
                    .frame(minHeight: NoopMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityHint(Text(caveatsOpen ? "Hides the notes" : "Shows the notes"))
                if caveatsOpen {
                    ForEach(caveats) { caveat in
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            if caveat != first || caveats.count > 1 { SleepCaveatBadge(caveat: caveat) }
                            Text(caveat.message)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }

    private var fullScreen: some View {
        SleepStagesFullScreen(model: model, stages: isStub ? nil : night.stages, store: store,
                              temperature: temperature, highlighted: $highlighted)
            .environmentObject(repo)
            // A presented cover keeps the scheme it was presented with, not the app's chosen appearance.
            .preferredColorScheme(colorScheme)
    }
}

/// What the explorer draws for one night, resolved once per render of the card.
struct SleepStagesModel {
    let onset: Date
    let end: Date
    /// The smoothed stage timeline; nil when the night has no real segments (an imported night or a stub).
    let timeline: NightTimeline?
    let isStub: Bool
    let subtitle: String

    init(night: Night, isStub: Bool) {
        onset = night.onsetDate
        end = max(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)), night.onsetDate.addingTimeInterval(60))
        self.isStub = isStub
        timeline = (night.realSegments?.count ?? 0) >= 2
            ? NightTimeline(onset: night.onsetDate, end: end, intervals: night.intervals)
            : nil
        subtitle = "\(SleepFormat.nightDateLine(night.session.endTs)) · "
            + SleepFormat.window(night.session.effectiveStartTs, night.session.endTs)
    }

    var span: TimeInterval { max(1, end.timeIntervalSince(onset)) }
    var window: ClosedRange<Date> { onset...end }
    var fromTs: Int { Int(onset.timeIntervalSince1970) }
    var toTs: Int { Int(end.timeIntervalSince1970) }
}

/// The expanded explorer at the screen's height, with the same toggles and durations.
private struct SleepStagesFullScreen: View {
    let model: SleepStagesModel
    let stages: Stages?
    @ObservedObject var store: SleepOverlayStore
    let temperature: TemperatureUnit
    @Binding var highlighted: SleepStage?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    HStack(alignment: .center) {
                        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                            Text("Sleep stages")
                                .font(StrandFont.title2)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(model.subtitle)
                                .font(StrandFont.footnote.monospacedDigit())
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        Spacer(minLength: 0)
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .font(StrandFont.icon(.row))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                                .background(Circle().fill(StrandPalette.surfaceInset))
                        }
                        .buttonStyle(.plain)
                        .keyboardShortcut(.cancelAction)
                        .accessibilityLabel("Close")
                    }
                    SleepStagesExplorer(model: model, store: store, temperature: temperature,
                                        highlighted: $highlighted,
                                        layout: .expanded(height: max(420, geo.size.height - 330)))
                    SleepLaneToggles(store: store, temperature: temperature)
                    Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                    SleepStageDurationRow(stages: stages, highlighted: $highlighted)
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}

// MARK: - Explorer

/// The hypnogram, one lane per enabled series, the shared clock axis, the scrubber and its tooltip.
struct SleepStagesExplorer: View {
    enum Layout: Equatable {
        case compact
        /// The whole explorer's height (stages + lanes), divided between them.
        case expanded(height: CGFloat)
    }

    let model: SleepStagesModel
    @ObservedObject var store: SleepOverlayStore
    let temperature: TemperatureUnit
    @Binding var highlighted: SleepStage?
    var layout: Layout = .compact

    @State private var selection: Date?

    static let labelWidth: CGFloat = 50
    static let valueWidth: CGFloat = 30
    static let gutter: CGFloat = labelWidth + valueWidth
    static let gutterSpacing: CGFloat = 6
    static let axisHeight: CGFloat = 18
    static let hintHeight: CGFloat = 28
    static let laneGap: CGFloat = 8
    static let compactStageHeight: CGFloat = 132
    static let compactLaneHeight: CGFloat = 46
    /// The compact explorer with every lane on, for placeholders.
    static let compactHeight: CGFloat = hintHeight + NoopMetrics.space2 + compactStageHeight
        + CGFloat(SleepOverlay.allCases.count) * (compactLaneHeight + laneGap) + laneGap + axisHeight

    private let stagesTopToBottom: [SleepStage] = [.awake, .rem, .light, .deep]

    private var lanes: [SleepOverlay] { store.orderedEnabled }

    private var stageHeight: CGFloat {
        switch layout {
        case .compact: return Self.compactStageHeight
        case .expanded(let h): return max(160, h * 0.38)
        }
    }

    private var laneHeight: CGFloat {
        switch layout {
        case .compact: return Self.compactLaneHeight
        case .expanded(let h):
            let rest = h - stageHeight - Self.axisHeight
            return min(110, max(54, rest / CGFloat(max(1, lanes.count)) - Self.laneGap))
        }
    }

    var body: some View {
        let axis = ChartAxis.layout(model.window, style: .hours)
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            hint
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: Self.gutterSpacing) {
                    VStack(alignment: .leading, spacing: Self.laneGap) {
                        stageGutter
                        ForEach(lanes) { laneGutter($0) }
                    }
                    .frame(width: Self.gutter)
                    VStack(alignment: .leading, spacing: Self.laneGap) {
                        stagePlot(grid: axis.grid)
                            .frame(height: stageHeight)
                        ForEach(lanes) { lanePlot($0, grid: axis.grid) }
                    }
                    .overlay { selectionRule }
                    .overlay { scrubSurface }
                }
                xAxis(axis)
                    .padding(.top, Self.laneGap)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Sleep stages"))
            .accessibilityValue(Text(accessibilityValue))
            .accessibilityAdjustableAction { direction in
                let step: TimeInterval = 15 * 60
                let current = selection ?? model.onset
                let next = direction == .increment ? current.addingTimeInterval(step) : current.addingTimeInterval(-step)
                selection = min(model.end, max(model.onset, next))
            }
        }
        .onChangeCompat(of: model.toTs) { _ in selection = nil }
    }

    /// "Drag to inspect" at rest; while inspecting, the scrubbed time and stage with a way to clear it. The
    /// lane values sit in each lane's gutter, so nothing covers the chart.
    @ViewBuilder
    private var hint: some View {
        if let selected = selection {
            let stage = model.timeline?.segment(at: selected)?.stage
            HStack(spacing: NoopMetrics.space2) {
                Text(Night.clockString(Int(selected.timeIntervalSince1970)))
                    .font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                    .foregroundStyle(StrandPalette.textPrimary)
                Circle()
                    .fill(stage.map(StrandPalette.sleepStageColor) ?? StrandPalette.textTertiary)
                    .frame(width: 8, height: 8)
                Text(stage?.label ?? String(localized: "No stage"))
                    .font(StrandFont.footnote.weight(.medium))
                    .foregroundStyle(stage == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Spacer(minLength: 0)
                Button { set(nil) } label: {
                    Label("Clear", systemImage: "xmark.circle.fill")
                        .font(StrandFont.footnote.weight(.medium))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(minHeight: NoopMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear inspected time")
            }
            .frame(height: Self.hintHeight)
        } else {
            HStack(spacing: 6) {
                Spacer(minLength: 0)
                Image(systemName: "arrow.left.and.right")
                    .font(StrandFont.icon(.inline))
                    .accessibilityHidden(true)
                Text("Drag or tap to inspect")
                    .font(StrandFont.footnote)
            }
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(height: Self.hintHeight)
            .accessibilityHidden(true)
        }
    }

    private var selectedStage: SleepStage? {
        selection.flatMap { model.timeline?.segment(at: $0)?.stage }
    }

    // MARK: Stages

    private var stageGutter: some View {
        let rows = CGFloat(stagesTopToBottom.count)
        let barH = stageHeight / (rows + 1)
        let spacing = (stageHeight - barH * rows) / (rows - 1)
        return ZStack(alignment: .topLeading) {
            ForEach(Array(stagesTopToBottom.enumerated()), id: \.element) { rank, stage in
                let emphasized = selection == nil ? highlighted == stage : selectedStage == stage
                HStack(spacing: 5) {
                    Circle().fill(StrandPalette.sleepStageColor(stage)).frame(width: 7, height: 7)
                    Text(stage.label)
                        .font(emphasized ? StrandFont.footnote.weight(.semibold) : StrandFont.footnote)
                        .foregroundStyle(emphasized ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: Self.gutter, height: barH + spacing, alignment: .leading)
                .offset(y: (barH + spacing) * CGFloat(rank) + barH / 2 - (barH + spacing) / 2)
            }
        }
        .frame(width: Self.gutter, height: stageHeight, alignment: .topLeading)
    }

    @ViewBuilder
    private func stagePlot(grid: [Date]) -> some View {
        let highlightedStage = highlighted
        ZStack {
            // The bar-and-connector drawing is ported from SleepChartKit's `SleepTimelineGraph`
            // (github.com/DanielJamesTronca/SleepChartKit, MIT License, Copyright (c) Daniel James Tronca).
            Canvas { ctx, size in
                let w = size.width, h = size.height
                let rows = CGFloat(stagesTopToBottom.count)
                let barH = h / (rows + 1)
                let spacing = (h - barH * rows) / (rows - 1)
                func rowY(_ rank: Int) -> CGFloat { (barH + spacing) * CGFloat(rank) }

                for g in grid {
                    let gx = CGFloat(g.timeIntervalSince(model.onset) / model.span) * w
                    guard gx > 0.5, gx < w - 0.5 else { continue }
                    var p = Path()
                    p.move(to: CGPoint(x: gx, y: 0)); p.addLine(to: CGPoint(x: gx, y: h))
                    ctx.stroke(p, with: .color(StrandPalette.textTertiary.opacity(0.5)),
                               style: StrokeStyle(lineWidth: 0.5, dash: [2, 3]))
                }
                guard let timeline = model.timeline else { return }

                var previous: (rect: CGRect, stage: SleepStage)?
                for seg in timeline.segments {
                    let x0 = CGFloat(seg.start / model.span) * w, x1 = CGFloat(seg.end / model.span) * w
                    let rect = CGRect(x: x0, y: rowY(seg.stage.bandRank), width: max(1, x1 - x0), height: barH)
                    let dimmed = highlightedStage != nil && seg.stage != highlightedStage
                    ctx.fill(Path(roundedRect: rect, cornerRadius: barH / 6),
                             with: .color(StrandPalette.sleepStageColor(seg.stage).opacity(dimmed ? 0.25 : 1)))
                    if let previous, previous.stage != seg.stage {
                        let start = CGPoint(x: previous.rect.maxX, y: previous.rect.midY)
                        let end = CGPoint(x: rect.minX, y: rect.midY)
                        var connector = Path()
                        connector.move(to: start)
                        connector.addCurve(to: end,
                                           control1: CGPoint(x: start.x + (end.x - start.x) * 0.3, y: start.y),
                                           control2: CGPoint(x: start.x + (end.x - start.x) * 0.7, y: end.y))
                        ctx.stroke(connector, with: .color(Color.gray.opacity(0.4)), lineWidth: 1.5)
                    }
                    previous = (rect, seg.stage)
                }
            }
            if model.timeline == nil {
                Text(model.isStub ? "No stage data recorded for this night" : "Stage totals only, no timeline")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, NoopMetrics.space3)
                    .padding(.vertical, NoopMetrics.space2)
                    .background(Capsule().fill(StrandPalette.surfaceRaised))
            }
        }
    }

    // MARK: Lanes

    private func laneGutter(_ overlay: SleepOverlay) -> some View {
        let series = store.series(overlay)
        let domain = series?.domain(from: model.fromTs, to: model.toTs, minSpan: overlay.minSpan(temperature))
        return Group {
            if let selected = selection, let series, !series.isEmpty {
                selectedGutter(overlay, value: series.value(at: Int(selected.timeIntervalSince1970)))
            } else {
                restingGutter(overlay, domain: domain)
            }
        }
        .frame(height: laneHeight)
    }

    /// While inspecting: the lane's value at the scrubbed minute, in the lane's colour.
    private func selectedGutter(_ overlay: SleepOverlay, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(overlay.shortTitle)
                .font(StrandFont.caption.weight(.medium))
                .foregroundStyle(overlay.color)
            if let value {
                (Text(overlay.format(value)).font(StrandFont.subhead.weight(.semibold).monospacedDigit())
                 + Text(" \(overlay.unit(temperature))").font(StrandFont.caption))
                    .foregroundColor(StrandPalette.textPrimary)
            } else {
                Text("No reading")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .frame(width: Self.gutter, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .center)
    }

    private func restingGutter(_ overlay: SleepOverlay, domain: ClosedRange<Double>?) -> some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text(overlay.shortTitle)
                    .font(StrandFont.caption.weight(.medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("(\(overlay.unit(temperature)))")
                    .font(StrandFont.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .foregroundStyle(overlay.color)
            .frame(width: Self.labelWidth, alignment: .leading)
            VStack(alignment: .trailing, spacing: 0) {
                if let domain {
                    Text(overlay.format(domain.upperBound))
                    Spacer(minLength: 0)
                    Text(overlay.format(domain.lowerBound))
                }
            }
            .font(NaraChartStyle.axisFont)
            .foregroundStyle(NaraChartStyle.axisColor)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(width: Self.valueWidth, alignment: .trailing)
        }
    }

    @ViewBuilder
    private func lanePlot(_ overlay: SleepOverlay, grid: [Date]) -> some View {
        switch store.loads[overlay] {
        case .loaded(let series) where !series.isEmpty:
            if let domain = series.domain(from: model.fromTs, to: model.toTs, minSpan: overlay.minSpan(temperature)) {
                laneCanvas(overlay, series: series, domain: domain, grid: grid)
                    .frame(height: laneHeight)
            } else {
                laneMessage("No readings this night")
            }
        case .loaded:
            laneMessage("No readings this night")
        default:
            ChartPlaceholder(height: laneHeight)
        }
    }

    private func laneMessage(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity)
            .frame(height: laneHeight)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(StrandPalette.surfaceInset.opacity(0.5)))
    }

    private func laneCanvas(_ overlay: SleepOverlay, series: SleepOverlaySeries, domain: ClosedRange<Double>,
                            grid: [Date]) -> some View {
        let selected = selection
        let from = model.fromTs, to = model.toTs
        return Canvas { ctx, size in
            let w = size.width, h = size.height
            let inset: CGFloat = 4
            func x(_ ts: Int) -> CGFloat { w * CGFloat(ts - from) / CGFloat(max(1, to - from)) }
            func y(_ v: Double) -> CGFloat {
                inset + (h - 2 * inset) * (1 - CGFloat((v - domain.lowerBound) / (domain.upperBound - domain.lowerBound)))
            }
            ctx.fill(Path(roundedRect: CGRect(x: 0, y: 0, width: w, height: h), cornerRadius: 6),
                     with: .color(overlay.color.opacity(0.05)))
            drawGrid(ctx, grid: grid, size: size)

            let visible = series.points.filter { $0.ts >= from - 60 && $0.ts <= to + 60 }
            var runs: [[CGPoint]] = []
            var prevTs: Int?
            for p in visible {
                let pt = CGPoint(x: x(p.ts), y: y(p.value))
                if let prev = prevTs, p.ts - prev <= series.gapSeconds, !runs.isEmpty {
                    runs[runs.count - 1].append(pt)
                } else {
                    runs.append([pt])
                }
                prevTs = p.ts
            }
            for run in runs {
                guard let first = run.first, let last = run.last else { continue }
                if run.count == 1 {
                    // A reading with no neighbour inside the gap limit is still a reading: a dot, not nothing.
                    ctx.fill(Path(ellipseIn: CGRect(x: first.x - 2, y: first.y - 2, width: 4, height: 4)),
                             with: .color(overlay.color))
                    continue
                }
                var line = Path()
                line.move(to: first)
                run.dropFirst().forEach { line.addLine(to: $0) }
                var area = line
                area.addLine(to: CGPoint(x: last.x, y: h))
                area.addLine(to: CGPoint(x: first.x, y: h))
                area.closeSubpath()
                ctx.fill(area, with: .linearGradient(
                    Gradient(colors: [overlay.color.opacity(0.22), overlay.color.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: h)))
                ctx.stroke(line, with: .color(overlay.color),
                           style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
            if let selected, let v = series.value(at: Int(selected.timeIntervalSince1970)) {
                let pt = CGPoint(x: x(Int(selected.timeIntervalSince1970)), y: y(v))
                let r = CGRect(x: pt.x - 4.5, y: pt.y - 4.5, width: 9, height: 9)
                ctx.fill(Path(ellipseIn: r), with: .color(overlay.color))
                ctx.stroke(Path(ellipseIn: r), with: .color(StrandPalette.surfaceRaised), lineWidth: 1.5)
            }
        }
    }

    // MARK: Selection

    private var selectionRule: some View {
        let selected = selection
        let span = model.span, onset = model.onset
        return Canvas { ctx, size in
            guard let selected else { return }
            let sx = CGFloat(selected.timeIntervalSince(onset) / span) * size.width
            var p = Path()
            p.move(to: CGPoint(x: sx, y: 0)); p.addLine(to: CGPoint(x: sx, y: size.height))
            ctx.stroke(p, with: .color(NaraChartStyle.selectionColor), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .allowsHitTesting(false)
    }

    // MARK: Axis

    private func xAxis(_ axis: ChartXAxisLayout) -> some View {
        HStack(spacing: Self.gutterSpacing) {
            Color.clear.frame(width: Self.gutter, height: 1)
            GeometryReader { geo in
                ForEach(Array(axis.marks.enumerated()), id: \.offset) { i, mark in
                    if i < axis.labels.count {
                        let x = CGFloat(mark.timeIntervalSince(model.onset) / model.span) * geo.size.width
                        let anchor = i < axis.anchors.count ? axis.anchors[i] : .center
                        Text(axis.labels[i])
                            .font(NaraChartStyle.axisFont)
                            .foregroundStyle(NaraChartStyle.axisColor)
                            .fixedSize()
                            .alignmentGuide(.leading) { d in
                                switch anchor {
                                case .leading: return -x
                                case .trailing: return d.width - x
                                case .center: return d.width / 2 - x
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .frame(height: Self.axisHeight)
        .accessibilityHidden(true)
    }

    private func drawGrid(_ ctx: GraphicsContext, grid: [Date], size: CGSize) {
        for g in grid {
            let gx = CGFloat(g.timeIntervalSince(model.onset) / model.span) * size.width
            guard gx > 0.5, gx < size.width - 0.5 else { continue }
            var p = Path()
            p.move(to: CGPoint(x: gx, y: 0)); p.addLine(to: CGPoint(x: gx, y: size.height))
            ctx.stroke(p, with: .color(NaraChartStyle.gridColor), style: NaraChartStyle.grid)
        }
    }

    // MARK: Scrub

    @ViewBuilder
    private var scrubSurface: some View {
        GeometryReader { geo in
            #if canImport(UIKit) && os(iOS)
            HorizontalScrubSurface(
                onScrub: { set(time(x: $0, width: geo.size.width)) },
                onEnd: { set(nil) },
                onTap: { x in
                    let tapped = time(x: x, width: geo.size.width)
                    set(ChartSelection.afterTap(current: selection, tapped: tapped))
                })
            #else
            Rectangle().fill(Color.clear).contentShape(Rectangle())
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let p): set(time(x: p.x, width: geo.size.width))
                    case .ended: set(nil)
                    }
                }
            #endif
        }
    }

    /// The x position as a clock time inside the window, to the minute.
    private func time(x: CGFloat, width: CGFloat) -> Date? {
        guard width > 0 else { return nil }
        let frac = min(1, max(0, Double(x / width)))
        let raw = model.onset.addingTimeInterval(frac * model.span)
        let snapped = (raw.timeIntervalSince1970 / 60).rounded() * 60
        return min(model.end, max(model.onset, Date(timeIntervalSince1970: snapped)))
    }

    private func set(_ next: Date?) {
        guard next != selection else { return }
        if let next, let timeline = model.timeline,
           timeline.segment(at: next)?.id != selection.flatMap({ timeline.segment(at: $0)?.id }) {
            StrandHaptic.selection.play()
        }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { selection = next }
    }

    private var accessibilityValue: String {
        guard let selected = selection else {
            guard let timeline = model.timeline else { return "" }
            return [SleepStage.deep, .rem, .light, .awake].compactMap { stage -> String? in
                let m = timeline.minutes(stage)
                return m > 0 ? "\(stage.label) \(SleepFormat.duration(m))" : nil
            }.joined(separator: ", ")
        }
        let ts = Int(selected.timeIntervalSince1970)
        var parts = [Night.clockString(ts)]
        if let seg = model.timeline?.segment(at: selected) { parts.append(seg.stage.label) }
        for overlay in lanes {
            guard let series = store.series(overlay), !series.isEmpty else { continue }
            if let v = series.value(at: ts) {
                parts.append("\(overlay.title) \(overlay.format(v)) \(overlay.unit(temperature))")
            } else {
                parts.append("\(overlay.title) no reading")
            }
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Lane toggles

/// One checkbox chip per series: switches its lane on or off. The chip is the lane's legend too.
struct SleepLaneToggles: View {
    @ObservedObject var store: SleepOverlayStore
    let temperature: TemperatureUnit
    @EnvironmentObject private var repo: Repository

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: NoopMetrics.space2)],
                  alignment: .leading, spacing: NoopMetrics.space2) {
            ForEach(SleepOverlay.allCases) { chip($0) }
        }
    }

    private func chip(_ overlay: SleepOverlay) -> some View {
        let on = store.isOn(overlay)
        return Button {
            store.toggle(overlay, repo: repo, temperature: temperature)
        } label: {
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(on ? overlay.color : Color.clear)
                    Circle()
                        .stroke(overlay.color, lineWidth: on ? 0 : 1.5)
                    if on {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                    }
                }
                .frame(width: 18, height: 18)
                VStack(alignment: .leading, spacing: 0) {
                    Text(overlay.title)
                        .font(StrandFont.caption.weight(.medium))
                        .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    Text("(\(overlay.unit(temperature)))")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, NoopMetrics.space2)
            .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget + 4)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(on ? overlay.color.opacity(0.1) : StrandPalette.surfaceInset.opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(on ? overlay.color.opacity(0.4) : StrandPalette.hairline, lineWidth: 1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text("\(overlay.title) lane"))
        .accessibilityValue(Text(on ? "On" : "Off"))
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

// MARK: - Stage durations

/// The night's time in each stage and its share, as four columns. Tap a stage to highlight it on the chart.
struct SleepStageDurationRow: View {
    /// nil: no stage totals for this night (each column shows a dash).
    let stages: Stages?
    @Binding var highlighted: SleepStage?

    private let order: [SleepStage] = [.awake, .rem, .light, .deep]

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Sleep stage duration")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 0) {
                ForEach(order.indices, id: \.self) { i in
                    if i > 0 {
                        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 52)
                    }
                    column(order[i])
                }
            }
        }
    }

    private func column(_ stage: SleepStage) -> some View {
        let hasData = (stages?.total ?? 0) > 0
        let minutes = stages.map { StageLegendRow.minutes(stage, in: $0) } ?? 0
        let share = stages.map { StageLegendRow.share(stage, in: $0) } ?? 0
        let isOn = highlighted == stage
        let dimmed = highlighted != nil && !isOn
        return Button {
            highlighted = isOn ? nil : stage
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(StrandPalette.sleepStageColor(stage)).frame(width: 10, height: 10)
                    Text(stage.label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Text(hasData ? SleepFormat.duration(minutes) : "–")
                    .font(StrandFont.number(17))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text(hasData ? "\(share)%" : " ")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(.horizontal, NoopMetrics.space2)
            .padding(.vertical, NoopMetrics.space1)
            .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget, alignment: .leading)
            .background {
                if isOn { NoopInsetSurface() }
            }
            .opacity(dimmed ? 0.5 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!hasData)
        .accessibilityLabel(Text(hasData
            ? "\(stage.label), \(SleepFormat.duration(minutes)), \(share) percent"
            : "\(stage.label), not available"))
        .accessibilityHint(Text("Highlights this stage on the sleep chart"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A card's title: a tinted glyph and the name, in the Sleep tab's one heading style.
struct SleepCardTitle: View {
    let icon: String
    let title: LocalizedStringKey
    var tint: Color = StrandPalette.restBright

    var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: icon)
                .font(StrandFont.icon(.row))
                .foregroundStyle(tint)
                .frame(width: 22)
                .accessibilityHidden(true)
            Text(title)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityAddTraits(.isHeader)
    }
}

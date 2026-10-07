import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// Watchdog for the last half-hour. Monitor embeds the live card; the homepage Watchdog ring opens the
/// full screen, which adds the triggered events.
@MainActor
struct WatchdogPlaceholderView: View {
    var embedded: Bool = false

    var body: some View {
        if embedded {
            WatchdogLiveCard()
        } else {
            ScreenScaffold(
                title: "Watchdog",
                subtitle: "Last 30 minutes. Separate from Charge.",
                topBackground: liquidScaffoldSky()
            ) {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    WatchdogLiveCard()
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        NaraSectionHeader(title: "Triggered events",
                                          subtitle: "Last 21 days. Tap one to see why it opened.")
                        WatchdogEventsCard()
                    }
                }
            }
        }
    }
}

private struct WatchdogPick: Identifiable, Equatable {
    let id: String
}

enum WatchdogTone {
    static func color(_ state: HeroRings.WatchdogState) -> Color {
        switch state {
        case .calm: return StrandPalette.statusPositive
        case .watching: return StrandPalette.statusWarning
        case .alert: return StrandPalette.statusCritical
        case .waiting, .offWrist: return StrandPalette.textTertiary
        }
    }
}

/// The live call, then one tile per vital. A tile opens that vital's half-hour graph and usual range.
@MainActor
struct WatchdogLiveCard: View {
    @EnvironmentObject private var store: BaselineStore
    @EnvironmentObject private var repo: Repository
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @State private var picked: WatchdogPick?

    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                     override: temperatureRaw)
    }

    private var snapshot: WatchdogLiveSnapshot {
        WatchdogLiveSnapshot(store: store, temperatureUnit: temperatureUnit)
    }

    private var state: HeroRings.WatchdogState { HeroRings.watchdogState(store.watchdogResult) }

    private var headline: String {
        guard let result = store.watchdogResult else {
            return "Waiting for the first half-hour check."
        }
        return result.headline
    }

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    var body: some View {
        let snap = snapshot
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                header(snap)
                if let caption = snap.certaintyCaption {
                    Text(caption)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let recovery = store.eventRecovery, recovery.status != .noReference {
                    Text(recovery.headline)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.pendingEpisodeNote != nil {
                    Button {
                        store.showEpisodeNoteSheet = true
                    } label: {
                        Label("Add a note about the last alert", systemImage: "square.and.pencil")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                }
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(snap.metrics) { row in
                        Button { picked = WatchdogPick(id: row.id) } label: {
                            WatchdogVitalTile(row: row)
                        }
                        .buttonStyle(LiquidPressStyle())
                        .accessibilityHint("Shows the half-hour graph and usual range")
                    }
                }
            }
        }
        .onAppear { WatchdogNotifier.requestAuthorization() }
        .sheet(item: $picked) { pick in
            if let row = snapshot.metrics.first(where: { $0.id == pick.id }) {
                WatchdogVitalSheet(row: row, isLive: snapshot.isLive, bandCaption: snapshot.bandCaption)
            }
        }
        .sheet(isPresented: $store.showEpisodeNoteSheet) {
            WatchdogEpisodeNoteSheet(deviceId: repo.deviceId) {
                store.showEpisodeNoteSheet = false
            }
            .environmentObject(store)
        }
    }

    private func header(_ snap: WatchdogLiveSnapshot) -> some View {
        let tone = WatchdogTone.color(state)
        return HStack(alignment: .center, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 0.9)) { timeline in
                let pulse = snap.isLive && Int(timeline.date.timeIntervalSince1970 / 0.9) % 2 == 0
                ZStack {
                    Circle().fill(tone.opacity(0.16))
                    Circle().fill(tone)
                        .frame(width: 12, height: 12)
                        .opacity(snap.isLive ? (pulse ? 1 : 0.4) : 0.7)
                }
                .frame(width: 40, height: 40)
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(HeroRings.watchdogLabel(state))
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(headline)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let ago = snap.updatedAgo {
                Text(ago)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Watchdog \(HeroRings.watchdogLabel(state)). \(headline)")
    }
}

private struct WatchdogVitalTile: View {
    let row: WatchdogLiveSnapshot.MetricRow

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(row.name)
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(row.now)
                .font(StrandFont.rounded(22, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            WatchdogTraitStrip(values: row.series,
                               reconstructed: row.reconstructed,
                               usual: row.usualValue,
                               tint: StrandPalette.textPrimary,
                               minSpan: row.minSpan,
                               decimals: row.decimals,
                               rangeHalf: row.rangeHalf,
                               rangeSeries: row.rangeSeries,
                               rangeReady: row.rangeReady,
                               pulsePeriod: 0,
                               height: 34,
                               showsTicks: false)
            Text(row.status)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(row.tone)
                .lineLimit(1)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: NoopVisualStyle.compactRadius, style: .continuous)
                .fill(StrandPalette.surfaceInset.opacity(0.6))
        )
        .contentShape(RoundedRectangle(cornerRadius: NoopVisualStyle.compactRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name), \(row.now), \(row.status)")
    }
}

private struct WatchdogVitalSheet: View {
    let row: WatchdogLiveSnapshot.MetricRow
    let isLive: Bool
    let bandCaption: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(row.now)
                                .font(StrandFont.rounded(40, weight: .bold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .monospacedDigit()
                            Spacer(minLength: 8)
                            Text(row.status)
                                .font(StrandFont.headline)
                                .foregroundStyle(row.tone)
                        }
                        Text(row.windowCaption)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    WatchdogTraitStrip(values: row.series,
                                       reconstructed: row.reconstructed,
                                       usual: row.usualValue,
                                       tint: StrandPalette.textPrimary,
                                       minSpan: row.minSpan,
                                       decimals: row.decimals,
                                       rangeHalf: row.rangeHalf,
                                       rangeSeries: row.rangeSeries,
                                       rangeReady: row.rangeReady,
                                       pulsePeriod: isLive ? row.pulsePeriod : 0,
                                       height: 180)
                        .padding(12)
                        .background(
                            RoundedRectangle(cornerRadius: NoopVisualStyle.compactRadius, style: .continuous)
                                .fill(StrandPalette.surfaceInset.opacity(0.6))
                        )
                    legend
                    VStack(spacing: 0) {
                        fact("Expected now", row.expected)
                        Divider().overlay(NoopVisualStyle.divider)
                        fact("Usual range", row.rangeLabel.map { $0.replacingOccurrences(of: "Range ", with: "") }
                             ?? "Learning")
                        Divider().overlay(NoopVisualStyle.divider)
                        fact("Trust", row.trustPct > 0 ? "\(row.trustPct)%" : "Learning")
                    }
                    Text(explanation)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(bandCaption)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(20)
            }
            .navigationTitle(row.name)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: false)
        #endif
    }

    private var explanation: String {
        switch row.status {
        case "In range":
            return "Inside the range Watchdog expects for you at this point in your day."
        case "Off":
            return "Outside the range Watchdog expects for you right now. An event opens when the whole half-hour stays unlike your usual, not from one reading."
        case "Live", "Learning":
            return "Watchdog is still learning how much this vital moves for you, so it shows the reading without calling it in range or off."
        default:
            return "No reading for this vital in the last half-hour."
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            legendItem("Your reading") {
                Capsule().fill(StrandPalette.textPrimary).frame(width: 16, height: 3)
            }
            legendItem("Expected") {
                Path { p in
                    p.move(to: CGPoint(x: 0, y: 1.5))
                    p.addLine(to: CGPoint(x: 16, y: 1.5))
                }
                .stroke(StrandPalette.statusPositive, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .frame(width: 16, height: 3)
            }
            legendItem("Usual range") {
                RoundedRectangle(cornerRadius: 2).fill(StrandPalette.statusPositive.opacity(0.3))
                    .frame(width: 16, height: 10)
            }
        }
        .accessibilityHidden(true)
    }

    private func legendItem(_ title: String, @ViewBuilder swatch: () -> some View) -> some View {
        HStack(spacing: 6) {
            swatch()
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
        }
        .padding(.vertical, 12)
    }
}

private struct WatchdogTraitStrip: View {
    let values: [Double]
    let reconstructed: [Double]
    let usual: Double?
    let tint: Color
    let minSpan: Double
    let decimals: Int
    let rangeHalf: Double
    let rangeSeries: [Double]
    let rangeReady: Bool
    let pulsePeriod: Double
    var height: CGFloat = 72
    var showsTicks: Bool = true

    private func half(at index: Int) -> Double {
        if index >= 0, index < rangeSeries.count, rangeSeries[index].isFinite, rangeSeries[index] > 0 {
            return rangeSeries[index]
        }
        return rangeHalf
    }

    private func hat(at index: Int) -> Double? {
        if index >= 0, index < reconstructed.count, reconstructed[index].isFinite {
            return reconstructed[index]
        }
        return usual
    }

    private func rangeOutside(at index: Int) -> Bool {
        guard index >= 0, index < values.count, values[index].isFinite,
              let center = hat(at: index) else { return false }
        return abs(values[index] - center) > max(half(at: index), 0.001)
    }

    /// Live-line ink only. The green band stays the model corridor.
    private func readingInk(at index: Int) -> Color {
        guard rangeOutside(at: index), let center = hat(at: index),
              index >= 0, index < values.count, values[index].isFinite else {
            return tint
        }
        let width = max(half(at: index), 0.001)
        let ratio = abs(values[index] - center) / width
        return baselineOffColor(min(1, (ratio - 1) / max(WatchdogConfig.tauSevere, 0.5)))
    }

    private var corridor: Color { StrandPalette.statusPositive }

    private var observed: [(id: Double, y: Double)] {
        values.enumerated().compactMap { i, v in
            guard v.isFinite else { return nil }
            return (Double(i), v)
        }
    }

    private var expected: [(id: Double, y: Double)] {
        let pts = reconstructed.enumerated().compactMap { i, v -> (Double, Double)? in
            guard v.isFinite else { return nil }
            return (Double(i), v)
        }
        if !pts.isEmpty { return pts }
        guard let usual else { return [] }
        return observed.map { ($0.id, usual) }
    }

    /// Minute knots plus smoothstep samples so lo/hi follow each minute's model width.
    private var ribbon: [(id: Double, y: Double, lo: Double, hi: Double)] {
        let src = expected
        guard !src.isEmpty else { return [] }
        var out: [(id: Double, y: Double, lo: Double, hi: Double)] = []
        func knot(_ p: (id: Double, y: Double)) -> (id: Double, y: Double, lo: Double, hi: Double) {
            let w = max(half(at: Int(p.id.rounded())), 0)
            return (p.id, p.y, p.y - w, p.y + w)
        }
        out.append(knot(src[0]))
        guard src.count > 1 else { return out }
        let steps = 6
        for i in 1..<src.count {
            let a = src[i - 1]
            let b = src[i]
            let aw = max(half(at: Int(a.id.rounded())), 0)
            let bw = max(half(at: Int(b.id.rounded())), 0)
            for s in 1...steps {
                let t = Double(s) / Double(steps)
                let u = t * t * (3 - 2 * t)
                let id = a.id + (b.id - a.id) * u
                let y = a.y + (b.y - a.y) * u
                let w = aw + (bw - aw) * u
                out.append((id, y, y - w, y + w))
            }
        }
        return out
    }

    private var readingRuns: [(id: Int, ink: Color, points: [(id: Double, y: Double)])] {
        var runs: [(id: Int, ink: Color, outside: Bool, points: [(id: Double, y: Double)])] = []
        for (i, point) in observed.enumerated() {
            let idx = Int(point.id.rounded())
            let outside = rangeOutside(at: idx)
            let ink = readingInk(at: idx)
            if var last = runs.last, last.outside == outside {
                last.points.append(point)
                last.ink = ink
                runs[runs.count - 1] = last
            } else {
                var pts: [(id: Double, y: Double)] = []
                if i > 0 { pts.append(observed[i - 1]) }
                pts.append(point)
                runs.append((runs.count, ink, outside, pts))
            }
        }
        return runs.map { ($0.id, $0.ink, $0.points) }
    }

    private var xDomain: ClosedRange<Double> {
        let xs = observed.map(\.id) + expected.map(\.id)
        guard let lo = xs.min(), let hi = xs.max() else { return 0...1 }
        if hi <= lo { return (lo - 0.6)...(lo + 0.6) }
        let pad = max(0.2, (hi - lo) * 0.04)
        return (lo - pad)...(hi + pad)
    }

    /// In-range corridor at the live end: reconstructed usual ± UniTS predicted scale at that minute.
    private var liveRange: (lo: Double, hi: Double)? {
        guard let hat = expected.last else {
            guard rangeHalf > 0, let usual else { return nil }
            return (usual - rangeHalf, usual + rangeHalf)
        }
        let width = half(at: Int(hat.id.rounded()))
        guard width > 0 else { return nil }
        return (hat.y - width, hat.y + width)
    }

    private var yDomain: ClosedRange<Double> {
        var ys = observed.map(\.y) + expected.map(\.y)
        if let usual { ys.append(usual) }
        for point in ribbon {
            ys.append(point.lo)
            ys.append(point.hi)
        }
        if let liveRange {
            ys.append(liveRange.lo)
            ys.append(liveRange.hi)
        }
        guard let lo = ys.min(), let hi = ys.max() else { return 0...1 }
        let span = max(hi - lo, minSpan)
        let mid = (hi + lo) / 2
        let pad = span * 0.16
        return (mid - span / 2 - pad)...(mid + span / 2 + pad)
    }

    @ViewBuilder
    private var plot: some View {
        if observed.count >= 1 || expected.count >= 1 {
            if pulsePeriod > 0, pulsePeriod <= 2 {
                TimelineView(.periodic(from: .now, by: 0.25)) { timeline in
                    let t = timeline.date.timeIntervalSince1970.truncatingRemainder(dividingBy: pulsePeriod)
                    chart(flash: t < 0.18)
                }
            } else {
                chart(flash: false)
            }
        } else {
            GeometryReader { geo in
                Path { path in
                    path.move(to: CGPoint(x: 0, y: geo.size.height * 0.65))
                    path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * 0.65))
                }
                .stroke(corridor.opacity(0.7),
                        style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }
        }
    }

    private func chart(flash: Bool) -> some View {
        Chart {
            if !ribbon.isEmpty {
                ForEach(Array(ribbon.enumerated()), id: \.offset) { _, point in
                    AreaMark(
                        x: .value("t", point.id),
                        yStart: .value("v", point.lo),
                        yEnd: .value("v", point.hi)
                    )
                    .foregroundStyle(corridor.opacity(0.28))
                    .interpolationMethod(.catmullRom)
                    LineMark(x: .value("t", point.id), y: .value("lo", point.lo),
                             series: .value("s", "lo"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(corridor.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    LineMark(x: .value("t", point.id), y: .value("hi", point.hi),
                             series: .value("s", "hi"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(corridor.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    LineMark(x: .value("t", point.id), y: .value("mid", point.y),
                             series: .value("s", "usual"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(corridor.opacity(rangeReady ? 0.95 : 0.72))
                        .lineStyle(StrokeStyle(lineWidth: rangeReady ? 2.0 : 1.5, dash: [5, 4]))
                }
            } else {
                ForEach(expected, id: \.id) { point in
                    LineMark(x: .value("t", point.id), y: .value("v", point.y), series: .value("s", "usual"))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(corridor.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 4]))
                }
            }
            ForEach(readingRuns, id: \.id) { run in
                ForEach(Array(run.points.enumerated()), id: \.offset) { _, point in
                    LineMark(x: .value("t", point.id), y: .value("v", point.y),
                             series: .value("s", "now-\(run.id)"))
                        .interpolationMethod(.linear)
                        .foregroundStyle(run.ink)
                        .lineStyle(StrokeStyle(lineWidth: 2.3))
                }
            }
            ForEach(observed, id: \.id) { point in
                PointMark(x: .value("t", point.id), y: .value("v", point.y))
                    .foregroundStyle(readingInk(at: Int(point.id.rounded())))
                    .symbolSize(point.id == observed.last?.id ? (flash ? 34 : 22) : 8)
            }
        }
        .chartXScale(domain: xDomain)
        .chartYScale(domain: yDomain)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .chartPlotStyle { plot in
            plot.padding(0).clipped()
        }
    }

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            plot
                .frame(maxWidth: .infinity)
                .frame(height: height)
            if showsTicks, let liveRange {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(tickLabel(liveRange.hi))
                    Spacer(minLength: 0)
                    Text(tickLabel(liveRange.lo))
                }
                .font(StrandFont.caption)
                .foregroundStyle(corridor)
                .monospacedDigit()
                .frame(width: 32, height: max(height - 14, 20))
                .accessibilityHidden(true)
            }
        }
    }

    private func tickLabel(_ value: Double) -> String {
        decimals == 0 ? String(format: "%.0f", value) : String(format: "%.\(decimals)f", value)
    }
}

@MainActor
private struct WatchdogLiveSnapshot {
    struct MetricRow: Identifiable {
        let id: String
        let name: String
        let now: String
        let expected: String
        let status: String
        let tone: Color
        let series: [Double]
        let reconstructed: [Double]
        let usualValue: Double?
        let windowCaption: String
        let minSpan: Double
        let decimals: Int
        let rangeHalf: Double
        let rangeSeries: [Double]
        let rangeLabel: String?
        let rangeReady: Bool
        let trustPct: Int
        let pulsePeriod: Double
    }

    let isLive: Bool
    let liveLabel: String
    let updatedAgo: String?
    let certaintyCaption: String?
    let bandCaption: String
    let metrics: [MetricRow]

    init(store: BaselineStore, temperatureUnit: TemperatureUnit = .celsius) {
        let fahrenheit = temperatureUnit == .fahrenheit
        if let result = store.watchdogResult {
            isLive = result.monitoringCurrent && result.unavailable == nil
            liveLabel = isLive ? "Live baseline" : Self.waitingLabel(result)
            updatedAgo = Self.ago(result.lastTickUnix)
            certaintyCaption = Self.certaintyCaption(result)
            bandCaption = Self.bandCaption(result, contextNote: store.activityContextNote)
            let hr = result.signals.first(where: { $0.name == "HR" })
            let rhr = result.signals.first(where: { $0.name == "RHR" })
            let hrv = result.signals.first(where: { $0.name == "HRV" })
            let temp = result.signals.first(where: { $0.name == "Temp" })
            let resp = result.signals.first(where: { $0.name == "Resp" })
            let spo2 = result.signals.first(where: { $0.name == "SpO2" })
            let whoop5 = WhoopModel.persisted == .whoop5mg
            metrics = [
                Self.row(id: "hr", name: "Heart rate", signal: hr, series: result.horizonHR,
                         reconstructed: result.reconstructedHR, rangeSeries: result.rangeHR,
                         caption: "Last 30 min", minSpan: 8, whoop5: whoop5,
                         trustPct: hr?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("HR") || result.personalOff,
                         bandReady: result.carry.channelBandReady(0)),
                Self.row(id: "rhr", name: "Resting HR", signal: rhr, series: result.horizonRHR,
                         reconstructed: result.reconstructedRHR, rangeSeries: result.rangeRHR,
                         caption: "Still minutes only", minSpan: 8, whoop5: whoop5,
                         trustPct: rhr?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("RHR") || result.personalOff,
                         bandReady: result.carry.channelBandReady(1)),
                Self.row(id: "hrv", name: "HRV", signal: hrv, series: result.horizonHRV,
                         reconstructed: result.reconstructedHRV, rangeSeries: result.rangeHRV,
                         caption: "5 min RMSSD", minSpan: 18, whoop5: whoop5,
                         trustPct: hrv?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("HRV") || result.personalOff,
                         bandReady: result.carry.channelBandReady(2)),
                Self.row(id: "temp", name: "Temp", signal: temp, series: result.horizonTemp,
                         reconstructed: result.reconstructedTemp, rangeSeries: result.rangeTemp,
                         caption: "Wrist skin · personal usual", minSpan: 0.4, whoop5: whoop5,
                         fahrenheit: fahrenheit, trustPct: temp?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("Temp"),
                         bandReady: result.carry.channelBandReady(3)),
                Self.row(id: "resp", name: "Breathing", signal: resp, series: result.horizonResp,
                         reconstructed: result.reconstructedResp, rangeSeries: result.rangeResp,
                         caption: "Last 30 min", minSpan: 4, whoop5: whoop5,
                         trustPct: resp?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("Resp"),
                         bandReady: result.carry.channelBandReady(4)),
                Self.row(id: "spo2", name: "SpO₂", signal: spo2, series: result.horizonSpO2,
                         reconstructed: result.reconstructedSpO2, rangeSeries: result.rangeSpO2,
                         caption: "When present", minSpan: 2, whoop5: whoop5,
                         trustPct: spo2?.trustPct ?? 0, liveOff: result.liveOff,
                         channelHot: result.contributing.contains("SpO2"),
                         bandReady: result.carry.channelBandReady(5))
            ]
            return
        }

        isLive = false
        liveLabel = "Waiting"
        updatedAgo = nil
        certaintyCaption = "Waiting on this half-hour."
        bandCaption = Self.bandCaption(nil, contextNote: store.activityContextNote)
        let whoop5 = WhoopModel.persisted == .whoop5mg
        metrics = [
            Self.emptyRow(id: "hr", name: "Heart rate", caption: "Last 30 min", minSpan: 8, whoop5: whoop5),
            Self.emptyRow(id: "rhr", name: "Resting HR", caption: "Still minutes only", minSpan: 8, whoop5: whoop5),
            Self.emptyRow(id: "hrv", name: "HRV", caption: "5 min RMSSD", minSpan: 18, whoop5: whoop5),
            Self.emptyRow(id: "temp", name: "Temp", caption: "Wrist skin · personal usual", minSpan: 0.4, whoop5: whoop5,
                          fahrenheit: fahrenheit),
            Self.emptyRow(id: "resp", name: "Breathing", caption: "Last 30 min", minSpan: 4, whoop5: whoop5),
            Self.emptyRow(id: "spo2", name: "SpO₂", caption: "When present", minSpan: 2, whoop5: whoop5)
        ]
    }

    static func row(id: String, name: String, signal: WatchdogSignalEvidence?,
                    series: [Double], reconstructed: [Double], rangeSeries: [Double],
                    caption: String, minSpan: Double, whoop5: Bool, fahrenheit: Bool = false,
                    trustPct: Int, liveOff: Bool = false, channelHot: Bool = false,
                    bandReady: Bool = false) -> MetricRow {
        var now = signal?.observed
        var usual = signal?.reconstructed ?? signal?.usual
        var series = series
        var reconstructed = reconstructed
        var rangeSeries = rangeSeries
        var minSpan = minSpan
        var range = (signal?.rangeHalf ?? 0) > 0 ? (signal?.rangeHalf ?? rangeHalf(for: id)) : rangeHalf(for: id)
        var unit = signal?.unit ?? ""
        if id == "temp", fahrenheit {
            now = now.map(UnitFormatter.celsiusToFahrenheit)
            usual = usual.map(UnitFormatter.celsiusToFahrenheit)
            series = series.map(UnitFormatter.celsiusToFahrenheit)
            reconstructed = reconstructed.map(UnitFormatter.celsiusToFahrenheit)
            minSpan *= 9.0 / 5.0
            range *= 9.0 / 5.0
            rangeSeries = rangeSeries.map { $0 * 9.0 / 5.0 }
            unit = "°F"
        }
        let hasLive = series.contains(where: \.isFinite)
        let callReady = bandReady && trustPct >= LongitudinalBaseline.trustHideThreshold
        let bandGain = Self.learningBandGain(trustPct)
        reconstructed = Self.maskToRecorded(reconstructed, recorded: series)
        rangeSeries = Self.maskToRecorded(rangeSeries, recorded: series).map { $0.isFinite ? $0 * bandGain : $0 }
        if id == "rhr" || id == "spo2" {
            let packed = Self.packRecorded(series: series, reconstructed: reconstructed, rangeSeries: rangeSeries)
            series = packed.series
            reconstructed = packed.reconstructed
            rangeSeries = packed.rangeSeries
        }
        range *= bandGain
        guard hasLive else {
            return MetricRow(id: id, name: name, now: "–", expected: "–", status: "No reading",
                             tone: StrandPalette.textTertiary, series: series, reconstructed: [],
                             usualValue: nil, windowCaption: caption, minSpan: minSpan,
                             decimals: decimals(for: id), rangeHalf: range, rangeSeries: [],
                             rangeLabel: nil, rangeReady: callReady, trustPct: trustPct,
                             pulsePeriod: whoopReadSeconds(id: id, whoop5: whoop5))
        }
        let aligned = lastAligned(series: series, reconstructed: reconstructed, usual: usual)
        let lastObs = aligned?.obs
        let lastHat = aligned?.hat
        let lastWidth: Double = {
            if let i = aligned?.index, i >= 0, i < rangeSeries.count, rangeSeries[i] > 0 {
                return rangeSeries[i]
            }
            return range
        }()
        let outsideBand: Bool = {
            guard let lastObs, let lastHat, lastWidth > 0 else { return false }
            return abs(lastObs - lastHat) > lastWidth
        }()
        let status: String
        let tone: Color
        if lastObs == nil {
            status = "No reading"
            tone = StrandPalette.textTertiary
        } else if !callReady {
            status = hasLive ? "Live" : "Learning"
            tone = StrandPalette.textSecondary
        } else if outsideBand {
            let mag: Double
            if lastWidth > 0, let lastObs, let lastHat {
                mag = min(1, abs(lastObs - lastHat) / max(lastWidth, 0.001) / WatchdogConfig.tauSevere)
            } else {
                mag = 0.5
            }
            status = "Off"
            tone = baselineOffColor(mag)
        } else {
            status = "In range"
            tone = StrandPalette.statusPositive
        }
        let rangeCenter = lastHat ?? usual
        let rangeLabel: String? = {
            guard let rangeCenter, lastWidth > 0 else { return nil }
            let dec = decimals(for: id)
            let lo = format(rangeCenter - lastWidth, decimals: dec, unit: "")
            let hi = format(rangeCenter + lastWidth, decimals: dec, unit: unit)
            return "Range \(lo)–\(hi)"
        }()
        return MetricRow(id: id, name: name,
                         now: format(lastObs ?? now, decimals: decimals(for: id), unit: unit),
                         expected: format(lastHat ?? usual, decimals: decimals(for: id), unit: unit),
                         status: status, tone: tone, series: series, reconstructed: reconstructed,
                         usualValue: lastHat ?? usual, windowCaption: caption, minSpan: minSpan,
                         decimals: decimals(for: id),
                         rangeHalf: lastWidth,
                         rangeSeries: rangeSeries,
                         rangeLabel: rangeLabel, rangeReady: callReady, trustPct: trustPct,
                         pulsePeriod: whoopReadSeconds(id: id, whoop5: whoop5))
    }

    static func learningBandGain(_ trust: Int) -> Double {
        if trust >= LongitudinalBaseline.trustHideThreshold { return 1 }
        let t = max(0, min(LongitudinalBaseline.trustHideThreshold, trust))
        return 1 + Double(LongitudinalBaseline.trustHideThreshold - t) / 35.0 * 2.5
    }

    static func maskToRecorded(_ values: [Double], recorded: [Double]) -> [Double] {
        values.enumerated().map { i, value in
            guard i < recorded.count, recorded[i].isFinite, value.isFinite else { return .nan }
            return value
        }
    }

    /// Drop empty minutes so still / sparse channels fill the plot instead of a sliver at t=29.
    static func packRecorded(series: [Double], reconstructed: [Double],
                             rangeSeries: [Double]) -> (series: [Double], reconstructed: [Double], rangeSeries: [Double]) {
        var outS: [Double] = []
        var outR: [Double] = []
        var outG: [Double] = []
        for i in series.indices {
            guard series[i].isFinite else { continue }
            outS.append(series[i])
            outR.append(i < reconstructed.count ? reconstructed[i] : .nan)
            outG.append(i < rangeSeries.count ? rangeSeries[i] : .nan)
        }
        return (outS, outR, outG)
    }

    static func lastAligned(series: [Double], reconstructed: [Double], usual: Double?) -> (obs: Double, hat: Double, index: Int)? {
        let n = max(series.count, reconstructed.count)
        guard n > 0 else {
            if let usual, let obs = series.last(where: { $0.isFinite }) { return (obs, usual, series.count - 1) }
            return nil
        }
        var i = n - 1
        while i >= 0 {
            let obs = i < series.count && series[i].isFinite ? series[i] : nil
            let hat = i < reconstructed.count && reconstructed[i].isFinite ? reconstructed[i] : nil
            if let obs, let hat { return (obs, hat, i) }
            if let obs, let usual { return (obs, usual, i) }
            i -= 1
        }
        return nil
    }

    static func emptyRow(id: String, name: String, caption: String, minSpan: Double, whoop5: Bool,
                         fahrenheit: Bool = false) -> MetricRow {
        let span = (id == "temp" && fahrenheit) ? minSpan * 9.0 / 5.0 : minSpan
        let half = rangeHalf(for: id) * ((id == "temp" && fahrenheit) ? 9.0 / 5.0 : 1)
        return MetricRow(id: id, name: name, now: "–", expected: "–", status: "No reading",
                  tone: StrandPalette.textTertiary, series: [], reconstructed: [],
                  usualValue: nil, windowCaption: caption, minSpan: span,
                  decimals: decimals(for: id), rangeHalf: half, rangeSeries: [],
                  rangeLabel: nil, rangeReady: false, trustPct: 0,
                  pulsePeriod: whoopReadSeconds(id: id, whoop5: whoop5))
    }

    static func rangeHalf(for id: String) -> Double {
        let scale: Double
        switch id {
        case "hr", "rhr": scale = WatchdogConfig.hrScale
        case "hrv": scale = WatchdogConfig.hrvScale
        case "temp": scale = WatchdogConfig.tempScale
        case "resp": scale = WatchdogConfig.respScale
        case "spo2": scale = WatchdogConfig.spo2Scale
        default: scale = 1
        }
        return scale * WatchdogConfig.tau
    }

    /// Live HR/RR cadence from the strap. WHOOP 4 ~1 Hz (2A37); 5/MG ~30 s. Other vitals are held or sparse.
    static func whoopReadSeconds(id: String, whoop5: Bool) -> Double {
        switch id {
        case "hr", "rhr", "hrv":
            return whoop5 ? 30 : 1
        default:
            return 0
        }
    }

    static func decimals(for id: String) -> Int { id == "temp" ? 1 : 0 }

    static func bandCaption(_ result: WatchdogResult?, contextNote: String? = nil) -> String {
        let base: String
        if let result, result.unavailable == nil {
            let n = result.carry.presentMinutes(channel: 0)
            let need = max(0, WatchdogBand.firstMinutes - n)
            if need == 0 {
                base = "Heart-rate green band is on. Sparse vitals (temp, breathing, SpO₂) each need their own 14 good minutes."
            } else {
                base = "Model range is on (gray). Green personal width after 14 good still minutes of that vital, about \(need) more for heart rate if the strap is labeling still."
            }
        } else {
            base = "Live line and gray model range can fill as soon as this half-hour has readings. Green personal width waits for 14 good still minutes of that vital."
        }
        return contextNote.map { base + " " + $0 } ?? base
    }

    static func certaintyCaption(_ result: WatchdogResult) -> String? {
        switch result.carry.notifyDelivery {
        case "denied":
            return "Alert not delivered. Notifications are off. Turn them on to retry."
        case "failed":
            return "Alert not delivered. Will retry."
        default:
            break
        }
        if result.unavailable == .wristOff {
            return "Strap off. Not recovered."
        }
        if result.unavailable != nil {
            return "Not enough minutes."
        }
        return nil
    }

    static func trustColor(_ pct: Int) -> Color {
        if pct >= 70 { return StrandPalette.statusPositive }
        if pct >= 40 { return StrandPalette.textSecondary }
        return StrandPalette.statusWarning
    }

    static func waitingLabel(_ result: WatchdogResult) -> String {
        result.unavailable == .wristOff ? "Off wrist" : "Waiting"
    }

    static func format(_ value: Double?, decimals: Int, unit: String) -> String {
        guard let value else { return "–" }
        let number = decimals == 0 ? String(format: "%.0f", value) : String(format: "%.\(decimals)f", value)
        return unit.isEmpty ? number : "\(number) \(unit)"
    }

    static func ago(_ unix: Int) -> String {
        let seconds = Int(Date().timeIntervalSince1970) - unix
        if seconds < 45 { return "Just now" }
        if seconds < 120 { return "1 min ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        return "\(seconds / 3600) h ago"
    }
}

// MARK: - Triggered events

/// Episodes from the on-phone ledger, newest first. Each row opens what Watchdog saw at the peak.
@MainActor
struct WatchdogEventsCard: View {
    @EnvironmentObject private var store: BaselineStore
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""
    @State private var picked: WatchdogPick?
    @State private var showAll = false

    private static let collapsedCount = 5

    private var fahrenheit: Bool {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                     override: temperatureRaw) == .fahrenheit
    }

    private var events: [WatchdogEpisodeLedgerRow] {
        store.episodeLedger.sorted { $0.openedUnix > $1.openedUnix }
    }

    var body: some View {
        let all = events
        let shown = showAll ? all : Array(all.prefix(Self.collapsedCount))
        NoopCard(padding: 0) {
            if all.isEmpty {
                emptyState
            } else {
                VStack(spacing: 0) {
                    ForEach(shown, id: \.episodeId) { row in
                        if row.episodeId != shown.first?.episodeId {
                            Divider().overlay(NoopVisualStyle.divider).padding(.leading, 52)
                        }
                        Button { picked = WatchdogPick(id: row.episodeId) } label: {
                            WatchdogEventRow(row: row, fahrenheit: fahrenheit)
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("Shows why this event opened")
                    }
                    if all.count > Self.collapsedCount {
                        Divider().overlay(NoopVisualStyle.divider)
                        Button {
                            withAnimation(StrandMotion.gentle) { showAll.toggle() }
                        } label: {
                            Text(showAll ? "Show fewer" : "Show all \(all.count) events")
                                .font(StrandFont.subhead.weight(.semibold))
                                .foregroundStyle(StrandPalette.accent)
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .sheet(item: $picked) { pick in
            if let row = events.first(where: { $0.episodeId == pick.id }) {
                WatchdogEventSheet(row: row, fahrenheit: fahrenheit)
                    .environmentObject(store)
            }
        }
    }

    private var emptyState: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "checkmark.shield")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.statusPositive)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(store.watchdogResult == nil
                     ? "Watchdog has not checked a half-hour on this phone yet."
                     : "No triggered events in the last 21 days.")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("When a half-hour starts to look unlike your usual, Watchdog opens an event here with the readings that caused it.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct WatchdogEventRow: View {
    let row: WatchdogEpisodeLedgerRow
    let fahrenheit: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Circle()
                .fill(WatchdogEventCopy.tone(row.maxSeverity))
                .frame(width: 10, height: 10)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(WatchdogEventCopy.severityTitle(row.maxSeverity))
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 6)
                    Text(WatchdogEventCopy.shortWhen(row.openedUnix))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
                Text(WatchdogEventCopy.reasonLine(row, fahrenheit: fahrenheit))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(WatchdogEventCopy.durationLine(row))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(minHeight: 56)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// What Watchdog saw at the strongest tick of one event, plus timing, context and the wearer's note.
private struct WatchdogEventSheet: View {
    let row: WatchdogEpisodeLedgerRow
    let fahrenheit: Bool
    @EnvironmentObject private var store: BaselineStore
    @EnvironmentObject private var repo: Repository
    @Environment(\.dismiss) private var dismiss
    @State private var notePresented = false

    private var annotation: WatchdogEpisodeAnnotation? {
        store.episodeAnnotations.first { $0.episodeId == row.episodeId }
    }

    private var signals: [WatchdogSignalEvidence] {
        let hot = Set(row.contributing ?? [])
        return (row.signals ?? [])
            .filter { $0.observed != nil }
            .sorted { a, b in
                let ah = hot.contains(a.name), bh = hot.contains(b.name)
                if ah != bh { return ah }
                return a.energy > b.energy
            }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    summary
                    whySection
                    contextSection
                    timelineSection
                    noteSection
                    Text("Not a diagnosis. Separate from Charge.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(20)
            }
            .navigationTitle(WatchdogEventCopy.severityTitle(row.maxSeverity))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .sheet(isPresented: $notePresented) {
            WatchdogEpisodeNoteSheet(deviceId: repo.deviceId) { notePresented = false }
                .environmentObject(store)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(WatchdogEventCopy.tone(row.maxSeverity))
                    .frame(width: 10, height: 10)
                    .accessibilityHidden(true)
                Text(WatchdogEventCopy.longWhen(row.openedUnix))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            Text(WatchdogEventCopy.durationLine(row))
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
            if let headline = row.headline {
                Text(headline)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
        }
    }

    private var whySection: some View {
        let hot = Set(row.contributing ?? [])
        return VStack(alignment: .leading, spacing: 10) {
            sectionTitle("Why it opened")
            if signals.isEmpty {
                Text("This event was recorded before Watchdog saved the readings behind each event. Newer events show them here.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 8) {
                    ForEach(signals, id: \.name) { signal in
                        signalRow(signal, hot: hot.contains(signal.name))
                    }
                }
                if let peak = row.peakUnix {
                    Text("Readings from \(WatchdogEventCopy.clock(peak)), when this event was strongest. Highlighted vitals are the ones that drove it.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func signalRow(_ signal: WatchdogSignalEvidence, hot: Bool) -> some View {
        let tone = hot ? WatchdogEventCopy.tone(row.maxSeverity) : StrandPalette.textTertiary
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(WatchdogEventCopy.vitalName(signal.name))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(hot ? "Drove this event" : "Near usual")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(tone)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(WatchdogEventCopy.value(signal.observed, signal: signal, fahrenheit: fahrenheit))
                    .font(StrandFont.rounded(20, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                Text(WatchdogEventCopy.expectedLine(signal, fahrenheit: fahrenheit))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .monospacedDigit()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: NoopVisualStyle.compactRadius, style: .continuous)
                .fill(hot ? tone.opacity(0.10) : StrandPalette.surfaceInset.opacity(0.6))
        )
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var contextSection: some View {
        let activity = WatchdogEventCopy.activity(row.activityLabel)
        let label = WatchdogEventCopy.eventLabel(row.eventLabel)
        let delivery = WatchdogEventCopy.delivery(row.notifyDelivery)
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Context")
                .padding(.bottom, 4)
            fact("Movement", activity ?? "Not known")
            Divider().overlay(NoopVisualStyle.divider)
            fact("Pattern", label ?? "Not labelled")
            Divider().overlay(NoopVisualStyle.divider)
            fact("Notification", delivery)
        }
    }

    private var timelineSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            sectionTitle("Timeline")
                .padding(.bottom, 4)
            fact("Opened", WatchdogEventCopy.clock(row.openedUnix))
            if let peak = row.peakUnix {
                Divider().overlay(NoopVisualStyle.divider)
                fact("Strongest", WatchdogEventCopy.clock(peak))
            }
            Divider().overlay(NoopVisualStyle.divider)
            fact("Closed", row.closedUnix.map(WatchdogEventCopy.clock) ?? "Still open")
            Divider().overlay(NoopVisualStyle.divider)
            fact("Minutes off usual", "\(row.offMinutes.count)")
            if row.unavailableMinutes > 0 {
                Divider().overlay(NoopVisualStyle.divider)
                fact("Checks without data", "\(row.unavailableMinutes)")
            }
        }
    }

    @ViewBuilder private var noteSection: some View {
        if let annotation {
            VStack(alignment: .leading, spacing: 8) {
                sectionTitle("Your note")
                switch annotation.status {
                case .entered:
                    let lines = WatchdogEventCopy.noteLines(annotation)
                    if lines.isEmpty {
                        Text("Saved with no details.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    } else {
                        ForEach(lines, id: \.self) { line in
                            Text(line)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                case .pending:
                    Button { notePresented = true } label: {
                        Label("Add a note about this alert", systemImage: "square.and.pencil")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(minHeight: 44)
                    }
                    .buttonStyle(.plain)
                case .skipped:
                    Text("You skipped the note for this alert.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                case .expired:
                    Text("The note window for this alert has closed.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
    }

    private func fact(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
        }
        .padding(.vertical, 12)
    }
}

/// Plain-language copy for ledger rows. Kept apart so rows and the detail sheet say the same thing.
enum WatchdogEventCopy {
    static func severityTitle(_ raw: String) -> String {
        switch raw {
        case "severe": return "Strong alert"
        case "active": return "Alert"
        default: return "Watching"
        }
    }

    static func tone(_ raw: String) -> Color {
        switch raw {
        case "severe", "active": return StrandPalette.statusCritical
        default: return StrandPalette.statusWarning
        }
    }

    static func vitalName(_ name: String) -> String {
        switch name {
        case "HR": return "Heart rate"
        case "RHR": return "Resting HR"
        case "HRV": return "HRV"
        case "Temp": return "Temp"
        case "Resp": return "Breathing"
        case "SpO2": return "SpO₂"
        default: return name
        }
    }

    private static func isTemp(_ signal: WatchdogSignalEvidence) -> Bool { signal.name == "Temp" }

    static func value(_ v: Double?, signal: WatchdogSignalEvidence, fahrenheit: Bool) -> String {
        guard let v, v.isFinite else { return "–" }
        if isTemp(signal) {
            let shown = fahrenheit ? UnitFormatter.celsiusToFahrenheit(v) : v
            return String(format: "%.1f %@", shown, fahrenheit ? "°F" : "°C")
        }
        let unit = signal.unit.isEmpty ? "" : " \(signal.unit)"
        return String(format: "%.0f", v) + unit
    }

    private static func delta(_ signal: WatchdogSignalEvidence, fahrenheit: Bool) -> String? {
        guard let obs = signal.observed, let exp = signal.reconstructed ?? signal.usual,
              obs.isFinite, exp.isFinite else { return nil }
        var d = obs - exp
        if isTemp(signal) {
            if fahrenheit { d *= 9.0 / 5.0 }
            return String(format: "%+.1f", d)
        }
        return String(format: "%+.0f", d)
    }

    static func expectedLine(_ signal: WatchdogSignalEvidence, fahrenheit: Bool) -> String {
        let expected = signal.reconstructed ?? signal.usual
        guard expected != nil else { return "No expected value" }
        let base = "Expected \(value(expected, signal: signal, fahrenheit: fahrenheit))"
        guard let d = delta(signal, fahrenheit: fahrenheit) else { return base }
        return "\(base) (\(d))"
    }

    /// One line for the list: the vital that drove the event most, and how far it was from expected.
    static func reasonLine(_ row: WatchdogEpisodeLedgerRow, fahrenheit: Bool) -> String {
        let hot = Set(row.contributing ?? [])
        let lead = (row.signals ?? [])
            .filter { hot.contains($0.name) && $0.observed != nil }
            .max { $0.energy < $1.energy }
        if let lead {
            let now = value(lead.observed, signal: lead, fahrenheit: fahrenheit)
            let expected = value(lead.reconstructed ?? lead.usual, signal: lead, fahrenheit: fahrenheit)
            var line = "\(vitalName(lead.name)) \(now), expected \(expected)"
            if hot.count > 1 { line += ", plus \(hot.count - 1) more" }
            return line
        }
        if row.safety { return "Past a safety limit." }
        if row.personalOff { return "Several readings away from your usual together." }
        return row.headline ?? "Recorded before reasons were saved."
    }

    static func durationLine(_ row: WatchdogEpisodeLedgerRow, now: Int = Int(Date().timeIntervalSince1970)) -> String {
        let end = row.closedUnix ?? row.lastUnix
        let minutes = max(1, (end - row.openedUnix) / 60)
        let length = minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
        if row.closedUnix == nil, now - row.lastUnix < 15 * 60 { return "\(length) so far" }
        return length
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(format)
        return f
    }

    static func clock(_ unix: Int) -> String {
        formatter("jmm").string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    static func shortWhen(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let cal = Calendar.current
        if cal.isDateInToday(date) { return clock(unix) }
        if cal.isDateInYesterday(date) { return "Yesterday \(clock(unix))" }
        return formatter("EEEdMMM").string(from: date)
    }

    static func longWhen(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today, \(clock(unix))" }
        if cal.isDateInYesterday(date) { return "Yesterday, \(clock(unix))" }
        return formatter("EEEEdMMMMjmm").string(from: date)
    }

    static func activity(_ raw: String?) -> String? {
        switch raw {
        case "still": return "Still"
        case "stand": return "Standing"
        case "walk": return "Walking"
        case "run": return "Running"
        case "cycleLike": return "Cycling"
        case "resistance": return "Lifting"
        case "artifact": return "Sensor noise"
        default: return nil
        }
    }

    static func eventLabel(_ raw: String?) -> String? {
        guard let raw, let label = WatchdogEventLabel(rawValue: raw) else { return nil }
        switch label {
        case .wristOff: return "Strap off"
        case .gap: return "Gap in readings"
        case .artifactSpike: return "Sensor spike"
        case .workoutWalk: return "Walking workout"
        case .workoutRun: return "Running workout"
        case .workoutCycle: return "Cycling workout"
        case .workoutLift: return "Lifting workout"
        case .postWorkout: return "Just after a workout"
        case .normalSleep: return "Asleep"
        case .normalStillAwake: return "Still and awake"
        case .forecastDriftOnly: return "Drifting from the forecast"
        case .abnormalStillTachycardia: return "High heart rate while still"
        case .abnormalMultiDirection: return "Several vitals moving together"
        case .abnormalSpo2Still: return "Low SpO₂ while still"
        case .safetyBound: return "Past a safety limit"
        case .mixedRejected: return "Mixed signals"
        }
    }

    static func delivery(_ raw: String) -> String {
        switch raw {
        case "sent": return "Sent"
        case "denied": return "Blocked, notifications are off"
        case "failed": return "Did not send"
        case "queued": return "Waiting to send"
        default: return "Not sent"
        }
    }

    static func noteLines(_ a: WatchdogEpisodeAnnotation) -> [String] {
        var out: [String] = []
        if let s = a.symptoms, !s.isEmpty { out.append("Symptoms: \(s)") }
        if let e = a.exertion { out.append("Exertion: \(e.rawValue)") }
        if let s = a.stress { out.append("Stress: \(s.rawValue)") }
        if let i = a.illness { out.append(i == .feltOff ? "Felt off" : "Not ill") }
        if let s = a.sensor {
            switch s {
            case .loose: out.append("Strap was loose")
            case .charging: out.append("Strap was charging")
            case .justOn: out.append("Strap had just gone on")
            case .other: out.append("Something else with the strap")
            }
        }
        if let n = a.note, !n.isEmpty { out.append(n) }
        return out
    }
}

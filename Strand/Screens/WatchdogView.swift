import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// Live half-hour on Baseline. Each vital is equal; dotted line is the reconstructed usual for this stretch.
@MainActor
struct WatchdogPlaceholderView: View {
    @EnvironmentObject private var store: BaselineStore
    @EnvironmentObject private var repo: Repository
    var embedded: Bool = false
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.temperatureKey) private var temperatureRaw = ""

    private var temperatureUnit: TemperatureUnit {
        UnitPrefs.resolveTemperature(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
                                     override: temperatureRaw)
    }

    var body: some View {
        if embedded {
            liveCard
        } else {
            ScreenScaffold(
                title: "Watchdog",
                subtitle: "Last 30 minutes. Separate from Charge.",
                topBackground: liquidScaffoldSky()
            ) {
                liveCard
            }
        }
    }

    private var liveCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Live baseline")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                liveBanner
                if let caption = snapshot.certaintyCaption {
                    Text(caption)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(snapshot.bandCaption)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                if let recovery = store.eventRecovery, recovery.status != .noReference {
                    Text(recovery.headline)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if store.pendingEpisodeNote != nil {
                    Button("Add a note about the last alert") {
                        store.showEpisodeNoteSheet = true
                    }
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
                }
                traitRows
            }
            .padding(.vertical, 4)
        }
        .onAppear { WatchdogNotifier.requestAuthorization() }
        .sheet(isPresented: $store.showEpisodeNoteSheet) {
            WatchdogEpisodeNoteSheet(deviceId: repo.deviceId) {
                store.showEpisodeNoteSheet = false
            }
            .environmentObject(store)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(snapshot.liveLabel). Live baseline")
    }

    private var liveBanner: some View {
        TimelineView(.periodic(from: .now, by: 0.9)) { timeline in
            let pulse = snapshot.isLive
                && Int(timeline.date.timeIntervalSince1970 / 0.9) % 2 == 0
            HStack(spacing: 8) {
                Circle()
                    .fill(snapshot.isLive ? StrandPalette.statusPositive : StrandPalette.textTertiary)
                    .frame(width: 8, height: 8)
                    .opacity(snapshot.isLive ? (pulse ? 1 : 0.28) : 0.5)
                    .accessibilityHidden(true)
                Text(snapshot.isLive ? "On" : snapshot.liveLabel)
                    .font(StrandFont.caption.weight(.semibold))
                    .tracking(0.6)
                    .foregroundStyle(snapshot.isLive ? StrandPalette.statusPositive : StrandPalette.textSecondary)
                Spacer(minLength: 0)
                Text(snapshot.isLive ? (snapshot.updatedAgo ?? "Updating") : "Waiting")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(snapshot.isLive
                          ? StrandPalette.statusPositive.opacity(0.12)
                          : StrandPalette.surfaceInset)
            )
        }
    }

    private var traitRows: some View {
        VStack(spacing: 10) {
            ForEach(snapshot.metrics) { row in
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(row.name)
                                .font(StrandFont.subhead.weight(.semibold))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                            Text(row.windowCaption)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        Text(row.now)
                            .font(StrandFont.rounded(20, weight: .bold))
                            .foregroundStyle(row.tone)
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
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
                                       pulsePeriod: snapshot.isLive ? row.pulsePeriod : 0)
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.status)
                            .font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(row.tone)
                        if row.trustPct > 0 {
                            Text("TRUST \(row.trustPct)%")
                                .font(StrandFont.caption)
                                .foregroundStyle(WatchdogLiveSnapshot.trustColor(row.trustPct))
                                .monospacedDigit()
                        }
                        Spacer(minLength: 6)
                        VStack(alignment: .trailing, spacing: 0) {
                            Text(row.expected)
                                .font(StrandFont.rounded(14, weight: .semibold))
                                .foregroundStyle(StrandPalette.textSecondary)
                                .monospacedDigit()
                            if let range = row.rangeLabel {
                                Text(range)
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.statusPositive)
                                    .monospacedDigit()
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.8)
                            }
                        }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(StrandPalette.surfaceInset.opacity(0.55))
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(row.name) \(row.windowCaption). \(row.now), predicted \(row.expected), range \(row.rangeLabel ?? "none"), \(row.status)")
            }
        }
    }

    private var snapshot: WatchdogLiveSnapshot {
        WatchdogLiveSnapshot(store: store, temperatureUnit: temperatureUnit)
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
                .frame(height: 72)
            if let liveRange {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(tickLabel(liveRange.hi))
                    Spacer(minLength: 0)
                    Text(tickLabel(liveRange.lo))
                }
                .font(StrandFont.caption)
                .foregroundStyle(corridor)
                .monospacedDigit()
                .frame(width: 32, height: 58)
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
            return MetricRow(id: id, name: name, now: "—", expected: "—", status: "—",
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
            status = "—"
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
        return MetricRow(id: id, name: name, now: "—", expected: "—", status: "—",
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
                base = "Model range is on (gray). Green personal width after 14 good still minutes of that vital — about \(need) more for heart rate if the strap is labeling still."
            }
        } else {
            base = "Live line and gray model range can fill as soon as this half-hour has readings. Green personal width waits for 14 good still minutes of that vital."
        }
        return contextNote.map { base + " " + $0 } ?? base
    }

    static func certaintyCaption(_ result: WatchdogResult) -> String? {
        switch result.carry.notifyDelivery {
        case "denied":
            return "Alert not delivered. Notifications are off — turn them on to retry."
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
        guard let value else { return "—" }
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

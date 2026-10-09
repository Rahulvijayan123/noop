import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// One signal of a stretch (heart rate, wrist movement or step-counter ticks) drawn the same way: a titled
/// chart with clock times along the bottom and the value (with its unit) up the side, gridlines behind, and a
/// shared guide so a touch on one reads all three. Heart rate is the slice's average as a line inside its
/// lowest-to-highest band; movement and steps are one column per slice.
struct StretchSignalChart: View {
    enum Kind {
        case heartRate, wristMovement, stepTicks

        var title: String {
            switch self {
            case .heartRate: return String(localized: "Heart rate")
            case .wristMovement: return String(localized: "Wrist movement")
            case .stepTicks: return String(localized: "Step counter")
            }
        }

        var unit: String {
            switch self {
            case .heartRate: return "bpm"
            case .wristMovement: return "g"
            case .stepTicks: return String(localized: "ticks per slice")
            }
        }

        var tint: Color {
            switch self {
            case .heartRate: return StrandPalette.metricRose
            case .wristMovement: return StrandPalette.metricCyan
            case .stepTicks: return StrandPalette.metricPurple
            }
        }
    }

    let detail: StretchDetail
    let kind: Kind
    @Binding var selection: Date?

    private struct Slice: Identifiable {
        let id: Int
        let from: Date
        let to: Date
        var mid: Date { from.addingTimeInterval(to.timeIntervalSince(from) / 2) }
        let value: Double
        let low: Double?
        let high: Double?
    }

    private static func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

    private var slices: [Slice] {
        detail.bins.compactMap { b in
            let value: Double?
            switch kind {
            case .heartRate: value = b.avgHr.map(Double.init)
            case .wristMovement: value = b.motionG
            case .stepTicks: value = b.stepTicks.map(Double.init)
            }
            guard let value else { return nil }
            return Slice(id: b.start, from: Self.date(b.start), to: Self.date(max(b.end, b.start + 1)), value: value,
                         low: kind == .heartRate ? b.minHr.map(Double.init) : nil,
                         high: kind == .heartRate ? b.maxHr.map(Double.init) : nil)
        }
    }

    private var window: ClosedRange<Date> { Self.date(detail.start)...Self.date(max(detail.end, detail.start + 1)) }

    private var showsSeconds: Bool { detail.durationSeconds < 300 }

    /// The value axis: heart rate fits its range with a little room, the others start at zero.
    private func yDomain(_ slices: [Slice]) -> ClosedRange<Double> {
        switch kind {
        case .heartRate:
            let lows = slices.map { $0.low ?? $0.value }, highs = slices.map { $0.high ?? $0.value }
            let lo = (lows.min() ?? 50), hi = (highs.max() ?? 100)
            let pad = max(4, (hi - lo) * 0.15)
            return max(0, (lo - pad).rounded(.down))...(hi + pad).rounded(.up)
        case .wristMovement:
            return 0...max(0.05, (slices.map(\.value).max() ?? 0) * 1.2)
        case .stepTicks:
            return 0...max(4, (slices.map(\.value).max() ?? 0) * 1.2)
        }
    }

    private func valueText(_ v: Double) -> String {
        switch kind {
        case .heartRate, .stepTicks: return String(Int(v.rounded()))
        case .wristMovement: return String(format: "%.2f", v)
        }
    }

    private var picked: Slice? {
        guard let selection else { return nil }
        return slices.first { $0.from <= selection && selection < $0.to }
    }

    var body: some View {
        let slices = self.slices
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(kind.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                Text(kind.unit)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if slices.isEmpty {
                Text(String(localized: "The strap recorded no \(kind.title.lowercased()) in this stretch."))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
            } else {
                chart(slices)
                Text(readout(slices))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func chart(_ slices: [Slice]) -> some View {
        let domain = yDomain(slices)
        let picked = self.picked
        return Chart {
            ForEach(slices) { s in
                switch kind {
                case .heartRate:
                    if let low = s.low, let high = s.high {
                        AreaMark(x: .value("Time", s.mid), yStart: .value("Low", low), yEnd: .value("High", high),
                                 series: .value("Series", "range"))
                            .foregroundStyle(kind.tint.opacity(0.18))
                            .interpolationMethod(.monotone)
                    }
                    LineMark(x: .value("Time", s.mid), y: .value("Heart rate", s.value), series: .value("Series", "avg"))
                        .foregroundStyle(kind.tint)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.monotone)
                case .wristMovement, .stepTicks:
                    RectangleMark(xStart: .value("From", s.from), xEnd: .value("To", s.to),
                                  yStart: .value("Zero", 0), yEnd: .value("Value", s.value))
                        .foregroundStyle(kind.tint.opacity(picked == nil || picked?.id == s.id ? 0.95 : 0.35))
                }
            }
            if let picked {
                RuleMark(x: .value("Selected", picked.mid))
                    .foregroundStyle(StrandPalette.textTertiary.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                if kind == .heartRate {
                    PointMark(x: .value("Selected", picked.mid), y: .value("Heart rate", picked.value))
                        .foregroundStyle(kind.tint)
                        .symbolSize(70)
                }
            }
        }
        .chartXScale(domain: window)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.textTertiary.opacity(0.18))
                AxisTick().foregroundStyle(StrandPalette.textTertiary.opacity(0.5))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(StretchFormat.clock(date, seconds: showsSeconds))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(StrandPalette.textTertiary.opacity(0.18))
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(valueText(v))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot = proxy.plotRectCompat(in: geo)
                touchSurface(proxy: proxy, plot: plot)
                    .frame(width: plot.width, height: plot.height)
                    .offset(x: plot.minX, y: plot.minY)
            }
        }
        .frame(height: kind == .heartRate ? 170 : 130)
        .accessibilityLabel(Text(kind.title))
    }

    @ViewBuilder
    private func touchSurface(proxy: ChartProxy, plot: CGRect) -> some View {
        #if os(iOS)
        HorizontalScrubSurface(onScrub: { select($0, proxy: proxy, plot: plot) }, onEnd: {},
                               onTap: { select($0, proxy: proxy, plot: plot) })
        #else
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { select($0.location.x, proxy: proxy, plot: plot) })
        #endif
    }

    private func select(_ x: CGFloat, proxy: ChartProxy, plot: CGRect) {
        guard plot.width > 0, let date: Date = proxy.value(atX: min(max(x, 0), plot.width)) else { return }
        selection = date
    }

    /// The slice under the guide (its time and value), or the stretch's own range when nothing is touched.
    private func readout(_ slices: [Slice]) -> String {
        if let p = picked {
            let time = StretchFormat.clock(p.from, seconds: true)
            switch kind {
            case .heartRate:
                let range = p.low.flatMap { lo in p.high.map { hi in " (\(Int(lo))–\(Int(hi)))" } } ?? ""
                return "\(time) · \(valueText(p.value)) bpm\(range)"
            case .wristMovement: return "\(time) · \(valueText(p.value)) g"
            case .stepTicks: return String(localized: "\(time) · \(valueText(p.value)) ticks")
            }
        }
        let sliceLength = StretchFormat.duration(detail.binSeconds)
        return String(localized: "Each \(kind == .heartRate ? "point" : "column") is \(sliceLength). Touch the chart to read one.")
    }
}

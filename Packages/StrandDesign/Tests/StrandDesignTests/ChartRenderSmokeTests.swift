#if os(macOS)
import XCTest
import SwiftUI
@testable import StrandDesign

/// Every kit chart renders in every state (loading, empty, one point, three, a month with gaps, a year)
/// without tripping a Swift Charts assertion, in light and dark. Compiling proves the marks type-check;
/// only rendering proves Charts accepts them.
///
/// Set `NARA_CHART_SNAPSHOTS` to a folder to also write each render there as a PNG for a visual check.
@MainActor
final class ChartRenderSmokeTests: XCTestCase {

    private func render<V: View>(_ name: String, _ view: V, height: CGFloat = 300) throws {
        for scheme in [ColorScheme.light, .dark] {
            let framed = view
                .padding(NoopMetrics.cardPadding)
                .frame(width: 390, height: height)
                .background(StrandPalette.surfaceRaised)
                .environment(\.colorScheme, scheme)
            let renderer = ImageRenderer(content: framed)
            renderer.scale = 2
            let image = try XCTUnwrap(renderer.cgImage, "\(name) did not render")
            XCTAssertGreaterThan(image.width, 0)
            if let folder = ProcessInfo.processInfo.environment["NARA_CHART_SNAPSHOTS"],
               let data = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) {
                let url = URL(fileURLWithPath: folder).appendingPathComponent("\(name)-\(scheme == .dark ? "dark" : "light").png")
                try png.write(to: url)
            }
        }
    }

    private var samples: [NaraChartPreviewSample] {
        NaraChartPreviewSample.Kind.allCases.map { NaraChartPreviewSample(kind: $0) }
    }

    private let none = Binding<Date?>.constant(nil)

    func testDailyBarChartsRender() throws {
        for sample in samples {
            try render("bars-scores-\(sample.kind)", DailyBarChart.scores(
                sample.points(base: 58, swing: 30), bands: NaraChartPreviewData.chargeBands, unit: "%",
                state: sample.state, window: sample.window, xStyle: sample.range.axisStyle,
                selection: .constant(sample.points(base: 1, swing: 0).last?.day), accessibilityTitle: "Charge"))
            for range in [ChartRange.month, .quarter, .year] {
                let window = ChartAxis.window(range, now: sample.now, firstDataDay: nil, calendar: sample.calendar)
                try render("bars-totals-\(range.rawValue)-\(sample.kind)", DailyBarChart.totals(
                    sample.points(base: 8_400, swing: 3_000, estimateEvery: 9), color: StrandPalette.metricCyan,
                    goal: ChartReference(10_000, label: "Goal"), bin: range.totalsBin, state: sample.state,
                    window: window, xStyle: range.axisStyle,
                    y: ChartValueAxis(unit: "steps", domain: .fitted(minSpan: 2_000, includeZero: true)),
                    selection: none, accessibilityTitle: "Steps"))
            }
        }
    }

    func testDailyLineChartsRender() throws {
        for sample in samples {
            let points = sample.points(base: 64, swing: 18, estimateEvery: 11)
            try render("line-\(sample.kind)", DailyLineChart(
                series: [.init(id: "hrv", name: "HRV", color: StrandPalette.metricCyan, points: points),
                         .init(id: "sdnn", name: "SDNN", color: StrandPalette.metricPurple,
                               points: sample.points(base: 80, swing: 10))],
                typicalBand: 52...78, rollingBand: points.map { (day: $0.day, range: ($0.value - 8)...($0.value + 8)) },
                baseline: ChartReference(64, label: "Baseline 64"), state: sample.state, window: sample.window,
                xStyle: sample.range.axisStyle, y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                selection: .constant(points.last?.day), accessibilityTitle: "HRV"))
            try render("spo2-\(sample.kind)", DailyLineChart.fixedDomainPoints(
                sample.points(base: 96, swing: 2), domain: 85...100, reference: ChartReference(95, label: "95 %"),
                color: StrandPalette.metricPurple, joined: false, state: sample.state, window: sample.window,
                xStyle: sample.range.axisStyle, selection: none, accessibilityTitle: "Blood oxygen"))
        }
    }

    func testTheOtherDailyChartsRender() throws {
        for sample in samples {
            try render("diverging-\(sample.kind)", DivergingBarChart(
                points: sample.points(base: 0, swing: 0.6), positive: StrandPalette.metricAmber,
                negative: StrandPalette.metricCyan, positiveLabel: "Warmer", negativeLabel: "Cooler",
                references: [ChartReference(0.5), ChartReference(-0.5)], state: sample.state, window: sample.window,
                xStyle: sample.range.axisStyle,
                y: ChartValueAxis(unit: "Δ°C", domain: .symmetric(minMagnitude: 0.5), format: ChartValueAxis.decimals(1)),
                selection: none, accessibilityTitle: "Skin temperature"))
            try render("rangebars-\(sample.kind)", RangeBarChart(
                items: sample.nights(), typicalStart: sample.clock(22, 45)...sample.clock(23, 30),
                color: StrandPalette.restColor, state: sample.state, window: sample.window,
                xStyle: sample.range.axisStyle, selection: none, accessibilityTitle: "Sleep schedule"))
            try render("stacked-\(sample.kind)", StackedBarChart(
                days: sample.stages(), categories: NaraChartPreviewData.stageCategories, highlighted: "deep",
                state: sample.state, window: sample.window, xStyle: sample.range.axisStyle,
                y: .durationMinutes(), selection: none, accessibilityTitle: "Deep sleep"))
            try render("dots-\(sample.kind)", DotStripChart(
                points: sample.points(base: 3, swing: 2), levels: 1...5, levelLabels: [1: "Low", 5: "Great"],
                color: { _ in StrandPalette.metricPurple }, state: sample.state, window: sample.window,
                xStyle: sample.range.axisStyle, selection: none, accessibilityTitle: "Mood"))
            try render("sparse-\(sample.kind)", SparsePointsChart(
                points: sample.points(base: 72.4, swing: 1.6, every: 3), color: StrandPalette.metricPurple,
                references: [ChartReference(72, label: "Goal")], state: sample.state, window: sample.window,
                xStyle: sample.range.axisStyle,
                y: ChartValueAxis(unit: "kg", domain: .fitted(minSpan: 2), format: ChartValueAxis.decimals(1)),
                selection: none, accessibilityTitle: "Weight"))
            try render("step-\(sample.kind)", StepLineChart(
                points: sample.points(base: 44, swing: 3, every: 7, estimateEvery: 2), color: StrandPalette.chargeColor,
                reference: ChartReference(46, label: "Your age"), state: sample.state, window: sample.window,
                xStyle: sample.range.axisStyle, y: ChartValueAxis(unit: "yrs", domain: .fitted(minSpan: 6)),
                selection: none, accessibilityTitle: "Fitness age"))
        }
    }

    func testIntradayChartsRender() throws {
        for sample in samples {
            let day = sample.dayWindow
            let samples = sample.heartRate()
            try render("intraday-\(sample.kind)", IntradayChart(
                samples: samples, bucketSeconds: 300,
                bands: [.init(id: "sleep", start: day.lowerBound, end: day.lowerBound.addingTimeInterval(7 * 3600),
                              color: StrandPalette.restColor, label: "Asleep"),
                        .init(id: "off", start: day.lowerBound.addingTimeInterval(13 * 3600),
                              end: day.lowerBound.addingTimeInterval(14 * 3600), color: StrandPalette.textTertiary,
                              label: "Off wrist", hatched: true)],
                valueBands: [.init(id: "z2", range: 100...120, color: StrandPalette.zone2, label: "Zone 2")],
                markers: [.init(id: "wake", time: day.lowerBound.addingTimeInterval(7 * 3600), label: "Woke",
                                color: StrandPalette.textSecondary)],
                references: [ChartReference(56, label: "Resting 56")], state: sample.state, window: day,
                y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)),
                selection: .constant(samples.last?.time), accessibilityTitle: "Heart rate"))
            try render("intraday-compact-\(sample.kind)", IntradayChart(
                samples: samples, bucketSeconds: 300, compact: true, live: true, state: sample.state, window: day,
                y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 30)), selection: none,
                accessibilityTitle: "Heart rate today"), height: 160)
        }
    }

    func testTheRangeControlAndLegendRender() throws {
        try render("rangecontrol", VStack {
            RangeControl(selection: .constant(.year), isAvailable: { ($0.days ?? 0) <= 90 })
            ChartLegend([ChartLegendItem(.line(StrandPalette.metricCyan, dashed: false), "RMSSD"),
                         ChartLegendItem(.band(StrandPalette.metricCyan), "Typical range"),
                         ChartLegendItem(.estimate(StrandPalette.metricCyan), "Estimate")])
            ChartPlaceholder(height: 80)
            EmptyChartMessage("No readings yet", height: 80)
        }, height: 280)
    }
}
#endif

import SwiftUI

// MARK: - Chart heights

public extension NoopMetrics {
    /// The primary chart on a detail page (the frame below the `ValueReadout`).
    static let chartHeightPrimary: CGFloat = 240
    /// A secondary chart further down a detail page (stage composition, weekday pattern).
    static let chartHeightSecondary: CGFloat = 160
    /// A chart inside a small card (Today's heart-rate card, the sleep heart-rate strip).
    static let chartHeightCompact: CGFloat = 120
}

// MARK: - Mark styling

/// The one set of mark styles every kit chart draws with, and app-side Swift Charts views should borrow,
/// so a line, a bar or a reference rule looks the same on every screen.
///
/// Named `NaraChartStyle` because `ChartStyle` is already the persisted Default/Classic colour preference
/// (`Appearance.swift`), whose raw values are shared with Android.
public enum NaraChartStyle {
    /// Data lines: 2 pt with round caps and joins.
    public static let lineWidth: CGFloat = 2
    public static let line = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
    /// A line through estimated readings only.
    public static let estimateLine = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round, dash: [4, 3])
    /// The trailing-mean line over bars.
    public static let meanLine = StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 4])

    /// Point marks, as Swift Charts symbol AREA (24 is a ~5.5 pt dot).
    public static let pointSize: CGFloat = 24
    /// The point under the selection rule.
    public static let selectedPointSize: CGFloat = 64
    /// Points in a points-only series with more than `densePointThreshold` readings in the window (a year
    /// of nightly SpO2, a year of mood check-ins), so neighbouring dots do not merge into a blob.
    public static let densePointSize: CGFloat = 10
    public static let densePointThreshold = 90
    /// The ring of a hollow (estimated) point.
    public static let estimateStroke: CGFloat = 1.5

    public static let barCornerRadius: CGFloat = 3
    /// The solid cap on an estimated bar, as a share of the value-axis span.
    public static let estimateCapShare: Double = 0.012
    /// Bar width as a share of its day, week or month.
    public static let barWidthRatio: CGFloat = 0.62
    /// Floating (bedtime to wake) bars are narrower so a run of nights reads as a rhythm.
    public static let rangeBarWidthRatio: CGFloat = 0.5

    /// Typical bands and other filled ranges, as an opacity of the series colour.
    public static let bandOpacity: Double = 0.12
    /// Everything that is not selected while a selection is held.
    public static let dimmedOpacity: Double = 0.35
    /// The fill of an estimated bar (its cap stays solid).
    public static let estimateFillOpacity: Double = 0.35
    /// Stacked categories that are not the highlighted one.
    public static let deemphasisedOpacity: Double = 0.3

    /// Dashed references (baseline, goal, 95 %): 1 pt, 4 on 4 off.
    public static let referenceDash: [CGFloat] = [4, 4]
    public static let reference = StrokeStyle(lineWidth: 1, dash: [4, 4])
    public static let solidReference = StrokeStyle(lineWidth: 1)
    /// The selection rule: 1 pt, solid.
    public static let selectionRule = StrokeStyle(lineWidth: 1)
    /// The axis grid: a hairline.
    public static let grid = StrokeStyle(lineWidth: 0.5)

    /// Marks animate this long, and only when the window or range changes (never on selection).
    public static let rangeAnimationDuration: Double = 0.25
    public static var rangeAnimation: Animation { .easeInOut(duration: rangeAnimationDuration) }

    /// A legend row's fixed height, so a frame with a legend is as tall in every state.
    public static let legendHeight: CGFloat = 20
    /// Space between the plot and its legend.
    public static let legendSpacing: CGFloat = 8
    /// Headroom above the top of the value axis, in points, so a point or label at the maximum is not cut.
    public static let plotTopPadding: CGFloat = 6
    /// A line series with more points than this in its window draws its line alone (points stay for
    /// isolated readings), because dots smaller than their spacing are noise and cost a mark each.
    public static let denseSeriesPointLimit = 60

    public static var axisFont: Font { StrandFont.footnote.monospacedDigit() }
    public static var axisColor: Color { StrandPalette.textTertiary }
    public static var unitFont: Font { StrandFont.caption }
    public static var gridColor: Color { StrandPalette.hairline.opacity(0.4) }
    public static var referenceColor: Color { StrandPalette.textSecondary }
    public static var referenceLabelFont: Font { StrandFont.footnote.monospacedDigit() }
    public static var selectionColor: Color { StrandPalette.textSecondary }
    public static var meanLineColor: Color { StrandPalette.textSecondary }
}

// MARK: - Compact charts

private struct NaraChartCompactKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Whether kit charts in this subtree draw in their compact form: no value-axis labels or unit, fewer
    /// time labels, no legend and no reference labels. For charts inside small cards.
    var naraChartCompact: Bool {
        get { self[NaraChartCompactKey.self] }
        set { self[NaraChartCompactKey.self] = newValue }
    }
}

public extension View {
    /// Draws the kit charts inside this view in their compact form (see `EnvironmentValues.naraChartCompact`).
    func naraChartCompact(_ compact: Bool = true) -> some View {
        environment(\.naraChartCompact, compact)
    }
}

#if !os(watchOS)
// Swift Charts overlays, `HorizontalScrubSurface` (iOS) and `onContinuousHover` (macOS); none exist on the
// watch, which draws no charts.
import SwiftUI
import Charts

// MARK: - Selection rules (pure)

/// The selection rules every kit chart shares, as pure functions so they are tested once.
///
/// A chart's selection is a `Binding<Date?>` the PAGE owns (the same shape as iOS 17's `chartXSelection`,
/// which the macOS 13 floor cannot use), because the page's `ValueReadout` shows the selected value. The
/// chart only snaps a finger or pointer to the nearest x it has.
public enum ChartSelection {

    /// The element of ascending `xs` nearest `date`; the earlier one on a tie. Nil when `xs` is empty.
    public static func nearest(to date: Date, in xs: [Date]) -> Date? {
        nearestIndex(to: date, in: xs).map { xs[$0] }
    }

    /// The index of the element of ascending `xs` nearest `date` (binary search, so a day of per-second
    /// samples costs a handful of comparisons per finger move).
    public static func nearestIndex(to date: Date, in xs: [Date]) -> Int? {
        guard !xs.isEmpty else { return nil }
        var low = 0
        var high = xs.count - 1
        while low < high {
            let mid = (low + high) / 2
            if xs[mid] < date { low = mid + 1 } else { high = mid }
        }
        // `low` is the first x at or after `date`; its predecessor may be nearer.
        if low > 0, date.timeIntervalSince(xs[low - 1]) <= xs[low].timeIntervalSince(date) {
            return low - 1
        }
        return low
    }

    /// One VoiceOver adjustment step through ascending `xs`: forward from nothing selects the first x and
    /// backward the last; stepping past either end stays there.
    public static func step(from current: Date?, in xs: [Date], forward: Bool) -> Date? {
        guard !xs.isEmpty else { return nil }
        guard let current, let index = xs.firstIndex(of: current) ?? nearest(to: current, in: xs).flatMap({ xs.firstIndex(of: $0) }) else {
            return forward ? xs.first : xs.last
        }
        let next = forward ? min(index + 1, xs.count - 1) : max(index - 1, 0)
        return xs[next]
    }

    /// The point a page's readout shows for `selection`: the point in the same calendar `unit` (the bin a
    /// bar chart aggregates to, `.day` otherwise), or nil when nothing is selected or that day has no value.
    /// For a binned bar chart pass the binned points (`DailyBarChart.bin`), so the readout shows the bar.
    public static func point(for selection: Date?, in points: [DailyPoint], unit: Calendar.Component = .day,
                             calendar: Calendar = .current) -> DailyPoint? {
        guard let selection, let start = calendar.dateInterval(of: unit, for: selection)?.start else { return nil }
        return points.first { calendar.dateInterval(of: unit, for: $0.day)?.start == start }
    }

    /// What a tap does: tapping the x that is already selected clears it; tapping any other x selects it.
    public static func afterTap(current: Date?, tapped: Date?) -> Date? {
        guard let tapped else { return current }
        return tapped == current ? nil : tapped
    }
}

// MARK: - Scrub layer

private struct NaraChartScrubEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

public extension EnvironmentValues {
    /// Whether kit charts in this subtree respond to touch and pointer. Off for a chart inside a card that
    /// is itself a link, so taps reach the link.
    var naraChartScrubEnabled: Bool {
        get { self[NaraChartScrubEnabledKey.self] }
        set { self[NaraChartScrubEnabledKey.self] = newValue }
    }
}

public extension View {
    /// Turns off scrubbing for the kit charts inside this view (see `EnvironmentValues.naraChartScrubEnabled`).
    func naraChartScrubDisabled(_ disabled: Bool = true) -> some View {
        environment(\.naraChartScrubEnabled, !disabled)
    }

    /// Adds the kit's scrub to any Swift Charts chart over a date axis. See `ChartScrubLayer`.
    func chartScrub(xs: [Date], selection: Binding<Date?>, pinsOnTap: Bool = true) -> some View {
        chartOverlay { proxy in
            ChartScrubLayer(proxy: proxy, xs: xs, selection: selection, pinsOnTap: pinsOnTap)
        }
    }
}

/// The scrub every kit chart puts in its `chartOverlay`.
///
/// iPhone: a `HorizontalScrubSurface` over the plot. A sideways drag selects the nearest x live and clears
/// when the finger lifts; a tap pins the nearest x, and tapping it again clears it; a vertical swipe that
/// starts on the chart still scrolls the page, because the surface never claims one. Mac: the pointer
/// selects as it moves and clears when it leaves; a click pins (the pointer then leaves the selection alone)
/// and a click on the pinned x releases it.
///
/// Every new x plays one `StrandHaptic.selection` (a no-op on the Mac) and lands in a non-animating
/// transaction, so the marks never replay their animation under a finger (#104).
///
/// ```swift
/// .chartOverlay { proxy in ChartScrubLayer(proxy: proxy, xs: days, selection: $selected) }
/// ```
public struct ChartScrubLayer: View {
    private let proxy: ChartProxy
    private let xs: [Date]
    @Binding private var selection: Date?
    private let pinsOnTap: Bool
    @Environment(\.naraChartScrubEnabled) private var enabled
    #if os(macOS)
    @State private var pinned = false
    #endif

    /// - Parameter xs: the selectable x values, ascending (the days or samples the chart draws).
    public init(proxy: ChartProxy, xs: [Date], selection: Binding<Date?>, pinsOnTap: Bool = true) {
        self.proxy = proxy
        self.xs = xs
        self._selection = selection
        self.pinsOnTap = pinsOnTap
    }

    public var body: some View {
        GeometryReader { geo in
            let plot = proxy.plotRectCompat(in: geo)
            if enabled && !xs.isEmpty {
                surface(plot: plot)
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        }
    }

    @ViewBuilder
    private func surface(plot: CGRect) -> some View {
        #if canImport(UIKit) && os(iOS)
        HorizontalScrubSurface(
            onScrub: { select(nearest(toX: $0, plot: plot)) },
            onEnd: { select(nil) },
            onTap: pinsOnTap ? { x in select(ChartSelection.afterTap(current: selection, tapped: nearest(toX: x, plot: plot))) } : nil
        )
        #else
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .onContinuousHover(coordinateSpace: CoordinateSpace.local) { phase in
                if pinned && selection == nil { pinned = false }
                guard !pinned else { return }
                switch phase {
                case .active(let location): select(nearest(toX: location.x, plot: plot))
                case .ended: select(nil)
                }
            }
            .onTapGesture(count: 1, coordinateSpace: CoordinateSpace.local) { location in
                guard pinsOnTap else { return }
                let tapped = nearest(toX: location.x, plot: plot)
                if pinned && tapped == selection {
                    pinned = false
                } else {
                    pinned = true
                    select(tapped)
                }
            }
        #endif
    }

    private func nearest(toX x: CGFloat, plot: CGRect) -> Date? {
        guard plot.width > 0 else { return nil }
        let clamped = min(max(x, plot.minX), plot.maxX)
        guard let date: Date = proxy.value(atX: clamped - plot.minX) else { return nil }
        return ChartSelection.nearest(to: date, in: xs)
    }

    private func select(_ next: Date?) {
        guard next != selection else { return }
        if next != nil { StrandHaptic.selection.play() }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { selection = next }
    }
}

// MARK: - Selection rule

/// The 1 pt rule that marks the selected x. Pass the same `unit` the chart's marks use, so the rule sits in
/// the middle of the selected day, week or month; nil for a raw time (intraday).
public struct SelectionRule: ChartContent {
    private let date: Date?
    private let unit: Calendar.Component?

    public init(_ date: Date?, unit: Calendar.Component? = .day) {
        self.date = date
        self.unit = unit
    }

    public var body: some ChartContent {
        if let date {
            if let unit {
                RuleMark(x: .value("Selected", date, unit: unit))
                    .lineStyle(NaraChartStyle.selectionRule)
                    .foregroundStyle(NaraChartStyle.selectionColor)
            } else {
                RuleMark(x: .value("Selected", date))
                    .lineStyle(NaraChartStyle.selectionRule)
                    .foregroundStyle(NaraChartStyle.selectionColor)
            }
        }
    }
}
#endif

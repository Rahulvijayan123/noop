import SwiftUI

// MARK: - ChartRange

/// The one set of time ranges a history chart pages through: W, M, 3M, 6M, Y, All.
///
/// Each screen used to bring its own enum ("7D/30D/90D", "1Y" vs "Y", "ALL" vs "All"); this is the one the
/// control shows. A screen whose data layer keeps its own window type (the detail page's `ExploreRange`)
/// maps to and from this one at the view boundary.
public enum ChartRange: String, CaseIterable, Identifiable, Hashable, Sendable {
    case week = "W", month = "M", quarter = "3M", half = "6M", year = "Y", all = "All"

    public var id: String { rawValue }

    /// The segment label.
    public var label: String {
        switch self {
        case .week: return String(localized: "W", bundle: .module)
        case .month: return String(localized: "M", bundle: .module)
        case .quarter: return String(localized: "3M", bundle: .module)
        case .half: return String(localized: "6M", bundle: .module)
        case .year: return String(localized: "Y", bundle: .module)
        case .all: return String(localized: "All", bundle: .module)
        }
    }

    /// What VoiceOver reads for the segment ("3 months" rather than "3M").
    public var accessibilityName: String {
        switch self {
        case .week: return String(localized: "1 week", bundle: .module)
        case .month: return String(localized: "1 month", bundle: .module)
        case .quarter: return String(localized: "3 months", bundle: .module)
        case .half: return String(localized: "6 months", bundle: .module)
        case .year: return String(localized: "1 year", bundle: .module)
        case .all: return String(localized: "All time", bundle: .module)
        }
    }

    /// Local days the window spans, ending today. Nil for `.all`, which starts at the first reading.
    public var days: Int? {
        switch self {
        case .week: return 7
        case .month: return 30
        case .quarter: return 90
        case .half: return 180
        case .year: return 365
        case .all: return nil
        }
    }

    /// The x-axis labels this range asks for. The axis still adapts when the actual window is shorter or
    /// longer than the style suits (an All window over ten days of history reads by day, not by month).
    public var axisStyle: ChartAxisStyle {
        switch self {
        case .week: return .weekday
        case .month: return .dayOfMonth
        case .quarter, .half, .year: return .month
        case .all: return .monthYear
        }
    }

    /// The bin for DAILY-TOTAL metrics (steps, calories, minutes) on this range: daily bars for W and M,
    /// weekly for 3M, monthly from 6M up. The same rule the steps detail already uses
    /// (`MetricDetailSteps.resolution(for:)`), so steps and every other total page agree.
    ///
    /// For `.all` this is always `.month`; prefer `totalsBin(for: window)`, which bins All by the span the
    /// history actually covers.
    public var totalsBin: Calendar.Component {
        switch self {
        case .week, .month: return .day
        case .quarter: return .weekOfYear
        case .half, .year, .all: return .month
        }
    }

    /// The bin for this range's actual `window` (from `ChartAxis.window`): `totalsBin` for the fixed ranges,
    /// and for `.all` the bin its span suits (`ChartRange.totalsBin(spanning:)`). A new user's All of three
    /// weeks is 21 daily bars, not two fat monthly ones.
    public func totalsBin(for window: ClosedRange<Date>, calendar: Calendar = .current) -> Calendar.Component {
        self == .all ? Self.totalsBin(spanning: window, calendar: calendar) : totalsBin
    }

    /// The bin a window's span suits, by the same breakpoints as the fixed ranges: daily bars up to 62 days
    /// (W, M), weekly up to 200 (3M), monthly beyond (6M, Y). Pure.
    public static func totalsBin(spanning window: ClosedRange<Date>, calendar: Calendar = .current) -> Calendar.Component {
        let last = window.upperBound > window.lowerBound ? window.upperBound.addingTimeInterval(-1) : window.lowerBound
        let days = ChartDay.daysBetween(window.lowerBound, last, calendar: calendar) + 1
        if days <= 62 { return .day }
        if days <= 200 { return .weekOfYear }
        return .month
    }
}

// MARK: - RangeControl

/// The one time-range control: an equal-width `SegmentedPillControl` at a fixed height, with the control's
/// own selection haptic.
///
/// Only the ranges the history can fill are shown (plus All), so a disabled "Y" never sits between "6M"
/// and "All" and no "Longer ranges unlock…" helper is needed. With one option left there is nothing to
/// choose, and the control is not drawn.
///
/// The selection is coerced for DISPLAY only, never written back on its own: a stored "Y" on a history that
/// cannot fill a year shows as the largest range that it can, and comes back as soon as the history grows.
/// That is the same non-destructive rule as the detail page's `ExploreRangeGating`, so the two never
/// disagree. The page draws `RangeControl.effectiveRange(range, …)` (the same coercion), so the chart always
/// shows the highlighted segment. Tapping the highlighted segment commits it (a stored "Y" shown as "3M"
/// becomes "3M").
///
/// ```swift
/// RangeControl(selection: $range, isAvailable: { unlocked(ExploreRange($0)) })
/// let shown = RangeControl.effectiveRange(range, isAvailable: { unlocked(ExploreRange($0)) })
/// ```
public struct RangeControl: View {
    /// The control's fixed height: a 32 pt segment inside the 3 pt track inset.
    public static let height: CGFloat = 38

    @Binding private var selection: ChartRange
    private let visible: [ChartRange]
    private let reservesSpaceWhenHidden: Bool

    /// - Parameters:
    ///   - options: the ranges this screen offers, in any order (shown in the canonical order).
    ///   - isAvailable: whether the history can fill a range. `.all` is always shown when offered.
    ///   - reservesSpaceWhenHidden: keep the control's height when it hides, for a page whose layout must
    ///     not move when the history turns out to be short.
    public init(selection: Binding<ChartRange>,
                options: [ChartRange] = ChartRange.allCases,
                isAvailable: (ChartRange) -> Bool = { _ in true },
                reservesSpaceWhenHidden: Bool = false) {
        self._selection = selection
        self.visible = Self.visibleOptions(options, isAvailable: isAvailable)
        self.reservesSpaceWhenHidden = reservesSpaceWhenHidden
    }

    /// The segments the control shows: the offered ranges that are available, plus `.all` when offered, in
    /// the canonical W…All order without duplicates. Pure.
    public static func visibleOptions(_ options: [ChartRange], isAvailable: (ChartRange) -> Bool) -> [ChartRange] {
        let offered = Set(options)
        return ChartRange.allCases.filter { offered.contains($0) && ($0 == .all || isAvailable($0)) }
    }

    /// Whether the control draws at all.
    public static func isHidden(visible: [ChartRange]) -> Bool { visible.count <= 1 }

    /// The range a page should DRAW for a stored `selection`: the segment the control shows for it
    /// (`displayedSelection`), or the selection itself when the control has nothing to show. Compute it once
    /// and use it for the window, the axis style and the bin, so the chart always matches the highlighted
    /// segment. Pure.
    ///
    /// ```swift
    /// let shown = RangeControl.effectiveRange(range, isAvailable: { unlocked(ExploreRange($0)) })
    /// let window = ChartAxis.window(shown, firstDataDay: points.first?.day)
    /// ```
    public static func effectiveRange(_ selection: ChartRange, options: [ChartRange] = ChartRange.allCases,
                                      isAvailable: (ChartRange) -> Bool = { _ in true }) -> ChartRange {
        displayedSelection(selection, visible: visibleOptions(options, isAvailable: isAvailable)) ?? selection
    }

    /// The segment shown as selected: the selection itself when visible, else the largest visible finite
    /// range no longer than it, else the shortest visible range. Never coerces to `.all` unless that is the
    /// selection or the only option. Pure.
    public static func displayedSelection(_ selection: ChartRange, visible: [ChartRange]) -> ChartRange? {
        if visible.contains(selection) { return selection }
        let limit = selection.days ?? Int.max
        if let fit = visible.filter({ ($0.days ?? Int.max) <= limit && $0.days != nil }).max(by: { ($0.days ?? 0) < ($1.days ?? 0) }) {
            return fit
        }
        return visible.first { $0.days != nil } ?? visible.first
    }

    public var body: some View {
        if !Self.isHidden(visible: visible) {
            let shown = Binding<ChartRange>(
                get: { Self.displayedSelection(selection, visible: visible) ?? selection },
                set: { selection = $0 }
            )
            SegmentedPillControl(visible, selection: shown, fillsAvailableWidth: true, isEnabled: { _ in true },
                                 commitsReselection: true) { $0.label }
                .frame(height: Self.height)
                // The segments are single letters; VoiceOver reads a picker of full names instead.
                .accessibilityRepresentation {
                    Picker(String(localized: "Range", bundle: .module), selection: shown) {
                        ForEach(visible) { range in
                            Text(range.accessibilityName).tag(range)
                        }
                    }
                }
        } else if reservesSpaceWhenHidden {
            Color.clear
                .frame(height: Self.height)
                .accessibilityHidden(true)
        }
    }
}

#if DEBUG
private struct RangeControlPreview: View {
    @State private var range: ChartRange = .year
    var body: some View {
        VStack(spacing: NoopMetrics.space4) {
            RangeControl(selection: $range)
            RangeControl(selection: $range, isAvailable: { ($0.days ?? 0) <= 90 })
            RangeControl(selection: $range, isAvailable: { _ in false }, reservesSpaceWhenHidden: true)
            Text("Selected: \(range.accessibilityName)").font(StrandFont.footnote)
        }
        .padding(NoopMetrics.screenHPadding)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("RangeControl · light") { RangeControlPreview().preferredColorScheme(.light) }
#Preview("RangeControl · dark") { RangeControlPreview().preferredColorScheme(.dark) }
#endif

import Foundation
import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Training Load card (CTL / ATL / TSB)
//
// The first UI surface for the long-horizon training-load model (TrainingLoadEngine, added with the
// paired `ReadinessEngine.evaluateWithTrainingLoad`). It overlays chronic load (CTL, the 42-day
// fitness proxy) and acute load (ATL, the 7-day fatigue proxy); the gap between the two lines IS the
// TSB / "form" (CTL − ATL), surfaced as the headline number and a footer stat.
//
// Descriptive only: CTL/ATL/TSB never feed the Readiness level or any score, and the loads are Nara's
// daily Effort/strain — NOT TRIMP. Long-horizon by nature, so the card MODELS the full history and only
// DRAWS the Trends range window (14+ contiguous days are needed before anything is drawn). The kit's
// two-line chart shows Fitness (CTL) and Fatigue (ATL); Form (TSB) is the readout.
//
// Isolated in its own file on purpose: TrendsView already sits near the iOS type-check budget, so this
// keeps its own inference cost out of that body.
struct TrainingLoadCard: View {
    let days: [DailyMetric]

    /// The range and window the Trends charts above it draw, so the two lines follow the range control.
    /// The model itself always runs over the FULL history (chronic load is a 42-day horizon).
    var range: ChartRange = .quarter
    var window: ClosedRange<Date> = ChartAxis.window(.quarter, firstDataDay: nil)
    var isLoading: Bool = false

    @State private var selected: Date?

    /// PERF: `result` used to be a plain computed property re-running `TrainingLoadEngine.evaluate`
    /// (a full-history EWMA scan) from scratch on every access — and `body` hit it TWICE per render
    /// (`let tl = result` here, then again via the old `rows`/`chart` computed properties), so opening
    /// this card ran the model twice per render, including on animation/hover frames and, before the
    /// `WorkoutsView`/`HealthView` AppModel-isolation fixes elsewhere, on every ~1 Hz live-HR tick.
    /// Mirrors the `modelCache`/`modelCacheKey` idiom `CompareView` already uses for its own memoized
    /// chart model (CompareView.swift:741-742): cached value + fingerprint, refreshed via `onAppear`/
    /// `onChange` rather than mutated mid-body.
    @State private var resultCache: TrainingLoadEngine.Result = Self.computeResult(days: [])
    @State private var resultCacheKey: String = ""

    /// Fingerprint of `days`. `days` is `Repository.days` (TrendsView.swift) — the SAME live-updating
    /// array `HealthView`/`TrendsView` observe, whose latest entry keeps accumulating strain through the
    /// day. That's why this can't copy `CompareView.modelKey`'s count+endpoints idiom verbatim (a fixed
    /// count/date range with a changing LAST value would never invalidate the cache): the key covers the
    /// total count (so a backfill/import that lengthens history always invalidates) plus every
    /// `(day, strain)` pair in the trailing `establishedDays` window the model actually weighs at anything
    /// more than a couple of percent (42-day EWMA — older days are exponentially near-zero weight).
    /// `internal` (not `private`), matching the MotionTrace-peak precedent (#2288) of the minimum a test
    /// can reach, so `StrandTests` can pin it without rendering the chart.
    static func modelKey(for days: [DailyMetric]) -> String {
        let tail = days.suffix(TrainingLoadEngine.Configuration.standard.establishedDays)
        return "\(days.count)|" + tail.map { "\($0.day):\($0.strain ?? -1)" }.joined(separator: ",")
    }

    /// Model straight from the training-load engine — NOT the paired `evaluateWithTrainingLoad`, which
    /// would also run the full Readiness synthesis this card never uses. `DailyMetric.strain` is the load.
    private static func computeResult(days: [DailyMetric]) -> TrainingLoadEngine.Result {
        let loads = days.map { TrainingLoadEngine.DailyLoad(day: $0.day, load: $0.strain) }
        return TrainingLoadEngine.evaluate(days: loads)
    }

    /// Cached accessor used by `body`. Mirrors `CompareView.currentModel`: returns the memoized result
    /// when the inputs match, else computes for THIS render (without mutating state mid-body); the
    /// matching `.onAppear`/`.onChange` then persist it so subsequent hover/animation frames hit the cache.
    private var result: TrainingLoadEngine.Result {
        Self.modelKey(for: days) == resultCacheKey ? resultCache : Self.computeResult(days: days)
    }

    /// Rebuild the result cache if (and only if) the fingerprint changed.
    private func refreshResult() {
        let key = Self.modelKey(for: days)
        guard key != resultCacheKey else { return }
        resultCacheKey = key
        resultCache = Self.computeResult(days: days)
    }

    private static let established = TrainingLoadEngine.Configuration.standard.establishedDays
    private static let minimum = TrainingLoadEngine.Configuration.standard.minimumDays

    private func fmt(_ v: Double) -> String { String(format: "%.1f", v) }
    private func signed(_ v: Double) -> String { String(format: "%+.1f", v) }

    var body: some View {
        let tl = result
        let fitness = tl.points.compactMap { DailyPoint(key: $0.day, value: $0.chronicLoad, series: "fitness") }
        let fatigue = tl.points.compactMap { DailyPoint(key: $0.day, value: $0.acuteLoad, series: "fatigue") }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Training load", trailing: tl.state == .building
                          ? String(localized: "Building, \(tl.contiguousDays) of \(Self.established) days") : nil)
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    readout(tl)
                    DailyLineChart(series: [
                                       .init(id: "fitness", name: String(localized: "Fitness"),
                                             color: StrandPalette.effortColor, points: fitness),
                                       .init(id: "fatigue", name: String(localized: "Fatigue"),
                                             color: StrandPalette.metricAmber, points: fatigue),
                                   ],
                                   marks: .lineOnly,
                                   state: isLoading ? .loading
                                       : (tl.isAvailable ? .ready
                                          : .empty(String(localized: "Needs \(Self.minimum)+ consecutive days of Effort to begin. \(tl.contiguousDays) so far."))),
                                   window: window, xStyle: range.axisStyle,
                                   y: ChartValueAxis(unit: nil, domain: .fitted(minSpan: 10, includeZero: true)),
                                   selection: $selected, height: NoopMetrics.chartHeightSecondary,
                                   accessibilityTitle: String(localized: "Training load"))
                }
            }
        }
        // Persist the memoized result into `@State` (mirrors `CompareView`'s `.onAppear { refreshModel() }`
        // / `.onChangeCompat(of: modelKey)` pair) so the NEXT render's `result` access hits the cache
        // instead of recomputing — `body` itself never mutates `@State` mid-evaluation.
        .onAppear { refreshResult() }
        .onChangeCompat(of: Self.modelKey(for: days)) { _ in refreshResult() }
        .onChangeCompat(of: range) { _ in selected = nil }
    }

    /// The day under the finger (fitness, fatigue and form), else the latest form.
    private func readout(_ tl: TrainingLoadEngine.Result) -> some View {
        if let selected, let point = tl.points.first(where: { $0.day == ChartDay.key(for: selected) }) {
            return InsightsCardReadout(
                value: signed(point.balance), unit: String(localized: "form"),
                context: "\(ReadoutContent.dateLine(selected, period: .day)) · \(String(localized: "Fitness")) \(fmt(point.chronicLoad)) · \(String(localized: "Fatigue")) \(fmt(point.acuteLoad))")
        }
        let latest = tl.isAvailable ? tl.points.last : nil
        return InsightsCardReadout(value: latest.map { signed($0.balance) }, unit: String(localized: "form"),
                                   context: latest.map { "\(String(localized: "Fitness")) \(fmt($0.chronicLoad)) · \(String(localized: "Fatigue")) \(fmt($0.acuteLoad))" } ?? "")
    }
}

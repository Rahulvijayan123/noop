#if !os(watchOS)
// Wraps `TrendChart.gapSegments` and `hrGapSegments`, which live in the watch-excluded TrendChart.swift; the
// watch draws no charts, so the line-run rules are excluded with them.
import Foundation

// MARK: - ChartGaps

/// Where a chart's line lifts: one run id per unbroken stretch, per series. Pure.
///
/// A line joined across a missing week draws a steady change the wearer never had, so every kit line breaks
/// wherever the series skips more than its cadence. The intraday and adaptive rules are the existing,
/// tested ones (`hrGapSegments`, `TrendChart.gapSegments`); this only chooses between them by cadence and
/// adds the day-based rules for nightly, weekly and sparse metrics.
public enum ChartGaps {

    /// Run ids for ascending `days`, one per point. A run ends where the gap to the next point exceeds the
    /// cadence, and wherever `series` changes, so two methods are never joined either. Each id is
    /// `"<series>#<n>"` with `n` counting every break, so a series that resumes after another one does not
    /// reuse its earlier id and get joined across the interruption.
    ///
    /// Day gaps are counted in whole LOCAL calendar days, so the 23- and 25-hour days of a clock change are
    /// still one day apart and do not break a nightly line.
    public static func runs(_ days: [Date], series: [String], cadence: ChartCadence,
                            calendar: Calendar = .current) -> [String] {
        guard days.count == series.count, !days.isEmpty else { return series }
        let gapBreaks = breaks(days, cadence: cadence, calendar: calendar)
        var run = 0
        return days.indices.map { i in
            if i > 0, gapBreaks[i] || series[i] != series[i - 1] { run += 1 }
            return "\(series[i])#\(run)"
        }
    }

    /// Whether a line breaks BEFORE each point because of its distance from the previous one.
    static func breaks(_ days: [Date], cadence: ChartCadence, calendar: Calendar) -> [Bool] {
        switch cadence {
        case .adaptive:
            // The run numbers `gapSegments` appends, read without the caller's segments.
            let ids = TrendChart.gapSegments(dates: days, segments: Array(repeating: "", count: days.count))
            return days.indices.map { $0 > 0 && ids[$0] != ids[$0 - 1] }
        case .buckets(let seconds):
            let ids = hrGapSegments(bucketTs: days.map { Int($0.timeIntervalSince1970.rounded()) },
                                    bucketSeconds: seconds)
            return days.indices.map { $0 > 0 && ids[$0] != ids[$0 - 1] }
        case .daily, .weekly, .sparse:
            let limit = maxGapDays(cadence)
            return days.indices.map { i in
                i > 0 && ChartDay.daysBetween(days[i - 1], days[i], calendar: calendar) > limit
            }
        }
    }

    /// The longest step, in days, that still joins two readings.
    static func maxGapDays(_ cadence: ChartCadence) -> Int {
        switch cadence {
        case .daily: return 1
        case .weekly: return 10
        case .sparse(let days): return max(1, days)
        case .buckets, .adaptive: return 1
        }
    }
}
#endif

#if !os(watchOS)
// Wraps `TrendChart.gapSegments` and `hrGapSegments`, which live in the watch-excluded TrendChart.swift; the
// watch draws no charts, so the line-run rules are excluded with them.
import Foundation

// MARK: - ChartGaps

/// Where a chart's line lifts: one run id per unbroken stretch, per series. Pure.
///
/// A line joined across a missing week draws a steady change the wearer never had, so every kit line breaks
/// wherever the series skips more than its cadence. The adaptive rule is the existing, tested
/// `TrendChart.gapSegments`; the intraday rule is `hrGapSegments`' with half a bucket of tolerance for
/// samples timed at their measurement rather than their bucket start; the day-based rules cover nightly,
/// weekly and sparse metrics.
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
            // The `hrGapSegments` rule (a step longer than one bucket is a skipped bucket), made tolerant of
            // samples stamped at the moment they were measured rather than at their bucket start (a 1 Hz live
            // trace reading at 1.0 s, 2.6 s, 3.4 s): a break needs a whole bucket with no sample in it (the
            // bucket indices skip one) AND a step of more than one and a half buckets. Bucket starts, which
            // step by exactly one bucket or by two or more, break exactly where `hrGapSegments` breaks them.
            let size = Double(max(1, seconds))
            return days.indices.map { i in
                guard i > 0 else { return false }
                let previous = days[i - 1].timeIntervalSince1970
                let current = days[i].timeIntervalSince1970
                return current - previous > size * 1.5
                    && (current / size).rounded(.down) - (previous / size).rounded(.down) > 1
            }
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

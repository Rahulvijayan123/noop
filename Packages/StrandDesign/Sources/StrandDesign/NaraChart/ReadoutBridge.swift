import SwiftUI

// MARK: - ReadoutContent from chart values
//
// The bridge between what a kit chart draws and what the `ValueReadout` above it says, so every page reads
// its selection the same way: the selected point (or the latest one when nothing is selected), its date line
// in the period the mark covers, the value with its unit, and the estimate flag. `ValueReadout` itself stays
// free of chart types (it builds on watchOS); these extensions live beside the chart data instead.

public extension ReadoutContent.Period {
    /// The period one mark of a chart binned to `bin` covers: `.week` for weekly bins, `.month` for monthly
    /// bins, otherwise `.day`, or `.night` for a nightly metric (dated by its wake day).
    ///
    /// ```swift
    /// let period = ReadoutContent.Period(bin: range.totalsBin)             // steps: day, week or month
    /// let period = ReadoutContent.Period(bin: .day, nightly: true)          // HRV, asleep time
    /// ```
    init(bin: Calendar.Component, nightly: Bool = false) {
        switch bin {
        case .weekOfYear, .weekOfMonth, .yearForWeekOfYear: self = .week
        case .month: self = .month
        default: self = nightly ? .night : .day
        }
    }
}

public extension ReadoutContent {

    /// The readout for one daily (or binned) value. A nil `point` reads "—" with no unit, under the date
    /// line of `fallbackDate` (the selected day that has no reading) or an empty, still reserved, line.
    ///
    /// - Parameters:
    ///   - format: the value's text without its unit ("62", "9,412", "7 h 32 m").
    ///   - period: how the date line reads (`Period(bin:nightly:)` picks it from the chart's bin).
    ///   - valueColor: only for a score drawn in its band colour, e.g. `{ bands.band(for: $0).color }`.
    static func daily(_ point: DailyPoint?, unit: String?, format: (Double) -> String,
                      context: String? = nil, period: Period = .day,
                      valueColor: ((Double) -> Color)? = nil, fallbackDate: Date? = nil,
                      now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> ReadoutContent {
        let date = point?.localDay(in: calendar) ?? fallbackDate
        let line = date.map { dateLine($0, period: period, now: now, calendar: calendar, locale: locale) } ?? ""
        return ReadoutContent(dateLine: line,
                              value: point.map { format($0.value) },
                              unit: unit,
                              context: context,
                              valueColor: point.flatMap { p in valueColor.map { $0(p.value) } },
                              isEstimate: point?.isEstimate ?? false)
    }

    /// The readout a detail page shows above a daily chart: the selected point when a selection is held,
    /// else the latest point. `points` are the values the chart draws: for a binned bar chart pass
    /// `DailyBarChart.bin(points, by: bin, aggregation:)` and the same `bin`, so the readout shows the bar
    /// (a weekly mean, a monthly total) rather than one day inside it. A selected day with no reading reads
    /// "—" under that day's date.
    ///
    /// ```swift
    /// ValueReadout(.daily(selection: selected, in: nights, nightly: true, unit: "ms", format: fmt,
    ///                     context: selected == nil ? "7-day avg 61 ms" : nil),
    ///              isScrubbing: selected != nil, isLoading: !loaded)
    /// ```
    static func daily(selection: Date?, in points: [DailyPoint], bin: Calendar.Component = .day,
                      nightly: Bool = false, unit: String?, format: (Double) -> String,
                      context: String? = nil, valueColor: ((Double) -> Color)? = nil,
                      now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> ReadoutContent {
        let period = Period(bin: bin, nightly: nightly)
        let fallback = selection.flatMap { calendar.dateInterval(of: bin, for: $0)?.start }
        let point: DailyPoint?
        if let fallback {
            // The same rule as `ChartSelection.point(for:in:unit:)`, written out here because that type is
            // chart-only and this bridge also builds on the watch.
            point = points.first { calendar.dateInterval(of: bin, for: $0.localDay(in: calendar))?.start == fallback }
        } else if selection == nil {
            point = points.filter { $0.value.isFinite }.max { $0.day < $1.day }
        } else {
            point = nil
        }
        return daily(point, unit: unit, format: format, context: context, period: period,
                     valueColor: valueColor, fallbackDate: fallback, now: now, calendar: calendar, locale: locale)
    }
}

#if !os(watchOS)
// `IntradayChart.Sample` lives with the chart, which the watch does not build.

public extension ChartSelection {
    /// The sample a page's readout shows for an intraday `selection`: the nearest sample (the same one the
    /// chart's rule snaps to), or nil when nothing is selected. `samples` must be ascending by time, as the
    /// chart draws them.
    static func sample(for selection: Date?, in samples: [IntradayChart.Sample]) -> IntradayChart.Sample? {
        guard let selection, let index = nearestIndex(to: selection, in: samples.map(\.time)) else { return nil }
        return samples[index]
    }
}

public extension ReadoutContent {

    /// The readout for one intraday sample: "Tue 7 Oct, 14:05" (`Period.time`), the value and its unit. A
    /// nil sample reads "—" under `fallbackTime` (or an empty, reserved line).
    static func intraday(_ sample: IntradayChart.Sample?, unit: String?, format: (Double) -> String,
                         context: String? = nil, fallbackTime: Date? = nil,
                         now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> ReadoutContent {
        let time = sample?.time ?? fallbackTime
        return ReadoutContent(dateLine: time.map { dateLine($0, period: .time, now: now, calendar: calendar, locale: locale) } ?? "",
                              value: sample.map { format($0.value) },
                              unit: unit,
                              context: context,
                              isEstimate: sample?.isEstimate ?? false)
    }

    /// The readout above a `RangeBarChart`: the selected night (or week or month, with the same means the
    /// bars show: pass `RangeBarChart.bin(items, by: bin)`), else the latest. The value reads
    /// "11:20 PM – 7:05 AM" with no unit; a selected night with no bar reads "—" under its date. With two
    /// spans on one day (a nap), the longest is read.
    ///
    /// ```swift
    /// let spans = RangeBarChart.bin(items, by: range.totalsBin)
    /// ValueReadout(.range(selection: selected, in: spans, bin: range.totalsBin), isScrubbing: selected != nil)
    /// ```
    static func range(selection: Date?, in spans: [RangeBarChart.Span], bin: Calendar.Component = .day,
                      anchorHour: Int = 18, context: String? = nil,
                      now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> ReadoutContent {
        let period = Period(bin: bin, nightly: true)
        let fallback = selection.flatMap { calendar.dateInterval(of: bin, for: $0)?.start }
        func longest(_ candidates: [RangeBarChart.Span]) -> RangeBarChart.Span? {
            candidates.max { (a: RangeBarChart.Span, b: RangeBarChart.Span) -> Bool in
                let lengthA: Double = a.end - a.start
                let lengthB: Double = b.end - b.start
                return lengthA < lengthB
            }
        }
        let span: RangeBarChart.Span?
        if let fallback {
            span = longest(spans.filter { calendar.dateInterval(of: bin, for: $0.day)?.start == fallback })
        } else if selection == nil {
            let latest = spans.map(\.day).max()
            span = longest(spans.filter { $0.day == latest })
        } else {
            span = nil
        }
        let date = span?.day ?? fallback
        let value = span.map { span -> String in
            let start = RangeBarChart.clockLabel(offset: span.start, anchorHour: anchorHour, calendar: calendar)
            let end = RangeBarChart.clockLabel(offset: span.end, anchorHour: anchorHour, calendar: calendar)
            return String(localized: "\(start) – \(end)", bundle: .module)
        }
        return ReadoutContent(dateLine: date.map { dateLine($0, period: period, now: now, calendar: calendar, locale: locale) } ?? "",
                              value: value, unit: nil, context: context, isEstimate: span?.isEstimate ?? false)
    }

    /// The readout above an intraday chart: the sample under the selection, else the latest sample.
    static func intraday(selection: Date?, in samples: [IntradayChart.Sample], unit: String?,
                         format: (Double) -> String, context: String? = nil,
                         now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> ReadoutContent {
        let sample = selection == nil
            ? samples.filter { $0.value.isFinite }.max { $0.time < $1.time }
            : ChartSelection.sample(for: selection, in: samples)
        return intraday(sample, unit: unit, format: format, context: context, fallbackTime: selection,
                        now: now, calendar: calendar, locale: locale)
    }
}
#endif

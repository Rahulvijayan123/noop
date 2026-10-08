import SwiftUI

// MARK: - Value and unit as one line

/// A value and its unit as ONE `Text`, so `lineLimit(1)` + `minimumScaleFactor` shrink them together:
/// two `Text`s in an `HStack` shrink separately and the value is cut ("252,6… steps") before the pair as a
/// whole gets smaller. The unit follows a space, in its own font and colour, on the value's baseline.
enum ValueUnitText {
    static func make(_ value: String, font: Font, color: Color, tracking: CGFloat = 0,
                     unit: String?, unitFont: Font, unitColor: Color = StrandPalette.textSecondary) -> Text {
        let number = colored(Text(value).font(font).tracking(tracking), color)
        guard let unit, !unit.isEmpty else { return number }
        return number + colored(Text(" " + unit).font(unitFont), unitColor)
    }

    private static func colored(_ text: Text, _ color: Color) -> Text {
        if #available(iOS 17.0, macOS 14.0, watchOS 10.0, *) {
            return text.foregroundStyle(color)
        }
        return text.foregroundColor(color)
    }
}

/// One value line (value and unit as one piece) at the largest of a few sizes that fits the width: full
/// size whenever it fits, then 85 %, 72 % and 60 %, then 50 % cut at the end. The line keeps the full
/// size's height at every rung, so a long value never makes its readout, cell or tile shorter.
///
/// An explicit ladder rather than `minimumScaleFactor`: on a value and unit concatenated into one `Text`,
/// that modifier jumps straight to its minimum as soon as the text does not fit at full size.
struct FittingValueLine: View {
    let value: String
    let unit: String?
    let color: Color
    /// The value's font at a scale (1 is full size).
    let valueFont: (CGFloat) -> Font
    let unitFont: (CGFloat) -> Font
    var tracking: (CGFloat) -> CGFloat = { _ in 0 }

    var body: some View {
        ZStack(alignment: .leading) {
            Text(verbatim: " ").font(valueFont(1)).hidden().accessibilityHidden(true)
            ViewThatFits(in: .horizontal) {
                line(1).fixedSize(horizontal: true, vertical: false)
                line(0.85).fixedSize(horizontal: true, vertical: false)
                line(0.72).fixedSize(horizontal: true, vertical: false)
                line(0.6).fixedSize(horizontal: true, vertical: false)
                line(0.5)
            }
        }
    }

    private func line(_ scale: CGFloat) -> some View {
        ValueUnitText.make(value, font: valueFont(scale), color: color, tracking: tracking(scale),
                           unit: unit, unitFont: unitFont(scale))
            .lineLimit(1)
    }
}

// MARK: - ValueReadout
//
// The pinned header above a detail chart. It shows the latest value, or the value under the finger while
// the chart is scrubbed, so it is also the chart's tooltip: there is no floating bubble over the marks.
// Its height never changes (every line is reserved and single-line), which is what lets a scrub run
// without the page below it moving.

/// What a `ValueReadout` shows. Screens build it from their own values; nothing here computes a metric.
public struct ReadoutContent: Equatable, Sendable {
    /// When the value is from: "Tue 7 Oct", "Week of 29 Sep", "Sep 2026", "Last night". See `dateLine(_:period:)`.
    public var dateLine: String
    /// The formatted number. `nil` (or empty) shows "—" with no unit.
    public var value: String?
    /// "ms", "bpm", "%", "h", "°C". Drawn beside the value, never inside the value string.
    public var unit: String?
    /// One line of context: "7-day avg 61 ms", "+4 bpm vs typical", "3 readings".
    public var context: String?
    /// Only for a score drawn in its band colour; everything else is `textPrimary`.
    public var valueColor: Color?
    /// Adds an "Estimate" pill after the value.
    public var isEstimate: Bool

    public init(dateLine: String, value: String?, unit: String?, context: String? = nil,
                valueColor: Color? = nil, isEstimate: Bool = false) {
        self.dateLine = dateLine
        self.value = value
        self.unit = unit
        self.context = context
        self.valueColor = valueColor
        self.isEstimate = isEstimate
    }

    // MARK: Display rules (pure, tested)

    /// The value as drawn: "—" when there is none.
    public var displayValue: String {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "—" }
        return value
    }

    /// The unit as drawn: only beside a real value, so a missing reading is a bare "—".
    public var displayUnit: String? {
        guard displayValue != "—", let unit, !unit.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return unit
    }

    /// The single VoiceOver string: "Tue 7 Oct, 62 ms, 7-day avg 61 ms, estimate".
    public var accessibilityText: String {
        var parts: [String] = []
        if !dateLine.isEmpty { parts.append(dateLine) }
        if let unit = displayUnit {
            parts.append("\(displayValue) \(unit)")
        } else {
            parts.append(displayValue == "—" ? String(localized: "No value", bundle: .module) : displayValue)
        }
        if let context, !context.isEmpty { parts.append(context) }
        if isEstimate { parts.append(String(localized: "estimate", bundle: .module)) }
        return parts.joined(separator: ", ")
    }

    // MARK: Date lines

    /// The period a readout value covers, which decides how its date line reads.
    public enum Period: Sendable {
        /// One day: "Tue 7 Oct" (the year is added outside the current year).
        case day
        /// One night, given its wake day: "Mon 6 – Tue 7 Oct".
        case night
        /// A week, given any day in it: "Week of 29 Sep" (the week starts on the calendar's first weekday).
        case week
        /// A month: "Sep 2026".
        case month
        /// An instant inside a day (an intraday scrub): "Tue 7 Oct, 14:05" in the locale's clock.
        case time
    }

    /// The readout's date line for `date`. Locale-driven, so en_GB reads "Tue 7 Oct" and en_US "Tue, Oct 7".
    /// `now` decides whether the year is needed and is injectable for tests.
    public static func dateLine(_ date: Date, period: Period, now: Date = Date(),
                                calendar: Calendar = .current, locale: Locale = .current) -> String {
        let base = Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
        let needsYear = !calendar.isDate(date, equalTo: now, toGranularity: .year)
        let dayStyle = needsYear ? base.weekday(.abbreviated).day().month(.abbreviated).year()
                                 : base.weekday(.abbreviated).day().month(.abbreviated)
        switch period {
        case .day:
            return date.formatted(dayStyle)
        case .time:
            return date.formatted(dayStyle.hour().minute())
        case .month:
            return date.formatted(base.month(.abbreviated).year())
        case .week:
            let start = calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
            let startStyle = needsYear ? base.day().month(.abbreviated).year() : base.day().month(.abbreviated)
            let formatted = start.formatted(startStyle)
            return String(localized: "Week of \(formatted)", bundle: .module)
        case .night:
            let wake = calendar.startOfDay(for: date)
            let bed = calendar.date(byAdding: .day, value: -1, to: wake) ?? wake
            var interval = Date.IntervalFormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
                .weekday(.abbreviated).day().month(.abbreviated)
            if needsYear { interval = interval.year() }
            return (bed..<wake).formatted(interval)
        }
    }
}

/// The pinned header above a detail chart: a date line (footnote, `textSecondary`), the hero value
/// (`display(40)`) with its unit (`title2`, `textSecondary`), and one context line (subhead).
///
/// ```swift
/// ValueReadout(ReadoutContent(dateLine: ReadoutContent.dateLine(day, period: .night),
///                             value: fmt(hrv), unit: "ms", context: "7-day avg 61 ms"),
///              isScrubbing: selection != nil, isLoading: !loaded)
/// ```
///
/// Fixed height (`NoopMetrics.readoutHeight` at the default text size; every instance grows by the same
/// amount with Dynamic Type). Each line is single-line and scales down rather than wrapping, the context
/// line is reserved even when empty, and values swap without animation, so scrubbing never moves the
/// page. The readout is one VoiceOver element and is marked as updating frequently while scrubbing.
/// `isLoading` renders the same frame redacted.
public struct ValueReadout: View {
    private let content: ReadoutContent
    private let isScrubbing: Bool
    private let isLoading: Bool

    public init(_ content: ReadoutContent, isScrubbing: Bool = false, isLoading: Bool = false) {
        self.content = content
        self.isScrubbing = isScrubbing
        self.isLoading = isLoading
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text(lineText(content.dateLine, placeholder: LoadingText.shortLine))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                FittingValueLine(value: isLoading ? LoadingText.value : content.displayValue,
                                 unit: isLoading ? content.unit : content.displayUnit,
                                 color: content.valueColor ?? StrandPalette.textPrimary,
                                 valueFont: { StrandFont.display(40 * $0) },
                                 unitFont: { $0 == 1 ? StrandFont.title2
                                                     : StrandFont.scaled(20 * $0, weight: .semibold, relativeTo: .title3) },
                                 tracking: { StrandFont.displayTracking(40 * $0) })
                if content.isEstimate && !isLoading {
                    StatePill("Estimate", tone: .neutral, showsDot: false)
                        .fixedSize()
                        .layoutPriority(1)
                }
            }
            // Reserved when empty, so a readout with a context line is not taller than one without.
            Text(lineText(content.context ?? "", placeholder: LoadingText.line))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.readoutHeight, alignment: .topLeading)
        .redacted(reason: isLoading ? .placeholder : [])
        // A scrub may run inside someone else's animation transaction; the numbers must not tween.
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(isLoading ? String(localized: "Loading", bundle: .module) : content.accessibilityText))
        .accessibilityAddTraits(isScrubbing ? .updatesFrequently : [])
    }

    /// A line's text: the placeholder while loading, a space when empty (keeps the line's height).
    private func lineText(_ text: String, placeholder: String) -> String {
        if isLoading { return placeholder }
        return text.isEmpty ? " " : text
    }
}

#if DEBUG
private struct ValueReadoutPreview: View {
    @State private var scrubbed = false
    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            ValueReadout(scrubbed
                ? ReadoutContent(dateLine: "Thu 2 Oct", value: "54", unit: "ms", context: "−8 ms vs typical")
                : ReadoutContent(dateLine: "Last night", value: "62", unit: "ms", context: "7-day avg 61 ms"),
                isScrubbing: scrubbed)
            ValueReadout(ReadoutContent(dateLine: "Tue 7 Oct", value: "41", unit: "%",
                                        valueColor: StrandPalette.recoveryColor(41)))
            ValueReadout(ReadoutContent(dateLine: "Week of 29 Sep", value: "9,412", unit: "steps",
                                        context: "Daily average", isEstimate: true))
            ValueReadout(ReadoutContent(dateLine: "Tue 7 Oct", value: nil, unit: "ms", context: "No reading"))
            ValueReadout(ReadoutContent(dateLine: "", value: nil, unit: "ms"), isLoading: true)
            Toggle("Scrubbing", isOn: $scrubbed).font(StrandFont.subhead)
        }
        .padding(NoopMetrics.screenHPadding)
        .frame(width: 390)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("ValueReadout — light") {
    ValueReadoutPreview().preferredColorScheme(.light)
}

#Preview("ValueReadout — dark") {
    ValueReadoutPreview().preferredColorScheme(.dark)
}
#endif

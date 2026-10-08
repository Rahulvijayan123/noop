import SwiftUI
import StrandDesign

// MetricInsightCard.swift — the server's explanation of a key metric (`MetricInsightStore`), under the value and the
// chart on `KeyMetricDetailView`. Optional by design: every state that has no explanation says so in one quiet
// line, and nothing here can hold up the rest of the screen.

/// The card's fixed copy, in one place so the wording checks can read every string it may show. A night metric's
/// card speaks of nights, a day metric's of days (`MetricInsightPeriod`).
enum MetricInsightCopy {
    static var title: String { String(localized: "Explanation") }
    static func preparing(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Looking at your recent nights…")
        case .day: return String(localized: "Looking at your recent days…")
        }
    }
    static func notEnoughData(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Not enough measured nights yet")
        case .day: return String(localized: "Not enough measured days yet")
        }
    }
    static var unavailable: String { String(localized: "Explanation unavailable right now") }
    static func signedOut(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Sign in to see an explanation of your recent nights.")
        case .day: return String(localized: "Sign in to see an explanation of your recent days.")
        }
    }
    static var updating: String { String(localized: "Updating…") }
    static var earlier: String { String(localized: "Earlier explanation") }
    // The three section labels, in plain words for patients: what was observed, the likely interpretation, and the
    // uncertainty.
    static var observed: String { String(localized: "What we noticed") }
    static var interpretation: String { String(localized: "What may be behind it") }
    static var uncertainty: String { String(localized: "What we can't tell yet") }
    static var related: String { String(localized: "Related signals") }
    static var estimated: String { String(localized: "Estimated") }
    static var sources: String { String(localized: "Sources") }
    static func writtenBy(_ period: MetricInsightPeriod) -> String {
        switch period {
        case .night: return String(localized: "Written by AI from your measured nights.")
        case .day: return String(localized: "Written by AI from your measured days.")
        }
    }

    /// "Based on 38 nights through Oct 6, 2026" (or days, by the insight's period), from what the insight carries;
    /// nil when it carries neither.
    static func basis(_ insight: MetricInsight, locale: Locale = AppLanguage.activeLocale) -> String? {
        let count = insight.basis?.nights
        let through = (insight.dataThrough ?? insight.basis?.to).flatMap { KeyMetricDates.day($0, locale: locale) }
        switch (insight.period, count, through) {
        case (.night, 1?, let through?): return String(localized: "Based on 1 night through \(through)")
        case (.night, let n?, let through?): return String(localized: "Based on \(n) nights through \(through)")
        case (.night, nil, let through?): return String(localized: "Based on nights through \(through)")
        case (.night, 1?, nil): return String(localized: "Based on 1 night")
        case (.night, let n?, nil): return String(localized: "Based on \(n) nights")
        case (.day, 1?, let through?): return String(localized: "Based on 1 day through \(through)")
        case (.day, let n?, let through?): return String(localized: "Based on \(n) days through \(through)")
        case (.day, nil, let through?): return String(localized: "Based on days through \(through)")
        case (.day, 1?, nil): return String(localized: "Based on 1 day")
        case (.day, let n?, nil): return String(localized: "Based on \(n) days")
        case (_, nil, nil): return nil
        }
    }

    /// "Generated Oct 6, 7:12 AM": the day and time the explanation was written, in the reader's locale and time
    /// zone, without the year. Nil when the server's timestamp could not be read.
    ///
    /// The day and the time are formatted separately and joined by the localizable string: one combined
    /// month-day-hour-minute style reads "Oct 6 at 7:12 AM" in current English data.
    static func generated(_ insight: MetricInsight, locale: Locale = AppLanguage.activeLocale,
                          timeZone: TimeZone = .autoupdatingCurrent) -> String? {
        guard let date = insight.generatedAt else { return nil }
        let day = date.formatted(Date.FormatStyle(locale: locale, timeZone: timeZone).month(.abbreviated).day())
        let time = date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, locale: locale, timeZone: timeZone))
        return String(localized: "Generated \(day), \(time)")
    }

    /// The footer, one line each: what the explanation covered, then when it was written.
    static func footerLines(_ insight: MetricInsight, locale: Locale = AppLanguage.activeLocale,
                            timeZone: TimeZone = .autoupdatingCurrent) -> [String] {
        [basis(insight, locale: locale), generated(insight, locale: locale, timeZone: timeZone)].compactMap { $0 }
    }

    /// The whole citation, "Title (2020)", for VoiceOver (the card truncates the title on screen).
    static func citation(_ c: MetricInsight.Citation) -> String {
        c.year.map { "\(c.title) (\($0))" } ?? c.title
    }

    /// Every fixed string above, for both periods (for the copy checks).
    static var allFixedText: [String] {
        [title, unavailable, updating, earlier, observed, interpretation, uncertainty, related, estimated, sources]
            + MetricInsightPeriod.allCases.flatMap { [preparing($0), notEnoughData($0), signedOut($0), writtenBy($0)] }
    }
}

/// The marker on an explanation the card shows that is not current.
enum MetricInsightMarker: Equatable, Sendable {
    /// A newer analysis is being prepared: "Updating…".
    case updating
    /// The explanation describes earlier nights (or days) and nothing newer is on its way right now: "Earlier
    /// explanation".
    case earlier
}

extension MetricInsightStore.State {
    /// The marker for the shown explanation given the phone's latest measured night or day
    /// (`isCurrent(latestMeasuredDay:)`); nil when there is no explanation or it is current.
    func marker(latestMeasuredDay: String?) -> MetricInsightMarker? {
        guard insight != nil, !isCurrent(latestMeasuredDay: latestMeasuredDay) else { return nil }
        return phase == .pending || phase == .loading ? .updating : .earlier
    }
}

/// Renders one `MetricInsightStore.State`. The screen owns the request (its `.task`) and hides the card entirely in
/// local-only mode (`.hidden`).
struct MetricInsightCard: View {
    /// Nil before the first request has started: shown as the quiet placeholder.
    let state: MetricInsightStore.State?
    var tint: Color? = nil
    /// The latest night or day the screen's own series has measured (`yyyy-MM-dd`). An explanation through an earlier
    /// day is marked as not current.
    var latestMeasuredDay: String? = nil
    /// The screen metric's period, for the lines shown while there is no explanation to read one from. A shown
    /// explanation speaks of its own period (`MetricInsight.period`).
    var period: MetricInsightPeriod = .night

    /// The period the card speaks of.
    private var shownPeriod: MetricInsightPeriod { state?.insight?.period ?? period }

    var body: some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                header
                if let insight = state?.insight {
                    if let message = statusLine { status(message) }
                    explanation(insight)
                    notes(insight)
                } else if let message = statusLine {
                    status(message)
                } else {
                    placeholder
                }
            }
        }
    }

    // MARK: States

    /// The one quiet line for a state with nothing (or nothing current) to show; nil while preparing or ready.
    private var statusLine: String? {
        switch state?.phase {
        case .notEnoughData?: return MetricInsightCopy.notEnoughData(shownPeriod)
        case .unavailable?: return MetricInsightCopy.unavailable
        case .signedOut?: return MetricInsightCopy.signedOut(shownPeriod)
        case nil, .loading?, .pending?, .ready?, .hidden?: return nil
        }
    }

    /// "Updating…" while a newer analysis is prepared over the one shown; "Earlier explanation" when the one shown is
    /// not current (stale, or older than the phone's latest measured night) and nothing newer is coming.
    @ViewBuilder
    private var marker: some View {
        switch state?.marker(latestMeasuredDay: latestMeasuredDay) {
        case .updating?:
            StatePill("\(MetricInsightCopy.updating)", tone: .accent, pulsing: true)
        case .earlier?:
            StatePill("\(MetricInsightCopy.earlier)", tone: .neutral, showsDot: false)
        case nil:
            EmptyView()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            Text(MetricInsightCopy.title).strandOverline()
            Spacer(minLength: NoopMetrics.space2)
            marker
        }
    }

    private func status(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A quiet skeleton while the first explanation is prepared.
    private var placeholder: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack(spacing: NoopMetrics.space2) {
                ProgressView().controlSize(.small)
                Text(MetricInsightCopy.preparing(shownPeriod))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            ForEach([0.92, 0.78, 0.6], id: \.self) { fraction in
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(StrandPalette.surfaceInset)
                        .frame(width: geo.size.width * fraction)
                }
                .frame(height: 10)
            }
            .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Explanation

    private func explanation(_ insight: MetricInsight) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            // The card's most prominent text on both platforms: `title2` is 20 pt on iOS and 15 pt on macOS, above
            // the 14 pt sentences (InsightCard's headline token).
            Text(insight.headline)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            section(MetricInsightCopy.observed, insight.observed)
            section(MetricInsightCopy.interpretation, insight.interpretation)
            section(MetricInsightCopy.uncertainty, insight.uncertainty)
            if !insight.related.isEmpty { related(insight.related) }
            if !insight.citations.isEmpty { sources(insight.citations) }
        }
    }

    /// A section label in the hero's overline style ("Latest measured night", "Latest full day").
    private func label(_ text: String) -> some View {
        Text(text)
            .strandOverline()
            .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder
    private func section(_ title: String, _ sentences: [String]) -> some View {
        if !sentences.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                label(title)
                ForEach(Array(sentences.enumerated()), id: \.offset) { _, sentence in
                    Text(sentence)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func related(_ items: [MetricInsight.Related]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            label(MetricInsightCopy.related)
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Group {
                        if let symbol = Self.symbol(item.direction) {
                            Image(systemName: symbol)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        } else {
                            Color.clear
                        }
                    }
                    .frame(width: 14)
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: NoopMetrics.space2) {
                            Text(item.label)
                                .font(StrandFont.subhead)
                                .fontWeight(.medium)
                                .foregroundStyle(StrandPalette.textPrimary)
                            if item.estimated {
                                StatePill("\(MetricInsightCopy.estimated)", tone: .warning, showsDot: false)
                            }
                        }
                        Text(item.summary)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .accessibilityElement(children: .combine)
            }
        }
    }

    private func sources(_ citations: [MetricInsight.Citation]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            label(MetricInsightCopy.sources)
            ForEach(Array(citations.enumerated()), id: \.offset) { _, citation in
                if let url = citation.url {
                    Link(destination: url) { citationLabel(citation, color: StrandPalette.accent) }
                        .accessibilityLabel(Text(MetricInsightCopy.citation(citation)))
                } else {
                    citationLabel(citation, color: StrandPalette.textSecondary)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(Text(MetricInsightCopy.citation(citation)))
                }
            }
        }
    }

    /// The title on at most two lines, cut at the tail, with the year kept visible after it; leading-aligned across
    /// the card's width (a macOS `Link` would otherwise centre a wrapped label like a button title).
    private func citationLabel(_ citation: MetricInsight.Citation, color: Color) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 4) {
            Text(citation.title)
                .lineLimit(2)
                .truncationMode(.tail)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            if let year = citation.year {
                Text(verbatim: "(\(year))")
                    .fixedSize()
            }
        }
        .font(StrandFont.footnote)
        .foregroundStyle(color)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }

    /// What the explanation covered and when it was written (a line each), then where it came from.
    private func notes(_ insight: MetricInsight) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            ForEach(MetricInsightCopy.footerLines(insight), id: \.self) { Text($0) }
            Text(MetricInsightCopy.writtenBy(insight.period))
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textTertiary)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// A neutral direction glyph (never coloured good or bad); none when the direction is unknown.
    private static func symbol(_ direction: MetricInsight.Direction) -> String? {
        switch direction {
        case .up: return "arrow.up.right"
        case .down: return "arrow.down.right"
        case .flat: return "arrow.right"
        case .unknown: return nil
        }
    }
}

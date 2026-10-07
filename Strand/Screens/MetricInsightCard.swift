import SwiftUI
import StrandDesign

// MetricInsightCard.swift — the server's explanation of a key metric (`MetricInsightStore`), under the value and the
// chart on `KeyMetricDetailView`. Optional by design: every state that has no explanation says so in one quiet
// line, and nothing here can hold up the rest of the screen.

/// The card's fixed copy, in one place so the wording checks can read every string it may show.
enum MetricInsightCopy {
    static var title: String { String(localized: "Explanation") }
    static var preparing: String { String(localized: "Looking at your recent nights…") }
    static var notEnoughData: String { String(localized: "Not enough measured nights yet") }
    static var unavailable: String { String(localized: "Explanation unavailable right now") }
    static var signedOut: String { String(localized: "Sign in to see an explanation of your recent nights.") }
    static var updating: String { String(localized: "Updating…") }
    static var earlier: String { String(localized: "Earlier explanation") }
    static var observed: String { String(localized: "Observed") }
    static var interpretation: String { String(localized: "Interpretation") }
    static var uncertainty: String { String(localized: "Uncertainty") }
    static var related: String { String(localized: "Related signals") }
    static var estimated: String { String(localized: "Estimated") }
    static var sources: String { String(localized: "Sources") }
    static var writtenBy: String { String(localized: "Written by AI from your measured nights.") }
    static var notAdvice: String { String(localized: "Informational only, not medical advice.") }

    /// "Based on 28 nights through 6 Oct 2026 · Generated 7 Oct 2026, 02:43", from what the insight carries.
    static func footer(_ insight: MetricInsight, locale: Locale = AppLanguage.activeLocale) -> String? {
        var parts: [String] = []
        let nights = insight.basis?.nights
        let through = (insight.dataThrough ?? insight.basis?.to).flatMap { KeyMetricDates.day($0, locale: locale) }
        switch (nights, through) {
        case (1?, let through?): parts.append(String(localized: "Based on 1 night through \(through)"))
        case (let n?, let through?): parts.append(String(localized: "Based on \(n) nights through \(through)"))
        case (nil, let through?): parts.append(String(localized: "Based on nights through \(through)"))
        case (1?, nil): parts.append(String(localized: "Based on 1 night"))
        case (let n?, nil): parts.append(String(localized: "Based on \(n) nights"))
        case (nil, nil): break
        }
        if let generated = insight.generatedAt {
            let when = generated.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
            parts.append(String(localized: "Generated \(when)"))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func citation(_ c: MetricInsight.Citation) -> String {
        c.year.map { "\(c.title) (\($0))" } ?? c.title
    }

    /// Every fixed string above (for the copy checks).
    static var allFixedText: [String] {
        [title, preparing, notEnoughData, unavailable, signedOut, updating, earlier, observed, interpretation,
         uncertainty, related, estimated, sources, writtenBy, notAdvice]
    }
}

/// Renders one `MetricInsightStore.State`. The screen owns the request (its `.task`) and hides the card entirely in
/// local-only mode (`.hidden`).
struct MetricInsightCard: View {
    /// Nil before the first request has started: shown as the quiet placeholder.
    let state: MetricInsightStore.State?
    var tint: Color? = nil

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
        case .notEnoughData?: return MetricInsightCopy.notEnoughData
        case .unavailable?: return MetricInsightCopy.unavailable
        case .signedOut?: return MetricInsightCopy.signedOut
        case nil, .loading?, .pending?, .ready?, .hidden?: return nil
        }
    }

    /// "Updating…" while a newer analysis is prepared over the one shown; "Earlier explanation" when the one shown is
    /// not current and nothing newer is coming.
    @ViewBuilder
    private var marker: some View {
        if let state, state.insight != nil, !state.insightIsCurrent {
            if state.phase == .pending || state.phase == .loading {
                StatePill("\(MetricInsightCopy.updating)", tone: .accent, pulsing: true)
            } else {
                StatePill("\(MetricInsightCopy.earlier)", tone: .neutral, showsDot: false)
            }
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
                Text(MetricInsightCopy.preparing)
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
            Text(insight.headline)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            section(MetricInsightCopy.observed, insight.observed)
            section(MetricInsightCopy.interpretation, insight.interpretation)
            section(MetricInsightCopy.uncertainty, insight.uncertainty)
            if !insight.related.isEmpty { related(insight.related) }
            if !insight.citations.isEmpty { sources(insight.citations) }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.caption)
            .fontWeight(.semibold)
            .foregroundStyle(StrandPalette.textSecondary)
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
                let text = MetricInsightCopy.citation(citation)
                Group {
                    if let url = citation.url {
                        Link(destination: url) {
                            Text(text).foregroundStyle(StrandPalette.accent)
                        }
                    } else {
                        Text(text).foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .font(StrandFont.footnote)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// What the explanation covered and when it was written, then where it came from.
    private func notes(_ insight: MetricInsight) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            if let footer = MetricInsightCopy.footer(insight) { Text(footer) }
            Text(MetricInsightCopy.writtenBy)
            Text(MetricInsightCopy.notAdvice)
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

import SwiftUI
import StrandDesign
import StrandAnalytics

// MeasurementContextCard.swift — the concise context summary under the hero on the HRV and resting heart rate
// pages (spec §16, contracts.md §9).
//
// It describes ONE measurement of the page's day: the nightly snapshot value when the server contextualized one,
// else the most recent qualifying window. It says when the measurement was taken, what state it was taken in,
// whether it qualifies for the comparison that applies and why not, how much of its activity is known, and how
// it differs from the reference that was used. Everything else lives in the detail sheet.
//
// Hidden entirely in local-only mode. Every other state has explicit copy: signed out, an older server, nothing
// for the day, context still being prepared, and context built from an earlier result ("Context updating").

// MARK: - View model

struct MeasurementContextSummary: Equatable {
    let envelopeId: String?
    let statePhrase: String
    let supportText: String?
    let eligibilityText: String?
    let coverageText: String?
    let referenceText: String?
    let episodeText: String?
    let episodeBadges: [ContextBadge]
    let badges: [ContextBadge]
    let note: String?

    /// Every string the card would show (for the copy checks).
    var allText: [String] {
        [statePhrase, supportText, eligibilityText, coverageText, referenceText, episodeText, note]
            .compactMap { $0 } + badges.map(\.text) + episodeBadges.map(\.text)
    }

    static func build(day: PhysiologyContextDay, metric: PhysiologyContext.MetricKind,
                      locale: Locale = .current) -> MeasurementContextSummary {
        let processing = PhysiologyContextWording.processingBadges(mode: day.effectiveMode,
                                                                   finality: day.effectiveFinality,
                                                                   unverified: false)
        guard let document = day.document,
              let e = MeasurementContextSelection.headline(in: document.envelopes, metric: metric) else {
            let name = PhysiologyContextWording.metric(metric)
            return MeasurementContextSummary(
                envelopeId: nil, statePhrase: String(localized: "Insufficient context"), supportText: nil,
                eligibilityText: String(localized: "No \(name) measurement for this day has context yet."),
                coverageText: nil, referenceText: nil, episodeText: nil, episodeBadges: [], badges: processing,
                note: nil)
        }
        let kind = MeasurementContextSelection.selectedComparison(for: e)
        // The measurement's own comparison when it has one. A 5-minute window that fed today's stable-awake
        // median has none (the engine attaches a comparison only to the envelope that is its value); the day's
        // comparison is then shown as the median's, never as the window's own difference.
        let own = MeasurementContextSelection.headlineReference(e.comparisons)
        let dayMedian = own == nil
            ? MeasurementContextSelection.headlineReference(
                MeasurementContextSelection.dayStableAwakeComparisons(for: e, in: document.comparisons))
            : nil
        let reference = own ?? dayMedian
        let episode = MeasurementContextSelection.episode(for: e, reference: reference, episodes: document.episodes)
        let referenceText: String
        if let own {
            referenceText = PhysiologyContextWording.referenceLine(own, units: e.method.units, locale: locale)
        } else if let dayMedian {
            referenceText = PhysiologyContextWording.stableAwakeMedianLine(dayMedian, units: e.method.units,
                                                                           locale: locale)
        } else {
            referenceText = String(localized: "No reference comparison for this measurement yet")
        }
        let unverified = e.validity.state == .unverified
        return MeasurementContextSummary(
            envelopeId: e.id,
            statePhrase: PhysiologyContextWording.statePhrase(e),
            supportText: PhysiologyContextWording.supportLine(e, locale: locale),
            eligibilityText: PhysiologyContextWording.eligibilityLine(e.verdict(kind), kind: kind),
            coverageText: PhysiologyContextWording.coverageLine(e, locale: locale),
            referenceText: referenceText,
            episodeText: episode.map { PhysiologyContextWording.episodeState($0) },
            episodeBadges: episode.map(PhysiologyContextWording.episodeBadges) ?? [],
            badges: PhysiologyContextWording.processingBadges(mode: day.effectiveMode,
                                                              finality: e.finality, unverified: unverified),
            note: nil)
    }

    /// Context built from an earlier scoring result. Nothing from it is paired with the value on the page. After
    /// the card's last re-read it says to check back later instead of promising the update.
    static func stale(checkBackLater: Bool = false) -> MeasurementContextSummary {
        MeasurementContextSummary(
            envelopeId: nil, statePhrase: String(localized: "Context updating"), supportText: nil,
            eligibilityText: nil, coverageText: nil, referenceText: nil, episodeText: nil, episodeBadges: [],
            badges: [], note: checkBackLater ? MeasurementContextCopy.staleCheckBackLaterNote
                                             : MeasurementContextCopy.staleNote)
    }
}

/// The card's copy for every state that is not a summary.
enum MeasurementContextCopy {
    static var title: String { String(localized: "Measurement context") }
    static var loading: String { String(localized: "Loading measurement context\u{2026}") }
    static var staleNote: String {
        String(localized: "This day's results changed after its context was built. Updated context is on its way.")
    }
    static var staleCheckBackLaterNote: String {
        String(localized: "This day's results changed after its context was built. The update is taking longer than usual. Check back later.")
    }
    static var checkBackLater: String { String(localized: "Check back later.") }
    static var refreshFailedNote: String { String(localized: "Couldn't refresh. Showing saved context.") }
    static var failed: String { String(localized: "Couldn't load measurement context.") }

    static func unavailable(_ reason: PhysiologyContextStore.UnavailableReason) -> String? {
        switch reason {
        case .cloudOff: return nil
        case .signedOut: return String(localized: "Sign in to see the context of this measurement.")
        case .accountNotReady:
            return String(localized: "Measurement context appears once your account finishes connecting.")
        case .unsupportedServer: return String(localized: "Measurement context isn't available from the server yet.")
        case .noData: return String(localized: "No measurement context for this day yet.")
        case .processingFailed: return String(localized: "Context unavailable for this day.")
        }
    }

    /// Pending copy; after the card's last re-read it adds "Check back later." rather than implying it is still
    /// watching.
    static func pending(_ reason: PhysiologyContextStore.PendingReason, checkBackLater: Bool = false) -> String {
        let text: String
        switch reason {
        case .computing: text = String(localized: "Measurement context for this day is being prepared.")
        case .deviceRegistration:
            text = String(localized: "Measurement context appears once this strap's data reaches your account.")
        }
        return checkBackLater ? text + " " + Self.checkBackLater : text
    }

    /// Every fixed string above (for the copy checks).
    static var allFixedText: [String] {
        [title, loading, staleNote, staleCheckBackLaterNote, checkBackLater, refreshFailedNote, failed]
            + [PhysiologyContextStore.UnavailableReason.signedOut, .accountNotReady, .unsupportedServer, .noData,
               .processingFailed].compactMap(unavailable)
            + [PhysiologyContextStore.PendingReason.computing, .deviceRegistration].flatMap {
                [pending($0), pending($0, checkBackLater: true)]
            }
    }
}

extension PhysiologyContextDay: Identifiable {
    /// One shown context: device, day, metric filter and revision.
    public var id: String { "\(deviceId)|\(day)|\(metric ?? "all")|\(contextRevision.map(String.init) ?? "-")" }
}

// MARK: - Card

struct MeasurementContextCard: View {
    let metric: PhysiologyContext.MetricKind
    /// The page's selected local day (`yyyy-MM-dd`).
    let day: String

    @ObservedObject private var store = PhysiologyContextStore.shared
    @State private var detailDay: PhysiologyContextDay?
    @State private var detailIsStale = false
    /// Set after the last scheduled re-read found the context still pending or updating.
    @State private var checkBackLater = false

    private var key: PhysiologyContextStore.Key { .init(day: day, metric: metric) }

    var body: some View {
        // Local-only mode: nothing at all, not even a placeholder.
        if CloudPushSettings.isEnabled, CloudPushSettings.isConfigured {
            content
                .task(id: "\(day)|\(metric.rawValue)|\(store.epoch)") { await run() }
                .sheet(item: $detailDay) { shown in
                    MeasurementContextDetailView(day: shown, metric: metric, isStale: detailIsStale)
                        .presentationDetents([.medium, .large])
                        .presentationDragIndicator(.visible)
                }
        }
    }

    /// Load, then re-read pending or updating context on a bounded backoff (`PhysiologyContextStore.pollDelaysS`,
    /// about 15 minutes) while the card is on screen; `.task` cancels it when the card disappears. When the
    /// schedule runs out and the context is still not current, the card says to check back later.
    private func run() async {
        checkBackLater = false
        await store.load(key)
        for delay in PhysiologyContextStore.pollDelaysS {
            guard !Task.isCancelled, store.state(for: key)?.wantsPolling == true else { return }
            try? await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await store.load(key)
        }
        if !Task.isCancelled, store.state(for: key)?.wantsPolling == true { checkBackLater = true }
    }

    @ViewBuilder
    private var content: some View {
        switch store.state(for: key) {
        case nil, .loading?:
            shell(badges: []) {
                HStack(spacing: NoopMetrics.space2) {
                    ProgressView().controlSize(.small)
                    message(MeasurementContextCopy.loading)
                }
            }
        case .unavailable(let reason)?:
            if let text = MeasurementContextCopy.unavailable(reason) {
                shell(badges: []) {
                    message(text)
                    if reason == .noData || reason == .processingFailed { actions(day: nil, stale: false) }
                }
            }
        case .pending(let shown, let reason)?:
            shell(badges: []) {
                message(MeasurementContextCopy.pending(reason, checkBackLater: checkBackLater))
                if let shown { actions(day: shown, stale: true) }
            }
        case .stale(let shown)?:
            summaryCard(MeasurementContextSummary.stale(checkBackLater: checkBackLater), day: shown, stale: true)
        case .available(let shown)?:
            summaryCard(MeasurementContextSummary.build(day: shown, metric: metric), day: shown, stale: false)
        case .failed(let cached, _)?:
            if let cached {
                let stale = PhysiologyContextStore.classify(cached) == .stale(cached)
                summaryCard(stale ? MeasurementContextSummary.stale() : MeasurementContextSummary.build(day: cached, metric: metric),
                            day: cached, stale: stale, extraNote: MeasurementContextCopy.refreshFailedNote)
            } else {
                shell(badges: []) {
                    message(MeasurementContextCopy.failed)
                    Button {
                        Task { await store.load(key) }
                    } label: {
                        Label("Try again", systemImage: "arrow.clockwise")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.accent)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func summaryCard(_ summary: MeasurementContextSummary, day shown: PhysiologyContextDay, stale: Bool,
                             extraNote: String? = nil) -> some View {
        shell(badges: summary.badges) {
            VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                Text(summary.statePhrase)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let support = summary.supportText {
                    Text(support)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            if let eligibility = summary.eligibilityText { line(eligibility) }
            if let coverage = summary.coverageText { line(coverage, tertiary: true) }
            if let reference = summary.referenceText {
                Text(reference)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let episode = summary.episodeText {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    line(episode)
                    if !summary.episodeBadges.isEmpty { badgeRow(summary.episodeBadges) }
                }
            }
            if let note = summary.note { line(note, tertiary: true) }
            if let extraNote { line(extraNote, tertiary: true) }
            actions(day: shown, stale: stale)
        }
    }

    /// "Details" (the sheet) and "History" (pushed onto the page's navigation stack).
    private func actions(day shown: PhysiologyContextDay?, stale: Bool) -> some View {
        HStack(spacing: NoopMetrics.space4) {
            if let shown {
                Button {
                    #if os(iOS)
                    StrandHaptic.selection.play()
                    #endif
                    detailIsStale = stale
                    detailDay = shown
                } label: {
                    Label("Details", systemImage: "info.circle")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityHint(Text("Shows how this measurement was taken"))
            }
            NavigationLink {
                PhysiologyContextHistoryView(metric: metric, endingAt: day,
                                             timezoneId: shown?.document?.timezoneId)
            } label: {
                Label("History", systemImage: "clock.arrow.circlepath")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
            }
            .buttonStyle(LiquidPressStyle())
            Spacer(minLength: 0)
        }
        .padding(.top, NoopMetrics.space1)
    }

    private func shell<Content: View>(badges: [ContextBadge], @ViewBuilder _ inner: @escaping () -> Content) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                HStack(alignment: .center, spacing: NoopMetrics.space2) {
                    Text(MeasurementContextCopy.title).strandOverline()
                    Spacer(minLength: NoopMetrics.space2)
                    badgeRow(badges)
                }
                inner()
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func line(_ text: String, tertiary: Bool = false) -> some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(tertiary ? StrandPalette.textTertiary : StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func badgeRow(_ badges: [ContextBadge]) -> some View {
        if !badges.isEmpty {
            HStack(spacing: NoopMetrics.space1) {
                ForEach(badges, id: \.self) { ContextBadgeView(badge: $0) }
            }
        }
    }
}

/// One badge as a dotless state pill.
struct ContextBadgeView: View {
    let badge: ContextBadge

    var body: some View {
        StatePill("\(badge.text)", tone: tone, showsDot: false)
    }

    private var tone: StrandTone {
        switch badge.tone {
        case .neutral: return .neutral
        case .accent: return .accent
        case .warning: return .warning
        }
    }
}

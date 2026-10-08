import SwiftUI
import StrandDesign
import StrandAnalytics

// PhysiologyContextHistoryView.swift — the last 30 to 90 days of change episodes and exertion bouts
// (`GET scores/context/history`), reached from the measurement context card and its detail (spec §16).
//
// Episodes are descriptive comparisons with the person's own earlier data: state, series, first and last day,
// whether still ongoing, and how final. Bouts show their kind, duration and whether the follow-up after them was
// observed to the end, is still going, or was cut short (and why).

// MARK: - View model

struct ContextHistoryEpisodeRow: Identifiable, Equatable {
    let id: String
    let title: String
    let state: String
    let dates: String
    let direction: String?
    let badges: [ContextBadge]
    let reasons: String?
}

struct ContextHistoryBoutRow: Identifiable, Equatable {
    let id: String
    let title: String
    let when: String
    let duration: String
    let status: String
    let ongoing: Bool
    /// Measured heart-rate response, when any was measured.
    let response: String?
    /// Breathing-rate return after the bout (spec-02 `recovery.respiratory_recovery`), when it was evaluated.
    var breathing: String? = nil
}

struct PhysiologyContextHistoryModel: Equatable {
    let metricEpisodes: [ContextHistoryEpisodeRow]
    let otherEpisodes: [ContextHistoryEpisodeRow]
    let bouts: [ContextHistoryBoutRow]

    var allText: [String] {
        (metricEpisodes + otherEpisodes).flatMap { [$0.title, $0.state, $0.dates, $0.direction, $0.reasons]
            .compactMap { $0 } + $0.badges.map(\.text) }
            + bouts.flatMap { [$0.title, $0.when, $0.duration, $0.status, $0.response, $0.breathing].compactMap { $0 } }
    }

    static func build(_ history: PhysiologyContextHistory, metric: PhysiologyContext.MetricKind, zone: TimeZone,
                      locale: Locale = .current) -> PhysiologyContextHistoryModel {
        typealias W = PhysiologyContextWording
        let episodes = history.episodes.sorted { ($0.lastDay, $0.id) > ($1.lastDay, $1.id) }.map { e in
            ContextHistoryEpisodeRow(
                id: e.id, title: W.series(e.seriesKey), state: W.episodeState(e),
                dates: dates(e, locale: locale), direction: W.direction(e.direction),
                badges: W.episodeBadges(e), reasons: W.reasonList(e.reasons))
        }
        let ownIds = Set(history.episodes.filter { MeasurementContextPage.belongs(seriesKey: $0.seriesKey, to: metric) }
            .map(\.id))
        let bouts = history.bouts.sorted { ($0.interval.start, $0.id) > ($1.interval.start, $1.id) }.map { b in
            ContextHistoryBoutRow(
                id: b.id, title: W.boutKind(b.kind),
                when: "\(W.dayAndTime(b.interval.start, zone: zone, locale: locale))\u{2013}\(W.time(b.interval.end, zone: zone, locale: locale))",
                duration: W.duration(b.durationS), status: W.boutStatus(b), ongoing: b.status == .ongoing,
                response: W.boutResponse(b, locale: locale),
                breathing: b.recovery?.respiratoryRecovery.map { W.respiratoryReturn($0, locale: locale) })
        }
        return PhysiologyContextHistoryModel(metricEpisodes: episodes.filter { ownIds.contains($0.id) },
                                             otherEpisodes: episodes.filter { !ownIds.contains($0.id) },
                                             bouts: bouts)
    }

    private static func dates(_ e: PhysiologyContext.ChangeEpisode, locale: Locale) -> String {
        typealias W = PhysiologyContextWording
        let span = e.startDay == e.lastDay ? W.day(e.startDay, locale: locale)
            : "\(W.day(e.startDay, locale: locale))\u{2013}\(W.day(e.lastDay, locale: locale))"
        let days = e.durationDays == 1 ? String(localized: "1 day") : String(localized: "\(e.durationDays) days")
        return "\(span) \u{00B7} \(days)"
    }
}

enum PhysiologyContextHistoryCopy {
    static var title: String { String(localized: "Context history") }
    static var loading: String { String(localized: "Loading history\u{2026}") }
    static var failed: String { String(localized: "Couldn't load history.") }
    static var pending: String { String(localized: "History appears once this strap's data reaches your account.") }
    static var noEpisodes: String { String(localized: "No changes recorded in this period.") }
    static var noBouts: String { String(localized: "No activity bouts in this period.") }
    static var refreshFailed: String { String(localized: "Couldn't refresh. Showing saved history.") }
    static var episodesFootnote: String {
        String(localized: "Episodes describe how values compare with your own earlier data under matching conditions.")
    }

    static func unavailable(_ reason: PhysiologyContextStore.UnavailableReason) -> String {
        switch reason {
        case .cloudOff: return String(localized: "Context history needs cloud sync.")
        case .signedOut: return String(localized: "Sign in to see context history.")
        case .accountNotReady: return String(localized: "Context history appears once your account finishes connecting.")
        case .unsupportedServer: return String(localized: "Context history isn't available from the server yet.")
        case .noData: return String(localized: "No context history yet.")
        case .processingFailed: return String(localized: "Context history is unavailable.")
        }
    }

    static var allFixedText: [String] {
        [title, loading, failed, pending, noEpisodes, noBouts, refreshFailed, episodesFootnote]
            + [PhysiologyContextStore.UnavailableReason.cloudOff, .signedOut, .accountNotReady, .unsupportedServer,
               .noData, .processingFailed].map(unavailable)
    }
}

// MARK: - View

struct PhysiologyContextHistoryView: View {
    let metric: PhysiologyContext.MetricKind
    /// The last local day of the range (the page's selected day).
    let endingAt: String
    /// The zone bout times are shown in (the day document's), else the phone's.
    let timezoneId: String?

    @ObservedObject private var store = PhysiologyContextStore.shared
    @State private var span = 30

    private static let spans = [30, 60, 90]

    private var key: PhysiologyContextStore.HistoryKey {
        .init(from: PhysiologyContextDates.key(endingAt, minusDays: span - 1) ?? endingAt, to: endingAt)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                Picker("Range", selection: $span) {
                    ForEach(Self.spans, id: \.self) { days in
                        Text("\(days) days").tag(days)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                content
            }
            .padding(NoopMetrics.screenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(StrandPalette.surfaceBase)
        .navigationTitle(PhysiologyContextHistoryCopy.title)
        .task(id: "\(key.from)|\(key.to)|\(store.epoch)") { await store.loadHistory(key) }
    }

    @ViewBuilder
    private var content: some View {
        switch store.historyState(for: key) {
        case nil, .loading?:
            HStack(spacing: NoopMetrics.space2) {
                ProgressView().controlSize(.small)
                message(PhysiologyContextHistoryCopy.loading)
            }
        case .unavailable(let reason)?:
            message(PhysiologyContextHistoryCopy.unavailable(reason))
        case .pending?:
            message(PhysiologyContextHistoryCopy.pending)
        case .loaded(let history)?:
            sections(history, note: nil)
        case .failed(let cached, _)?:
            if let cached {
                sections(cached, note: PhysiologyContextHistoryCopy.refreshFailed)
            } else {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    message(PhysiologyContextHistoryCopy.failed)
                    Button {
                        Task { await store.loadHistory(key) }
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

    @ViewBuilder
    private func sections(_ history: PhysiologyContextHistory, note: String?) -> some View {
        let model = PhysiologyContextHistoryModel.build(history, metric: metric,
                                                        zone: PhysiologyContextWording.zone(timezoneId))
        if let note { message(note) }
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Changes in \(PhysiologyContextWording.metric(metric))").strandOverline()
                if model.metricEpisodes.isEmpty {
                    message(PhysiologyContextHistoryCopy.noEpisodes)
                } else {
                    ForEach(model.metricEpisodes) { episodeRow($0) }
                }
                Text(PhysiologyContextHistoryCopy.episodesFootnote)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if !model.otherEpisodes.isEmpty {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    Text("Other series").strandOverline()
                    ForEach(model.otherEpisodes) { episodeRow($0) }
                }
            }
        }
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Activity bouts").strandOverline()
                if model.bouts.isEmpty {
                    message(PhysiologyContextHistoryCopy.noBouts)
                } else {
                    ForEach(model.bouts) { boutRow($0) }
                }
            }
        }
    }

    private func episodeRow(_ row: ContextHistoryEpisodeRow) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack(alignment: .firstTextBaseline) {
                Text(row.title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.space2)
                Text(row.dates)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(row.direction.map { "\(row.state) \u{00B7} \($0)" } ?? row.state)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !row.badges.isEmpty {
                HStack(spacing: NoopMetrics.space1) {
                    ForEach(row.badges, id: \.self) { ContextBadgeView(badge: $0) }
                }
            }
            if let reasons = row.reasons {
                Text(reasons)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func boutRow(_ row: ContextHistoryBoutRow) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(row.title), \(row.duration)")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: NoopMetrics.space2)
                Text(row.when)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(row.status)
                .font(StrandFont.footnote)
                .foregroundStyle(row.ongoing ? StrandPalette.accent : StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let response = row.response {
                Text(response)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let breathing = row.breathing {
                Text(breathing)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func message(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

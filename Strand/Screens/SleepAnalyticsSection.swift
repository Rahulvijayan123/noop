import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

// SleepAnalyticsSection.swift — the compact "Sleep details" area for the Phase-1 sleep analytics
// document (`daily.sleep_analytics_v1`, docs/sleep-analytics/spec.md §8 app steps 1–5).
//
// Fed by the hosted document decoded by `HostedDayResult` into the SHARED StrandAnalytics
// `SleepAnalyticsDocument`. SleepView renders this section inside the night-detail area ONLY when
// a document exists for the CURRENT night AND passes the staleness guard; with no payload, or with
// a stale pre-edit document, the section is absent entirely, so builds without the payload render
// exactly as before.
//
// Honesty rules the section (spec §8 app step 4):
//   • Every null renders as "Unavailable" with a SHORT human-readable reason mapped from the
//     machine reason enum + coverage context — never 0, never "excellent", never a clinical
//     alert, never a misleading full-night count.
//   • Partial totals are clearly marked "Observed/partial".
//   • No normative red/green cutoffs.
//   • All stage-derived text says "estimated".
//   • Seconds are converted to minutes at presentation only.
//
// Staleness (spec §8 app step 5): a document renders ONLY when its fragment fingerprint still
// matches the night on screen. A mismatch withholds the section and requests the existing
// invalidated hosted refresh (`ServerScoreRepository.refresh(day:deviceIds:)` — the same path the
// sleep-features section uses when its document is missing). Owner isolation stays with the
// per-owner server-score cache: a different owner's cached document is never read, so it can never
// render here.

// MARK: - Loader

/// Loads the hosted `daily.sleep_analytics_v1` for the night on screen from the server-score cache
/// and renders `SleepAnalyticsCards` when a document exists for the current night AND its fragment
/// fingerprint still matches that night; otherwise nothing.
///
/// Read path mirrors `SleepFeatureSection`: cache first (`repository.cachedDay`), then the existing
/// invalidated hosted refresh (`repository.refresh(day:deviceIds:)`). A document whose fragments no
/// longer match the current night is withheld and the same refresh is requested, so an
/// edited/delete/source-switch night never carries a stale analytics card.
struct SleepAnalyticsSection: View {
    let startTs: Int
    let endTs: Int
    /// The CURRENT displayed night's main-night group (the real stored blocks, with device
    /// lineage), used by the staleness guard.
    let currentSessions: [CachedSleepSession]

    @EnvironmentObject private var repo: Repository
    @State private var loaded: (document: SleepAnalyticsDocument, sessions: [CachedSleepSession])?

    var body: some View {
        // The 1-pt anchor is load-bearing: a `.task` on an empty view never fires, so with no
        // document yet nothing would ever load one (same pattern as SleepFeatureSection).
        ZStack(alignment: .top) {
            Color.clear.frame(height: 1)
            if let loaded {
                SleepAnalyticsCards(document: loaded.document, currentSessions: loaded.sessions)
            }
        }
        .task(id: "sleepAnalytics|\(startTs)|\(endTs)|\(repo.refreshSeq)") { await load() }
    }

    private func load() async {
        guard CloudPushIdentityStore.current() != nil,
              let repository = CloudPushRuntime.shared.scoreRepository() else { loaded = nil; return }
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(endTs)))
        let deviceIds = await IntradaySeriesStore.shared.readCandidates
        let sessions = currentSessions
        var document = repository.cachedDay(day: day, deviceIds: deviceIds)?.hostedResult?.sleepAnalytics
        if let doc = document, !SleepAnalyticsStaleness.isCurrent(document: doc, sessions: sessions) {
            // Stale (an edit/delete/source switch changed the night after the document was
            // computed): withhold and ask the existing invalidated hosted refresh path to re-fetch.
            document = nil
        }
        if document == nil {
            document = (try? await repository.refresh(day: day, deviceIds: deviceIds))?.hostedResult?.sleepAnalytics
        }
        guard !Task.isCancelled, let document,
              SleepAnalyticsStaleness.isCurrent(document: document, sessions: sessions) else { loaded = nil; return }
        loaded = (document, sessions)
    }
}

// MARK: - Staleness guard (spec §8 app step 5)

/// Staleness guard: a hosted document renders ONLY when its fragment fingerprint still matches the
/// night on screen. The app cannot recompute the document's SHA-256 fingerprint (that needs the
/// normalized input timeline), so it checks the equivalent invariants the fingerprint hashes:
/// every document fragment must correspond to a current-night session (id pattern
/// `sleep-<deviceId>-<start>`, effective bounds, edited lineage) and the document's effective
/// group bounds must align with the current group's bounds.
///
/// Known limit (review P3-5): an edit that only re-STAGES a night without moving its bounds (or a
/// second edit with identical bounds) is not detectable client-side — the session model carries no
/// edit revision to compare against the document's `edit_revision`. The guard therefore also relies
/// on the refresh path: an edited day re-dirties its score and the hosted refresh replaces the
/// document; until it arrives, the section shows the last matching document (bounded staleness).
enum SleepAnalyticsStaleness {

    /// One current-night fragment descriptor, derived from a stored sleep session.
    struct CurrentFragment: Equatable {
        /// The session's canonical detected start key (the `<start>` the wire id embeds).
        var canonicalStart: Int
        /// The device id the wire id embeds, when the read stamped one.
        var deviceId: String?
        /// Effective bounds (half-open unix seconds).
        var start: Int
        var end: Int
        var edited: Bool
    }

    /// Build the current night's fragment descriptors from the resolved main-night group.
    static func currentFragments(from sessions: [CachedSleepSession]) -> [CurrentFragment] {
        sessions
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
            .map {
                CurrentFragment(canonicalStart: $0.startTs, deviceId: $0.deviceId,
                                start: $0.effectiveStartTs, end: $0.endTs, edited: $0.userEdited)
            }
    }

    /// True when `document` describes the night currently on screen. False (withhold) means the
    /// section renders nothing and asks for a refresh.
    static func isCurrent(document: SleepAnalyticsDocument, sessions: [CachedSleepSession]) -> Bool {
        let current = currentFragments(from: sessions)
        guard !current.isEmpty else { return false }
        guard document.fragments.count == current.count else { return false }
        for fragment in document.fragments {
            guard let match = current.first(where: { $0.start == fragment.start }) else { return false }
            guard match.end == fragment.end,
                  match.edited == fragment.edited,
                  idMatches(fragment.id, match: match) else { return false }
        }
        guard let minStart = current.map(\.start).min(),
              let maxEnd = current.map(\.end).max() else { return false }
        return document.start == minStart && document.end == maxEnd
    }

    /// The wire id `sleep-<deviceId>-<start>` — or, when the session carried no device id, the
    /// numeric `<start>` suffix must still match the session's canonical or effective start key.
    private static func idMatches(_ id: String, match: CurrentFragment) -> Bool {
        if let device = match.deviceId {
            let canonical = "sleep-\(device)-\(match.canonicalStart)"
            let effective = "sleep-\(device)-\(match.start)"
            if id == canonical || id == effective { return true }
            // The device segment is known: a document from another device must never match, even
            // when it happens to carry the same start-key suffix.
            guard id.hasPrefix("sleep-\(device)-") else { return false }
        }
        guard let dash = id.lastIndex(of: "-") else { return false }
        let suffix = id[id.index(after: dash)...]
        guard let parsed = Int(suffix) else { return false }
        return parsed == match.canonicalStart || parsed == match.start
    }
}

// MARK: - Cards

/// The "Sleep analytics" section: a SectionHeader + one card whose primary rows show the six
/// headline metrics and whose expandable rows open the detail groups (deep latency, stage time &
/// bouts, transitions, temperature trend, pulse-interval diagnostics, coverage).
struct SleepAnalyticsCards: View {
    let model: SleepAnalyticsDisplayModel

    @State private var open: Set<String> = []

    init(document: SleepAnalyticsDocument, currentSessions: [CachedSleepSession]) {
        // All derived display strings are computed once here, never per-body (spec §12
        // "no SwiftUI-body analytics").
        model = SleepAnalyticsDisplayModel(document: document, sessions: currentSessions)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep analytics")

            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.rows) { row in
                        hairline
                        rowView(row)
                    }
                    ForEach(model.details) { group in
                        hairline
                        detailToggle(group)
                    }
                }
            }
        }
        // The night page stacks this above its About card with no gap of its own (the host renders nothing
        // until a document loads), so the section brings the page's section gap with it.
        .padding(.bottom, NoopMetrics.sectionGap)
        .accessibilityElement(children: .contain)
    }

    private var hairline: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1)
            .padding(.leading, NoopMetrics.cardPadding)
    }

    // MARK: Primary rows

    private func rowView(_ row: SleepAnalyticsDisplayModel.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let caption = row.caption {
                    Text(caption)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(row.value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
    }

    // MARK: Expandable detail

    private func detailToggle(_ group: SleepAnalyticsDisplayModel.DetailGroup) -> some View {
        let isOpen = open.contains(group.id)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(StrandMotion.interactive) {
                    if isOpen { open.remove(group.id) } else { open.insert(group.id) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: group.icon)
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(group.title)
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(group.summary)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(StrandFont.icon(.inline))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, NoopMetrics.cardPadding)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(group.accessibilityLabel)
            .accessibilityHint(isOpen ? "Collapse" : "Expand")

            if isOpen {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        detailRow(row.label, row.value)
                    }
                }
                .padding(.leading, NoopListDivider.iconRowInset)
                .padding(.trailing, NoopMetrics.cardPadding)
                .padding(.bottom, 14)
                .transition(.opacity)
            }
        }
    }

    @ViewBuilder private func detailRow(_ label: String, _ value: String) -> some View {
        // Detail rows render even when unavailable: "Unavailable — reason" is the honest reading,
        // never a hidden row and never a fabricated zero (spec §8 app step 4).
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label). \(value)")
    }
}

// MARK: - Display model (pure, precomputed once per document)

/// The pure, precomputed view data for `SleepAnalyticsCards`. Everything here is computed once in
/// `init(document:sessions:)` so the SwiftUI body stays a thin renderer.
struct SleepAnalyticsDisplayModel {
    struct Row: Identifiable, Equatable {
        let id: String
        let title: String
        let value: String
        let caption: String?
        let accessibilityLabel: String
    }

    /// One label/value pair inside an expandable detail group.
    struct DetailRow: Equatable {
        let label: String
        let value: String
        init(_ label: String, _ value: String) {
            self.label = label
            self.value = value
        }
    }

    struct DetailGroup: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: String
        let summary: String
        let rows: [DetailRow]
        let accessibilityLabel: String
    }

    let rows: [Row]
    let details: [DetailGroup]

    init(document: SleepAnalyticsDocument, sessions: [CachedSleepSession]) {
        let continuity = document.continuity
        let dynamics = document.stageDynamics
        let movement = document.movement
        let thermal = document.thermal
        let prv = document.prvDiagnostics

        var rows: [Row] = []
        var details: [DetailGroup] = []

        // ── Primary rows (spec §8 app step 3) ────────────────────────────────
        rows.append(Self.wakeAfterOnsetRow(continuity))
        rows.append(Self.longestStretchRow(continuity))
        rows.append(Self.awakeningsRow(continuity))
        rows.append(Self.remLatencyRow(continuity))
        rows.append(Self.movementRow(movement))
        rows.append(Self.temperatureSpreadRow(thermal))

        // ── Expandable detail ────────────────────────────────────────────────
        details.append(Self.stageTimingDetail(continuity))
        details.append(Self.stageBoutsDetail(dynamics))
        details.append(Self.transitionsDetail(dynamics))
        details.append(Self.thermalTrendDetail(thermal))
        details.append(Self.prvDetail(prv))
        // Spec-02 groups (docs/spec-02/CONTRACT.md §4.3–4.4): shown only when the document carries them, so an
        // older document renders exactly as before (absent ≠ unavailable; nothing is invented for it).
        if let morning = document.morningResponse {
            details.append(Self.morningResponseDetail(morning, timezone: document.timezone))
        }
        if let stageMovement = movement.stageMovement {
            details.append(Self.stageMovementDetail(stageMovement, note: movement.stageMovementNote))
        }
        details.append(Self.coverageDetail(document))

        self.rows = rows
        self.details = details
    }

    // MARK: One metric's display decision (the state-decision functions tests pin)

    struct MetricDisplay: Equatable {
        var text: String
        var note: String?
        var partial: Bool = false
        var unavailable: Bool = false
        var disabled: Bool = false
    }

    /// Decide how one real-valued metric renders: available/partial values show their formatted
    /// number; unavailable/disabled show "Unavailable"/"Disabled" plus the reason wording and
    /// coverage. A value-less available/partial wrapper (tolerant decode) is treated as
    /// unavailable — never a fabricated zero.
    static func display(_ metric: SleepAnalyticsMetric,
                        format: (Double) -> String,
                        coverage: String?) -> MetricDisplay {
        switch metric.status {
        case .available, .partial:
            if let value = metric.value {
                return MetricDisplay(text: format(value),
                                     note: note(forPartial: metric.status == .partial, coverage: coverage),
                                     partial: metric.status == .partial)
            }
            return unavailable(reason: metric.reason, disabled: false, coverage: coverage)
        case .unavailable, .disabled:
            return unavailable(reason: metric.reason, disabled: metric.status == .disabled, coverage: coverage)
        }
    }

    /// Decide how one integer metric renders (bout/transition/window counts). A genuine zero with
    /// qualifying exposure renders "0" — never null.
    static func display(_ count: SleepAnalyticsCount, coverage: String?) -> MetricDisplay {
        switch count.status {
        case .available, .partial:
            if let value = count.value {
                return MetricDisplay(text: "\(value)",
                                     note: note(forPartial: count.status == .partial, coverage: coverage),
                                     partial: count.status == .partial)
            }
            return unavailable(reason: count.reason, disabled: count.status == .disabled, coverage: coverage)
        case .unavailable, .disabled:
            return unavailable(reason: count.reason, disabled: count.status == .disabled, coverage: coverage)
        }
    }

    static func unavailable(reason: SleepAnalyticsReason?, disabled: Bool, coverage: String?) -> MetricDisplay {
        let reasonNote = reason.map(SleepAnalyticsWording.reason)
        let note = [reasonNote, coverage].compactMap { $0 }.joined(separator: " · ")
        return MetricDisplay(text: disabled ? "Disabled" : "Unavailable",
                             note: note.isEmpty ? nil : note,
                             unavailable: !disabled, disabled: disabled)
    }

    private static func note(forPartial partial: Bool, coverage: String?) -> String? {
        if partial {
            return ["Observed/partial", coverage].compactMap { $0 }.joined(separator: " · ")
        }
        return coverage
    }

    /// Coverage context from a group's quality block: "95% label-supported · 93% input-supported".
    static func coverage(_ quality: SleepAnalyticsQuality) -> String? {
        var parts: [String] = []
        if let label = quality.labelSupportedFraction {
            parts.append("\(SleepAnalyticsFormat.fractionPercent(label)) label-supported")
        }
        if let input = quality.inputSupportedFraction {
            parts.append("\(SleepAnalyticsFormat.fractionPercent(input)) input-supported")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func isUnavailable(_ text: String) -> Bool {
        text == "Unavailable" || text == "Disabled"
    }

    // MARK: Primary row builders

    static func wakeAfterOnsetRow(_ continuity: SleepAnalyticsContinuityGroup) -> Row {
        let cov = coverage(continuity.quality)
        let observed = display(continuity.observedWasoSeconds, format: SleepAnalyticsFormat.minutes, coverage: cov)
        let gapSeconds = continuity.inferredGapAwakeSecondsWithinSleepPeriod
        let gapValue: Double? = (gapSeconds.status == .available || gapSeconds.status == .partial)
            ? gapSeconds.value : nil
        let hasGap = (gapValue ?? 0) > 0
        let estimated = display(continuity.estimatedWasoIncludingInferredGapsSeconds,
                                format: SleepAnalyticsFormat.minutes, coverage: nil)

        let value: String
        var caption: String?
        if !isUnavailable(observed.text) {
            value = observed.text
            var parts: [String] = []
            if observed.partial { parts.append("Observed/partial") }
            if hasGap {
                parts.append("incl. \(SleepAnalyticsFormat.minutes(gapValue)) inferred from a split-night gap")
                if !isUnavailable(estimated.text) {
                    parts.append("est. total \(estimated.text)")
                }
            } else if !observed.partial, let cov { parts.append(cov) }
            caption = parts.isEmpty ? nil : parts.joined(separator: " · ")
        } else if !isUnavailable(estimated.text) {
            value = estimated.text
            var parts: [String] = []
            if estimated.partial { parts.append("Observed/partial") }
            parts.append("estimate includes any split-night gap")
            caption = parts.joined(separator: " · ")
        } else {
            value = observed.text
            caption = observed.note
        }
        return Row(id: "waso", title: "Est. wake after onset", value: value, caption: caption,
                   accessibilityLabel: Self.label("Est. wake after onset", value: value, caption: caption))
    }

    static func longestStretchRow(_ continuity: SleepAnalyticsContinuityGroup) -> Row {
        let cov = coverage(continuity.quality)
        let m = display(continuity.longestObservedSleepBoutSeconds,
                        format: SleepAnalyticsFormat.minutes, coverage: cov)
        var caption = m.note
        if continuity.longestBoutCensored == true {
            caption = [caption, "may be cut short by a gap"].compactMap { $0 }.joined(separator: " · ")
        }
        return Row(id: "longestStretch", title: "Longest sleep stretch", value: m.text, caption: caption,
                   accessibilityLabel: Self.label("Longest sleep stretch", value: m.text, caption: caption))
    }

    static func awakeningsRow(_ continuity: SleepAnalyticsContinuityGroup) -> Row {
        let cov = coverage(continuity.quality)
        let m = display(continuity.awakeningBoutCount, coverage: cov)
        var caption: String?
        if isUnavailable(m.text) {
            caption = m.note
        } else {
            var parts: [String] = []
            if m.partial { parts.append("Observed/partial") }
            parts.append("complete awakenings · label-level estimate")
            caption = parts.joined(separator: " · ")
        }
        return Row(id: "awakenings", title: "Est. awakenings", value: m.text, caption: caption,
                   accessibilityLabel: Self.label("Est. awakenings", value: m.text, caption: caption))
    }

    static func remLatencyRow(_ continuity: SleepAnalyticsContinuityGroup) -> Row {
        let cov = coverage(continuity.quality)
        let m = display(continuity.remLatencyFromSleepOnsetSeconds,
                        format: SleepAnalyticsFormat.minutes, coverage: cov)
        var caption: String?
        if isUnavailable(m.text) {
            caption = m.note
        } else {
            var parts: [String] = []
            if m.partial { parts.append("Observed/partial") }
            parts.append("from sleep onset · estimated")
            caption = parts.joined(separator: " · ")
        }
        return Row(id: "remLatency", title: "REM latency", value: m.text, caption: caption,
                   accessibilityLabel: Self.label("REM latency", value: m.text, caption: caption))
    }

    static func movementRow(_ movement: SleepAnalyticsMovementGroup) -> Row {
        let cov = coverage(movement.quality)
        let pct = display(movement.movementPercentage,
                          format: { SleepAnalyticsFormat.percentValue($0) }, coverage: cov)
        let bouts = display(movement.movementBoutCount, coverage: nil)

        let value: String
        if !isUnavailable(pct.text) && !isUnavailable(bouts.text) {
            value = "\(pct.text) · \(bouts.text) bouts"
        } else if !isUnavailable(pct.text) {
            value = pct.text
        } else if !isUnavailable(bouts.text) {
            value = "\(bouts.text) bouts"
        } else {
            value = pct.text
        }
        var caption: String?
        if isUnavailable(pct.text) && isUnavailable(bouts.text) {
            caption = [pct.note, bouts.note].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        } else {
            var parts: [String] = []
            if pct.partial || bouts.partial { parts.append("Observed/partial") }
            parts.append("wrist movement · device-specific estimate")
            if !isUnavailable(pct.text), let cov { parts.append(cov) }
            caption = parts.joined(separator: " · ")
        }
        return Row(id: "movement", title: "Movement", value: value, caption: caption,
                   accessibilityLabel: Self.label("Movement", value: value, caption: caption))
    }

    static func temperatureSpreadRow(_ thermal: SleepAnalyticsThermalGroup) -> Row {
        let cov = coverage(thermal.quality)
        let p95 = display(thermal.nightP95MinusP05C, format: SleepAnalyticsFormat.magnitude, coverage: cov)
        let iqr = display(thermal.nightIqrC, format: SleepAnalyticsFormat.magnitude, coverage: nil)

        let value: String
        var caption: String?
        if !isUnavailable(p95.text) {
            value = p95.text
            var parts: [String] = []
            if p95.partial { parts.append("Observed/partial") }
            parts.append("95th−5th percentile of nightly wrist temp (approx.)")
            caption = parts.joined(separator: " · ")
        } else if !isUnavailable(iqr.text) {
            value = iqr.text
            var parts: [String] = []
            if iqr.partial { parts.append("Observed/partial") }
            parts.append("middle 50% of nightly wrist temp (approx.)")
            caption = parts.joined(separator: " · ")
        } else {
            value = p95.text
            caption = [p95.note, iqr.note].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
        return Row(id: "tempSpread", title: "Temp. spread (approx.)", value: value, caption: caption,
                   accessibilityLabel: Self.label("Approximate temperature spread", value: value, caption: caption))
    }

    private static func label(_ title: String, value: String, caption: String?) -> String {
        caption.map { "\(title). \(value). \($0)" } ?? "\(title). \(value)"
    }

    // MARK: Detail group builders

    static func stageTimingDetail(_ continuity: SleepAnalyticsContinuityGroup) -> DetailGroup {
        let cov = coverage(continuity.quality)
        let deep = display(continuity.deepLatencyFromSleepOnsetSeconds,
                           format: SleepAnalyticsFormat.minutes, coverage: cov)
        let onset = display(continuity.onsetDelayFromWindowSeconds,
                            format: SleepAnalyticsFormat.minutes, coverage: cov)
        var summaryParts: [String] = []
        if !isUnavailable(deep.text) { summaryParts.append("Deep first at \(deep.text)") }
        if !isUnavailable(onset.text) { summaryParts.append("asleep by \(onset.text)") }
        let summary = summaryParts.isEmpty
            ? "Deep latency · onset delay"
            : summaryParts.joined(separator: " · ")
        return DetailGroup(id: "stageTiming", title: "Stage timing", icon: "hourglass",
                           summary: summary,
                           rows: [
                            DetailRow("Deep sleep first at", deep.text + "\(deep.note.map { " · \($0)" } ?? "")"),
                            DetailRow("Asleep by", onset.text + "\(onset.note.map { " · \($0)" } ?? "")"),
                           ],
                           accessibilityLabel: "Stage timing. \(summary)")
    }

    static func stageBoutsDetail(_ dynamics: SleepAnalyticsStageDynamicsGroup) -> DetailGroup {
        let cov = coverage(dynamics.quality)
        let order: [SleepAnalyticsLabel] = [.light, .deep, .rem, .wake]
        var rows: [DetailRow] = []
        var summaryParts: [String] = []
        for label in order {
            let seconds = dynamics.stageSeconds.first { $0.label == label }?.seconds
            let m = seconds.map { display($0, format: SleepAnalyticsFormat.minutes, coverage: cov) }
            let bout = dynamics.stageBouts.first { $0.label == label }?.medianCompleteBoutSeconds
            let boutText = bout.map { display($0, format: SleepAnalyticsFormat.minutes, coverage: nil) }
            let title = Self.stageTitle(label)
            var value: String
            var note: String?
            if let m, !isUnavailable(m.text) {
                value = m.text
                note = m.note
                if let boutText, !isUnavailable(boutText.text) {
                    value += " · median bout \(boutText.text)"
                }
                summaryParts.append("\(title) \(m.text)")
            } else if let m {
                value = m.text
                note = m.note
            } else {
                value = "Unavailable"
                note = "not reported"
            }
            rows.append(DetailRow("\(title) (est.)", value + "\(note.map { " · \($0)" } ?? "")"))
        }
        let summary = summaryParts.isEmpty ? "Stage time & bout medians" : summaryParts.joined(separator: " · ")
        return DetailGroup(id: "stageBouts", title: "Stage time & bouts", icon: "square.stack.3d.up",
                           summary: summary, rows: rows,
                           accessibilityLabel: "Stage time and bout medians, estimated. \(summary)")
    }

    static func transitionsDetail(_ dynamics: SleepAnalyticsStageDynamicsGroup) -> DetailGroup {
        guard let matrix = dynamics.epochTransitions else {
            return DetailGroup(id: "transitions", title: "Stage transitions", icon: "arrow.triangle.swap",
                               summary: "Not supported for this sleep source",
                               rows: [DetailRow("Stage transitions", "Not supported for this sleep source")],
                               accessibilityLabel: "Stage transitions. Not supported for this sleep source.")
        }
        let pairs = display(matrix.eligiblePairCount, coverage: nil)
        let changes = display(matrix.stageChangeCount, coverage: nil)
        var summaryParts: [String] = []
        if !isUnavailable(pairs.text) { summaryParts.append("\(pairs.text) eligible pairs") }
        if !isUnavailable(changes.text) { summaryParts.append("\(changes.text) stage changes") }
        let summary = summaryParts.isEmpty ? "Adjacent estimated-stage changes" : summaryParts.joined(separator: " · ")
        // Rows are origin [wake, light, deep, rem]; cols destination in the same order.
        let counts = matrix.counts
        guard counts.count == 4, counts.allSatisfy({ $0.count == 4 }) else {
            return DetailGroup(id: "transitions", title: "Stage transitions", icon: "arrow.triangle.swap",
                               summary: summary, rows: [DetailRow("Stage transitions", "Not available")],
                               accessibilityLabel: "Stage transitions. \(summary)")
        }
        let wakeToSleep = counts[0][1] + counts[0][2] + counts[0][3]
        let sleepToWake = counts[1][0] + counts[2][0] + counts[3][0]
        var rows: [DetailRow] = [
            DetailRow("Wake → sleep", "\(wakeToSleep)"),
            DetailRow("Sleep → wake", "\(sleepToWake)"),
            DetailRow("Eligible pairs", pairs.text + "\(pairs.note.map { " · \($0)" } ?? "")"),
            DetailRow("Stage changes", changes.text + "\(changes.note.map { " · \($0)" } ?? "")"),
        ]
        if let observed = matrix.observedBoutChangeCount, let v = observed.value {
            rows.append(DetailRow("Observed bout changes (source resolution)", "\(v)"))
        }
        return DetailGroup(id: "transitions", title: "Stage transitions", icon: "arrow.triangle.swap",
                           summary: summary, rows: rows,
                           accessibilityLabel: "Stage transitions, estimated. \(summary). \(wakeToSleep) wake to sleep. \(sleepToWake) sleep to wake.")
    }

    static func thermalTrendDetail(_ thermal: SleepAnalyticsThermalGroup) -> DetailGroup {
        func slopeText(_ slope: SleepAnalyticsSlope?) -> String {
            guard let slope else { return "Unavailable" }
            let m = display(slope.value, format: SleepAnalyticsFormat.temperaturePerHour, coverage: nil)
            if isUnavailable(m.text) { return m.text + "\(m.note.map { " · \($0)" } ?? "")" }
            var text = m.text
            if slope.eligibleMinutes > 0 {
                text += " over \(slope.validMinutes) of \(slope.eligibleMinutes) min"
            }
            return text + "\(m.note.map { " · \($0)" } ?? "")"
        }
        let pre = slopeText(thermal.preOnsetSlopeCPerHour)
        let post = slopeText(thermal.postWakeSlopeCPerHour)
        let summaryParts = [pre, post].filter { !isUnavailable($0) && !$0.hasPrefix("Unavailable") }
        let summary = summaryParts.isEmpty ? "Temperature trend before/after sleep"
            : "Before onset \(pre) · after window end \(post)"
        // Spec-02 §4.2: the pre-onset slope fits [onset − 60 min, onset); the post-wake slope fits
        // [estimated window end, + 30 min) — labelled after the estimated window END, never "after waking".
        return DetailGroup(id: "thermalTrend", title: "Temperature trend", icon: "thermometer.medium",
                           summary: summary,
                           rows: [
                            DetailRow("Hour before sleep onset", pre),
                            DetailRow("30 min after estimated window end", post),
                           ],
                           accessibilityLabel: "Temperature trend. Hour before sleep onset \(pre). Thirty minutes after the estimated end of the sleep window \(post).")
    }

    static func prvDetail(_ prv: SleepAnalyticsPrvDiagnosticsGroup) -> DetailGroup {
        let cov = coverage(prv.quality)
        let sd1 = display(prv.nightlySd1Ms, format: { SleepAnalyticsFormat.value($0, unit: "ms") }, coverage: cov)
        let sd2 = display(prv.nightlySd2Ms, format: { SleepAnalyticsFormat.value($0, unit: "ms") }, coverage: cov)
        let ratio = display(prv.nightlyRatio, format: { String(format: "%.2f", $0) }, coverage: nil)
        let windows = display(prv.eligibleWindowCount, coverage: nil)
        let withheld = display(prv.withheldWindowCount, coverage: nil)
        let rejected = display(prv.rejectionFraction,
                               format: { SleepAnalyticsFormat.fractionPercent($0) }, coverage: nil)

        // pNN50 (spec-02 §4.1): shown only when the document carries it (an older document has no key).
        let pnn50 = prv.nightlyPnn50Pct.map { Self.pnn50Display($0, prv: prv) }

        var summaryParts: [String] = []
        if !isUnavailable(sd1.text) { summaryParts.append("SD1 \(sd1.text)") }
        if !isUnavailable(sd2.text) { summaryParts.append("SD2 \(sd2.text)") }
        if let pnn50, !isUnavailable(pnn50.text) { summaryParts.append("pNN50 \(pnn50.text)") }
        let summary = summaryParts.isEmpty ? "Pulse-interval variation (PRV)"
            : summaryParts.joined(separator: " · ") + " · related to HRV"

        let disabled = prv.quality.status == .disabled
        if disabled {
            return DetailGroup(id: "prv", title: "Pulse-interval diagnostics", icon: "waveform.path.ecg",
                               summary: "Disabled — pulse diagnostics are off",
                               rows: [DetailRow("Pulse-interval diagnostics", "Disabled — pulse diagnostics are off")],
                               accessibilityLabel: "Pulse-interval diagnostics. Disabled. Pulse diagnostics are off.")
        }

        var rows: [DetailRow] = [
            DetailRow("SD1 (ms)", sd1.text + "\(sd1.note.map { " · \($0)" } ?? "")"),
            DetailRow("SD2 (ms)", sd2.text + "\(sd2.note.map { " · \($0)" } ?? "")"),
            DetailRow("Ratio SD1/SD2", ratio.text),
            DetailRow("Eligible windows", windows.text + "\(!isUnavailable(withheld.text) ? " · \(withheld.text) withheld" : "")"),
            DetailRow("Rejected beats", rejected.text),
        ]
        if let pnn50 {
            rows.append(DetailRow("pNN50 (optical PRV)", pnn50.text + "\(pnn50.note.map { " · \($0)" } ?? "")"))
            rows.append(DetailRow("Source", "Optical pulse intervals (pulse-rate variability), not ECG"))
            if let method = prv.pnn50Method { rows.append(DetailRow("pNN50 definition", method)) }
        }
        return DetailGroup(id: "prv", title: "Pulse-interval diagnostics", icon: "waveform.path.ecg",
                           summary: summary, rows: rows,
                           accessibilityLabel: "Pulse-interval diagnostics, related to heart-rate variability, not ECG-equivalent. \(summary).")
    }

    /// pNN50 with its denominator: "12.4%" and "1,190 of 9,600 adjacent pairs differ by > 50 ms". The value is
    /// the pooled proportion the producer persisted (never re-derived here); the pairs are the SD1/SD2 pairs.
    static func pnn50Display(_ metric: SleepAnalyticsMetric, prv: SleepAnalyticsPrvDiagnosticsGroup) -> MetricDisplay {
        var shown = display(metric, format: SleepAnalyticsFormat.percentOneDecimal, coverage: nil)
        guard !isUnavailable(shown.text) else { return shown }
        var parts: [String] = []
        if shown.partial { parts.append("Observed/partial") }
        if let pairs = prv.pnn50PairCount?.value {
            if let nn50 = prv.nn50Count?.value {
                parts.append("\(SleepAnalyticsFormat.count(nn50)) of \(SleepAnalyticsFormat.count(pairs)) adjacent pairs differ by > 50 ms")
            } else {
                parts.append("of \(SleepAnalyticsFormat.count(pairs)) adjacent pairs")
            }
        }
        shown.note = parts.isEmpty ? nil : parts.joined(separator: " · ")
        return shown
    }

    /// One signal of the morning response: "54 → 63 bpm (+9 bpm)" with its OWN coverage, or why not.
    static func morningSignalText(_ w: SleepAnalyticsSignalWindow) -> String {
        let unit = w.unit
        let fmt: (Double) -> String = { SleepAnalyticsFormat.signalValue($0, unit: unit) }
        let before = display(w.beforeMedian, format: fmt, coverage: nil)
        let after = display(w.afterMedian, format: fmt, coverage: nil)
        let change = display(w.change, format: { SleepAnalyticsFormat.signedSignalValue($0, unit: unit) }, coverage: nil)
        let coverage = "before \(w.beforeValidMinutes) of \(w.eligibleMinutesEachSide) min · after \(w.afterValidMinutes) of \(w.eligibleMinutesEachSide) min valid"
        var text: String
        if !isUnavailable(before.text) && !isUnavailable(after.text) {
            text = "\(before.text) → \(after.text)"
            if !isUnavailable(change.text) { text += " (\(change.text))" }
            if before.partial || after.partial || change.partial { text += " · Observed/partial" }
        } else {
            // A side without enough valid minutes: never a fabricated median.
            let reason = (w.change.reason ?? w.beforeMedian.reason ?? w.afterMedian.reason)
                .map(SleepAnalyticsWording.morningReason)
            text = ["Unavailable", reason].compactMap { $0 }.joined(separator: " · ")
        }
        return "\(text) · \(coverage)"
    }

    /// HR / skin-temperature / movement around the ESTIMATED end of the sleep window (spec-02 §4.3). A response
    /// around a detected boundary, never proof of waking physiology; each signal keeps its own coverage.
    static func morningResponseDetail(_ m: SleepAnalyticsMorningResponseGroup, timezone: String?) -> DetailGroup {
        let hr = morningSignalText(m.heartRate)
        let temp = morningSignalText(m.skinTemperature)
        let move = morningSignalText(m.movement)
        let disclaimer = "A response around the estimated end of the sleep window, not proof of how waking feels or works"
        var summaryParts: [String] = []
        if !hr.hasPrefix("Unavailable") { summaryParts.append("HR \(hr.components(separatedBy: " · ").first ?? hr)") }
        if !temp.hasPrefix("Unavailable") { summaryParts.append("temp \(temp.components(separatedBy: " · ").first ?? temp)") }
        let summary: String
        switch m.quality.status {
        case .unavailable, .disabled:
            summary = "Unavailable · not enough data around the estimated window end"
        case .available, .partial:
            summary = summaryParts.isEmpty ? "Heart rate, temperature and movement around the estimated window end"
                : summaryParts.joined(separator: " · ")
        }
        var rows: [DetailRow] = [
            DetailRow("Heart rate, 30 min before → after", hr),
            DetailRow("Skin temperature, 30 min before → after", temp),
            DetailRow("Movement, 30 min before → after", move),
        ]
        if let ts = m.anchorTs {
            rows.append(DetailRow("Anchored at", "Estimated end of the sleep window, \(SleepAnalyticsFormat.clock(ts, timezone: timezone))"))
        } else {
            rows.append(DetailRow("Anchored at", "Estimated end of the sleep window"))
        }
        rows.append(DetailRow("About this", disclaimer))
        rows.append(DetailRow("Definition", m.algorithmVersion))
        return DetailGroup(id: "morningResponse", title: "Around the end of the sleep window",
                           icon: "sunrise", summary: summary, rows: rows,
                           accessibilityLabel: "Heart rate, skin temperature and movement around the estimated end of the sleep window. \(summary). \(disclaimer).")
    }

    /// Movement inside each estimated stage (spec-02 §4.4). Unknown stays unknown, and the stager reads wrist
    /// movement itself, so the association is partly built in — always said.
    static func stageMovementDetail(_ stages: [SleepAnalyticsStageMovement], note: String?) -> DetailGroup {
        let order: [SleepAnalyticsLabel] = [.wake, .light, .deep, .rem, .unknown]
        var rows: [DetailRow] = []
        var summaryParts: [String] = []
        for label in order {
            guard let s = stages.first(where: { $0.label == label }) else { continue }
            let pct = display(s.movementPercentage, format: { SleepAnalyticsFormat.percentValue($0) }, coverage: nil)
            let eligible = display(s.eligibleSeconds, format: SleepAnalyticsFormat.minutes, coverage: nil)
            let rate = display(s.movementBoutsPerEligibleHour,
                               format: { String(format: "%.1f bouts/h", $0) }, coverage: nil)
            let title = label == .unknown ? "Unknown stage" : "\(stageTitle(label)) (est.)"
            var value: String
            if !isUnavailable(pct.text) {
                value = pct.text
                if !isUnavailable(eligible.text) { value += " of \(eligible.text) moving" }
                if !isUnavailable(rate.text) {
                    value += " · \(rate.text)" + (rate.partial ? " (short exposure)" : "")
                }
                if pct.partial { value += " · Observed/partial" }
                if label != .unknown { summaryParts.append("\(stageTitle(label)) \(pct.text)") }
            } else {
                value = pct.text + "\(pct.note.map { " · \($0)" } ?? "")"
            }
            rows.append(DetailRow(title, value))
        }
        let disclosure = SleepAnalyticsWording.stageMovementNote(note)
        rows.append(DetailRow("Note", disclosure))
        let summary = summaryParts.isEmpty ? "Wrist movement inside each estimated stage" : summaryParts.joined(separator: " · ")
        return DetailGroup(id: "stageMovement", title: "Movement by estimated stage", icon: "figure.walk.motion",
                           summary: summary, rows: rows,
                           accessibilityLabel: "Movement by estimated stage. \(summary). \(disclosure).")
    }

    static func coverageDetail(_ document: SleepAnalyticsDocument) -> DetailGroup {
        func line(_ name: String, _ quality: SleepAnalyticsQuality) -> DetailRow {
            var parts: [String] = []
            if let label = quality.labelSupportedFraction {
                parts.append("\(SleepAnalyticsFormat.fractionPercent(label)) label-supported")
            }
            if let input = quality.inputSupportedFraction {
                parts.append("\(SleepAnalyticsFormat.fractionPercent(input)) input-supported")
            }
            let value = parts.isEmpty ? Self.statusText(quality.status) : parts.joined(separator: " · ")
            return DetailRow(name, value)
        }
        let rows: [DetailRow] = [
            line("Continuity", document.continuity.quality),
            line("Stage dynamics", document.stageDynamics.quality),
            line("Movement", document.movement.quality),
            line("Temperature", document.thermal.quality),
            line("Pulse diagnostics", document.prvDiagnostics.quality),
        ]
        return DetailGroup(id: "coverage", title: "Coverage", icon: "scope",
                           summary: "How much of the night each group could observe",
                           rows: rows,
                           accessibilityLabel: "Coverage per group.")
    }

    static func statusText(_ status: SleepAnalyticsStatus) -> String {
        switch status {
        case .available: return "Available"
        case .partial: return "Partial"
        case .unavailable: return "Unavailable"
        case .disabled: return "Disabled"
        }
    }

    private static func stageTitle(_ label: SleepAnalyticsLabel) -> String {
        switch label {
        case .light: return "Light"
        case .deep: return "Deep"
        case .rem: return "REM"
        case .wake: return "Wake"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Reason wording (spec §8 closed vocabulary)

/// Short, human-readable wording for each machine reason. Every null renders as "Unavailable" plus
/// one of these lines (plus coverage context) — never 0, never a clinical verdict.
enum SleepAnalyticsWording {
    static func reason(_ reason: SleepAnalyticsReason) -> String {
        switch reason {
        case .insufficientCoverage: return "not enough supported sleep time"
        case .insufficientDuration: return "sleep window too short"
        case .unsupportedSource: return "not supported for this sleep source"
        case .missingMarker: return "no sleep marker for this night"
        case .invalidMarker: return "sleep marker did not validate"
        case .onsetNotObserved: return "sleep onset was not observed"
        case .noObservedSleep: return "no sleep observed"
        case .noObservedRem: return "no REM observed"
        case .noObservedDeep: return "no deep sleep observed"
        case .insufficientBouts: return "not enough sleep bouts"
        case .unresolvedAdjacency: return "beat timing could not be resolved"
        case .unreliableBeats: return "beat quality too low"
        case .zeroDenominator: return "not enough data to compare"
        case .sourceMismatch: return "data source changed"
        case .staleEdit: return "outdated after an edit"
        case .computationFailed: return "could not be computed"
        case .noSamples: return "no data recorded"
        }
    }

    /// A morning-response side's reason: "insufficient coverage" there means too few valid minutes around the
    /// boundary, not too little sleep.
    static func morningReason(_ reason: SleepAnalyticsReason) -> String {
        switch reason {
        case .insufficientCoverage: return "too few valid minutes on one side"
        case .noSamples: return "no readings around the window end"
        default: return self.reason(reason)
        }
    }

    /// The disclosure carried with stage-associated movement (`stage_movement_note`). The stager reads wrist
    /// movement, so a stage–movement association is partly built in; any note reads as that disclosure.
    static func stageMovementNote(_ note: String?) -> String {
        "Stages are estimated partly from wrist movement, so movement and stage are not independent"
    }
}

// MARK: - Formatting helpers (presentation only)

/// Number formatting for the sleep analytics cards. Honesty rule: a nil value formats as
/// "Unavailable" — never a fabricated 0. Minutes convert seconds at presentation only.
enum SleepAnalyticsFormat {
    static let unavailable = "Unavailable"

    /// "42 min" / "3 h 25 m" from seconds (spec §8 app step 4).
    static func minutes(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return unavailable }
        let totalMinutes = Int((seconds / 60).rounded())
        if totalMinutes <= 0 { return "<1 min" }
        if totalMinutes < 60 { return "\(totalMinutes) min" }
        return "\(totalMinutes / 60) h \(String(format: "%02d", totalMinutes % 60)) m"
    }

    /// "+1.2 °C" / "−0.4 °C" (signed — slopes and deltas).
    static func temperature(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return unavailable }
        let sign = celsius < 0 ? "−" : "+"
        return "\(sign)\(String(format: "%.1f", abs(celsius))) °C"
    }

    /// "0.3 °C/h" for a slope (sign kept).
    static func temperaturePerHour(_ celsiusPerHour: Double?) -> String {
        guard let celsiusPerHour, celsiusPerHour.isFinite else { return unavailable }
        return "\(temperature(celsiusPerHour))/h"
    }

    /// A magnitude with no forced sign: "1.2 °C" for spreads.
    static func magnitude(_ celsius: Double?) -> String {
        guard let celsius, celsius.isFinite else { return unavailable }
        return "\(String(format: "%.1f", abs(celsius))) °C"
    }

    /// An already-percent number: 4.2 → "4%".
    static func percentValue(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unavailable }
        return String(format: "%.0f%%", value)
    }

    /// A fraction 0…1: 0.95 → "95%".
    static func fractionPercent(_ fraction: Double?) -> String {
        guard let fraction, fraction.isFinite else { return unavailable }
        return String(format: "%.0f%%", fraction * 100)
    }

    /// A value with a unit suffix: 61.4, "ms" → "61.4 ms".
    static func value(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return unavailable }
        return "\(String(format: "%.1f", value)) \(unit)"
    }

    /// An already-percent number with one decimal: 12.43 → "12.4%" (pNN50).
    static func percentOneDecimal(_ value: Double?) -> String {
        guard let value, value.isFinite else { return unavailable }
        return String(format: "%.1f%%", value)
    }

    /// A grouped integer count: 9600 → "9,600".
    static func count(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// Decimals a morning-response unit is shown with (bpm whole, °C two places, s/min one place).
    static func signalDecimals(_ unit: String) -> Int {
        switch unit {
        case "bpm": return 0
        case "°C", "c", "C": return 2
        default: return 1
        }
    }

    static func signalUnit(_ unit: String) -> String {
        unit == "c" || unit == "C" ? "°C" : unit
    }

    /// "54 bpm" / "33.12 °C" / "1.5 s/min".
    static func signalValue(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return unavailable }
        return "\(String(format: "%.\(signalDecimals(unit))f", value)) \(signalUnit(unit))"
    }

    /// Signed: "+9 bpm" / "−0.42 °C".
    static func signedSignalValue(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return unavailable }
        let digits = signalDecimals(unit)
        let magnitude = String(format: "%.\(digits)f", abs(value))
        let zero = String(format: "%.\(digits)f", 0.0)
        let sign = magnitude == zero ? "±" : (value < 0 ? "−" : "+")
        return "\(sign)\(magnitude) \(signalUnit(unit))"
    }

    /// "07:02" in the document's zone (the phone's zone when it has none).
    static func clock(_ ts: Int, timezone: String?) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_GB")
        f.dateFormat = "HH:mm"
        f.timeZone = timezone.flatMap(TimeZone.init(identifier:)) ?? .current
        return f.string(from: Date(timeIntervalSince1970: TimeInterval(ts)))
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

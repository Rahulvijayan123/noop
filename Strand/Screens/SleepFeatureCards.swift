import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics

// SleepFeatureCards.swift — the compact "Sleep details" section (spec-25 §7.5).
//
// Fed by the hosted `daily.sleep_features` document (decoded by HostedDayResult into the SHARED
// StrandAnalytics `SleepFeatureDocument`). SleepView renders this section in the night-detail
// area ONLY when a document exists for the current night; with no payload the section is absent
// entirely, so builds without the enrichment render exactly as before (the same feature-off
// default as the Activity Context line).
//
// Cards (spec 7.5):
//   • Continuity   — WASO, awakenings/hour, longest sleep bout, maintenance efficiency.
//   • Regularity   — SRI 7d with history/coverage + onset/wake variability.
//   • Architecture — stage bouts, REM/deep latency, a transition summary.
//   • Physiology   — a small stage-by-metric comparison.
//   • Settling     — aligned HR + temperature curves with the sleep onset marked.
//   • Breathing    — RSA-derived rate + interval variability + coverage.
//
// Honesty rules the section (spec 7.5 + contract section 7):
//   • Every metric is Optional — a withheld/partial metric shows honest wording, never a fake
//     number and never a fabricated zero.
//   • Breathing is explicitly an ESTIMATE from the heart-rate rhythm, not airflow.
//   • Oxygen is NEVER shown here: `capabilities.oxygen_events.ready` is false until the sparse
//     strap estimate is qualified, and spec 7.5 forbids a zero oxygen-burden display. The
//     existing "strap estimate (unverified)" line on the oxygen surface is untouched.
//
// Collapsed by default: Continuity + Regularity only. The expander reveals the four remaining
// cards ("fewer numbers initially, full object downstream" — spec 7.5).

/// Loads the hosted `daily.sleep_features` for the night on screen from the server-score cache and
/// renders `SleepFeatureCards` when a matching night exists; otherwise nothing, so a build or night
/// without the enrichment renders exactly as before.
///
/// Reads under the device ids the app model syncs (`IntradaySeriesStore.readCandidates`, the same
/// list Today and the metric pages use) and re-reads whenever the repository refreshes, which is
/// when the app model writes a new server result into the cache.
struct SleepFeatureSection: View {
    let startTs: Int
    let endTs: Int

    @EnvironmentObject private var repo: Repository
    @State private var loaded: (document: SleepFeatureDocument, night: SleepFeatureNight)?

    var body: some View {
        Group {
            if let loaded {
                SleepFeatureCards(document: loaded.document, night: loaded.night)
            }
        }
        .task(id: "\(startTs)|\(endTs)|\(repo.refreshSeq)") { await load() }
    }

    private func load() async {
        guard CloudPushIdentityStore.current() != nil,
              let repository = CloudPushRuntime.shared.scoreRepository() else { loaded = nil; return }
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(endTs)))
        let deviceIds = await IntradaySeriesStore.shared.readCandidates
        guard let document = repository.cachedDay(day: day, deviceIds: deviceIds)?.hostedResult?.sleepFeatures,
              let night = document.night(matchingStart: startTs, end: endTs) else { loaded = nil; return }
        loaded = (document, night)
    }
}

/// The whole "Sleep details" section: two always-visible cards plus an expander that reveals the
/// rest.
struct SleepFeatureCards: View {
    let document: SleepFeatureDocument
    let night: SleepFeatureNight

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep details", overline: "Server enrichment")

            SleepFeatureContinuityCard(continuity: night.continuity)
            SleepFeatureRegularityCard(regularity: document.regularity)

            if expanded {
                SleepFeatureArchitectureCard(architecture: night.architecture)
                SleepFeaturePhysiologyCard(physiology: night.stagePhysiology)
                SleepFeatureSettlingCard(settling: night.settling)
                SleepFeatureBreathingCard(breathing: night.respiratoryVariability)
            }

            Button {
                withAnimation(StrandMotion.interactive) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(expanded ? "Show fewer" : "Show all sleep details")
                        .font(StrandFont.footnote)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(StrandPalette.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(expanded ? "Collapse sleep details" : "Expand sleep details")
        }
    }
}

// MARK: - Continuity

/// Continuity card: the four numbers spec 7.5 asks for. Withheld/partial nights show the block's
/// machine-readable reasons instead of inventing values.
struct SleepFeatureContinuityCard: View {
    let continuity: SleepContinuity?

    var body: some View {
        NoopCard(tint: StrandPalette.restColor) {
            VStack(alignment: .leading, spacing: 8) {
                cardHeader("Continuity", status: continuity?.status,
                           caption: "Waking patterns across the night")

                if let continuity, continuity.status != .withheld, continuity.status != .notApplicable {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.gap),
                                        GridItem(.flexible(), spacing: NoopMetrics.gap)],
                              alignment: .leading, spacing: 10) {
                        SleepFeatureRow(label: "WASO",
                                        value: SleepFeatureFormat.minutes(continuity.wasoMin))
                        SleepFeatureRow(label: "Awakenings/hr",
                                        value: SleepFeatureFormat.value(continuity.recurrentAwakeningIndexPerH))
                        SleepFeatureRow(label: "Longest sleep bout",
                                        value: SleepFeatureFormat.minutes(continuity.longestSleepBoutMin))
                        SleepFeatureRow(label: "Maintenance eff.",
                                        value: SleepFeatureFormat.percent(continuity.sleepMaintenanceEfficiencyPct))
                    }
                    if !continuity.reasons.isEmpty {
                        reasonLine(continuity.reasons)
                    }
                } else {
                    withheldLine("Continuity isn't published for this night.",
                                 reasons: continuity?.reasons)
                }
            }
        }
    }

    private func cardHeader(_ title: String, status: SleepMetricStatus?, caption: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).strandOverline()
                Text(caption).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 8)
            SleepFeatureStatusPill(status: status)
        }
    }

    private func withheldLine(_ message: String, reasons: [String]?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(message)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let reasons, !reasons.isEmpty { reasonLine(reasons) }
        }
    }

    private func reasonLine(_ reasons: [String]) -> some View {
        Text(reasons.joined(separator: " · "))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Regularity

/// Regularity card: SRI 7d with an honest coverage/history line, plus onset/wake variability.
/// A withheld SRI shows WHY it is withheld (never a fake value); timing variability is still
/// shown because the sidecar delivers it independently of the SRI gates (contract section 3).
struct SleepFeatureRegularityCard: View {
    let regularity: SleepRegularity?

    var body: some View {
        NoopCard(tint: StrandPalette.metricCyan) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Regularity").strandOverline()
                        Text("Sleep regularity index (SRI)").font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    SleepFeatureStatusPill(status: regularity?.status)
                }

                if let sri = regularity?.sri7d {
                    if sri.status == .available, let value = sri.value {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Text(String(format: "%.0f", value))
                                .font(StrandFont.number(26, weight: .medium))
                                .foregroundStyle(StrandPalette.metricCyan)
                            Text("/ 100")
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Spacer()
                        }
                        // History + coverage: how many days and paired minutes stand behind the
                        // number — the denominator of the SRI gate, not a score.
                        if let paired = sri.pairedMinutes, let eligible = sri.eligibleMinutes, eligible > 0 {
                            let coverage = min(1.0, Double(paired) / Double(eligible))
                            Text("\(sri.validDays ?? 0) monitored days · \(SleepFeatureFormat.percent(coverage * 100)) paired coverage")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !sri.reasons.isEmpty { reasonLine(sri.reasons) }
                    } else {
                        // Honest withheld state: reasons first, never a number.
                        VStack(alignment: .leading, spacing: 4) {
                            Text("SRI withheld")
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                            if let paired = sri.pairedMinutes, let days = sri.validDays {
                                Text("\(days) monitored days · \(paired) paired minutes")
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            if !sri.reasons.isEmpty { reasonLine(sri.reasons) }
                        }
                    }
                } else {
                    Text("Not enough monitored history for a regularity reading yet.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // Timing variability rides independently of the SRI gates (contract section 3).
                if let clock = regularity?.clockProfile {
                    HStack(spacing: 12) {
                        SleepFeatureRow(label: "Onset",
                                        value: SleepFeatureFormat.minutes(clock.sleepOnset?.circadianSdMin,
                                                                          prefix: "±"))
                        SleepFeatureRow(label: "Wake",
                                        value: SleepFeatureFormat.minutes(clock.finalWake?.circadianSdMin,
                                                                          prefix: "±"))
                        SleepFeatureRow(label: "Night shift",
                                        value: SleepFeatureFormat.minutes(clock.adjacentNightPhaseShiftMin?.value))
                    }
                    Text("Variability across recent nights, in minutes")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
    }

    private func reasonLine(_ reasons: [String]) -> some View {
        Text(reasons.joined(separator: " · "))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Architecture

/// Architecture card: stage bout medians, REM/deep latency from sleep onset, and a compact
/// transition summary. The latency numbers are from ACTUAL sleep onset (contract section 3
/// architecture — NOT YASA's recording-start Lat_REM).
struct SleepFeatureArchitectureCard: View {
    let architecture: SleepArchitecture?

    var body: some View {
        NoopCard(tint: StrandPalette.restBright) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Architecture").strandOverline()
                        Text("Stage structure and transitions").font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    SleepFeatureStatusPill(status: architecture?.status)
                }

                if let architecture, architecture.status != .withheld, architecture.status != .notApplicable {
                    HStack(spacing: 12) {
                        SleepFeatureRow(label: "REM latency",
                                        value: SleepFeatureFormat.minutes(architecture.remLatencyFromOnsetMin))
                        SleepFeatureRow(label: "Deep latency",
                                        value: SleepFeatureFormat.minutes(architecture.deepLatencyFromOnsetMin))
                        SleepFeatureRow(label: "REM bout",
                                        value: SleepFeatureFormat.minutes(architecture.bouts(for: "rem")?.medianMin))
                        SleepFeatureRow(label: "Deep bout",
                                        value: SleepFeatureFormat.minutes(architecture.bouts(for: "deep")?.medianMin))
                    }

                    let transitions = architecture.transitionCounts.flatMap { $0 }.reduce(0, +)
                    HStack(spacing: 12) {
                        SleepFeatureRow(label: "Stage transitions",
                                        value: transitions > 0 ? "\(transitions)" : "Not available")
                        SleepFeatureRow(label: "Entropy",
                                        value: SleepFeatureFormat.value(architecture.entropyRateBitsPerTransition,
                                                                        suffix: " bits"))
                    }
                    Text("Latency from actual sleep onset, not recording start")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Architecture isn't published for this night.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let arch = architecture, !arch.reasons.isEmpty { reasonLine(arch.reasons) }
                }
            }
        }
    }

    private func reasonLine(_ reasons: [String]) -> some View {
        Text(reasons.joined(separator: " · "))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Physiology

/// Physiology card: a small stage-by-metric comparison (heart rate and RMSSD per stage).
/// Model-dependent by nature (contract section 3 stage_physiology: stages come from sleep-v2).
struct SleepFeaturePhysiologyCard: View {
    let physiology: SleepStagePhysiology?

    private struct StageColumns: Identifiable {
        let stage: String
        let label: String
        let metrics: SleepStagePhysiologyMetrics?
        var id: String { stage }
    }

    private var columns: [StageColumns] {
        [
            StageColumns(stage: "light", label: "Light", metrics: physiology?.light),
            StageColumns(stage: "deep", label: "Deep", metrics: physiology?.deep),
            StageColumns(stage: "rem", label: "REM", metrics: physiology?.rem),
        ]
    }

    var body: some View {
        NoopCard(tint: StrandPalette.accent) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Physiology").strandOverline()
                        Text("Heart rate and RMSSD by stage").font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    SleepFeatureStatusPill(status: physiology?.status)
                }

                if physiology?.stages.isEmpty == false {
                    HStack(alignment: .top, spacing: NoopMetrics.gap) {
                        ForEach(columns) { column in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(column.label).strandOverline()
                                SleepFeatureRow(label: "HR",
                                                value: SleepFeatureFormat.value(column.metrics?.hrMedianBpm,
                                                                                suffix: " bpm"))
                                SleepFeatureRow(label: "RMSSD",
                                                value: SleepFeatureFormat.value(column.metrics?.rmssdMs?.median,
                                                                                suffix: " ms"))
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    Text("Stages are model estimates from sleep-v2, not ground truth")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Stage physiology isn't available for this night.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Settling

/// Settling card: the heart-rate and skin-temperature curves around sleep onset, aligned on the
/// same minute axis with the onset marked at t=0. Anchored at the canonical ACTUAL sleep onset s
/// (first sleep epoch), which is minute 0 of the sidecar's curves (contract section 3 settling).
/// Invalid minutes are real gaps — the path never bridges them, so a missing minute never
/// invents a plateau (contract section 4).
struct SleepFeatureSettlingCard: View {
    let settling: SleepSettling?

    var body: some View {
        NoopCard(tint: StrandPalette.metricRose) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Settling").strandOverline()
                        Text("Heart rate and temperature around sleep onset").font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    SleepFeatureStatusPill(status: settling?.status)
                }

                if let settling, settling.status != .withheld, settling.status != .notApplicable {
                    // The onset s = the curve's earliest timestamp + 30 min (the sidecar emits
                    // one entry per minute over [-30, +90) relative to s).
                    let onset = SettlingCurves.onset(hr: settling.hrCurve, temp: settling.tempCurve)
                    SettlingCurves(hr: settling.hrCurve, temp: settling.tempCurve, onsetTs: onset)
                        .frame(height: 110)
                        .accessibilityHidden(true)

                    HStack(spacing: 12) {
                        SleepFeatureRow(label: "HR drop",
                                        value: SleepFeatureFormat.value(settling.hrDropBpm, suffix: " bpm"))
                        SleepFeatureRow(label: "Settling",
                                        value: SleepFeatureFormat.minutes(settling.hrSettlingLatencyMin))
                    }
                    Text("Minutes from sleep onset (t = 0)")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text("Settling curves aren't available for this night.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let s = settling, !s.reasons.isEmpty { reasonLine(s.reasons) }
                }
            }
        }
    }

    private func reasonLine(_ reasons: [String]) -> some View {
        Text(reasons.joined(separator: " · "))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Two stacked mini-lines (HR top, temperature bottom) sharing one minute axis with a dashed
/// onset marker. Simple Path rendering in the app's flat style — no gradients, no bloom.
private struct SettlingCurves: View {
    let hr: [SleepHrCurvePoint]
    let temp: [SleepTempCurvePoint]
    let onsetTs: Int?

    /// Recover the actual sleep onset s from either curve: the sidecar emits one entry per minute
    /// over [s−30, s+90), so s = earliest timestamp + 30 minutes.
    static func onset(hr: [SleepHrCurvePoint], temp: [SleepTempCurvePoint]) -> Int? {
        let earliestHr = hr.compactMap { $0.ts }.min()
        let earliestTemp = temp.compactMap { $0.ts }.min()
        guard let earliest = [earliestHr, earliestTemp].compactMap({ $0 }).min() else { return nil }
        return earliest + 30 * 60
    }

    var body: some View {
        let hrSamples = hr.compactMap { p -> (Double, Double?)? in
            guard let ts = p.ts else { return nil }
            return (Double(ts - (onsetTs ?? ts)) / 60.0, p.valid == true ? p.bpm : nil)
        }
        let tempSamples = temp.compactMap { p -> (Double, Double?)? in
            guard let ts = p.ts else { return nil }
            return (Double(ts - (onsetTs ?? ts)) / 60.0, p.valid == true ? p.celsius : nil)
        }
        VStack(alignment: .leading, spacing: 6) {
            MiniCurve(samples: hrSamples, color: StrandPalette.metricRose, onsetMinute: 0,
                      caption: "HR", valueFormat: { String(format: "%.0f bpm", $0) })
            MiniCurve(samples: tempSamples, color: StrandPalette.restColor, onsetMinute: 0,
                      caption: "Temp", valueFormat: { String(format: "%.1f°C", $0) })
        }
    }
}

/// One flat line over a minute axis. nil values are gaps (not bridged). A dashed vertical line
/// marks the onset minute.
private struct MiniCurve: View {
    let samples: [(minute: Double, value: Double?)]
    let color: Color
    let onsetMinute: Double
    let caption: String
    let valueFormat: (Double) -> String

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(caption)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 30, alignment: .leading)
            GeometryReader { geo in
                ZStack {
                    curve(geo.size)
                    // Onset marker at minute 0.
                    let x0 = xPosition(minute: onsetMinute, width: geo.size.width)
                    Path { p in
                        p.move(to: CGPoint(x: x0, y: 0))
                        p.addLine(to: CGPoint(x: x0, y: geo.size.height))
                    }
                    .stroke(StrandPalette.hairlineStrong, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }
            }
        }
        .frame(height: 34)
    }

    private func validSamples() -> [(minute: Double, value: Double)] {
        samples.compactMap { s in s.value.map { (s.minute, $0) } }
    }

    private func xPosition(minute: Double, width: CGFloat) -> CGFloat {
        let valid = validSamples()
        guard let minX = valid.map({ $0.minute }).min(),
              let maxX = valid.map({ $0.minute }).max(), maxX > minX else { return width / 2 }
        return CGFloat((minute - minX) / (maxX - minX)) * width
    }

    private func curve(_ size: CGSize) -> some View {
        Canvas { context, size in
            let valid = validSamples()
            guard valid.count > 1,
                  let minX = valid.map({ $0.minute }).min(),
                  let maxX = valid.map({ $0.minute }).max(),
                  let minY = valid.map({ $0.value }).min(),
                  let maxY = valid.map({ $0.value }).max() else { return }
            let yRange = max(maxY - minY, 0.001)
            let span = max(maxX - minX, 0.001)
            var path = Path()
            for (i, sample) in valid.enumerated() {
                let x = CGFloat((sample.minute - minX) / span) * size.width
                let y = size.height - CGFloat((sample.value - minY) / yRange) * size.height
                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Breathing

/// Breathing card: RSA-derived rate and interval variability with honest estimate wording
/// (contract section 3 respiratory_variability: "estimated from heart-rate rhythm, not airflow").
struct SleepFeatureBreathingCard: View {
    let breathing: SleepRespiratoryVariability?

    var body: some View {
        NoopCard(tint: StrandPalette.signalYellow) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Breathing").strandOverline()
                        Text("RSA-derived estimate").font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    Spacer(minLength: 8)
                    SleepFeatureStatusPill(status: breathing?.status)
                }

                if let breathing, breathing.status != .withheld, breathing.status != .notApplicable {
                    HStack(spacing: 12) {
                        SleepFeatureRow(label: "Rate",
                                        value: SleepFeatureFormat.value(breathing.rateBpm, suffix: " br/min"))
                        SleepFeatureRow(label: "Variability",
                                        value: SleepFeatureFormat.percent(breathing.cvInterval.map { $0 * 100 }))
                        SleepFeatureRow(label: "Coverage",
                                        value: SleepFeatureFormat.percent(breathing.quality?.nightRunCoverage.map { $0 * 100 }))
                    }
                    Text("Estimated from heart-rate rhythm, not airflow")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if breathing.unobservedBreathIsNotApnea == true {
                        Text("An unobserved breath is not an apnea.")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !breathing.reasons.isEmpty { reasonLine(breathing.reasons) }
                } else {
                    Text("Breathing estimate isn't available for this night.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let b = breathing, !b.reasons.isEmpty { reasonLine(b.reasons) }
                }
            }
        }
    }

    private func reasonLine(_ reasons: [String]) -> some View {
        Text(reasons.joined(separator: " · "))
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Shared small pieces

/// One label/value line inside a card (label overline, value in the metric number font).
private struct SleepFeatureRow: View {
    let label: String
    let value: String

    init(label: String, value: String) {
        self.label = label
        self.value = value
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).strandOverline()
            Text(value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }
}

/// A tiny status pill (Available / Partial / Withheld / …) so the section explains WHY a number
/// is missing instead of silently omitting it. `.unknown` renders nothing (a future status is
/// "don't guess", never a wrong claim).
private struct SleepFeatureStatusPill: View {
    let status: SleepMetricStatus?

    var body: some View {
        if let status {
            switch status {
            case .available:
                pill("Available", StrandPalette.statusPositive)
            case .partial:
                pill("Partial", StrandPalette.signalYellow)
            case .withheld:
                pill("Withheld", StrandPalette.textTertiary)
            case .notApplicable:
                pill("N/A", StrandPalette.textTertiary)
            case .notRun:
                pill("Not run", StrandPalette.textTertiary)
            case .timeout, .error:
                pill("Unavailable", StrandPalette.metricRose)
            case .unknown:
                EmptyView()
            }
        }
    }

    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(StrandFont.captionNumber)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.14), in: Capsule(style: .continuous))
    }
}

/// Number formatting for the sleep-features cards. Honesty rule: a nil value formats as
/// "Not available" (spec 7.5 "show estimate/source and missing-data explanations"; contract:
/// null/absent is the ONLY representation of an unavailable metric — never a fabricated 0).
enum SleepFeatureFormat {
    static func value(_ value: Double?, suffix: String = "") -> String {
        guard let value else { return "Not available" }
        return String(format: "%.1f", value) + suffix
    }

    static func percent(_ value: Double?) -> String {
        guard let value else { return "Not available" }
        return String(format: "%.0f%%", value)
    }

    static func minutes(_ value: Double?, prefix: String = "") -> String {
        guard let value else { return "Not available" }
        if abs(value) < 60 {
            return "\(prefix)\(String(format: "%.0f", value))m"
        }
        let h = Int(abs(value)) / 60
        let m = Int(abs(value.rounded())) % 60
        let sign = value < 0 ? "−" : ""
        return "\(sign)\(prefix)\(h)h \(m)m"
    }
}

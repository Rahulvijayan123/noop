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
        // The 1-pt anchor is load-bearing: a `.task` on an empty view never fires, so with no document yet
        // nothing would ever load one.
        ZStack(alignment: .top) {
            Color.clear.frame(height: 1)
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
        var hosted = repository.cachedDay(day: day, deviceIds: deviceIds)?.hostedResult
        if hosted?.sleepFeatures == nil {
            hosted = (try? await repository.refresh(day: day, deviceIds: deviceIds))?.hostedResult
        }
        // `daily.sleep_analytics_v1` owns continuity/architecture/thermal; showing both would put two
        // conflicting definitions of the same metrics on one screen.
        guard hosted?.sleepAnalytics == nil else { loaded = nil; return }
        guard !Task.isCancelled, let document = hosted?.sleepFeatures,
              let night = document.night(matchingStart: startTs, end: endTs) else { loaded = nil; return }
        loaded = (document, night)
    }
}


/// The "Sleep details" section: one surface, a headline strip with the three numbers that matter, and a
/// list of chapters (Continuity, Regularity, Architecture, Physiology, Settling, Breathing). Each chapter
/// is a single line that opens in place, so the page reads as one calm list instead of six boxes.
struct SleepFeatureCards: View {
    let document: SleepFeatureDocument
    let night: SleepFeatureNight

    @State private var open: Set<Chapter> = []

    enum Chapter: String, CaseIterable, Hashable {
        case continuity, regularity, architecture, physiology, settling, breathing
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep details")

            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    headline
                        .padding(.horizontal, NoopMetrics.cardPadding)
                        .padding(.top, NoopMetrics.cardPadding)
                        .padding(.bottom, 14)

                    ForEach(Chapter.allCases.filter { summary(for: $0).hasDetail }, id: \.self) { chapter in
                        hairline
                        chapterRow(chapter)
                    }
                }
            }
        }
        // The night page stacks this above its About card with no gap of its own (the host renders nothing
        // until a document loads), so the section brings the page's section gap with it.
        .padding(.bottom, NoopMetrics.sectionGap)
    }

    private var hairline: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1)
            .padding(.leading, NoopMetrics.cardPadding)
    }

    // MARK: Headline

    private var headline: some View {
        let c = night.continuity
        let continuityOK = c.map { $0.status != .withheld && $0.status != .notApplicable } ?? false
        let sri = document.regularity?.sri7d
        let sriValue: String = {
            guard let sri, sri.status == .available, let v = sri.value else { return "–" }
            return String(format: "%.0f", v)
        }()
        return HStack(alignment: .top, spacing: 0) {
            heroStat(label: "Awake in bed",
                     value: continuityOK ? SleepFeatureFormat.compactMinutes(c?.wasoMin) : "–")
            heroDivider
            heroStat(label: "Longest stretch",
                     value: continuityOK ? SleepFeatureFormat.compactMinutes(c?.longestSleepBoutMin) : "–")
            heroDivider
            heroStat(label: "Regularity", value: sriValue, unit: sriValue == "–" ? nil : "/100")
        }
    }

    private func heroStat(label: String, value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(StrandFont.number(20))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Text(label).strandLabel().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 36)
            .padding(.trailing, 12)
    }

    // MARK: Chapters

    private func chapterRow(_ chapter: Chapter) -> some View {
        let info = summary(for: chapter)
        let isOpen = open.contains(chapter)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                guard info.hasDetail else { return }
                withAnimation(StrandMotion.interactive) {
                    if isOpen { open.remove(chapter) } else { open.insert(chapter) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: info.icon)
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 28)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.title)
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(info.line)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    if info.hasDetail {
                        Image(systemName: "chevron.down")
                            .font(StrandFont.icon(.inline))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(isOpen ? 180 : 0))
                    }
                }
                .padding(.horizontal, NoopMetrics.cardPadding)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(info.title). \(info.line)")
            .accessibilityHint(info.hasDetail ? (isOpen ? "Collapse" : "Expand") : "")

            if isOpen && info.hasDetail {
                detail(for: chapter)
                    .padding(.leading, NoopListDivider.iconRowInset)
                    .padding(.trailing, NoopMetrics.cardPadding)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
    }

    private struct ChapterSummary {
        var title: String
        var icon: String
        var tint: Color
        var line: String
        var hasDetail: Bool
    }

    private func available(_ s: SleepMetricStatus?) -> Bool {
        guard let s else { return false }
        return s != .withheld && s != .notApplicable && s != .notRun && s != .timeout && s != .error
    }

    private func partialNote(_ s: SleepMetricStatus?) -> String { "" }

    private func summary(for chapter: Chapter) -> ChapterSummary {
        switch chapter {
        case .continuity:
            let c = night.continuity
            let ok = available(c?.status)
            return ChapterSummary(
                title: "Continuity", icon: "waveform.path", tint: StrandPalette.restColor,
                line: ok ? "\(SleepFeatureFormat.value(c?.recurrentAwakeningIndexPerH, suffix: " wakes/hr")) · \(SleepFeatureFormat.percent(c?.sleepMaintenanceEfficiencyPct)) maintained\(partialNote(c?.status))"
                         : "Not published for this night", hasDetail: ok || !(c?.reasons.isEmpty ?? true))
        case .regularity:
            let r = document.regularity
            let sri = r?.sri7d
            let line: String
            if let sri, sri.status == .available, let v = sri.value {
                line = "SRI \(String(format: "%.0f", v)) of 100 · \(sri.validDays ?? 0) days"
            } else if r?.clockProfile != nil {
                line = "SRI still building · timing variability available"
            } else {
                line = "Not enough history yet"
            }
            return ChapterSummary(title: "Regularity", icon: "metronome", tint: StrandPalette.metricCyan,
                                  line: line, hasDetail: sri != nil || r?.clockProfile != nil)
        case .architecture:
            let a = night.architecture
            let ok = available(a?.status)
            var parts: [String] = []
            if let rem = a?.remLatencyFromOnsetMin { parts.append("REM first at \(SleepFeatureFormat.minutes(rem))") }
            if let deep = a?.deepLatencyFromOnsetMin { parts.append("deep first at \(SleepFeatureFormat.minutes(deep))") }
            return ChapterSummary(title: "Architecture", icon: "square.stack.3d.up", tint: StrandPalette.restBright,
                                  line: parts.isEmpty ? "Stage timing" : parts.joined(separator: " · "),
                                  hasDetail: ok && !parts.isEmpty)
        case .physiology:
            let p = night.stagePhysiology
            let ok = p?.stages.isEmpty == false
            let line = ok
                ? "Deep \(SleepFeatureFormat.value(p?.deep?.hrMedianBpm, suffix: " bpm", short: true)) · REM \(SleepFeatureFormat.value(p?.rem?.hrMedianBpm, suffix: " bpm", short: true))"
                : "Not available for this night"
            return ChapterSummary(title: "Physiology by stage", icon: "heart.text.square", tint: StrandPalette.accent,
                                  line: line, hasDetail: ok)
        case .settling:
            let st = night.settling
            let nadir = st?.hrNadirLatencyMin
            let ok = available(st?.status) && nadir != nil
            return ChapterSummary(title: "Falling asleep", icon: "moon.zzz", tint: StrandPalette.metricRose,
                                  line: nadir.map { "Lowest heart rate \(SleepFeatureFormat.minutes($0)) after falling asleep" } ?? "",
                                  hasDetail: ok)
        case .breathing:
            let b = night.respiratoryVariability
            let ok = available(b?.status)
            let line = ok
                ? "\(SleepFeatureFormat.value(b?.rateBpm, suffix: " br/min", short: true))"
                : "Not available for this night"
            return ChapterSummary(title: "Breathing", icon: "lungs", tint: StrandPalette.signalYellow,
                                  line: line, hasDetail: ok && b?.rateBpm != nil)
        }
    }

    // MARK: Chapter details

    @ViewBuilder private func detail(for chapter: Chapter) -> some View {
        switch chapter {
        case .continuity:
            let c = night.continuity
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Awake after falling asleep", SleepFeatureFormat.minutes(c?.wasoMin))
                detailRow("Awakenings per hour", SleepFeatureFormat.value(c?.recurrentAwakeningIndexPerH))
                detailRow("Longest sleep bout", SleepFeatureFormat.minutes(c?.longestSleepBoutMin))
                detailRow("Maintenance efficiency", SleepFeatureFormat.percent(c?.sleepMaintenanceEfficiencyPct))
            }
        case .regularity:
            let r = document.regularity
            VStack(alignment: .leading, spacing: 8) {
                if let sri = r?.sri7d, sri.status == .available, let v = sri.value {
                    detailRow("Sleep regularity index", String(format: "%.0f / 100", v))
                    detailRow("Monitored days", sri.validDays.map { "\($0)" } ?? SleepFeatureFormat.missing)
                }
                if let clock = r?.clockProfile {
                    detailRow("Bedtime varies by", SleepFeatureFormat.minutes(clock.sleepOnset?.circadianSdMin, prefix: "±"))
                    detailRow("Wake time varies by", SleepFeatureFormat.minutes(clock.finalWake?.circadianSdMin, prefix: "±"))
                    detailRow("Shift from last night",
                              SleepFeatureFormat.minutes(clock.adjacentNightPhaseShiftMin?.value))
                }
            }
        case .architecture:
            let a = night.architecture
            VStack(alignment: .leading, spacing: 8) {
                detailRow("REM latency", SleepFeatureFormat.minutes(a?.remLatencyFromOnsetMin))
                detailRow("Deep latency", SleepFeatureFormat.minutes(a?.deepLatencyFromOnsetMin))
                detailRow("Typical REM bout", SleepFeatureFormat.minutes(a?.bouts(for: "rem")?.medianMin))
                detailRow("Typical deep bout", SleepFeatureFormat.minutes(a?.bouts(for: "deep")?.medianMin))
            }
        case .physiology:
            let p = night.stagePhysiology
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 0) {
                    Text("").frame(maxWidth: .infinity, alignment: .leading)
                    stageHeader("Light"); stageHeader("Deep"); stageHeader("REM")
                }
                stageRow("Heart rate (bpm)", [p?.light, p?.deep, p?.rem].map {
                    SleepFeatureFormat.value($0?.hrMedianBpm, suffix: "", short: true) })
                stageRow("RMSSD (ms)", [p?.light, p?.deep, p?.rem].map {
                    SleepFeatureFormat.value($0?.rmssdMs?.median, suffix: "", short: true) })
            }
        case .settling:
            let s = night.settling
            VStack(alignment: .leading, spacing: 10) {
                if let s {
                    let onset = SettlingCurves.onset(hr: s.hrCurve, temp: s.tempCurve)
                    SettlingCurves(hr: s.hrCurve, temp: s.tempCurve, onsetTs: onset)
                        .frame(height: 80)
                        .accessibilityHidden(true)
                    detailRow("Lowest heart rate", SleepFeatureFormat.minutes(s.hrNadirLatencyMin) + " in")
                    if let drop = s.hrDropBpm, drop > 0 {
                        detailRow("Heart rate drop", SleepFeatureFormat.value(drop, suffix: " bpm", short: true))
                    }
                    if let settle = s.hrSettlingLatencyMin, settle > 0 {
                        detailRow("Time to settle", SleepFeatureFormat.minutes(settle))
                    }
                }
            }
        case .breathing:
            let b = night.respiratoryVariability
            VStack(alignment: .leading, spacing: 8) {
                detailRow("Rate", SleepFeatureFormat.value(b?.rateBpm, suffix: " br/min", short: true))
                detailRow("Variability", SleepFeatureFormat.percent(b?.cvInterval.map { $0 * 100 }))
                detailRow("Coverage", SleepFeatureFormat.percent(b?.quality?.nightRunCoverage.map { $0 * 100 }))
            }
        }
    }

    @ViewBuilder private func detailRow(_ label: String, _ value: String) -> some View {
        if value != SleepFeatureFormat.missing && !value.hasPrefix(SleepFeatureFormat.missing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                Text(value)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
    }

    private func stageHeader(_ text: String) -> some View {
        Text(text).strandLabel().frame(width: 52, alignment: .trailing)
    }

    private func stageRow(_ label: String, _ values: [String]) -> some View {
        HStack(spacing: 0) {
            Text(label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Text(v).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                    .frame(width: 52, alignment: .trailing)
            }
        }
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


/// Number formatting for the sleep-features cards. Honesty rule: a nil value formats as
/// "Not available" (spec 7.5 "show estimate/source and missing-data explanations"; contract:
/// null/absent is the ONLY representation of an unavailable metric — never a fabricated 0).
enum SleepFeatureFormat {
    static let missing = "Not available"

    static func value(_ value: Double?, suffix: String = "", short: Bool = false) -> String {
        guard let value else { return short ? "–" : missing }
        return String(format: short ? "%.0f" : "%.1f", value) + suffix
    }

    /// "1h 05m" / "12m" for the headline strip; a missing value is a dash, never a zero.
    static func compactMinutes(_ value: Double?) -> String {
        guard let value else { return "–" }
        let total = Int(value.rounded())
        if total < 60 { return "\(total)m" }
        return "\(total / 60)h \(String(format: "%02d", total % 60))m"
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

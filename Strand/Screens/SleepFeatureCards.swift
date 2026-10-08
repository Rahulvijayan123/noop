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
// Cards (spec 7.5, extended by spec-02 docs/spec-02/CONTRACT.md §5):
//   • Continuity   — WASO, awakenings/hour, longest sleep bout, maintenance efficiency.
//   • Regularity   — SRI 7d with history/coverage + onset/wake variability.
//   • Architecture — stage bouts, REM/deep latency, a transition summary.
//   • Physiology   — a small stage-by-metric comparison.
//   • Settling     — aligned HR + temperature curves with the sleep onset marked.
//   • Breathing    — RSA-derived rate, interval SD/RMSSD, interval distribution, stable-modulation
//                    components, per-stage rate/variability, supported range and coverage.
//   • Temperature rhythm, rest-activity rhythm, next-night rebound, secondary PRV statistics (spec-02).
//
// With `daily.sleep_analytics_v1` present, Continuity and Architecture step aside (the analytics section
// owns them, CONTRACT §2); every other chapter still renders (the section used to hide itself entirely).
//
// Honesty rules the section (spec 7.5 + contract section 7):
//   • Every metric is Optional — a withheld/partial metric shows honest wording, never a fake
//     number and never a fabricated zero.
//   • Breathing is explicitly an ESTIMATE from the heart-rate rhythm, not airflow.
//   • Oxygen is NEVER shown here: `capabilities.oxygen_events.ready` is false until the sparse
//     strap estimate is qualified, and spec 7.5 forbids a zero oxygen-burden display. The
//     existing "strap estimate (unverified)" line on the oxygen surface is untouched.
//
// Every chapter is one collapsed line; a chapter opens in place ("fewer numbers initially, full object
// downstream" — spec 7.5). Existing chapters hide when their block is unavailable (their prior behaviour); the
// spec-02 chapters show an unavailable block's reason instead of numbers (never a placeholder value).

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
    @State private var loaded: (document: SleepFeatureDocument, night: SleepFeatureNight, analyticsPresent: Bool)?

    var body: some View {
        // The 1-pt anchor is load-bearing: a `.task` on an empty view never fires, so with no document yet
        // nothing would ever load one.
        ZStack(alignment: .top) {
            Color.clear.frame(height: 1)
            if let loaded {
                SleepFeatureCards(document: loaded.document, night: loaded.night,
                                  analyticsPresent: loaded.analyticsPresent)
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
        // `daily.sleep_analytics_v1` owns continuity / architecture / nightly thermal (docs/spec-02/CONTRACT.md
        // §2). When it exists those chapters step aside here (no two definitions of one metric on a screen);
        // regularity, stage physiology, settling, breathing, rhythm, rebound and the secondary PRV statistics
        // still come from `sleep_features` (spec-02 readback fix: the whole section used to hide itself).
        guard !Task.isCancelled, let document = hosted?.sleepFeatures,
              let night = document.night(matchingStart: startTs, end: endTs) else { loaded = nil; return }
        let plan = SleepFeatureSectionPlan(document: document, night: night,
                                           analyticsPresent: hosted?.sleepAnalytics != nil)
        loaded = plan.isEmpty ? nil : (document, night, plan.analyticsPresent)
    }
}

/// Which chapters of the Sleep details section render for one night (pure, testable). With a
/// `sleep_analytics_v1` document present the continuity and architecture chapters (and the continuity numbers
/// of the headline) are left to the analytics section; everything else still renders from `sleep_features`.
struct SleepFeatureSectionPlan: Equatable {
    let analyticsPresent: Bool
    let chapters: [SleepFeatureCards.Chapter]
    /// The headline strip's three stats.
    let headline: [SleepFeatureDisplayModel.Stat]

    init(document: SleepFeatureDocument, night: SleepFeatureNight, analyticsPresent: Bool) {
        self.analyticsPresent = analyticsPresent
        let model = SleepFeatureDisplayModel(document: document, night: night, analyticsPresent: analyticsPresent)
        chapters = model.chapters.map(\.chapter)
        headline = model.headline
    }

    /// Nothing to show: no chapter has content. The section is then absent, as before.
    var isEmpty: Bool { chapters.isEmpty }
}

/// The "Sleep details" section: one surface, a headline strip with the three numbers that matter, and a
/// list of chapters. Each chapter is a single line that opens in place, so the page reads as one calm list
/// instead of many boxes.
struct SleepFeatureCards: View {
    let document: SleepFeatureDocument
    let night: SleepFeatureNight
    let model: SleepFeatureDisplayModel

    @State private var open: Set<Chapter> = []

    enum Chapter: String, CaseIterable, Hashable {
        case continuity, regularity, architecture, physiology, settling, breathing
        // spec-02 (docs/spec-02/CONTRACT.md §5)
        case temperatureRhythm, restActivityRhythm, rebound, prvResearch
    }

    init(document: SleepFeatureDocument, night: SleepFeatureNight, analyticsPresent: Bool = false) {
        self.document = document
        self.night = night
        // Display strings are computed once here, never per body.
        self.model = SleepFeatureDisplayModel(document: document, night: night, analyticsPresent: analyticsPresent)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sleep details", overline: "Server enrichment")

            NoopCard(padding: 0, tint: StrandPalette.restColor) {
                VStack(alignment: .leading, spacing: 0) {
                    headline
                        .padding(.horizontal, NoopMetrics.cardPadding)
                        .padding(.top, NoopMetrics.cardPadding)
                        .padding(.bottom, 14)

                    ForEach(model.chapters, id: \.chapter) { info in
                        hairline
                        chapterRow(info)
                    }
                }
            }
        }
    }

    private var hairline: some View {
        Rectangle().fill(StrandPalette.hairline).frame(height: 1)
            .padding(.leading, NoopMetrics.cardPadding)
    }

    // MARK: Headline

    private var headline: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(model.headline.enumerated()), id: \.offset) { index, stat in
                if index > 0 { heroDivider }
                heroStat(label: stat.label, value: stat.value, unit: stat.unit)
            }
        }
    }

    private func heroStat(label: String, value: String, unit: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(StrandFont.number(24, weight: .medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let unit {
                    Text(unit).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Text(label).strandOverline().lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var heroDivider: some View {
        Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 36)
            .padding(.trailing, 12)
    }

    // MARK: Chapters

    private func chapterRow(_ info: SleepFeatureDisplayModel.ChapterSummary) -> some View {
        let chapter = info.chapter
        let isOpen = open.contains(chapter)
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(StrandMotion.interactive) {
                    if isOpen { open.remove(chapter) } else { open.insert(chapter) }
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: info.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(tint(chapter))
                        .frame(width: 30, height: 30)
                        .background(tint(chapter).opacity(0.14), in: Circle())
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
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                }
                .padding(.horizontal, NoopMetrics.cardPadding)
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(info.title). \(info.line)")
            .accessibilityHint(isOpen ? "Collapse" : "Expand")

            if isOpen {
                detail(for: chapter)
                    .padding(.leading, NoopMetrics.cardPadding + 42)
                    .padding(.trailing, NoopMetrics.cardPadding)
                    .padding(.bottom, 14)
                    .transition(.opacity)
            }
        }
    }

    private func tint(_ chapter: Chapter) -> Color {
        switch chapter {
        case .continuity: return StrandPalette.restColor
        case .regularity: return StrandPalette.metricCyan
        case .architecture: return StrandPalette.restBright
        case .physiology: return StrandPalette.accent
        case .settling: return StrandPalette.metricRose
        case .breathing: return StrandPalette.signalYellow
        case .temperatureRhythm: return StrandPalette.metricAmber
        case .restActivityRhythm: return StrandPalette.metricCyan
        case .rebound: return StrandPalette.restBright
        case .prvResearch: return StrandPalette.metricPurple
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
        case .breathing, .temperatureRhythm, .restActivityRhythm, .rebound, .prvResearch:
            // Model-driven chapters: every row was decided once in `SleepFeatureDisplayModel` (missing values
            // are left out, an unavailable block shows its reason).
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(model.rows(for: chapter).enumerated()), id: \.offset) { _, row in
                    modelRow(row)
                }
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

    private func modelRow(_ row: SleepFeatureDisplayModel.Row) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(row.label).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 8)
                Text(row.value)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(3)
                    .minimumScaleFactor(0.75)
            }
            if let note = row.note {
                Text(note)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.note.map { "\(row.label). \(row.value). \($0)" } ?? "\(row.label). \(row.value)")
    }

    private func stageHeader(_ text: String) -> some View {
        Text(text).strandOverline().frame(width: 52, alignment: .trailing)
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

    // spec-02 display helpers (presentation only; the persisted value is never re-derived).

    /// A duration in seconds with two decimals: 4.25 → "4.25 s" (breath intervals and their spread).
    static func seconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        return String(format: "%.2f s", value)
    }

    /// A 0…1 fraction as a whole percent: 0.64 → "64%".
    static func fractionPercent(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        return String(format: "%.0f%%", value * 100)
    }

    /// "6,120".
    static func count(_ value: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US_POSIX")
        f.usesGroupingSeparator = true
        f.groupingSeparator = ","
        return f.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "6–24" for a two-element range.
    static func range(_ bounds: [Double]) -> String {
        guard bounds.count == 2 else { return missing }
        let fmt: (Double) -> String = { $0 == $0.rounded() ? String(format: "%.0f", $0) : String(format: "%.1f", $0) }
        return "\(fmt(bounds[0]))–\(fmt(bounds[1]))"
    }

    /// "33.42 °C" (rhythm temperatures keep two decimals: amplitudes are fractions of a degree).
    static func celsius(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        return String(format: "%.2f °C", value)
    }

    /// A clock hour 0…24 as "03:24" (wraps outside the day).
    static func clockHours(_ hours: Double?) -> String {
        guard let hours, hours.isFinite else { return missing }
        var minutes = Int((hours * 60).rounded()) % 1440
        if minutes < 0 { minutes += 1440 }
        return String(format: "%02d:%02d", minutes / 60, minutes % 60)
    }

    /// "0.6 h".
    static func hours(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        return String(format: "%.1f h", value)
    }

    /// "+1.5 h" / "−0.3 h".
    static func signedHours(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        let magnitude = String(format: "%.1f", abs(value))
        let sign = magnitude == "0.0" ? "±" : (value < 0 ? "−" : "+")
        return "\(sign)\(magnitude) h"
    }

    /// "+28m" / "−5m" / "±0m" (rebound differences).
    static func signedMinutes(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        let magnitude = minutes(abs(value))
        let rounded = Int(abs(value).rounded())
        let sign = rounded == 0 ? "±" : (value < 0 ? "−" : "+")
        return "\(sign)\(magnitude)"
    }

    /// Movement seconds per minute: "4.2 s/min".
    static func movement(_ value: Double?) -> String {
        guard let value, value.isFinite else { return missing }
        return String(format: "%.1f s/min", value)
    }

    /// "1.42 (IQR 0.21)".
    static func medianIqr(_ median: Double, _ iqr: Double?) -> String {
        let m = String(format: "%.2f", median)
        guard let iqr, iqr.isFinite else { return m }
        return "\(m) (IQR \(String(format: "%.2f", iqr)))"
    }
}

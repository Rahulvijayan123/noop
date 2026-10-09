import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Sleep tab cards (the overview and the analytics stack under the stages)
//
// One card per question, in the order the tab asks them: how much sleep (overview), was it unbroken
// (Continuity), is the schedule steady (Regularity), how did the body run in each stage (Physiology by
// stage), how fast did it settle (Falling asleep), how was breathing (Breathing).
//
// Sources, unchanged: the overview reads the night itself (asleep, the in-bed window, the efficiency the
// night page prints). Continuity's strip is the night's own raw stage segments; Regularity's chart is the
// last seven nights' main-night spans (`SleepView.mainNightSpan`, the bed/wake every screen reads). Every
// other figure is the server's `daily.sleep_features` for this night, read exactly as the night page's
// "Sleep details" reads it. A figure the document does not carry is a dash, never a zero, and a card whose
// block is unavailable says why in one line.

// MARK: Overview

/// Asleep, time in bed and efficiency for the night. (The in-bed window is in the stages card's header.)
struct SleepOverviewCard: View {
    let asleep: String?
    let inBed: String?
    let efficiency: String?
    var isLoading = false

    var body: some View {
        NoopCard {
            HStack(alignment: .top, spacing: 0) {
                stat("Asleep", asleep)
                divider
                stat("Time in bed", inBed)
                divider
                stat("Efficiency", efficiency)
            }
        }
        .redacted(reason: isLoading ? .placeholder : [])
        .accessibilityElement(children: .combine)
    }

    private var divider: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(width: 1, height: 40)
            .padding(.horizontal, NoopMetrics.space3)
    }

    private func stat(_ label: LocalizedStringKey, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(value ?? "–")
                .font(StrandFont.number(24))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Analytics stack

/// The four analytics cards for the night on screen. Owns its own load so a document landing re-renders
/// only this stack, never `SleepView`.
struct SleepTabAnalyticsStack: View {
    let night: Night
    let isStub: Bool
    /// Every recorded day's blocks, newest first (`SleepView.navDays`).
    let navDays: [[CachedSleepSession]]
    let habitualMidsleepSec: Int?
    var isLoading = false

    @EnvironmentObject private var repo: Repository
    @State private var load: SleepFeatureLoad = .loading
    @State private var loadedKey: String?
    @State private var assessment: BreathingRateAssessment?

    private var key: String { "\(night.session.effectiveStartTs)|\(night.session.endTs)|\(repo.refreshSeq)" }

    var body: some View {
        let state = isLoading ? .loading : load
        let breathing = state.night?.respiratoryVariability
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SleepContinuityCard(night: night, isStub: isStub, continuity: state.night?.continuity, state: state)
            SleepRegularityCard(nights: regularityNights, regularity: state.document?.regularity, state: state)
            SleepStagePhysiologyCard(physiology: state.night?.stagePhysiology, state: state)
            SleepBreathingCard(breathing: breathing, assessment: isLoading ? nil : assessment, state: state)
        }
        .task(id: "\(key)|\(breathing?.rateBpm ?? -1)") {
            assessment = BreathingRateAssessment.assess(
                wakeDay: SleepFormat.wakeDayKey(night.session.endTs), days: repo.days,
                sleepFeatureRate: breathing?.rateBpm)
        }
        .task(id: key) {
            // A refresh under the same night keeps the cards on screen while the new read lands.
            if loadedKey?.hasPrefix("\(night.session.effectiveStartTs)|\(night.session.endTs)|") != true {
                load = .loading
            }
            let result = await SleepFeatureLoad.fetch(startTs: night.session.effectiveStartTs,
                                                      endTs: night.session.endTs)
            guard !Task.isCancelled else { return }
            load = result
            loadedKey = key
        }
    }

    /// The seven calendar nights ending at this night's wake day, each as its main-night span (nil: no night).
    private var regularityNights: [SleepRegularityNight] {
        let cal = Calendar.current
        let wake = Date(timeIntervalSince1970: TimeInterval(night.session.endTs))
        return (0..<7).reversed().compactMap { back -> SleepRegularityNight? in
            guard let day = cal.date(byAdding: .day, value: -back, to: wake) else { return nil }
            let dayKey = Repository.localDayKey(day)
            let span = SleepModel.navIndex(wakeDay: dayKey, navDays: navDays)
                .flatMap { SleepView.mainNightSpan(navDays[$0], habitualMidsleepSec: habitualMidsleepSec) }
            return SleepRegularityNight(day: day, start: span?.start, end: span?.end)
        }
    }
}

/// The night's `daily.sleep_features` read: loading, the document (and this night inside it, when the
/// document has one), or why there is none.
enum SleepFeatureLoad {
    case loading
    case loaded(SleepFeatureDocument, SleepFeatureNight?)
    case unavailable(String)

    var document: SleepFeatureDocument? {
        if case .loaded(let d, _) = self { return d }
        return nil
    }

    var night: SleepFeatureNight? {
        if case .loaded(_, let n) = self { return n }
        return nil
    }

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }

    /// One line for a card whose block is missing: the block's own first reason when it has one, else
    /// why the whole document is missing.
    func message(reasons: [String]?) -> String {
        if let first = reasons?.first { return SleepFeatureWording.reason(first).capitalizedFirst }
        switch self {
        case .unavailable(let why): return why
        case .loaded(_, nil): return String(localized: "Not published for this night")
        default: return String(localized: "Not available for this night")
        }
    }

    /// The same read the night page's "Sleep details" makes: the cached server day, refreshed once when the
    /// cache has no sleep features.
    @MainActor
    static func fetch(startTs: Int, endTs: Int) async -> SleepFeatureLoad {
        guard CloudPushIdentityStore.current() != nil,
              let repository = CloudPushRuntime.shared.scoreRepository() else {
            return .unavailable(String(localized: "Needs cloud scoring"))
        }
        let day = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(endTs)))
        let deviceIds = await IntradaySeriesStore.shared.readCandidates
        var hosted = await repository.cachedDay(day: day, deviceIds: deviceIds)?.hostedResult
        if hosted?.sleepFeatures == nil {
            do {
                hosted = try await repository.refresh(day: day, deviceIds: deviceIds).hostedResult
            } catch {
                if hosted == nil { return .unavailable(String(localized: "Couldn't load. Pull to refresh.")) }
            }
        }
        guard let document = hosted?.sleepFeatures else {
            return .unavailable(String(localized: "Not published for this night yet"))
        }
        return .loaded(document, document.night(matchingStart: startTs, end: endTs))
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

// MARK: - Card chrome

/// The analytics cards' shared frame: the title row (with an optional legend), then the card's content.
private struct SleepAnalyticsCard<Trailing: View, Content: View>: View {
    let icon: String
    let title: LocalizedStringKey
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                HStack(spacing: NoopMetrics.space2) {
                    SleepCardTitle(icon: icon, title: title)
                    Spacer(minLength: NoopMetrics.space2)
                    trailing()
                }
                .frame(minHeight: 28)
                content()
            }
        }
    }
}

private extension SleepAnalyticsCard where Trailing == EmptyView {
    init(icon: String, title: LocalizedStringKey, @ViewBuilder content: @escaping () -> Content) {
        self.init(icon: icon, title: title, trailing: { EmptyView() }, content: content)
    }
}

/// A card's empty state: one line in the frame the content would fill.
private struct SleepCardMessage: View {
    let text: String
    var height: CGFloat = 72
    var body: some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textSecondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity, minHeight: height)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(StrandPalette.surfaceInset.opacity(0.5)))
    }
}

/// A row of two or three figures separated by hairlines (the Continuity and Falling asleep footers).
private struct SleepStatRow: View {
    let stats: [(value: String, label: LocalizedStringKey)]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(stats.indices, id: \.self) { i in
                if i > 0 {
                    Rectangle().fill(StrandPalette.hairline).frame(width: 1, height: 36)
                        .padding(.horizontal, NoopMetrics.space3)
                }
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(stats[i].value)
                        .font(StrandFont.number(20))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text(stats[i].label)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A coloured dot and a label (chart legends).
private struct SleepLegendItem: View {
    let color: Color
    let label: String
    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
    }
}

private enum SleepTabFormat {
    static func number(_ v: Double?, digits: Int = 0, suffix: String = "") -> String {
        guard let v, v.isFinite else { return "–" }
        return v.formatted(.number.precision(.fractionLength(digits))) + suffix
    }

    static func minutes(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        return SleepFormat.duration(v)
    }

    static func percent(_ v: Double?) -> String {
        guard let v, v.isFinite else { return "–" }
        return "\(Int(v.rounded()))%"
    }

    /// "10 PM" for an hour offset from the 18:00 anchor the regularity chart counts from.
    static func anchoredHour(_ offset: Int) -> String {
        let hour = ((18 + offset) % 24 + 24) % 24
        var c = DateComponents()
        c.hour = hour
        let date = Calendar.current.date(from: c) ?? Date()
        return date.formatted(.dateTime.hour())
    }
}

// MARK: - Continuity

/// The night as a barcode: each column is a slice of the in-bed window, tall and rose where any wake
/// fell inside it, short and lavender where it was all sleep, blank where nothing was recorded. Below
/// it the three continuity figures.
private struct SleepContinuityCard: View {
    let night: Night
    let isStub: Bool
    let continuity: SleepContinuity?
    let state: SleepFeatureLoad
    private var segments: [SleepInterval] { night.realSegments ?? [] }
    private var span: TimeInterval { TimeInterval(max(60, night.session.endTs - night.session.effectiveStartTs)) }

    var body: some View {
        SleepAnalyticsCard(icon: "waveform", title: "Continuity", trailing: {
            if segments.count >= 2 {
                HStack(spacing: NoopMetrics.space3) {
                    SleepLegendItem(color: StrandPalette.restColor, label: String(localized: "Asleep"))
                    SleepLegendItem(color: StrandPalette.metricRose, label: String(localized: "Awake"))
                }
            }
        }) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                if segments.count >= 2 {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        barcode.frame(height: 52)
                        HStack {
                            Text(Night.clockString(night.session.effectiveStartTs))
                            Spacer(minLength: 0)
                            Text(Night.clockString(night.session.endTs))
                        }
                        .font(NaraChartStyle.axisFont)
                        .foregroundStyle(NaraChartStyle.axisColor)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Sleep continuity strip"))
                    .accessibilityValue(Text("\(segments.filter { $0.stage == .awake }.count) awake segments"))
                } else {
                    SleepCardMessage(text: isStub
                                     ? String(localized: "No stage data recorded for this night.")
                                     : String(localized: "Stage totals only, no timeline"), height: 52)
                }
                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                if state.isLoading {
                    ChartPlaceholder(height: 40)
                } else if let c = continuity, c.recurrentAwakeningIndexPerH != nil
                            || c.longestSleepBoutMin != nil || c.sleepMaintenanceEfficiencyPct != nil {
                    SleepStatRow(stats: [
                        (SleepTabFormat.number(c.recurrentAwakeningIndexPerH, digits: 1), "Awakenings/hr"),
                        (SleepTabFormat.minutes(c.longestSleepBoutMin), "Longest stretch"),
                        (SleepTabFormat.percent(c.sleepMaintenanceEfficiencyPct), "Maintenance"),
                    ])
                } else {
                    SleepCardMessage(text: state.message(reasons: continuity?.reasons), height: 40)
                }
            }
        }
    }

    private var barcode: some View {
        Canvas { ctx, size in
            let pitch: CGFloat = 4.5
            let barW: CGFloat = 2.5
            let columns = max(1, Int(size.width / pitch))
            let step = span / Double(columns)
            let sleepH = size.height * 0.5
            for col in 0..<columns {
                let t0 = Double(col) * step, t1 = t0 + step
                let inside = segments.filter { $0.end > t0 && $0.start < t1 }
                guard !inside.isEmpty else { continue }
                let x = CGFloat(col) * pitch + (pitch - barW) / 2
                if inside.contains(where: { $0.stage == .awake }) {
                    ctx.fill(Path(roundedRect: CGRect(x: x, y: 0, width: barW, height: size.height), cornerRadius: 1.25),
                             with: .color(StrandPalette.metricRose))
                } else {
                    let rect = CGRect(x: x, y: (size.height - sleepH) / 2, width: barW, height: sleepH)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.25), with: .color(StrandPalette.restColor))
                }
            }
        }
    }
}

// MARK: - Regularity

/// One calendar night on the regularity chart: its main-night span, or nil when none was recorded.
struct SleepRegularityNight {
    let day: Date
    let start: Int?
    let end: Int?
}

/// The 7-day sleep regularity index, with each of the last seven nights as a bar from sleep onset to
/// final wake on one clock axis: steady bars mean a steady schedule.
private struct SleepRegularityCard: View {
    let nights: [SleepRegularityNight]
    let regularity: SleepRegularity?
    let state: SleepFeatureLoad
    /// Hours after 18:00 (so a night never wraps the axis): onset, then wake (past onset).
    private var spans: [(day: Date, onset: Double, wake: Double)?] {
        nights.map { n in
            guard let s = n.start, let e = n.end, e > s else { return nil }
            let onset = (SleepView.localClockHour(s) - 18 + 24).truncatingRemainder(dividingBy: 24)
            let wake = onset + Double(e - s) / 3600
            return (n.day, onset, wake)
        }
    }

    var body: some View {
        let sri = regularity?.sri7d
        let sriValue = sri?.status == .available ? sri?.value : nil
        SleepAnalyticsCard(icon: "calendar", title: "Regularity") {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline) {
                    if state.isLoading {
                        Text("00/100").font(StrandFont.number(28)).redacted(reason: .placeholder)
                    } else if let v = sriValue {
                        (Text(v.formatted(.number.precision(.fractionLength(0))))
                            .font(StrandFont.number(28))
                            .foregroundColor(StrandPalette.textPrimary)
                         + Text("/100")
                            .font(StrandFont.number(16))
                            .foregroundColor(StrandPalette.textSecondary))
                        .accessibilityLabel(Text("Regularity \(Int(v.rounded())) of 100"))
                    } else {
                        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                            Text("–").font(StrandFont.number(28)).foregroundStyle(StrandPalette.textPrimary)
                            Text(state.message(reasons: sri?.reasons ?? regularity?.reasons))
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(2)
                        }
                    }
                    Spacer(minLength: NoopMetrics.space2)
                    VStack(alignment: .trailing, spacing: NoopMetrics.space1) {
                        SleepLegendItem(color: StrandPalette.restColor,
                                        label: legend(String(localized: "Bedtime"), regularity?.clockProfile?.sleepOnset))
                        SleepLegendItem(color: StrandPalette.restBright,
                                        label: legend(String(localized: "Wake"), regularity?.clockProfile?.finalWake))
                    }
                }
                chart
            }
        }
    }

    private func legend(_ name: String, _ metric: SleepCircadianMetric?) -> String {
        guard let sd = metric?.circadianSdMin, sd.isFinite else { return name }
        return "\(name) ±\(Int(sd.rounded()))m"
    }

    @ViewBuilder
    private var chart: some View {
        let present = spans.compactMap { $0 }
        if present.isEmpty {
            SleepCardMessage(text: String(localized: "No nights recorded this week"), height: 110)
        } else {
            let lo = max(0, (Int((present.map(\.onset).min() ?? 4).rounded(.down)) / 2) * 2)
            let hiRaw = Int((present.map(\.wake).max() ?? 16).rounded(.up))
            let hi = max(lo + 4, ((hiRaw + 1) / 2) * 2)
            let ticks = stride(from: lo, through: hi, by: max(2, ((hi - lo) / 4 + 1) / 2 * 2)).map { $0 }
            let plotH: CGFloat = 104
            HStack(alignment: .top, spacing: NoopMetrics.space2) {
                ZStack(alignment: .topLeading) {
                    ForEach(ticks, id: \.self) { t in
                        Text(SleepTabFormat.anchoredHour(t))
                            .font(NaraChartStyle.axisFont)
                            .foregroundStyle(NaraChartStyle.axisColor)
                            .fixedSize()
                            .position(x: 20, y: plotH * CGFloat(t - lo) / CGFloat(hi - lo))
                    }
                }
                .frame(width: 40, height: plotH)
                VStack(spacing: NoopMetrics.space1) {
                    Canvas { ctx, size in
                        let w = size.width, h = size.height
                        func y(_ hours: Double) -> CGFloat { h * CGFloat((hours - Double(lo)) / Double(hi - lo)) }
                        for t in ticks {
                            var p = Path()
                            p.move(to: CGPoint(x: 0, y: y(Double(t)))); p.addLine(to: CGPoint(x: w, y: y(Double(t))))
                            ctx.stroke(p, with: .color(NaraChartStyle.gridColor), style: NaraChartStyle.grid)
                        }
                        let colW = w / CGFloat(max(1, spans.count))
                        for (i, span) in spans.enumerated() {
                            guard let span else { continue }
                            let cx = colW * (CGFloat(i) + 0.5)
                            let y0 = y(span.onset), y1 = y(span.wake)
                            let capsule = CGRect(x: cx - 5, y: y0, width: 10, height: max(10, y1 - y0))
                            ctx.fill(Path(roundedRect: capsule, cornerRadius: 5),
                                     with: .color(StrandPalette.restColor.opacity(0.22)))
                            ctx.fill(Path(ellipseIn: CGRect(x: cx - 5, y: y0 - 5, width: 10, height: 10)),
                                     with: .color(StrandPalette.restColor))
                            ctx.fill(Path(ellipseIn: CGRect(x: cx - 5, y: y1 - 5, width: 10, height: 10)),
                                     with: .color(StrandPalette.restBright))
                        }
                    }
                    .frame(height: plotH)
                    HStack(spacing: 0) {
                        ForEach(nights.indices, id: \.self) { i in
                            Text(nights[i].day.formatted(.dateTime.weekday(.abbreviated)))
                                .font(NaraChartStyle.axisFont)
                                .foregroundStyle(spans[i] == nil ? StrandPalette.textTertiary : NaraChartStyle.axisColor)
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            .padding(.vertical, 6)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Bedtime and wake time, last seven nights"))
            .accessibilityValue(Text(nights.compactMap { n -> String? in
                guard let s = n.start, let e = n.end else { return nil }
                return "\(n.day.formatted(.dateTime.weekday(.wide))) \(Night.clockString(s)) to \(Night.clockString(e))"
            }.joined(separator: ", ")))
        }
    }
}

// MARK: - Physiology by stage

/// Heart rate, RMSSD and SDNN in light, deep and REM sleep as one matrix; each bar is the cell against the
/// highest stage in its row.
private struct SleepStagePhysiologyCard: View {
    let physiology: SleepStagePhysiology?
    let state: SleepFeatureLoad
    private struct Row {
        let icon: String
        let title: LocalizedStringKey
        let unit: String
        let value: (SleepStagePhysiologyMetrics) -> Double?
    }

    private let rows: [Row] = [
        Row(icon: "heart", title: "Heart rate", unit: "bpm", value: { $0.hrMedianBpm }),
        Row(icon: "waveform.path.ecg", title: "RMSSD", unit: "ms", value: { $0.rmssdMs?.median }),
        Row(icon: "chart.bar", title: "SDNN", unit: "ms", value: { $0.sdnnMs?.median }),
    ]
    private let stages: [SleepStage] = [.light, .deep, .rem]

    private func metrics(_ stage: SleepStage) -> SleepStagePhysiologyMetrics? {
        switch stage {
        case .light: return physiology?.light
        case .deep: return physiology?.deep
        case .rem: return physiology?.rem
        case .awake: return physiology?.wake
        }
    }

    var body: some View {
        let hasAny = rows.contains { r in stages.contains { s in metrics(s).flatMap(r.value) != nil } }
        let thin = stages.contains { metrics($0)?.thinData == true }
        SleepAnalyticsCard(icon: "heart.text.square", title: "Physiology by stage") {
            if state.isLoading {
                ChartPlaceholder(height: 150)
            } else if hasAny {
                VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                    matrix
                    if thin {
                        Text("Faded cells: few minutes of that stage")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
            } else {
                SleepCardMessage(text: state.message(reasons: physiology?.reasons), height: 150)
            }
        }
    }

    private var matrix: some View {
        Grid(alignment: .leading, horizontalSpacing: NoopMetrics.space3, verticalSpacing: 0) {
            GridRow {
                Color.clear.frame(width: 1, height: 1)
                ForEach(stages, id: \.self) { stage in
                    HStack(spacing: 5) {
                        Circle().fill(StrandPalette.sleepStageColor(stage)).frame(width: 8, height: 8)
                        Text(stage.label)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(1)
                    }
                    .padding(.bottom, NoopMetrics.space2)
                }
            }
            ForEach(rows.indices, id: \.self) { i in
                let row = rows[i]
                let values = stages.map { metrics($0).flatMap(row.value) }
                let peak = values.compactMap { $0 }.max() ?? 0
                Divider().overlay(StrandPalette.hairline).gridCellUnsizedAxes(.horizontal)
                GridRow {
                    HStack(spacing: NoopMetrics.space2) {
                        Image(systemName: row.icon)
                            .font(StrandFont.icon(.inline))
                            .foregroundStyle(StrandPalette.restBright)
                            .frame(width: 18)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(row.title)
                                .font(StrandFont.footnote.weight(.medium))
                                .foregroundStyle(StrandPalette.textPrimary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                            Text(row.unit)
                                .font(StrandFont.caption)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    ForEach(stages.indices, id: \.self) { j in
                        cell(values[j], peak: peak, stage: stages[j], thin: metrics(stages[j])?.thinData == true)
                    }
                }
                .padding(.vertical, NoopMetrics.space2)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(row.title))
                .accessibilityValue(Text(stages.indices.map { j in
                    "\(stages[j].label) \(values[j].map { "\(Int($0.rounded())) \(row.unit)" } ?? String(localized: "not available"))"
                }.joined(separator: ", ")))
            }
        }
    }

    private func cell(_ value: Double?, peak: Double, stage: SleepStage, thin: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(SleepTabFormat.number(value))
                .font(StrandFont.number(18))
                .foregroundStyle(StrandPalette.textPrimary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    if let value, peak > 0 {
                        Capsule().fill(StrandPalette.sleepStageColor(stage))
                            .frame(width: geo.size.width * CGFloat(min(1, value / peak)))
                    }
                }
            }
            .frame(height: 6)
        }
        .opacity(thin ? 0.5 : 1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Breathing

/// How the night's breathing rate sits against the normal adult range and the wearer's own usual.
///
/// The rate judged is the night's daily breathing rate (`DailyMetric.respRateBpm`), the figure the Readiness
/// respiratory signal grades, so the ring and that signal cannot disagree. The usual is the same reference
/// Readiness uses: `BaselineStandard.windowReference` over the 30 calendar days before the night (robust
/// median, 1.4826·MAD scale floored at 0.3 br/min, confounded days out), values outside the plausible
/// sleeping band (`SleepStager.respPlausibleRangeBpm`, 8–25) excluded. Its z grades the deviation with the
/// Readiness thresholds: 1.5 is "slightly raised", 2.0 is "raised". The range check uses the resting adult
/// norm of 12–20 breaths per minute.
///
/// When the night has no daily rate, the server's estimate is judged against the range alone (it comes from a
/// different method, so it is never compared with a daily-rate usual).
struct BreathingRateAssessment: Equatable {
    enum Level: Equatable { case good, watch, concern }

    let rate: Double
    /// The usual rate, nil until the reference has `BaselineStandard.minUsableDays` nights.
    let usual: Double?
    let baselineNights: Int
    /// The ring's fill, 0.25 (concerning) to 1 (good).
    let fill: Double
    let level: Level
    /// One line: why the ring is filled the way it is.
    let reason: String

    static let normalRange: ClosedRange<Double> = 12...20
    static let baselineWindowDays = 30

    var statusWord: String {
        switch level {
        case .good: return String(localized: "Typical")
        case .watch: return String(localized: "Slightly off")
        case .concern: return String(localized: "Unusual")
        }
    }

    static func assess(wakeDay: String, days: [DailyMetric], sleepFeatureRate: Double?) -> BreathingRateAssessment? {
        let plausible = SleepStager.respPlausibleRangeBpm
        let daily = days.last(where: { $0.day == wakeDay })?.respRateBpm.flatMap { plausible.contains($0) ? $0 : nil }
        guard let rate = daily ?? sleepFeatureRate.flatMap({ $0.isFinite && $0 > 0 ? $0 : nil }) else { return nil }

        var usual: Double?
        var nights = 0
        var z: Double?
        if daily != nil {
            let series = BaselineStandard.series(days.filter { plausible.contains($0.respRateBpm ?? -1) },
                                                 day: \.day, value: \.respRateBpm)
            let ref = BaselineStandard.windowReference(series, metric: .respiration, asOf: wakeDay,
                                                       windowDays: baselineWindowDays,
                                                       context: BaselineStandard.Context.app())
            nights = ref.n
            if ref.usable, plausible.contains(ref.centerNative) {
                usual = ref.centerNative
                z = ref.z(rate)
            }
        }

        // Range: 1 inside 12–20, easing to 0.5 at the plausible band's edges, 0.25 beyond it.
        let rangeScore: Double = {
            if normalRange.contains(rate) { return 1 }
            guard plausible.contains(rate) else { return 0.25 }
            if rate > normalRange.upperBound {
                return 1 - 0.5 * (rate - normalRange.upperBound) / (plausible.upperBound - normalRange.upperBound)
            }
            return 1 - 0.5 * (normalRange.lowerBound - rate) / (normalRange.lowerBound - plausible.lowerBound)
        }()
        // Baseline: a rise is graded on the Readiness thresholds; an unusually low night is flagged softly.
        let baselineScore: Double = {
            guard let z else { return 1 }
            if z <= 1.0 { return z <= -2 ? 0.75 : 1 }
            if z <= 1.5 { return 1 - 0.25 * (z - 1.0) / 0.5 }
            if z <= 2.0 { return 0.75 - 0.25 * (z - 1.5) / 0.5 }
            return max(0.25, 0.5 - 0.25 * (z - 2.0))
        }()
        let fill = min(1, max(0.25, min(rangeScore, baselineScore)))
        let level: Level = fill >= 0.95 ? .good : (fill >= 0.7 ? .watch : .concern)

        let usualText = usual.map { $0.formatted(.number.precision(.fractionLength(1))) }
        let reason: String
        if baselineScore < rangeScore, let z, let usualText {
            if z < 0 {
                reason = String(localized: "Below your usual \(usualText) br/min")
            } else {
                reason = level == .concern
                    ? String(localized: "Raised vs your usual \(usualText) br/min")
                    : String(localized: "Slightly above your usual \(usualText) br/min")
            }
        } else if rangeScore < 1 {
            reason = rate > normalRange.upperBound
                ? String(localized: "Above the 12–20 br/min adult range")
                : String(localized: "Below the 12–20 br/min adult range")
        } else if let usualText {
            reason = String(localized: "In the adult range, near your usual \(usualText)")
        } else if daily != nil {
            reason = String(localized: "In the adult range. Learning your usual (\(nights) of \(BaselineStandard.minUsableDays) nights)")
        } else {
            reason = String(localized: "In the 12–20 br/min adult range")
        }
        return BreathingRateAssessment(rate: rate, usual: usual, baselineNights: nights, fill: fill, level: level,
                                       reason: reason)
    }
}

/// The night's breathing rate in a ring filled by how typical it is (range and personal usual), beside how
/// much breath intervals varied and the range most of them fell in.
private struct SleepBreathingCard: View {
    let breathing: SleepRespiratoryVariability?
    let assessment: BreathingRateAssessment?
    let state: SleepFeatureLoad

    private static let accent = StrandPalette.restBright

    private var levelColor: Color {
        switch assessment?.level {
        case .watch?: return StrandPalette.metricAmber
        case .concern?: return StrandPalette.metricRose
        default: return Self.accent
        }
    }

    var body: some View {
        let b = breathing
        let hasDetails = b?.sdIntervalS != nil || b?.intervalDistribution?.p10S != nil
        SleepAnalyticsCard(icon: "lungs", title: "Breathing") {
            if state.isLoading && assessment == nil {
                ChartPlaceholder(height: 130)
            } else if assessment != nil || hasDetails {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    HStack(alignment: .center, spacing: NoopMetrics.space4) {
                        ring
                        VStack(alignment: .leading, spacing: 0) {
                            if state.isLoading {
                                ChartPlaceholder(height: 96)
                            } else if let b, hasDetails {
                                variabilityRow(b)
                                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                                rangeRow(b)
                            } else {
                                Text(state.message(reasons: b?.reasons))
                                    .font(StrandFont.footnote)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .padding(.vertical, NoopMetrics.space3)
                            }
                        }
                        .padding(.horizontal, NoopMetrics.space3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StrandPalette.surfaceInset.opacity(0.6)))
                    }
                    if let assessment {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Circle().fill(levelColor).frame(width: 7, height: 7)
                            Text(assessment.reason)
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if hasDetails {
                        Text("Breath intervals are estimated from the heart-rate rhythm, not measured airflow")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                SleepCardMessage(text: state.message(reasons: b?.reasons), height: 130)
            }
        }
    }

    private var ring: some View {
        let fill = assessment?.fill ?? 0
        return VStack(spacing: NoopMetrics.space1) {
            ZStack {
                Circle().stroke(StrandPalette.surfaceInset, lineWidth: 10)
                if assessment != nil {
                    Circle()
                        .trim(from: 0, to: CGFloat(fill))
                        .stroke(levelColor, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                VStack(spacing: 0) {
                    Text(SleepTabFormat.number(assessment?.rate, digits: 1))
                        .font(StrandFont.number(26))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .minimumScaleFactor(0.7)
                    Text("br/min")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .frame(width: 104, height: 104)
            Text(assessment?.statusWord ?? " ")
                .font(StrandFont.footnote.weight(.medium))
                .foregroundStyle(assessment == nil ? StrandPalette.textTertiary : levelColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Breathing rate"))
        .accessibilityValue(Text(assessment.map {
            "\($0.rate.formatted(.number.precision(.fractionLength(1)))) breaths per minute, \($0.statusWord). \($0.reason)"
        } ?? String(localized: "Not available")))
    }

    private func variabilityRow(_ b: SleepRespiratoryVariability) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Variability")
                    .font(StrandFont.footnote.weight(.medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("interval SD")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 5) {
                Text(b.sdIntervalS.map { "\($0.formatted(.number.precision(.fractionLength(2)))) s" } ?? "–")
                    .font(StrandFont.number(17))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let cv = b.cvInterval, cv.isFinite {
                    // The bar is the coefficient of variation on a 0–100 % track (its own unit, no invented scale).
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(StrandPalette.surfaceRaised)
                            Capsule().fill(Self.accent).frame(width: geo.size.width * CGFloat(min(1, max(0, cv))))
                        }
                    }
                    .frame(width: 64, height: 5)
                    Text("CV \(Int((cv * 100).rounded()))%")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .padding(.vertical, NoopMetrics.space2)
        .accessibilityElement(children: .combine)
    }

    private func rangeRow(_ b: SleepRespiratoryVariability) -> some View {
        let d = b.intervalDistribution
        let p10 = d?.p10S, p90 = d?.p90S
        let band = b.supportedRange?.detectorBandBpm ?? []
        let track: ClosedRange<Double>? = {
            if band.count == 2, let lo = band.min(), let hi = band.max(), lo > 0 { return (60 / hi)...(60 / lo) }
            if let lo = d?.p05S, let hi = d?.p95S, hi > lo { return (lo * 0.8)...(hi * 1.2) }
            return nil
        }()
        return HStack(alignment: .center, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Interval range")
                    .font(StrandFont.footnote.weight(.medium))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("middle 80%, s")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                Text(p10 != nil && p90 != nil
                     ? "\(p10!.formatted(.number.precision(.fractionLength(1))))–\(p90!.formatted(.number.precision(.fractionLength(1))))"
                     : "–")
                    .font(StrandFont.number(17))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let p10, let p90, let track, track.upperBound > track.lowerBound {
                    Canvas { ctx, size in
                        func x(_ v: Double) -> CGFloat {
                            size.width * CGFloat(min(1, max(0, (v - track.lowerBound) / (track.upperBound - track.lowerBound))))
                        }
                        let mid = size.height / 2
                        var base = Path()
                        base.move(to: CGPoint(x: 0, y: mid)); base.addLine(to: CGPoint(x: size.width, y: mid))
                        ctx.stroke(base, with: .color(StrandPalette.surfaceRaised), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        var seg = Path()
                        seg.move(to: CGPoint(x: x(p10), y: mid)); seg.addLine(to: CGPoint(x: x(p90), y: mid))
                        ctx.stroke(seg, with: .color(Self.accent), style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        for v in [p10, p90] {
                            ctx.fill(Path(ellipseIn: CGRect(x: x(v) - 4, y: mid - 4, width: 8, height: 8)), with: .color(Self.accent))
                        }
                    }
                    .frame(width: 64, height: 10)
                }
            }
        }
        .padding(.vertical, NoopMetrics.space2)
        .accessibilityElement(children: .combine)
    }
}


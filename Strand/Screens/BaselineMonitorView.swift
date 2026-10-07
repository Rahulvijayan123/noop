import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics
import WhoopStore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Monitor: Watchdog for the last half-hour, then the day-and-night usuals, then trends.
/// The homepage Baseline ring opens `.baseline` and shows only the usuals.
/// Treatment stays a separate caregiver screen. The plots themselves are unchanged.
struct BaselineMonitorView: View {
    enum Focus {
        /// Monitor tab: Watchdog, baseline, and trends.
        case monitor
        /// Homepage Baseline ring: the day-and-night usuals only.
        case baseline
    }

    var focus: Focus = .monitor
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var store: BaselineStore
    @EnvironmentObject var router: NavRouter

    private var days: [DailyMetric] { store.displayDays(from: repo.days) }

    var body: some View {
        ScreenScaffold(
            title: focus == .baseline ? "Baseline" : "Monitor",
            subtitle: focus == .baseline ? "Day and night usuals" : "Watchdog and baseline",
            onRefresh: { await repo.refresh(); store.rescore(days: days) },
            topBackground: liquidScaffoldSky(),
            trailing: {
                HStack(spacing: 14) {
                    ShareLink(item: store.clinicianExportText(deviceId: repo.deviceId)) {
                        Image(systemName: "square.and.arrow.up")
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                    .accessibilityLabel("Share 7-day summary for a clinician")
                    HeaderSettingsButton()
                }
            }
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if focus == .monitor {
                    NaraSectionHeader(
                        title: "Watchdog",
                        subtitle: "Last 30 minutes. Separate from Charge."
                    )
                    WatchdogPlaceholderView(embedded: true)
                    NaraSectionHeader(
                        title: "Baseline",
                        subtitle: "Day and night usuals. This week, and the longer copy."
                    )
                }
                monitorCard
                if focus == .monitor {
                    NaraSectionHeader(
                        title: "Trends",
                        subtitle: "Charge, effort, and the other vitals over weeks and months."
                    )
                    TrendsView(embedded: true)
                }
            }
        }
        .onAppear {
            let tape = days
            if store.evaluation == nil, let last = tape.last?.day {
                store.asOf = last
                store.longAsOf = last
            }
            store.rescore(days: tape)
        }
    }

    private var usualsReady: Bool {
        (store.evaluation?.show7 == true) || store.longCopyForPlot() != nil
    }

    private var monitorCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                Text("Long-term baseline")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                seriesHeader
                SegmentedPillControl(BaselineStore.ContextFilter.allCases,
                                     selection: Binding(
                                        get: { store.context },
                                        set: { store.selectContext($0, days: days) }
                                     ),
                                     adaptsToAvailableWidth: true) { $0.rawValue }
                metricChips
                if usualsReady {
                    BaselineCopyPlot(
                        heading: "Short-term usual · this week",
                        methodNote: "Day by day. Green band is this week’s usual. Last night is on the right; it is not folded into the usual.",
                        boxTitle: "THIS WEEK",
                        unit: store.series.planRow.unit,
                        points: store.weekPoints,
                        copy: store.evaluation?.copy7,
                        show: store.evaluation?.show7 ?? false,
                        trust: store.shortConfidence,
                        howOff: store.shortHowOff,
                        verdict: store.shortVerdict,
                        yDomain: shortY,
                        xTickStyle: .daily,
                        navigator: .init(
                            label: store.asOfLabel,
                            atOldest: !store.canShift(-1, days: days),
                            atNewest: !store.canShift(1, days: days),
                            back: { store.shiftDay(-1, days: days) },
                            forward: { store.shiftDay(1, days: days) }
                        )
                    )
                    BaselineCopyPlot(
                        heading: store.evaluation?.trial.card.slowTitle ?? "Longer usual",
                        methodNote: store.evaluation?.slopeUsable == true
                            ? "Longer usual may drift slowly. A short spike is not."
                            : "Week by week. Each step rebuilds the 60-day median for that week.",
                        boxTitle: store.longBoxTitle,
                        unit: store.series.planRow.unit,
                        points: store.longPoints,
                        copy: store.longCopyForPlot(),
                        show: store.longCopyForPlot() != nil,
                        trust: store.longConfidence,
                        howOff: nil,
                        verdict: store.longVerdict,
                        yDomain: longY,
                        xTickStyle: .weekly,
                        navigator: .init(
                            label: store.longAsOfLabel,
                            atOldest: !store.canShiftLongWeek(-1, days: days),
                            atNewest: !store.canShiftLongWeek(1, days: days),
                            back: { store.shiftLongWeek(-1, days: days) },
                            forward: { store.shiftLongWeek(1, days: days) }
                        )
                    )
                    if store.evaluation?.trial.trialFreezeOk == true {
                        trialBlock
                    }
                } else {
                    notEnoughNightsBox
                }
                treatmentBridge
                Text("Not a diagnosis. Separate from Charge.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var notEnoughNightsBox: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.line.uptrend.xyaxis")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.accent)
                .frame(width: 22)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not enough days yet")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(store.nightsNeeded(for: store.series) > 0
                     ? "\(store.shortTitle(for: store.series)) needs \(store.nightsNeeded(for: store.series)) more night\(store.nightsNeeded(for: store.series) == 1 ? "" : "s") for a week usual. Other vitals that are ready stay on the chips."
                     : "There aren’t enough days to calculate this vital yet. Other vitals that are ready stay on the chips.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .fill(StrandPalette.surfaceInset.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("There aren’t enough days to calculate the baseline yet")
    }

    private var seriesHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(store.series.planRow.planName)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(store.quietRangeCaption)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
            if store.isExploratory(store.series) {
                Text("EXPLORATORY")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .tracking(0.8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 28, alignment: .leading)
    }

    private var treatmentBridge: some View {
        Button { router.openTreatment() } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "cross.case")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.activeStart.map { "Course · \($0.bannerName)" } ?? "Treatment")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(2)
                        .minimumScaleFactor(0.85)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(store.activeStart == nil
                         ? "Log a start so Baseline can freeze the untreated usual."
                         : store.medicationLabelToday.wearerLine)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Text("Open")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(StrandPalette.surfaceInset.opacity(0.65))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open Treatment")
    }

    private var trialBlock: some View {
        let tr = store.evaluation?.trial
        return VStack(alignment: .leading, spacing: 10) {
            if let banner = tr?.card.banner {
                Text(banner)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    trialColumn("EXPECTED WITHOUT TREATMENT",
                                value: tr?.expectedUntreatedDisplay)
                    trialColumn(tr?.displayName.map { "ON \($0.uppercased())" } ?? "ON TREATMENT",
                                value: store.evaluation?.copyLong?.centerDisplay)
                    trialColumn("TODAY",
                                value: store.evaluation?.todayNative)
                }
                VStack(alignment: .leading, spacing: 12) {
                    trialColumn("EXPECTED WITHOUT TREATMENT",
                                value: tr?.expectedUntreatedDisplay)
                    trialColumn(tr?.displayName.map { "ON \($0.uppercased())" } ?? "ON TREATMENT",
                                value: store.evaluation?.copyLong?.centerDisplay)
                    trialColumn("TODAY",
                                value: store.evaluation?.todayNative)
                }
            }
            if store.evaluation?.trial.phase == .washingOut, let days = tr?.washoutDaysUsed {
                Text("Washing out — you entered \(days) days after last dose.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if store.evaluation?.trial.tooEarly == true {
                Text("Too early to judge a response.")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            if let line = tr?.summarySentence {
                Text(line)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let ghost = tr?.gapVsFlatDisplay, tr?.flatModelOnly != true {
                Text(String(format: "Vs the old flat usual it would look like %.1f %@.",
                            ghost, store.series.planRow.unit))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if tr?.flatModelOnly == true {
                Text("Not enough pre-start trend to project; comparing to the usual level only.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Text(tr?.disclaimer.isEmpty == false ? (tr?.disclaimer ?? "") : LongitudinalBaseline.reviewDisclaimer)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(StrandPalette.surfaceInset.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
        )
    }

    private func trialColumn(_ title: String, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .tracking(0.5)
                .lineLimit(2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
            Text(value.map { BaselineMonitorView.format($0, unit: "") } ?? "—")
                .font(StrandFont.rounded(20, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            Text(store.series.planRow.unit)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var shortY: ClosedRange<Double> {
        BaselinePlotScale.yDomain(
            values: store.weekPoints.compactMap(\.value),
            bandLo: store.evaluation?.copy7?.bandLoDisplay,
            bandHi: store.evaluation?.copy7?.bandHiDisplay)
    }

    private var longY: ClosedRange<Double> {
        let copy = store.longCopyForPlot()
        return BaselinePlotScale.yDomain(
            values: store.longPoints.compactMap(\.value),
            bandLo: copy?.bandLoDisplay,
            bandHi: copy?.bandHiDisplay)
    }

    private var metricChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(store.displayedSeries, id: \.rawValue) { s in
                    let on = store.series == s
                    Button { store.selectSeries(s, days: days) } label: {
                        HStack(spacing: 4) {
                            Text(store.shortTitle(for: s))
                            if store.isExploratory(s) {
                                Text("EXPLORATORY")
                                    .font(StrandFont.caption.weight(.semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                        }
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        .opacity(store.seriesReadiness[s]?.ready == true ? 1 : 0.55)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(on ? StrandPalette.accent.opacity(0.12) : StrandPalette.surfaceInset,
                                    in: Capsule())
                        .overlay(Capsule().strokeBorder(on ? StrandPalette.accent.opacity(0.45)
                                                        : StrandPalette.hairline, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    static func format(_ value: Double, unit: String) -> String {
        if unit.isEmpty {
            return value >= 100 ? String(format: "%.0f", value) : String(format: "%.1f", value)
        }
        if unit == "steps" { return String(format: "%.0f %@", value, unit) }
        if unit == "g" { return String(format: "%.2f %@", value, unit) }
        return String(format: "%.1f %@", value, unit)
    }
}

struct BaselineCopyPlot: View {
    struct Navigator {
        var label: String
        var atOldest: Bool
        var atNewest: Bool
        var back: () -> Void
        var forward: () -> Void
    }

    enum TickStyle {
        case daily
        case weekly
    }

    let heading: String
    let methodNote: String
    let boxTitle: String
    let unit: String
    let points: [BaselinePlotPoint]
    let copy: LBCopySnapshot?
    let show: Bool
    var confidence: Int? = nil
    var trust: Int? = nil
    var howOff: Int? = nil
    var verdict: String? = nil
    let yDomain: ClosedRange<Double>
    let xTickStyle: TickStyle
    var navigator: Navigator? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(heading)
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(methodNote)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .frame(maxWidth: .infinity, minHeight: 34, alignment: .topLeading)
            HStack(alignment: .center, spacing: 16) {
                if let navigator {
                    navRow(navigator)
                        .frame(minHeight: 44, alignment: .center)
                }
                Spacer(minLength: 16)
                rangeBoxSlot
            }
            chart
                .frame(height: 148)
            if outlierCount > 0 {
                Text(outlierCount == 1
                     ? "1 night outside this usual’s range"
                     : "\(outlierCount) nights outside this usual’s range")
                    .font(StrandFont.caption)
                    .foregroundStyle(outlierCaptionColor)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if points.contains(where: \.explained) {
                Text("Grey nights have a logged event. They stay visible and are not used to judge a treatment response.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private var rangeBoxSlot: some View {
        Group {
            if let copy, show {
                rangeBox(copy)
            } else {
                Color.clear
            }
        }
        .frame(width: 152, alignment: .topLeading)
    }

    private func navRow(_ nav: Navigator) -> some View {
        HStack(spacing: 8) {
            Button(action: nav.back) {
                Image(systemName: "chevron.left")
                    .font(StrandFont.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(nav.atOldest ? StrandPalette.textTertiary : StrandPalette.accent)
            .disabled(nav.atOldest)
            Text(nav.label)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Button(action: nav.forward) {
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption.weight(.semibold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(nav.atNewest ? StrandPalette.textTertiary : StrandPalette.accent)
            .disabled(nav.atNewest)
        }
    }

    private func rangeBox(_ copy: LBCopySnapshot) -> some View {
        let off = rangeBoxOffStrength(copy)
        let fill = off.map { baselineOffColor($0).opacity(0.16) } ?? StrandPalette.statusPositive.opacity(0.12)
        let stroke = off.map { baselineOffColor($0).opacity(0.45) } ?? StrandPalette.statusPositive.opacity(0.4)
        return VStack(alignment: .leading, spacing: 4) {
            Text(boxTitle)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
                .tracking(0.8)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
                .fixedSize(horizontal: false, vertical: true)
            Text(BaselinePlotScale.formatTick(copy.centerDisplay, domain: yDomain))
                .font(StrandFont.rounded(22, weight: .bold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("\(BaselinePlotScale.formatTick(copy.bandLoDisplay, domain: yDomain)) – \(BaselinePlotScale.formatTick(copy.bandHiDisplay, domain: yDomain)) \(unit)")
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .monospacedDigit()
                .lineLimit(2)
                .minimumScaleFactor(0.7)
                .fixedSize(horizontal: false, vertical: true)
            if let verdict {
                Text(verdict)
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(verdictColor(verdict, copy: copy))
                    .tracking(0.5)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            if let trust {
                Text("TRUST \(trust)%")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(confidenceColor(trust))
                    .tracking(0.6)
            }
            if let howOff, verdict != "NOT ENOUGH NIGHTS", verdict != "BUILDING" {
                Text("HOW OFF \(howOff)%")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .tracking(0.4)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 152, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(stroke, lineWidth: 1)
                )
        )
    }

    private func rangeBoxOffStrength(_ copy: LBCopySnapshot) -> Double? {
        guard let last = points.last(where: { $0.isScoredNight })?.value
                ?? points.last(where: { $0.value != nil })?.value else { return nil }
        return BaselineOffPaint.strength(value: last, lo: copy.bandLoDisplay, hi: copy.bandHiDisplay)
    }

    private func verdictColor(_ text: String, copy: LBCopySnapshot) -> Color {
        switch text {
        case "IN RANGE": return StrandPalette.statusPositive
        case "OFF":
            return rangeBoxOffStrength(copy).map(baselineOffColor) ?? StrandPalette.statusWarning
        case "WEAK SIGNAL", "NOT ENOUGH NIGHTS": return StrandPalette.textTertiary
        default: return StrandPalette.textSecondary
        }
    }

    private func confidenceColor(_ pct: Int) -> Color {
        if pct >= 70 { return StrandPalette.statusPositive }
        if pct >= 40 { return StrandPalette.textSecondary }
        return StrandPalette.statusWarning
    }

    private func pointColor(_ point: BaselinePlotPoint, value: Double) -> Color {
        if point.explained { return StrandPalette.textTertiary }
        if let copy, show,
           let strength = BaselineOffPaint.strength(value: value, lo: copy.bandLoDisplay, hi: copy.bandHiDisplay) {
            return baselineOffColor(strength)
        }
        return StrandPalette.textPrimary
    }

    private var outlierCaptionColor: Color {
        let strengths = points.compactMap { point -> Double? in
            guard !point.explained, let value = point.value, let copy, show else { return nil }
            return BaselineOffPaint.strength(value: value, lo: copy.bandLoDisplay, hi: copy.bandHiDisplay)
        }
        guard let worst = strengths.max() else { return StrandPalette.statusWarning }
        return baselineOffColor(worst)
    }

    private var outlierCount: Int {
        points.filter { !$0.explained && isOut($0.value) }.count
    }

    private func isOut(_ value: Double?) -> Bool {
        guard let copy, show, let value else { return false }
        return value > copy.bandHiDisplay || value < copy.bandLoDisplay
    }

    private var chart: some View {
        Chart {
            if let c = copy, show {
                ForEach(Array(points.enumerated()), id: \.element.id) { idx, _ in
                    AreaMark(
                        x: .value("Day", idx),
                        yStart: .value("Low", c.bandLoDisplay),
                        yEnd: .value("High", c.bandHiDisplay)
                    )
                    .foregroundStyle(StrandPalette.statusPositive.opacity(0.22))
                }
            }
            ForEach(Array(points.enumerated()), id: \.element.id) { idx, point in
                if let value = point.value {
                    LineMark(x: .value("Day", idx), y: .value(unit, value))
                        .foregroundStyle(StrandPalette.textPrimary.opacity(0.88))
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                    PointMark(x: .value("Day", idx), y: .value(unit, value))
                        .foregroundStyle(pointColor(point, value: value))
                        .symbolSize(point.explained || isOut(value) || point.isScoredNight ? 56 : 18)
                }
            }
        }
        .chartXScale(domain: 0...max(points.count - 1, 1))
        .chartYScale(domain: yDomain)
        .chartXAxis {
            AxisMarks(values: xTicks) { value in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.35))
                AxisValueLabel {
                    if let i = value.as(Int.self), points.indices.contains(i) {
                        Text(BaselinePlotScale.shortDate(points[i].day))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: BaselinePlotScale.ticks(in: yDomain)) { val in
                AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.35))
                AxisValueLabel {
                    if let d = val.as(Double.self) {
                        Text(BaselinePlotScale.formatTick(d, domain: yDomain))
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .monospacedDigit()
                    }
                }
            }
        }
        .chartPlotStyle { plot in
            plot.background(StrandPalette.surfaceInset.opacity(0.45)).clipped()
        }
        .accessibilityLabel("\(heading) in \(unit)")
    }

    private var xTicks: [Int] {
        let n = max(points.count - 1, 1)
        switch xTickStyle {
        case .daily:
            if n <= 6 { return Array(0...n) }
            return [0, n / 2, n]
        case .weekly:
            let step = n > 42 ? 14 : 7
            var ticks = Array(stride(from: 0, through: n, by: step))
            if ticks.last != n { ticks.append(n) }
            return ticks
        }
    }
}

struct BaselineDayLogSheet: View {
    @EnvironmentObject var store: BaselineStore
    var days: [DailyMetric]
    @State private var mood: LBDayMood = .okay
    @State private var activeWindow: LBActiveWindow = .spread
    @State private var workout: LBWorkoutLoad = .none
    @State private var energy: LBDayEnergy = .steady
    @State private var demand: LBDayDemand = .usual
    @State private var alcohol = false
    @State private var travel = false
    @State private var feltIll = false
    @State private var extraMed = false
    @State private var scheduledMed: LBScheduledMedStatus = .unspecified
    @State private var sleepTypical = true
    @State private var dietTypical = true

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Eight questions. Same ones every day, whether the night looked usual or not.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(BaselinePlotScale.mediumDate(store.loggingDay))
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textTertiary)
                    question(1, "How was your mood today?") {
                        pillRow(LBDayMood.allCases, selection: $mood, label: { $0.displayLabel })
                    }
                    question(2, "When were you most active?") {
                        pillRow(LBActiveWindow.allCases, selection: $activeWindow, label: { $0.displayLabel })
                    }
                    question(3, "How hard was activity today?") {
                        pillRow(LBWorkoutLoad.allCases, selection: $workout, label: { $0.displayLabel })
                    }
                    question(4, "How did energy feel through the day?") {
                        pillRow(LBDayEnergy.allCases, selection: $energy, label: { $0.displayLabel })
                    }
                    question(5, "How demanding was the day besides the workout?") {
                        pillRow(LBDayDemand.allCases, selection: $demand, label: { $0.displayLabel })
                    }
                    question(6, "Was eating typical for you?") {
                        pillRow([true, false], selection: $dietTypical, label: { $0 ? "Typical" : "Not typical" })
                    }
                    question(7, "Anything that stood out?") {
                        VStack(alignment: .leading, spacing: 10) {
                            if store.activeStart != nil {
                                Text("Scheduled course")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                                pillRow(LBScheduledMedStatus.allCases.filter { $0 != .unspecified } + [.unspecified],
                                        selection: $scheduledMed, label: { $0.displayLabel })
                            }
                            VStack(spacing: 0) {
                                toggle("Alcohol", $alcohol)
                                toggle("Travel", $travel)
                                toggle("Felt ill", $feltIll)
                                toggle("Another medication", $extraMed)
                            }
                        }
                    }
                    question(8, "Was last night’s sleep typical for you?") {
                        pillRow([true, false], selection: $sleepTypical, label: { $0 ? "Typical" : "Not typical" })
                    }
                    NoopButton("Save daily log", systemImage: "checkmark") {
                        let log = LBDayLog(workout: workout, alcohol: alcohol, travel: travel,
                                           feltIll: feltIll, sleepTypical: sleepTypical,
                                           dietTypical: dietTypical, extraMed: extraMed,
                                           scheduledMed: scheduledMed, mood: mood,
                                           activeWindow: activeWindow, energy: energy, demand: demand)
                        store.setDayLog(log, on: store.loggingDay, days: days)
                    }
                }
                .padding(NoopMetrics.cardInnerSpacing)
            }
            .navigationTitle("Daily log")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { store.showContextSheet = false }
                }
            }
            .onAppear {
                if let log = store.loggingLog {
                    mood = log.mood
                    activeWindow = log.activeWindow
                    workout = log.workout
                    energy = log.energy
                    demand = log.demand
                    alcohol = log.alcohol
                    travel = log.travel
                    feltIll = log.feltIll
                    extraMed = log.extraMed
                    scheduledMed = log.scheduledMed
                    sleepTypical = log.sleepTypical
                    dietTypical = log.dietTypical
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 560)
        #endif
    }

    private func question<Content: View>(_ n: Int, _ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(n)  \(title)")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            content()
        }
    }

    private func pillRow<T: Hashable>(_ items: [T], selection: Binding<T>, label: @escaping (T) -> String) -> some View {
        let rows = items.chunked(by: 3)
        return VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { i in
                HStack(spacing: 8) {
                    ForEach(rows[i], id: \.self) { item in
                        let on = selection.wrappedValue == item
                        Button {
                            selection.wrappedValue = item
                        } label: {
                            Text(label(item))
                                .font(StrandFont.caption.weight(.semibold))
                                .foregroundStyle(on ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.75)
                                .padding(.vertical, 10)
                                .padding(.horizontal, 8)
                                .frame(maxWidth: .infinity)
                                .background(on ? StrandPalette.statusPositive.opacity(0.18) : StrandPalette.surfaceInset,
                                            in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private func toggle(_ title: String, _ value: Binding<Bool>) -> some View {
        Button {
            value.wrappedValue.toggle()
        } label: {
            HStack {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Image(systemName: value.wrappedValue ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(value.wrappedValue ? StrandPalette.statusPositive : StrandPalette.textTertiary)
            }
            .padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

private extension Array {
    func chunked(by size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        var out: [[Element]] = []
        var i = startIndex
        while i < endIndex {
            let j = index(i, offsetBy: size, limitedBy: endIndex) ?? endIndex
            out.append(Array(self[i..<j]))
            i = j
        }
        return out
    }
}

func baselineOffColor(_ strength: Double) -> Color {
    let t = min(1, max(0, strength))
    #if canImport(UIKit)
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    UIColor(StrandPalette.statusWarning).getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    UIColor(StrandPalette.statusCritical).getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t,
                 blue: b1 + (b2 - b1) * t, opacity: a1 + (a2 - a1) * t)
    #elseif canImport(AppKit)
    guard let from = NSColor(StrandPalette.statusWarning).usingColorSpace(.sRGB),
          let to = NSColor(StrandPalette.statusCritical).usingColorSpace(.sRGB) else {
        return t < 0.5 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    }
    return Color(red: from.redComponent + (to.redComponent - from.redComponent) * t,
                 green: from.greenComponent + (to.greenComponent - from.greenComponent) * t,
                 blue: from.blueComponent + (to.blueComponent - from.blueComponent) * t,
                 opacity: from.alphaComponent + (to.alphaComponent - from.alphaComponent) * t)
    #else
    return t < 0.5 ? StrandPalette.statusWarning : StrandPalette.statusCritical
    #endif
}

/// Compact Baseline entry used on Today once usuals exist. No single biometric.
struct BaselineTodayPeek: View {
    var liquid: Bool = false
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var store: BaselineStore
    @EnvironmentObject var router: NavRouter

    private var days: [DailyMetric] { store.displayDays(from: repo.days) }

    var body: some View {
        Button { router.openBaseline() } label: {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: "rectangle.split.2x1")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 22)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text("LIVE BASELINE")
                        .font(StrandFont.overline)
                        .tracking(1.4)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Text(store.usualsReadyCaption)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Open for right now and your usuals.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
            .padding(liquid ? 16 : 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open live baseline")
        .onAppear {
            let tape = days
            if store.evaluation == nil, let last = tape.last?.day {
                store.asOf = last
                store.longAsOf = last
            }
            store.rescore(days: tape)
        }
    }

    @ViewBuilder private var surface: some View {
        if liquid {
            NoopPanelSurface(cornerRadius: 22)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(StrandPalette.surfaceInset.opacity(0.8))
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
        }
    }
}

/// Prominent Today CTA for the evening daily log.
struct DayLogTodayButton: View {
    var liquid: Bool = false
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var store: BaselineStore

    private var logged: Bool { store.calendarTodayLog != nil }

    var body: some View {
        Button {
            store.openDayLog(on: store.calendarTodayKey)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: logged ? "checkmark.circle.fill" : "square.and.pencil")
                    .font(StrandFont.headline)
                    .foregroundStyle(logged ? StrandPalette.statusPositive : StrandPalette.accent)
                    .frame(width: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text(logged ? "Daily log saved" : "Daily log")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(logged
                         ? (store.calendarTodayLog?.summaryLine ?? "Tap to change today’s label.")
                         : "Eight questions · labels the day for your usual.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(liquid ? 16 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                if liquid {
                    NoopPanelSurface(tint: StrandPalette.accent, cornerRadius: 22)
                } else {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(StrandPalette.accent.opacity(0.12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .strokeBorder(StrandPalette.accent.opacity(0.35), lineWidth: 1)
                        )
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(logged ? "Change daily log" : "Open daily log")
    }
}

#Preview {
    BaselineMonitorView()
        .environmentObject(Repository(deviceId: "preview"))
        .environmentObject(BaselineStore())
        .environmentObject(NavRouter())
}

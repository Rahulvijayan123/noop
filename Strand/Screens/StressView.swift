import SwiftUI
import Foundation
import StrandDesign
import StrandAnalytics
import WhoopStore

/// The shared explanation for an activity-masked gap on the Stress screen and hosted Today cards.
/// Whole-phrase singular/plural variants keep the sentence natural in every catalog locale.
func stressActivityMaskedHoursCaption(_ count: Int) -> String? {
    guard count > 0 else { return nil }
    return count == 1
        ? String(localized: "1 hour excluded — you were moving.")
        : String(localized: "\(count) hours excluded — you were moving.")
}

// MARK: - Stress Monitor
//
// A clear, Whoop-style "Stress Monitor": one 0–3 number, a band (Low/Medium/High),
// and a single plain-English line on *why*. The score is a transparent proxy for
// autonomic load.
//
// Source of the daily 0–3 value, in priority order:
//   1. The persisted `stress` metric series ("my-whoop") via `repo.series` — if a
//      day has a stored stress value we trust it.
//   2. Otherwise we DERIVE it from how today's resting HR / HRV sit against a
//      personal 30-day baseline. Stress shows up as HIGHER resting HR and LOWER
//      HRV, so we sum two z-scores and squash onto 0–3 with a logistic curve:
//
//        zRHR = (todayRHR − meanRHR) / sdRHR        // positive when RHR is UP
//        zHRV = (meanHRV − todayHRV) / sdHRV        // positive when HRV is DOWN
//        raw  = zRHR + zHRV                          // combined autonomic load
//        stress = 3 / (1 + e^(−raw))                // 0 calm · 1.5 baseline · 3 high
//
// Bands:  0–1 Low · 1–2 Medium · 2–3 High.
//
// Everything is computed live from `repo.days` (+ the stored series), so the math
// is fully inspectable — see the "How this is computed" disclosure at the bottom.
//
// The page follows the detail-page anatomy (docs/DESIGN_SYSTEM.md): one readout (score and band word,
// once), the range control, day stress as band-coloured bars on the fixed 0–3 axis, today's timeline as
// an interactive intraday chart with the day's split below it, the statistics, the two markers, and the
// method in About.

struct StressView: View {
    @EnvironmentObject var repo: Repository

    /// The stored 0–3 stress series ("my-whoop"), oldest→newest. Empty → derive.
    @State private var storedSeries: [(day: String, value: Double)] = []
    @State private var loaded = false
    /// History window for the daily chart (W/M/3M/6M/Y/All).
    @State private var range: ChartRange = .month
    /// The day under the finger on the daily chart; nil reads the latest day.
    @State private var selectedDay: Date?
    /// The time under the finger on today's timeline; nil reads the peak.
    @State private var selectedTime: Date?

    /// Today's intraday stress read (hourly timeline + sustained-high flag), computed
    /// from the day's banked HR + R-R via the SAME 0–3 proxy the daily score uses. Nil
    /// until the async read completes; `.empty` when the day has no usable intraday HR.
    @State private var daytime: DaytimeStress.Result?
    /// Whether TODAY's intraday timeline is scored against the PERSONAL cross-day daytime baseline
    /// (`.baselineRelative`, once enough worn history exists) instead of the day's own calm hours
    /// (`.dayRelative`). Drives only the explanatory copy — the 0–3 scale + bands are identical either way.
    @State private var daytimeUsesPersonalBaseline = false
    /// Drives the Breathe sheet presented from the sustained-stress suggestion.
    @State private var showBreathe = false

    /// ADDITIVE, on-demand advanced readouts, computed live from the SAME day's R-R the
    /// daytime timeline already reads. These do NOT feed the 0..3 score or the timeline; they
    /// are two extra, clearly-labelled HRV lenses surfaced in their own disclosure. Nil until the
    /// async read completes, and individually nil when their span/beat gates are not met.
    /// Baevsky Stress Index components (si / Mo / AMo / MxDMn).
    @State private var stressIndex: StressIndex.Components?
    /// Frequency-domain HRV bands (LF / HF / LF-HF / total power).
    @State private var freqHRV: HRVFreqDomain.Bands?

    /// Cached StressModel + the input signature it was built from. Rebuilding the
    /// model is expensive (z-score derivation + per-day date parsing over the full
    /// history), so we recompute it only when its inputs actually change — NOT on
    /// every body re-eval (scrub / 1 Hz HR ticks).
    @State private var model: StressModel?
    @State private var modelSignature: StressInputs?

    /// The real layout is drawn redacted until both the stored series and the history have loaded.
    private var isLoading: Bool { !loaded || !repo.loaded }

    var body: some View {
        // The detail-page anatomy (docs/DESIGN_SYSTEM.md): readout, range, the daily chart, today's
        // timeline, the statistics, the two markers, then the method in About. One layout in every
        // state: loading redacts it, an empty history shows the empty message inside the chart frames.
        let points = dailyPoints
        let span = InsightsRanges.span(firstDay: points.first?.day)
        let shownRange = InsightsRanges.effective(range, span: span)
        ScreenScaffold(title: "Stress", titleDisplay: .navigationBar, isLoading: isLoading, lazy: true) {
            readout(points: points, range: shownRange)
            RangeControl(insightsSelection: $range, span: span)
            dailyCard(points: points, range: shownRange)
            todaySection
            if let daytime, daytime.sustainedHigh {
                sustainedBreatheNotice(daytime)
            }
            StatGrid(stats(points: points, range: shownRange), isLoading: isLoading)
            markersSection
            if hasAdvancedReadouts {
                advancedDisclosure
            }
            AboutDisclosure("How this is computed", paragraphs: aboutParagraphs)
        }
        .onAppear { rebuildModelIfNeeded() }
        .onChangeCompat(of: repo.days) { _ in rebuildModelIfNeeded() }
        .onChangeCompat(of: range) { _ in selectedDay = nil }
        .task(id: repo.refreshSeq) { await load() }
        // The sustained-stress suggestion opens the existing Breathe trainer in a sheet —
        // in-app and passive (no alert / notification), inheriting the app environment.
        .sheet(isPresented: $showBreathe) {
            NavigationStack {
                BreathingView()
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showBreathe = false }
                                .foregroundStyle(StrandPalette.accent)
                        }
                    }
            }
            #if os(macOS)
            .frame(width: 520, height: 760)
            #endif
        }
    }

    private func load() async {
        storedSeries = await repo.series(key: "stress", source: "my-whoop")
        loaded = true
        rebuildModelIfNeeded()
        await loadDaytime()
    }

    /// Read TODAY's banked HR + R-R and build the intraday stress timeline. Local-day
    /// window [midnight, now]; the helper buckets it into waking hours and reuses the
    /// daily score's math, so this is the same proxy at a finer grain — never a new score.
    private func loadDaytime() async {
        let cal = Calendar.current
        let startOfDay = cal.startOfDay(for: Date())
        let from = Int(startOfDay.timeIntervalSince1970)
        let to = Int(Date().timeIntervalSince1970)
        let tz = TimeZone.current.secondsFromGMT(for: Date())

        let hr = await repo.hrSamples(from: from, to: to, limit: 200_000)
        // Too few HR samples: empty the timeline AND clear the advanced readouts in lockstep. Without this
        // reset a later refresh that hits this path would leave the Advanced HRV card showing stale values
        // next to an empty timeline (the readouts are only recomputed past this guard).
        guard hr.count >= DaytimeStress.minHourHRSamples else {
            daytime = .empty
            stressIndex = nil
            freqHRV = nil
            return
        }
        let rr = await repo.rrIntervals(from: from, to: to, limit: 200_000)
        // Wrist accelerometer for the motion gate: an ambulatory hour is EXERTION, not stress, so it
        // is masked rather than scored (DaytimeStress). Same store read as R-R; empty on hardware or
        // imports with no gravity, which is exactly the "no masking, prior behaviour" degradation.
        let gravity = await repo.gravitySamplesUnion(from: from, to: to, limit: 200_000)

        // Score today's hours against the PERSONAL cross-day daytime baseline ONLY when the user has
        // opted in (Settings → Experimental) AND enough worn history exists (Oura-style
        // `.baselineRelative`), else the day's own calm hours (`.dayRelative`, the default). The opt-in
        // gate is deliberate: the validated r≈0.6 margin is single-subject so far (#463), so this stays a
        // chooseable lens, not a silent default. The mode is resolved only AFTER the HR-count guard above,
        // so the trailing-history reads are never paid on a day with no scorable timeline — and are never
        // paid at all while the toggle is OFF (the default), keeping the read byte-identical to before.
        let mode = await DaytimeStressMode.selected(
            repo: repo,
            startOfToday: startOfDay,
            calendar: cal,
            personalBaseline: PuffinExperiment.stressPersonalBaselineEnabled
        )
        if case .baselineRelative = mode { daytimeUsesPersonalBaseline = true }
        else { daytimeUsesPersonalBaseline = false }
        // includeTimeline: the SLIDING read, so the screen's line moves in half-hours instead of
        // stepping through whole clock hours (#2144). The scored unit is still a full hour; this only
        // decides how often that hour is re-read, so a thin ten minutes costs the windows that overlap
        // it rather than a whole hour of chart. The Today card and the widget have always asked for
        // this; the screen people actually study was the one still stepping. Twin of the Kotlin change.
        // #2181: this is pure, database-free computation over a whole local day of samples, and it used
        // to run inline on this view's (main) actor. `analyze` memoises behind a lock-guarded
        // `AnalyticsMemoCache`, so it is safe off the main actor and the Today card already reads its own
        // stress the same way. Moving it here is what lets the timeline be published — and drawn — before
        // the advanced readouts below are started.
        //
        // `runUnescalated`, NOT `await Task.detached(...).value`: awaiting a task from a @MainActor
        // caller makes it a child and hands it the caller's priority, so a `.utility` label on a
        // detached task is decorative and the work races the UI for cores anyway. StressDayCurve
        // learned that on this same issue; the continuation in UnescalatedWork is what keeps the
        // priority honest.
        daytime = await runUnescalated(priority: .userInitiated) {
            DaytimeStress.analyze(hr: hr, rr: rr, gravity: gravity, tzOffsetSeconds: tz, mode: mode,
                                  includeTimeline: true)
        }

        // ADDITIVE advanced readouts, computed on-demand from the SAME `rr` (no extra fetch, no
        // DB / schema change, and no effect on the 0..3 score above). Each engine returns nil when
        // its own gate is not met (Baevsky needs >= 20 clean beats; freq-HRV needs >= 60 s span),
        // in which case its row is simply hidden.
        // A SECOND hop on purpose (#2181). `HRVFreqDomain` is a Lomb-Scargle periodogram: its cost is
        // (clean beats x frequency-grid steps) with a transcendental per step, and it takes whatever beat
        // count the day's read returned — the store read above is bounded at 200 000, this is not bounded
        // at all. On a live-banked day that is seconds of arithmetic, and run inline it held the main
        // thread for all of them, which is why the screen stayed blank rather than drawing the timeline it
        // already had. Both engines are pure statics over the same `rr`, so they compute together off the
        // main actor and publish when done; their card is hidden until then, exactly as it is when a gate
        // is unmet. Same `runUnescalated` reasoning as above, and the default `.utility` is real here
        // because nothing escalates it: this is the phase that must yield to the UI.
        let advanced = await runUnescalated {
            (index: StressIndex.components(rr: rr), freq: HRVFreqDomain.freqDomain(rr: rr))
        }
        stressIndex = advanced.index
        freqHRV = advanced.freq
    }

    /// Recompute the cached `StressModel` only when (repo.days, storedSeries)
    /// actually changed since the last build. Equality is an O(n) value compare,
    /// far cheaper than the model rebuild it guards.
    private func rebuildModelIfNeeded() {
        let signature = StressInputs(days: repo.days, stored: storedSeries)
        guard signature != modelSignature else { return }
        modelSignature = signature
        model = StressModel(days: repo.days, stored: storedSeries)
    }

    // MARK: Daily history

    /// The daily proxy history as chart points. `fullTrend` dates are the stored day keys parsed at UTC
    /// midnight, so they are moved to the same local day (never one day early west of UTC).
    private var dailyPoints: [DailyPoint] {
        (model?.fullTrend ?? []).map { DailyPoint($0, dayIsUTC: true) }
    }

    /// The window the daily chart and the statistics cover.
    private func window(points: [DailyPoint], range: ChartRange) -> ClosedRange<Date> {
        ChartAxis.window(range, firstDataDay: points.first?.day)
    }

    /// The readout above the chart: the bar under the finger, else the latest one, with its band word and
    /// the window's average as context.
    @ViewBuilder
    private func readout(points: [DailyPoint], range: ChartRange) -> some View {
        let bin = range.totalsBin
        let bars = DailyBarChart.bin(points, by: bin, aggregation: .mean)
        let shown = selectedDay == nil
            ? bars.last
            : ChartSelection.point(for: selectedDay, in: bars, unit: bin)
        ValueReadout(.daily(selection: selectedDay, in: bars, bin: bin,
                            unit: String(localized: "of 3"),
                            format: { StressTrace.formatLevel($0) },
                            context: readoutContext(shown: shown, points: points, range: range)),
                     isScrubbing: selectedDay != nil, isLoading: isLoading)
    }

    private func readoutContext(shown: DailyPoint?, points: [DailyPoint], range: ChartRange) -> String? {
        guard let shown else { return nil }
        let band = StressBand(score: shown.value).title
        guard selectedDay == nil else { return band }
        let inWindow = points.filter { window(points: points, range: range).contains($0.day) }
        guard !inWindow.isEmpty else { return band }
        let avg = StressTrace.formatLevel(inWindow.map(\.value).reduce(0, +) / Double(inWindow.count))
        if let days = range.days {
            return "\(band) · " + String(localized: "\(days)-day avg \(avg)")
        }
        return "\(band) · " + String(localized: "avg \(avg)")
    }

    /// Day stress as bars on its fixed 0–3 scale, each in its band's colour, weekly or monthly means on
    /// the long ranges, the 7-day mean on daily bars.
    private func dailyCard(points: [DailyPoint], range: ChartRange) -> some View {
        let state: ChartState = isLoading ? .loading
            : (points.isEmpty ? .empty(String(localized: "No stress history yet")) : .ready)
        var legend = StressBand.allCases.map { ChartLegendItem(.swatch($0.color), $0.title) }
        if range.totalsBin == .day, points.count >= 3 {
            legend.append(ChartLegendItem(.line(NaraChartStyle.meanLineColor, dashed: true),
                                          String(localized: "7-day average")))
        }
        return NoopCard {
            DailyBarChart.scores(points, bands: StressBand.scoreBands, scale: 0...3, bin: range.totalsBin,
                                 legend: legend, state: state,
                                 window: window(points: points, range: range), xStyle: range.axisStyle,
                                 selection: $selectedDay, accessibilityTitle: String(localized: "Stress"))
        }
    }

    /// Average, calm share, high days and day count for the visible window.
    private func stats(points: [DailyPoint], range: ChartRange) -> [StatItem] {
        let w = window(points: points, range: range)
        let values = points.filter { w.contains($0.day) }.map(\.value)
        let avg = values.isEmpty ? nil : values.reduce(0, +) / Double(values.count)
        let calm = values.isEmpty ? nil
            : Int((Double(values.filter { StressBand(score: $0) == .low }.count) / Double(values.count) * 100).rounded())
        let high = values.filter { StressBand(score: $0) == .high }.count
        return [
            StatItem(String(localized: "Average"), value: avg.map { StressTrace.formatLevel($0) }, unit: String(localized: "of 3")),
            StatItem(String(localized: "Calm time"), value: calm.map { "\($0)" }, unit: "%"),
            StatItem(String(localized: "High days"), value: values.isEmpty ? nil : "\(high)"),
            StatItem(String(localized: "Days"), value: values.isEmpty ? nil : "\(values.count)"),
        ]
    }

    // MARK: Today's timeline (intraday, same 0–3 proxy)

    /// Today's waking hours as an interactive line on the 0–3 scale, the Low / Medium / High bands behind
    /// it and the hours masked for movement hatched, with the day's split into the three bands below.
    /// The frame is the same while the read runs, once it lands, and on a day with no scored hours.
    private var todaySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Today", trailing: daytime.flatMap { $0.scored.isEmpty ? nil : timelineTrailing($0) })
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    timelineLine
                    IntradayChart(samples: timelineSamples, bucketSeconds: DaytimeStress.timelineStepSeconds,
                                  color: StrandPalette.stressColor,
                                  bands: movingBands,
                                  valueBands: StressBand.allCases.map {
                                      .init(id: "\($0)", range: $0.range, color: $0.color, label: $0.title)
                                  },
                                  state: timelineState,
                                  window: wakingWindow,
                                  y: ChartValueAxis(unit: nil, domain: .fixed(0...3), ticks: [0, 1, 2, 3]),
                                  selection: $selectedTime,
                                  height: NoopMetrics.chartHeightSecondary,
                                  accessibilityTitle: String(localized: "Stress today"))
                    InsightsShareBar(segments: splitSegments)
                }
            }
        }
    }

    /// The day's scored hours split into the three bands (the same `StressTotals` the old tubes read).
    private var splitSegments: [InsightsShareBar.Segment] {
        let totals = StressTotals(hours: daytime?.hours ?? [])
        return StressBand.allCases.map { band in
            .init(id: "\(band)", label: band.title, value: Double(totals.hours(band)),
                  color: band.color, valueText: durationLabel(totals.hours(band)))
        }
    }

    private var timelineState: ChartState {
        guard let daytime, !isLoading else { return .loading }
        return daytime.scored.isEmpty ? .empty(String(localized: "No scored hours yet today")) : .ready
    }

    /// One line above the timeline: the point under the finger ("2:30 PM · 1.8 · Medium"), else the
    /// day's peak. Always one line, so scrubbing never moves the chart.
    private var timelineLine: some View {
        let text: String
        var color = StrandPalette.textSecondary
        if let selectedTime, let sample = ChartSelection.sample(for: selectedTime, in: timelineSamples) {
            text = "\(sample.time.formatted(date: .omitted, time: .shortened)) · \(StressTrace.formatLevel(sample.value)) · \(StressBand(score: sample.value).title)"
            color = StrandPalette.textPrimary
        } else if let peak = drawnPeak, let level = peak.level {
            // The peak of what is DRAWN, not of the whole hours (#2144). A sliding window can exceed both
            // hourly neighbours when the busy stretch straddles a boundary, so `day.peak` would caption the
            // line with a number below its visible maximum.
            text = String(localized: "peak \(StressTrace.formatLevel(level)) · \(hourLabel(peak.hour))")
        } else {
            text = " "
        }
        return Text(text)
            .font(StrandFont.captionNumber)
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .transaction { $0.animation = nil }
    }

    private var drawnPeak: DaytimeStress.HourPoint? {
        daytime?.timeline.filter { $0.level != nil }.max { ($0.level ?? 0) < ($1.level ?? 0) }
    }

    /// The SLIDING series (#2144): each scored window plotted at its centre (never past now), so the line
    /// moves in half-hours. Unscored windows are left out, so the line breaks across them.
    private var timelineSamples: [IntradayChart.Sample] {
        let now = Date()
        return (daytime?.timeline ?? []).compactMap { point in
            guard let level = point.level else { return nil }
            let centre = Date(timeIntervalSince1970: TimeInterval(point.startTs + DaytimeStress.bucketSeconds / 2))
            return IntradayChart.Sample(time: min(centre, now), value: level)
        }
    }

    /// Hours masked because you were moving, merged into runs and hatched on the timeline.
    private var movingBands: [IntradayChart.Band] {
        var bands: [IntradayChart.Band] = []
        var runStart: Int?
        var runEnd = 0
        for hour in (daytime?.hours ?? []) {
            if hour.maskedForActivity {
                if runStart == nil || hour.startTs > runEnd {
                    if let start = runStart { bands.append(movingBand(start, runEnd)) }
                    runStart = hour.startTs
                }
                runEnd = hour.startTs + DaytimeStress.bucketSeconds
            }
        }
        if let start = runStart { bands.append(movingBand(start, runEnd)) }
        return bands
    }

    private func movingBand(_ start: Int, _ end: Int) -> IntradayChart.Band {
        IntradayChart.Band(id: "moving-\(start)",
                           start: Date(timeIntervalSince1970: TimeInterval(start)),
                           end: Date(timeIntervalSince1970: TimeInterval(end)),
                           color: StrandPalette.textTertiary,
                           label: String(localized: "Moving"), hatched: true)
    }

    /// The waking day the timeline is scored over, today.
    private var wakingWindow: ClosedRange<Date> {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = cal.date(byAdding: .hour, value: DaytimeStress.wakingStartHour, to: today) ?? today
        let end = cal.date(byAdding: .hour, value: DaytimeStress.wakingEndHour + 1, to: today) ?? today
        return start...max(end, start.addingTimeInterval(3_600))
    }

    /// "avg 1.4 · 9h" summary for the timeline header, from the scored hours.
    private func timelineTrailing(_ day: DaytimeStress.Result) -> String {
        let n = day.scored.count
        guard let mean = day.dayMean else { return String(localized: "\(n)h") }
        return String(localized: "avg \(StressTrace.formatLevel(mean)) · \(n)h")
    }

    /// "—" when a band had no scored hours, else "N h" (each scored bucket is one hour).
    private func durationLabel(_ hours: Int) -> String {
        hours <= 0 ? "—" : String(localized: "\(hours) h")
    }

    /// The timeline's explanatory line, honest about WHICH reference each hour was scored against —
    /// the personal cross-day baseline (`.baselineRelative`) or the day's own calm hours (`.dayRelative`).
    private var daytimeTimelineCaption: String {
        daytimeUsesPersonalBaseline
            ? String(localized: "The line is each waking hour's 0-3 proxy, scored against your personal daytime baseline (how your own days usually run). The bar below splits your day into calm, moderate and high stress time.")
            : String(localized: "The line is each waking hour's 0-3 proxy, scored against your own calm hours today. The bar below splits your day into calm, moderate and high stress time.")
    }

    /// A passive, in-app nudge to run a Breathe session after a sustained high-stress run.
    /// No notification — just a notice with an action that opens the existing trainer.
    private func sustainedBreatheNotice(_ day: DaytimeStress.Result) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(spacing: NoopMetrics.space2) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(StrandFont.icon(.inline))
                        .foregroundStyle(StrandPalette.statusWarning)
                        .accessibilityHidden(true)
                    Text("Sustained high stress")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    StatePill("\(day.sustainedRun)h elevated", tone: .warning, showsDot: false)
                }
                Text("Your last \(day.sustainedRun) hours have stayed in the high band. A few minutes of paced breathing can help downshift your nervous system.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                NoopButton("Start a Breathe session", systemImage: "wind", kind: .secondary, fullWidth: true) {
                    showBreathe = true
                }
            }
        }
        .softCardTransition()
    }

    /// Hour-of-day label following the device's locale + 12-/24-hour preference ("2 PM" / "14 Uhr"),
    /// instead of a hard-coded English "am/pm" (which read "3 pm" for 24-hour locales like German).
    private func hourLabel(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        let date = Calendar.current.date(bySettingHour: h, minute: 0, second: 0, of: Date()) ?? Date()
        return date.formatted(.dateTime.hour())
    }

    // MARK: Markers (vs the 30-day baseline)

    /// Resting HR and HRV against their 30-day baseline, each opening its own detail page.
    private var markersSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Markers", trailing: String(localized: "vs 30-day baseline"))
            NoopListSection {
                MetricDetailLink(key: "rhr") {
                    NoopListRow(icon: "heart", iconColor: StrandPalette.metricRose, title: "Resting HR",
                                subtitle: markerDelta(model?.rhrDelta, unit: "bpm"),
                                value: model?.rhrToday.map { "\($0) bpm" } ?? "—")
                }
                NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                MetricDetailLink(key: "hrv") {
                    NoopListRow(icon: "waveform.path.ecg", iconColor: StrandPalette.metricPurple, title: "HRV",
                                subtitle: markerDelta(model?.hrvDelta, unit: "ms"),
                                value: model?.hrvToday.map { "\(Int($0.rounded())) ms" } ?? "—")
                }
            }
        }
    }

    /// The marker's move against its baseline as a signed number with its unit. NO TEXT for a missing
    /// delta, rather than a claim we cannot make (#2145): it is nil when today has no reading or there is
    /// no 30-day baseline to stand one against.
    private func markerDelta(_ delta: Double?, unit: String) -> String? {
        guard let delta else { return nil }
        guard abs(delta) >= 0.5 else { return String(localized: "at baseline") }
        return "\(delta > 0 ? "+" : "−")\(Int(abs(delta).rounded())) \(unit)"
    }

    // MARK: Advanced HRV readouts (additive, on-demand)
    //
    // Two extra lenses on the SAME day's R-R the timeline already reads, behind their own disclosure so
    // they are visibly separate from the 0..3 score. Each row is shown only when its engine produced a
    // value (the engines self-gate on clean-beat count / record span). Nothing here feeds the score.

    /// True when at least one advanced readout is presentable (an SI value, or an LF/HF ratio, or
    /// at least the HF power). Drives whether the disclosure is shown at all.
    private var hasAdvancedReadouts: Bool {
        if stressIndex != nil { return true }
        if let f = freqHRV, f.lfhf != nil || f.hf > 0 { return true }
        return false
    }

    private var advancedDisclosure: some View {
        AboutDisclosure("Advanced HRV") {
            // Baevsky Stress Index, a whole number; higher means a more rigid, stressed rhythm.
            if let si = stressIndex {
                InsightsValueRow(label: String(localized: "Baevsky Stress Index"), value: "\(Int(si.si.rounded()))")
            }
            // Frequency-domain HRV: prefer the LF/HF ratio; if the span was too short for LF (lfhf nil)
            // fall back to the HF (rest) band power so the lens still reads.
            if let f = freqHRV {
                if let ratio = f.lfhf {
                    InsightsValueRow(label: String(localized: "Autonomic balance (LF/HF)"),
                                     value: StressTrace.formatRatio(ratio))
                } else if f.hf > 0 {
                    InsightsValueRow(label: String(localized: "HF power"), value: "\(Int(f.hf.rounded()))", unit: "ms²")
                }
            }
            AboutParagraphs(advancedParagraphs)
        }
    }

    private var advancedParagraphs: [String] {
        var out: [String] = []
        if stressIndex != nil {
            out.append(String(localized: "Autonomic rigidity from your heart-rate rhythm. Higher means a more rigid, stressed rhythm."))
        }
        if let f = freqHRV {
            if f.lfhf != nil {
                out.append(String(localized: "Sympathetic vs parasympathetic tone from frequency-domain HRV. Higher leans sympathetic (stress-ward)."))
            } else if f.hf > 0 {
                out.append(String(localized: "Parasympathetic (rest) band of your HRV."))
            }
        }
        out.append(String(localized: "These are extra, on-demand HRV lenses computed from today's R-R intervals. They are informational and do not change the stress score above."))
        return out
    }

    // MARK: About (transparency)

    private var aboutParagraphs: [String] {
        var out: [String] = []
        if let model { out.append(model.explanation) }
        out.append(model?.usingStored == true
                   ? String(localized: "Today's value is your recorded daily stress score (0-3).")
                   : String(localized: "Stress is derived from two autonomic signals."))
        out.append(String(localized: "We compare today's resting heart rate and HRV to your own 30-day baseline. A higher-than-usual resting HR and a lower-than-usual HRV both push the score up, classic signs the body is activated. The combined shift is mapped onto a 0-3 scale: 0 is calm, 1.5 sits at your baseline, 3 is highly activated."))
        out.append(StressBand.allCases.map { "\($0.title) \($0.rangeText)" }.joined(separator: " · "))
        out.append(daytimeTimelineCaption)
        if let masked = stressActivityMaskedHoursCaption(daytime?.activityMaskedHours ?? 0) {
            out.append(masked)
        }
        return out
    }
}

// MARK: - Stress band

enum StressBand: CaseIterable {
    case low, medium, high

    init(score: Double) {
        switch score {
        case ..<1.0: self = .low
        case ..<2.0: self = .medium
        default:     self = .high
        }
    }

    var title: String {
        switch self {
        case .low:    return String(localized: "Low")
        case .medium: return String(localized: "Medium")
        case .high:   return String(localized: "High")
        }
    }

    var tone: StrandTone {
        switch self {
        case .low:    return .positive
        case .medium: return .warning
        case .high:   return .critical
        }
    }

    /// The band's colour on charts and the day's split: its tone's colour, so a band reads the same on
    /// the bars, the timeline's value bands and the split bar.
    var color: Color { tone.color }

    /// The band's span on the 0–3 scale, the same thresholds `init(score:)` applies.
    var range: ClosedRange<Double> {
        switch self {
        case .low:    return 0...1
        case .medium: return 1...2
        case .high:   return 2...3
        }
    }

    var rangeText: String {
        switch self {
        case .low:    return "0–1"
        case .medium: return "1–2"
        case .high:   return "2–3"
        }
    }

    /// The bands for the kit's bar chart, from the thresholds above (a value below 1 is Low, below 2
    /// Medium, else High), so the bars can never drift from the band word in the readout.
    static var scoreBands: ScoreBands {
        ScoreBands(allCases.map { band in
            ScoreBands.Band(upperBound: band == .high ? .infinity : band.range.upperBound,
                            color: band.color, name: band.title)
        })
    }
}

// MARK: - Stress ramp (the WHOOP Stress sweep: blue → green → amber)
//
// The Stress screen's one ramp. WHOOP has NO gold: calm reads as the link blue, a
// balanced day as positive green, and a high-stress day as warning amber. The
// semicircle gauge fill, the day autonomic-load line, the Calm/Moderate/High totals bar
// and the trend all sample this SAME ramp, so the colour language is identical across
// the screen. Never the gold or red→green recovery ramp.

enum StressRamp {
    /// Band anchors, lifted from the shared palette (no hard-coded hex). These are the
    /// blue / green / amber the totals legend and band dots use, kept in lock-step with
    /// the gauge gradient below.
    static let calm    = StrandPalette.accent         // #60A0E0 — calm WHOOP blue
    static let steady  = StrandPalette.statusPositive // #03E095 — balanced WHOOP green
    static let tense   = StrandPalette.statusWarning  // #F0A020 — high WHOOP amber

    /// The 3-stop gauge ramp, evenly spaced (blue → green → amber).
    static let stops: [Gradient.Stop] = [
        .init(color: calm,   location: 0.00),
        .init(color: steady, location: 0.50),
        .init(color: tense,  location: 1.00),
    ]

    /// The blue→green→amber gauge gradient, built from the WHOOP band anchors above.
    static let gradient = Gradient(stops: stops)

    /// Sample the ramp at a 0–3 stress score.
    static func color(_ score: Double) -> Color {
        StrandPalette.sample(stops: stops, at: min(max(score / 3.0, 0), 1))
    }
}

// MARK: - Stress model inputs (cache key)

/// An `Equatable` snapshot of everything `StressModel.init` reads, used to decide
/// when the cached model must be rebuilt. `DailyMetric` is already `Equatable`;
/// the stored series is a tuple array (not `Equatable`), so we mirror it into an
/// `Equatable` shape. Comparison is O(n) — cheap versus rebuilding the model.
private struct StressInputs: Equatable {
    let days: [DailyMetric]
    let stored: [StoredPoint]

    struct StoredPoint: Equatable {
        let day: String
        let value: Double
    }

    init(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        self.days = days
        self.stored = stored.map { StoredPoint(day: $0.day, value: $0.value) }
    }
}

// MARK: - Stress model (transparent: stored value OR z-score derivation)

struct StressModel {
    let score: Double            // 0–3 (today)
    let band: StressBand
    let explanation: String
    let rhrToday: Int?
    let hrvToday: Double?
    let rhrDelta: Double?        // today − baseline mean (bpm)
    let hrvDelta: Double?        // today − baseline mean (ms)
    let fullTrend: [TrendPoint]  // entire daily proxy history, oldest→newest
    let calmTimeValue: String    // e.g. "58%"
    let calmTimeCaption: String  // e.g. "of last 30 days"
    let usingStored: Bool        // true when today's value came from the stored series

    /// Last up-to-14 trend values, for the hero tile sparkline.
    var sparkValues: [Double] { Array(fullTrend.suffix(14)).map(\.value) }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Build from oldest→newest daily metrics plus any stored "stress" series.
    /// Returns nil only when there is no usable signal at all.
    init?(days: [DailyMetric], stored: [(day: String, value: Double)]) {
        // Stored values keyed by day, clamped to 0–3.
        let storedByDay: [String: Double] = Dictionary(
            stored.map { ($0.day, min(max($0.value, 0), 3)) },
            uniquingKeysWith: { _, b in b }
        )

        // Carry (#543): today's own row is often vitals-less until the overnight is analyzed —
        // especially right after an app update relaunches and re-runs the pass — so score the NEWEST
        // day that actually carries usable signal (RHR/HRV, or a stored/imported stress value) instead of
        // calibrating, the same last-night carry every other Today vital uses. The predicate mirrors the
        // storedToday||derived gate below, so an imported stress-only latest day is still honored (not
        // skipped). Falls back to the last row when no day has any signal (cold start).
        guard let idx = days.lastIndex(where: {
            $0.restingHr != nil || $0.avgHrv != nil || storedByDay[$0.day] != nil
        }) ?? days.indices.last
        else { return nil }   // no days at all
        let today = days[idx]

        // Baseline window: up to 30 days ending the day BEFORE the scored day, so it's measured
        // against its own recent past rather than itself.
        let baseline = idx > 0 ? Array(days[0..<idx].suffix(30)) : []

        let rhrBase = baseline.compactMap { $0.restingHr }.map(Double.init)
        let hrvBase = baseline.compactMap { $0.avgHrv }

        let meanRHR = StressMath.mean(rhrBase)
        let sdRHR   = StressMath.std(rhrBase, mean: meanRHR)
        let meanHRV = StressMath.mean(hrvBase)
        let sdHRV   = StressMath.std(hrvBase, mean: meanHRV)

        let rhrT = today.restingHr.map(Double.init)
        let hrvT = today.avgHrv

        // Resolve today's score: prefer a stored value, else derive.
        let derivedAvailable = (rhrT != nil && meanRHR != nil) || (hrvT != nil && meanHRV != nil)
        let storedToday = storedByDay[today.day]
        guard storedToday != nil || derivedAvailable else { return nil }

        let derivedToday: Double? = derivedAvailable
            ? StressMath.squash(StressMath.rawScore(
                rhrToday: rhrT, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: hrvT, meanHRV: meanHRV, sdHRV: sdHRV))
            : nil

        let s = storedToday ?? derivedToday ?? 1.5
        self.usingStored = storedToday != nil
        self.score = s
        self.band = StressBand(score: s)
        self.rhrToday = today.restingHr
        self.hrvToday = hrvT
        self.rhrDelta = (rhrT != nil && meanRHR != nil) ? (rhrT! - meanRHR!) : nil
        self.hrvDelta = (hrvT != nil && meanHRV != nil) ? (hrvT! - meanHRV!) : nil

        self.explanation = StressMath.explanation(
            band: self.band,
            rhrDelta: self.rhrDelta,
            hrvDelta: self.hrvDelta,
            usingStored: self.usingStored
        )

        // Full daily proxy history: stored value if present for the day, else the
        // z-score derivation against the SAME baseline so the line is comparable.
        var pts: [TrendPoint] = []
        for d in days {
            guard let date = Self.dayParser.date(from: d.day) else { continue }
            if let v = storedByDay[d.day] {
                pts.append(TrendPoint(date: date, value: v))
                continue
            }
            let dRHR = d.restingHr.map(Double.init)
            let dHRV = d.avgHrv
            guard (dRHR != nil && meanRHR != nil) || (dHRV != nil && meanHRV != nil) else { continue }
            let r = StressMath.rawScore(
                rhrToday: dRHR, meanRHR: meanRHR, sdRHR: sdRHR,
                hrvToday: dHRV, meanHRV: meanHRV, sdHRV: sdHRV
            )
            pts.append(TrendPoint(date: date, value: StressMath.squash(r)))
        }
        self.fullTrend = pts

        // "Calm time": share of the last 30 charted days that sat in the LOW band.
        let recent = Array(pts.suffix(30))
        if recent.isEmpty {
            self.calmTimeValue = "—"
            self.calmTimeCaption = String(localized: "needs history")
        } else {
            let calm = recent.filter { $0.value < 1.0 }.count
            let pct = Int((Double(calm) / Double(recent.count) * 100).rounded())
            self.calmTimeValue = "\(pct)%"
            self.calmTimeCaption = String(localized: "low-stress days · \(recent.count)d")
        }
    }
}

// MARK: - Stress math (pure, testable helpers)

enum StressMath {
    static func mean(_ xs: [Double]) -> Double? {
        guard !xs.isEmpty else { return nil }
        return xs.reduce(0, +) / Double(xs.count)
    }

    /// Population standard deviation; 0 when there's no spread.
    static func std(_ xs: [Double], mean m: Double?) -> Double {
        guard let m, xs.count > 1 else { return 0 }
        let v = xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count)
        return v.squareRoot()
    }

    /// Combined autonomic z-score. RHR-up and HRV-down both push it positive.
    static func rawScore(
        rhrToday: Double?, meanRHR: Double?, sdRHR: Double,
        hrvToday: Double?, meanHRV: Double?, sdHRV: Double
    ) -> Double {
        var sum = 0.0
        if let r = rhrToday, let m = meanRHR, sdRHR > 0.0001 {
            sum += (r - m) / sdRHR            // up = stress
        }
        if let h = hrvToday, let m = meanHRV, sdHRV > 0.0001 {
            sum += (m - h) / sdHRV            // down = stress
        }
        return sum
    }

    /// Logistic squash of the raw z-sum onto 0–3 (baseline 0 → 1.5).
    static func squash(_ raw: Double) -> Double {
        let s = 3.0 / (1.0 + exp(-raw))
        return min(max(s, 0), 3)
    }

    static func explanation(band: StressBand, rhrDelta: Double?, hrvDelta: Double?, usingStored: Bool) -> String {
        let rhrUp = (rhrDelta ?? 0) > 1.0
        let rhrDn = (rhrDelta ?? 0) < -1.0
        let hrvUp = (hrvDelta ?? 0) > 1.0
        let hrvDn = (hrvDelta ?? 0) < -1.0

        switch band {
        case .high:
            if rhrUp && hrvDn {
                return String(localized: "Resting HR is elevated and HRV is below your baseline, both classic signs of high activation. Prioritise rest, hydration and an easy day.")
            } else if hrvDn {
                return String(localized: "HRV has dropped well below your baseline, pointing to elevated stress or fatigue. Ease off and give your body time to recover.")
            } else if rhrUp {
                return String(localized: "Resting heart rate is running high versus your norm. Your body is under load today. Keep effort light.")
            }
            return String(localized: "Your autonomic markers are skewed toward stress today. Treat it as a recovery-focused day.")
        case .medium:
            if rhrUp || hrvDn {
                return rhrUp
                    ? String(localized: "Slightly off baseline (resting HR is a touch high), so you're moderately activated. Nothing alarming; just don't overreach.")
                    : String(localized: "Slightly off baseline (HRV is a little low), so you're moderately activated. Nothing alarming; just don't overreach.")
            }
            return String(localized: "You're sitting around your typical autonomic baseline: moderate stress, a normal, balanced day.")
        case .low:
            if rhrDn && hrvUp {
                return String(localized: "Resting heart rate is low and HRV is up. Your nervous system looks well-recovered and calm. A great day to push if you want to.")
            } else if hrvUp {
                return String(localized: "HRV is above baseline, a sign of a relaxed, well-recovered nervous system. Stress is low.")
            }
            return String(localized: "Resting heart rate and HRV are sitting at or below baseline: low physiological stress. You're in a calm, recovered state.")
        }
    }
}

// MARK: - Daytime autonomic-load line (README screen-9)
//
// The day's intraday stress proxy drawn as a smooth LINE across the waking hours, filled
// under the curve and stroked with the SAME 3-stop blue→green→amber WHOOP ramp as
// the gauge. Only scored hours contribute points (no-data hours are skipped, never a
// guessed value); the smooth line connects the ones we have. The y-axis is the 0–3 scale
// and a faint dashed mid-line marks the 1.5 baseline.

struct DaytimeLoadLine: View {
    let hours: [DaytimeStress.HourPoint]

    private let chartHeight: CGFloat = 78

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            // y maps a 0–3 level into the chart (0 at bottom), for the baseline rule below. The x
            // placement moved into `scoredRuns`, which needs it per point anyway.
            // (a closure, not a `func` — a `@ViewBuilder` closure can't contain declarations)
            let y: (Double) -> CGFloat = { level in h - h * CGFloat(min(max(level / 3.0, 0), 1)) }

            // Contiguous runs of scored hours. Built in a method, not here: this is a
            // `@ViewBuilder` closure and cannot hold statements.
            let runs = scoredRuns(width: w, height: h)

            ZStack {
                // Baseline (1.5 of 3) reference line.
                Path { p in
                    let yb = y(1.5)
                    p.move(to: CGPoint(x: 0, y: yb))
                    p.addLine(to: CGPoint(x: w, y: yb))
                }
                .stroke(StrandPalette.hairline, style: StrokeStyle(lineWidth: 1, dash: [3, 3]))

                // The ramp runs DOWN the chart, not across the day.
                //
                // It used to be `.leading` to `.trailing`, which painted the stress band colours along
                // the x-axis: a calm 9pm hour rendered amber and a tense 7am one blue, so the colour
                // said nothing about the score while looking exactly as though it did. Because y maps
                // the 0-3 level onto the chart, a vertical ramp makes vertical position the level, which
                // is what the Kotlin twin does and what the legend claims. Amber at the top, blue at the
                // bottom: `StressRamp.gradient` runs calm-first, so it is reversed here.
                let levelRamp = LinearGradient(
                    gradient: Gradient(colors: Array(StressRamp.stops.map(\.color).reversed())),
                    startPoint: .top, endPoint: .bottom
                )
                ForEach(Array(runs.enumerated()), id: \.offset) { _, seg in
                    if seg.count >= 2 {
                        // Closed PER RUN, so the wash cannot spread under an hour that was never scored
                        // and undo the gap the broken line just drew.
                        areaPath(seg, width: w, height: h)
                            .fill(
                                LinearGradient(
                                    gradient: Gradient(colors: [
                                        StressRamp.calm.opacity(0.22),
                                        StressRamp.calm.opacity(0.02),
                                    ]),
                                    startPoint: .top, endPoint: .bottom
                                )
                            )
                        linePath(seg)
                            .stroke(levelRamp,
                                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    } else if let only = seg.first {
                        // A run of one scored hour: a dot rather than a line. Coloured by the level it
                        // actually carries — it used to be hardcoded to the mid colour, so a lone HIGH
                        // hour drew as an ordinary one.
                        Circle()
                            .fill(StressRamp.color(level(at: only.1, height: h)))
                            .frame(width: 6, height: 6)
                            .position(x: only.0, y: only.1)
                    }
                }
            }
        }
        .frame(height: chartHeight)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    /// CONTIGUOUS RUNS of scored hours, in chart coordinates.
    ///
    /// The old path `compactMap`-ed the unscored hours away and stroked a smooth curve through whatever
    /// was left, which draws a reading straight across an hour that has none — the one thing the caption
    /// promises it will not do. Splitting into runs lets each be stroked and filled separately, so a
    /// hole in the day stays a hole. The Kotlin twin has always broken the line here.
    private func scoredRuns(width w: CGFloat, height h: CGFloat) -> [[(CGFloat, CGFloat)]] {
        let n = max(hours.count, 1)
        var out: [[(CGFloat, CGFloat)]] = []
        var run: [(CGFloat, CGFloat)] = []
        for (i, p) in hours.enumerated() {
            guard let level = p.level else {
                if !run.isEmpty { out.append(run); run = [] }
                continue
            }
            let px = n <= 1 ? w / 2 : w * CGFloat(i) / CGFloat(n - 1)
            let py = h - h * CGFloat(min(max(level / 3.0, 0), 1))
            run.append((px, py))
        }
        if !run.isEmpty { out.append(run) }
        return out
    }

    /// The 0-3 level a chart y-position represents: the inverse of the `y` mapping above, so a lone
    /// point can be coloured by what it actually reads rather than by a fixed guess.
    private func level(at yPos: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double((height - yPos) / height) * 3.0
    }

    /// A smooth (Catmull-Rom-ish) stroke through the scored points.
    private func linePath(_ pts: [(CGFloat, CGFloat)]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: CGPoint(x: first.0, y: first.1))
        for i in 1..<pts.count {
            let prev = pts[i - 1]
            let cur = pts[i]
            let midX = (prev.0 + cur.0) / 2
            path.addCurve(
                to: CGPoint(x: cur.0, y: cur.1),
                control1: CGPoint(x: midX, y: prev.1),
                control2: CGPoint(x: midX, y: cur.1)
            )
        }
        return path
    }

    private func areaPath(_ pts: [(CGFloat, CGFloat)], width: CGFloat, height: CGFloat) -> Path {
        var path = linePath(pts)
        if let last = pts.last, let first = pts.first {
            path.addLine(to: CGPoint(x: last.0, y: height))
            path.addLine(to: CGPoint(x: first.0, y: height))
            path.closeSubpath()
        }
        return path
    }

    private var accessibilitySummary: String {
        let scored = hours.compactMap { p in p.level.map { (p.hour, $0) } }
        guard !scored.isEmpty else { return String(localized: "No intraday stress data yet today.") }
        let parts = scored.map { "\($0.0):00 \(StressTrace.formatLevel($0.1))" }
        return String(localized: "Autonomic load today: \(parts.joined(separator: ", "))")
    }
}

// MARK: - Stress totals (Calm / Moderate / High) split for the day

/// Splits the day's SCORED waking hours into the three stress bands and exposes each
/// band's share + duration. Each intraday bucket is one hour (`DaytimeStress.bucketSeconds`),
/// so the band's hour-count is its duration. Calm = 0–1, Moderate = 1–2, High = 2–3.
struct StressTotals {
    let calmHours: Int
    let moderateHours: Int
    let highHours: Int

    init(hours: [DaytimeStress.HourPoint]) {
        var c = 0, m = 0, hi = 0
        for p in hours {
            guard let lvl = p.level else { continue }
            switch StressBand(score: lvl) {
            case .low:    c += 1
            case .medium: m += 1
            case .high:   hi += 1
            }
        }
        calmHours = c; moderateHours = m; highHours = hi
    }

    var total: Int { calmHours + moderateHours + highHours }

    /// 0...1 share of the scored day spent in each band (0 when no scored hours).
    func fraction(_ band: StressBand) -> Double {
        guard total > 0 else { return 0 }
        switch band {
        case .low:    return Double(calmHours) / Double(total)
        case .medium: return Double(moderateHours) / Double(total)
        case .high:   return Double(highHours) / Double(total)
        }
    }

    func hours(_ band: StressBand) -> Int {
        switch band {
        case .low:    return calmHours
        case .medium: return moderateHours
        case .high:   return highHours
        }
    }
}

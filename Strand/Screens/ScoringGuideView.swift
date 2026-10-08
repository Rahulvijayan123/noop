import SwiftUI
import StrandDesign

// MARK: - Scoring guide
//
// "How your metrics work" — the one honest explainer for the real measurements Nara reads (HRV,
// resting heart rate, sleep, breathing, skin temperature, steps, calories, heart-rate zones), each with
// how Nara measures it and the published studies behind it, plus the confidence labels. Content only: the title and the Done button are the host
// navigation bar's (`.navigationTitle` + a confirmation-action Done when `onClose` is set), so it reads
// the same as a sheet (wrapped in a NavigationStack by the caller) and when pushed (Browse, the Charge
// breakdown). Each score section names itself with its score colour on the icon only.

/// The three daily scores callers deep-link from (Today rings, detail screens). The guide itself is
/// organised by the underlying metrics; each section opens at the metric that score leans on most
/// (`guideMetric`). The Android port mirrors these case names exactly.
enum ScoreSection: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest

    var id: String { rawValue }

    /// The metric the guide opens at for this score: Charge → HRV, Effort → heart rate, Rest → sleep.
    var guideMetric: GuideMetric.ID {
        switch self {
        case .charge: return .hrv
        case .effort: return .heartRate
        case .rest:   return .sleep
        }
    }

    /// The accent each section uses — the SAME Reset score token its Today hero ring draws with, so a
    /// section reads as that score's colour. No gold / strain / sleep-purple: Charge = chargeColor green,
    /// Effort = effortColor blue accent, Rest = restColor slate (Design Reset, 2026-06-23).
    var accent: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor     // Charge hero ring — green
        case .effort: return StrandPalette.effortColor     // Effort hero ring — blue accent
        case .rest:   return StrandPalette.restColor       // Rest hero ring — slate
        }
    }

    /// The SF Symbol for the section header (heart/spark · flame · moon).
    var icon: String {
        switch self {
        case .charge: return "heart.circle.fill"
        case .effort: return "flame.fill"
        case .rest:   return "moon.stars.fill"
        }
    }

    /// Localized display name for the section (the raw value stays the stable anchor id).
    var displayName: String {
        switch self {
        case .charge: return String(localized: "Charge")
        case .effort: return String(localized: "Effort")
        case .rest:   return String(localized: "Rest")
        }
    }
}

/// One real metric in the guide: what it is, how Nara measures it, and the studies behind it.
struct GuideMetric: Identifiable {
    enum ID: String { case hrv, restingHR, sleep, respiratory, skinTemp, steps, calories, heartRate }

    let id: ID
    let icon: String
    let name: String
    let unit: String
    let what: String
    let how: String
    let studies: [String]

    static let all: [GuideMetric] = [
        GuideMetric(
            id: .hrv, icon: "waveform.path.ecg", name: String(localized: "Heart-rate variability"), unit: "ms · RMSSD",
            what: String(localized: "The beat-to-beat variation in your heart rhythm. Higher usually means a more recovered, calmer nervous system. It is read against your own baseline, never against other people."),
            how: String(localized: "Overnight only, inside detected sleep. Beats outside 300-2000 ms, or more than 20% off their neighbours, are dropped. Clean 5-minute windows (at least 20 beats) are averaged, weighted by session length."),
            studies: [
                "Task Force of the ESC and NASPE (1996). Heart rate variability: standards of measurement, physiological interpretation, and clinical use. Circulation 93(5):1043-1065.",
                "Shaffer & Ginsberg (2017). An overview of heart rate variability metrics and norms. Front Public Health 5:258.",
                "Plews et al. (2013). Training adaptation and heart rate variability in elite endurance athletes. Sports Med 43(9):773-781."
            ]),
        GuideMetric(
            id: .restingHR, icon: "heart.fill", name: String(localized: "Resting heart rate"), unit: "bpm",
            what: String(localized: "How slowly your heart beats at full rest. Lower is generally fitter. A sustained rise above your baseline can point to stress, illness or poor recovery."),
            how: String(localized: "The lowest 5-minute average (at least 5 samples) inside your main night's sleep. It is a floor, not the night's average, so a short nap can't replace it."),
            studies: [
                "Fox et al. (2007). Resting heart rate in cardiovascular disease. J Am Coll Cardiol 50(9):823-830.",
                "Zhang et al. (2016). Resting heart rate and all-cause and cardiovascular mortality in the general population: a meta-analysis. CMAJ 188(3):E53-E63."
            ]),
        GuideMetric(
            id: .sleep, icon: "moon.stars.fill", name: String(localized: "Sleep"), unit: String(localized: "hours · stages"),
            what: String(localized: "How long you slept, how efficiently, and how the night split into light, deep and REM sleep. Most adults need seven or more hours."),
            how: String(localized: "Nara finds still stretches in wrist motion, confirms them with a lower heart rate, and requires over an hour. It then labels 30-second epochs from heart rate, HRV and movement relative to your own night. Stages are approximate, and deep sleep is the least reliable."),
            studies: [
                "Watson et al. (2015). Recommended amount of sleep for a healthy adult: a joint consensus statement of the AASM and SRS. Sleep 38(6):843-844.",
                "Ohayon et al. (2004). Meta-analysis of quantitative sleep parameters from childhood to old age in healthy individuals. Sleep 27(7):1255-1273.",
                "Walch et al. (2019). Sleep stage prediction with raw acceleration and photoplethysmography heart rate data derived from a consumer wearable device. Sleep 42(12):zsz180.",
                "Chinoy et al. (2021). Performance of seven consumer sleep-tracking devices compared with polysomnography. Sleep 44(5):zsaa291."
            ]),
        GuideMetric(
            id: .respiratory, icon: "lungs.fill", name: String(localized: "Respiratory rate"), unit: String(localized: "breaths / min"),
            what: String(localized: "Breaths per minute while you sleep. It is very steady night to night, so a rise is an early sign of illness or strain."),
            how: String(localized: "Recovered from the breathing rhythm hidden in your beat-to-beat intervals. Nara takes the median across 5-minute windows and keeps it to 8-25 breaths per minute. It is an estimate, not a chest-band reading."),
            studies: [
                "Cretikos et al. (2008). Respiratory rate: the neglected vital sign. Med J Aust 188(11):657-659.",
                "Charlton et al. (2018). Breathing rate estimation from the electrocardiogram and photoplethysmogram: a review. IEEE Rev Biomed Eng 11:2-20."
            ]),
        GuideMetric(
            id: .skinTemp, icon: "thermometer.medium", name: String(localized: "Skin temperature"), unit: String(localized: "°C vs baseline"),
            what: String(localized: "How your wrist temperature compares with your own norm. Only the deviation matters, because absolute wrist temperature shifts with the room and the fit. A lasting rise can accompany illness."),
            how: String(localized: "Tracked against your personal baseline, and flagged only once Nara has learned it, which takes a few nights."),
            studies: [
                "Smarr et al. (2020). Feasibility of continuous fever monitoring using wearable devices. Sci Rep 10:21640.",
                "Mishra et al. (2020). Pre-symptomatic detection of COVID-19 from smartwatch data. Nat Biomed Eng 4(12):1208-1220."
            ]),
        GuideMetric(
            id: .steps, icon: "figure.walk", name: String(localized: "Steps"), unit: String(localized: "steps"),
            what: String(localized: "Your daily step count, estimated from the strap's motion counter. It is not a calibrated pedometer, so expect it to differ a little from your phone."),
            how: String(localized: "Counter increments across the local day count only when the strap saw walking or running at a plausible pace. The first burst of a walking bout is credited as one block."),
            studies: [
                "Paluch et al. (2022). Daily steps and all-cause mortality: a meta-analysis of 15 international cohorts. Lancet Public Health 7(3):e219-e228."
            ]),
        GuideMetric(
            id: .calories, icon: "flame.fill", name: String(localized: "Calories"), unit: "kcal",
            what: String(localized: "Your day's total energy use: resting metabolism plus the energy from moving."),
            how: String(localized: "Resting energy uses your measured value if you set one, otherwise the revised Harris-Benedict equation from age, sex, height and weight. Active energy is estimated each minute from heart rate and motion as METs. Minutes with no usable data add none."),
            studies: [
                "Roza & Shizgal (1984). The Harris Benedict equation reevaluated: resting energy requirements and the body cell mass. Am J Clin Nutr 40(1):168-182.",
                "Ainsworth et al. (2011). 2011 Compendium of Physical Activities. Med Sci Sports Exerc 43(8):1575-1581."
            ]),
        GuideMetric(
            id: .heartRate, icon: "heart.text.square.fill", name: String(localized: "Heart rate & zones"), unit: "bpm",
            what: String(localized: "Your heart rate through the day, grouped into intensity zones so you can see how hard a stretch of activity really was."),
            how: String(localized: "Max heart rate uses 208 - 0.7 × age unless you set your own. Zones are shares of heart-rate reserve, the gap between your resting and maximum heart rate."),
            studies: [
                "Tanaka et al. (2001). Age-predicted maximal heart rate revisited. J Am Coll Cardiol 37(1):153-156.",
                "Karvonen et al. (1957). The effects of training on heart rate: a longitudinal study. Ann Med Exp Biol Fenn 35(3):307-315."
            ])
    ]
}

struct ScoringGuideView: View {
    /// When set, the guide scrolls to the metric that score leans on most (Charge → HRV, Effort → heart
    /// rate, Rest → sleep) on appear, so each Today ring opens at the right place.
    var initialSection: ScoreSection? = nil
    /// Dismisses the presenting sheet; nil when the guide is pushed (the back button is the way out).
    var onClose: (() -> Void)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    introCard
                    ForEach(GuideMetric.all) { metricCard($0) }
                    confidenceCard
                    footerNote
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space6)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .onAppear { jump(to: initialSection, using: proxy) }
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text("How your metrics work"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .foregroundStyle(StrandPalette.accent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        // A fixed window on macOS (a macOS sheet hosting a ScrollView collapses without one); fill the
        // presented sheet on iOS so nothing runs off a narrow phone screen (#185).
        #if os(macOS)
        .frame(minWidth: 560, minHeight: 640)
        #else
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    // MARK: - Cards

    private var introCard: some View {
        NoopCard {
            Text("The signals Nara reads from your strap, how each one is measured on your device, and the published research behind it. Everything is computed on your phone against your own baseline.")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One metric: icon, name and unit, then what it is, how Nara measures it, and the studies.
    private func metricCard(_ metric: GuideMetric) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Image(systemName: metric.icon)
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(StrandPalette.accent)
                        .accessibilityHidden(true)
                    Text(metric.name)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(metric.unit)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                labelled(String(localized: "What it is"), metric.what)
                labelled(String(localized: "How Nara measures it"), metric.how)
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: NoopMetrics.hairlineWidth)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Studies")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                    ForEach(metric.studies, id: \.self) { study in
                        Text(study)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(metric.id.rawValue)
    }

    private func labelled(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textSecondary)
            Text(text)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var confidenceCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("How sure is Nara?")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                // The three labels as the same pills used elsewhere, in their honest order.
                HStack(spacing: NoopMetrics.space2) {
                    StatePill("Solid", tone: .positive, showsDot: true)
                    StatePill("Building", tone: .warning, showsDot: true)
                    StatePill("Calibrating", tone: .neutral, showsDot: true)
                }
                Text("Calibrating means Nara is still learning your baseline (it needs about 4 nights, and trusts it after 14). Building means there's enough to show, but it's thin. Solid means full inputs are present. When Nara can't compute something honestly, it shows nothing rather than a fake number.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerNote: some View {
        Text("Independent approximations from a consumer strap, built on open research. Not medical advice.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Deep-link

    /// Scroll to the metric the requested score leans on. Instant under Reduce Motion.
    private func jump(to section: ScoreSection?, using proxy: ScrollViewProxy) {
        guard let section else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo(section.guideMetric.rawValue, anchor: .top)
        }
    }
}

#if DEBUG
#Preview("Metrics guide") {
    NavigationStack { ScoringGuideView(initialSection: .effort, onClose: {}) }
        .preferredColorScheme(.dark)
}
#endif

import SwiftUI
import StrandDesign

// MARK: - Scoring guide
//
// "How your scores work" — the one honest explainer for Nara's three daily scores (Charge, Effort,
// Rest) and the confidence labels. Content only: the title and the Done button are the host
// navigation bar's (`.navigationTitle` + a confirmation-action Done when `onClose` is set), so it reads
// the same as a sheet (wrapped in a NavigationStack by the caller) and when pushed (Browse, the Charge
// breakdown). Each score section names itself with its score colour on the icon only.

/// The three score sections the guide can deep-link to. The raw value is used as the
/// ScrollViewReader anchor id. The Android port mirrors these case names exactly.
enum ScoreSection: String, CaseIterable, Identifiable {
    case charge
    case effort
    case rest

    var id: String { rawValue }

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

struct ScoringGuideView: View {
    /// When set, the guide scrolls to this section on appear — used by the Today rings so each opens at
    /// its own score.
    var initialSection: ScoreSection? = nil
    /// Dismisses the presenting sheet; nil when the guide is pushed (the back button is the way out).
    var onClose: (() -> Void)? = nil

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    introCard
                    scoreCard(.charge,
                              headline: String(localized: "Charge: how recovered are you?"),
                              body: String(localized: "Led by your heart-rate variability (HRV) measured against your own personal baseline, plus resting heart rate, last night's Rest, breathing rate, and a skin-temperature signal (an early illness or overreach flag). Higher HRV versus your baseline means more Charge. Nara needs a few nights to learn your baseline first. Until then you'll see “Calibrating”."),
                              vsWhoop: String(localized: "Same core idea as WHOOP's Recovery % (HRV-led recovery), but our weighting and baseline maths are our own, and openly documented."))
                    scoreCard(.effort,
                              headline: String(localized: "Effort: how hard did your heart work?"),
                              body: String(localized: "Your cardiovascular load. Nara turns every second of heart rate into a training-impulse using heart-rate-reserve zones (Karvonen), weights time in harder zones more heavily (Edwards / Banister), and places it on a logarithmic 0-100 scale, so easy days sit low and an all-out day approaches 100, which stays genuinely rare. A long walk with little cardio still counts, through a steps / active-energy floor."),
                              vsWhoop: String(localized: "Same cardiovascular-load idea as WHOOP's Day Strain (0-21). We rescaled the top of the ladder from 21 to 100 so all three scores share one scale. The rungs didn't move, so a 100 is as rare as a 21.0 was."))
                    scoreCard(.rest,
                              headline: String(localized: "Rest: how restorative was your sleep?"),
                              body: String(localized: "A blend of how long you slept versus your personal need (the biggest factor), how efficiently (asleep versus in bed), how much was restorative (deep + REM sleep), and how consistent your sleep and wake timing is."),
                              vsWhoop: String(localized: "Similar in spirit to WHOOP's Sleep Performance %; our composite is our own."))
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
        .navigationTitle(Text("How your scores work"))
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
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Nara gives you three daily scores (Charge, Effort and Rest), each on a 0-100 scale. They're built from your strap's raw signals using published, peer-reviewed sport science, and computed entirely on your device. They are NOT WHOOP's scores: we don't have WHOOP's private algorithms and don't pretend to. They aim at the same three questions using open science, so they'll usually track WHOOP's in direction, but won't match number-for-number. And that's the point.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// One score section: the score's icon (in its colour) and name, the question it answers, how it is
    /// built, and how it compares with WHOOP's, under a hairline.
    private func scoreCard(_ section: ScoreSection, headline: String, body: String, vsWhoop: String) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Image(systemName: section.icon)
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(section.accent)
                        .accessibilityHidden(true)
                    Text(headline)
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text(body)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: NoopMetrics.hairlineWidth)
                    .accessibilityHidden(true)
                Text(vsWhoop)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id(section.id)
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
                Text("Every score carries a small honesty label. Calibrating means Nara is still learning your baseline, or doesn't have enough data yet. Building means there's enough to show, but it's thin. Solid means full inputs are present. When Nara can't compute a score honestly, it shows nothing rather than a fake number.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footerNote: some View {
        Text("These are independent approximations from a consumer strap, built on open science: not medical advice, and not WHOOP's official scores.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }

    // MARK: - Deep-link

    /// Scroll to the requested section. Instant under Reduce Motion.
    private func jump(to section: ScoreSection?, using proxy: ScrollViewProxy) {
        guard let section else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo(section.id, anchor: .top)
        }
    }
}

#if DEBUG
#Preview("Scoring guide") {
    NavigationStack { ScoringGuideView(initialSection: .effort, onClose: {}) }
        .preferredColorScheme(.dark)
}
#endif

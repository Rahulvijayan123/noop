import SwiftUI
import StrandDesign

// MARK: - Card explainer
//
// Tapping a card on Today opens this pop-up: what the number is, how Nara measures it, and the studies
// behind it. The card's old destination (its detail page, graph and history) is one button away, so
// nothing became unreachable. The wording for real metrics comes from `GuideMetric`, the same text as
// "How your metrics work", so a card and the guide can never describe a metric two ways.

/// What one card's pop-up says.
struct CardExplainer: Identifiable {
    let id: String
    let title: String
    let icon: String
    let tint: Color
    /// The card's current reading ("62 ms", "3/4"), shown large at the top. nil draws no reading.
    var value: String? = nil
    /// The card's state word ("In range", "Solid").
    var state: String? = nil
    let what: String
    let how: String
    var studies: [String] = []
    /// The page the card used to open. nil hides the button.
    var route: TabRoute? = nil

    /// A pop-up for a real metric, worded from the guide.
    static func metric(_ id: GuideMetric.ID, title: String? = nil, icon: String? = nil, tint: Color,
                       value: String? = nil, state: String? = nil, route: TabRoute? = nil) -> CardExplainer {
        let m = GuideMetric.all.first { $0.id == id } ?? GuideMetric.all[0]
        return CardExplainer(id: m.id.rawValue, title: title ?? m.name, icon: icon ?? m.icon, tint: tint,
                             value: value, state: state, what: m.what, how: m.how, studies: m.studies,
                             route: route)
    }
}

extension CardExplainer {
    // MARK: Hero rings

    static func baseline(value: String?, state: String?, tint: Color, route: TabRoute?) -> CardExplainer {
        CardExplainer(
            id: "baseline", title: String(localized: "Baseline"), icon: "chart.bar.doc.horizontal",
            tint: tint, value: value, state: state,
            what: String(localized: "How many of last night's vitals landed inside your own usual range. 3/4 means three were normal for you."),
            how: String(localized: "Each vital (resting heart rate, HRV, skin temperature, breathing and blood oxygen when available) is compared with a usual built from your own nights. A usual starts after about 4 nights and is trusted after 14."),
            route: route)
    }

    static func watchdog(value: String?, state: String?, tint: Color, route: TabRoute?) -> CardExplainer {
        CardExplainer(
            id: "watchdog", title: String(localized: "Watchdog"), icon: "eye", tint: tint,
            value: value, state: state,
            what: String(localized: "A live check on whether the last half-hour looks like you."),
            how: String(localized: "Heart rate, HRV, skin temperature, breathing and blood oxygen from the last 30 minutes are compared with your own usual. The ring fills the further they drift, and is full at a severe departure."),
            route: route)
    }

    static func rest(value: String?, state: String?, tint: Color, route: TabRoute?) -> CardExplainer {
        let sleep = GuideMetric.all.first { $0.id == .sleep }
        return CardExplainer(
            id: "rest", title: String(localized: "Rest"), icon: "moon.stars.fill", tint: tint,
            value: value, state: state,
            what: String(localized: "How restorative your sleep was, from 0 to 100."),
            how: String(localized: "A blend of how long you slept against your personal need (the biggest factor), how efficiently, how much was deep and REM sleep, and how consistent your timing is."),
            studies: sleep.map { Array($0.studies.prefix(2)) } ?? [],
            route: route)
    }

    // MARK: Key-metric tiles

    /// The pop-up for a Key Metrics tile. `value` is the tile's reading with its unit.
    static func keyMetric(_ metric: KeyMetric, value: String?, state: String?, tint: Color,
                          icon: String, route: TabRoute?) -> CardExplainer {
        func real(_ id: GuideMetric.ID) -> CardExplainer {
            .metric(id, title: metric.title, icon: icon, tint: tint, value: value, state: state, route: route)
        }
        func custom(_ what: String, _ how: String, _ studies: [String] = []) -> CardExplainer {
            CardExplainer(id: metric.rawValue, title: metric.title, icon: icon, tint: tint, value: value,
                          state: state, what: what, how: how, studies: studies, route: route)
        }
        let hrv = GuideMetric.all.first { $0.id == .hrv }?.studies ?? []
        let heart = GuideMetric.all.first { $0.id == .heartRate }?.studies ?? []
        switch metric {
        case .hrv:         return real(.hrv)
        case .restingHr:   return real(.restingHR)
        case .respiratory: return real(.respiratory)
        case .steps:       return real(.steps)
        case .calories:    return real(.calories)
        case .skinTemp:    return real(.skinTemp)
        case .charge:
            return custom(
                String(localized: "How recovered your body is, from 0 to 100."),
                String(localized: "Led by your overnight HRV against your own baseline, together with resting heart rate, last night's sleep, breathing and a skin-temperature signal. It needs a few nights to learn your baseline."),
                Array(hrv.dropFirst()))
        case .effort:
            return custom(
                String(localized: "How hard your heart worked today, from 0 to 100."),
                String(localized: "Time in each heart-rate-reserve zone is weighted more heavily as intensity rises, then placed on a logarithmic scale. Easy days sit low and an all-out day approaches 100."),
                heart)
        case .rest:
            return .rest(value: value, state: state, tint: tint, route: route)
        case .bloodOxygen:
            return custom(
                String(localized: "An estimate of the oxygen your blood carries, read at the wrist."),
                String(localized: "The strap records it while you are asleep and still, so a daytime reading can legitimately be empty. It is an estimate, not a medical pulse oximeter."))
        case .weight:
            return custom(
                String(localized: "Your body weight."),
                String(localized: "Taken from Apple Health when a reading exists, otherwise from your profile. Nara uses it, with age, sex and height, to estimate your resting energy."))
        }
    }

    // MARK: Heart-rate card

    static func heartRate(value: String?, route: TabRoute?) -> CardExplainer {
        .metric(.heartRate, title: String(localized: "Heart rate"), tint: StrandPalette.metricRose,
                value: value, route: route)
    }
}

/// The pop-up. Medium first, large on drag; a plain sheet on the Mac.
struct CardExplainerSheet: View {
    let explainer: CardExplainer
    let onOpenDetails: (TabRoute) -> Void
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    header
                    NoopCard {
                        VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                            labelled(String(localized: "What it is"), explainer.what)
                            labelled(String(localized: "How Nara measures it"), explainer.how)
                            if !explainer.studies.isEmpty {
                                Rectangle()
                                    .fill(StrandPalette.hairline)
                                    .frame(height: NoopMetrics.hairlineWidth)
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("Studies")
                                        .font(StrandFont.footnote.weight(.semibold))
                                        .foregroundStyle(StrandPalette.textSecondary)
                                    ForEach(explainer.studies, id: \.self) { study in
                                        Text(study)
                                            .font(StrandFont.footnote)
                                            .foregroundStyle(StrandPalette.textTertiary)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let route = explainer.route {
                        Button { onOpenDetails(route) } label: {
                            HStack {
                                Text("Open details")
                                Image(systemName: "chevron.right")
                                    .font(StrandFont.footnote.weight(.semibold))
                            }
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.accent)
                            .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("cardExplainer.openDetails")
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(verbatim: explainer.title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .foregroundStyle(StrandPalette.accent)
                        .keyboardShortcut(.defaultAction)
                        .accessibilityIdentifier("cardExplainer.done")
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 460, minHeight: 420)
        #else
        .noopSheetPresentation(largeFirst: false)
        #endif
        .accessibilityIdentifier("cardExplainer.sheet")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Image(systemName: explainer.icon)
                .font(StrandFont.icon(.row))
                .foregroundStyle(explainer.tint)
                .frame(width: 44, height: 44)
                .background(Circle().fill(explainer.tint.opacity(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                if let value = explainer.value {
                    Text(verbatim: value)
                        .font(StrandFont.number(28))
                        .monospacedDigit()
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                if let state = explainer.state, !state.trimmingCharacters(in: .whitespaces).isEmpty {
                    Text(verbatim: state)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
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
}

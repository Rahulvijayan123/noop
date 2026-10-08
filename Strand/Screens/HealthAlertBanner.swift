import SwiftUI
import StrandDesign
import StrandAnalytics
import Foundation

/// Strain/illness early-warning banner. Observes AppModel in isolation so the ~1 Hz HR stream
/// re-renders only this small view, not the whole screen. Renders nothing when there's no alert.
///
/// A glance, not a paragraph: what the body looks like, which signals moved, and the one caveat a
/// medical-adjacent claim must carry. The reasoning (what was logged, what to do) lives on the Health page
/// the banner opens. The warning symbol carries the state; the card itself is the plain card.
struct HealthAlertBanner: View {
    @EnvironmentObject var model: AppModel

    /// The alert to show: the model's, or in DEBUG with `--demo-health-alert` a raised sample, so the
    /// banner can be screenshotted without an illness signal.
    private var shownAlert: AppModel.HealthAlert? {
        #if DEBUG
        if CommandLine.arguments.contains("--demo-health-alert") {
            return model.healthAlert ?? AppModel.HealthAlert(message: .raised,
                                                             firedSignals: ["HRV", "resting heart rate"])
        }
        #endif
        return model.healthAlert
    }

    var body: some View {
        if let alert = shownAlert {
            let copy = homeHealthAlertCopy(alert)
            NavigationLink(value: TabRoute.health) {
                NoopCard {
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(StrandFont.icon(.row))
                            .foregroundStyle(StrandPalette.statusWarning)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                            Text(copy.title)
                                .font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let detail = copy.detail {
                                Text(detail)
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Text("Estimate, not a diagnosis")
                                .font(StrandFont.footnote)
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right")
                            .font(StrandFont.icon(.inline))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .accessibilityHidden(true)
                    }
                }
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityElement(children: .combine)
            .accessibilityHint(Text("Opens Health"))
        }
    }
}

/// The banner's short form of the semantic illness result: a title and, when there is one, the signals
/// line. The full sentences (`localizedHealthAlertCopy`) stay for the places that read them.
func homeHealthAlertCopy(_ alert: AppModel.HealthAlert) -> (title: String, detail: String?) {
    switch alert.message {
    case .raised:
        let formatter = ListFormatter()
        formatter.locale = AppLanguage.activeLocale
        let signals = formatter.string(from: alert.firedSignals) ?? alert.firedSignals.joined(separator: ", ")
        return (String(localized: "Signals look strained"),
                alert.firedSignals.isEmpty ? nil : String(localized: "Up: \(signals)"))
    case .alreadyUnwellAgree:
        return (String(localized: "You logged feeling unwell"), String(localized: "Your signals agree"))
    case .alreadyUnwell:
        return (String(localized: "You logged feeling unwell"), nil)
    default:
        // The publisher gates the banner to raised/already-unwell; keep the impossible fallback semantic.
        return (String(localized: "Nothing notable. Your signals look like their normal range."), nil)
    }
}

/// Home-facing rendering of the semantic illness result. Both Today variants share this banner,
/// so neither can accidentally expose the analytics engine's English notification copy.
func localizedHealthAlertCopy(_ alert: AppModel.HealthAlert) -> String {
    if alert.message == .raised {
        let formatter = ListFormatter()
        formatter.locale = AppLanguage.activeLocale
        let signals = formatter.string(from: alert.firedSignals) ?? alert.firedSignals.joined(separator: ", ")
        return String(localized: "Your body looks strained. Signals up: \(signals). No alcohol or travel was logged, so consider taking it easy. On-device estimate, not a diagnosis.")
    }
    if alert.message == .alreadyUnwellAgree {
        return String(localized: "You logged feeling unwell, and your signals agree. Take it easy today. On-device estimate, not a diagnosis.")
    }
    if alert.message == .alreadyUnwell {
        return String(localized: "You logged feeling unwell. Take it easy today. On-device estimate, not a diagnosis.")
    }
    // The publisher gates the banner to raised/already-unwell. Keep the impossible fallback localized
    // and semantic rather than leaking `Result.copy` if a future caller bypasses that gate.
    return String(localized: "Nothing notable. Your signals look like their normal range.")
}

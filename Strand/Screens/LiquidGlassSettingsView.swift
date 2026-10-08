#if os(iOS)
import SwiftUI
import StrandDesign

/// Settings → Display → Liquid Glass: how strongly every surface, control and the tab bar is drawn as
/// glass. 0 is the solid look the app had before.
///
/// The slider previews on this page while it is dragged and writes the setting when it is let go, so the
/// rest of the app redraws once per change rather than once per step.
struct LiquidGlassSettingsView: View {
    @AppStorage(LiquidGlassPrefs.intensityKey) private var storedPercent = LiquidGlassPrefs.defaultPercent
    @State private var draft: Double?
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    static let presets: [(percent: Int, label: LocalizedStringKey)] = [
        (0, "Off"), (35, "Subtle"), (70, "Balanced"), (100, "Vivid"),
    ]

    /// The Settings row's value: "Off", or the intensity as a percent.
    static func valueLabel(_ percent: Int) -> String {
        percent <= 0 ? String(localized: "Off") : "\(percent)%"
    }

    private var shownPercent: Int { Int((draft ?? Double(storedPercent)).rounded()) }

    var body: some View {
        ScreenScaffold(title: "Liquid Glass") {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                LiquidGlassPreview()
                    .accessibilityHidden(true)
                SettingsGroup(footer: "Cards, buttons, search fields and the tab bar blur and bend what is behind them. Higher is clearer and more liquid; Off keeps solid surfaces.") {
                    intensityRow
                    SettingsDivider()
                    SettingsOptions(selection: presetSelection,
                                    options: Self.presets.map { (String($0.percent), $0.label) })
                }
                if reduceTransparency {
                    SettingsNote("Reduce Transparency is on in iOS Settings, so glass is off.")
                }
            }
        }
        .liquidGlass(percent: shownPercent)
    }

    private var intensityRow: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("Intensity")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text(verbatim: Self.valueLabel(shownPercent))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
            Slider(value: sliderValue, in: Double(LiquidGlassPrefs.range.lowerBound)...Double(LiquidGlassPrefs.range.upperBound),
                   step: 5) { editing in
                if !editing, let draft {
                    storedPercent = Int(draft.rounded())
                    self.draft = nil
                }
            }
            .tint(StrandPalette.accent)
            .accessibilityLabel("Liquid Glass intensity")
            .accessibilityValue(Self.valueLabel(shownPercent))
            .accessibilityIdentifier("liquidGlass.intensity")
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
    }

    private var sliderValue: Binding<Double> {
        Binding(
            get: { draft ?? Double(storedPercent) },
            set: { draft = $0 }
        )
    }

    private var presetSelection: Binding<String> {
        Binding(
            get: { String(shownPercent) },
            set: { if let percent = Int($0) { storedPercent = percent } }
        )
    }
}

/// A swatch of glass over a bright backdrop, so the effect of the slider is visible on this page whatever
/// screen sits behind Settings.
private struct LiquidGlassPreview: View {
    var body: some View {
        ZStack {
            backdrop
            HStack(spacing: NoopMetrics.space3) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Recovery").strandOverline()
                    Text(verbatim: "82%")
                        .font(StrandFont.number(28, weight: .medium))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                .padding(NoopMetrics.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(NoopPanelSurface(cornerRadius: NoopMetrics.cardRadius, elevated: true))
                Button {} label: {
                    Image(systemName: "sparkles")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .frame(width: 36, height: 36)
                }
                .buttonStyle(NoopGlassButtonStyle(shape: Circle(), controlSize: .regular))
                .allowsHitTesting(false)
            }
            .padding(NoopMetrics.space5)
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
                .strokeBorder(StrandPalette.textPrimary.opacity(0.12), lineWidth: 1)
        )
    }

    private var backdrop: some View {
        ZStack {
            LinearGradient(colors: [NaraBrand.deepIndigo, NaraBrand.deepPurple.opacity(0.7)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(NaraBrand.hotPink).frame(width: 140).offset(x: -110, y: -30)
            Circle().fill(NaraBrand.lightCyan).frame(width: 120).offset(x: 40, y: 50)
            Circle().fill(NaraBrand.deepPurple).frame(width: 110).offset(x: 140, y: -40)
            Text(verbatim: "Nara")
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .offset(x: -20, y: 10)
        }
    }
}
#endif

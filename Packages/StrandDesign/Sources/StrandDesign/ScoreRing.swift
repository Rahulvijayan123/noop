import SwiftUI

// MARK: - ScoreRing
//
// The one score ring: a flat track, one solid arc in the score's colour, the value in the centre. It
// replaces the six ring styles that grew on different screens (RecoveryRing, BevelGauge, StrainGauge,
// LiquidVessel, LiquidScoreGauge, StressHeroGauge); GlowRing stays for the watch and widget call sites.
// No gradient, shadow, glow, end-cap dot or counting number: the arc says how full, the number says how
// much, and nothing else moves. Cross-platform (shapes only), so the watch can adopt it later.

/// A flat score ring.
///
/// ```swift
/// ScoreRing(fraction: charge.map { $0 / 100 }, value: charge.map { "\(Int($0))" } ?? "—",
///           caption: "Charge", color: StrandPalette.recoveryColor(charge ?? 0), diameter: 88)
/// ```
///
/// - `fraction`: 0…1, clamped. `nil` (no score yet) draws the track alone with "—" in the centre,
///   whatever `value` says, so a missing score never shows a number.
/// - `caption`: one short line under the value ("of 100" only when the scale is not obvious, or the
///   score's name). Omit it when the ring is labelled beside it.
/// - The arc eases for 0.25 s when the score changes from one value to another. It does not sweep in
///   when a score first arrives, and does not move at all under Reduce Motion or the quiet-motion gate.
/// - The ring is one accessibility element: the value, then the caption. Override with
///   `.accessibilityLabel(_:)` when the surrounding context names the score.
public struct ScoreRing: View {
    private let fraction: Double?
    private let value: String
    private let caption: String?
    private let color: Color
    private let diameter: CGFloat
    private let lineWidth: CGFloat
    private let isLoading: Bool

    /// Whether the ring has already drawn a real score. Animation is only allowed between two real
    /// scores: the first value after a load (or after `nil`) appears in place.
    @State private var hasShownScore: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    public init(fraction: Double?, value: String, caption: String? = nil,
                color: Color, diameter: CGFloat, lineWidth: CGFloat? = nil,
                isLoading: Bool = false) {
        let shown = isLoading ? nil : ScoreRing.clampedFraction(fraction)
        self.fraction = shown
        self.value = value
        self.caption = caption
        self.color = color
        self.diameter = diameter
        self.lineWidth = lineWidth ?? ScoreRing.defaultLineWidth(diameter: diameter)
        self.isLoading = isLoading
        _hasShownScore = State(initialValue: shown != nil)
    }

    public var body: some View {
        let arc = fraction ?? 0
        let animates = fraction != nil && hasShownScore && !motion.poseStill(reduceMotion)
        ZStack {
            track
            Circle()
                .trim(from: 0, to: arc)
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(lineWidth / 2)
                // A zero-length round-capped arc would still draw a dot at 12 o'clock.
                .opacity(arc > 0 ? 1 : 0)
                .animation(animates ? .easeInOut(duration: 0.25) : nil, value: arc)
            centre
        }
        .frame(width: diameter, height: diameter)
        .onChangeCompat(of: fraction != nil) { hasShownScore = $0 }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isLoading ? Text("Loading", bundle: .module)
                                      : Text(ScoreRing.displayValue(fraction: fraction, value: value)))
        .accessibilityValue(Text(caption ?? ""))
    }

    /// The well the arc runs in: `surfaceInset`, edged by a hairline on both sides so it still reads on
    /// the dark card, where the inset and card fills are close.
    private var track: some View {
        ZStack {
            Circle()
                .stroke(StrandPalette.surfaceInset, lineWidth: lineWidth)
                .padding(lineWidth / 2)
            Circle()
                .strokeBorder(StrandPalette.hairline, lineWidth: NoopMetrics.hairlineWidth)
            Circle()
                .stroke(StrandPalette.hairline, lineWidth: NoopMetrics.hairlineWidth)
                .padding(lineWidth)
        }
    }

    private var centre: some View {
        let inner = max(0, diameter - 2 * lineWidth)
        return VStack(spacing: 0) {
            Text(isLoading ? LoadingText.value : ScoreRing.displayValue(fraction: fraction, value: value))
                .font(StrandFont.number(ScoreRing.numeralSize(diameter: diameter, lineWidth: lineWidth),
                                        weight: .medium))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            if let caption {
                Text(caption)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .frame(width: inner * 0.82)
        .redacted(reason: isLoading ? .placeholder : [])
    }

    // MARK: Pure helpers (tested)

    /// The arc's fill: `nil` for no score (including NaN and infinities, which a division by a zero
    /// baseline can produce upstream), otherwise clamped to 0…1.
    public static func clampedFraction(_ fraction: Double?) -> Double? {
        guard let fraction, fraction.isFinite else { return nil }
        return min(1, max(0, fraction))
    }

    /// What the centre shows: "—" whenever there is no score, else `value` ("—" too if it is empty).
    public static func displayValue(fraction: Double?, value: String) -> String {
        guard clampedFraction(fraction) != nil else { return "—" }
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? "—" : value
    }

    /// Stroke width for a ring of `diameter` when the caller does not pass one: 9 % of the diameter, never
    /// thinner than 4 pt so a small ring's arc stays visible.
    public static func defaultLineWidth(diameter: CGFloat) -> CGFloat {
        max(4, diameter * 0.09)
    }

    /// Point size of the centre numeral: 40 % of the space inside the arc, between 14 pt and the hero
    /// `display(40)` size. An 88 pt ring gets ~28 pt (the tile numeral), a 140 pt ring the full 40.
    public static func numeralSize(diameter: CGFloat, lineWidth: CGFloat) -> CGFloat {
        let inner = max(0, diameter - 2 * lineWidth)
        return min(40, max(14, (inner * 0.4).rounded()))
    }
}

#if DEBUG
private struct ScoreRingPreview: View {
    @State private var charge: Double = 62
    var body: some View {
        VStack(spacing: NoopMetrics.sectionGap) {
            NoopCard {
                HStack(spacing: NoopMetrics.space5) {
                    ScoreRing(fraction: charge / 100, value: "\(Int(charge))", caption: "Charge",
                              color: StrandPalette.recoveryColor(charge), diameter: 88)
                    ScoreRing(fraction: 0.48, value: "48", caption: "Effort",
                              color: StrandPalette.effortColor, diameter: 88)
                    ScoreRing(fraction: nil, value: "", caption: "Rest",
                              color: StrandPalette.restColor, diameter: 88)
                }
                .frame(maxWidth: .infinity)
            }
            NoopCard {
                HStack(spacing: NoopMetrics.space5) {
                    ScoreRing(fraction: 0.92, value: "92", caption: "of 100",
                              color: StrandPalette.restColor, diameter: 140)
                    ScoreRing(fraction: 0.5, value: "50", color: StrandPalette.chargeColor,
                              diameter: 140, isLoading: true)
                }
                .frame(maxWidth: .infinity)
            }
            Button("Change Charge") { charge = charge > 50 ? 31 : 84 }
                .font(StrandFont.subhead)
        }
        .padding(NoopMetrics.screenHPadding)
        .frame(width: 390)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("ScoreRing — light") {
    ScoreRingPreview().preferredColorScheme(.light)
}

#Preview("ScoreRing — dark") {
    ScoreRingPreview().preferredColorScheme(.dark)
}
#endif

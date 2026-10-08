import SwiftUI

// MARK: - NOOP visual foundation
//
// These tokens describe the visual treatment used by NOOP's existing views. They deliberately
// contain no navigation, state, or domain semantics: screens keep their current hierarchy and data
// bindings, while cards, gauges, typography, and chrome share one maintainable source of truth.

/// The six Nara brand colours, scheme-invariant. Screens should reach for the semantic tokens
/// (`NoopVisualStyle`, `StrandPalette`) instead; these exist for surfaces that are pinned to one brand
/// colour in both schemes (the logo tile, rendered icons).
public enum NaraBrand {
    public static let lavenderWhite = Color(hex: "#FDF7FF")
    public static let deepIndigo = Color(hex: "#0B0226")
    public static let hotPink = Color(hex: "#FE2178")
    public static let deepRose = Color(hex: "#BB1167")
    public static let lightCyan = Color(hex: "#8AEEEE")
    public static let deepPurple = Color(hex: "#390282")
}

public enum NoopVisualStyle {
    // Lavender White paper with white cards on light; Deep Indigo night with lifted indigo cards on dark.
    public static let canvas = Color(light: "#FDF7FF", dark: "#0B0226")
    public static let surface = Color(light: "#FFFFFF", dark: "#170B36")
    public static let surfaceTop = Color(light: "#FFFFFF", dark: "#1B0F3D")
    public static let surfaceBottom = Color(light: "#FFFCFF", dark: "#160A33")
    public static let inset = Color(light: "#F4EEF8", dark: "#120830")

    public static let border = Color(light: "#ECE4F2", dark: "#2A1D4E")
    public static let borderHighlight = Color(light: "#FFFFFF", dark: "#342760")
    public static let divider = Color(light: "#EFE8F4", dark: "#251948")

    // Deep Indigo carries almost all text; secondary/tertiary are the same ink at lower strength.
    public static let primaryText = Color(light: "#0B0226", dark: "#FDF7FF")
    public static let secondaryText = Color(light: "#4A4262", dark: "#C9C1DA")
    public static let tertiaryText = Color(light: "#6A6382", dark: "#9A92B2")

    // The chrome accent. The names predate the rebrand and are load-bearing across screens; the values
    // are Deep Purple on light and a lifted violet on dark.
    public static let mint = Color(light: "#390282", dark: "#B79CFF")
    public static let mintDeep = Color(light: "#2A0163", dark: "#8F6BF0")
    public static let mintGlow = Color(light: "#6A3FD0", dark: "#CDB8FF")

    public static let cardRadius: CGFloat = 20
    public static let compactRadius: CGFloat = 14
    public static let pillRadius: CGFloat = 999
    public static let pagePadding: CGFloat = 20
    public static let cardPadding: CGFloat = 16
    public static let itemGap: CGFloat = 12
    public static let sectionGap: CGFloat = 24
}

/// The card fill: flat `surfaceRaised` behind a 1 pt `hairline`, at `cornerRadius`.
///
/// No gradient and no tint: domain colour belongs to the data marks and icons inside a card, not its
/// fill (docs/DESIGN_SYSTEM.md, Canvas and surfaces). `tint` and `surfaceOpacity` are accepted so the
/// direct call sites keep compiling, and ignored, the same way `FrostedCardSurface` ignores them, which
/// flattens every tinted or translucent panel in one place. The fill stays `NoopVisualStyle.surface`:
/// the sleep-ramp contrast tests measure against it.
///
/// Light mode keeps one shared soft shadow so a white card still separates from the lavender canvas;
/// dark mode has none, because a shadow on a deep indigo canvas reads as a smudge rather than a lift and
/// the hairline already does the work. `elevated` is for things that float over other content (tooltips,
/// popovers, a sheet's pinned control) and gets a slightly stronger shadow in both schemes.
public struct NoopPanelSurface: View {
    /// Ignored: cards carry no tint.
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    /// Ignored: cards are opaque.
    public var surfaceOpacity: Double
    @Environment(\.colorScheme) private var scheme
    @Environment(\.liquidGlass) private var glass

    public init(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.elevated = elevated
        self.surfaceOpacity = surfaceOpacity
    }

    public var body: some View {
        if glass.isEnabled {
            glassBody
        } else {
            solidBody
        }
    }

    /// The Liquid Glass panel: the same flat fill, hairline and shadow as the solid panel over a live blurred
    /// backdrop, with the body thinned by the glass intensity. Cards sample the backdrop at half
    /// resolution because a long list puts many of them on screen at once.
    private var glassBody: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let shadow = NoopSurfaceShadow.resolve(elevated: elevated, dark: scheme == .dark)
        return ZStack {
            LiquidGlassBackdrop(level: glass, scale: 0.5)
                .clipShape(shape)
            shape
                .fill(NoopVisualStyle.surface)
                .opacity(glass.bodyOpacity(scheme))
                .shadow(color: shadow.color.opacity(glass.shadowScale), radius: shadow.radius, x: 0, y: shadow.y)
            shape.strokeBorder(NoopVisualStyle.border.opacity(0.45), lineWidth: NoopMetrics.hairlineWidth)
            LiquidGlassHighlights(shape: shape, level: glass)
        }
    }

    /// The flat card: `surface` behind a hairline, with the one shared shadow.
    private var solidBody: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let shadow = NoopSurfaceShadow.resolve(elevated: elevated, dark: scheme == .dark)
        return shape
            .fill(NoopVisualStyle.surface)
            .overlay(shape.strokeBorder(NoopVisualStyle.border, lineWidth: NoopMetrics.hairlineWidth))
            .shadow(color: shadow.color, radius: shadow.radius, x: 0, y: shadow.y)
    }
}

/// The one shared card shadow, decided in one place so every surface lifts by the same amount.
enum NoopSurfaceShadow {
    struct Value { let color: Color; let radius: CGFloat; let y: CGFloat }

    static func resolve(elevated: Bool, dark: Bool) -> Value {
        switch (elevated, dark) {
        case (false, false): return Value(color: NaraBrand.deepIndigo.opacity(0.05), radius: 8, y: 2)
        case (false, true):  return Value(color: .clear, radius: 0, y: 0)
        case (true, false):  return Value(color: NaraBrand.deepIndigo.opacity(0.08), radius: 12, y: 4)
        case (true, true):   return Value(color: .black.opacity(0.28), radius: 12, y: 4)
        }
    }
}

/// A surface nested inside a card: a stat cell, a chip row, an inset list. `surfaceInset` at
/// `NoopMetrics.insetRadius`, with no border and no shadow, so it reads as a well in the card rather
/// than a second card stacked on the first.
///
/// ```swift
/// Text("62 ms").padding(12).background(NoopInsetSurface())
/// ```
public struct NoopInsetSurface: View {
    public var cornerRadius: CGFloat

    public init(cornerRadius: CGFloat = NoopMetrics.insetRadius) {
        self.cornerRadius = cornerRadius
    }

    public var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(NoopVisualStyle.inset)
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers: the flat card fill with a hairline
/// divider along the bottom edge, no outline and no elevation.
public struct NoopChromeSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.liquidGlass) private var glass

    public init() {}

    public var body: some View {
        NoopVisualStyle.surface
            .opacity(glass.bodyOpacity(scheme))
            .background {
                if glass.isEnabled {
                    LiquidGlassBackdrop(level: glass)
                }
            }
            .overlay(alignment: .top) {
                if glass.isEnabled {
                    LinearGradient(colors: [Color.white.opacity(glass.sheenOpacity), .clear],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 24)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(NoopVisualStyle.divider)
                    .frame(height: 0.5)
            }
    }
}

public extension View {
    func noopPanel(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopVisualStyle.cardRadius,
        elevated: Bool = false,
        surfaceOpacity: Double = 1
    ) -> some View {
        background {
            NoopPanelSurface(
                tint: tint,
                cornerRadius: cornerRadius,
                elevated: elevated,
                surfaceOpacity: surfaceOpacity
            )
        }
    }
}

#if DEBUG
private struct SurfacesPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Card").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                HStack(spacing: NoopMetrics.space2) {
                    ForEach(["Average", "Low", "High"], id: \.self) { label in
                        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                            Text(label).strandLabel()
                            Text("61 ms").font(StrandFont.number(20)).foregroundStyle(StrandPalette.textPrimary)
                        }
                        .padding(NoopMetrics.space3)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(NoopInsetSurface())
                    }
                }
            }
            .padding(NoopMetrics.cardPadding)
            .background(NoopPanelSurface(tint: StrandPalette.metricRose, surfaceOpacity: 0.4))
            Text("Elevated (tooltips, popovers)")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(NoopMetrics.space3)
                .background(NoopPanelSurface(cornerRadius: NoopMetrics.insetRadius, elevated: true))
            Text("Chrome")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, minHeight: 44)
                .background(NoopChromeSurface())
        }
        .padding(NoopMetrics.screenHPadding)
        .frame(width: 390)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Surfaces — light") {
    SurfacesPreview().preferredColorScheme(.light)
}

#Preview("Surfaces — dark") {
    SurfacesPreview().preferredColorScheme(.dark)
}
#endif

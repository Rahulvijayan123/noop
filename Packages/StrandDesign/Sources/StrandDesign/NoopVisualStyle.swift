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
    public static let sectionGap: CGFloat = 30
}

/// Shared card/panel treatment: a quiet vertical gradient, a top-lit rim, and deep soft elevation.
/// `tint` is intentionally faint so metric identity never turns the whole card into a coloured tile.
public struct NoopPanelSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var elevated: Bool
    public var surfaceOpacity: Double
    @Environment(\.colorScheme) private var scheme

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
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(
                LinearGradient(
                    colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay {
                if let tint {
                    shape.fill(
                        LinearGradient(
                            colors: [tint.opacity(0.055), tint.opacity(0.012), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay(
                shape.strokeBorder(
                    LinearGradient(
                        colors: [NoopVisualStyle.borderHighlight.opacity(0.72), NoopVisualStyle.border.opacity(0.52)],
                        startPoint: .top,
                        endPoint: .bottom
                    ),
                    lineWidth: 0.8
                )
            )
            .shadow(
                color: scheme == .dark ? .black.opacity(elevated ? 0.30 : 0.14)
                                       : NaraBrand.deepIndigo.opacity(elevated ? 0.10 : 0.05),
                radius: elevated ? 18 : 12,
                x: 0,
                y: elevated ? 8 : 4
            )
            .opacity(surfaceOpacity)
    }
}

/// Shared edge-to-edge chrome for sheet and split-view headers. Unlike a card it has no
/// rounded outline or elevation, but it uses the same top-lit surface ramp and divider token.
public struct NoopChromeSurface: View {
    public init() {}

    public var body: some View {
        LinearGradient(
            colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
            startPoint: .top,
            endPoint: .bottom
        )
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

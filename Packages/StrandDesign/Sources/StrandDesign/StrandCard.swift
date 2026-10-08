import SwiftUI

// MARK: - Card surface + StrandCard
//
// Every card in the app is the same surface: `NoopPanelSurface` at `NoopMetrics.cardRadius` (20) with no
// tint (docs/DESIGN_SYSTEM.md, Canvas and surfaces). `NoopCard`, `StrandCard`, `.frostedCardSurface()` and
// the app's `.naraCard()` all draw it through `FrostedCardSurface`, so the look lives in one place. Domain
// colour belongs to the data marks and icons inside a card, not to its fill, so the `tint` parameters below
// are accepted for source compatibility and ignored.

public extension View {
    /// The card surface as a background. `tint` and `washStrength` are ignored (cards carry no tint).
    func frostedCardSurface(
        tint: Color? = nil,
        cornerRadius: CGFloat = NoopMetrics.cardRadius,
        washStrength: Double = 1.0
    ) -> some View {
        background(FrostedCardSurface(tint: tint, cornerRadius: cornerRadius, washStrength: washStrength))
    }
}

/// The card background fill and border. Standalone so it can be a `.background { }` (animation never
/// reaches the card's content subtree — #104).
///
/// Solid: the "Card transparency" preference (`CardAppearancePrefs`) only existed to reveal the day-cycle
/// sky behind the cards, and the sky is gone, so the key is kept for backups and no longer read.
public struct FrostedCardSurface: View {
    public var tint: Color?
    public var cornerRadius: CGFloat
    public var washStrength: Double

    public init(tint: Color? = nil, cornerRadius: CGFloat = NoopMetrics.cardRadius, washStrength: Double = 1.0) {
        self.tint = tint
        self.cornerRadius = cornerRadius
        self.washStrength = washStrength
    }

    public var body: some View {
        NoopPanelSurface(tint: nil, cornerRadius: cornerRadius, elevated: false, surfaceOpacity: 1)
    }
}

// MARK: - StrandCard
//
// The older name for the card. Same surface and radius as `NoopCard`; new code uses `NoopCard`. Keeps the
// macOS hover lift via `.strandCardHover()`.

/// The card under its older name: `FrostedCardSurface` at `NoopMetrics.cardRadius`. Prefer `NoopCard`.
public struct StrandCard<Content: View>: View {

    public var padding: CGFloat
    public var cornerRadius: CGFloat
    /// Ignored: cards carry no tint.
    public var tint: Color?
    @ViewBuilder public var content: () -> Content

    public init(
        padding: CGFloat = NoopMetrics.cardPadding,
        cornerRadius: CGFloat = NoopMetrics.cardRadius,
        tint: Color? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.padding = padding
        self.cornerRadius = cornerRadius
        self.tint = tint
        self.content = content
    }

    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface(tint: tint, cornerRadius: cornerRadius)
            .strandCardHover(cornerRadius: cornerRadius)
    }
}

// MARK: - Hover lift modifier

/// The mandated hover behavior: shadow-md + translateY(-1px) and a hairline →
/// hairline.strong border on hover. Apply to any card-like surface.
public struct StrandCardHover: ViewModifier {
    public var cornerRadius: CGFloat
    @State private var hovering = false
    @Environment(\.colorScheme) private var scheme

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius) {
        self.cornerRadius = cornerRadius
    }

    public func body(content: Content) -> some View {
        content
            // Hover emphasis: brighten the hairline edge (the frosted surface owns the
            // resting border) and add the mandated lift (shadow + translateY(-1px)).
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(hovering ? 1 : 0)
            )
            // Incremental hover lift on top of the surface's resting elevation: a warm soft shadow on
            // light (the white card lifts off the paper), the signature black on dark.
            .shadow(
                color: hovering ? (scheme == .light ? Color(hex: "#1A2230").opacity(0.16)
                                                     : Color.black.opacity(0.45)) : .clear,
                radius: hovering ? (scheme == .light ? 14 : 16) : 0,
                x: 0,
                y: hovering ? (scheme == .light ? 6 : 10) : 0
            )
            .offset(y: hovering ? -1 : 0)
            .animation(StrandMotion.interactive, value: hovering)
            // .onHover is unavailable on watchOS (no pointer); the watch never hovers a card.
            #if !os(watchOS)
            .onHover { hovering = $0 }
            #endif
    }
}

public extension View {
    /// Apply the Strand card hover lift (shadow + -1px translate + border emphasis).
    func strandCardHover(cornerRadius: CGFloat = NoopMetrics.cardRadius) -> some View {
        modifier(StrandCardHover(cornerRadius: cornerRadius))
    }
}

// MARK: - Touch press feedback (iOS) — the hover lift's touch analogue.
//
// `.onHover` never fires on a touchscreen, so tappable cards/rows feel dead on iPhone.
// This gives a subtle press-DOWN state (scale + edge emphasis) for direct manipulation,
// honouring Reduce Motion (which swaps the transform for a gentle dim). It's additive to
// the hover lift: hover (pointer NEAR) and pressed (finger/click DOWN) animate distinct
// properties on the shared StrandMotion.interactive spring, so they compose without a
// double-bounce. Exposed two ways — a ButtonStyle for Button/NavigationLink-as-card (the
// `.plain` replacement), and a `.strandPressable()` modifier for `.onTapGesture`-driven cards.

/// Drop-in replacement for `.buttonStyle(.plain)` on full-card Buttons / NavigationLinks:
/// a subtle press-down scale + hairline-strong edge.
public struct StrandPressableButtonStyle: ButtonStyle {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = 0.985) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(reduceMotion && pressed ? 0.82 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Backs `.strandPressable()` — a press-down state for cards driven by `.onTapGesture`
/// (no Button). A 0-distance drag tracks the finger; @GestureState auto-resets on release
/// or when a parent scroll claims the gesture.
public struct StrandPressableModifier: ViewModifier {
    public var cornerRadius: CGFloat
    public var scale: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var pressed = false

    public init(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = 0.985) {
        self.cornerRadius = cornerRadius
        self.scale = scale
    }

    public func body(content: Content) -> some View {
        content
            .scaleEffect(reduceMotion ? 1 : (pressed ? scale : 1))
            .opacity(reduceMotion && pressed ? 0.82 : 1)
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1)
                    .opacity(pressed ? 1 : 0)
            )
            .animation(StrandMotion.interactive, value: pressed)
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .updating($pressed) { _, state, _ in state = true }
            )
    }
}

public extension View {
    /// Subtle touch press-down feedback for a tappable card/row that uses `.onTapGesture`
    /// (not a Button). For Buttons/NavigationLinks, use `StrandPressableButtonStyle` instead.
    func strandPressable(cornerRadius: CGFloat = NoopMetrics.cardRadius, scale: CGFloat = 0.985) -> some View {
        modifier(StrandPressableModifier(cornerRadius: cornerRadius, scale: scale))
    }
}

#if DEBUG && !os(watchOS)
#Preview("StrandCard") {
    VStack(spacing: 16) {
        StrandCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Sleep performance").strandOverline()
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("87").font(StrandFont.number(34)).foregroundStyle(StrandPalette.textPrimary)
                    Text("%").font(StrandFont.headline).foregroundStyle(StrandPalette.textTertiary)
                }
                Text("7h 42m asleep · 92% efficiency")
                    .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        StrandCard {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Resting HR").strandOverline()
                    Text("51 bpm").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
                }
                Spacer()
                Sparkline(values: (0..<30).map { i -> Double in 50 + 4 * sin(Double(i) / 5) })
                    .frame(width: 120, height: 40)
            }
        }
        Text("Hover the cards to see the lift.")
            .font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
    }
    .padding(28)
    .frame(width: 420, height: 360)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif

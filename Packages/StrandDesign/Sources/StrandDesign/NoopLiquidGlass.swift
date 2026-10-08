import SwiftUI
#if os(iOS)
import AemiSDR
#endif

// MARK: - Liquid Glass
//
// The app-wide glass material, drawn with the vendored AemiSDR renderer (Packages/AemiSDR). One setting
// drives every surface that reads `\.liquidGlass`: cards and panels (`NoopPanelSurface`), edge-to-edge
// chrome (`NoopChromeSurface`), buttons, the header controls, search fields and the floating tab bar.
//
// At 0 the app is exactly the solid Titanium look it always had, including the platform's own iOS 26
// controls. Above 0 a surface blurs and saturates what is behind it (AemiSDR's backdrop blur), lets it
// show through a thinner body, and gains a specular sheen and rim light; floating controls also refract
// their backdrop through AemiSDR's Metal lens. All of it scales with the setting.
//
// The environment default is OFF so the widget and watch extensions, which share these surfaces but can
// host neither UIKit views nor a backdrop, never pick the glass up. Only an app root opts in, through
// `.liquidGlass(percent:)`.

/// The Liquid Glass intensity setting, as a percent. Device-local, like the other appearance choices.
public enum LiquidGlassPrefs {
    public static let intensityKey = "noop.liquidGlassIntensity"
    public static let defaultPercent = 70
    public static let range = 0...100
}

/// Every glass parameter, resolved from one intensity.
public struct LiquidGlassLevel: Equatable, Sendable {
    /// 0 (off) … 1 (full).
    public let amount: Double

    public init(percent: Int) {
        amount = min(1, max(0, Double(percent) / 100))
    }

    public static let off = LiquidGlassLevel(percent: 0)

    public var isEnabled: Bool { amount > 0 }

    /// Backdrop blur radius, in points.
    public var blurRadius: CGFloat { 6 + 24 * amount }
    /// Backdrop saturation multiplier: glass reads richer than what is behind it.
    public var saturation: CGFloat { 1.05 + 0.75 * amount }

    /// How much of a surface's solid body is kept. The floor keeps text on the glass legible at full
    /// strength over the busiest backdrop the app draws (the day-cycle sky, a custom photo).
    public func bodyOpacity(_ scheme: ColorScheme) -> Double {
        let floor = scheme == .dark ? 0.44 : 0.40
        return 1 - (1 - floor) * amount
    }

    /// The same, for a surface that is a solid colour by meaning (a filled primary button).
    public var tintedBodyOpacity: Double { 1 - 0.28 * amount }

    public var sheenOpacity: Double { 0.18 * amount }
    public var rimOpacity: Double { 0.62 * amount }
    /// The drop shadow is thinned as the body thins, or it would show through the glass as a smudge.
    public var shadowScale: Double { 1 - 0.55 * amount }

    /// Metal lens strength for floating controls. Zero below 15% so a faint setting stays a pure blur.
    public var refractionStrength: Float { amount < 0.15 ? 0 : Float(0.35 + 0.65 * amount) }
}

private struct LiquidGlassKey: EnvironmentKey {
    static let defaultValue = LiquidGlassLevel.off
}

public extension EnvironmentValues {
    /// The Liquid Glass level surfaces draw with. `.off` unless an app root sets it.
    var liquidGlass: LiquidGlassLevel {
        get { self[LiquidGlassKey.self] }
        set { self[LiquidGlassKey.self] = newValue }
    }
}

public extension View {
    /// Opts this hierarchy into Liquid Glass at the given intensity percent. Reduce Transparency wins:
    /// it turns the glass off, matching what the platform does with its own materials.
    func liquidGlass(percent: Int) -> some View {
        modifier(LiquidGlassRoot(percent: percent))
    }
}

private struct LiquidGlassRoot: ViewModifier {
    let percent: Int
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    func body(content: Content) -> some View {
        content.environment(\.liquidGlass, reduceTransparency ? .off : LiquidGlassLevel(percent: percent))
    }
}

// MARK: - Glass layers

/// The live, blurred backdrop: AemiSDR's backdrop blur, which the render server composites from whatever
/// is behind the view, so it follows scrolling and animation at no per-frame cost to the app.
/// `scale` below 1 samples the backdrop at a lower resolution, which the blur hides and the GPU likes.
struct LiquidGlassBackdrop: View {
    let level: LiquidGlassLevel
    var scale: CGFloat = 1

    var body: some View {
        #if os(iOS)
        BackdropBlurView(configuration: BackdropBlurConfiguration(
            blurRadius: level.blurRadius,
            scale: scale,
            saturationDeltaFactor: level.saturation
        ))
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        #else
        Color.clear
        #endif
    }
}

/// Specular sheen across the top of the glass plus a rim light that is brightest on the top-leading
/// edge, where the light comes from, and returns faintly on the bottom-trailing edge.
struct LiquidGlassHighlights<S: InsettableShape>: View {
    let shape: S
    let level: LiquidGlassLevel
    var pressed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // On the light canvas a white rim vanishes against a white body, so it leans on the ink colour.
        let rimColor = scheme == .dark ? Color.white : NaraBrand.deepIndigo
        let rim = level.rimOpacity * (scheme == .dark ? 1 : 0.30)
        let sheen = level.sheenOpacity * (pressed ? 1.8 : 1)
        ZStack {
            shape.fill(
                LinearGradient(
                    colors: [Color.white.opacity(sheen), Color.white.opacity(sheen * 0.25), .clear],
                    startPoint: .top,
                    endPoint: UnitPoint(x: 0.5, y: 0.6)
                )
            )
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        rimColor.opacity(rim),
                        rimColor.opacity(rim * 0.10),
                        rimColor.opacity(rim * 0.10),
                        rimColor.opacity(rim * 0.45),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
            // A thin inner light just inside the rim gives the edge its thickness.
            shape.inset(by: 1.5).strokeBorder(Color.white.opacity(level.rimOpacity * 0.16), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }
}

/// Liquid Glass for a floating control: blurred backdrop, Metal-refracted edges, a thin body, highlights.
/// `body` is the control's resting fill (nil = the neutral surface ramp).
struct LiquidGlassControlBackground<S: InsettableShape>: View {
    let shape: S
    let level: LiquidGlassLevel
    var tint: Color? = nil
    var refraction = true
    var pressed = false
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            LiquidGlassBackdrop(level: level)
                .clipShape(shape)
            if let tint {
                shape.fill(tint).opacity(level.tintedBodyOpacity)
            } else {
                shape.fill(
                    LinearGradient(
                        colors: [NoopVisualStyle.surfaceTop, NoopVisualStyle.surfaceBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                // Controls float over content, so they keep less body than a card.
                .opacity(level.bodyOpacity(scheme) * 0.72)
            }
            LiquidGlassHighlights(shape: shape, level: level, pressed: pressed)
        }
        .modifier(LiquidGlassRefraction(shape: shape, level: level, enabled: refraction))
    }
}

/// AemiSDR's Metal lens behind the glass: it captures the layers above it and bends them through a
/// curved water surface, strongest at the rim. It runs a display link, so it is reserved for the few
/// floating controls, never for cards in a scrolling list.
private struct LiquidGlassRefraction<S: InsettableShape>: ViewModifier {
    let shape: S
    let level: LiquidGlassLevel
    let enabled: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(iOS)
        if enabled, level.refractionStrength > 0, !reduceMotion {
            content.liquidBackground(
                LiquidGlassConfiguration(
                    strength: level.refractionStrength,
                    lensCurvature: 1.0,
                    falloff: .easeInOut,
                    falloffLength: 1.0,
                    falloffIntensity: 1.0,
                    chromaticAmount: Float(3 * level.amount),
                    material: .water,
                    refreshRate: 60,
                    captureScale: 0.5,
                    diagonalBand: 0
                ),
                shape: shape,
                ignoreSafeArea: false
            )
        } else {
            content
        }
        #else
        content
        #endif
    }
}

// MARK: - Glass controls

public extension View {
    /// Liquid Glass behind a floating control (a header button, a pill, a search field, a bar).
    /// `tint` gives the glass a solid-colour body, as for a filled button.
    func noopGlassControl<S: InsettableShape>(
        in shape: S,
        tint: Color? = nil,
        refraction: Bool = true
    ) -> some View {
        modifier(NoopGlassControlModifier(shape: shape, tint: tint, refraction: refraction))
    }
}

private struct NoopGlassControlModifier<S: InsettableShape>: ViewModifier {
    let shape: S
    let tint: Color?
    let refraction: Bool
    @Environment(\.liquidGlass) private var level

    func body(content: Content) -> some View {
        content
            .background {
                LiquidGlassControlBackground(shape: shape, level: level, tint: tint, refraction: refraction)
            }
            .contentShape(shape)
    }
}

/// A button drawn as a piece of Liquid Glass. The glass flexes on press: it sinks slightly and the sheen
/// brightens, the touch analogue of the platform's interactive glass.
public struct NoopGlassButtonStyle<S: InsettableShape>: ButtonStyle {
    private let shape: S
    private let padding: CGFloat
    private let tint: Color?
    @Environment(\.liquidGlass) private var level
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init(shape: S, controlSize: ControlSize = .small, tint: Color? = nil) {
        self.shape = shape
        self.tint = tint
        switch controlSize {
        case .mini: padding = 4
        case .small: padding = 6
        case .large: padding = 10
        default: padding = 8
        }
    }

    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .padding(padding)
            .background {
                LiquidGlassControlBackground(shape: shape, level: level, tint: tint, pressed: pressed)
            }
            .contentShape(shape)
            .scaleEffect(pressed && !reduceMotion ? 0.94 : 1)
            .opacity(isEnabled ? 1 : 0.5)
            .animation(reduceMotion ? nil : StrandMotion.interactive, value: pressed)
    }
}

/// Picks the Liquid Glass rendering while the setting is on and the app's original rendering while it is
/// off, so 0% leaves every control exactly as it was before the setting existed.
public struct LiquidGlassSwitch<Glass: View, Original: View>: View {
    private let glass: Glass
    private let original: Original
    @Environment(\.liquidGlass) private var level

    public init(@ViewBuilder glass: () -> Glass, @ViewBuilder original: () -> Original) {
        self.glass = glass()
        self.original = original()
    }

    public var body: some View {
        if level.isEnabled { glass } else { original }
    }
}

// MARK: - Floating glass tab bar

/// One destination in `NoopGlassTabBar`.
public struct NoopGlassTabItem: Identifiable {
    public let tag: Int
    public let title: LocalizedStringKey
    public let systemImage: String
    /// Stable UI-test handle, e.g. "tab.sana".
    public let identifier: String

    public var id: Int { tag }

    public init(tag: Int, title: LocalizedStringKey, systemImage: String, identifier: String) {
        self.tag = tag
        self.title = title
        self.systemImage = systemImage
        self.identifier = identifier
    }
}

/// The bottom navigation as a floating capsule of Liquid Glass. The selected tab sits on a lens of
/// brighter glass that slides between items. Tapping the selected tab calls `onReselect`, which is how
/// the shell keeps its pop-to-root / scroll-to-top convention.
public struct NoopGlassTabBar: View {
    private let items: [NoopGlassTabItem]
    @Binding private var selection: Int
    private let onReselect: (Int) -> Void
    @Namespace private var selectionSpace
    @Environment(\.liquidGlass) private var level
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(items: [NoopGlassTabItem], selection: Binding<Int>, onReselect: @escaping (Int) -> Void) {
        self.items = items
        self._selection = selection
        self.onReselect = onReselect
    }

    public var body: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                tabButton(item)
            }
        }
        .padding(4)
        .background {
            LiquidGlassControlBackground(shape: Capsule(style: .continuous), level: level)
        }
        .shadow(color: .black.opacity(scheme == .dark ? 0.32 : 0.12), radius: 18, x: 0, y: 8)
        .padding(.horizontal, 20)
        .padding(.bottom, 4)
        .accessibilityElement(children: .contain)
    }

    private func tabButton(_ item: NoopGlassTabItem) -> some View {
        let selected = item.tag == selection
        return Button {
            if selected {
                onReselect(item.tag)
            } else {
                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.78)) {
                    selection = item.tag
                }
            }
        } label: {
            VStack(spacing: 3) {
                Image(systemName: item.systemImage)
                    .font(.system(size: 19, weight: .medium))
                    .frame(height: 24)
                Text(item.title)
                    .font(.system(size: 10, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 54)
            .background {
                if selected {
                    selectionLens
                        .matchedGeometryEffect(id: "selection", in: selectionSpace)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(GlassTabPressStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(item.identifier)
    }

    /// The selected item's brighter glass: more body, a stronger rim.
    private var selectionLens: some View {
        let shape = Capsule(style: .continuous)
        return ZStack {
            shape.fill(Color.white.opacity(scheme == .dark ? 0.10 + 0.06 * level.amount : 0.55))
            LiquidGlassHighlights(shape: shape, level: LiquidGlassLevel(percent: Int(min(1, level.amount + 0.25) * 100)))
        }
    }
}

private struct GlassTabPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.92 : 1)
            .animation(reduceMotion ? nil : StrandMotion.interactive, value: configuration.isPressed)
    }
}

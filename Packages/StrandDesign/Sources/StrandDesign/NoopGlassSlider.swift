import SwiftUI

// MARK: - Glass slider
//
// A slider drawn with the app's own Liquid Glass helpers (`LiquidGlassControlBackground`, `LiquidGlassSwitch`):
// a glass track and a glass thumb that refracts what is under it and swells while it is held, the way the
// platform's iOS 26 slider behaves. It draws the same on every supported iOS because the glass is the app's
// (AemiSDR), not the platform's. At 0% glass the thumb is a plain raised capsule on a flat track.
//
// With `step` the thumb follows the finger freely and the value snaps to the nearest stop as it passes (with a
// selection tick); on release the thumb settles onto the stop. `thumbWidth: .fraction(1 / n)` over `n` stops
// makes the thumb one stop wide, so at rest it sits exactly over its stop (the glass tab bar uses this to
// line the thumb up with a tab).

public struct NoopGlassSlider: View {
    public enum ThumbWidth {
        case fixed(CGFloat)
        /// A fraction of the track's usable width (its width less the edge inset on both sides).
        case fraction(CGFloat)
    }

    @Binding private var value: Double
    private let range: ClosedRange<Double>
    private let step: Double?
    private let thumbWidth: ThumbWidth
    private let edgeInset: CGFloat
    private let showsFill: Bool
    private let showsTicks: Bool
    private let label: LocalizedStringKey
    private let valueText: (Double) -> String
    private let identifier: String?

    @State private var dragFraction: CGFloat?
    @Environment(\.liquidGlass) private var level
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    public init(
        value: Binding<Double>,
        in range: ClosedRange<Double> = 0...1,
        step: Double? = nil,
        thumbWidth: ThumbWidth = .fixed(44),
        edgeInset: CGFloat = 2,
        showsFill: Bool = true,
        showsTicks: Bool = false,
        label: LocalizedStringKey,
        valueText: @escaping (Double) -> String = { String(Int($0.rounded())) },
        identifier: String? = nil
    ) {
        self._value = value
        self.range = range
        self.step = step
        self.thumbWidth = thumbWidth
        self.edgeInset = edgeInset
        self.showsFill = showsFill
        self.showsTicks = showsTicks
        self.label = label
        self.valueText = valueText
        self.identifier = identifier
    }

    // MARK: Value maths

    private var span: Double { range.upperBound - range.lowerBound }

    private func fraction(of v: Double) -> CGFloat {
        span > 0 ? CGFloat(min(1, max(0, (v - range.lowerBound) / span))) : 0
    }

    private func snapped(_ raw: Double) -> Double {
        let clamped = min(range.upperBound, max(range.lowerBound, raw))
        guard let step, step > 0 else { return clamped }
        let stops = ((clamped - range.lowerBound) / step).rounded()
        return min(range.upperBound, range.lowerBound + stops * step)
    }

    private var stopCount: Int {
        guard let step, step > 0, span > 0 else { return 0 }
        return Int((span / step).rounded()) + 1
    }

    // MARK: Body

    public var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let usable = max(0, width - 2 * edgeInset)
            let thumbW: CGFloat = {
                switch thumbWidth {
                case .fixed(let w): return min(w, usable)
                case .fraction(let f): return min(usable, max(height, usable * f))
                }
            }()
            let travel = max(0, usable - thumbW)
            let shown = dragFraction ?? fraction(of: value)
            let thumbX = edgeInset + travel * shown
            let pressed = dragFraction != nil

            ZStack(alignment: .leading) {
                track(height: height)
                if showsFill {
                    Capsule(style: .continuous)
                        .fill(StrandPalette.accent.opacity(0.30))
                        .frame(width: thumbX + thumbW / 2, height: height)
                        .allowsHitTesting(false)
                }
                if showsTicks, stopCount > 1 {
                    ForEach(0..<stopCount, id: \.self) { i in
                        Circle()
                            .fill(StrandPalette.textTertiary.opacity(0.55))
                            .frame(width: 3.5, height: 3.5)
                            .position(x: edgeInset + thumbW / 2 + travel * CGFloat(i) / CGFloat(stopCount - 1), y: height / 2)
                    }
                    .allowsHitTesting(false)
                }
                thumb(pressed: pressed)
                    .frame(width: thumbW, height: max(0, height - 4))
                    .scaleEffect(pressed && !reduceMotion ? 1.08 : 1)
                    .offset(x: thumbX, y: 0)
                    .animation(reduceMotion ? nil : StrandMotion.interactive, value: pressed)
                    .allowsHitTesting(false)
            }
            .frame(width: width, height: height, alignment: .leading)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = travel > 0 ? CGFloat(min(1, max(0, (g.location.x - edgeInset - thumbW / 2) / travel))) : 0
                        dragFraction = f
                        let next = snapped(range.lowerBound + Double(f) * span)
                        if next != value {
                            value = next
                            StrandHaptic.selection.play()
                        }
                    }
                    .onEnded { _ in
                        withAnimation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.8)) {
                            dragFraction = nil
                        }
                    }
            )
        }
        .opacity(isEnabled ? 1 : 0.5)
        .animation(reduceMotion ? nil : .spring(response: 0.34, dampingFraction: 0.8), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(valueText(value))
        .accessibilityAdjustableAction { direction in
            let delta = step ?? max(span / 10, .leastNonzeroMagnitude)
            switch direction {
            case .increment: value = snapped(value + delta)
            case .decrement: value = snapped(value - delta)
            @unknown default: break
            }
        }
        .accessibilityIdentifier(identifier ?? "")
    }

    // MARK: Parts

    private func track(height: CGFloat) -> some View {
        let shape = Capsule(style: .continuous)
        return LiquidGlassSwitch {
            LiquidGlassControlBackground(shape: shape, level: level, refraction: false)
                .overlay { shape.fill(Color.black.opacity(scheme == .dark ? 0.20 : 0.04)) }
        } original: {
            shape.fill(StrandPalette.surfaceInset)
                .overlay { shape.strokeBorder(StrandPalette.hairline, lineWidth: 0.5) }
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }

    private func thumb(pressed: Bool) -> some View {
        let shape = Capsule(style: .continuous)
        return LiquidGlassSwitch {
            ZStack {
                LiquidGlassControlBackground(shape: shape, level: level, pressed: pressed)
                shape.fill(Color.white.opacity(scheme == .dark ? 0.12 + 0.06 * level.amount : 0.50))
            }
            .shadow(color: .black.opacity(0.16 * level.shadowScale), radius: pressed ? 9 : 5, x: 0, y: pressed ? 4 : 2)
        } original: {
            shape.fill(Color.white)
                .overlay { shape.strokeBorder(StrandPalette.hairline, lineWidth: 0.5) }
                .shadow(color: .black.opacity(0.18), radius: 3, x: 0, y: 1)
        }
    }
}

import SwiftUI

// MARK: - Range strips and the typical-range bar
//
// "Solid = you, hatch = the context." Small horizontal strips that place one value against a range:
//
//   • `RangeStrip`       — a value on a REAL domain (56 bpm on a 40…80 bpm strip): the usual band (hatched or
//                          filled), an optional reference tick (what was expected) and a dot for the value.
//                          For vitals, where zero means nothing, this is the one to use.
//   • `TypicalRangeBar`  — a 0…1 fill from the left over a hatched typical range, for shares and proportions
//                          (a sleep stage's share of the night). Never use the fill for a vital.
//   • `TypicalRangeRow`  — swatch · label · coloured value · bar · trailing text, in sentence case.
//
// Tokens only, light/dark safe, cross-platform (no UIKit/AppKit), VoiceOver-summarised.

// MARK: - Diagonal hatch shape

/// A field of parallel 45° diagonal lines clipped to the shape's rect — the "typical range" texture.
/// Spacing/inset are in points so the hatch density stays constant regardless of bar width.
public struct DiagonalHatch: Shape {
    /// Gap between hatch lines, in points.
    public var spacing: CGFloat
    public init(spacing: CGFloat = 5) { self.spacing = spacing }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0, spacing > 0 else { return path }
        // Draw lines running bottom-left → top-right (45°). Start far enough left that the slanted
        // lines still cover the full rect after the diagonal offset, then clip to the rect.
        var x = rect.minX - rect.height
        while x <= rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height, y: rect.minY))
            x += spacing
        }
        return path
    }
}

// MARK: - RangeStrip

/// One value placed on a real domain against a band, e.g. a reading against Watchdog's expected range.
///
/// ```swift
/// RangeStrip(domain: 40...90, band: 56...72, reference: 64, marker: 81,
///            markerColor: StrandPalette.statusWarning)
/// ```
///
/// The track spans `domain`; `band` is drawn hatched (a range, not a quantity) or, with `bandStyle: .filled`,
/// as a light fill; `reference` is a thin tick (the expected value); `marker` is a dot in `markerColor`.
/// Values outside the domain are pinned to its edge. Decorative to VoiceOver by default: the row beside it
/// says the numbers; pass `accessibilityText` to make the strip its own element.
public struct RangeStrip: View {
    public enum BandStyle: Sendable { case hatched, filled }

    public var domain: ClosedRange<Double>
    public var band: ClosedRange<Double>?
    public var bandStyle: BandStyle
    public var reference: Double?
    public var marker: Double?
    public var markerColor: Color
    public var height: CGFloat
    public var accessibilityText: String?

    public init(domain: ClosedRange<Double>, band: ClosedRange<Double>? = nil, bandStyle: BandStyle = .hatched,
                reference: Double? = nil, marker: Double? = nil,
                markerColor: Color = StrandPalette.textPrimary, height: CGFloat = 10,
                accessibilityText: String? = nil) {
        self.domain = domain
        self.band = band
        self.bandStyle = bandStyle
        self.reference = reference
        self.marker = marker
        self.markerColor = markerColor
        self.height = height
        self.accessibilityText = accessibilityText
    }

    /// Where `value` sits along `domain`, 0…1, pinned to the ends. Pure.
    public static func fraction(_ value: Double, in domain: ClosedRange<Double>) -> Double {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0, value.isFinite else { return 0.5 }
        return min(1, max(0, (value - domain.lowerBound) / span))
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = height
            let track = Capsule(style: .continuous)
            ZStack(alignment: .leading) {
                track.fill(StrandPalette.surfaceInset)
                    .frame(height: h)
                if let band, band.upperBound > band.lowerBound {
                    let x0 = w * Self.fraction(band.lowerBound, in: domain)
                    let x1 = w * Self.fraction(band.upperBound, in: domain)
                    let segment = RoundedRectangle(cornerRadius: min(h / 2, max(0, x1 - x0) / 2), style: .continuous)
                    Group {
                        switch bandStyle {
                        case .hatched:
                            ZStack {
                                segment.fill(StrandPalette.textTertiary.opacity(0.10))
                                DiagonalHatch(spacing: 4)
                                    .stroke(StrandPalette.textTertiary.opacity(0.55), lineWidth: 1)
                                    .clipShape(segment)
                            }
                        case .filled:
                            segment.fill(StrandPalette.textTertiary.opacity(0.22))
                        }
                    }
                    .frame(width: max(0, x1 - x0), height: h)
                    .offset(x: x0)
                }
                if let reference {
                    Rectangle()
                        .fill(StrandPalette.textSecondary)
                        .frame(width: 1.5, height: h + 6)
                        .offset(x: w * Self.fraction(reference, in: domain) - 0.75)
                }
                if let marker {
                    let d = h + 4
                    Circle()
                        .fill(markerColor)
                        .overlay(Circle().strokeBorder(StrandPalette.surfaceRaised, lineWidth: 1.5))
                        .frame(width: d, height: d)
                        .offset(x: min(max(0, w * Self.fraction(marker, in: domain) - d / 2), max(0, w - d)))
                }
            }
            .frame(width: w, height: geo.size.height)
        }
        .frame(height: height + 6)
        .modifier(RangeStripAccessibility(text: accessibilityText))
    }
}

private struct RangeStripAccessibility: ViewModifier {
    let text: String?
    func body(content: Content) -> some View {
        if let text {
            content.accessibilityElement(children: .ignore).accessibilityLabel(Text(text))
        } else {
            content.accessibilityHidden(true)
        }
    }
}

// MARK: - TypicalRangeBar

public struct TypicalRangeBar: View {

    /// The user's value as a 0…1 fraction of the bar's full width (clamped).
    public var value: Double
    /// The typical / reference range as 0…1 fractions (lower…upper) of the bar (clamped, ordered).
    /// nil = no range → the value fill sits over a plain inset track (no hatch).
    public var typical: ClosedRange<Double>?
    /// The solid fill colour for the user's value (the domain / stage / status token).
    public var color: Color
    /// Bar height. Kept short so it reads as a row element.
    public var height: CGFloat
    /// Corner radius of the bar; defaults to fully-rounded for the WHOOP pill look.
    public var cornerRadius: CGFloat?

    public init(
        value: Double,
        typical: ClosedRange<Double>? = nil,
        color: Color,
        height: CGFloat = 8,
        cornerRadius: CGFloat? = nil
    ) {
        self.value = value
        self.typical = typical
        self.color = color
        self.height = height
        self.cornerRadius = cornerRadius
    }

    private var clampedValue: Double { min(max(value, 0), 1) }

    /// The typical range clamped to 0…1 and ordered low→high, or nil.
    private var clampedTypical: ClosedRange<Double>? {
        guard let t = typical else { return nil }
        let lo = min(max(t.lowerBound, 0), 1)
        let hi = min(max(t.upperBound, 0), 1)
        return lo <= hi ? lo...hi : hi...lo
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            let radius = cornerRadius ?? h / 2
            let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

            ZStack(alignment: .leading) {
                // Base track — the inset "well" the bar sits in.
                shape.fill(StrandPalette.surfaceInset)

                // Diagonal-hatch "typical range" segment (only over the range span).
                if let t = clampedTypical, t.upperBound > t.lowerBound {
                    let x = w * CGFloat(t.lowerBound)
                    let segWidth = w * CGFloat(t.upperBound - t.lowerBound)
                    DiagonalHatch(spacing: 5)
                        .stroke(StrandPalette.textTertiary.opacity(0.55), lineWidth: 1)
                        .frame(width: segWidth, height: h)
                        .clipShape(RoundedRectangle(cornerRadius: min(radius, segWidth / 2), style: .continuous))
                        .offset(x: x)
                        .accessibilityHidden(true)
                }

                // Solid value fill — "you". Flat + crisp, no glow.
                shape
                    .fill(color)
                    .frame(width: max(h, w * CGFloat(clampedValue)))
            }
            .clipShape(shape)
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(axLabel))
    }

    private var axLabel: String {
        let pct = Int((clampedValue * 100).rounded())
        if let t = clampedTypical {
            let lo = Int((t.lowerBound * 100).rounded())
            let hi = Int((t.upperBound * 100).rounded())
            let placement = clampedValue < t.lowerBound ? "below" : (clampedValue > t.upperBound ? "above" : "within")
            return "\(pct) percent, \(placement) the typical range of \(lo) to \(hi) percent"
        }
        return "\(pct) percent"
    }
}

// MARK: - TypicalRangeRow (full WHOOP detail row)

/// One range row: a leading colour swatch, a sentence-case label, the value tinted to the stage/domain
/// colour, the hatched range bar, and a right-aligned trailing string in `textPrimary` (e.g. a duration
/// like "1:24").
public struct TypicalRangeRow: View {

    /// Sentence-case label (e.g. "Deep", "REM", "HRV").
    public var label: String
    /// The coloured value string shown next to the label (e.g. "18%"). nil hides it.
    public var valueText: String?
    /// Right-aligned trailing string (e.g. a duration "1:24" or "62 ms"). nil hides it.
    public var trailingText: String?
    /// The user's value 0…1 fraction for the bar.
    public var value: Double
    /// The typical range 0…1, or nil for no hatch.
    public var typical: ClosedRange<Double>?
    /// The stage / domain colour (swatch, value tint, value fill).
    public var color: Color

    public init(
        label: String,
        valueText: String? = nil,
        trailingText: String? = nil,
        value: Double,
        typical: ClosedRange<Double>? = nil,
        color: Color
    ) {
        self.label = label
        self.valueText = valueText
        self.trailingText = trailingText
        self.value = value
        self.typical = typical
        self.color = color
    }

    public var body: some View {
        HStack(spacing: 10) {
            // Colour swatch.
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 12)
                .accessibilityHidden(true)

            // Label + coloured value.
            HStack(spacing: 6) {
                Text(label)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let valueText {
                    Text(valueText)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(color)
                }
            }
            .frame(width: 96, alignment: .leading)

            // The hatched range bar.
            TypicalRangeBar(value: value, typical: typical, color: color)

            // Right-aligned trailing (duration / raw value).
            if let trailingText {
                Text(trailingText)
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .frame(minWidth: 44, alignment: .trailing)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(axLabel))
    }

    private var axLabel: String {
        var parts: [String] = [label]
        if let valueText { parts.append(valueText) }
        if let trailingText { parts.append(trailingText) }
        let base = parts.joined(separator: ", ")
        guard let t = typical else { return base }
        let v = min(max(value, 0), 1)
        let placement = v < t.lowerBound ? "below typical" : (v > t.upperBound ? "above typical" : "within typical range")
        return "\(base), \(placement)"
    }
}

#if DEBUG
private struct RangeStripsPreview: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Against the expected range").font(StrandFont.headline)
            RangeStrip(domain: 40...100, band: 55...73, reference: 64, marker: 91,
                       markerColor: StrandPalette.statusWarning)
            RangeStrip(domain: 20...70, band: 37...55, reference: 46, marker: 44)
            RangeStrip(domain: 12...18, band: 13.4...15.8, bandStyle: .filled, marker: 14.2)
            Text("Sleep stages").font(StrandFont.headline).padding(.top, 8)
            VStack(spacing: 10) {
                TypicalRangeRow(label: "Light", valueText: "52%", trailingText: "4:02",
                                value: 0.52, typical: 0.45...0.60, color: StrandPalette.sleepLight)
                TypicalRangeRow(label: "Deep", valueText: "18%", trailingText: "1:24",
                                value: 0.18, typical: 0.12...0.23, color: StrandPalette.sleepDeep)
            }
        }
        .padding(NoopMetrics.screenHPadding)
        .frame(width: 390)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Range strips · light") { RangeStripsPreview().preferredColorScheme(.light) }
#Preview("Range strips · dark") { RangeStripsPreview().preferredColorScheme(.dark) }
#endif

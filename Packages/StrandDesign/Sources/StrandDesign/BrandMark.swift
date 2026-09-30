import SwiftUI

// MARK: - BrandMark — the Nara logo mark
//
// The "N" with a molecular cross: a stem and a 45° diagonal that ends in a short squared foot, plus a
// thin cross whose arms end in small nodes around one larger node. Drawn natively (not an image) so it
// stays crisp from a 22pt sidebar glyph to the onboarding hero and the rendered app icons.
//
// Geometry is traced from the master artwork on a 153-unit square, so every proportion scales off one
// `size`. The ink is Deep Indigo on light and Lavender White on dark.

public struct BrandMark: View {

    public enum Style: Sendable {
        /// The bare mark in brand ink — for onboarding, headers and report lock-ups.
        case mark
        /// The mark knocked out of a Deep Indigo disc — for avatars and anywhere the mark needs a plate.
        case tile
    }

    public var size: CGFloat
    public var style: Style

    public init(size: CGFloat = 120, style: Style = .mark) {
        self.size = size
        self.style = style
    }

    public var body: some View {
        Group {
            switch style {
            case .mark:
                NaraMarkShape()
                    .fill(StrandPalette.brandInk)
                    .frame(width: size, height: size)
            case .tile:
                ZStack {
                    Circle().fill(NaraBrand.deepIndigo)
                    Circle().strokeBorder(StrandPalette.hairline, lineWidth: max(1, size * 0.008))
                    NaraMarkShape()
                        .fill(NaraBrand.lavenderWhite)
                        .frame(width: size * 0.56, height: size * 0.56)
                }
                .frame(width: size, height: size)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Nara"))
        .accessibilityAddTraits(.isImage)
    }
}

#if DEBUG
#Preview("BrandMark — sizes") {
    VStack(spacing: 40) {
        BrandMark(size: 120)
        HStack(spacing: 28) {
            BrandMark(size: 72, style: .tile)
            BrandMark(size: 44)
            BrandMark(size: 28, style: .tile)
        }
    }
    .padding(48)
    .frame(width: 420, height: 460)
    .background(StrandPalette.surfaceBase)
}
#endif

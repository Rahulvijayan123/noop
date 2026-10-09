import SwiftUI
import StrandDesign

// MARK: - Shared building blocks (also used by EventsView)

/// The `NoopCard` surface as a background, for content that lays out its own padding.
///
/// `radius` is accepted so the existing call sites keep compiling and ignored: every card is drawn at
/// `NoopMetrics.cardRadius`. A surface nested inside a card uses `NoopMetrics.insetRadius` on
/// `StrandPalette.surfaceInset` instead.
struct NaraCardModifier: ViewModifier {
    var radius: CGFloat = NoopMetrics.cardRadius

    func body(content: Content) -> some View {
        content.background(FrostedCardSurface(cornerRadius: NoopMetrics.cardRadius))
    }
}

extension View {
    func naraCard(radius: CGFloat = NoopMetrics.cardRadius) -> some View { modifier(NaraCardModifier(radius: radius)) }
}

/// Section title with an optional caption and a "See all" link. Drawn as the kit's `SectionHeader` (one
/// `title2` line, the action in `accent`) so the screens that still call it match the rest of the app; new
/// code uses `SectionHeader` directly. The caption, when a caller still passes one, is a footnote line.
struct NaraSectionHeader: View {
    let title: String
    var subtitle: String? = nil
    var seeAll: TabRoute? = nil
    var seeAllLabel: LocalizedStringKey = "See all"

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            HStack(alignment: .firstTextBaseline) {
                Text(verbatim: title)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: NoopMetrics.space2)
                if let seeAll {
                    NavigationLink(value: seeAll) {
                        Text(seeAllLabel)
                            .font(StrandFont.subhead.weight(.medium))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(minHeight: NoopMetrics.minimumHitTarget)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, -12)
                }
            }
            if let subtitle {
                Text(subtitle)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

/// Round gear in the screen header; the iOS shell presents Settings.
struct HeaderSettingsButton: View {
    @EnvironmentObject private var router: NavRouter

    var body: some View {
        Button { router.openSettings() } label: {
            HeaderControlGlyph(systemName: "gearshape")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Settings")
    }
}

/// The look of a round header control (the gear, the Monitor "More" menu): a 36 pt inset circle with the
/// symbol in `textSecondary`, with a 44 pt hit area that does not change the header's layout.
struct HeaderControlGlyph: View {
    let systemName: String

    var body: some View {
        // With Liquid Glass on, the circle is a piece of glass (blur, thin body, rim light) like the other floating
        // controls; with it off it keeps the solid inset fill it always had.
        let glyph = Image(systemName: systemName)
            .font(StrandFont.icon(.row))
            .foregroundStyle(StrandPalette.textSecondary)
            .frame(width: NoopMetrics.compactControlSize, height: NoopMetrics.compactControlSize)
        LiquidGlassSwitch {
            glyph.noopGlassControl(in: Circle())
        } original: {
            glyph.background(Circle().fill(StrandPalette.surfaceInset))
        }
        // The hit area grows to 44 pt and the padding is given back, so the header row keeps its height.
        .padding(4)
        .contentShape(Rectangle())
        .padding(-4)
    }
}

/// Smooth curve through `points` (quadratic segments between midpoints).
func naraSmoothPath(_ points: [CGPoint]) -> Path {
    var path = Path()
    guard let first = points.first, let last = points.last, points.count >= 2 else { return path }
    path.move(to: first)
    for i in 1..<(points.count - 1) {
        let c = points[i], n = points[i + 1]
        path.addQuadCurve(to: CGPoint(x: (c.x + n.x) / 2, y: (c.y + n.y) / 2), control: c)
    }
    path.addLine(to: last)
    return path
}

/// "12 min" under an hour, "2h 48m" above.
func naraDurationText(_ seconds: TimeInterval) -> String {
    let minutes = Int((seconds / 60).rounded())
    return minutes < 60 ? "\(minutes) min" : "\(minutes / 60)h \(minutes % 60)m"
}

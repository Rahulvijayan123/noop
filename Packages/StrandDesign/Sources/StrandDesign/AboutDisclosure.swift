import SwiftUI

// MARK: - AboutDisclosure
//
// Where the explanations go. Method notes, caveats and disclaimers used to sit as helper sentences on the
// screens themselves (under heroes, beside charts, in subtitles); they now live in one collapsed card at
// the bottom of the detail page, so the page leads with the data and the reader who wants the "how" is
// one tap from it.

/// A collapsed "About" card for the bottom of a detail page: a title row with a chevron that expands
/// to reveal paragraphs or custom content.
///
/// ```swift
/// AboutDisclosure("About HRV", paragraphs: [
///     "Heart rate variability is the variation between heartbeats, measured overnight as RMSSD.",
///     "Nara compares each night with your own usual range, not a population average.",
/// ])
///
/// AboutDisclosure {
///     Text("Scored on \(deviceName).").font(StrandFont.body)
///     NoopButton("How it is scored", kind: .tertiary) { showGuide = true }
/// }
/// ```
///
/// Expanding only grows the card downward, so nothing above it moves. The open/close is a 0.2 s ease
/// (none under Reduce Motion or the quiet-motion gate).
public struct AboutDisclosure<Content: View>: View {
    private let title: LocalizedStringKey
    private let content: () -> Content
    @State private var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject private var motion = NoopMotionState.shared

    public init(_ title: LocalizedStringKey = "About", initiallyExpanded: Bool = false,
                @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.content = content
        _isExpanded = State(initialValue: initiallyExpanded)
    }

    public var body: some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Button {
                    withAnimation(motion.poseStill(reduceMotion) ? nil : .easeInOut(duration: 0.2)) {
                        isExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: NoopMetrics.space2) {
                        Text(title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.down")
                            .font(StrandFont.icon(.inline))
                            .foregroundStyle(StrandPalette.textTertiary)
                            .rotationEffect(.degrees(isExpanded ? 180 : 0))
                    }
                    .padding(.horizontal, NoopMetrics.cardPadding)
                    .frame(minHeight: NoopMetrics.listRowMinHeight)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityValue(isExpanded ? Text("Expanded", bundle: .module) : Text("Collapsed", bundle: .module))

                if isExpanded {
                    Rectangle()
                        .fill(StrandPalette.hairline)
                        .frame(height: NoopMetrics.hairlineWidth)
                    VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                        content()
                    }
                    .padding(NoopMetrics.cardPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

public extension AboutDisclosure where Content == AboutParagraphs {
    /// An About card whose content is plain paragraphs (body, `textSecondary`).
    init(_ title: LocalizedStringKey = "About", initiallyExpanded: Bool = false, paragraphs: [String]) {
        self.init(title, initiallyExpanded: initiallyExpanded) { AboutParagraphs(paragraphs) }
    }
}

/// Paragraphs of body text, as the About card draws them. Wraps freely: this is the one place on a page
/// where sentences belong.
public struct AboutParagraphs: View {
    private let paragraphs: [String]

    public init(_ paragraphs: [String]) {
        self.paragraphs = paragraphs
    }

    public var body: some View {
        ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
            Text(paragraph)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#if DEBUG
private struct AboutDisclosurePreview: View {
    var body: some View {
        VStack(spacing: NoopMetrics.sectionGap) {
            AboutDisclosure("About HRV", paragraphs: [
                "Heart rate variability is the variation between heartbeats, measured overnight as RMSSD.",
                "Nara compares each night with your own usual range, not a population average.",
            ])
            AboutDisclosure(initiallyExpanded: true) {
                Text("Blood oxygen is read during sleep. A strap estimate is drawn hollow.")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("Not a medical device.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(NoopMetrics.screenHPadding)
        .frame(width: 390)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("AboutDisclosure — light") {
    AboutDisclosurePreview().preferredColorScheme(.light)
}

#Preview("AboutDisclosure — dark") {
    AboutDisclosurePreview().preferredColorScheme(.dark)
}
#endif

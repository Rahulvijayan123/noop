import SwiftUI
import StrandDesign

// MARK: - Stable layout
//
// The pairing screens say different things as a strap connects, drops, searches and pairs, and the things
// they say are different lengths. SwiftUI sizes a screen from what is on it, so a longer sentence pushed
// everything beneath it down and a shorter one pulled it back. These helpers separate the two: a slot is
// sized once, for the most it can ever need, and what changes inside it fades rather than moves.

/// How the pairing screens change state: a short cross-fade, never a move. Reduce Motion turns it off.
enum PairingMotion {
    static let settle = Animation.easeInOut(duration: StrandMotion.durationFast)
}

/// Text that always takes the room of the longest thing it can say.
///
/// `alternatives` are the other lines this slot may show. Every one is laid out in the same place, at the same
/// width and type size, with only the current one visible, so the slot is as tall as the tallest of them and
/// swapping the wording is an opacity change. Hidden lines are dropped from VoiceOver.
struct ReservedText: View {
    let text: String
    var alternatives: [String] = []
    var font: Font = StrandFont.subhead
    var color: Color = StrandPalette.textSecondary
    var alignment: Alignment = .leading
    var textAlignment: TextAlignment = .leading

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Current line first, then the rest without repeats.
    private var variants: [String] {
        var seen: Set<String> = []
        return ([text] + alternatives).filter { seen.insert($0).inserted }
    }

    var body: some View {
        ZStack(alignment: alignment) {
            ForEach(variants, id: \.self) { variant in
                Text(verbatim: variant)
                    .font(font)
                    .foregroundStyle(color)
                    .multilineTextAlignment(textAlignment)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: alignment)
                    .opacity(variant == text ? 1 : 0)
                    .accessibilityHidden(variant != text)
            }
        }
        .animation(reduceMotion ? nil : PairingMotion.settle, value: text)
    }
}

/// A message box with a fixed height: `lines` lines tall whatever it holds.
///
/// A message that fits is plain text. One that doesn't scrolls inside the box, with its last line fading out
/// for as long as there is more below, instead of growing the box and pushing the screen around it. A new
/// message starts back at the top.
struct FixedMessageArea: View {
    let text: String
    var lines = 4
    var font: Font = StrandFont.subhead
    var color: Color = StrandPalette.textSecondary

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text(verbatim: " ")
            .font(font)
            .lineLimit(lines, reservesSpace: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hidden()
            .accessibilityHidden(true)
            .overlay(alignment: .topLeading) {
                ViewThatFits(in: .vertical) {
                    MessageText(text: text, font: font, color: color)
                    ScrollingMessage(text: text, font: font, color: color)
                }
                .id(text)
                .transition(.opacity)
            }
            .animation(reduceMotion ? nil : PairingMotion.settle, value: text)
    }
}

private struct MessageText: View {
    let text: String
    let font: Font
    let color: Color

    var body: some View {
        Text(verbatim: text)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Where a message has been scrolled to, read from the text inside the scroll view.
private struct MessageScroll: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
}

private struct MessageScrollKey: PreferenceKey {
    static let defaultValue = MessageScroll()
    static func reduce(value: inout MessageScroll, nextValue: () -> MessageScroll) { value = nextValue() }
}

/// A message too long for its box. The text scrolls, and the box's bottom edge fades out while there is more
/// to read, so a cut-off sentence reads as "scroll for the rest" rather than as the end of the message.
private struct ScrollingMessage: View {
    let text: String
    let font: Font
    let color: Color

    @State private var scroll = MessageScroll()

    private static let space = "FixedMessageArea.scroll"
    private static let fadeHeight: CGFloat = 24

    var body: some View {
        GeometryReader { box in
            ScrollView(.vertical) {
                MessageText(text: text, font: font, color: color)
                    .background(
                        GeometryReader { content in
                            Color.clear.preference(
                                key: MessageScrollKey.self,
                                value: MessageScroll(offset: -content.frame(in: .named(Self.space)).minY,
                                                     content: content.size.height))
                        }
                    )
            }
            .coordinateSpace(name: Self.space)
            .scrollIndicators(.visible)
            .onPreferenceChange(MessageScrollKey.self) { scroll = $0 }
            .mask(fade(viewport: box.size.height))
        }
    }

    private func fade(viewport: CGFloat) -> some View {
        let moreBelow = scroll.content - (scroll.offset + viewport) > 2
        return VStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, moreBelow ? .clear : .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.fadeHeight)
        }
    }
}

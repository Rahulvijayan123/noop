import SwiftUI
import StrandDesign

// KeyMetricStyle.swift — the look of the key-metric screens (`KeyMetricDetailView`): a quiet purple surface, one
// bordered panel per group, a large plain number, small secondary labels, and controls drawn as a bordered track
// with the chosen segment filled. Colours and sizes follow the HRV concept the owner approved (nara-hrv.html):
// every key metric uses them, so the screens read as one family. Nothing here knows about a metric.

enum KeyMetricStyle {

    // MARK: Colour (light, dark)

    static let background = Color(light: "#F8F5FD", dark: "#110A24")
    static let panel = Color(light: "#FFFFFF", dark: "#1D1236")
    static let text = Color(light: "#281840", dark: "#F6F1FF")
    static let secondary = Color(light: "#6A5C7E", dark: "#C2B5D8")
    static let border = Color(light: "#E2D9EE", dark: "#3B2C55")
    /// Readings, the chosen chip's focus, links.
    static let accent = Color(light: "#7852B5", dark: "#BF9AF5")
    /// The usual or recent range behind the readings, and the chosen segment's fill.
    static let band = Color(light: "#F0E8FA", dark: "#35234E")
    /// The second series (heart rate beside HRV, stable awake on the activity lane).
    static let teal = Color(light: "#357E84", dark: "#8AD2D2")
    /// Context the readings cannot be matched to (mixed, unknown).
    static let track = Color(light: "#E8E1F0", dark: "#312741")
    /// Activity contexts on the lane and the readings: standing, and moving.
    static let amber = Color(light: "#A86A1C", dark: "#E8B66A")
    static let rose = Color(light: "#B0446A", dark: "#F09AB8")
    /// Behind a stretch without a reading: fainter than the range band, so a gap never reads as a value.
    static let gapFill = secondary.opacity(0.12)

    // MARK: Type

    /// The screen's title.
    static let title = StrandFont.scaled(23, weight: .medium, relativeTo: .title2)
    /// The headline number, and its unit beside it.
    static let value = StrandFont.scaled(48, weight: .medium, relativeTo: .largeTitle).monospacedDigit()
    static let valueUnit = StrandFont.scaled(22, weight: .regular, relativeTo: .title3)
    /// Controls and the explanation's sentences.
    static let control = StrandFont.scaled(15, weight: .regular, relativeTo: .subheadline)
    static let body = StrandFont.scaled(16, weight: .regular, relativeTo: .body)
    /// The explanation's headline.
    static let headline = StrandFont.scaled(19, weight: .medium, relativeTo: .title3)
    /// The line under the number that says how it compares.
    static let range = StrandFont.scaled(14, weight: .regular, relativeTo: .subheadline)
    /// Chips, labels, panel headers.
    static let label = StrandFont.scaled(13, weight: .regular, relativeTo: .footnote)
    static let labelStrong = StrandFont.scaled(13, weight: .medium, relativeTo: .footnote)
    /// Legends, the selected reading's details, table cells.
    static let small = StrandFont.scaled(12, weight: .regular, relativeTo: .caption)
    static let selectedValue = StrandFont.scaled(15, weight: .medium, relativeTo: .subheadline).monospacedDigit()

    // MARK: Shape

    static let panelRadius: CGFloat = 18
    static let trackRadius: CGFloat = 14
    static let gap: CGFloat = 12
    static let sectionGap: CGFloat = 20
}

// MARK: - Panel

/// One bordered group: the chart, the explanation.
struct KeyMetricPanel<Content: View>: View {
    var padding: EdgeInsets = EdgeInsets(top: 16, leading: 14, bottom: 12, trailing: 14)
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(KeyMetricStyle.panel, in: RoundedRectangle(cornerRadius: KeyMetricStyle.panelRadius,
                                                                  style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: KeyMetricStyle.panelRadius, style: .continuous)
                .strokeBorder(KeyMetricStyle.border, lineWidth: 1))
            // The panel is the one raised surface on this screen: the shared lift keeps it off the page.
            .noopCardShadow(in: RoundedRectangle(cornerRadius: KeyMetricStyle.panelRadius, style: .continuous))
    }
}

// MARK: - Segmented track

/// Equal segments in a bordered track; the chosen one is filled. A segment that is not available yet stays visible,
/// dimmed, and ignores taps (the #943 rule for longer ranges).
struct KeyMetricSegments<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    var isEnabled: (Item) -> Bool = { _ in true }
    let label: (Item) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(items, id: \.self) { item in
                let chosen = item == selection
                let enabled = isEnabled(item)
                Button {
                    guard enabled, !chosen else { return }
                    StrandHaptic.selection.play()
                    selection = item
                } label: {
                    Text(label(item))
                        .font(KeyMetricStyle.control)
                        .foregroundStyle(chosen ? KeyMetricStyle.text : KeyMetricStyle.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background {
                            if chosen {
                                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(KeyMetricStyle.band)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(enabled ? 1 : StrandPalette.disabledOpacity)
                .accessibilityAddTraits(chosen ? .isSelected : [])
                .accessibilityHint(enabled ? Text(verbatim: "") : Text("Unlocks as more history builds"))
            }
        }
        .padding(4)
        .background(KeyMetricStyle.panel, in: RoundedRectangle(cornerRadius: KeyMetricStyle.trackRadius,
                                                              style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: KeyMetricStyle.trackRadius, style: .continuous)
            .strokeBorder(KeyMetricStyle.border, lineWidth: 1))
    }
}

// MARK: - Chips

/// Small bordered pills; the chosen one is drawn in the text colour with the page colour on it.
struct KeyMetricChips<Item: Hashable>: View {
    let items: [Item]
    @Binding var selection: Item
    let label: (Item) -> String

    var body: some View {
        HStack(spacing: 8) {
            ForEach(items, id: \.self) { item in
                let chosen = item == selection
                Button {
                    guard !chosen else { return }
                    StrandHaptic.selection.play()
                    selection = item
                } label: {
                    Text(label(item))
                        .font(KeyMetricStyle.label)
                        .foregroundStyle(chosen ? KeyMetricStyle.background : KeyMetricStyle.secondary)
                        .padding(.horizontal, 12)
                        .frame(minHeight: 36)
                        .background(Capsule().fill(chosen ? KeyMetricStyle.text : Color.clear))
                        .overlay(Capsule().strokeBorder(chosen ? Color.clear : KeyMetricStyle.border, lineWidth: 1))
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(chosen ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - Disclosure

/// A quiet row that opens a group below it, with a hairline under the row.
struct KeyMetricDisclosure<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { open.toggle() }
            } label: {
                HStack {
                    Text(title)
                        .font(KeyMetricStyle.control)
                        .foregroundStyle(KeyMetricStyle.secondary)
                    Spacer(minLength: 8)
                    Image(systemName: open ? "minus" : "plus")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(KeyMetricStyle.secondary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isHeader)
            .accessibilityValue(Text(open ? "Expanded" : "Collapsed"))
            Rectangle().fill(KeyMetricStyle.border).frame(height: 1)
            if open {
                content
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                    .transition(.opacity)
            }
        }
    }
}

// MARK: - Ask Sana

/// The small pill that opens Sana with this screen's context.
struct KeyMetricAskSanaButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .medium))
                    .accessibilityHidden(true)
                Text("Ask Sana")
                    .font(KeyMetricStyle.labelStrong)
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(KeyMetricStyle.accent)
            .padding(.horizontal, 14)
            .frame(minHeight: 34)
            .background(Capsule().fill(KeyMetricStyle.band))
            .overlay(Capsule().strokeBorder(KeyMetricStyle.border, lineWidth: 1))
            .contentShape(Capsule())
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityHint(Text("Opens a new chat with Sana about this screen"))
    }
}

import SwiftUI

// MARK: - Loading placeholder
//
// Before data arrives a screen renders its REAL layout, redacted, so nothing moves when the values land
// (docs/DESIGN_SYSTEM.md, Loading, empty and sparse states). Static on purpose: no shimmer, nothing loops
// for a load that is usually over in a second. Charts reserve their frame with `ChartPlaceholder` instead,
// because a redacted chart is just its empty axes.

public extension View {
    /// Shows this view redacted while `isLoading`: placeholder bars instead of text, no taps, and a single
    /// "Loading" element for VoiceOver in place of the redacted content.
    ///
    /// Every part is a value modifier, so flipping `isLoading` never changes the view's identity: the state
    /// and `.task`s inside it survive the load finishing.
    ///
    /// ```swift
    /// MetricTile(icon: "heart", iconColor: StrandPalette.metricRose, label: "Resting HR",
    ///            value: rhr.map(fmt), unit: "bpm")
    ///     .loadingPlaceholder(!loaded)
    /// ```
    ///
    /// Apply it to one view (a card, a tile, a section). For a column of several views use
    /// `loadingRedaction(_:)`, which applies to each child without adding an announcement per child
    /// (`ScreenScaffold(isLoading:)` does this for a page).
    func loadingPlaceholder(_ isLoading: Bool) -> some View {
        loadingRedaction(isLoading)
            .overlay {
                if isLoading { LoadingAccessibilityElement() }
            }
    }

    /// The redaction half of `loadingPlaceholder(_:)`, safe on multi-view content: redacted, no taps and,
    /// where the OS can do it without touching the view when not loading (iOS 18, macOS 15, watchOS 11),
    /// hidden from VoiceOver. Pair it with one "Loading" announcement for the group.
    ///
    /// The hiding uses `accessibilityHidden(_:isEnabled:)` rather than `accessibilityHidden(isLoading)`:
    /// a plain `accessibilityHidden(false)` is an explicit value, not "no change", and applied over a
    /// whole page it could reveal elements a screen hid on purpose (a decorative sparkline).
    func loadingRedaction(_ isLoading: Bool) -> some View {
        self.redacted(reason: isLoading ? .placeholder : [])
            .allowsHitTesting(!isLoading)
            .modifier(HiddenWhileLoading(isLoading: isLoading))
    }
}

/// Hides content from VoiceOver only while loading. The availability branch is fixed for the life of the
/// process, so it never changes the content's identity; before iOS 18 the redacted content stays readable
/// and the "Loading" announcement comes first.
private struct HiddenWhileLoading: ViewModifier {
    let isLoading: Bool

    func body(content: Content) -> some View {
        if #available(iOS 18.0, macOS 15.0, watchOS 11.0, *) {
            content.accessibilityHidden(true, isEnabled: isLoading)
        } else {
            content
        }
    }
}

/// The one "Loading" VoiceOver element for a redacted group: invisible, takes no taps. Put it in a
/// `.background` or `.overlay` of the group, present only while loading.
public struct LoadingAccessibilityElement: View {
    public init() {}

    public var body: some View {
        // The content shape gives the clear fill a frame VoiceOver can focus; it takes no taps itself.
        Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel(Text("Loading", bundle: .module))
    }
}

/// Placeholder strings for redacted layouts: a redaction bar is as wide as the text under it, so a
/// loading value is drawn with a representative width rather than "—" (which would redact to a sliver
/// and widen when the number arrives).
enum LoadingText {
    static let value = "000"
    static let shortLine = "Mon 00 Sep"
    static let line = "Average 00 ms"
}

#if DEBUG
private struct LoadingPlaceholderPreview: View {
    @State private var loading = true
    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("Resting heart rate").strandLabel()
                    Text("52 bpm").font(StrandFont.number(28)).foregroundStyle(StrandPalette.textPrimary)
                    Text("Within your usual range").font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .loadingPlaceholder(loading)
            Toggle("Loading", isOn: $loading).font(StrandFont.subhead)
        }
        .padding(NoopMetrics.screenHPadding)
        .frame(width: 360)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Loading placeholder — light") {
    LoadingPlaceholderPreview().preferredColorScheme(.light)
}

#Preview("Loading placeholder — dark") {
    LoadingPlaceholderPreview().preferredColorScheme(.dark)
}
#endif

import SwiftUI

// MARK: - The locked component system
//
// Every screen composes ONLY these. Fixed dimensions + one spacing scale guarantee
// the uniform, instrument-grade look from the reference. Do not invent ad-hoc cards.

public enum NoopMetrics {
    public static let cardRadius: CGFloat = NoopVisualStyle.cardRadius
    /// Corner radius of a surface nested inside a card (a stat cell, a chip row, an inset list), drawn on
    /// `StrandPalette.surfaceInset` without a shadow.
    public static let insetRadius: CGFloat = 12
    public static let cardPadding: CGFloat = NoopVisualStyle.cardPadding
    public static let gap: CGFloat = NoopVisualStyle.itemGap
    public static let sectionGap: CGFloat = NoopVisualStyle.sectionGap
    public static let screenPadding: CGFloat = NoopVisualStyle.pagePadding
    public static let tileHeight: CGFloat = 96   // Design Reset: tighter metric tile
    // Key Metrics grid: one fixed height every tile snaps to, so a sparkline-and-caption tile and a
    // plain value tile read the same. maxHeight: .infinity can't equalise them inside a LazyVGrid (the
    // grid only offers a cell its content height, so there's nothing for the shorter tile to grow into),
    // so we pin a single height that clears the tallest layout (value + inline sparkline + caption).
    public static let keyMetricTileHeight: CGFloat = 122
    public static let chartHeight: CGFloat = 220
    /// Minimum macOS detail-sheet footprint for a scrollable editor/history surface.
    public static let detailSheetMinWidth: CGFloat = 520
    public static let detailSheetMinHeight: CGFloat = 620
    /// Canonical compact provenance-chip height; shared with overlays that align the chip to a border.
    public static let sourceBadgeHeight: CGFloat = 18
    public static let hypnogramBandMinThickness: CGFloat = 14  // floor so short stages read as bars, not ticks
    public static let tabBarClearance: CGFloat = 76  // iOS: extra bottom scroll room so the last card clears the floating tab bar
    /// Canonical diameter for compact circular controls in dense header chrome.
    public static let compactControlSize: CGFloat = 36
    /// Expanded width of the compact charge-to-sync status capsule.
    public static let syncIndicatorExpandedWidth: CGFloat = 108
    /// Optical space between the sync ring and its transient label.
    public static let syncIndicatorLabelSpacing: CGFloat = 5
    /// Smallest readable scale for long localized labels inside the sync capsule.
    public static let syncIndicatorMinimumLabelScale: CGFloat = 0.72
    /// Even inset around the sync control before applying exact-bounds Liquid Glass, matching the inset
    /// the system's `.small` glass chrome gives the sibling header circles. Equal on both axes so the
    /// compact state stays circular.
    public static let syncIndicatorGlassPadding: CGFloat = 5
    /// Inset for the indicator's ring in BOTH states — the battery arc and the sync spinner share one
    /// radius, so the morph changes colour and sweep without the circle also resizing. Two different
    /// radii read as two different controls swapping places rather than one control changing state.
    public static let syncIndicatorArcInset: CGFloat = 2.5
    /// Width of the soft fade where long header text passes beneath trailing controls.
    public static let headerTextFadeWidth: CGFloat = 48
    /// Starting guess for the trailing footprint a header control row occupies, used ONLY until the host
    /// has measured its own cluster (see `headerTrailingControlFadeMask(reserving:)`). Four compact
    /// controls plus their gaps and the sync control's glass inset — deliberately not a fixed budget,
    /// because a cluster that gains a control must not silently start mis-fading the title beside it.
    public static let headerControlReserveWidth: CGFloat = 168

    // MARK: Standardised spacing scale (the ONE source of truth for margins)
    //
    // A 4pt-based ramp. Reach for these instead of literal numbers so every gap,
    // inset and margin lines up to the same grid. Note `cardPadding` (16) above is
    // the same value as `space4` — kept as a named alias for the existing call sites.
    public static let space1:  CGFloat = 4
    /// Optical separation for paired labels; structural layout still follows the 4-point ramp.
    public static let spaceHalf: CGFloat = 2
    public static let space2:  CGFloat = 8
    public static let space3:  CGFloat = 12
    public static let space4:  CGFloat = 16
    public static let space5:  CGFloat = 20
    public static let space6:  CGFloat = 24
    public static let space8:  CGFloat = 32
    public static let space10: CGFloat = 40

    // MARK: Named layout constants — the canonical margins/heights screens compose with.
    /// Horizontal page margin (the gutter on the left/right edge of a screen). Use via `.screenPadding()`.
    public static let screenHPadding: CGFloat = NoopVisualStyle.pagePadding
    /// Vertical gap between top-level page sections.
    public static let sectionSpacing: CGFloat = NoopVisualStyle.sectionGap
    /// Interior padding inside a card's content (matches `cardPadding`).
    public static let cardInnerPadding: CGFloat = 16
    /// Vertical gap between stacked elements INSIDE a card.
    public static let cardInnerSpacing: CGFloat = 12
    /// Vertical gap between rows in a list-style card.
    public static let rowSpacing: CGFloat = 10
    /// Standard interactive-control height (buttons, fields, segmented controls).
    public static let controlHeight: CGFloat = 48
    /// Standard one-pixel edge used by cards and compact controls.
    public static let hairlineWidth: CGFloat = 1
    /// Profile form dimensions shared by avatar and numeric controls.
    public static let profileAvatarDiameter: CGFloat = 44
    public static let formValueColumnWidth: CGFloat = 48
    public static let formWideValueColumnWidth: CGFloat = 64
    /// Compact metadata and explanatory-footer heights.
    public static let compactMetadataMinHeight: CGFloat = 24
    public static let compactHintMinHeight: CGFloat = 18
    /// Canonical thickness for compact horizontal indicator tracks.
    public static let indicatorTrackHeight: CGFloat = 8
    /// Fully-rounded corner radius — pills, chips, capsule buttons.
    public static let pillRadius: CGFloat = NoopVisualStyle.pillRadius
    /// Minimum desktop size for a navigation-based customization sheet.
    public static let editorSheetMinWidth: CGFloat = 440
    public static let editorSheetMinHeight: CGFloat = 600

    // MARK: Kit component sizes
    //
    // Heights here are FLOORS for components whose every line is reserved and single-line, so the
    // natural height never depends on the values shown (scrubbing, loading and empty states all keep
    // the same frame). The floor is what the component measures at the default text size; larger
    // Dynamic Type sizes grow every instance by the same amount, so a row of them still lines up.

    /// `ValueReadout`: date line, hero value + unit, one context line.
    public static let readoutHeight: CGFloat = 88
    /// `MetricTile` without a trend slot (icon + label, value + unit, state line, card padding). A tile
    /// that reserves its trend slot adds `metricTileTrendSlot`. Separate from `tileHeight` and
    /// `keyMetricTileHeight`, which older screens size their own tiles with.
    public static let metricTileHeight: CGFloat = 116
    /// Height a `MetricTile` adds when it shows (or reserves) its sparkline: 22 pt line + 6 pt gap.
    public static let metricTileTrendSlot: CGFloat = 28
    /// The segmented control's segment height (`SegmentedPillControl`, `RangeControl`).
    public static let segmentedHeight: CGFloat = 32
    /// Inset between the segmented track and its selected segment.
    public static let segmentedTrackPadding: CGFloat = 3
    /// Corner radius of the selected segment: the track's `insetRadius` minus `segmentedTrackPadding`,
    /// so the two curves stay concentric.
    public static let segmentRadius: CGFloat = 9
    /// `NoopListRow` minimum height (a single-line row; a subtitle grows it).
    public static let listRowMinHeight: CGFloat = 52
    /// The smallest tap target a control may have (Human Interface Guidelines).
    public static let minimumHitTarget: CGFloat = 44
    /// Page margin on the Mac, where the window is wider than a phone and the content column has room.
    public static let desktopScreenPadding: CGFloat = 28
    /// Widest the page column grows on iPad, so lines of text stay readable in landscape.
    public static let readableColumnWidth: CGFloat = 700
}

// MARK: - Screen padding

public extension View {
    /// Apply the canonical horizontal page gutter (`NoopMetrics.screenHPadding`). The single
    /// source of truth for left/right screen margins — use this instead of a literal padding so
    /// every screen lines up to the same edge.
    func screenPadding() -> some View {
        self.padding(.horizontal, NoopMetrics.screenHPadding)
    }
}

// MARK: - iOS sheet presentation idiom

#if os(iOS)
public extension View {
    /// The house iOS sheet idiom: the drag indicator (the touch affordance that says
    /// "swipe to dismiss") plus detents. macOS sheets are free-floating windows and must
    /// NOT receive this, so the helper is iOS-only and call sites stay shared via #if.
    /// `largeFirst == false` opens at .medium with .large reachable by dragging up (short
    /// forms); `true` opens full-height (long scrolls).
    func noopSheetPresentation(largeFirst: Bool) -> some View {
        self
            .presentationDragIndicator(.visible)
            .presentationDetents(largeFirst ? [.large] : [.medium, .large])
    }
}
#endif

// MARK: - Surface

/// The one card: `NoopPanelSurface` at `NoopMetrics.cardRadius` with `NoopMetrics.cardPadding` inside.
///
/// ```swift
/// NoopCard {
///     Text("Resting heart rate").font(StrandFont.headline)
/// }
/// ```
///
/// `tint` is accepted for source compatibility and ignored: domain colour belongs to the data marks and
/// icons inside a card, not its fill.
public struct NoopCard<Content: View>: View {
    private let padding: CGFloat
    private let tint: Color?
    @ViewBuilder private let content: () -> Content
    #if os(macOS)
    @State private var hover = false
    #endif
    public init(padding: CGFloat = NoopMetrics.cardPadding, tint: Color? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.padding = padding; self.tint = tint; self.content = content
    }
    public var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            // Hover chrome (fill + border + shadow) lives in the background so its animation is
            // scoped to the card surface ONLY. It must never animate the content() subtree, or a
            // chart inside re-animates its line every time the cursor crosses the card. (#104)
            .background { cardSurface }
        #if os(macOS)
            .onHover { hover = $0 }
        #endif
    }

    // Touch can't hover, so iOS renders only the static resting frosted surface — no
    // hover @State, no .onHover tracking, no .animation node. That trims the modifier
    // count on every card, which multiplies across long scrolling lists. macOS adds the
    // hover emphasis border on top (with the #104 animation scoping) unchanged.
    @ViewBuilder private var cardSurface: some View {
        let shape = RoundedRectangle(cornerRadius: NoopMetrics.cardRadius, style: .continuous)
        #if os(macOS)
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
            .overlay(
                shape.strokeBorder(StrandPalette.hairlineStrong, lineWidth: 1).opacity(hover ? 1 : 0)
            )
            .animation(.easeOut(duration: 0.16), value: hover)
        #else
        FrostedCardSurface(tint: tint, cornerRadius: NoopMetrics.cardRadius)
        #endif
    }
}

// MARK: - Section header

/// The one section title: a single `title2` line with an optional trailing note and an optional action.
///
/// ```swift
/// SectionHeader("Trends")
/// SectionHeader("Readings", trailing: "Last 7")
/// SectionHeader("Events", action: .link(label: "See all", value: TabRoute.events))
/// SectionHeader("Key metrics", action: .button(label: "Edit") { editing = true })
/// ```
///
/// `overline` is accepted so the existing call sites keep compiling, and ignored: content screens no longer
/// carry spaced-capital overlines above their section titles (docs/DESIGN_SYSTEM.md, Type).
public struct SectionHeader: View {
    let title: LocalizedStringKey; let trailing: String?; let action: SectionHeaderAction?
    public init(_ title: LocalizedStringKey, overline: LocalizedStringKey? = nil, trailing: String? = nil,
                action: SectionHeaderAction? = nil) {
        self.title = title; self.trailing = trailing; self.action = action
    }
    public var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NoopMetrics.space2)
            if let trailing {
                Text(trailing).font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            if let action {
                action.control
            }
        }
    }
}

/// The trailing action of a `SectionHeader`: a short label in the accent colour (links and actions are
/// the only things drawn in accent; never a data colour). Its tap area is grown to the 44 pt minimum
/// without making the header row any taller.
public struct SectionHeaderAction {
    fileprivate let control: AnyView

    /// Pushes `value` on the enclosing `NavigationStack` (resolved by its `navigationDestination(for:)`).
    /// Built here, where `V` is still concrete, so the stack matches the destination by its real type.
    public static func link<V: Hashable>(label: LocalizedStringKey, value: V) -> SectionHeaderAction {
        SectionHeaderAction(control: AnyView(
            NavigationLink(value: value) { SectionHeaderActionLabel(label: label) }
                .buttonStyle(.plain)
        ))
    }

    /// Pushes a destination built in place, for a stack that has no `navigationDestination` for a value
    /// type (for example a Mac sidebar pane).
    public static func link<Destination: View>(label: LocalizedStringKey,
                                               @ViewBuilder destination: @escaping () -> Destination) -> SectionHeaderAction {
        SectionHeaderAction(control: AnyView(
            NavigationLink { destination() } label: { SectionHeaderActionLabel(label: label) }
                .buttonStyle(.plain)
        ))
    }

    /// Runs `action` (open a sheet, enter an edit mode).
    public static func button(label: LocalizedStringKey, action: @escaping () -> Void) -> SectionHeaderAction {
        SectionHeaderAction(control: AnyView(
            Button(action: action) { SectionHeaderActionLabel(label: label) }
                .buttonStyle(.plain)
        ))
    }
}

private struct SectionHeaderActionLabel: View {
    let label: LocalizedStringKey
    var body: some View {
        // The visible label stays one subhead line; the hit area is padded out to 44 pt and the padding
        // is then given back, so the header row is no taller with an action than without one.
        let grow = max(0, (NoopMetrics.minimumHitTarget - 20) / 2)
        Text(label)
            .font(StrandFont.subhead.weight(.medium))
            .foregroundStyle(StrandPalette.accent)
            .lineLimit(1)
            .padding(.vertical, grow)
            .padding(.leading, NoopMetrics.space2)
            .contentShape(Rectangle())
            .padding(.vertical, -grow)
    }
}

// MARK: - Stat tile (older value tile)

/// A value tile: label, value with an optional trend chip, optional sparkline and caption.
///
/// New top-level tiles use `MetricTile` and detail-page statistics use `StatGrid`; this one stays for the
/// existing call sites. The label is the Label role (subhead, `textSecondary`) and the value is always
/// `textPrimary`: `accent` is accepted for source compatibility and no longer colours the number, the
/// metric's colour lives on the sparkline (`sparkColor`). Every line is single-line and the caption line
/// is reserved even when empty, so tiles with and without a caption are the same height and their labels
/// and values line up across a row.
public struct StatTile<Accessory: View>: View {
    let label: LocalizedStringKey, value: String
    var caption: String? = nil
    var accent: Color = StrandPalette.textPrimary
    var delta: String? = nil
    var deltaColor: Color = StrandPalette.textTertiary
    var sparkline: [Double]? = nil
    var sparkColor: Color = StrandPalette.accent
    /// An optional trailing accessory laid out INLINE in the header row beside the label (e.g. a small
    /// ⓘ that opens a scoring guide). Inline placement — not a corner overlay — so it can never sit on
    /// top of the value, sparkline or trend chip on a narrow tile (#495). Defaults to nothing.
    @ViewBuilder var accessory: () -> Accessory

    public init(label: LocalizedStringKey, value: String, caption: String? = nil,
                accent: Color = StrandPalette.textPrimary, delta: String? = nil,
                deltaColor: Color = StrandPalette.textTertiary,
                sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent,
                @ViewBuilder accessory: @escaping () -> Accessory) {
        self.label = label; self.value = value; self.caption = caption; self.accent = accent
        self.delta = delta; self.deltaColor = deltaColor; self.sparkline = sparkline; self.sparkColor = sparkColor
        self.accessory = accessory
    }

    public var body: some View {
        NoopCard(padding: NoopMetrics.cardPadding) {
            VStack(alignment: .leading, spacing: 0) {
                // Header row: the metric label, and (right-aligned) the optional accessory laid out in
                // flow so it reserves its own space rather than floating over the value below (#495).
                HStack(alignment: .top, spacing: NoopMetrics.space1) {
                    Text(label)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                    accessory()
                }
                Spacer(minLength: NoopMetrics.space1)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(value)
                        .font(StrandFont.number(24, weight: .medium))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer(minLength: 0)
                    // Trend chip — the delta as a tinted pill with a direction arrow.
                    if let delta { TrendChip(text: delta, color: deltaColor) }
                }
                // Sparkline isn't available on watchOS (it relies on chart-hover helpers); the watch
                // doesn't use StatTile, but guard the reference so the file still compiles there.
                #if !os(watchOS)
                if let sparkline, sparkline.count > 1 {
                    Sparkline(values: sparkline,
                              gradient: Gradient(colors: [sparkColor.opacity(0.5), sparkColor]),
                              showsHover: false)
                        .frame(height: 22).padding(.top, NoopMetrics.space1)
                        .accessibilityHidden(true)
                }
                #endif
                // Reserved even when there is no caption, so a captioned tile is not taller than its
                // neighbour and the values in a row sit on one line.
                Text(caption ?? " ")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .padding(.top, NoopMetrics.spaceHalf)
                    .opacity(caption == nil ? 0 : 1)
                    .accessibilityHidden(caption == nil)
            }
        }
        // A FLOOR, not a fixed height: a sparkline tile's content exceeds the 96pt base and must be
        // allowed to grow rather than clip. maxHeight: .infinity lets a caller that DOES hand this tile a
        // bounded height (e.g. the Key Metrics grid pins every cell to NoopMetrics.keyMetricTileHeight)
        // stretch it to fill; in an unbounded parent it resolves to the content's own height, unchanged.
        // Note: inside a LazyVGrid the cell only offers content height, so equal heights come from the
        // caller pinning a fixed height, not from maxHeight: .infinity alone.
        .frame(minHeight: NoopMetrics.tileHeight, maxHeight: .infinity)
        // One VoiceOver stop per tile (label, value, caption, delta) instead of up
        // to four fragmented stops; the decorative sparkline is hidden above.
        .accessibilityElement(children: .combine)
    }
}

// Backward-compatible convenience: a StatTile with NO accessory (the common case) — every existing
// call site keeps working unchanged, and the type defaults `Accessory` to `EmptyView`.
public extension StatTile where Accessory == EmptyView {
    init(label: LocalizedStringKey, value: String, caption: String? = nil,
         accent: Color = StrandPalette.textPrimary, delta: String? = nil,
         deltaColor: Color = StrandPalette.textTertiary,
         sparkline: [Double]? = nil, sparkColor: Color = StrandPalette.accent) {
        self.init(label: label, value: value, caption: caption, accent: accent, delta: delta,
                  deltaColor: deltaColor, sparkline: sparkline, sparkColor: sparkColor,
                  accessory: { EmptyView() })
    }
}

// MARK: - Trend chip — a small tinted delta pill with a direction arrow.

/// A compact trend pill: an up/down arrow + the delta text, tinted to `color`.
/// Inferred direction comes from a leading +/− in the text (else no arrow). Sits beside a value.
///
/// The chip is laid out at its ideal width and never truncates: a cut-off number ("+2 v…", "-14.…")
/// is worse than no chip, so the value beside it scales down instead. Pass the number and its unit only
/// ("+4 bpm"), not a sentence. (The Android twin still ellipsizes, #934.)
public struct TrendChip: View {
    let text: String
    var color: Color = StrandPalette.textTertiary
    public init(text: String, color: Color = StrandPalette.textTertiary) {
        self.text = text; self.color = color
    }
    private var symbol: String? {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("+") || t.hasPrefix("▲") || t.lowercased().hasPrefix("up") { return "arrow.up.right" }
        if t.hasPrefix("-") || t.hasPrefix("−") || t.hasPrefix("▼") || t.lowercased().hasPrefix("down") { return "arrow.down.right" }
        // No sign → a plain magnitude (e.g. a workout's "874 kcal"), not a trend: show NO direction
        // glyph. Previously this fell to "minus", whose leading dash read as a negative ("-874 kcal" — #41).
        return nil
    }
    public var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(StrandFont.icon(.inline)) }
            Text(text).font(StrandFont.captionNumber).lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(color.opacity(0.14), in: Capsule(style: .continuous))
        .fixedSize()
        .accessibilityHidden(true)
    }
}

// MARK: - Chart card (UNIFORM: header + fixed chart body + footer)

public struct ChartCard<ChartBody: View, Footer: View>: View {
    let title: LocalizedStringKey
    var subtitle: String? = nil
    var trailing: String? = nil
    var height: CGFloat = NoopMetrics.chartHeight
    var tint: Color? = nil
    @ViewBuilder let chart: () -> ChartBody
    @ViewBuilder let footer: () -> Footer

    public init(title: LocalizedStringKey, subtitle: String? = nil, trailing: String? = nil,
                height: CGFloat = NoopMetrics.chartHeight, tint: Color? = nil,
                @ViewBuilder chart: @escaping () -> ChartBody,
                @ViewBuilder footer: @escaping () -> Footer = { EmptyView() }) {
        self.title = title; self.subtitle = subtitle; self.trailing = trailing
        self.height = height; self.tint = tint; self.chart = chart; self.footer = footer
    }

    public var body: some View {
        NoopCard(tint: tint) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        if let subtitle { Text(subtitle).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary) }
                    }
                    Spacer()
                    if let trailing { Text(trailing).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary) }
                }
                chart().frame(height: height)
                let f = footer()
                if !(f is EmptyView) {
                    Divider().overlay(StrandPalette.hairline)
                    f
                }
            }
        }
    }
}

/// A footer row of small "label / value" stats for ChartCard.
public struct ChartFooter: View {
    let items: [(LocalizedStringKey, String)]
    public init(_ items: [(LocalizedStringKey, String)]) { self.items = items }
    public var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, it in
                VStack(alignment: .leading, spacing: 2) {
                    Text(it.0).font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
                    Text(it.1).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Insight card

public struct InsightCard: View {
    let category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey
    var statusColor: Color = StrandPalette.accent
    var tint: Color? = nil
    /// Extra trailing inset reserved on the overline + status rows so a caller's
    /// `.overlay(alignment: .topTrailing)` (greeting + state pill) doesn't run over the
    /// card's own title text on a narrow screen (#69). Defaults to 0 — no effect unless set.
    var titleTrailingInset: CGFloat = 0
    public init(category: LocalizedStringKey, status: LocalizedStringKey, detail: LocalizedStringKey, statusColor: Color = StrandPalette.accent, tint: Color? = nil, titleTrailingInset: CGFloat = 0) {
        self.category = category; self.status = status; self.detail = detail; self.statusColor = statusColor; self.tint = tint; self.titleTrailingInset = titleTrailingInset
    }
    public var body: some View {
        // Defaults the card wash to the status colour so the coaching card sits in the
        // same colour world as the score it summarises (e.g. gold for Charge). The
        // insight card reads a touch stronger than a tile: an explicit hue wash
        // (.14 → .04) + a matching .22 hue border on top of the frosted surface.
        let hue = tint ?? statusColor
        // Apple-flat: a plain flat card. Identity comes from the COLOURED status headline alone — no extra
        // hue-gradient wash, no border (so it reads identical to every other card on the page).
        return NoopCard(padding: 18, tint: hue) {
            VStack(alignment: .leading, spacing: 8) {
                Text(category).strandOverline()
                    .padding(.trailing, titleTrailingInset)
                Text(status).font(StrandFont.title2).foregroundStyle(statusColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.trailing, titleTrailingInset)
                Text(detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Segmented control (the ONE segmented pill control, used everywhere)

/// The one segmented control: a solid `surfaceInset` track with the selected segment raised on
/// `surfaceRaised` behind a hairline. Flat, no gradients or shadows. `RangeControl` is built on it.
///
/// ```swift
/// SegmentedPillControl(["Day", "Week"], selection: $mode, fillsAvailableWidth: true) { $0 }
/// ```
public struct SegmentedPillControl<T: Hashable>: View {
    let items: [T]
    let label: (T) -> String
    /// When requested, keep the regular intrinsic control wherever it fits and fall back to
    /// equal-width segments inside the parent's available width on compact screens. This prevents
    /// long option sets from widening an entire page beyond the viewport while leaving the many
    /// shorter segmented controls byte-identical.
    let adaptsToAvailableWidth: Bool
    /// Per-segment availability (#943): a disabled segment stays visible (so users learn the
    /// option exists) but renders extra-dim and ignores taps; VoiceOver announces it dimmed.
    /// Defaults to everything enabled; ADDED additively, no existing call site touched.
    let isEnabled: (T) -> Bool
    let fillsAvailableWidth: Bool
    @Binding var selection: T
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    public init(_ items: [T], selection: Binding<T>, adaptsToAvailableWidth: Bool = false,
                fillsAvailableWidth: Bool = false,
                label: @escaping (T) -> String) {
        self.init(items, selection: selection, adaptsToAvailableWidth: adaptsToAvailableWidth,
                  fillsAvailableWidth: fillsAvailableWidth,
                  isEnabled: { _ in true }, label: label)
    }
    public init(_ items: [T], selection: Binding<T>, adaptsToAvailableWidth: Bool = false,
                fillsAvailableWidth: Bool = false,
                isEnabled: @escaping (T) -> Bool,
                label: @escaping (T) -> String) {
        self.items = items
        self._selection = selection
        self.adaptsToAvailableWidth = adaptsToAvailableWidth
        self.fillsAvailableWidth = fillsAvailableWidth
        self.isEnabled = isEnabled
        self.label = label
    }
    @ViewBuilder
    public var body: some View {
        if fillsAvailableWidth {
            track(equalWidth: true)
        } else if adaptsToAvailableWidth {
            if dynamicTypeSize > .large {
                ScrollView(.horizontal, showsIndicators: false) {
                    track(equalWidth: false)
                        .fixedSize(horizontal: true, vertical: false)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    track(equalWidth: false)
                    track(equalWidth: true)
                }
            }
        } else {
            track(equalWidth: false)
        }
    }

    private func track(equalWidth: Bool) -> some View {
        HStack(spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                let sel = item == selection
                let enabled = isEnabled(item)
                Button {
                    guard selection != item else { return }   // re-tapping the active segment stays silent
                    StrandHaptic.selection.play()
                    withAnimation(StrandMotion.interactive) { selection = item }
                } label: {
                    Text(label(item))
                        .font(StrandFont.captionNumber)
                        .lineLimit(equalWidth ? 1 : nil)
                        // Range selection stays deliberately neutral so the control works above charts
                        // from every metric colour world without borrowing their green/blue/amber tint.
                        // Disabled segments drop to a fainter tertiary so the lock reads at a glance.
                        .foregroundStyle(sel ? StrandPalette.textPrimary
                                             : StrandPalette.textTertiary.opacity(enabled ? 1 : 0.35))
                        // Fill the segment height so the selected pill has EQUAL margins to the track
                        // on every side. (The old compact pill inside a taller 44pt touch frame left
                        // more vertical margin than horizontal — it read as off-centre.)
                        .frame(minWidth: equalWidth ? nil : 26,
                               maxWidth: equalWidth ? .infinity : nil,
                               maxHeight: .infinity)
                        .padding(.horizontal, equalWidth ? NoopMetrics.space1 : 9)
                        .background {
                            if sel {
                                // Flat: the raised surface with a hairline edge, no gradient or shadow.
                                let selectedShape = RoundedRectangle(cornerRadius: NoopMetrics.segmentRadius,
                                                                     style: .continuous)
                                selectedShape
                                    .fill(StrandPalette.surfaceRaised)
                                    .overlay(selectedShape.strokeBorder(StrandPalette.hairline,
                                                                        lineWidth: NoopMetrics.hairlineWidth))
                            }
                        }
                        .contentShape(RoundedRectangle(cornerRadius: NoopMetrics.segmentRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .frame(maxWidth: equalWidth ? .infinity : nil)
                .frame(height: NoopMetrics.segmentedHeight)   // the pill fills it for an even inset
                .disabled(!enabled)
                // Announce the active range to VoiceOver and give a non-colour cue.
                .accessibilityAddTraits(sel ? .isSelected : [])
            }
        }
        .padding(NoopMetrics.segmentedTrackPadding)
        .frame(maxWidth: equalWidth ? .infinity : nil)
        // A solid inset well; the selected segment sits on it as a raised tile. Track radius minus the
        // track padding is the segment radius, so the corners are concentric.
        .background(NoopInsetSurface(cornerRadius: NoopMetrics.insetRadius))
    }
}

// MARK: - Badges

public struct SourceBadge: View {
    let text: LocalizedStringKey; var tint: Color = StrandPalette.accent
    public init(_ text: LocalizedStringKey, tint: Color = StrandPalette.accent) { self.text = text; self.tint = tint }
    public var body: some View {
        // `.frame(height:)` centres its content by default, so the label sits mid-capsule for free. Noted
        // because the Android twin pinned the same 18 with `heightIn` applied to the label itself, which
        // top-aligns — same number, different render. That one is matched to this, not the reverse.
        Text(text).font(StrandFont.overlineScaled(11))
            .padding(.horizontal, 9).frame(height: NoopMetrics.sourceBadgeHeight)
            .background(tint.opacity(0.16), in: Capsule(style: .continuous))
            .foregroundStyle(tint)
            .overlay(Capsule(style: .continuous).strokeBorder(tint.opacity(0.34), lineWidth: 1))
    }
}

// MARK: - Numeric field helpers (iOS soft-keyboard)

public extension View {
    /// Configures a TextField for whole-number-or-decimal entry on iOS: the decimal-pad
    /// keyboard (handles both integer Avg-HR and decimal calories). No-op on macOS
    /// (hardware keyboard), so the SAME shared view compiles on both. Pair with
    /// `.keyboardDoneToolbar(...)` on the enclosing view to add a Done button (the decimal
    /// pad has no return key).
    func numericKeyboard() -> some View {
        #if os(iOS)
        self.keyboardType(.decimalPad).textContentType(nil)
        #else
        self
        #endif
    }

    /// Adds a single trailing "Done" button to the software-keyboard accessory bar that
    /// resigns the given focus binding. iOS-only; the keyboard toolbar is hosted by the
    /// keyboard itself, so it works inside a sheet with no NavigationStack. No-op on macOS.
    func keyboardDoneToolbar<Value: Hashable>(_ focus: FocusState<Value?>.Binding) -> some View {
        #if os(iOS)
        self.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focus.wrappedValue = nil }
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
            }
        }
        #else
        self
        #endif
    }
}

// MARK: - Buttons (Titanium & Gold) — ADDED additively, no existing API touched.
//
// Three house button styles for primary actions, secondary chrome and ghost/gold
// CTAs. Drop in via `.buttonStyle(.noopPrimary)` etc. on any `Button`. All read off
// the new gold tokens so they match Apple ⇄ Android. Pressed = subtle dim + scale.

/// Primary call-to-action: a flat brand-purple fill with Lavender White ink (Deep Indigo on dark).
public struct NoopPrimaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.goldDeepText)
            .padding(.vertical, 14).padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(StrandPalette.gold)
            )
            .opacity(pressed ? 0.9 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Secondary: inset well + hairline border + primary ink. Quieter than the primary fill.
public struct NoopSecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return configuration.label
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
            .padding(.vertical, 14).padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.surfaceInset))
            .overlay(shape.strokeBorder(StrandPalette.hairline, lineWidth: 1))
            .opacity(pressed ? 0.82 : 1)
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

/// Ghost: transparent + accent hairline + accent text. Tertiary CTA.
public struct NoopGhostButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return configuration.label
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.gold)
            .padding(.vertical, 14).padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(shape.fill(StrandPalette.gold.opacity(pressed ? 0.10 : 0)))
            .overlay(shape.strokeBorder(StrandPalette.gold.opacity(0.3), lineWidth: 1))
            .scaleEffect(pressed ? 0.98 : 1)
            .animation(StrandMotion.interactive, value: pressed)
            .contentShape(Rectangle())
    }
}

public extension ButtonStyle where Self == NoopPrimaryButtonStyle {
    /// Gold-gradient primary CTA.
    static var noopPrimary: NoopPrimaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopSecondaryButtonStyle {
    /// Inset secondary button.
    static var noopSecondary: NoopSecondaryButtonStyle { .init() }
}
public extension ButtonStyle where Self == NoopGhostButtonStyle {
    /// Transparent gold-outline ghost button.
    static var noopGhost: NoopGhostButtonStyle { .init() }
}

// MARK: - Score state pill (SOLID / BUILDING / CALIBRATING / LIVE)
//
// ADDED additively — the existing `StatePill` (tone-based, in StatePill.swift) is
// untouched. This is the score-lifecycle chip the new design calls for: SOLID = gold
// fill, BUILDING = blue, CALIBRATING = slate, LIVE = gold dot with a pulsing halo.

public enum ScoreState: Sendable, Equatable {
    case solid        // a settled, trustworthy score
    case building     // accruing nights, not yet settled
    case calibrating  // baseline still forming
    case live         // streaming right now

    /// The chip's hue, drawn from the re-pointed palette (gold / blue / slate).
    public var color: Color {
        switch self {
        case .solid:        return StrandPalette.statusPositive // settled / trustworthy — WHOOP green
        case .live:         return StrandPalette.accent          // streaming now — WHOOP blue
        case .building:     return StrandPalette.sleepLight   // #4A90E2 blue
        case .calibrating:  return StrandPalette.textTertiary // #8A94A4 slate
        }
    }
    public var label: LocalizedStringKey {
        switch self {
        case .solid:       return "Solid"
        case .building:    return "Building"
        case .calibrating: return "Calibrating"
        case .live:        return "Live"
        }
    }
    var pulsing: Bool { self == .live }
}

/// The score-lifecycle chip: dot + hue@.12 fill + hue@.32 border + hue text. LIVE
/// pulses its dot. `text` overrides the default state label (e.g. "Building — 2 of 4").
public struct ScoreStatePill: View {
    public var state: ScoreState
    public var text: LocalizedStringKey?
    public init(_ state: ScoreState, text: LocalizedStringKey? = nil) {
        self.state = state; self.text = text
    }
    public var body: some View {
        let hue = state.color
        return HStack(spacing: 6) {
            PulseDot(color: hue, pulsing: state.pulsing, size: 7)
            Text(text ?? state.label)
                .font(StrandFont.overline)
                .foregroundStyle(hue)
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule(style: .continuous).fill(hue.opacity(0.12)))
        .overlay(Capsule(style: .continuous).stroke(hue.opacity(0.32), lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text ?? state.label)
    }
}

/// A small dot with an optional breathing pulse halo (LIVE). Honours Reduce Motion.
/// Local to the score pill so it doesn't disturb StatePill.swift's ConnectionDot.
private struct PulseDot: View {
    var color: Color
    var pulsing: Bool
    var size: CGFloat
    @State private var animate = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Low Power Mode / "Reduce motion in NOOP". This halo is a `repeatForever` loop that never
    /// settles and is on screen for long stretches — a connected strap in Settings, a backfill on
    /// every scaffolded screen — so it belongs behind the same gate as the liquid surfaces.
    @ObservedObject private var motion = NoopMotionState.shared
    private var poseStill: Bool { motion.poseStill(reduceMotion) }
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            // Dark-mode only (#review): AdditiveBloom used to hide this expanding ring on light
            // (content.opacity(0)); now that we drop the offscreen bloom, gate it explicitly so light
            // mode stays ring-free (the resting dot + its shadow carry the live state there).
            if pulsing && scheme == .dark {
                Circle().fill(color)
                    .frame(width: size, height: size)
                    .scaleEffect(animate ? 2.4 : 1.0)
                    .opacity(animate ? 0.0 : 0.5)
                    // No .additiveBloom(): the .plusLighter blend forced an offscreen pass every
                    // frame of the repeatForever pulse, a continuous cost while a strap is backfilling
                    // (exactly when this live dot is on screen). The expanding/fading ring reads the
                    // same without it; the resting dot's shadow still carries the "live" glow.
            }
            Circle().fill(color)
                .frame(width: size, height: size)
                .shadow(color: color.opacity(0.8), radius: pulsing ? 4 : 2)
        }
        .frame(width: size, height: size)
        .onAppear { if pulsing && !poseStill { animate = true } }
        .animation(pulsing && !poseStill ? StrandMotion.breathe : nil, value: animate)
        .accessibilityHidden(true)
    }
}

#if DEBUG
private struct ComponentsPreview: View {
    @State private var range = "M"
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                    SectionHeader("Readings", trailing: "Last 7")
                    SectionHeader("Events", action: .button(label: "See all") {})
                    SegmentedPillControl(["W", "M", "3M", "6M", "Y", "All"], selection: $range,
                                         fillsAvailableWidth: true) { $0 }
                }
                HStack(alignment: .top, spacing: NoopMetrics.gap) {
                    StatTile(label: "Stress", value: "1.4", caption: "low-stress days · 30d",
                             delta: "+0.2", deltaColor: StrandPalette.statusWarning)
                    StatTile(label: "Resting HR", value: "54 bpm", accent: StrandPalette.metricRose,
                             delta: "−14.5 bpm", deltaColor: StrandPalette.statusPositive)
                }
                .fixedSize(horizontal: false, vertical: true)
                StatTile(label: "Average", value: "61 ms", sparkline: [58, 61, 60, 64, 62, 59, 63],
                         sparkColor: StrandPalette.metricPurple)
            }
            .padding(NoopMetrics.screenHPadding)
        }
        .frame(width: 390, height: 560)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("Components — light") {
    ComponentsPreview().preferredColorScheme(.light)
}

#Preview("Components — dark") {
    ComponentsPreview().preferredColorScheme(.dark)
}
#endif

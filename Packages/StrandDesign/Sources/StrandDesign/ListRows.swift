import SwiftUI

// MARK: - List rows
//
// Settings-like lists (links to sub-pages, devices, readings) are rows inside ONE card separated by
// hairlines, not a stack of separate cards. The row is the tap target; the card is just the group.

/// One row of a list card: optional icon, title (and optional subtitle), optional trailing value, and a
/// chevron when it navigates.
///
/// ```swift
/// NoopListSection("Data") {
///     NavigationLink(value: TabRoute.devices) {
///         NoopListRow(icon: "sensor", title: "Devices", value: "WHOOP 4.0")
///     }
///     NoopListDivider()
///     NavigationLink(value: TabRoute.storage) {
///         NoopListRow(icon: "internaldrive", title: "Storage", value: "1.2 GB")
///     }
/// }
/// .buttonStyle(.plain)
/// ```
///
/// The row is at least `NoopMetrics.listRowMinHeight` tall with the card padding on both sides, and its
/// whole width is the tap target. Wrap it in a `NavigationLink` or `Button` with `.buttonStyle(.plain)`;
/// pass `showsChevron: false` for a row that does not navigate.
public struct NoopListRow: View {
    private let icon: String?
    private let iconColor: Color
    private let title: LocalizedStringKey
    private let subtitle: String?
    private let value: String?
    private let showsChevron: Bool

    public init(icon: String?, iconColor: Color = StrandPalette.textSecondary, title: LocalizedStringKey,
                subtitle: String? = nil, value: String? = nil, showsChevron: Bool = true) {
        self.icon = icon
        self.iconColor = iconColor
        self.title = title
        self.subtitle = subtitle
        self.value = value
        self.showsChevron = showsChevron
    }

    public var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            if let icon {
                Image(systemName: icon)
                    .font(StrandFont.icon(.row))
                    .foregroundStyle(iconColor)
                    .frame(width: 28)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            if let value {
                Text(value)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// The hairline between two rows of a list card, inset to line up with the row text (past the icon
/// column when the rows have icons).
public struct NoopListDivider: View {
    private let leadingInset: CGFloat

    /// `leadingInset` defaults to the card padding; pass `NoopListDivider.iconRowInset` for rows with icons.
    public init(leadingInset: CGFloat = NoopMetrics.cardPadding) {
        self.leadingInset = leadingInset
    }

    /// Card padding + the 28 pt icon column + the icon gap, so the line starts under the row titles.
    public static let iconRowInset: CGFloat = NoopMetrics.cardPadding + 28 + NoopMetrics.space3

    public var body: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: NoopMetrics.hairlineWidth)
            .padding(.leading, leadingInset)
            .accessibilityHidden(true)
    }
}

/// A list card: an optional label above it (subhead, `textSecondary`), the rows in one `NoopCard` with no
/// inner padding, and an optional footnote under it. Separate rows with `NoopListDivider`.
public struct NoopListSection<Content: View>: View {
    private let title: LocalizedStringKey?
    private let footer: LocalizedStringKey?
    private let content: () -> Content

    public init(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil,
                @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if let title {
                Text(title)
                    .font(StrandFont.subhead.weight(.medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.leading, NoopMetrics.space1)
                    .accessibilityAddTraits(.isHeader)
            }
            NoopCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) { content() }
            }
            if let footer {
                Text(footer)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NoopMetrics.space1)
            }
        }
    }
}

// MARK: - ReadingsList

/// The most recent readings on a detail page, newest first, with "Show all" when there are more.
///
/// ```swift
/// ReadingsList(rows: readings.map { .init(id: $0.key, date: $0.dateText, value: "\($0.text) ms",
///                                         source: $0.sourceName) },
///              onShowAll: { showAllReadings = true })
/// ```
///
/// The list is bounded (`visibleCount`, default 7) so a long history never turns the page into a table;
/// the full list belongs on its own page or sheet. The source is drawn in `textTertiary`, never in a data
/// or brand colour. `onShowAll: nil` hides the row even when there are more readings.
public struct ReadingsList: View {
    public struct Row: Identifiable, Hashable, Sendable {
        public var id: String
        /// "Tue 7 Oct" or "Tue 7 Oct, 06:12".
        public var date: String
        /// The value with its unit: "62 ms".
        public var value: String
        /// Where it came from: "WHOOP", "Apple Health". Optional.
        public var source: String?

        public init(id: String, date: String, value: String, source: String? = nil) {
            self.id = id
            self.date = date
            self.value = value
            self.source = source
        }
    }

    private let rows: [Row]
    private let visibleCount: Int
    private let onShowAll: (() -> Void)?

    public init(rows: [Row], visibleCount: Int = 7, onShowAll: (() -> Void)?) {
        self.rows = rows
        self.visibleCount = visibleCount
        self.onShowAll = onShowAll
    }

    public var body: some View {
        let shown = ReadingsList.visibleRows(rows, visibleCount: visibleCount)
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { NoopListDivider() }
                    readingRow(row)
                }
                if let onShowAll, ReadingsList.hasMore(rows, visibleCount: visibleCount) {
                    NoopListDivider(leadingInset: 0)
                    Button(action: onShowAll) {
                        HStack {
                            Text("Show all", bundle: .module)
                                .font(StrandFont.subhead.weight(.medium))
                                .foregroundStyle(StrandPalette.accent)
                            Spacer(minLength: NoopMetrics.space2)
                            Text("\(rows.count)")
                                .font(StrandFont.captionNumber)
                                .foregroundStyle(StrandPalette.textTertiary)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.icon(.inline))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(.horizontal, NoopMetrics.cardPadding)
                        .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Show all \(rows.count) readings", bundle: .module))
                    .accessibilityAddTraits(.isButton)
                }
            }
        }
    }

    private func readingRow(_ row: Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(row.date)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
                if let source = row.source {
                    Text(source)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: NoopMetrics.space2)
            Text(row.value)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// The rows the card draws: the first `visibleCount` (at least one when there are any).
    public static func visibleRows(_ rows: [Row], visibleCount: Int) -> [Row] {
        Array(rows.prefix(max(1, visibleCount)))
    }

    /// Whether there are readings beyond the visible ones, i.e. whether "Show all" has anything to show.
    public static func hasMore(_ rows: [Row], visibleCount: Int) -> Bool {
        rows.count > max(1, visibleCount)
    }
}

#if DEBUG
private struct ListRowsPreview: View {
    private let readings: [ReadingsList.Row] = (0..<12).map { i in
        ReadingsList.Row(id: "\(i)", date: "\(["Tue", "Mon", "Sun", "Sat", "Fri", "Thu", "Wed"][i % 7]) \(7 - i % 7) Oct",
                         value: "\(58 + (i * 7) % 13) ms", source: i % 3 == 0 ? "Apple Health" : "WHOOP")
    }
    var body: some View {
        ScrollView {
            VStack(spacing: NoopMetrics.sectionGap) {
                NoopListSection("Data", footer: "Everything stays on this iPhone.") {
                    NoopListRow(icon: "sensor", iconColor: StrandPalette.accent, title: "Devices", value: "WHOOP 4.0")
                    NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                    NoopListRow(icon: "internaldrive", title: "Storage", subtitle: "Last cleaned 3 days ago",
                                value: "1.2 GB")
                    NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                    NoopListRow(icon: "square.and.arrow.up", title: "Export", showsChevron: false)
                }
                ReadingsList(rows: readings, onShowAll: {})
            }
            .padding(NoopMetrics.screenHPadding)
        }
        .frame(width: 390, height: 760)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("List rows — light") {
    ListRowsPreview().preferredColorScheme(.light)
}

#Preview("List rows — dark") {
    ListRowsPreview().preferredColorScheme(.dark)
}
#endif

import SwiftUI

// MARK: - StatGrid
//
// The statistics for the visible range on a detail page (Average, Low, High, Typical, vs previous). It
// replaces the row of separate StatTiles and the ChartFooter, which between them repeated "Latest" three
// times on one page and gave each number its own card. Here the numbers share ONE card and sit in inset
// cells, so they read as one group that belongs to the chart above.

/// One labelled value in a `StatGrid`.
public struct StatItem: Identifiable, Hashable, Sendable {
    public var id: String { label }
    /// "Average", "Low", "High", "Typical", "vs previous month". Sentence case, short.
    public var label: String
    /// The formatted number; `nil` shows "—" with no unit.
    public var value: String?
    public var unit: String?
    /// One quiet line under the value, e.g. the date of a Low or High ("30 Sep").
    public var detail: String?

    public init(_ label: String, value: String?, unit: String? = nil, detail: String? = nil) {
        self.label = label
        self.value = value
        self.unit = unit
        self.detail = detail
    }

    /// The value as drawn: "—" when there is none.
    public var displayValue: String {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "—" }
        return value
    }

    /// The unit as drawn: only beside a real value.
    public var displayUnit: String? {
        guard displayValue != "—", let unit, !unit.isEmpty else { return nil }
        return unit
    }
}

/// Two to four labelled values in one `NoopCard`, laid out `columns` across.
///
/// ```swift
/// StatGrid([
///     StatItem("Average", value: "61", unit: "ms"),
///     StatItem("Typical", value: "54–68", unit: "ms"),
///     StatItem("Low", value: "42", unit: "ms", detail: "30 Sep"),
///     StatItem("High", value: "88", unit: "ms", detail: "3 Oct"),
/// ])
/// ```
///
/// Each cell sits on `NoopInsetSurface`: label (subhead, `textSecondary`), value (`number(20)`) + unit, and
/// the optional detail line (footnote, `textTertiary`). Rows have one fixed height: every line is
/// single-line, and when any item has a detail every cell reserves the detail line, so cells never differ
/// in height. A short last row keeps the column widths. `isLoading` keeps the layout and redacts it.
public struct StatGrid: View {
    private let items: [StatItem]
    private let columns: Int
    private let isLoading: Bool

    public init(_ items: [StatItem], columns: Int = 2, isLoading: Bool = false) {
        self.items = items
        self.columns = columns
        self.isLoading = isLoading
    }

    public var body: some View {
        let layout = StatGrid.rows(itemCount: items.count, columns: columns)
        let reservesDetail = items.contains { $0.detail?.isEmpty == false }
        NoopCard {
            VStack(spacing: NoopMetrics.space2) {
                ForEach(Array(layout.enumerated()), id: \.offset) { _, row in
                    HStack(spacing: NoopMetrics.space2) {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, index in
                            if let index {
                                StatCell(item: items[index], reservesDetail: reservesDetail, isLoading: isLoading)
                            } else {
                                // Pads a short last row so its cells keep the column width.
                                Color.clear.frame(maxWidth: .infinity)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    // Cells in a row share the tallest cell's height (they are equal by construction; this
                    // keeps it so if a label scales differently).
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .loadingPlaceholder(isLoading)
    }

    /// The grid as rows of item indices, `nil` padding the last row. Columns are clamped to 1…4 and never
    /// exceed the item count, so two items in a 4-column grid are two halves, not two quarters.
    public static func rows(itemCount: Int, columns: Int) -> [[Int?]] {
        guard itemCount > 0 else { return [] }
        let perRow = min(max(1, min(columns, 4)), itemCount)
        return stride(from: 0, to: itemCount, by: perRow).map { start in
            (start..<(start + perRow)).map { $0 < itemCount ? $0 : nil }
        }
    }
}

private struct StatCell: View {
    let item: StatItem
    let reservesDetail: Bool
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(item.label)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(isLoading && item.value == nil ? LoadingText.value : item.displayValue)
                    .font(StrandFont.number(20))
                    .foregroundStyle(StrandPalette.textPrimary)
                if let unit = item.displayUnit ?? (isLoading ? item.unit : nil) {
                    Text(unit)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            if reservesDetail {
                Text(item.detail ?? " ")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(NoopInsetSurface())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(item.label))
        .accessibilityValue(Text([item.displayUnit.map { "\(item.displayValue) \($0)" } ?? item.displayValue,
                                  item.detail].compactMap { $0 }.joined(separator: ", ")))
    }
}

#if DEBUG
private struct StatGridPreview: View {
    var body: some View {
        ScrollView {
            VStack(spacing: NoopMetrics.sectionGap) {
                StatGrid([
                    StatItem("Average", value: "61", unit: "ms"),
                    StatItem("Typical", value: "54–68", unit: "ms"),
                    StatItem("Low", value: "42", unit: "ms", detail: "30 Sep"),
                    StatItem("High", value: "88", unit: "ms", detail: "3 Oct"),
                ])
                StatGrid([
                    StatItem("Average", value: "8,420", unit: "steps"),
                    StatItem("Total", value: "252,600", unit: "steps"),
                    StatItem("Best day", value: nil, unit: "steps"),
                ], columns: 3)
                StatGrid([
                    StatItem("Average", value: nil, unit: "bpm"),
                    StatItem("Low", value: nil, unit: "bpm"),
                ], isLoading: true)
            }
            .padding(NoopMetrics.screenHPadding)
        }
        .frame(width: 390, height: 520)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("StatGrid — light") {
    StatGridPreview().preferredColorScheme(.light)
}

#Preview("StatGrid — dark") {
    StatGridPreview().preferredColorScheme(.dark)
}
#endif

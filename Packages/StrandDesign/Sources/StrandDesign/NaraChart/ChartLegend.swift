import SwiftUI

// MARK: - ChartLegend

/// One row of legend items under a chart, at a fixed height so a frame with a legend is the same height in
/// every state. When the row is wider than the card it scrolls sideways rather than wrapping onto a second
/// line, which would change the height.
///
/// Items can be toggles (a second HRV method that is off by default): pass `onToggle` and the ids in
/// `hidden`, and each item becomes a button that dims while its series is hidden.
public struct ChartLegend: View {
    private let items: [ChartLegendItem]
    private let hidden: Set<String>
    private let onToggle: ((String) -> Void)?

    public init(_ items: [ChartLegendItem], hidden: Set<String> = [], onToggle: ((String) -> Void)? = nil) {
        self.items = items
        self.hidden = hidden
        self.onToggle = onToggle
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            row
            ScrollView(.horizontal, showsIndicators: false) { row }
        }
        .frame(height: NaraChartStyle.legendHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var row: some View {
        HStack(spacing: NoopMetrics.space3) {
            ForEach(items) { item in
                if let onToggle {
                    Button { onToggle(item.id) } label: { entry(item) }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(hidden.contains(item.id) ? [] : .isSelected)
                } else {
                    entry(item)
                }
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private func entry(_ item: ChartLegendItem) -> some View {
        HStack(spacing: NoopMetrics.space1 + 2) {
            ChartLegendGlyph(mark: item.mark)
            Text(item.label)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
        .opacity(hidden.contains(item.id) ? 0.4 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// The small mark beside a legend label, drawn to match the chart mark it names.
struct ChartLegendGlyph: View {
    let mark: ChartLegendItem.Mark

    var body: some View {
        Group {
            switch mark {
            case .swatch(let color):
                RoundedRectangle(cornerRadius: 2, style: .continuous).fill(color).frame(width: 9, height: 9)
            case .line(let color, let dashed):
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 1))
                    path.addLine(to: CGPoint(x: 14, y: 1))
                }
                .stroke(color, style: dashed ? NaraChartStyle.meanLine : NaraChartStyle.line)
                .frame(width: 14, height: 2)
            case .point(let color):
                Circle().fill(color).frame(width: 7, height: 7)
            case .band(let color):
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(color.opacity(NaraChartStyle.bandOpacity * 2))
                    .frame(width: 14, height: 9)
            case .estimate(let color):
                Circle().strokeBorder(color, lineWidth: NaraChartStyle.estimateStroke).frame(width: 8, height: 8)
            case .hatched(let color):
                DiagonalHatch(spacing: 3)
                    .stroke(color.opacity(0.7), lineWidth: 1)
                    .frame(width: 14, height: 9)
                    .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
            }
        }
        .frame(width: 14, height: 12)
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("ChartLegend") {
    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
        ChartLegend([
            ChartLegendItem(.line(StrandPalette.metricCyan, dashed: false), "RMSSD"),
            ChartLegendItem(.band(StrandPalette.metricCyan), "Typical range"),
            ChartLegendItem(.estimate(StrandPalette.metricCyan), "Estimate"),
            ChartLegendItem(.line(StrandPalette.textSecondary, dashed: true), "7-day average"),
        ])
        ChartLegend([
            ChartLegendItem(.swatch(StrandPalette.sleepDeep), "Deep"),
            ChartLegendItem(.swatch(StrandPalette.sleepREM), "REM"),
            ChartLegendItem(.swatch(StrandPalette.sleepLight), "Light"),
            ChartLegendItem(.hatched(StrandPalette.textTertiary), "Off wrist"),
        ], hidden: ["REM"], onToggle: { _ in })
    }
    .padding(NoopMetrics.screenHPadding)
    .background(StrandPalette.surfaceRaised)
}
#endif

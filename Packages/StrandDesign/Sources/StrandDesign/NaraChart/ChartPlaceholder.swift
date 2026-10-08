import SwiftUI

// MARK: - Chart placeholder and empty message
//
// A chart frame keeps its final size in every state, so the page does not move when the data lands: while
// loading it shows the empty axes it is about to fill, and once loading has finished with nothing to draw it
// shows one short line in the same frame. Both are static (nothing shimmers or loops), and both are drawn
// by every kit chart through its `ChartState`; pages with a chart of their own can use them directly.

/// Reserves a chart's final size while it loads: a value-axis gutter and a faint grid, nothing moving.
public struct ChartPlaceholder: View {
    private let height: CGFloat

    public init(height: CGFloat = NoopMetrics.chartHeightPrimary) {
        self.height = height
    }

    public var body: some View {
        ChartPlaceholderGrid()
            .frame(maxWidth: .infinity)
            .frame(height: height)
            .accessibilityElement()
            .accessibilityLabel(Text("Loading", bundle: .module))
    }
}

/// One short centred line inside an empty chart frame of the same height, shown only once loading has
/// finished and there is really nothing to draw.
public struct EmptyChartMessage: View {
    private let text: Text
    private let height: CGFloat

    public init(_ text: LocalizedStringKey, height: CGFloat = NoopMetrics.chartHeightPrimary) {
        self.text = Text(text)
        self.height = height
    }

    @_disfavoredOverload
    public init<S: StringProtocol>(_ text: S, height: CGFloat = NoopMetrics.chartHeightPrimary) {
        self.text = Text(text)
        self.height = height
    }

    public var body: some View {
        ZStack {
            ChartPlaceholderGrid().opacity(0.6)
            text
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
                .padding(.horizontal, NoopMetrics.space4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityElement(children: .combine)
    }
}

/// The empty axes both states draw: four hairlines over a leading gutter the width of a value label, and a
/// baseline gutter the height of a time label, so the real chart lands in the same place. A compact chart
/// has no value labels, so its placeholder has no leading gutter either.
struct ChartPlaceholderGrid: View {
    @Environment(\.naraChartCompact) private var compact

    var body: some View {
        GeometryReader { geo in
            let gutterX: CGFloat = compact ? 0 : 28
            let gutterY: CGFloat = 20
            let plotHeight = max(0, geo.size.height - gutterY - NaraChartStyle.plotTopPadding)
            Path { path in
                for row in 0...3 {
                    let y = NaraChartStyle.plotTopPadding + plotHeight * CGFloat(row) / 3
                    path.move(to: CGPoint(x: gutterX, y: y))
                    path.addLine(to: CGPoint(x: geo.size.width, y: y))
                }
            }
            .stroke(StrandPalette.hairline, style: NaraChartStyle.grid)
        }
        .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview("ChartPlaceholder · light") {
    VStack(spacing: NoopMetrics.space4) {
        NoopCard { ChartPlaceholder() }
        NoopCard { EmptyChartMessage("No readings in this range yet") }
    }
    .padding(NoopMetrics.screenHPadding)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.light)
}

#Preview("ChartPlaceholder · dark") {
    VStack(spacing: NoopMetrics.space4) {
        NoopCard { ChartPlaceholder(height: NoopMetrics.chartHeightCompact) }
        NoopCard { EmptyChartMessage("No heart rate yet today", height: NoopMetrics.chartHeightCompact) }
    }
    .padding(NoopMetrics.screenHPadding)
    .background(StrandPalette.surfaceBase)
    .preferredColorScheme(.dark)
}
#endif

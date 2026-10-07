import SwiftUI

// MARK: - MetricTile
//
// The top-level tile (Today's key metrics, Health's vitals): what the metric is, its value, and at most
// one state word. It deliberately has no progress bar (a bar implies a goal, and HRV, resting heart rate
// and SpO2 have none) and no helper caption ("latest", "Measured during sleep") that would make one tile
// taller than its neighbours. The detail lives one tap down.

/// A top-level metric tile.
///
/// ```swift
/// NavigationLink(value: TabRoute.metric("hrv")) {
///     MetricTile(icon: "waveform.path.ecg", iconColor: StrandPalette.metricPurple,
///                label: "HRV", value: hrv.map(fmt), unit: "ms",
///                state: "Within range", trend: last14, reservesTrendSlot: showsTrends)
/// }
/// .buttonStyle(.plain)
/// ```
///
/// - `value`: the formatted number; `nil` shows "—" with no unit.
/// - `state`: one short word or phrase ("Low", "Within range", "Last night · 4 Oct"), coloured by
///   `stateTone`. The word carries the meaning; the colour only reinforces it.
/// - `trend`: a few recent values drawn as a sparkline under the value (not on watchOS).
///   `reservesTrendSlot` keeps that space when a tile has no trend, so a grid where some tiles have one
///   still lines up: pass the same `reservesTrendSlot` to every tile in a grid.
/// - `isEstimate`: appends "Estimate" to the state line.
///
/// Height: every line is reserved and single-line, with `NoopMetrics.metricTileHeight` (plus
/// `metricTileTrendSlot` when the trend slot is shown) as the floor, so every tile in a grid has the
/// same height at any text size, whatever it contains. `isLoading` keeps that frame and redacts it.
public struct MetricTile: View {
    private let icon: String
    private let iconColor: Color
    private let label: LocalizedStringKey
    private let value: String?
    private let unit: String?
    private let state: String?
    private let stateTone: StrandTone
    private let trend: [Double]?
    private let reservesTrendSlot: Bool
    private let isEstimate: Bool
    private let isLoading: Bool

    public init(icon: String, iconColor: Color, label: LocalizedStringKey,
                value: String?, unit: String?,
                state: String? = nil, stateTone: StrandTone = .neutral,
                trend: [Double]? = nil, reservesTrendSlot: Bool = false,
                isEstimate: Bool = false, isLoading: Bool = false) {
        self.icon = icon
        self.iconColor = iconColor
        self.label = label
        self.value = value
        self.unit = unit
        self.state = state
        self.stateTone = stateTone
        self.trend = trend
        self.reservesTrendSlot = reservesTrendSlot
        self.isEstimate = isEstimate
        self.isLoading = isLoading
    }

    private var showsTrendSlot: Bool { reservesTrendSlot || (trend?.count ?? 0) > 1 }

    private var displayValue: String {
        if isLoading { return LoadingText.value }
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return "—" }
        return value
    }

    private var displayUnit: String? {
        guard isLoading || displayValue != "—", let unit, !unit.isEmpty else { return nil }
        return unit
    }

    public var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: icon)
                        .font(StrandFont.icon(.tile))
                        .foregroundStyle(iconColor)
                    Text(label)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 0)
                }
                Spacer(minLength: NoopMetrics.space2)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(displayValue)
                        .font(StrandFont.number(28))
                        .foregroundStyle(StrandPalette.textPrimary)
                    if let displayUnit {
                        Text(displayUnit)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                // Reserved when empty: a tile with a state word is never taller than one without.
                Text(MetricTile.stateLine(state: state, isEstimate: isEstimate) ?? " ")
                    .font(StrandFont.footnote)
                    .foregroundStyle(stateTone == .neutral ? StrandPalette.textSecondary : stateTone.color)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.top, NoopMetrics.space1)
                if showsTrendSlot {
                    trendSlot
                        .frame(height: NoopMetrics.metricTileTrendSlot - 6)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minHeight: NoopMetrics.metricTileHeight + (showsTrendSlot ? NoopMetrics.metricTileTrendSlot : 0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(label))
        .accessibilityValue(Text(accessibilityValue))
        .loadingPlaceholder(isLoading)
    }

    @ViewBuilder private var trendSlot: some View {
        #if !os(watchOS)
        let values = (trend ?? []).filter(\.isFinite)
        if !isLoading, values.count > 1 {
            Sparkline(values: values,
                      gradient: Gradient(colors: [iconColor.opacity(0.45), iconColor]),
                      lineWidth: 1.5, showsArea: false, showsHead: true, showsHover: false)
        } else {
            Color.clear
        }
        #else
        Color.clear
        #endif
    }

    private var accessibilityValue: String {
        let number = displayUnit.map { "\(displayValue) \($0)" } ?? displayValue
        return [number, MetricTile.stateLine(state: state, isEstimate: isEstimate)]
            .compactMap { $0 }
            .joined(separator: ", ")
    }

    /// The state line: the state word, then "Estimate" when the value is one ("Low · Estimate").
    /// `nil` when there is neither, so the line is reserved but blank.
    public static func stateLine(state: String?, isEstimate: Bool) -> String? {
        let word = state?.trimmingCharacters(in: .whitespaces)
        let parts = [word?.isEmpty == false ? word : nil,
                     isEstimate ? String(localized: "Estimate", bundle: .module) : nil].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

#if DEBUG
private struct MetricTilePreview: View {
    private let spark: [Double] = [58, 61, 60, 64, 62, 59, 63, 66, 62, 61, 65, 64]
    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.gap),
                                GridItem(.flexible(), spacing: NoopMetrics.gap)],
                      spacing: NoopMetrics.gap) {
                MetricTile(icon: "waveform.path.ecg", iconColor: StrandPalette.metricPurple,
                           label: "HRV", value: "62", unit: "ms", state: "Within range",
                           trend: spark, reservesTrendSlot: true)
                MetricTile(icon: "heart", iconColor: StrandPalette.metricRose,
                           label: "Resting HR", value: "57", unit: "bpm", state: "High",
                           stateTone: .warning, reservesTrendSlot: true)
                MetricTile(icon: "figure.walk", iconColor: StrandPalette.metricCyan,
                           label: "Steps", value: "8,412", unit: "steps",
                           reservesTrendSlot: true, isEstimate: true)
                MetricTile(icon: "scalemass", iconColor: StrandPalette.metricAmber,
                           label: "Weight", value: nil, unit: "kg", reservesTrendSlot: true)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: NoopMetrics.gap),
                                GridItem(.flexible(), spacing: NoopMetrics.gap)],
                      spacing: NoopMetrics.gap) {
                MetricTile(icon: "lungs", iconColor: StrandPalette.metricCyan,
                           label: "Respiratory rate", value: "14.2", unit: "rpm")
                MetricTile(icon: "drop", iconColor: StrandPalette.metricRose,
                           label: "Blood oxygen", value: nil, unit: "%", isLoading: true)
            }
            .padding(.top, NoopMetrics.sectionGap)
        }
        .padding(NoopMetrics.screenHPadding)
        .frame(width: 390, height: 560)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("MetricTile — light") {
    MetricTilePreview().preferredColorScheme(.light)
}

#Preview("MetricTile — dark") {
    MetricTilePreview().preferredColorScheme(.dark)
}
#endif

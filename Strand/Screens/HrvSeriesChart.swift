import SwiftUI
import StrandDesign

/// The hosted worker's intraday HRV: one RMSSD reading per 15-minute slot of the local day, on the kit's
/// compact intraday chart. A slot with no neighbour is a gap, never a line drawn across it.
struct HrvSeriesChart: View {
    let points: [HrvSeriesPoint]
    let slotSeconds: Int

    @State private var selected: Date?

    private func date(_ point: HrvSeriesPoint) -> Date {
        Date(timeIntervalSince1970: TimeInterval(point.startTs))
    }

    private var samples: [IntradayChart.Sample] {
        points.map { IntradayChart.Sample(time: date($0), value: $0.rmssd) }
    }

    /// The local day the readings fall in, so the axis reads midnight to midnight.
    private var window: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: points.first.map(date) ?? Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start...end
    }

    /// "62 ms at 09:12": the reading under the finger, else the latest.
    private var readout: String? {
        let sample = selected.flatMap { ChartSelection.sample(for: $0, in: samples) } ?? samples.last
        guard let sample else { return nil }
        let time = sample.time.formatted(date: .omitted, time: .shortened)
        return String(localized: "\(Int(sample.value.rounded())) ms at \(time)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(readout ?? " ")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .transaction { $0.animation = nil }
            IntradayChart(samples: samples, bucketSeconds: max(60, slotSeconds), color: StrandPalette.metricPurple,
                          compact: true, window: window,
                          y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                          selection: $selected, accessibilityTitle: String(localized: "Heart rate variability through the day"))
        }
    }
}

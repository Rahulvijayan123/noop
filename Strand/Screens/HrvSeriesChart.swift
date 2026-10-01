import SwiftUI
import Charts
import StrandDesign

/// The hosted worker's intraday HRV: one RMSSD reading per 15-minute slot of the local day.
///
/// A run of consecutive slots is one line, so a gap in the data (strap off, phone not synced, a slot
/// the worker rejected as movement noise) shows as a gap and not as a straight line drawn across it.
/// Each reading is also a point, so a slot with no neighbour still shows.
struct HrvSeriesChart: View {
    let points: [HrvSeriesPoint]
    let slotSeconds: Int

    private struct Run: Identifiable {
        let id: Int
        let points: [HrvSeriesPoint]
    }

    private var runs: [Run] {
        var grouped: [[HrvSeriesPoint]] = []
        for point in points {
            if let previous = grouped.last?.last, point.startTs - previous.startTs <= slotSeconds {
                grouped[grouped.count - 1].append(point)
            } else {
                grouped.append([point])
            }
        }
        return grouped.enumerated().map { Run(id: $0.offset, points: $0.element) }
    }

    private func date(_ point: HrvSeriesPoint) -> Date {
        Date(timeIntervalSince1970: TimeInterval(point.startTs))
    }

    private var latestSummary: String? {
        guard let latest = points.last else { return nil }
        let time = date(latest).formatted(date: .omitted, time: .shortened)
        return "\(Int(latest.rmssd.rounded())) ms at \(time)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack {
                Text("HRV every \(slotSeconds / 60) min")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: NoopMetrics.space2)
                if let latestSummary {
                    Text("Latest \(latestSummary)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Chart {
                ForEach(runs) { run in
                    ForEach(run.points, id: \.startTs) { point in
                        LineMark(x: .value("Time", date(point)), y: .value("HRV (ms)", point.rmssd),
                                 series: .value("Run", "run-\(run.id)"))
                            .foregroundStyle(StrandPalette.metricCyan)
                            .interpolationMethod(.monotone)
                    }
                }
                ForEach(points, id: \.startTs) { point in
                    PointMark(x: .value("Time", date(point)), y: .value("HRV (ms)", point.rmssd))
                        .foregroundStyle(StrandPalette.metricCyan)
                        .symbolSize(16)
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .chartYAxis { AxisMarks(position: .leading) }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .frame(height: 120)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Heart rate variability through the day"))
            .accessibilityValue(Text(latestSummary.map { "Latest \($0)" } ?? ""))
            Text("Daytime wrist readings are noisier than overnight ones.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

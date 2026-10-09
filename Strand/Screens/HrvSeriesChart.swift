import SwiftUI
import StrandDesign

/// The hosted worker's intraday HRV: one RMSSD reading per 15-minute slot of the local day, on the kit's
/// compact intraday chart. A slot with no neighbour is a gap, never a line drawn across it.
///
/// A slot the worker flagged weak (`hrv_series.context`: mostly movement, mostly unknown activity, or few
/// clean beats; audit D6-14) is left out of the line and the read-out and hatched behind it as time without a
/// trustworthy signal, so a walking slot never sets the shape of the day. See `HrvSeriesEmphasis`.
struct HrvSeriesChart: View {
    let points: [HrvSeriesPoint]
    let slotSeconds: Int

    @State private var selected: Date?

    private func date(_ point: HrvSeriesPoint) -> Date {
        Date(timeIntervalSince1970: TimeInterval(point.startTs))
    }

    private var samples: [IntradayChart.Sample] {
        HrvSeriesEmphasis.lineRuns(points, slotSeconds: slotSeconds).joined()
            .map { IntradayChart.Sample(time: date($0), value: $0.rmssd) }
    }

    private var weakBands: [IntradayChart.Band] {
        points.filter { HrvSeriesEmphasis.emphasis(of: $0) == .deemphasised }.map {
            IntradayChart.Band(id: "weak-\($0.startTs)", start: date($0),
                               end: date($0).addingTimeInterval(TimeInterval(slotSeconds)),
                               color: StrandPalette.textTertiary, hatched: true)
        }
    }

    /// The local day the readings fall in, so the axis reads midnight to midnight.
    private var window: ClosedRange<Date> {
        let start = Calendar.current.startOfDay(for: points.first.map(date) ?? Date())
        let end = Calendar.current.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return start...end
    }

    /// "62 ms at 09:12": the reading under the finger, else the latest well-supported one.
    private var readout: String? {
        let sample = selected.flatMap { ChartSelection.sample(for: $0, in: samples) } ?? samples.last
        guard let sample else { return nil }
        let time = sample.time.formatted(date: .omitted, time: .shortened)
        return String(localized: "\(Int(sample.value.rounded())) ms at \(time)")
    }

    private var notes: [String] {
        [HrvSeriesEmphasis.weakNote(points), HrvSeriesEmphasis.pendingNote(points)].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(readout ?? " ")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .transaction { $0.animation = nil }
            IntradayChart(samples: samples, bucketSeconds: max(60, slotSeconds), color: StrandPalette.metricPurple,
                          bands: weakBands, compact: true, window: window,
                          y: ChartValueAxis(unit: "ms", domain: .fitted(minSpan: 20)),
                          selection: $selected, accessibilityTitle: String(localized: "Heart rate variability through the day"))
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// How each intraday HRV point is drawn. Pure, so the mapping is unit-tested without rendering.
enum HrvSeriesEmphasis: Equatable {
    /// Drawn normally, joined into the line, eligible for the "latest" read-out.
    case full
    /// Hatched behind the line as untrusted time; never part of the line or the read-out.
    case deemphasised

    /// A point is de-emphasised only when the worker flagged it weak. A point without context (a snapshot
    /// from before the flags existed) keeps its old look rather than guessing.
    static func emphasis(of point: HrvSeriesPoint) -> HrvSeriesEmphasis {
        point.context?.weak == true ? .deemphasised : .full
    }

    /// The line's runs: consecutive well-supported points. A weak point or a missing slot breaks the run, so
    /// the line never bridges across a reading it does not trust.
    static func lineRuns(_ points: [HrvSeriesPoint], slotSeconds: Int) -> [[HrvSeriesPoint]] {
        var grouped: [[HrvSeriesPoint]] = []
        var previous: HrvSeriesPoint?
        for point in points {
            defer { previous = point }
            guard emphasis(of: point) == .full else { continue }
            // A full `previous` is always the last point of the last run.
            if let previous, emphasis(of: previous) == .full, point.startTs - previous.startTs <= slotSeconds {
                grouped[grouped.count - 1].append(point)
            } else {
                grouped.append([point])
            }
        }
        return grouped
    }

    /// A quiet note when some readings' activity context is not published yet. Those readings are drawn normally;
    /// nil when there are none, or when every one of them is already left out for another reason.
    static func pendingNote(_ points: [HrvSeriesPoint]) -> String? {
        let pending = points.filter {
            emphasis(of: $0) == .full && ($0.context?.reasons.contains(.contextPending) ?? false)
        }
        guard !pending.isEmpty else { return nil }
        return pending.count == points.count
            ? "Activity context is not available yet for these readings."
            : "Activity context is not available yet for the latest readings."
    }

    /// The newest well-supported point, which the "latest" read-out names.
    static func latestSupported(_ points: [HrvSeriesPoint]) -> HrvSeriesPoint? {
        points.last { emphasis(of: $0) == .full }
    }

    /// One plain sentence on why some readings are left out, or nil when none are.
    static func weakNote(_ points: [HrvSeriesPoint]) -> String? {
        let weak = points.filter { emphasis(of: $0) == .deemphasised }
        guard !weak.isEmpty else { return nil }
        let reasons = Set(weak.flatMap { $0.context?.reasons ?? [] })
        var why: [String] = []
        if reasons.contains(.movement) { why.append("you were moving") }
        if reasons.contains(.unknownContext) { why.append("activity was unclear") }
        if reasons.contains(.sparseBeats) { why.append("there were few clean beats") }
        let count = weak.count == 1 ? "1 reading" : "\(weak.count) readings"
        let joined = why.count <= 2 ? why.joined(separator: " or ")
            : why.dropLast().joined(separator: ", ") + ", or " + why[why.count - 1]
        let because = why.isEmpty ? "" : " because " + joined
        return "\(count) left out of the line and latest value\(because)."
    }
}

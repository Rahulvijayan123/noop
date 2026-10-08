import SwiftUI
import Charts
import StrandDesign

/// The hosted worker's intraday HRV: one RMSSD reading per 15-minute slot of the local day.
///
/// A run of consecutive slots is one line, so a gap in the data (strap off, phone not synced, a slot
/// the worker rejected as movement noise) shows as a gap and not as a straight line drawn across it.
/// Each reading is also a point, so a slot with no neighbour still shows.
///
/// A slot the worker flagged weak (`hrv_series.context`: mostly movement, mostly unknown activity, or few
/// clean beats; audit D6-14) is still drawn, as a faded hollow point, but it is left out of the line and
/// the "latest" read-out, so a walking slot never sets the shape of the day. See `HrvSeriesEmphasis`.
struct HrvSeriesChart: View {
    let points: [HrvSeriesPoint]
    let slotSeconds: Int

    private struct Run: Identifiable {
        let id: Int
        let points: [HrvSeriesPoint]
    }

    private var runs: [Run] {
        HrvSeriesEmphasis.lineRuns(points, slotSeconds: slotSeconds)
            .enumerated().map { Run(id: $0.offset, points: $0.element) }
    }

    private func date(_ point: HrvSeriesPoint) -> Date {
        Date(timeIntervalSince1970: TimeInterval(point.startTs))
    }

    private var latestSummary: String? {
        guard let latest = HrvSeriesEmphasis.latestSupported(points) else { return nil }
        let time = date(latest).formatted(date: .omitted, time: .shortened)
        return "\(Int(latest.rmssd.rounded())) ms at \(time)"
    }

    private var weakNote: String? { HrvSeriesEmphasis.weakNote(points) }
    private var pendingNote: String? { HrvSeriesEmphasis.pendingNote(points) }

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
                    if HrvSeriesEmphasis.emphasis(of: point) == .full {
                        PointMark(x: .value("Time", date(point)), y: .value("HRV (ms)", point.rmssd))
                            .foregroundStyle(StrandPalette.metricCyan)
                            .symbolSize(16)
                    } else {
                        PointMark(x: .value("Time", date(point)), y: .value("HRV (ms)", point.rmssd))
                            .symbol {
                                Circle()
                                    .strokeBorder(StrandPalette.metricCyan, lineWidth: 1)
                                    .frame(width: 5, height: 5)
                            }
                            .opacity(StrandPalette.disabledOpacity)
                    }
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
            .accessibilityValue(Text([latestSummary.map { "Latest \($0)" }, weakNote, pendingNote]
                .compactMap { $0 }.joined(separator: ". ")))
            Text("Daytime wrist readings are noisier than overnight ones.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            ForEach([weakNote, pendingNote].compactMap { $0 }, id: \.self) { note in
                Text(note)
                    .font(StrandFont.caption)
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
    /// Drawn faded and hollow; never part of the line or the read-out.
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
    /// nil when there are none, or when every one of them is already faded for another reason.
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

    /// One plain sentence on why some points are faded, or nil when none are.
    static func weakNote(_ points: [HrvSeriesPoint]) -> String? {
        let weak = points.filter { emphasis(of: $0) == .deemphasised }
        guard !weak.isEmpty else { return nil }
        let reasons = Set(weak.flatMap { $0.context?.reasons ?? [] })
        var why: [String] = []
        if reasons.contains(.movement) { why.append("you were moving") }
        if reasons.contains(.unknownContext) { why.append("activity was unclear") }
        if reasons.contains(.sparseBeats) { why.append("there were few clean beats") }
        let count = weak.count == 1 ? "1 faded reading" : "\(weak.count) faded readings"
        let joined = why.count <= 2 ? why.joined(separator: " or ")
            : why.dropLast().joined(separator: ", ") + ", or " + why[why.count - 1]
        let because = why.isEmpty ? "" : " because " + joined
        return "\(count) left out of the line and latest value\(because)."
    }
}

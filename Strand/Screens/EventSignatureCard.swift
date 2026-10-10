import SwiftUI
import Charts
import StrandDesign

// MARK: - Event signature
//
// What Nara has learned about how one person's readings change around one event type they log
// (docs/PHENOTYPE_SIGNATURES.md, signature-report-1). Top to bottom: where the signature stands, the findings
// (each with its direction, change and interval, and how many events showed it), the event-locked profile of
// the top channel, the evidence behind it, whether it could ever support alerts, and the data-quality notes and
// limitations. It describes patterns in the person's own readings, never a diagnosis, and says alerts are off.

struct EventSignatureCard: View {
    let report: SignatureReport?
    /// Events of this type logged so far, for the status before the first report.
    let loggedEvents: Int
    /// Whether the cloud has answered for this type yet.
    var checked = true

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            statusCard
            if let signature = report?.primary {
                if !signature.findings.isEmpty { findingsCard(signature) }
                // An average with a 95% range means something only once a pattern is testable: with one or two
                // days the day-level range collapses onto the line. Before that, each event's own context is shown.
                if SignaturePresentation.showsProfile(report), let profile = SignaturePresentation.profileChannel(signature) {
                    profileCard(signature, key: profile.key, channel: profile.channel)
                }
            }
            if let report { evidenceCard(report) }
            detectabilityCard
            if let report, !(report.dataQuality?.notes.isEmpty ?? true) || !report.limitations.isEmpty {
                notesCard(report)
            }
        }
    }

    // MARK: Status

    private var statusCard: some View {
        let line = SignaturePresentation.status(report, loggedEvents: loggedEvents)
        return NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Label {
                    Text(line.title).font(StrandFont.headline)
                } icon: {
                    Image(systemName: line.symbol).foregroundStyle(StrandPalette.metricPurple)
                }
                Text(line.detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if report?.status == nil, loggedEvents < SignaturePresentation.minimumEvents {
                    ProgressView(value: Double(loggedEvents), total: Double(SignaturePresentation.minimumEvents))
                        .tint(StrandPalette.metricPurple)
                    Text("\(loggedEvents) of \(SignaturePresentation.minimumEvents) events logged")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
                if let generated = report?.generated {
                    Text("Last analysed \(generated.formatted(date: .abbreviated, time: .shortened))")
                        .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                } else if !checked {
                    Text("Checking the cloud for an analysis…").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Findings

    private func findingsCard(_ signature: SignatureReport.Signature) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("What changes around this event").font(StrandFont.headline)
                ForEach(Array(signature.findings.prefix(5).enumerated()), id: \.offset) { index, finding in
                    if index > 0 { Divider() }
                    findingRow(finding)
                }
                Text("Compared with similar times without this event: same activity and time of day, on other days. “Vs the minutes before” is the change from just before onset, compared with how much it changes at those times.")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func findingRow(_ finding: SignatureReport.Finding) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: SignaturePresentation.directionSymbol(finding))
                .font(StrandFont.headline).foregroundStyle(StrandPalette.metricPurple)
                .frame(width: 32, height: 32)
                .background(StrandPalette.metricPurple.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(finding.text ?? SignaturePresentation.channelTitle(finding.channel))
                    .font(StrandFont.subhead).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let change = SignaturePresentation.change(finding) { chip(change, strong: true) }
                    if let window = SignaturePresentation.window(finding.window) { chip(window) }
                }
                let parts = SignaturePresentation.jointParts(finding)
                if !parts.isEmpty {
                    HStack(spacing: 6) { ForEach(parts, id: \.self) { chip($0) } }
                }
                HStack(spacing: 6) {
                    if let basis = SignaturePresentation.basis(finding) { chip(basis) }
                    if let movement = SignaturePresentation.movement(finding) { chip(movement) }
                }
                if let consistency = SignaturePresentation.consistency(finding),
                   let n = finding.consistentEvents, let total = finding.eventsWithData, total > 0 {
                    HStack(spacing: 8) {
                        ConsistencyDots(hits: n, total: total)
                        Text(consistency).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text("Seen in \(consistency)"))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func chip(_ text: String, strong: Bool = false) -> some View {
        Text(text).font(strong ? StrandFont.captionNumber : StrandFont.caption)
            .foregroundStyle(strong ? StrandPalette.textPrimary : StrandPalette.textSecondary)
            .lineLimit(1).minimumScaleFactor(0.8)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(StrandPalette.surfaceInset, in: Capsule())
    }

    // MARK: Profile

    private func profileCard(_ signature: SignatureReport.Signature, key: String,
                             channel: SignatureReport.ProfileChannel) -> some View {
        let points = SignaturePresentation.profilePoints(channel, lags: signature.profile?.lags ?? [-30, 30])
        let unit = channel.unit ?? ""
        let banded = points.filter { $0.low != nil && $0.high != nil }
        let values = points.flatMap { [$0.mean, $0.low, $0.high].compactMap { $0 } }
        let lo = values.min() ?? 0, hi = values.max() ?? 1
        let pad = max((hi - lo) * 0.12, 0.5)
        let color = StrandPalette.metricPurple
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text("\(SignaturePresentation.channelTitle(key)) around the event").font(StrandFont.headline)
                    Text("Average of \(SignaturePresentation.count(signature.events ?? points.count, "event")), with its 95% range")
                        .font(StrandFont.footnote).foregroundStyle(StrandPalette.textSecondary)
                }
                Chart {
                    ForEach(banded) { point in
                        AreaMark(x: .value("Minutes", point.minute), yStart: .value("Low", point.low ?? point.mean),
                                 yEnd: .value("High", point.high ?? point.mean), series: .value("Run", "band\(point.run)"))
                            .interpolationMethod(.monotone)
                            .foregroundStyle(color.opacity(0.16))
                    }
                    RuleMark(x: .value("Onset", 0))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .annotation(position: .top, alignment: .leading, spacing: 2) {
                            Text("Onset").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    ForEach(points) { point in
                        LineMark(x: .value("Minutes", point.minute), y: .value(unit, point.mean),
                                 series: .value("Run", "mean\(point.run)"))
                            .interpolationMethod(.monotone)
                            .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                            .foregroundStyle(color)
                    }
                }
                .chartXScale(domain: (signature.profile?.lags.first ?? -30)...(signature.profile?.lags.last ?? 30))
                .chartYScale(domain: (lo - pad)...(hi + pad))
                .chartXAxis {
                    AxisMarks(values: [-30, -15, 0, 15, 30]) { value in
                        AxisGridLine().foregroundStyle(StrandPalette.hairline)
                        // The last label sits inside the plot so it is never clipped at the trailing edge.
                        AxisValueLabel(anchor: value.index == 4 ? .topTrailing : value.index == 0 ? .topLeading : .top) {
                            if let minute = value.as(Double.self) {
                                Text(minute == 0 ? "0" : "\(minute > 0 ? "+" : "−")\(Int(abs(minute)))")
                                    .font(StrandFont.caption)
                            }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine().foregroundStyle(StrandPalette.hairline)
                        AxisValueLabel().font(StrandFont.caption)
                    }
                }
                .chartYAxisLabel(unit, position: .topLeading)
                .chartXAxisLabel("minutes from onset", position: .bottom, alignment: .center)
                .frame(height: NoopMetrics.chartHeightSecondary)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text("\(SignaturePresentation.channelTitle(key)) from 30 minutes before to 30 minutes after the event"))
                .accessibilityValue(Text(profileSummary(points, unit: unit)))
                HStack(spacing: 14) {
                    legend(color: color, text: "Average")
                    legend(color: color.opacity(0.25), text: "95% range", block: true)
                    Spacer()
                }
            }
        }
    }

    private func legend(color: Color, text: String, block: Bool = false) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: block ? 10 : 3)
            Text(text).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func profileSummary(_ points: [SignaturePresentation.ProfilePoint], unit: String) -> String {
        let before = points.filter { $0.minute < 0 }.map(\.mean), after = points.filter { $0.minute >= 0 }.map(\.mean)
        guard let b = before.isEmpty ? nil : before.reduce(0, +) / Double(before.count),
              let peak = after.max(by: { abs($0 - b) < abs($1 - b) }) else { return "" }
        return "Average before \(Int(b.rounded())) \(unit), furthest after the event \(Int(peak.rounded())) \(unit)"
    }

    // MARK: Evidence

    private func evidenceCard(_ report: SignatureReport) -> some View {
        let e = report.evidence
        let items: [StatItem] = [
            StatItem("Events", value: e?.events.map(String.init)),
            StatItem("Days", value: e?.eventDays.map(String.init)),
            StatItem("Observed", value: e?.observationHours.map { String(format: $0 < 100 && $0.rounded() != $0 ? "%.1f" : "%.0f", $0) }, unit: "h"),
            StatItem("Confirmed", value: e?.confirmedDetections.map(String.init)),
            StatItem("Rejected", value: e?.rejectedDetections.map(String.init)),
            StatItem("Monitored", value: e?.monitoredDays.map { String(format: "%.1f", $0) }, unit: "days"),
        ]
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Evidence")
            StatGrid(items, columns: 3)
            Text("Observed: hours you logged as watched, with every event recorded. Confirmed and rejected: possible events you reviewed.")
                .font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Detectability

    private var detectabilityCard: some View {
        let detect = report.map(SignaturePresentation.detectability)
            ?? SignaturePresentation.Detectability(title: "Not reliable enough for alerts yet", detail: "", promising: false)
        return NoopCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Could this support alerts?").font(StrandFont.headline)
                Label(detect.title, systemImage: detect.promising ? "sparkles" : "hourglass")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(detect.promising ? StrandPalette.metricPurple : StrandPalette.textPrimary)
                if !detect.detail.isEmpty {
                    Text(detect.detail).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Label(SignaturePresentation.alertsOff, systemImage: "bell.slash")
                    .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Notes

    private func notesCard(_ report: SignatureReport) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let dropped = SignaturePresentation.droppedNote(report) {
                Label(dropped, systemImage: "minus.circle").fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array((report.dataQuality?.notes ?? []).enumerated()), id: \.offset) { _, note in
                Label(note, systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
            }
            ForEach(Array(report.limitations.enumerated()), id: \.offset) { _, limitation in
                Label(limitation, systemImage: "exclamationmark.circle").fixedSize(horizontal: false, vertical: true)
            }
            Text("These are patterns in your own readings around the events you logged. They are not a diagnosis.")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
    }
}

/// One dot per event with data; filled where the event changed in the finding's direction.
private struct ConsistencyDots: View {
    let hits: Int
    let total: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(total, 20), id: \.self) { index in
                Circle()
                    .fill(index < hits ? StrandPalette.metricPurple : StrandPalette.textTertiary.opacity(0.35))
                    .frame(width: 7, height: 7)
            }
        }
    }
}

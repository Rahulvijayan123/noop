import SwiftUI
import StrandDesign

// MARK: - Event detail
//
// One event: what happened, and what the body did around it. Top to bottom: the event (its detail, time,
// duration and whether it was reported or detected), the readout the chart drives, the metric switch,
// the event-window chart, Before / During / After for the selected metric, the recovery numbers with the
// comparison against other events of the same kind and the link to the recovery history, links to the
// metric pages, and the About card that defines the phases.

struct EventDetailView: View {
    let event: HealthEvent
    var history: [HealthEvent] = []

    @State private var metricIndex = EventDetailView.initialMetricIndex
    @State private var selected: Date?

    var body: some View {
        ScreenScaffold(title: verbatimKey(event.title), titleDisplay: .navigationBar) {
            EventHeader(event: event)
            if let physiology = event.physiology, !physiology.metrics.isEmpty {
                physiologySection(physiology)
            } else {
                NoopCard {
                    EmptyChartMessage(String(localized: "No readings around this event"),
                                      height: NoopMetrics.chartHeightSecondary)
                }
            }
            if let recovery = event.recovery {
                recoverySection(recovery)
            }
            relatedSection
            AboutDisclosure(paragraphs: aboutParagraphs)
        }
        .onChangeCompat(of: metricIndex) { _ in selected = nil }
    }

    /// The metric the page opens on: the first. DEBUG builds take `--demo-event-metric N` for screenshots.
    private static var initialMetricIndex: Int {
        #if DEBUG
        return DemoLaunch.intArg("--demo-event-metric") ?? 0
        #else
        return 0
        #endif
    }

    // MARK: Physiology

    private func metric(in physiology: EventPhysiology) -> PhysiologyMetric {
        physiology.metrics[min(metricIndex, max(0, physiology.metrics.count - 1))]
    }

    @ViewBuilder
    private func physiologySection(_ physiology: EventPhysiology) -> some View {
        let metric = metric(in: physiology)
        let stats = EventPhaseStats(physiology: physiology, metric: metric)
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            ValueReadout(readout(stats), isScrubbing: selected != nil)
            if physiology.metrics.count > 1 {
                metricSwitch(physiology)
            }
        }
        NoopCard {
            EventWindowChart(physiology: physiology, metric: metric, eventDate: event.date, selection: $selected)
        }
        StatGrid(EventPhase.allCases.map { phase in
            StatItem(phase.title, value: stats.mean(phase).map(EventFormat.value), unit: metric.unit,
                     detail: phase == .before ? nil : stats.change(phase).map(EventFormat.percentChange))
        }, columns: 3)
    }

    @ViewBuilder
    private func metricSwitch(_ physiology: EventPhysiology) -> some View {
        if physiology.metrics.count <= 3 {
            SegmentedPillControl(Array(physiology.metrics.indices), selection: $metricIndex, fillsAvailableWidth: true) {
                physiology.metrics[$0].name
            }
        } else {
            Menu {
                ForEach(Array(physiology.metrics.enumerated()), id: \.offset) { index, m in
                    Button(m.name) { metricIndex = index }
                }
            } label: {
                HStack(spacing: NoopMetrics.space1) {
                    Text(verbatim: metric(in: physiology).name)
                    Image(systemName: "chevron.down").font(StrandFont.icon(.inline))
                }
                .font(StrandFont.subhead.weight(.medium))
                .foregroundStyle(StrandPalette.accent)
                .frame(minHeight: NoopMetrics.minimumHitTarget)
            }
        }
    }

    /// The scrubbed reading against the "before" mean, or, at rest, the reading furthest in the unhealthy
    /// direction during the event (the lowest HRV, the highest heart rate).
    private func readout(_ stats: EventPhaseStats) -> ReadoutContent {
        let samples = EventWindowChart.samples(stats.metric)
        let unit = stats.metric.unit
        if let selected, let sample = ChartSelection.sample(for: selected, in: samples) {
            let context = stats.change(of: sample.value).map {
                String(localized: "\(EventFormat.percentChange($0)) vs before")
            }
            return ReadoutContent(dateLine: ReadoutContent.dateLine(sample.time, period: .time),
                                  value: EventFormat.value(sample.value), unit: unit, context: context)
        }
        guard let extreme = stats.extreme() else {
            return ReadoutContent(dateLine: "", value: nil, unit: unit)
        }
        let point = extreme.point, phase = extreme.phase
        let lowest = stats.metric.higherIsBetter ?? true
        let time = EventFormat.time(point.time)
        let line: String
        switch (lowest, phase) {
        case (true, .during): line = String(localized: "Lowest during, \(time)")
        case (true, _): line = String(localized: "Lowest after, \(time)")
        case (false, .during): line = String(localized: "Highest during, \(time)")
        case (false, _): line = String(localized: "Highest after, \(time)")
        }
        let context = stats.change(of: point.value).map {
            String(localized: "\(EventFormat.percentChange($0)) vs before")
        }
        return ReadoutContent(dateLine: line, value: EventFormat.value(point.value), unit: unit, context: context)
    }

    // MARK: Recovery

    private var sameKind: [HealthEvent] {
        history.filter { $0.title == event.title && $0.id != event.id }
    }

    @ViewBuilder
    private func recoverySection(_ recovery: EventRecovery) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Recovery")
            StatGrid([
                StatItem(String(localized: "To recover"), value: recovery.timeToRecover.map(EventFormat.duration),
                         detail: recovery.timeToRecover.map {
                             String(localized: "by \(EventFormat.time(event.date.addingTimeInterval($0)))")
                         }),
                StatItem(String(localized: "HRV regained"), value: recovery.hrvReturn.map(EventFormat.share), unit: "%",
                         detail: String(localized: "of before")),
                StatItem(String(localized: "Active again"), value: recovery.activityReturn.map(EventFormat.duration),
                         detail: String(localized: "after the event")),
            ], columns: 3)
            if let curves = recoveryCurves {
                curves
            }
            let count = history.filter { $0.recovery != nil }.count
            NoopListSection {
                NavigationLink(value: TabRoute.recoveryDetails(event, history: history)) {
                    NoopListRow(icon: nil, title: "Recovery history",
                                value: count > 0 ? String(localized: "\(count) events") : nil)
                }
            }
            .buttonStyle(.plain)
        }
    }

    /// This event's after-window against the other events of the same kind with the same metric.
    private var recoveryCurves: EventRecoveryCurves? {
        guard let physiology = event.physiology, !physiology.metrics.isEmpty else { return nil }
        let metric = metric(in: physiology)
        guard let current = EventRecoveryCurves.curve(for: event, metricName: metric.name) else { return nil }
        let others = sameKind.compactMap { EventRecoveryCurves.curve(for: $0, metricName: metric.name) }
        guard !others.isEmpty else { return nil }
        return EventRecoveryCurves(title: event.title, current: current, others: others,
                                   color: EventFormat.color(for: metric))
    }

    // MARK: Related

    /// The metric pages behind this event's readings.
    @ViewBuilder
    private var relatedSection: some View {
        let units = Set(event.physiology?.metrics.map { $0.unit.lowercased() } ?? [])
        if units.contains("ms") || units.contains("bpm") {
            NoopListSection("Related") {
                if units.contains("ms") {
                    NavigationLink(value: TabRoute.metric("hrv")) {
                        NoopListRow(icon: "waveform.path.ecg", iconColor: StrandPalette.metricPurple,
                                    title: "Heart rate variability")
                    }
                }
                if units.contains("ms") && units.contains("bpm") {
                    NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                }
                if units.contains("bpm") {
                    NavigationLink(value: TabRoute.heartRateDay) {
                        NoopListRow(icon: "heart", iconColor: StrandPalette.metricRose, title: "Heart rate")
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: About

    private var aboutParagraphs: [String] {
        var out = [String(localized: "Before is your average in the hours leading up to the event. During covers the event itself and After the hours that follow. Changes are shown against Before.")]
        if event.recovery != nil {
            out.append(String(localized: "Time to recover is how long your readings took to return toward their level before the event. HRV regained is how much of that level your HRV was back to."))
        }
        out.append(String(localized: "A change shown here happened around the same time as the event. It does not show that the event caused it."))
        return out
    }
}

/// What happened: the event's detail, when, for how long, and whether it was reported or detected.
private struct EventHeader: View {
    let event: HealthEvent

    private var meta: String {
        var parts = [EventFormat.dayAndTime(event.date)]
        if let physiology = event.physiology, physiology.eventEnd > physiology.eventStart {
            parts.append(EventFormat.duration(physiology.eventEnd.timeIntervalSince(physiology.eventStart)))
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            Image(systemName: event.symbol)
                .font(StrandFont.icon(.row))
                .foregroundStyle(event.tone.color)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                Text(verbatim: event.detail ?? event.title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(2)
                Text(verbatim: meta)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: NoopMetrics.space2)
            SourceBadge(event.origin == .reported ? "Reported" : "Detected", tint: StrandPalette.textSecondary)
        }
        .accessibilityElement(children: .combine)
    }
}

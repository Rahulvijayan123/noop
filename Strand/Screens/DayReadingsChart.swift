import SwiftUI
import StrandDesign
import StrandAnalytics

/// Every reading of one vital since local midnight, on the key-metric screen's Today rules
/// (`KeyMetricWindows.day`): the server's windows for heart rate, resting heart rate, HRV and breathing, the strap
/// readings the phone banked for temperature and blood oxygen, each dot coloured by what the wearer was doing,
/// the activity lane under it and the gaps shaded with their reasons. Scrub to read one.
struct DayReadingsChart: View {
    let metric: MetricInsightMetric
    /// The unit the reading is shown in, and whether temperature is shown in °F (banked values are °C).
    let unit: String
    var fahrenheit = false

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var context = PhysiologyContextStore.shared
    @ObservedObject private var lanes = KeyMetricActivityLanes.shared
    @State private var banked: KeyMetricReadings.BankedSeries?
    @State private var selected: Date?
    @State private var inset = KeyMetricPlotInsetKey.defaultValue

    private var day: String { Repository.localDayKey(Date()) }

    private var kinds: [PhysiologyContext.MetricKind] {
        var out: [PhysiologyContext.MetricKind] = [.heartRate]
        if case .windows(let kind)? = metric.todaySource, kind != .heartRate { out.append(kind) }
        if let night = metric.nightlyContextMetric, !out.contains(night) { out.append(night) }
        return out
    }

    private func documents(_ kind: PhysiologyContext.MetricKind) -> [PhysiologyContextDocument] {
        [context.state(for: .init(day: day, metric: kind))?.shownDay?.document].compactMap { $0 }
    }

    private var zone: TimeZone {
        PhysiologyContextWording.zone(kinds.lazy.compactMap { documents($0).first?.timezoneId }.first)
    }

    private var interval: PhysiologyContext.Interval? { KeyMetricWindows.today(day, timeZone: zone) }

    private var shown: KeyMetricWindows.DayReadings {
        guard let source = metric.todaySource, let interval else { return .init() }
        return KeyMetricWindows.day(source, night: metric.nightlyContextMetric, interval: interval,
                                    documents: documents, banked: banked)
    }

    private func display(_ v: Double) -> Double { metric == .skinTemp && fahrenheit ? v * 9 / 5 + 32 : v }

    var body: some View {
        let shown = self.shown
        let readings = shown.readings
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Today")
                    .font(KeyMetricStyle.labelStrong)
                    .foregroundStyle(KeyMetricStyle.text)
                Spacer(minLength: 8)
                if let source = metric.todaySource {
                    Text(KeyMetricScreenCopy.todayGrain(source, sessions: shown.sessions))
                        .font(KeyMetricStyle.small)
                        .foregroundStyle(KeyMetricStyle.secondary)
                        .multilineTextAlignment(.trailing)
                }
            }
            if let interval, !readings.isEmpty {
                chart(readings, gaps: shown.gaps, interval: interval)
                if !shown.lane.isEmpty {
                    KeyMetricActivityLane(spans: shown.lane, domain: domain(interval), inset: inset, guideX: selected)
                }
                Text(readout(readings, gaps: shown.gaps))
                    .font(KeyMetricStyle.label)
                    .foregroundStyle(KeyMetricStyle.text)
                    .monospacedDigit()
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let note = note(readings, gaps: shown.gaps, sessions: shown.sessions, interval: interval) {
                    Text(note)
                        .font(KeyMetricStyle.small)
                        .foregroundStyle(KeyMetricStyle.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text(emptyText)
                    .font(KeyMetricStyle.label)
                    .foregroundStyle(KeyMetricStyle.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .onPreferenceChange(KeyMetricPlotInsetKey.self) { inset = $0 }
        .task(id: "\(day)|\(context.epoch)|\(repo.refreshSeq)") { await load() }
    }

    private var emptyText: String {
        if metric.todaySource == .banked(.spo2) { return KeyMetricScreenCopy.spo2SleepOnly }
        let states = kinds.map { context.state(for: .init(day: day, metric: $0)) }
        if states.contains(where: { $0 == nil || $0 == .loading }) || (metric.todaySource?.isBanked == true && banked == nil) {
            return KeyMetricScreenCopy.windowsLoading
        }
        return KeyMetricScreenCopy.noReadingsToday
    }

    private func domain(_ interval: PhysiologyContext.Interval) -> ClosedRange<Date> {
        Date(timeIntervalSince1970: TimeInterval(interval.start))...Date(timeIntervalSince1970: TimeInterval(interval.end))
    }

    private func chart(_ readings: [KeyMetricWindowReading], gaps: [KeyMetricGap],
                       interval: PhysiologyContext.Interval) -> some View {
        let domain = domain(interval)
        let dots = readings.map { r in
            KeyMetricDot(id: r.id, x: r.mid, y: display(r.value), color: KeyMetricActivityLane.dotColor(r.context),
                         span: r.isSpan ? Date(timeIntervalSince1970: TimeInterval(r.start))...Date(timeIntervalSince1970: TimeInterval(r.end)) : nil)
        }
        let pick = selected.flatMap { nearest(readings, to: $0) }
        return KeyMetricDotChart(dots: dots, domain: domain, gaps: gaps,
                                 yTitle: unit.isEmpty ? "" : "(\(unit))", xTitle: KeyMetricScreenCopy.localTime,
                                 xTicks: KeyMetricDetailView.hourTicks(domain, zone: zone),
                                 xLabel: { KeyMetricDetailView.hourLabel($0, zone: zone) },
                                 dotSize: readings.count > 400 ? 6 : readings.count > 160 ? 10 : 16,
                                 minimumPad: 2, floorsAtZero: metric != .skinTemp, height: 180,
                                 guideX: selected, selectedID: pick?.id,
                                 onSelect: { date in
                                     if nearest(readings, to: date)?.id != pick?.id { StrandHaptic.selection.play() }
                                     selected = date
                                 })
    }

    private func nearest(_ readings: [KeyMetricWindowReading], to date: Date) -> KeyMetricWindowReading? {
        guard let r = readings.min(by: { abs($0.mid.timeIntervalSince(date)) < abs($1.mid.timeIntervalSince(date)) })
        else { return nil }
        return abs(r.mid.timeIntervalSince(date)) <= max(450, Double(r.end - r.start) / 2) ? r : nil
    }

    /// The reading under the finger (or the latest), its time and context; or why there is none there.
    private func readout(_ readings: [KeyMetricWindowReading], gaps: [KeyMetricGap]) -> String {
        if let selected, nearest(readings, to: selected) == nil {
            let reason = gaps.first { $0.contains(selected) }?.words
            let time = KeyMetricDetailView.timeText(selected, zone: zone)
            return [KeyMetricScreenCopy.noReading, time, reason.map(PhysiologyContextWording.capitalizedFirst)]
                .compactMap { $0 }.joined(separator: " · ")
        }
        guard let r = selected.flatMap({ nearest(readings, to: $0) }) ?? readings.last else { return " " }
        let time = r.isSpan
            ? PhysiologyContextWording.timeRange(.init(r.start, r.end), zone: zone, locale: AppLanguage.activeLocale)
            : KeyMetricDetailView.timeText(r.mid, zone: zone)
        return "\(MonitorLabels.number(display(r.value), unit: unit)) \(unit) · \(time) · \(r.context.name)"
    }

    private func note(_ readings: [KeyMetricWindowReading], gaps: [KeyMetricGap], sessions: Bool,
                      interval: PhysiologyContext.Interval) -> String? {
        let gapNote = KeyMetricGap.note(gaps, in: domain(interval))
        guard !sessions else { return gapNote }
        return ["\(KeyMetricScreenCopy.todayCount(readings.count)).", gapNote].compactMap { $0 }.joined(separator: " ")
    }

    private func load() async {
        await lanes.load(dayStart: Calendar.current.startOfDay(for: Date()), repo: repo)
        for kind in kinds {
            guard !Task.isCancelled else { return }
            await context.load(.init(day: day, metric: kind))
        }
        guard case .banked(let signal)? = metric.todaySource, let interval else { return }
        let series = await repo.bankedSeries(signal, from: interval.start, to: interval.end)
        guard !Task.isCancelled else { return }
        banked = series
    }
}

extension KeyMetricTodaySource {
    var isBanked: Bool { if case .banked = self { return true } else { return false } }
}

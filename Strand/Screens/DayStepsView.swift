import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - One day's steps
//
// Opened from the step count on the day page's Walking card. The headline is the same gait-model count the card
// shows, so the number tapped is the number that opens. The strap's own counter sits beside it, because the two
// count different things: the gait model counts steps inside walks, the counter counts every step the strap felt.

struct DayStepsView: View {
    let dayStart: Date

    @EnvironmentObject private var repo: Repository
    @State private var reading: WalkingDayReading?
    /// The strap's own motion-counter total for the day, when it banked one.
    @State private var strapSteps: Int?
    @State private var loaded = false

    private var walkingColor: Color { ActivityFamily.walking.color }

    var body: some View {
        ScreenScaffold(title: "Steps", subtitle: LocalizedStringKey(dayTitle), lockHorizontalScroll: true) {
            totalsCard
            if let reading, (reading.steps ?? 0) > 0 {
                hourlyCard(reading)
                walksSection(reading)
            } else if loaded {
                DataPendingNote(
                    title: reading == nil ? "No gait reading for this day yet" : "No walks counted",
                    message: reading == nil
                        ? "Steps by hour and by walk appear once the server has processed a raw motion session from your strap."
                        : "The motion the server has processed for this day has no walking in it.",
                    symbol: "shoeprints.fill")
            }
            links
            Text("Steps in walks come from the strap's raw motion, read every 5 seconds by a gait model (ElderNet). They are wrist estimates, steadiest on longer, unhurried walks.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NoopMetrics.space1)
        }
        .task(id: dayStart) { await load() }
    }

    private var dayTitle: String {
        let today = Repository.logicalDayStart(Date())
        if Calendar.current.isDate(dayStart, inSameDayAs: today) { return String(localized: "Today") }
        if Calendar.current.isDate(dayStart, inSameDayAs: today.addingTimeInterval(-86_400)) {
            return String(localized: "Yesterday")
        }
        return dayStart.formatted(.dateTime.weekday(.wide).month().day())
    }

    // MARK: Totals

    private var totalsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "shoeprints.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(walkingColor)
                Text("Steps in walks")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 8)
                if !loaded { ProgressView().controlSize(.small) }
            }
            if let steps = reading?.steps {
                Text(Int(steps.rounded()).formatted())
                    .font(StrandFont.number(44, weight: .bold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                    .accessibilityLabel(Text("\(Int(steps.rounded())) steps in walks"))
            } else {
                Text(loaded ? "No count" : "Reading your steps…")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            if let reading, !reading.isEmpty {
                FlowLayout(spacing: 6) {
                    chip("Walking", StretchFormat.duration(reading.walkingSeconds))
                    if !reading.bouts.isEmpty { chip("Walks", "\(reading.bouts.count)") }
                    if let c = reading.cadenceSpm { chip("Cadence", "\(Int(c.rounded())) steps/min") }
                }
            }
            if let strapSteps {
                Divider().overlay(StrandPalette.hairline)
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Strap's step counter")
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Every step the strap felt, including ones outside walks, so it rarely matches the count above.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Text(strapSteps.formatted())
                        .font(StrandFont.number(20))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 20))
    }

    private func chip(_ label: LocalizedStringKey, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(walkingColor.opacity(0.12)))
    }

    // MARK: By hour

    private func hourDate(_ hour: Int) -> Date {
        Calendar.current.date(byAdding: .hour, value: hour, to: dayStart) ?? dayStart.addingTimeInterval(Double(hour) * 3_600)
    }

    private func hourlyCard(_ r: WalkingDayReading) -> some View {
        let hours = Array(r.hourlySteps.enumerated())
        let peak = hours.max { $0.element < $1.element }
        return VStack(alignment: .leading, spacing: 10) {
            Text("Steps by hour")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            if let peak, peak.element >= 1 {
                Text("Most at \(hourDate(peak.offset).formatted(.dateTime.hour())), with \(Int(peak.element.rounded()).formatted()) steps.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Chart(hours, id: \.offset) { hour, steps in
                BarMark(x: .value("Hour", hour), y: .value("Steps", steps))
                    .foregroundStyle(walkingColor.opacity(hour == peak?.offset ? 1.0 : 0.6))
                    .cornerRadius(2)
            }
            .chartXScale(domain: -0.5...(Double(max(24, r.hourlySteps.count)) - 0.5))
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisValueLabel {
                        if let h = value.as(Int.self) { Text(hourDate(h).formatted(.dateTime.hour())) }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 150)
            .accessibilityLabel(Text("Steps in each hour of the day"))
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 20))
    }

    // MARK: By walk

    @ViewBuilder
    private func walksSection(_ r: WalkingDayReading) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            DaySectionHeader(title: "Biggest walks") { EmptyView() }
            if r.bouts.isEmpty {
                Text("These steps came in moments shorter than a minute, so no single walk is listed.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .padding(.horizontal, NoopMetrics.space1)
            } else {
                ForEach(r.bouts.sorted { $0.steps > $1.steps }.prefix(8)) { bout in
                    walkRow(bout)
                }
            }
        }
    }

    private func walkRow(_ bout: WalkingDayReading.Bout) -> some View {
        let from = Date(timeIntervalSince1970: TimeInterval(bout.start))
        let to = Date(timeIntervalSince1970: TimeInterval(bout.end))
        let brisk = (bout.cadenceSpm ?? 0) >= WalkingDayReading.briskCadenceSpm
        return HStack(spacing: 12) {
            Image(systemName: brisk ? "figure.walk.motion" : "figure.walk")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(walkingColor)
                .frame(width: 44, height: 44)
                .background(Circle().fill(walkingColor.opacity(0.16)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(StretchFormat.clock(from)) – \(StretchFormat.clock(to))")
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                Text(walkDetail(bout, brisk: brisk))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 1) {
                Text(Int(bout.steps.rounded()).formatted())
                    .font(StrandFont.number(18))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                Text("steps")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 16))
        .accessibilityElement(children: .combine)
    }

    private func walkDetail(_ bout: WalkingDayReading.Bout, brisk: Bool) -> String {
        var parts = [StretchFormat.duration(bout.seconds)]
        if let c = bout.cadenceSpm { parts.append(String(localized: "\(Int(c.rounded())) steps/min")) }
        if brisk { parts.append(String(localized: "Brisk")) }
        return parts.joined(separator: " · ")
    }

    // MARK: Links

    private var links: some View {
        VStack(spacing: 10) {
            NavigationLink {
                WalkingDetailScreen(day: GaitDayLoader.dayString(dayStart))
            } label: {
                linkRow(symbol: "figure.walk", title: "How you walked",
                        detail: "Pace, cadence mix and gait for this day.")
            }
            .buttonStyle(.plain)
            if let metric = MetricCatalog.todayStepsMetric(hasMeasuredSteps: strapSteps != nil) {
                NavigationLink(value: TabRoute.metricSourced(key: metric.key, source: metric.source)) {
                    linkRow(symbol: "chart.bar.xaxis", title: "Steps over time",
                            detail: "Your daily step count across weeks and months.")
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func linkRow(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(walkingColor)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 18))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    // MARK: Load

    private func load() async {
        async let gait = GaitDayLoader.load(dayStart: dayStart)
        let day = GaitDayLoader.dayString(dayStart)
        let daily = await repo.dailyMetrics(fromDay: day, toDay: day)
        let gaitDay = await gait
        guard !Task.isCancelled else { return }
        strapSteps = daily.first { $0.day == day }?.steps
        reading = gaitDay.map { WalkingDayReading(days: $0.columns, from: $0.from, to: $0.to) }
        loaded = true
    }
}

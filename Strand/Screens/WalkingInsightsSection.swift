import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

/// The Steps page's reading of HOW the steps were walked, from the server's gait model (ElderNet) on the strap's
/// raw motion: walking time, pace, cadence mix, when in the day, and each walk. One day at a time, starting on the
/// latest day the page shows; the arrows step through the days around it.
struct WalkingInsightsSection: View {
    /// The local calendar day ("yyyy-MM-dd") to open on.
    let day: String

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceRaw = ""
    @State private var offset = 0
    @State private var reading: WalkingDayReading?
    @State private var loaded = false

    private var system: UnitSystem {
        UnitPrefs.resolveDistance(system: UnitSystem(rawValue: unitSystemRaw) ?? .metric, override: distanceRaw)
    }

    private var dayStart: Date? {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let base = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
        else { return nil }
        return Calendar.current.date(byAdding: .day, value: offset, to: base)
    }

    private var dayEnd: Date? {
        dayStart.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if let reading, !reading.isEmpty {
                headline(reading)
                pace(reading)
                cadenceMix(reading)
                if reading.hourlySeconds.contains(where: { $0 > 0 }) { hours(reading) }
                quality(reading)
                if !reading.bouts.isEmpty { walks(reading) }
                Text("Read every 5 seconds from the strap's raw motion by a gait model (ElderNet). Steps, speed and stride are wrist estimates; they are steadiest on longer, unhurried walks.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if loaded {
                Text(reading == nil
                     ? "No gait reading for this day. It appears once the server has processed a raw motion session from your strap."
                     : "No walking detected in the motion the server has processed for this day.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 20))
        .task(id: "\(day)|\(offset)") { await load() }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "figure.walk")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(ActivityFamily.walking.color)
            VStack(alignment: .leading, spacing: 1) {
                Text("How you walked")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let dayStart {
                    Text(dayStart.formatted(.dateTime.weekday(.wide).month().day()))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            Spacer(minLength: 8)
            if !loaded { ProgressView().controlSize(.small) }
            stepper("chevron.left", label: "Previous day", disabled: offset <= -13) { offset -= 1 }
            stepper("chevron.right", label: "Next day", disabled: offset >= 0) { offset += 1 }
        }
    }

    private func stepper(_ symbol: String, label: LocalizedStringKey, disabled: Bool,
                         action: @escaping () -> Void) -> some View {
        Button(action: { loaded = false; reading = nil; action() }) {
            Image(systemName: symbol)
                .font(StrandFont.caption.weight(.semibold))
                .frame(width: 28, height: 28)
                .background(Circle().fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
        .foregroundStyle(disabled ? StrandPalette.textTertiary : StrandPalette.textPrimary)
        .disabled(disabled)
        .accessibilityLabel(Text(label))
    }

    private func headline(_ r: WalkingDayReading) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 18) {
            stat(StretchFormat.duration(r.walkingSeconds), "walking")
            if let steps = r.steps { stat(Int(steps.rounded()).formatted(), "steps in walks") }
            if r.briskSeconds > 0 { stat(StretchFormat.duration(r.briskSeconds), "brisk") }
        }
    }

    private func stat(_ value: String, _ caption: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(StrandFont.number(20))
                .foregroundStyle(StrandPalette.textPrimary)
            Text(caption)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    /// The usual pace of a walk, against the common bands for adults' everyday walking speed.
    @ViewBuilder
    private func pace(_ r: WalkingDayReading) -> some View {
        if let typical = r.typicalSpeedMps ?? r.speedMps {
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Usual walking pace")
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(speed(typical))
                        .font(StrandFont.number(20))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(Self.paceBand(typical))
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(ActivityFamily.walking.color)
                }
                paceScale(typical)
                Text(r.typicalSpeedMps == nil
                     ? "Across every walking moment today."
                     : "The middle pace of your walks of a minute or more. Short shuffles don't pull it down.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }

    /// Where `mps` falls on a 0.4–1.8 m/s scale.
    private func paceScale(_ mps: Double) -> some View {
        let fraction = (min(1.8, max(0.4, mps)) - 0.4) / 1.4
        let gradient = LinearGradient(colors: [ActivityFamily.walking.color.opacity(0.18),
                                               ActivityFamily.walking.color.opacity(0.75)],
                                      startPoint: .leading, endPoint: .trailing)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(gradient).frame(height: 6)
                Circle().fill(StrandPalette.textPrimary)
                    .frame(width: 10, height: 10)
                    .offset(x: fraction * geo.size.width - 5)
            }
        }
        .frame(height: 10)
        .accessibilityHidden(true)
    }

    static func paceBand(_ mps: Double) -> String {
        switch mps {
        case ..<0.8: return String(localized: "Unhurried")
        case ..<1.2: return String(localized: "Typical")
        case ..<1.4: return String(localized: "Brisk")
        default: return String(localized: "Fast")
        }
    }

    /// Walking time by cadence: strolling, steady, brisk (≥ 100 steps/min, moderate intensity) and fast.
    @ViewBuilder
    private func cadenceMix(_ r: WalkingDayReading) -> some View {
        let total = r.cadenceBandSeconds.reduce(0, +)
        if total > 0 {
            let names = [String(localized: "Strolling"), String(localized: "Steady"),
                         String(localized: "Brisk"), String(localized: "Fast")]
            VStack(alignment: .leading, spacing: 6) {
                sectionTitle("Cadence mix")
                GeometryReader { geo in
                    HStack(spacing: 2) {
                        ForEach(Array(r.cadenceBandSeconds.enumerated()), id: \.offset) { i, s in
                            if s > 0 {
                                Rectangle()
                                    .fill(ActivityFamily.walking.color.opacity(0.25 + 0.25 * Double(i)))
                                    .frame(width: max(2, geo.size.width * Double(s) / Double(total) - 2))
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                }
                .frame(height: 12)
                .accessibilityHidden(true)
                FlowLayout(spacing: 6) {
                    ForEach(Array(r.cadenceBandSeconds.enumerated()), id: \.offset) { i, s in
                        if s > 0 { chip(names[i], "\(StretchFormat.duration(s)) · \(bandRange(i))") }
                    }
                }
                if let c = r.cadenceSpm {
                    Text("Average \(Int(c.rounded())) steps per minute while walking. 100 or more is moderate-intensity walking for most adults.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bandRange(_ i: Int) -> String {
        let bands = WalkingDayReading.cadenceBands
        let lo = Int(bands[i])
        return i + 1 < bands.count ? "\(lo)–\(Int(bands[i + 1]) - 1)" : "\(lo)+"
    }

    /// Walking minutes in each hour of the day.
    private func hours(_ r: WalkingDayReading) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("When you walked")
            Chart(Array(r.hourlySeconds.enumerated()), id: \.offset) { hour, seconds in
                BarMark(x: .value("Hour", hour), y: .value("Minutes", Double(seconds) / 60))
                    .foregroundStyle(ActivityFamily.walking.color.opacity(seconds > 0 ? 0.85 : 0.0))
                    .cornerRadius(2)
            }
            .chartXScale(domain: 0...max(23, r.hourlySeconds.count - 1))
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisValueLabel {
                        if let h = value.as(Int.self), let d = dayStart.flatMap({
                            Calendar.current.date(byAdding: .hour, value: h, to: $0)
                        }) {
                            Text(d.formatted(.dateTime.hour()))
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 90)
            .accessibilityLabel(Text("Walking minutes in each hour of the day"))
        }
    }

    private func quality(_ r: WalkingDayReading) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("Gait")
            FlowLayout(spacing: 6) {
                if let s = r.strideM { chip(String(localized: "Stride"), UnitFormatter.distanceFromMeters(s, system: system)) }
                if let g = r.regularity { chip(String(localized: "Step evenness"), "\(Int((g * 100).rounded()))%") }
                if let s = r.speedMps { chip(String(localized: "Average speed"), speed(s)) }
                let sustained = r.bouts.filter { $0.seconds >= 600 }.count
                if sustained > 0 { chip(String(localized: "Walks of 10+ min"), "\(sustained)") }
                if let longest = r.bouts.map(\.seconds).max() {
                    chip(String(localized: "Longest walk"), StretchFormat.duration(longest))
                }
            }
        }
    }

    /// The day's walks of a minute or more, longest first.
    private func walks(_ r: WalkingDayReading) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("Walks")
            ForEach(r.bouts.sorted { $0.seconds > $1.seconds }.prefix(6)) { bout in
                HStack(spacing: 10) {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(ActivityFamily.walking.color.opacity(
                            (bout.cadenceSpm ?? 0) >= WalkingDayReading.briskCadenceSpm ? 1.0 : 0.5))
                        .frame(width: 4, height: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(StretchFormat.clock(Date(timeIntervalSince1970: TimeInterval(bout.start))))
                            .font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text(walkDetail(bout))
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: 8)
                    Text(StretchFormat.duration(bout.seconds))
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                }
            }
        }
    }

    private func walkDetail(_ bout: WalkingDayReading.Bout) -> String {
        var parts = [String(localized: "\(Int(bout.steps.rounded())) steps")]
        if let c = bout.cadenceSpm { parts.append(String(localized: "\(Int(c.rounded())) steps/min")) }
        if let s = bout.speedMps { parts.append(speed(s)) }
        return parts.joined(separator: " · ")
    }

    private func sectionTitle(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.textSecondary)
    }

    private func chip(_ label: String, _ value: String) -> some View {
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
        .background(Capsule().fill(ActivityFamily.walking.color.opacity(0.12)))
    }

    private func speed(_ mps: Double) -> String {
        system == .imperial
            ? String(format: "%.1f mph", mps * 2.236_94)
            : String(format: "%.1f km/h", mps * 3.6)
    }

    // MARK: Load

    private func load() async {
        defer { loaded = true }
        guard let dayStart, let dayEnd,
              let identity = CloudPushIdentityStore.current(),
              let repository = CloudPushRuntime.shared.scoreRepository(),
              let device = await IntradaySeriesStore.shared.readCandidates.first else { return }
        let from = Int(dayStart.timeIntervalSince1970), to = Int(dayEnd.timeIntervalSince1970)
        guard let columns = try? await GaitWindowsCache.shared.columns(
            utcDays: ActivityEncoderWindowStore.utcDays(from: from, to: to), deviceId: device,
            ownerId: identity.ownerId, repository: repository),
              !columns.isEmpty, !Task.isCancelled else { return }
        reading = WalkingDayReading(days: columns, from: from, to: to)
    }
}

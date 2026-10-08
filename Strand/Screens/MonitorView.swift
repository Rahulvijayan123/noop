import SwiftUI
import StrandDesign

// MARK: - Model
//
// Everything the Monitor tab draws comes from a `MonitorSnapshot`. The sample below only fills the
// screen until the backend lands: build a snapshot from real data and pass it to `MonitorView(snapshot:)`.
// All strings that depend on units or locale (`valueText`, `usualText`) arrive pre-formatted, so the
// view never guesses at them. Models are `Codable` so a backend payload can decode straight into them.

enum MonitorTone: String, Codable, Hashable {
    case heart, hrv, respiratory, sleep, alert, notice

    var color: Color {
        switch self {
        case .heart, .alert: return StrandPalette.metricRose
        case .hrv, .notice: return StrandPalette.metricPurple
        case .respiratory: return Color(red: 0.42, green: 0.74, blue: 1.0)
        case .sleep: return Color(red: 0.78, green: 0.70, blue: 1.0)
        }
    }
}

struct MonitorBaseline: Identifiable, Hashable, Codable {
    /// Also the `MetricCatalog` key the card opens (`rhr`, `hrv`, `resp_rate`, `sleep_total_min`).
    let id: String
    var title: String
    var symbol: String
    var tone: MonitorTone
    var valueText: String
    var unit: String
    var usualLow: Double
    var usualHigh: Double
    var usualText: String
    /// Daily values over the baseline window, oldest first.
    var series: [Double]
}

struct LegacyMonitorWatchdogEpisode: Identifiable, Hashable, Codable {
    let id: String
    var start: Date
    var label: String
    var duration: TimeInterval
    var tone: MonitorTone
}

enum MonitoringStatus: String, Codable, Hashable {
    case good, fair, poor

    var label: String {
        switch self {
        case .good: return String(localized: "Good")
        case .fair: return String(localized: "Fair")
        case .poor: return String(localized: "Poor")
        }
    }

    var color: Color {
        switch self {
        case .good: return Color(red: 0.25, green: 0.86, blue: 0.5)
        case .fair: return StrandPalette.metricAmber
        case .poor: return StrandPalette.statusCritical
        }
    }
}

struct MonitoringQuality: Hashable, Codable {
    /// 0...1 share of the day the strap was monitoring.
    var coverage: Double
    /// 0...1 share of monitored time with valid wear.
    var validWear: Double
    var status: MonitoringStatus
}

struct MonitorSnapshot: Hashable, Codable {
    var baselines: [MonitorBaseline]
    var episodes: [LegacyMonitorWatchdogEpisode]
    var quality: MonitoringQuality
}

// MARK: - Sample data (DEBUG only: fabricated episodes and baselines must not ship)

#if DEBUG
extension MonitorSnapshot {
    static var sample: MonitorSnapshot {
        func series(_ base: Double, _ amp: Double, _ seed: Double) -> [Double] {
            var values: [Double] = []
            for day in 0..<28 {
                let d = Double(day)
                let slow: Double = amp * sin(d * 0.7 + seed)
                let fast: Double = amp * 0.5 * sin(d * 1.9 + seed * 2)
                values.append(base + slow + fast)
            }
            return values
        }
        func when(daysAgo: Int, _ hour: Int, _ minute: Int) -> Date {
            let cal = Calendar.current
            let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date())) ?? Date()
            return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
        }
        return MonitorSnapshot(
            baselines: [
                MonitorBaseline(id: "rhr", title: "Resting heart rate", symbol: "heart.fill", tone: .heart,
                                valueText: "58", unit: "bpm", usualLow: 50, usualHigh: 66,
                                usualText: "Usual 50–66", series: series(58, 5, 0.3)),
                MonitorBaseline(id: "hrv", title: "HRV", symbol: "waveform.path.ecg", tone: .hrv,
                                valueText: "32", unit: "ms", usualLow: 20, usualHigh: 65,
                                usualText: "Usual 20–65", series: series(38, 9, 1.1)),
                MonitorBaseline(id: "resp_rate", title: "Respiratory rate", symbol: "lungs.fill", tone: .respiratory,
                                valueText: "14", unit: "br/min", usualLow: 12, usualHigh: 18,
                                usualText: "Usual 12–18", series: series(14.5, 1.4, 2.0)),
                MonitorBaseline(id: "sleep_total_min", title: "Sleep duration", symbol: "moon.fill", tone: .sleep,
                                valueText: "8h 19m", unit: "", usualLow: 7, usualHigh: 9,
                                usualText: "Usual 7–9 h", series: series(8, 0.8, 2.8)),
            ],
            episodes: [
                LegacyMonitorWatchdogEpisode(id: "ep-1", start: when(daysAgo: 2, 13, 32), label: "Elevated resting HR",
                                duration: 12 * 60, tone: .alert),
                LegacyMonitorWatchdogEpisode(id: "ep-2", start: when(daysAgo: 4, 10, 14), label: "Low HRV",
                                duration: 18 * 60, tone: .alert),
                LegacyMonitorWatchdogEpisode(id: "ep-3", start: when(daysAgo: 6, 15, 48), label: "Higher than usual HR",
                                duration: 25 * 60, tone: .notice),
                LegacyMonitorWatchdogEpisode(id: "ep-4", start: when(daysAgo: 8, 22, 6), label: "Elevated respiratory rate",
                                duration: 9 * 60, tone: .notice),
                LegacyMonitorWatchdogEpisode(id: "ep-5", start: when(daysAgo: 11, 9, 41), label: "Low HRV",
                                duration: 32 * 60, tone: .alert),
                LegacyMonitorWatchdogEpisode(id: "ep-6", start: when(daysAgo: 14, 17, 20), label: "Elevated resting HR",
                                duration: 15 * 60, tone: .alert),
                LegacyMonitorWatchdogEpisode(id: "ep-7", start: when(daysAgo: 19, 12, 3), label: "Higher than usual HR",
                                duration: 21 * 60, tone: .notice),
                LegacyMonitorWatchdogEpisode(id: "ep-8", start: when(daysAgo: 24, 3, 55), label: "Low HRV",
                                duration: 47 * 60, tone: .alert),
            ],
            quality: MonitoringQuality(coverage: 0.96, validWear: 0.98, status: .good))
    }
}
#endif

// MARK: - Watchdog page

struct LegacyMonitorWatchdogEpisodeRow: View {
    let episode: LegacyMonitorWatchdogEpisode
    var showsChevron = false

    var body: some View {
        HStack(spacing: 14) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(episode.tone.color)
                .frame(width: 3, height: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(episode.start.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                    .font(StrandFont.subhead.weight(.semibold))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(episode.label)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            Spacer(minLength: 8)
            Text(naraDurationText(episode.duration))
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
            if showsChevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
    }
}

/// Every watchdog episode, newest first, with the totals across them.
struct LegacyMonitorWatchdogView: View {
    var snapshot: MonitorSnapshot

    private var episodes: [LegacyMonitorWatchdogEpisode] { snapshot.episodes.sorted { $0.start > $1.start } }

    var body: some View {
        ScreenScaffold(title: "Watchdog", subtitle: "Episodes in the last 30 days") {
            VStack(alignment: .leading, spacing: 26) {
                HStack(spacing: 10) {
                    stat("Episodes", "\(episodes.count)")
                    stat("Total time", naraDurationText(episodes.reduce(0) { $0 + $1.duration }))
                    stat("Longest", naraDurationText(episodes.map(\.duration).max() ?? 0))
                }
                VStack(spacing: 0) {
                    ForEach(Array(episodes.enumerated()), id: \.element.id) { index, episode in
                        if index > 0 { Divider().overlay(StrandPalette.hairline) }
                        LegacyMonitorWatchdogEpisodeRow(episode: episode)
                    }
                    if episodes.isEmpty {
                        Text("No episodes")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(18)
                    }
                }
                .naraCard()
            }
        }
    }

    private func stat(_ title: LocalizedStringKey, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textSecondary)
            Text(value)
                .font(StrandFont.rounded(22))
                .foregroundStyle(StrandPalette.textPrimary)
                .lineLimit(1).minimumScaleFactor(0.7)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .naraCard(radius: 16)
    }
}

// MARK: - Pieces

/// 28-day trend with the "usual" range as a shaded band between dashed edges.
private struct BaselineSparkline: View {
    let series: [Double]
    let low: Double
    let high: Double
    let tint: Color

    var body: some View {
        Canvas { context, size in
            guard series.count >= 2, let sMin = series.min(), let sMax = series.max() else { return }
            let lo = min(sMin, low), hi = max(sMax, high)
            let pad = max((hi - lo) * 0.12, 0.001)
            let yMin = lo - pad, yMax = hi + pad
            func y(_ v: Double) -> CGFloat { size.height * (1 - CGFloat((v - yMin) / (yMax - yMin))) }

            let top = y(high), bottom = y(low)
            context.fill(Path(CGRect(x: 0, y: top, width: size.width, height: bottom - top)),
                         with: .color(tint.opacity(0.14)))
            var edges = Path()
            for edge in [top, bottom] {
                edges.move(to: CGPoint(x: 0, y: edge))
                edges.addLine(to: CGPoint(x: size.width, y: edge))
            }
            context.stroke(edges, with: .color(tint.opacity(0.55)),
                           style: StrokeStyle(lineWidth: 0.8, dash: [3, 3]))

            let points = series.enumerated().map {
                CGPoint(x: size.width * CGFloat($0.offset) / CGFloat(series.count - 1), y: y($0.element))
            }
            context.stroke(naraSmoothPath(points), with: .color(tint),
                           style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

private struct CoverageRing: View {
    let fraction: Double
    private let tint = Color(red: 0.25, green: 0.85, blue: 0.78)

    var body: some View {
        ZStack {
            Circle().stroke(StrandPalette.hairline, lineWidth: 6)
            Circle()
                .trim(from: 0, to: max(0, min(1, fraction)))
                .stroke(tint, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(Int((fraction * 100).rounded()))%")
                .font(StrandFont.rounded(16))
                .foregroundStyle(StrandPalette.textPrimary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Coverage \(Int((fraction * 100).rounded())) percent"))
    }
}

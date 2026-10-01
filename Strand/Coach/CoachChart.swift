import Foundation
import WhoopStore

/// A metric series pulled from the synced daily rows. It is never drawn directly: `CoachVisualEvidence.describe`
/// turns it into plain text for the model, and the visual pipeline designs the chart from that text.
struct CoachChart: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        /// "yyyy-MM-dd".
        let dateISO: String
        let value: Double
    }

    let title: String
    let unit: String
    let points: [Point]
}

/// Everything `prepare_chart` can fetch, each read straight off the synced daily rows.
enum CoachChartMetric: String, CaseIterable, Sendable {
    case charge, effort, sleepHours, hrv, rhr, spo2, respiration, skinTemp, steps, activeCalories

    var title: String {
        switch self {
        case .charge: return "Charge"
        case .effort: return "Effort"
        case .sleepHours: return "Sleep duration"
        case .hrv: return "HRV"
        case .rhr: return "Resting heart rate"
        case .spo2: return "Blood oxygen"
        case .respiration: return "Respiration"
        case .skinTemp: return "Skin temperature deviation"
        case .steps: return "Steps"
        case .activeCalories: return "Active calories"
        }
    }

    var unit: String {
        switch self {
        case .charge: return "%"
        case .effort: return "0–100"
        case .sleepHours: return "hrs"
        case .hrv: return "ms"
        case .rhr: return "bpm"
        case .spo2: return "%"
        case .respiration: return "br/min"
        case .skinTemp: return "°C"
        case .steps: return "steps"
        case .activeCalories: return "kcal"
        }
    }

    func value(_ d: DailyMetric) -> Double? {
        switch self {
        case .charge: return d.recovery
        case .effort: return d.strain
        case .sleepHours: return d.totalSleepMin.map { $0 / 60 }
        case .hrv: return d.avgHrv
        case .rhr: return d.restingHr.map(Double.init)
        case .spo2: return d.spo2Pct
        case .respiration: return d.respRateBpm
        case .skinTemp: return d.skinTempDevC
        case .steps: return d.steps.map(Double.init)
        case .activeCalories: return d.activeKcalEst
        }
    }

    /// Days with no measurement are skipped rather than plotted as zero, matching how the rest of the
    /// app treats a missing value.
    func chart(from days: [DailyMetric], last n: Int) -> CoachChart {
        let points = days.suffix(n).compactMap { d -> CoachChart.Point? in
            guard let v = value(d), v.isFinite else { return nil }
            return CoachChart.Point(dateISO: d.day, value: v)
        }
        return CoachChart(title: title, unit: unit, points: points)
    }
}

import Foundation
import StrandAnalytics

/// The coach's view of two server documents the phone already draws: the measurement context behind a metric
/// (the Measurement context sheet) and a night's sleep details (the Sleep details section). The text comes from
/// the same view models as those screens, so the coach can only quote what the user can find there.
enum CoachServerContext {

    static let metricNames = "hrv|rhr|heart_rate|respiration|skin_temp|spo2"

    static func metric(named raw: String) -> PhysiologyContext.MetricKind? {
        switch raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: " ", with: "_") {
        case "hrv", "hrv_rmssd", "rmssd": return .hrvRmssd
        case "rhr", "resting_hr", "resting_heart_rate": return .restingHeartRate
        case "hr", "heart_rate": return .heartRate
        case "respiration", "resp_rate", "respiratory_rate", "breathing": return .respiratoryRate
        case "skin_temp", "skin_temperature", "temperature": return .skinTemperature
        case "spo2", "oxygen", "spo2_candidate": return .spo2Candidate
        default: return nil
        }
    }

    /// `YYYY-MM-DD`, or nil for anything else.
    static func day(_ raw: Any?) -> String? {
        guard let s = (raw as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              s.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else { return nil }
        return s
    }

    // MARK: Measurement context

    static func describe(state: PhysiologyContextStore.State?, metric: PhysiologyContext.MetricKind,
                         day: String) -> String {
        func model(_ d: PhysiologyContextDay, stale: Bool) -> String {
            describe(MeasurementContextDetailModel.build(day: d, metric: metric, isStale: stale), day: day)
        }
        switch state {
        case .available(let d)?:
            return model(d, stale: false)
        case .stale(let d)?:
            return model(d, stale: true)
        case .pending(let d, .computing)?:
            let lead = "The server is still preparing the context for \(day)."
            return d.map { lead + " The previous version follows.\n" + model($0, stale: true) } ?? lead
        case .pending(_, .deviceRegistration)?:
            return "This strap is not registered with the account yet, so the server has no measurement context for it."
        case .unavailable(let reason)?:
            switch reason {
            case .cloudOff: return "Measurement context comes from cloud scoring, which is off on this install."
            case .signedOut: return "Measurement context needs the user to be signed in."
            case .accountNotReady: return "The account is still connecting; measurement context is not readable yet."
            case .unsupportedServer: return "This server does not provide measurement context."
            case .noData: return "The server has no measurement context for \(day)."
            case .processingFailed: return "The server could not build the measurement context for \(day); no update is on its way."
            }
        case .failed(let cached, _)?:
            guard let cached else { return "Could not load the measurement context right now." }
            return "(Could not reach the server; this is the last saved context.)\n" + model(cached, stale: false)
        case .loading?, nil:
            return "Could not load the measurement context right now."
        }
    }

    /// The sheet's sections as text. The person's own exposure entries and the diagnostics are left out.
    static func describe(_ m: MeasurementContextDetailModel, day: String) -> String {
        var lines = ["MEASUREMENT CONTEXT (\(day)): \(m.title)"]
        if let s = m.subtitle { lines.append(s) }
        if let b = m.banner { lines.append("NOTE: " + b) }
        if !m.badges.isEmpty { lines.append("Status: " + m.badges.map(\.text).joined(separator: " · ")) }
        for section in m.sections {
            let rows = section.rows.filter { !$0.id.hasPrefix("exposure-event-") }
            guard !rows.isEmpty || section.footnote != nil else { continue }
            lines.append(section.title + ":")
            for r in rows {
                lines.append("  • \(r.title): \(r.value)" + (r.note.map { " (\($0))" } ?? ""))
            }
            if let f = section.footnote { lines.append("  " + f) }
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Sleep details

    static func describe(_ m: SleepFeatureDisplayModel, day: String) -> String {
        guard !m.chapters.isEmpty else { return "No sleep details for the night ending \(day)." }
        var lines = ["SLEEP DETAILS (night ending \(day)); a dash means not available, never zero:"]
        lines.append(m.headline.map { "\($0.label) \($0.value)" + ($0.unit.map { " \($0)" } ?? "") }
            .joined(separator: " · "))
        for c in m.chapters {
            lines.append("\(c.title): \(c.line)")
            for r in m.rows(for: c.chapter) {
                lines.append("  • \(r.label): \(r.value)" + (r.note.map { " (\($0))" } ?? ""))
            }
        }
        return lines.joined(separator: "\n")
    }
}

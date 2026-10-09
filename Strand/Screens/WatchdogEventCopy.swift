import SwiftUI
import StrandDesign
import StrandAnalytics

/// Plain-language copy for ledger rows. Kept apart so rows and the detail sheet say the same thing.
enum WatchdogEventCopy {
    static func severityTitle(_ raw: String) -> String {
        switch raw {
        case "severe": return "Strong alert"
        case "active": return "Alert"
        default: return "Watching"
        }
    }

    static func tone(_ raw: String) -> Color {
        switch raw {
        case "severe", "active": return StrandPalette.statusCritical
        default: return StrandPalette.statusWarning
        }
    }

    static func vitalName(_ name: String) -> String {
        switch name {
        case "HR": return "Heart rate"
        case "RHR": return "Resting HR"
        case "HRV": return "HRV"
        case "Temp": return "Temp"
        case "Resp": return "Breathing"
        case "SpO2": return "SpO₂"
        default: return name
        }
    }

    private static func isTemp(_ signal: WatchdogSignalEvidence) -> Bool { signal.name == "Temp" }

    static func value(_ v: Double?, signal: WatchdogSignalEvidence, fahrenheit: Bool) -> String {
        guard let v, v.isFinite else { return "–" }
        if isTemp(signal) {
            let shown = fahrenheit ? UnitFormatter.celsiusToFahrenheit(v) : v
            return String(format: "%.1f %@", shown, fahrenheit ? "°F" : "°C")
        }
        let unit = signal.unit.isEmpty ? "" : " \(signal.unit)"
        return String(format: "%.0f", v) + unit
    }

    private static func delta(_ signal: WatchdogSignalEvidence, fahrenheit: Bool) -> String? {
        guard let obs = signal.observed, let exp = signal.reconstructed ?? signal.usual,
              obs.isFinite, exp.isFinite else { return nil }
        var d = obs - exp
        if isTemp(signal) {
            if fahrenheit { d *= 9.0 / 5.0 }
            return String(format: "%+.1f", d)
        }
        return String(format: "%+.0f", d)
    }

    static func expectedLine(_ signal: WatchdogSignalEvidence, fahrenheit: Bool) -> String {
        let expected = signal.reconstructed ?? signal.usual
        guard expected != nil else { return "No expected value" }
        let base = "Expected \(value(expected, signal: signal, fahrenheit: fahrenheit))"
        guard let d = delta(signal, fahrenheit: fahrenheit) else { return base }
        return "\(base) (\(d))"
    }

    /// One line for the list: the vital that drove the event most, and how far it was from expected.
    static func reasonLine(_ row: WatchdogEpisodeLedgerRow, fahrenheit: Bool) -> String {
        let hot = Set(row.contributing ?? [])
        let lead = (row.signals ?? [])
            .filter { hot.contains($0.name) && $0.observed != nil }
            .max { $0.energy < $1.energy }
        if let lead {
            let now = value(lead.observed, signal: lead, fahrenheit: fahrenheit)
            let expected = value(lead.reconstructed ?? lead.usual, signal: lead, fahrenheit: fahrenheit)
            var line = "\(vitalName(lead.name)) \(now), expected \(expected)"
            if hot.count > 1 { line += ", plus \(hot.count - 1) more" }
            return line
        }
        if row.safety { return "Past a safety limit." }
        if row.personalOff { return "Several readings away from your usual together." }
        return row.headline ?? "Recorded before reasons were saved."
    }

    static func durationLine(_ row: WatchdogEpisodeLedgerRow, now: Int = Int(Date().timeIntervalSince1970)) -> String {
        let end = row.closedUnix ?? row.lastUnix
        let minutes = max(1, (end - row.openedUnix) / 60)
        let length = minutes < 60 ? "\(minutes) min" : String(format: "%d h %02d min", minutes / 60, minutes % 60)
        if row.closedUnix == nil, now - row.lastUnix < 15 * 60 { return "\(length) so far" }
        return length
    }

    private static func formatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate(format)
        return f
    }

    static func clock(_ unix: Int) -> String {
        formatter("jmm").string(from: Date(timeIntervalSince1970: TimeInterval(unix)))
    }

    static func shortWhen(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let cal = Calendar.current
        if cal.isDateInToday(date) { return clock(unix) }
        if cal.isDateInYesterday(date) { return "Yesterday \(clock(unix))" }
        return formatter("EEEdMMM").string(from: date)
    }

    static func longWhen(_ unix: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unix))
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today, \(clock(unix))" }
        if cal.isDateInYesterday(date) { return "Yesterday, \(clock(unix))" }
        return formatter("EEEEdMMMMjmm").string(from: date)
    }

    static func activity(_ raw: String?) -> String? {
        switch raw {
        case "still": return "Still"
        case "stand": return "Standing"
        case "walk": return "Walking"
        case "run": return "Running"
        case "cycleLike": return "Cycling"
        case "resistance": return "Lifting"
        case "artifact": return "Sensor noise"
        case "exercise_session": return "Exercise session"
        case "recovery": return "Recovering from exercise"
        default: return nil
        }
    }

    /// What an exercise-session reading was compared with (rule exercise-session-1). Nil outside a session.
    static func exerciseComparison(_ e: WatchdogExerciseSnapshot?) -> String? {
        guard let e, e.phase != "none" else { return nil }
        let session = e.phase == "session"
        let reference = session ? e.sessionReference : e.recoveryReference
        let what = session ? "your own workouts" : "your own recovery after workouts"
        return reference == "established" ? "Compared with \(what)"
            : "Still learning \(what); only safety limits apply"
    }

    /// One plain sentence for the live card while a session or its recovery is in view.
    static func exerciseLine(_ e: WatchdogExerciseSnapshot?) -> String? {
        guard let e, e.phase != "none", let comparison = exerciseComparison(e) else { return nil }
        let head = e.phase == "session" ? "Exercise session" : "Recovering from exercise"
        var line = "\(head). \(comparison)."
        if let routine = e.routine { line += " Matches your usual \(routine.split(separator: " ").first ?? "") session." }
        return line
    }

    static func eventLabel(_ raw: String?) -> String? {
        guard let raw, let label = WatchdogEventLabel(rawValue: raw) else { return nil }
        switch label {
        case .wristOff: return "Strap off"
        case .gap: return "Gap in readings"
        case .artifactSpike: return "Sensor spike"
        case .workoutWalk: return "Walking workout"
        case .workoutRun: return "Running workout"
        case .workoutCycle: return "Cycling workout"
        case .workoutLift: return "Lifting workout"
        case .postWorkout: return "Just after a workout"
        case .normalSleep: return "Asleep"
        case .normalStillAwake: return "Still and awake"
        case .forecastDriftOnly: return "Drifting from the forecast"
        case .abnormalStillTachycardia: return "High heart rate while still"
        case .abnormalMultiDirection: return "Several vitals moving together"
        case .abnormalSpo2Still: return "Low SpO₂ while still"
        case .safetyBound: return "Past a safety limit"
        case .mixedRejected: return "Mixed signals"
        }
    }

    static func delivery(_ raw: String) -> String {
        switch raw {
        case "sent": return "Sent"
        case "denied": return "Blocked, notifications are off"
        case "failed": return "Did not send"
        case "queued": return "Waiting to send"
        default: return "Not sent"
        }
    }

    static func noteLines(_ a: WatchdogEpisodeAnnotation) -> [String] {
        var out: [String] = []
        if let s = a.symptoms, !s.isEmpty { out.append("Symptoms: \(s)") }
        if let e = a.exertion { out.append("Exertion: \(MonitorLabels.exertion(e))") }
        if let s = a.stress { out.append("Stress: \(MonitorLabels.stress(s))") }
        if let i = a.illness { out.append(i == .feltOff ? "Felt off" : "Not ill") }
        if let s = a.sensor {
            switch s {
            case .loose: out.append("Strap was loose")
            case .charging: out.append("Strap was charging")
            case .justOn: out.append("Strap had just gone on")
            case .other: out.append("Something else with the strap")
            }
        }
        if let n = a.note, !n.isEmpty { out.append(n) }
        return out
    }
}

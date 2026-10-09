import Foundation
import StrandDesign
import StrandAnalytics

// MARK: - MonitorLabels
//
// Pure display mappings for the Monitor area (Watchdog, Baseline, alerts). The engines and the stores
// produce their own words and units (caps verdicts such as "IN RANGE", "/min", raw enum values such as
// "rest"); this is where the screens turn them into the app's vocabulary: sentence case, the design
// system's units, the user's temperature unit. Nothing here computes or changes a value the engines use.
// Covered by MonitorLabelsTests.

enum MonitorLabels {

    // MARK: Units and values

    /// The unit the screens show for a Layer 1 plan unit: "/min" reads "rpm", temperature follows the
    /// user's unit, everything else is unchanged.
    static func unit(_ planUnit: String, fahrenheit: Bool) -> String {
        switch planUnit {
        case "/min": return "rpm"
        case "°C": return fahrenheit ? "°F" : "°C"
        default: return planUnit
        }
    }

    /// A native value (Layer 1 stores temperature in °C) in the unit the screens show.
    static func displayValue(_ native: Double, planUnit: String, fahrenheit: Bool) -> Double {
        planUnit == "°C" && fahrenheit ? UnitFormatter.celsiusToFahrenheit(native) : native
    }

    /// Decimal places for a displayed unit: whole beats, milliseconds, percent and steps; one place for
    /// breathing and temperature, whose usual ranges are narrow.
    static func decimals(forUnit unit: String) -> Int {
        switch unit {
        case "bpm", "ms", "%", "steps": return 0
        default: return 1
        }
    }

    /// The number alone ("62", "14.2", "—" for nil or not finite).
    static func number(_ value: Double?, unit: String) -> String {
        guard let value, value.isFinite else { return "—" }
        let places = decimals(forUnit: unit)
        return places == 0 ? String(format: "%.0f", value) : String(format: "%.\(places)f", value)
    }

    /// A range with one unit: "44–67 bpm".
    static func range(_ low: Double, _ high: Double, unit: String) -> String {
        "\(number(low, unit: unit))–\(number(high, unit: unit)) \(unit)"
    }

    /// Splits a pre-formatted value such as "64 bpm" or "33.1 °F" into its number and unit, so the unit can
    /// be drawn in `textSecondary` beside the number. "–" (the engines' missing value) is nil.
    static func splitValue(_ formatted: String) -> (value: String?, unit: String?) {
        let trimmed = formatted.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == "–" || trimmed == "—" { return (nil, nil) }
        guard let space = trimmed.firstIndex(of: " ") else { return (trimmed, nil) }
        let value = String(trimmed[..<space])
        let unit = String(trimmed[trimmed.index(after: space)...]).trimmingCharacters(in: .whitespaces)
        return (value, unit.isEmpty ? nil : unit)
    }

    // MARK: Words

    /// Layer 1 verdicts (`BaselineStore.shortVerdict` / `longVerdict`) in sentence case.
    static func verdict(_ caps: String) -> String {
        switch caps {
        case "IN RANGE": return "In range"
        case "OFF": return "Off usual"
        case "NOT RECENT": return "Not recent"
        case "NOT ENOUGH NIGHTS": return "Not enough nights"
        case "BUILDING": return "Building"
        default: return caps.prefix(1).uppercased() + caps.dropFirst().lowercased()
        }
    }

    /// The tone of a verdict's word: green in range, amber off usual, quiet otherwise.
    static func verdictTone(_ caps: String) -> StrandTone {
        switch caps {
        case "IN RANGE": return .positive
        case "OFF": return .warning
        default: return .neutral
        }
    }

    /// Confidence in a usual or a band from its trust percentage, on the cut-offs the screens have always
    /// coloured it by (70 and 40). Nil when there is no trust yet.
    static func confidence(_ pct: Int?) -> String? {
        guard let pct, pct > 0 else { return nil }
        if pct >= 70 { return "High" }
        if pct >= 40 { return "Medium" }
        return "Low"
    }

    /// A Watchdog vital's call (`WatchdogLiveSnapshot.MetricRow.status`) in the app's vocabulary. "Off"
    /// says what it is off from, and "Live" (a reading shown without a call because the band is still
    /// being learned) reads as "Learning", the word the Baseline rows use for the same state.
    static func watchdogStatus(_ status: String) -> String {
        switch status {
        case "Off": return "Off usual"
        case "Live": return "Learning"
        default: return status
        }
    }

    /// The Baseline vitals' state words.
    static func vitalState(_ state: BaselineVitalsCheck.Vital.State) -> String {
        switch state {
        case .inRange: return "In range"
        case .off: return "Off usual"
        case .learning: return "Learning"
        case .noReading: return "No reading"
        }
    }

    static func vitalTone(_ state: BaselineVitalsCheck.Vital.State) -> StrandTone {
        switch state {
        case .inRange: return .positive
        case .off: return .warning
        case .learning, .noReading: return .neutral
        }
    }

    /// The wearer's note choices, which the engine stores as lowercase raw values.
    static func exertion(_ value: WatchdogAnnotationExertion) -> String {
        switch value {
        case .rest: return "Rest"
        case .light: return "Light"
        case .hard: return "Hard"
        }
    }

    static func stress(_ value: WatchdogAnnotationStress) -> String {
        switch value {
        case .low: return "Low"
        case .high: return "High"
        }
    }

    static func sensor(_ value: WatchdogAnnotationSensor) -> String {
        switch value {
        case .loose: return "Loose"
        case .charging: return "Charging"
        case .justOn: return "Just on"
        case .other: return "Other"
        }
    }

    static func illness(_ value: WatchdogAnnotationIllness) -> String {
        value == .feltOff ? "Felt off" : "Not ill"
    }

    // MARK: Contexts

    /// The order the Baseline page lists its contexts: the night first, then the waking contexts.
    static let contextOrder: [BaselineStore.ContextFilter] = [.sleep, .rest, .active, .allDay]

    static func contextName(_ context: BaselineStore.ContextFilter) -> String {
        switch context {
        case .sleep: return "Night"
        case .rest: return "At rest"
        case .active: return "Active"
        case .allDay: return "All day"
        }
    }

    /// The series the Baseline page offers in a context. The same rule as `BaselineStore.displayedSeries`
    /// (which only answers for the store's current context), so a menu can list every context at once;
    /// MonitorLabelsTests checks the two agree.
    static func series(in context: BaselineStore.ContextFilter) -> [LBSeries] {
        LBSeries.allCases.filter {
            if $0 == .wakingImuEnergy { return context == .active }
            return $0.context == context.lbContext && $0 != .wakingSteps && $0 != .sleepSpO2Nadir
        }
    }

    // MARK: Watchdog

    /// The Watchdog engine's last check as a clock time, only once it is overdue: twice the live interval
    /// without a check. A current check needs no time stamp ("Just now" said nothing).
    static func staleCheckTime(lastTickUnix: Int, nowUnix: Int, intervalMinutes: Int) -> String? {
        guard lastTickUnix > 0, nowUnix - lastTickUnix > max(1, intervalMinutes) * 60 * 2 else { return nil }
        return WatchdogEventCopy.clock(lastTickUnix)
    }

    /// The one line under the Watchdog state word: the engine's headline, or why there is nothing to read.
    static func watchdogLine(headline: String?, hasReadings: Bool) -> String {
        guard let headline else { return "Waiting for the first check" }
        return hasReadings ? headline : "No readings in the last 30 minutes"
    }

    /// The snapshot's caption only when it asks for something: an alert that was not delivered. The other
    /// captions ("Not enough minutes.", "Strap off. Not recovered.") repeat what the state word says.
    static func watchdogNotice(_ caption: String?) -> String? {
        guard let caption, caption.hasPrefix("Alert not delivered") else { return nil }
        return caption
    }

    /// The alert list's one-line reason: the vital that drove the alert most, its reading and what was
    /// expected ("Heart rate 91 bpm, expected 64", "+1" when others drove it too). Rows without saved
    /// readings fall back to `WatchdogEventCopy.reasonLine`.
    static func alertReason(_ row: WatchdogEpisodeLedgerRow, fahrenheit: Bool) -> String {
        let hot = Set(row.contributing ?? [])
        let lead = (row.signals ?? [])
            .filter { hot.contains($0.name) && $0.observed != nil }
            .max { $0.energy < $1.energy }
        guard let lead else {
            return WatchdogEventCopy.reasonLine(row, fahrenheit: fahrenheit).replacingOccurrences(of: " /min", with: " rpm")
        }
        let reading = WatchdogEventCopy.value(lead.observed, signal: lead, fahrenheit: fahrenheit)
            .replacingOccurrences(of: " /min", with: " rpm")
        var line = "\(WatchdogEventCopy.vitalName(lead.name)) \(reading)"
        if let expected = splitValue(WatchdogEventCopy.value(lead.reconstructed ?? lead.usual, signal: lead,
                                                             fahrenheit: fahrenheit)).value {
            line += ", expected \(expected)"
        }
        if hot.count > 1 { line += " · +\(hot.count - 1)" }
        return line
    }

    /// The summary of the alert ledger: how many, how long in total, the longest. Durations are the same
    /// open-to-close spans the rows show.
    static func alertTotals(_ rows: [WatchdogEpisodeLedgerRow]) -> (count: Int, totalMinutes: Int, longestMinutes: Int) {
        let minutes = rows.map { max(1, (($0.closedUnix ?? $0.lastUnix) - $0.openedUnix) / 60) }
        return (rows.count, minutes.reduce(0, +), minutes.max() ?? 0)
    }

    /// "25 min", "1 h 35 min".
    static func minutesText(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) min" : (minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min")
    }
}

#if DEBUG

// MARK: - DEBUG-only screenshot hooks for the Monitor area
//
// A simulator cannot be tapped from outside, so these launch arguments open the Monitor area's sheets and
// states for screenshots. Compiled out of Release builds; an absent argument changes nothing.
//
//   --demo-monitor-sheet vital:<id>   the Watchdog page opens a vital's half-hour sheet (hr, rhr, hrv, temp,
//                                      resp, spo2) once the first check has landed
//   --demo-monitor-sheet alert:<n>    the Watchdog page opens the n-th newest alert's sheet (0 = newest)
//   --demo-monitor-sheet note         the Watchdog page opens the alert note sheet
//   --demo-monitor-sheet summary      the Monitor root opens the 7-day summary
//   --demo-monitor-sheet daylog       the Baseline vital page opens the daily log
//   --demo-monitor-window long        the Baseline vital page starts on its 60-day usual
enum MonitorDemoHooks {
    static var sheet: String? { DemoLaunch.stringArg("--demo-monitor-sheet") }
    static var longWindow: Bool { DemoLaunch.stringArg("--demo-monitor-window") == "long" }

    static var vitalSheet: String? {
        guard let sheet, sheet.hasPrefix("vital:") else { return nil }
        return String(sheet.dropFirst("vital:".count))
    }

    static var alertSheet: Int? {
        guard let sheet, sheet.hasPrefix("alert:") else { return nil }
        return Int(sheet.dropFirst("alert:".count))
    }
}
#endif

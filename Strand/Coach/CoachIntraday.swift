import Foundation
import StrandAnalytics

/// The coach's view of the server's dense intraday series: the same buckets the metric pages draw (one
/// minute for respiratory rate, steps and calories, five for HRV and resting heart rate), turned into text a
/// model can quote.
///
/// The model reads this INSTEAD of inferring what the device records from the daily rows, which carry one
/// overnight HRV per day and read as if that were all the strap produces.
enum CoachIntraday {
    /// Tool-argument spellings, mapped to the series the worker publishes.
    static func metric(named raw: String) -> IntradayMetric? {
        switch raw.lowercased().replacingOccurrences(of: " ", with: "_") {
        case "hrv", "hrv_rmssd_ms", "heart_rate_variability": return .hrv
        case "rhr", "resting_hr", "resting_hr_bpm", "resting_heart_rate": return .restingHeartRate
        case "respiration", "resp_rate", "resp_rate_bpm", "respiratory_rate", "breathing": return .respiratoryRate
        case "steps": return .steps
        case "calories", "calories_kcal", "active_calories", "energy": return .calories
        default: return nil
        }
    }

    static let metricNames = "hrv|rhr|respiration|steps|calories"

    static func title(_ metric: IntradayMetric) -> String {
        switch metric {
        case .hrv: return "HRV (RMSSD)"
        case .restingHeartRate: return "Resting heart rate"
        case .respiratoryRate: return "Respiratory rate"
        case .steps: return "Steps"
        case .calories: return "Calories"
        }
    }

    /// What the buckets are, said once, so the model never describes these as once-a-day values.
    /// Resting HR: the lowest qualifying 5-minute mean over the trailing 12 buckets (the bucket included),
    /// so each point's real support is the hour ending with its bucket — the worker's
    /// `ContextInputs.restingSeriesMethod`, support `[b − 3300, b + 300)`.
    static let restingTrailingBuckets = 12

    static func provenance(_ metric: IntradayMetric, bucketSeconds: Int = 300) -> String {
        let computed = "Computed on the server from the strap's data and recomputed about every 5 minutes as new data syncs; "
        let gaps = " A time with no reading means no valid one was possible then (strap off, phone not yet synced"
        let base = computed + "each reading covers a \(bucketWording(bucketSeconds)) bucket." + gaps
        switch metric {
        case .hrv: return base + ", or the wrist moving, since HRV is only read when the wrist is still)."
        case .restingHeartRate:
            // D3-14: the shown bucket is not the support. The minimum can come from any 5-min bin of the hour.
            let support = bucketSeconds * restingTrailingBuckets
            return computed + "each reading at a time T is the LOWEST \(bucketWording(bucketSeconds)) mean heart rate over the "
                + "\(durationWording(support)) ending with T's bucket, so it can come from any part of that hour and does not "
                + "describe what the wearer was doing at T." + gaps + ", or the wrist moving)."
        case .respiratoryRate: return base + ", the wrist moving, or too few clean beats; each reading pools about the last 2 minutes of breaths)."
        case .steps, .calories: return base + "). Each value is that bucket's share of the day's total."
        }
    }

    /// "60 minutes" / "90 seconds".
    static func durationWording(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
    }

    /// "5-minute" / "1-minute" (or "90-second" for anything that is not a whole minute).
    static func bucketWording(_ seconds: Int) -> String {
        seconds % 60 == 0 ? "\(seconds / 60)-minute" : "\(seconds)-second"
    }

    /// - Parameter activity: the saved activity context over the window (and a few hours before it). For HRV each
    ///   reading is then labelled with the wearer's state and the readings are summarised per state, so the model
    ///   compares like with like instead of a morning reading with an evening one.
    static func describe(window: IntradaySeriesWindow, metric: IntradayMetric,
                         timeZone: TimeZone = .current, now: Date = Date(),
                         activity: [ActivityContextInterval]? = nil) -> String {
        let points = window.points(metric)
        let name = title(metric)
        let width = window.bucketSeconds(for: metric)
        let each = width % 60 == 0 ? "\(width / 60) minute\(width == 60 ? "" : "s")" : "\(width) seconds"
        let span = "\(stamp(Date(timeIntervalSince1970: TimeInterval(window.from)), timeZone)) to "
            + stamp(Date(timeIntervalSince1970: TimeInterval(window.to)), timeZone)
        guard !points.isEmpty else {
            return "\(name): no readings between \(span) (\(timeZone.identifier)). "
                + "That means no valid reading was computed for the window, not that the device only records once a day. "
                + provenance(metric, bucketSeconds: width)
        }

        var lines = ["\(name), \(span) (\(timeZone.identifier)): \(points.count) readings of \(each) each. " + provenance(metric, bucketSeconds: width)]
        let values = points.map(\.value)
        let latest = points[points.count - 1]
        let age = IntradayFormat.age(from: latest.date.addingTimeInterval(TimeInterval(width)), to: now)

        if metric.isCumulative {
            let total = values.reduce(0, +)
            lines.append("Total in window: \(metric.format(total)) \(metric.unit). Latest bucket \(clock(latest.date, timeZone)): \(metric.format(latest.value)) (ends \(age)).")
        } else {
            let mean = values.reduce(0, +) / Double(values.count)
            lines.append("Latest \(metric.format(latest.value)) \(metric.unit) at \(clock(latest.date, timeZone)) (\(age)); "
                + "min \(metric.format(values.min() ?? 0)), mean \(metric.format(mean)), max \(metric.format(values.max() ?? 0)) \(metric.unit).")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var hours: [(start: Date, values: [Double])] = []
        for point in points {
            let hour = calendar.dateInterval(of: .hour, for: point.date)?.start ?? point.date
            if let last = hours.last, last.start == hour {
                hours[hours.count - 1].values.append(point.value)
            } else {
                hours.append((hour, [point.value]))
            }
        }
        let states: [HrvState]? = metric == .hrv ? activity.map { context in
            let sorted = context.sorted { $0.start < $1.start }
            return points.map { hrvState(bucketStart: $0.start, width: width, intervals: sorted) }
        } : nil
        if let states {
            lines.append(contentsOf: stateSummary(points: points, states: states, metric: metric, timeZone: timeZone))
        }

        lines.append(metric.isCumulative ? "By hour (total, readings in the hour):" : "By hour (mean, readings in the hour):")
        for hour in hours {
            let sum = hour.values.reduce(0, +)
            let shown = metric.isCumulative ? sum : sum / Double(hour.values.count)
            lines.append("  \(stamp(hour.start, timeZone)): \(metric.format(shown)) (\(hour.values.count))")
        }
        if states != nil { lines.append("  (Hourly means mix states; compare within one state above, not hour against hour.)") }

        let recent = points.indices.suffix(12)
        lines.append("Most recent readings:")
        for i in recent {
            let tag = states.map { " — " + $0[i].tag } ?? ""
            lines.append("  \(clock(points[i].date, timeZone)): \(metric.format(points[i].value))\(tag)")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: HRV by state

    /// The wearer's state during one HRV bucket, read from the saved activity context under the steady-state rule
    /// the awake-rest baselines use (`LongitudinalBaseline.ContextMaterializer`), so each group lines up with a
    /// baseline row of `get_baseline_status`.
    struct HrvState: Equatable {
        enum Group: Int, CaseIterable, Comparable {
            case asleep, lying, seated, standing, stillUnresolved, unsettled, moving, unknown
            static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }

            var title: String {
                switch self {
                case .asleep: return "Asleep"
                case .lying: return "Awake, lying still, settled"
                case .seated: return "Awake, sitting still, settled"
                case .standing: return "Awake, standing still, settled"
                case .stillUnresolved: return "Awake and still (sitting or standing, unresolved), settled"
                case .unsettled: return "Awake and still but not settled (just changed position or recently moved)"
                case .moving: return "Moving"
                case .unknown: return "No activity context for the reading"
                }
            }
        }

        let group: Group
        /// Seconds the wearer had been still in one position when the reading began.
        let stillForS: Int?
        /// Seconds since the last walking, light or vigorous activity, when one was seen in the look-back.
        let sinceMovementS: Int?

        var tag: String {
            var parts: [String]
            switch group {
            case .asleep: parts = ["asleep"]
            case .lying: parts = ["lying still, settled"]
            case .seated: parts = ["sitting still, settled"]
            case .standing: parts = ["standing still, settled"]
            case .stillUnresolved: parts = ["still (sitting or standing), settled"]
            case .unsettled: parts = ["still, not settled"]
            case .moving: parts = ["moving"]
            case .unknown: parts = ["no activity context"]
            }
            if let s = stillForS { parts.append("still \(CoachActivityContext.duration(s))") }
            if let m = sinceMovementS, group != .asleep, group != .moving {
                parts.append("\(CoachActivityContext.duration(m)) after moving")
            }
            return parts.joined(separator: ", ")
        }
    }

    /// How far back a still run and the last movement are looked for.
    static let stateLookbackS = 3 * 3_600

    static func hrvState(bucketStart s: Int, width: Int, intervals: [ActivityContextInterval]) -> HrvState {
        typealias M = LongitudinalBaseline.ContextMaterializer
        let end = s + width
        var seconds: [ActivityClass: Int] = [:]
        var asleepS = 0, covered = 0
        for iv in intervals where iv.end > s && iv.start < end {
            guard iv.wear != .offWrist, iv.activityClass != .offWrist, iv.activityClass != .unknown else { continue }
            let overlap = min(iv.end, end) - max(iv.start, s)
            covered += overlap
            seconds[iv.activityClass, default: 0] += overlap
            if iv.activityClass == .sleeping || iv.sleep == .asleep { asleepS += overlap }
        }
        guard covered * 2 >= width, let dominant = seconds.max(by: { $0.value < $1.value })?.key else {
            return HrvState(group: .unknown, stillForS: nil, sinceMovementS: nil)
        }
        if asleepS * 2 >= covered { return HrvState(group: .asleep, stillForS: nil, sinceMovementS: nil) }
        if dominant.isMovement { return HrvState(group: .moving, stillForS: nil, sinceMovementS: nil) }
        guard dominant.isStationaryAwake || dominant == .lyingDown else {
            return HrvState(group: .unknown, stillForS: nil, sinceMovementS: nil)
        }

        // Walk back from the reading: the still run in one position, then the last movement of each kind.
        let lying = dominant == .lyingDown
        let before = intervals.filter { $0.start < s && $0.end > s - stateLookbackS }.reversed()
        var runStart = s
        var runOpen = true
        var lastWalk: Int?, lastVigorous: Int?
        for iv in before {
            let still = (iv.activityClass.isStationaryAwake || iv.activityClass == .lyingDown) && iv.sleep != .asleep
                && iv.wear != .offWrist
            if runOpen {
                if still, (iv.activityClass == .lyingDown) == lying, runStart - iv.end <= 10 {
                    runStart = min(runStart, iv.start)
                    continue
                }
                runOpen = false
            }
            switch iv.activityClass {
            case .running, .cycling, .vigorousActivity: lastVigorous = lastVigorous ?? iv.end
            case .walking, .briskWalking, .lightActivity: lastWalk = lastWalk ?? iv.end
            default: break
            }
            if lastWalk != nil, lastVigorous != nil { break }
        }
        let stillFor = s - runStart
        let sinceWalk = lastWalk.map { s - $0 }, sinceVigorous = lastVigorous.map { s - $0 }
        let settled = stillFor >= M.settleAfterTransitionS
            && (sinceWalk ?? .max) >= M.settleAfterWalkingS
            && (sinceVigorous ?? .max) >= M.settleAfterVigorousS
        let sinceMovement = [sinceWalk, sinceVigorous].compactMap { $0 }.min()
        let group: HrvState.Group
        if !settled {
            group = .unsettled
        } else {
            switch dominant {
            case .lyingDown: group = .lying
            case .sitting, .sittingDesk: group = .seated
            case .standing: group = .standing
            default: group = .stillUnresolved
            }
        }
        return HrvState(group: group, stillForS: stillFor, sinceMovementS: sinceMovement)
    }

    /// One line per state: count, median and middle half, and when those readings were taken.
    static func stateSummary(points: [IntradaySeriesPoint], states: [HrvState], metric: IntradayMetric,
                             timeZone: TimeZone) -> [String] {
        typealias M = LongitudinalBaseline.ContextMaterializer
        var lines = ["HRV BY STATE: each 5-minute RMSSD reading matched to the saved activity context. 'Settled' is the "
            + "steady-state rule the personal baselines use (still in one position for at least \(M.settleAfterTransitionS / 60) min, "
            + "\(M.settleAfterWalkingS / 60) min after walking or light activity, \(M.settleAfterVigorousS / 60) min after vigorous "
            + "activity). Compare readings only within one state, and a settled state only with its matching baseline row:"]
        for group in HrvState.Group.allCases {
            let idx = states.indices.filter { states[$0].group == group }
            guard !idx.isEmpty else { continue }
            let values = idx.map { points[$0].value }.sorted()
            let q = { (p: Double) -> Double in values[min(values.count - 1, Int((Double(values.count - 1) * p).rounded()))] }
            var line = "  • \(group.title): \(values.count) reading\(values.count == 1 ? "" : "s"), median \(metric.format(q(0.5))) \(metric.unit)"
            if values.count >= 4 { line += " (middle half \(metric.format(q(0.25)))–\(metric.format(q(0.75))))" }
            line += ", \(clock(points[idx.first!].date, timeZone))–\(clock(points[idx.last!].date, timeZone))"
            lines.append(line)
        }
        return lines
    }

    private static func stamp(_ date: Date, _ zone: TimeZone) -> String { format(date, zone, "EEE MMM d HH:mm") }
    private static func clock(_ date: Date, _ zone: TimeZone) -> String { format(date, zone, "HH:mm") }

    private static func format(_ date: Date, _ zone: TimeZone, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

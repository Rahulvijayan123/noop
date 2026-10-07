import Foundation

/// F09 read-only 7-day pack. Does not evaluate live or write Layer 1.
public struct WatchdogClinicianExport: Equatable, Sendable, Codable {
    public var versionLine: String
    public var deviceId: String
    public var windowStartUnix: Int
    public var windowEndUnix: Int
    public var disclaimer: String
    public var episodes: [WatchdogEpisodeLedgerRow]
    public var offMinuteCount: Int
    public var annotations: [WatchdogEpisodeAnnotation]
    public var recoveryHeadline: String?
    public var dayLogSummaries: [String: String]
    public var copyLines: [String]
    public var monitoredByDay: [String: Int]
    public var text: String

    public static let disclaimer =
        "Not a medical device. Not a diagnosis. Bundled graphs are students."

    public static func versionLine() -> String {
        "\(WatchdogConfig.configVersion) · \(WatchdogConfig.modelVersion) student · \(WatchdogConfig.forecastModelVersion) student · Layer 1 \(WatchdogConfig.paramSet)"
    }

    public static func build(deviceId: String, startUnix: Int, endUnix: Int,
                             ledger: [WatchdogEpisodeLedgerRow],
                             evaluations: [LBEvaluation],
                             dayLogs: [String: LBDayLog],
                             annotations: [WatchdogEpisodeAnnotation],
                             recovery: WatchdogEventRecovery?,
                             monitoredByDay: [String: Int] = [:]) -> WatchdogClinicianExport {
        let episodes = WatchdogEpisodeLedger.inWindow(ledger, deviceId: deviceId,
                                                      startUnix: startUnix, endUnix: endUnix)
        let off = Set(episodes.flatMap(\.offMinutes)).count
        let notes = annotations.filter {
            $0.deviceId == deviceId && $0.eventUnix >= startUnix && $0.eventUnix <= endUnix
        }
        var copies: [String] = []
        for ev in evaluations {
            let week = ev.copy7.map {
                String(format: "%@ week n=%d center=%.2f", ev.series.rawValue, $0.n, $0.centerDisplay)
            }
            let long = ev.copyLong.map {
                String(format: "%@ long n=%d center=%.2f", ev.series.rawValue, $0.n, $0.centerDisplay)
            }
            if let week { copies.append(week) }
            if let long { copies.append(long) }
            if ev.copy7 != nil, ev.copyLong != nil {
                copies.append("\(ev.series.rawValue) copies not averaged")
            }
        }
        var logs: [String: String] = [:]
        for (day, log) in dayLogs {
            logs[day] = log.summaryLine
        }
        let pack = WatchdogClinicianExport(
            versionLine: versionLine(),
            deviceId: deviceId,
            windowStartUnix: startUnix,
            windowEndUnix: endUnix,
            disclaimer: disclaimer,
            episodes: episodes,
            offMinuteCount: off,
            annotations: notes,
            recoveryHeadline: recovery?.headline,
            dayLogSummaries: logs,
            copyLines: copies,
            monitoredByDay: monitoredByDay,
            text: "")
        var out = pack
        out.text = render(pack)
        return out
    }

    public static func render(_ pack: WatchdogClinicianExport) -> String {
        var lines: [String] = []
        lines.append(pack.disclaimer)
        lines.append(pack.versionLine)
        lines.append("Source \(pack.deviceId)")
        lines.append("Window \(pack.windowStartUnix)–\(pack.windowEndUnix)")
        lines.append("Episodes \(pack.episodes.count) · Off minutes \(pack.offMinuteCount)")
        for row in pack.episodes {
            lines.append("  \(row.episodeId) max=\(row.maxSeverity) notify=\(row.notifyDelivery) offMin=\(row.offMinutes.count)")
        }
        lines.append("Usual copies (week and long stay separate)")
        lines.append(contentsOf: pack.copyLines)
        lines.append("Daily logs")
        for day in pack.dayLogSummaries.keys.sorted() {
            lines.append("  \(day) \(pack.dayLogSummaries[day] ?? "")")
        }
        lines.append("Episode notes (missing is not “no symptoms”)")
        if pack.annotations.isEmpty {
            lines.append("  none")
        }
        for note in pack.annotations {
            if note.status != .entered {
                lines.append("  \(note.episodeId) \(note.status.rawValue) missing")
            } else {
                let sx = note.symptoms ?? "missing"
                lines.append("  \(note.episodeId) entered event=\(note.eventUnix) entry=\(note.enteredUnix ?? 0) reporter=\(note.reporter) symptoms=\(sx)")
            }
        }
        if let rec = pack.recoveryHeadline {
            lines.append("Event recovery \(rec)")
        }
        lines.append("Monitored minutes by day")
        for day in pack.monitoredByDay.keys.sorted() {
            lines.append("  \(day) \(pack.monitoredByDay[day] ?? 0)")
        }
        return lines.joined(separator: "\n")
    }
}

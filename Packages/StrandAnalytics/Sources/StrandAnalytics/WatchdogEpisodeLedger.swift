import Foundation

/// F09 journal of decisions `evaluate` already made. Does not change `nextState`.
public struct WatchdogEpisodeLedgerRow: Equatable, Sendable, Codable {
    public var episodeId: String
    public var deviceId: String
    public var openedUnix: Int
    public var lastUnix: Int
    public var closedUnix: Int?
    public var maxSeverity: String
    public var safety: Bool
    public var personalOff: Bool
    public var notifyDelivery: String
    public var liveAlerts: Bool
    public var offMinutes: [Int]
    public var unavailableMinutes: Int
    /// The tick with the highest fused energy in this episode, and what `evaluate` saw then.
    /// Optional so rows written before these fields decode unchanged.
    public var peakUnix: Int?
    public var peakEnergy: Double?
    public var peakSeverity: String?
    public var headline: String?
    public var eventLabel: String?
    public var activityLabel: String?
    public var contributing: [String]?
    public var signals: [WatchdogSignalEvidence]?

    public init(episodeId: String, deviceId: String, openedUnix: Int, lastUnix: Int,
                closedUnix: Int? = nil, maxSeverity: String, safety: Bool,
                personalOff: Bool, notifyDelivery: String, liveAlerts: Bool,
                offMinutes: [Int] = [], unavailableMinutes: Int = 0,
                peakUnix: Int? = nil, peakEnergy: Double? = nil, peakSeverity: String? = nil,
                headline: String? = nil, eventLabel: String? = nil, activityLabel: String? = nil,
                contributing: [String]? = nil, signals: [WatchdogSignalEvidence]? = nil) {
        self.episodeId = episodeId
        self.deviceId = deviceId
        self.openedUnix = openedUnix
        self.lastUnix = lastUnix
        self.closedUnix = closedUnix
        self.maxSeverity = maxSeverity
        self.safety = safety
        self.personalOff = personalOff
        self.notifyDelivery = notifyDelivery
        self.liveAlerts = liveAlerts
        self.offMinutes = offMinutes
        self.unavailableMinutes = unavailableMinutes
        self.peakUnix = peakUnix
        self.peakEnergy = peakEnergy
        self.peakSeverity = peakSeverity
        self.headline = headline
        self.eventLabel = eventLabel
        self.activityLabel = activityLabel
        self.contributing = contributing
        self.signals = signals
    }

    /// Keeps the strongest scored moment. Unavailable ticks carry no evidence and never replace it.
    mutating func notePeak(_ result: WatchdogResult, nowUnix: Int) {
        guard result.unavailable == nil else { return }
        if let peakEnergy, result.fusedEnergy <= peakEnergy { return }
        peakUnix = nowUnix
        peakEnergy = result.fusedEnergy
        peakSeverity = result.severity.rawValue
        headline = result.headline
        eventLabel = result.eventLabel
        activityLabel = result.activityLabel
        contributing = result.contributing
        signals = result.signals.filter { $0.name != "Motion" }
    }
}

public enum WatchdogEpisodeLedger: Sendable {
    public static let persistPrefix = "noop.watchdog.episodeLedger.v1."
    public static let keepSeconds = 21 * 24 * 3600

    public static func persistKey(deviceId: String) -> String { persistPrefix + deviceId }

    private static let rank: [String: Int] = [
        "candidate": 1, "active": 2, "severe": 3
    ]

    public static func upsert(rows: [WatchdogEpisodeLedgerRow],
                              result: WatchdogResult, deviceId: String,
                              nowUnix: Int, liveAlerts: Bool) -> [WatchdogEpisodeLedgerRow] {
        guard liveAlerts else { return rows }
        guard let eid = result.episodeId, !eid.isEmpty else {
            return closeOpen(rows, nowUnix: nowUnix, ifResolved: result.episodeState)
        }
        var next = rows
        let minute = nowUnix - nowUnix % WatchdogConfig.gridSeconds
        let sev = result.severity.rawValue
        if let i = next.firstIndex(where: { $0.episodeId == eid && $0.deviceId == deviceId }) {
            var row = next[i]
            row.lastUnix = nowUnix
            if (rank[sev] ?? 0) > (rank[row.maxSeverity] ?? 0) {
                row.maxSeverity = sev
            }
            row.safety = row.safety || result.unavailable == nil && result.liveOff && result.severity == .severe
            row.personalOff = row.personalOff || result.personalOff
            if !result.carry.notifyDelivery.isEmpty {
                row.notifyDelivery = result.carry.notifyDelivery
            }
            if result.liveOff {
                if !row.offMinutes.contains(minute) { row.offMinutes.append(minute) }
            }
            if result.unavailable != nil {
                row.unavailableMinutes += 1
            }
            if result.episodeState == .resolved {
                row.closedUnix = row.closedUnix ?? nowUnix
            }
            row.notePeak(result, nowUnix: nowUnix)
            next[i] = row
        } else if result.severity == .candidate || result.severity == .active
                    || result.severity == .severe {
            var off: [Int] = []
            if result.liveOff { off = [minute] }
            var row = WatchdogEpisodeLedgerRow(
                episodeId: eid, deviceId: deviceId, openedUnix: nowUnix, lastUnix: nowUnix,
                maxSeverity: sev, safety: result.severity == .severe,
                personalOff: result.personalOff,
                notifyDelivery: result.carry.notifyDelivery,
                liveAlerts: true, offMinutes: off,
                unavailableMinutes: result.unavailable == nil ? 0 : 1)
            row.notePeak(result, nowUnix: nowUnix)
            next.append(row)
        }
        return prune(next, nowUnix: nowUnix, deviceId: deviceId)
    }

    private static func closeOpen(_ rows: [WatchdogEpisodeLedgerRow], nowUnix: Int,
                                  ifResolved state: WatchdogEpisodeState) -> [WatchdogEpisodeLedgerRow] {
        guard state == .resolved || state == .withinLimits else { return rows }
        return rows.map { row in
            var out = row
            if out.closedUnix == nil { out.closedUnix = nowUnix }
            return out
        }
    }

    public static func prune(_ rows: [WatchdogEpisodeLedgerRow], nowUnix: Int,
                             deviceId: String) -> [WatchdogEpisodeLedgerRow] {
        rows.filter { $0.deviceId == deviceId && nowUnix - $0.openedUnix <= keepSeconds }
    }

    public static func inWindow(_ rows: [WatchdogEpisodeLedgerRow], deviceId: String,
                                startUnix: Int, endUnix: Int) -> [WatchdogEpisodeLedgerRow] {
        rows.filter {
            $0.deviceId == deviceId && $0.openedUnix <= endUnix && $0.lastUnix >= startUnix
        }
    }
}

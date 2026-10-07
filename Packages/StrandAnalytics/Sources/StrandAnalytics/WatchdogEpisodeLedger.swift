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

    public init(episodeId: String, deviceId: String, openedUnix: Int, lastUnix: Int,
                closedUnix: Int? = nil, maxSeverity: String, safety: Bool,
                personalOff: Bool, notifyDelivery: String, liveAlerts: Bool,
                offMinutes: [Int] = [], unavailableMinutes: Int = 0) {
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
            next[i] = row
        } else if result.severity == .candidate || result.severity == .active
                    || result.severity == .severe {
            var off: [Int] = []
            if result.liveOff { off = [minute] }
            next.append(WatchdogEpisodeLedgerRow(
                episodeId: eid, deviceId: deviceId, openedUnix: nowUnix, lastUnix: nowUnix,
                maxSeverity: sev, safety: result.severity == .severe,
                personalOff: result.personalOff,
                notifyDelivery: result.carry.notifyDelivery,
                liveAlerts: true, offMinutes: off,
                unavailableMinutes: result.unavailable == nil ? 0 : 1))
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

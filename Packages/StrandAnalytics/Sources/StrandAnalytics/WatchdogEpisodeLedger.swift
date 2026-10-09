import Foundation

/// F09 journal of decisions `evaluate` already made. Does not change `nextState`.
public struct WatchdogEpisodeLedgerRow: Equatable, Sendable, Codable {
    public var episodeId: String
    public var deviceId: String
    public var openedUnix: Int
    public var lastUnix: Int
    public var closedUnix: Int?
    public var maxSeverity: String
    /// A verified safety-extreme alert happened in this episode (not merely "reached severe").
    public var safety: Bool
    public var personalOff: Bool
    /// Delivery of THIS episode's notification: "" (never notified), "queued", "sent". Never copied from another
    /// episode's push.
    public var notifyDelivery: String
    public var liveAlerts: Bool
    /// Minutes judged off the person's usual (not off-wrist).
    public var offMinutes: [Int]
    /// Minutes (not ticks) the Watchdog could not judge.
    public var unavailableMinutes: Int
    public var lastUnavailableMinute: Int?
    /// Exercise context at the peak tick (rule exercise-session-2): lineage for the clinician export and the server.
    public var exercise: WatchdogExerciseSnapshot?
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
        exercise = result.exercise
    }

    static func verifiedSafety(_ result: WatchdogResult) -> Bool {
        (result.verdicts ?? []).contains { $0.decision == .alert && $0.candidate.kind == .safetyExtreme }
    }

    /// This episode's own delivery state: queued on the tick that notified it, sent once the notifier stamped it.
    static func delivery(_ result: WatchdogResult, episodeId: String) -> String? {
        if result.shouldNotify { return "queued" }
        if result.carry.notifiedSevereEpisodeId == episodeId, !result.carry.notifyDelivery.isEmpty {
            return result.carry.notifyDelivery
        }
        return nil
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
            row.safety = row.safety || WatchdogEpisodeLedgerRow.verifiedSafety(result)
            row.personalOff = row.personalOff || result.personalOff
            if let d = WatchdogEpisodeLedgerRow.delivery(result, episodeId: eid) {
                row.notifyDelivery = d
            }
            if result.liveOff {
                if !row.offMinutes.contains(minute) { row.offMinutes.append(minute) }
            }
            if result.unavailable != nil, row.lastUnavailableMinute != minute {
                row.unavailableMinutes += 1
                row.lastUnavailableMinute = minute
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
                maxSeverity: sev, safety: WatchdogEpisodeLedgerRow.verifiedSafety(result),
                personalOff: result.personalOff,
                notifyDelivery: WatchdogEpisodeLedgerRow.delivery(result, episodeId: eid) ?? "",
                liveAlerts: true, offMinutes: off,
                unavailableMinutes: result.unavailable == nil ? 0 : 1)
            if result.unavailable != nil { row.lastUnavailableMinute = minute }
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

// MARK: - Server record (POST scores/watchdog-episodes, docs/context-watchdog/WATCHDOG_EPISODES.md)

extension WatchdogEpisodeLedger {
    /// The JSON body for `POST scores/watchdog-episodes`: the alarm lineage (what was judged, against which
    /// reference, what the wearer said about it) kept on the account, not only on this phone.
    public static func serverBody(rows: [WatchdogEpisodeLedgerRow], annotations: [WatchdogEpisodeAnnotation],
                                  serverDeviceId: String, localDeviceId: String, versions: [String: String],
                                  nowUnix: Int) -> [String: Any] {
        let encoder = JSONEncoder()
        func json<T: Encodable>(_ v: T?) -> Any {
            guard let v, let data = try? encoder.encode(v),
                  let obj = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
            return obj
        }
        let byEpisode = Dictionary(annotations.map { ($0.episodeId, $0) }, uniquingKeysWith: { _, b in b })
        let episodes: [[String: Any]] = rows.map { r in
            [
                "episode_id": r.episodeId,
                "opened_at": r.openedUnix,
                "last_at": r.lastUnix,
                "closed_at": r.closedUnix.map { $0 as Any } ?? NSNull(),
                "max_severity": r.maxSeverity,
                "peak_severity": r.peakSeverity.map { $0 as Any } ?? NSNull(),
                "safety": r.safety,
                "personal_off": r.personalOff,
                "notify_delivery": r.notifyDelivery,
                "live_alerts": r.liveAlerts,
                "off_minute_count": r.offMinutes.count,
                "unavailable_minutes": r.unavailableMinutes,
                "headline": r.headline.map { $0 as Any } ?? NSNull(),
                "event_label": r.eventLabel.map { $0 as Any } ?? NSNull(),
                "activity_label": r.activityLabel.map { $0 as Any } ?? NSNull(),
                "contributing": r.contributing ?? [],
                "signals": json(r.signals),
                "exercise": json(r.exercise),
                "annotation": json(byEpisode[r.episodeId]),
                "versions": versions,
                "client_updated_at": max(r.lastUnix, byEpisode[r.episodeId]?.enteredUnix ?? 0, r.closedUnix ?? 0),
            ]
        }
        return ["device_id": serverDeviceId, "local_device_id": localDeviceId, "episodes": episodes,
                "sent_at": nowUnix]
    }

    /// A stable fingerprint of what would be sent for one episode (resend only when it changed).
    public static func fingerprint(_ row: WatchdogEpisodeLedgerRow, annotation: WatchdogEpisodeAnnotation?) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        // FNV-1a 64 over the sorted-key JSON: stable across launches (Swift's hashValue is reseeded per process) and
        // available on Linux, where this package also builds.
        var h: UInt64 = 0xcbf29ce484222325
        for data in [(try? encoder.encode(row)) ?? Data(), Data([0]), annotation.flatMap { try? encoder.encode($0) } ?? Data()] {
            for byte in data {
                h ^= UInt64(byte)
                h = h &* 0x100000001b3
            }
        }
        return String(h, radix: 16)
    }
}

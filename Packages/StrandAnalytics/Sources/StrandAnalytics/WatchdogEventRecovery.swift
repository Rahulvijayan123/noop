import Foundation

public enum WatchdogEventRecoveryStatus: String, Equatable, Sendable, Codable {
    case open
    case returning
    case returned
    case unknown
    case noReference = "no_reference"
}

public struct WatchdogEventRecoveryChannel: Equatable, Sendable, Codable {
    public var series: LBSeries
    public var center: Double
    public var spread: Double
    public var k: Double
    public var remainingZ: Double?
    public var nativeRemaining: Double?
    public var lastEligibleUnix: Int
    public var inBandSinceUnix: Int?
    public var returnedUnix: Int?

    public init(series: LBSeries, center: Double, spread: Double, k: Double,
                remainingZ: Double? = nil, nativeRemaining: Double? = nil,
                lastEligibleUnix: Int = 0, inBandSinceUnix: Int? = nil,
                returnedUnix: Int? = nil) {
        self.series = series
        self.center = center
        self.spread = spread
        self.k = k
        self.remainingZ = remainingZ
        self.nativeRemaining = nativeRemaining
        self.lastEligibleUnix = lastEligibleUnix
        self.inBandSinceUnix = inBandSinceUnix
        self.returnedUnix = returnedUnix
    }
}

public struct WatchdogEventRecovery: Equatable, Sendable, Codable {
    public var episodeId: String
    public var deviceId: String
    public var openedUnix: Int
    public var openedCivilDay: String
    public var status: WatchdogEventRecoveryStatus
    public var channels: [WatchdogEventRecoveryChannel]
    public var lastUnavailable: Bool

    public static let persistPrefix = "noop.watchdog.eventRecovery.v1."

    public init(episodeId: String, deviceId: String, openedUnix: Int, openedCivilDay: String,
                status: WatchdogEventRecoveryStatus, channels: [WatchdogEventRecoveryChannel],
                lastUnavailable: Bool = false) {
        self.episodeId = episodeId
        self.deviceId = deviceId
        self.openedUnix = openedUnix
        self.openedCivilDay = openedCivilDay
        self.status = status
        self.channels = channels
        self.lastUnavailable = lastUnavailable
    }

    public static func persistKey(deviceId: String) -> String { persistPrefix + deviceId }

    /// Same ruler as live personal-off: freeze long copy, else shown 60-day. Never week, never hat.
    public static func reference(freeze: LBUsualFreeze?, copyLong: LBCopySnapshot?,
                                 establishedLong: Bool, showLong: Bool,
                                 k: Double) -> (center: Double, spread: Double, k: Double)? {
        if let f = freeze, f.spreadLong > 0 {
            return (f.centerLong, f.spreadLong, k)
        }
        if establishedLong || showLong, let c = copyLong, c.spread > 0 {
            return (c.center, c.spread, k)
        }
        return nil
    }

    public static func openIfNeeded(existing: WatchdogEventRecovery?,
                                    episodeId: String?, deviceId: String,
                                    nowUnix: Int, civilDay: String,
                                    evaluations: [LBEvaluation],
                                    liveAlerts: Bool) -> WatchdogEventRecovery? {
        guard liveAlerts, let eid = episodeId, !eid.isEmpty else { return existing }
        if let existing, existing.episodeId == eid { return existing }
        var channels: [WatchdogEventRecoveryChannel] = []
        let wanted: [LBSeries] = [
            .awakeRestHR, .sleepRHR, .continuousHR,
            .awakeRestHRVLn, .sleepHRVLn, .continuousHRVLn
        ]
        for series in wanted {
            guard let ev = evaluations.first(where: { $0.series == series }),
                  let ref = reference(freeze: ev.usualFreeze, copyLong: ev.copyLong,
                                      establishedLong: ev.establishedLong, showLong: ev.showLong,
                                      k: ev.kBandUsed) else { continue }
            channels.append(WatchdogEventRecoveryChannel(
                series: series, center: ref.center, spread: ref.spread, k: ref.k))
        }
        let status: WatchdogEventRecoveryStatus = channels.isEmpty ? .noReference : .open
        return WatchdogEventRecovery(episodeId: eid, deviceId: deviceId, openedUnix: nowUnix,
                                     openedCivilDay: civilDay, status: status, channels: channels)
    }

    public static func step(_ record: WatchdogEventRecovery, hrBpm: Double?, hrvMs: Double?,
                            nowUnix: Int, unavailable: Bool) -> WatchdogEventRecovery {
        var out = record
        if unavailable {
            out.lastUnavailable = true
            out.status = .unknown
            return out
        }
        out.lastUnavailable = false
        let minute = nowUnix - nowUnix % WatchdogConfig.gridSeconds
        for i in out.channels.indices {
            let series = out.channels[i].series
            let native: Double?
            if series.usesLog { native = hrvMs } else { native = hrBpm }
            guard let native, native > 0,
                  let math = LongitudinalBaseline.toMath(native, series: series) else { continue }
            guard minute > out.channels[i].lastEligibleUnix else { continue }
            let z = (math - out.channels[i].center) / out.channels[i].spread
            let inBand = !LongitudinalBaseline.isOffUsual(z: z, k: out.channels[i].k)
            out.channels[i].remainingZ = z
            out.channels[i].nativeRemaining = native - LongitudinalBaseline.toDisplay(out.channels[i].center, series: series)
            out.channels[i].lastEligibleUnix = minute
            if inBand {
                if out.channels[i].inBandSinceUnix == nil {
                    out.channels[i].inBandSinceUnix = minute
                } else if out.channels[i].returnedUnix == nil,
                          minute > (out.channels[i].inBandSinceUnix ?? minute) {
                    out.channels[i].returnedUnix = minute
                }
            } else {
                out.channels[i].inBandSinceUnix = nil
                out.channels[i].returnedUnix = nil
            }
        }
        if out.channels.isEmpty {
            out.status = .noReference
        } else if out.channels.allSatisfy({ $0.returnedUnix != nil }) {
            out.status = .returned
        } else if out.channels.contains(where: { $0.inBandSinceUnix != nil && $0.returnedUnix == nil }) {
            out.status = .returning
        } else {
            out.status = .open
        }
        return out
    }

    public var hoursToReturn: Double? {
        guard status == .returned else { return nil }
        let times = channels.compactMap(\.returnedUnix)
        guard let last = times.max() else { return nil }
        return Double(last - openedUnix) / 3600
    }

    public var headline: String {
        switch status {
        case .noReference:
            return "No pre-event usual to recover to yet."
        case .unknown:
            return "Unknown — strap off or not enough minutes."
        case .returned:
            if let h = hoursToReturn {
                return String(format: "Back to usual after %.0f hours.", h)
            }
            return "Back to your pre-event usual."
        case .returning:
            return "Settling toward your pre-event usual."
        case .open:
            if let ch = channels.first(where: { ($0.remainingZ.map(abs) ?? 0) > 0 }),
               let rem = ch.nativeRemaining {
                let unit = ch.series.usesLog ? "ms" : "bpm"
                return String(format: "Not back to your pre-event usual yet · %+.0f %@.", rem, unit)
            }
            return "Not back to your pre-event usual yet."
        }
    }
}

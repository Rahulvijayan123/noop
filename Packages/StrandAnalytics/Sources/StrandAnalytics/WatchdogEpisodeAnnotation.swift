import Foundation

/// F08 sidecar. Optional note after a **sent** page. Never writes `LBDayLog`.
public enum WatchdogAnnotationStatus: String, Equatable, Sendable, Codable {
    case pending
    case entered
    case skipped
    case expired
}

public enum WatchdogAnnotationExertion: String, Equatable, Sendable, Codable {
    case rest
    case light
    case hard
}

public enum WatchdogAnnotationStress: String, Equatable, Sendable, Codable {
    case low
    case high
}

public enum WatchdogAnnotationIllness: String, Equatable, Sendable, Codable {
    case feltOff = "felt_off"
    case not
}

public enum WatchdogAnnotationSensor: String, Equatable, Sendable, Codable {
    case loose
    case charging
    case justOn = "just_on"
    case other
}

public struct WatchdogEpisodeAnnotation: Equatable, Sendable, Codable {
    public var episodeId: String
    public var deviceId: String
    public var eventUnix: Int
    public var enteredUnix: Int?
    public var reporter: String
    public var status: WatchdogAnnotationStatus
    public var symptoms: String?
    public var exertion: WatchdogAnnotationExertion?
    public var stress: WatchdogAnnotationStress?
    public var illness: WatchdogAnnotationIllness?
    public var sensor: WatchdogAnnotationSensor?
    public var note: String?

    public static let expireSeconds = 24 * 3600
    public static let persistPrefix = "noop.watchdog.annotations.v1."
    public static let maxStored = 30
    public static let noteCategory = "watchdog-episode-note"

    public init(episodeId: String, deviceId: String, eventUnix: Int,
                enteredUnix: Int? = nil, reporter: String = "wearer",
                status: WatchdogAnnotationStatus = .pending,
                symptoms: String? = nil, exertion: WatchdogAnnotationExertion? = nil,
                stress: WatchdogAnnotationStress? = nil,
                illness: WatchdogAnnotationIllness? = nil,
                sensor: WatchdogAnnotationSensor? = nil, note: String? = nil) {
        self.episodeId = episodeId
        self.deviceId = deviceId
        self.eventUnix = eventUnix
        self.enteredUnix = enteredUnix
        self.reporter = reporter
        self.status = status
        self.symptoms = symptoms
        self.exertion = exertion
        self.stress = stress
        self.illness = illness
        self.sensor = sensor
        self.note = note
    }

    public static func persistKey(deviceId: String) -> String { persistPrefix + deviceId }

    /// Insert pending only after a live **sent** page. Does not write the daily log.
    public static func pendingIfNeeded(existing: [WatchdogEpisodeAnnotation],
                                       episodeId: String, deviceId: String,
                                       eventUnix: Int, delivery: String,
                                       liveAlerts: Bool) -> [WatchdogEpisodeAnnotation] {
        guard liveAlerts, delivery == "sent", !episodeId.isEmpty else { return existing }
        if existing.contains(where: { $0.episodeId == episodeId }) { return existing }
        var next = existing
        next.append(WatchdogEpisodeAnnotation(episodeId: episodeId, deviceId: deviceId,
                                              eventUnix: eventUnix))
        if next.count > maxStored {
            next.removeFirst(next.count - maxStored)
        }
        return next
    }

    public func entered(nowUnix: Int, symptoms: String?, exertion: WatchdogAnnotationExertion?,
                        stress: WatchdogAnnotationStress?, illness: WatchdogAnnotationIllness?,
                        sensor: WatchdogAnnotationSensor?, note: String?) -> WatchdogEpisodeAnnotation {
        var out = self
        out.status = .entered
        out.enteredUnix = max(nowUnix, eventUnix)
        out.symptoms = symptoms
        out.exertion = exertion
        out.stress = stress
        out.illness = illness
        out.sensor = sensor
        out.note = note
        return out
    }

    public func skipped() -> WatchdogEpisodeAnnotation {
        var out = self
        out.status = .skipped
        return out
    }

    public func expireIfNeeded(nowUnix: Int) -> WatchdogEpisodeAnnotation {
        guard status == .pending, nowUnix - eventUnix >= Self.expireSeconds else { return self }
        var out = self
        out.status = .expired
        return out
    }

    /// Export / training: only `entered` is a label. Skip / pending / expired are missing.
    public var isNegativeSymptomLabel: Bool { false }

    public var symptomsMissing: Bool {
        status != .entered || symptoms == nil
    }

    public static func replace(_ rows: [WatchdogEpisodeAnnotation],
                               with row: WatchdogEpisodeAnnotation) -> [WatchdogEpisodeAnnotation] {
        var next = rows
        if let i = next.firstIndex(where: { $0.episodeId == row.episodeId }) {
            next[i] = row
        } else {
            next.append(row)
        }
        return next
    }
}

import Foundation

/// How much of the day the WHOOP 5/MG raw motion stream (100 Hz accelerometer + gyroscope) is recorded for
/// the activity classifier.
///
/// The server's HART model reads 4 s windows of that stream (resampled to 30 Hz) and hands its per-window
/// verdicts back to the phone's activity decoder. Without this the stream is only recorded during a Raw
/// Data session someone starts by hand, so HART never sees anything.
///
/// The strap's battery cost of streaming raw motion has not been measured, so the default records part of
/// the time: one minute in every three. Each minute is about 30 HART windows; the decoder carries its
/// belief through the gaps. Continuous is for when the battery cost is known to be acceptable.
enum ActivityImuCaptureMode: String, CaseIterable, Identifiable, Sendable {
    case off
    case partTime
    case continuous

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .partTime: return "Part-time"
        case .continuous: return "Continuous"
        }
    }
}

enum ActivityImuCapture {
    static let modeKey = "activityImuCaptureMode"
    static let defaultMode: ActivityImuCaptureMode = .partTime

    /// Part-time duty cycle: on for the first `partTimeOnSeconds` of every `partTimePeriodSeconds`, aligned to
    /// the wall clock so a reconnect lands in the same phase. The keep-alive tick that drives it runs every
    /// 30 s, so each edge can land up to one tick late.
    static let partTimeOnSeconds = 60
    static let partTimePeriodSeconds = 180

    /// Below this strap charge (and not charging) the stream is released. Power saving's own threshold
    /// takes over while Power saving is on.
    static let defaultPauseBatteryPct = 15

    /// Lean raw capture: after arming the live IMU stream, ask the strap NOT to bank the raw optical and IMU
    /// records to flash and not to stream optical live. Raw collection otherwise banks one 2140 B optical
    /// and one 1244 B IMU record per second, about 87% of every offload's bytes, while 98% of the IMU it
    /// banks has already arrived live and nothing reads the optical. On by default; the key turns it off.
    static let leanRawCaptureKey = "activityImuLeanRawCapture"
    static func leanRawCapture(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: leanRawCaptureKey) == nil ? true : defaults.bool(forKey: leanRawCaptureKey)
    }

    /// How long the IMU-only arm (105 + 106, no raw start) has to produce a live IMU frame before the
    /// capture falls back to the shared raw start for the rest of the process.
    static let imuOnlyVerifySeconds: TimeInterval = 6

    /// The OFF writes sent after a shared raw start, in order. Revision-1 boolean bodies `[1, 0]`. On a 5/MG
    /// the strap acknowledges 107 and 105 but keeps banking while the raw start holds its own request, so
    /// what these still buy there is 108: no live optical stream that nothing reads.
    static let leanRawCaptureCommands: [(command: WhoopCommand, payload: [UInt8])] = [
        (.enableOpticalData, [0x01, 0x00]),   // 107 optical session saving off
        (.toggleOpticalLive, [0x01, 0x00]),   // 108 optical live transport off
        (.toggleIMUSaving, [0x01, 0x00]),     // 105 IMU session saving off (live IMU, 106, stays on)
    ]

    /// The always-open IMU store window this capture writes through, one per local device id. The store
    /// keeps a frame only while a window of its device covers it, which is what made recording session-only.
    static let windowPrefix = "activity-"
    static func windowId(deviceId: String) -> String { windowPrefix + deviceId }
    static func isActivityWindow(_ id: String) -> Bool { id.hasPrefix(windowPrefix) }

    static func mode(_ defaults: UserDefaults = .standard) -> ActivityImuCaptureMode {
        defaults.string(forKey: modeKey).flatMap(ActivityImuCaptureMode.init(rawValue:)) ?? defaultMode
    }

    static func setMode(_ mode: ActivityImuCaptureMode, _ defaults: UserDefaults = .standard) {
        defaults.set(mode.rawValue, forKey: modeKey)
    }

    /// Whether the raw stream should be armed now. `batteryPct` / `charging` describe the STRAP.
    static func wantsStream(mode: ActivityImuCaptureMode, now: Date, batteryPct: Int, charging: Bool,
                            pauseBatteryPct: Int = defaultPauseBatteryPct) -> Bool {
        guard mode != .off else { return false }
        if !charging && pauseBatteryPct > 0 && batteryPct <= pauseBatteryPct { return false }
        switch mode {
        case .off: return false
        case .continuous: return true
        case .partTime:
            let t = Int(now.timeIntervalSince1970.rounded(.down))
            let phase = ((t % partTimePeriodSeconds) + partTimePeriodSeconds) % partTimePeriodSeconds
            return phase < partTimeOnSeconds
        }
    }
}

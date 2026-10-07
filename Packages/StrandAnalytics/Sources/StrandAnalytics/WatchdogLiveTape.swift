import Foundation
import WhoopProtocol

/// Honest live HR/RR ingest for Watchdog. A leftover on-screen BPM is not a new sample.
public enum WatchdogLiveTape: Sendable {
    /// Append only when the strap produced a packet newer than the last ring timestamp.
    /// `packetUnix` must advance on every real HR packet, including unchanged bpm (no UI drag).
    public static func hrSample(lastRingTs: Int?, packetUnix: Int?, packetBpm: Int?) -> HRSample? {
        guard let t = packetUnix, let bpm = packetBpm, (30...220).contains(bpm) else { return nil }
        if let last = lastRingTs, t <= last { return nil }
        return HRSample(ts: t, bpm: bpm)
    }

    public static func rrSample(lastSeq: Int, currentSeq: Int, lastRingTs: Int?,
                                packetUnix: Int?, rrMs: Int?) -> RRInterval? {
        guard currentSeq != lastSeq else { return nil }
        guard let rrMs, rrMs > 250, rrMs < 3000 else { return nil }
        let t = packetUnix ?? lastRingTs.map { $0 + 1 }
        guard let t else { return nil }
        if let last = lastRingTs, t <= last { return nil }
        return RRInterval(ts: t, rrMs: rrMs)
    }

    public static func isFresh(packetUnix: Int?, now: Int, freshnessSeconds: Int) -> Bool {
        guard let t = packetUnix else { return false }
        return now - t <= freshnessSeconds
    }

    /// Device wrist-off wins. A leftover 2A37 packet clock cannot clear WRIST_OFF.
    public static func wristOff(deviceOff: Bool, freshLiveHR: Bool) -> Bool {
        _ = freshLiveHR
        return deviceOff
    }
}

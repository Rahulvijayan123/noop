import Foundation
import WhoopProtocol

/// Honest live HR/RR ingest for Watchdog. A leftover on-screen BPM is not a new sample.
public enum WatchdogLiveTape: Sendable {
    /// Plausible single R-R interval bounds (ms), exclusive.
    public static let rrMinMs = 250
    public static let rrMaxMs = 3000

    /// Append only when the strap produced a packet newer than the last ring timestamp.
    /// `packetUnix` must advance on every real HR packet, including unchanged bpm (no UI drag).
    public static func hrSample(lastRingTs: Int?, packetUnix: Int?, packetBpm: Int?) -> HRSample? {
        guard let t = packetUnix, let bpm = packetBpm, (30...220).contains(bpm) else { return nil }
        if let last = lastRingTs, t <= last { return nil }
        return HRSample(ts: t, bpm: bpm)
    }

    /// Legacy single-beat ingest (`rr.last` of a packet). Kept for callers that hold one beat; the Watchdog
    /// ring uses `rrBeats`, which keeps every interval of the packet.
    public static func rrSample(lastSeq: Int, currentSeq: Int, lastRingTs: Int?,
                                packetUnix: Int?, rrMs: Int?) -> RRInterval? {
        guard currentSeq != lastSeq else { return nil }
        guard let rrMs, rrMs > rrMinMs, rrMs < rrMaxMs else { return nil }
        let t = packetUnix ?? lastRingTs.map { $0 + 1 }
        guard let t else { return nil }
        if let last = lastRingTs, t <= last { return nil }
        return RRInterval(ts: t, rrMs: rrMs)
    }

    /// Every plausible interval of one live R-R packet, in emission order.
    ///
    /// A standard-BLE packet carries the beats that ended since the previous notification, oldest first, and
    /// arrives just after the last of them. Beat `i` therefore ended about `Σ rr[i+1…]` ms before receipt, so it
    /// is stamped `receivedUnix − round(that) s` (the receipt second is itself truncated), but never before the
    /// newest beat already in the ring (arrival order decides ordering). Beats sharing a second get consecutive `seq`, continuing from a ring beat already in
    /// that second, so `(ts, rrMs, seq)` stays a unique identity and two equal beats in one second are both kept.
    /// (The old ingest kept `rr.last` only and rejected a second beat in the same second.) Implausible values
    /// are skipped but still occupy their time, since the strap did emit something there.
    public static func rrBeats(packet: [Int], receivedUnix: Int, lastRingBeat: RRInterval?) -> [RRInterval] {
        guard !packet.isEmpty else { return [] }
        var stamps = Array(repeating: receivedUnix, count: packet.count)
        var after = 0  // ms of this packet that ended after beat i
        for i in stride(from: packet.count - 1, through: 0, by: -1) {
            stamps[i] = receivedUnix - Int((Double(after) / 1000).rounded())
            after += max(0, packet[i])
        }
        var out: [RRInterval] = []
        out.reserveCapacity(packet.count)
        var lastTs = lastRingBeat?.ts
        var lastSeq = lastRingBeat?.seq ?? -1
        for (i, rrMs) in packet.enumerated() {
            guard rrMs > rrMinMs, rrMs < rrMaxMs else { continue }
            var ts = stamps[i]
            if let floor = lastTs, ts < floor { ts = floor }
            let seq = (ts == lastTs) ? lastSeq + 1 : 0
            out.append(RRInterval(ts: ts, rrMs: rrMs, seq: seq))
            lastTs = ts
            lastSeq = seq
        }
        return out
    }

    public static func isFresh(packetUnix: Int?, now: Int, freshnessSeconds: Int) -> Bool {
        guard let t = packetUnix else { return false }
        return now - t <= freshnessSeconds
    }

    /// Device wrist-off wins. A leftover 2A37 packet clock cannot clear WRIST_OFF.
    /// The Watchdog window uses `WatchdogWearEvidence.openWristOff`, which also looks past the 30-minute window.
    public static func wristOff(deviceOff: Bool, freshLiveHR: Bool) -> Bool {
        _ = freshLiveHR
        return deviceOff
    }
}

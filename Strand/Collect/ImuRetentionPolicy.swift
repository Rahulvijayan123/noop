import Foundation

/// Pure NOOPIMU2 retention policy (C8 Fix G): bounded eviction so continuous raw-IMU capture
/// cannot grow without bound. Conservative, documented defaults; a pure value type so the policy
/// is unit-testable without the file system.
///
/// Two independent, conservative triggers:
///  1. Age: a COMPLETED session whose last recorded second is older than `maxAgeDays` is expired
///     and evicted. A completed session that never captured a second is also evicted.
///  2. Size: when the total NOOPIMU2 footprint exceeds `maxTotalBytes`, the OLDEST completed
///     sessions are evicted (oldest-first by last recorded second) until the footprint is back
///     under the cap.
/// An active (open-ended) session is never evicted WHOLE, but on the P2-4 capture cadence its
/// expired SEGMENTS (30-minute buckets) that are fully before the active window are reaped via
/// `activeSessionSegmentDecision` — so continuous capture still cannot grow without bound.
///
/// "Fully-uploaded" is not tracked here yet: upload-ack state lands with the ios-upload source
/// (PushSnapshotSource.acknowledgeBinary), and once it exists the age trigger can be tightened to
/// "uploaded OR older than maxAgeDays". Keeping the age rule conservative (30 days) means an
/// un-uploaded session still gets a month of grace before eviction.
struct ImuRetentionPolicy: Equatable {
    let maxAgeDays: Int
    let maxTotalBytes: Int64

    /// Conservative defaults: 30 days of grace for completed sessions, 1 GiB total cap.
    /// ~104 MB/day for six-axis int16 @100 Hz before compression (spec §6), so the cap holds
    /// roughly a week of fully dense capture plus compression slack.
    static let `default` = ImuRetentionPolicy(maxAgeDays: 30, maxTotalBytes: 1_073_741_824)

    /// The age rule for the always-on activity capture (`ActivityImuCapture`). It records far more than a
    /// Raw Data session (up to ~50 MB a day on disk when continuous) and is only kept until the object lane
    /// has uploaded it, which normally takes minutes, so it gets a week of grace instead of a month. The size
    /// cap is the shared one.
    var activityCapture: ImuRetentionPolicy {
        ImuRetentionPolicy(maxAgeDays: min(maxAgeDays, 7), maxTotalBytes: maxTotalBytes)
    }

    enum Decision: Equatable {
        case keep
        case evict(reason: String)
    }

    /// Age + completeness rule for ONE session. `endTs` is the session's last recorded second
    /// (nil when it never stored one). Active sessions are always kept.
    func decision(active: Bool, endTs: Int64?, now: Int64) -> Decision {
        guard !active else { return .keep }
        guard let endTs else { return .evict(reason: "completed session with no captured seconds") }
        if now - endTs > Int64(maxAgeDays) * 86_400 {
            return .evict(reason: "expired (last data \(now - endTs)s ago, older than \(maxAgeDays) days)")
        }
        return .keep
    }

    /// Size rule: given the TOTAL footprint and the COMPLETED (never active) sessions with their
    /// on-disk bytes, return the ids to evict oldest-first until the total is at most
    /// `maxTotalBytes`. Empty when the footprint is already under the cap.
    func evictionsForSizeCap(totalBytes: Int64,
                             completed: [(id: String, endTs: Int64?, bytes: Int64)]) -> [String] {
        guard totalBytes > maxTotalBytes else { return [] }
        let ordered = completed.sorted { a, b in
            (a.endTs ?? Int64.min, a.id) < (b.endTs ?? Int64.min, b.id)
        }
        var remaining = totalBytes
        var evicted: [String] = []
        for candidate in ordered where remaining > maxTotalBytes {
            evicted.append(candidate.id)
            remaining -= candidate.bytes
        }
        return evicted
    }

    /// P2-4: active-session SEGMENT rule. Continuous capture keeps one open-ended session for
    /// weeks, so whole-session age/size rules never touch it; eviction must work at the
    /// 30-minute segment (bucket) granularity. A segment is protected when ANY of its seconds is
    /// inside the active window (the bucket currently being written) or newer than the retention
    /// floor; it may be evicted only when it is BOTH fully expired AND fully before the active
    /// window. `segmentEndTs` is the segment's NOMINAL end second (bucketStart + segmentSeconds - 1)
    /// — conservative, since a partial file's real end is earlier. "Fully uploaded" is still not
    /// tracked here, so the age floor stays the conservative 30-day grace for un-uploaded data.
    func activeSessionSegmentDecision(segmentEndTs: Int64, activeWindowStartTs: Int64, now: Int64) -> Decision {
        guard now - segmentEndTs > Int64(maxAgeDays) * 86_400 else {
            return .keep   // touches seconds newer than the retention floor
        }
        guard segmentEndTs < activeWindowStartTs else {
            return .keep   // touches the active window (the bucket being written)
        }
        return .evict(reason: "expired (\(now - segmentEndTs)s ago) and fully before the active window (start \(activeWindowStartTs))")
    }
}

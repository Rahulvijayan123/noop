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
/// Both triggers only ever take data the object lane has UPLOADED (its durable cursor, advanced on a verified
/// receipt, has passed it; see `ImuUploadWatermarks`) in a build that has a cloud to upload to. Raw IMU that has
/// not reached the server yet is kept whatever its age: downstream models must never lose it. The one exception
/// is `hardCeilingBytes`, a last resort against filling the phone, which evicts the oldest data even when it was
/// never uploaded and says so loudly.
struct ImuRetentionPolicy: Equatable {
    let maxAgeDays: Int
    let maxTotalBytes: Int64
    /// The footprint at which even data not yet uploaded is evicted, oldest first. Never below `maxTotalBytes`.
    let hardCeilingBytes: Int64

    /// `hardCeilingBytes` defaults to four times the size cap.
    init(maxAgeDays: Int, maxTotalBytes: Int64, hardCeilingBytes: Int64? = nil) {
        self.maxAgeDays = maxAgeDays
        self.maxTotalBytes = maxTotalBytes
        self.hardCeilingBytes = max(hardCeilingBytes ?? maxTotalBytes * 4, maxTotalBytes)
    }

    /// Conservative defaults: 30 days of grace for completed sessions, 1 GiB total cap.
    /// ~104 MB/day for six-axis int16 @100 Hz before compression (spec §6), so the cap holds
    /// roughly a week of fully dense capture plus compression slack. The hard ceiling (4 GiB) holds about
    /// eleven weeks of continuous activity capture that could not be uploaded.
    static let `default` = ImuRetentionPolicy(maxAgeDays: 30, maxTotalBytes: 1_073_741_824)

    /// The age rule for the always-on activity capture (`ActivityImuCapture`). It records far more than a
    /// Raw Data session (up to ~50 MB a day on disk when continuous) and is only kept until the object lane
    /// has uploaded it, which normally takes minutes, so it gets a week of grace instead of a month. The size
    /// cap and the hard ceiling are the shared ones.
    var activityCapture: ImuRetentionPolicy {
        ImuRetentionPolicy(maxAgeDays: min(maxAgeDays, 7), maxTotalBytes: maxTotalBytes,
                           hardCeilingBytes: hardCeilingBytes)
    }

    /// Whether data whose last second is `endTs` is known to be on the server, given the object lane's upload
    /// watermark for its strap. No data (`endTs` nil) is trivially uploaded; no watermark means nothing is.
    static func isUploaded(endTs: Int64?, uploadedThrough: Int64?) -> Bool {
        guard let endTs else { return true }
        guard let uploadedThrough else { return false }
        return uploadedThrough >= endTs
    }

    /// Last-resort rule: when the footprint is over `hardCeilingBytes`, the units (completed sessions or
    /// expired-able segments) to evict, oldest first by their last second, until it is back under. Uploaded or
    /// not. Empty under the ceiling.
    func evictionsForHardCeiling(totalBytes: Int64,
                                 candidates: [(id: String, endTs: Int64?, bytes: Int64)]) -> [String] {
        guard totalBytes > hardCeilingBytes else { return [] }
        let ordered = candidates.sorted { a, b in
            (a.endTs ?? Int64.min, a.id) < (b.endTs ?? Int64.min, b.id)
        }
        var remaining = totalBytes
        var evicted: [String] = []
        for candidate in ordered where remaining > hardCeilingBytes {
            evicted.append(candidate.id)
            remaining -= candidate.bytes
        }
        return evicted
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

/// How far the object lane has uploaded each strap's raw IMU, by the LOCAL id the IMU store files it under.
///
/// The lane's durable cursor (`ImuPushProgressStore`, advanced only after a verified receipt) is keyed by the
/// cloud id and read asynchronously; IMU retention runs synchronously on the capture path, so the lane copies
/// each pass's cursor here and retention reads the copy. Kept in the preferences so a relaunch knows it before
/// the first pass, and only ever moved forward.
final class ImuUploadWatermarks: @unchecked Sendable {
    static let shared = ImuUploadWatermarks(defaults: .standard)

    private let defaults: UserDefaults
    private let lock = NSLock()
    private static let key = "noop.imu.uploadedThrough.v1"

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The last second of `localDeviceId`'s raw IMU known to be on the server, or nil when none is.
    func uploadedThrough(localDeviceId: String) -> Int64? {
        lock.lock(); defer { lock.unlock() }
        return stored()[localDeviceId.lowercased()]
    }

    func record(localDeviceId: String, through second: Int64) {
        let key = localDeviceId.lowercased()
        lock.lock(); defer { lock.unlock() }
        var marks = stored()
        guard second > (marks[key] ?? Int64.min) else { return }
        marks[key] = second
        defaults.set(marks.mapValues { NSNumber(value: $0) }, forKey: Self.key)
    }

    private func stored() -> [String: Int64] {
        guard let raw = defaults.dictionary(forKey: Self.key) else { return [:] }
        return raw.compactMapValues { ($0 as? NSNumber)?.int64Value }
    }
}

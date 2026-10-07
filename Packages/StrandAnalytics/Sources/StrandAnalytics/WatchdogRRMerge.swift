import Foundation
import WhoopProtocol

/// One beat train for the Watchdog window: the stored beats and the live ring, de-duplicated before HRV.
///
/// Why this exists. The window used to be `stored + liveRing` with no de-duplication. The live ring holds the
/// same physical beats the strap later banks (a WHOOP 5 standard-BLE beat has an exact-value v18 twin stamped
/// 1–4 s earlier on 87.7 % of beats), so every live beat that overlapped history was counted twice. Successive
/// differences across a twin are ~0, which biased RMSSD down to ~0.7–0.8×, and beat coverage read ~2.
///
/// The rules, in order:
/// 1. Stored beats stay on ONE transport. `store.rrIntervals` already pins a WHOOP 5 window to the lowest of
///    {5, 7} and a WHOOP 4 window per UTC hour, and drops `tsSuspect` rows; this re-checks it so a merged or
///    legacy read can never splice two transports (there is no shared beat identity across transports).
/// 2. Within one transport a beat's identity is `(ts, rrMs, seq)` (the storage key without the device). `ord`
///    is never used: it is NULL on most rows.
/// 3. Live beats are spliced only after `maxStoredTs + liveSpliceGuardSeconds`: a live beat is stamped with
///    receipt time, 1–4 s after the stored copy of the same beat.
/// 4. 500 ms and 333 ms are transport fill values below 100 bpm, not beats. The concurrent heart rate decides;
///    when no heart-rate sample is near, the neighbouring beats' median interval stands in. Unknown keeps the beat.
/// 5. A second holding more than 3000 ms of R-R is a receipt-time pileup. Flagged (POOR evidence), not removed.
public enum WatchdogRRMerge {
    public static let liveSpliceGuardSeconds = 4
    public static let fillValuesMs: Set<Int> = [500, 333]
    /// A fill value is only a fill below this concurrent heart rate.
    public static let fillMaxBpm = 100.0
    public static let pileupMsPerSecond = 3000
    /// How far (s) a concurrent heart-rate sample may sit from a beat.
    public static let hrToleranceSeconds = 2
    /// Neighbouring beats within this many seconds estimate the local heart rate when no HR sample is near.
    public static let localRateSeconds = 5
    /// `transport` value for stored beats that carry no source label.
    public static let unlabelledTransport = 0

    public struct Result: Equatable, Sendable {
        /// Time-ordered beats; within one second the stored emission order (then the live packet order) is kept.
        public var beats: [RRInterval]
        /// Same-identity copies, live twins of stored beats, and beats on a second stored transport.
        public var duplicatesRemoved: Int
        /// Of `duplicatesRemoved`: stored beats dropped because another transport was pinned.
        public var otherTransportDropped: Int
        /// Of `duplicatesRemoved`: live beats at or before the splice cut.
        public var liveTwinsDropped: Int
        public var fillRejected: Int
        public var pileupSeconds: [Int]
        /// The pinned stored transport (`RRSourceChannel.rawValue`; `unlabelledTransport` for unlabelled rows),
        /// the dominant one when a WHOOP 4 window spans two hourly choices. nil = no stored beats.
        public var transport: Int?
        /// Live beats were spliced only after this second. nil = no live beat was spliced.
        public var splicedAfterTs: Int?
        public var liveSpliced: Int

        public init(beats: [RRInterval] = [], duplicatesRemoved: Int = 0, otherTransportDropped: Int = 0,
                    liveTwinsDropped: Int = 0, fillRejected: Int = 0, pileupSeconds: [Int] = [],
                    transport: Int? = nil, splicedAfterTs: Int? = nil, liveSpliced: Int = 0) {
            self.beats = beats; self.duplicatesRemoved = duplicatesRemoved
            self.otherTransportDropped = otherTransportDropped; self.liveTwinsDropped = liveTwinsDropped
            self.fillRejected = fillRejected; self.pileupSeconds = pileupSeconds; self.transport = transport
            self.splicedAfterTs = splicedAfterTs; self.liveSpliced = liveSpliced
        }
    }

    private struct BeatKey: Hashable { let ts: Int; let rrMs: Int; let seq: Int }

    /// - Parameters:
    ///   - stored: beats from the store for ONE device id, in read order.
    ///   - live: the live ring (receipt-time stamps), in arrival order.
    ///   - hrBpmAt: concurrent heart rate for a unix second, or nil when unknown.
    public static func merge(stored: [RRInterval], live: [RRInterval],
                             hrBpmAt: (Int) -> Double?) -> Result {
        var out = Result()

        // 1. One stored transport.
        let pinned = pinTransport(stored)
        out.transport = pinned.transport
        out.otherTransportDropped = pinned.dropped

        // 2. Identity de-duplication inside the stored train.
        var seen = Set<BeatKey>()
        var storedKept: [RRInterval] = []
        storedKept.reserveCapacity(pinned.beats.count)
        var identityDupes = 0
        for beat in pinned.beats {
            if seen.insert(BeatKey(ts: beat.ts, rrMs: beat.rrMs, seq: beat.seq)).inserted {
                storedKept.append(beat)
            } else {
                identityDupes += 1
            }
        }
        storedKept = stableSortedByTs(storedKept)

        // 3. Live splice after the stored train (plus its own identity de-duplication).
        let cut: Int? = storedKept.last.map { $0.ts + liveSpliceGuardSeconds }
        var liveSeen = Set<BeatKey>()
        var liveKept: [RRInterval] = []
        for beat in stableSortedByTs(live) {
            guard liveSeen.insert(BeatKey(ts: beat.ts, rrMs: beat.rrMs, seq: beat.seq)).inserted else {
                identityDupes += 1
                continue
            }
            if let cut, beat.ts <= cut {
                out.liveTwinsDropped += 1
                continue
            }
            liveKept.append(beat)
        }

        // 4. Fill values, judged against the concurrent heart rate.
        let combined = storedKept + liveKept
        let storedCount = storedKept.count
        var kept: [RRInterval] = []
        kept.reserveCapacity(combined.count)
        var liveSurvivors = 0
        for (i, beat) in combined.enumerated() {
            if fillValuesMs.contains(beat.rrMs) {
                let bpm = hrBpmAt(beat.ts) ?? localBpm(around: i, in: combined)
                if let bpm, bpm < fillMaxBpm {
                    out.fillRejected += 1
                    continue
                }
            }
            kept.append(beat)
            if i >= storedCount { liveSurvivors += 1 }
        }
        out.liveSpliced = liveSurvivors
        if liveSurvivors > 0 {
            out.splicedAfterTs = cut ?? ((liveKept.first?.ts ?? 0) - 1)
        }

        // 5. Pileups.
        out.pileupSeconds = pileupSeconds(kept)
        out.duplicatesRemoved = identityDupes + out.otherTransportDropped + out.liveTwinsDropped
        out.beats = kept
        return out
    }

    /// Heart rate at a second from samples within `hrToleranceSeconds` (nearest wins; exact second first).
    public static func hrLookup(_ hr: [HRSample]) -> (Int) -> Double? {
        var byTs: [Int: Double] = [:]
        byTs.reserveCapacity(hr.count)
        for sample in hr where (30...220).contains(sample.bpm) {
            byTs[sample.ts] = Double(sample.bpm)
        }
        return { ts in
            if let v = byTs[ts] { return v }
            for d in 1...hrToleranceSeconds {
                if let v = byTs[ts - d] { return v }
                if let v = byTs[ts + d] { return v }
            }
            return nil
        }
    }

    /// Seconds whose summed R-R exceeds `pileupMsPerSecond`, ascending.
    public static func pileupSeconds(_ beats: [RRInterval]) -> [Int] {
        var perSecond: [Int: Int] = [:]
        for beat in beats { perSecond[beat.ts, default: 0] += beat.rrMs }
        return perSecond.filter { $0.value > pileupMsPerSecond }.keys.sorted()
    }

    // MARK: - Internals

    /// Median-interval heart rate of the non-fill beats within `localRateSeconds` of beat `index`.
    static func localBpm(around index: Int, in beats: [RRInterval]) -> Double? {
        let ts = beats[index].ts
        var neighbours: [Int] = []
        var j = index - 1
        while j >= 0, ts - beats[j].ts <= localRateSeconds {
            if !fillValuesMs.contains(beats[j].rrMs) { neighbours.append(beats[j].rrMs) }
            j -= 1
        }
        j = index + 1
        while j < beats.count, beats[j].ts - ts <= localRateSeconds {
            if !fillValuesMs.contains(beats[j].rrMs) { neighbours.append(beats[j].rrMs) }
            j += 1
        }
        guard neighbours.count >= 2 else { return nil }
        let sorted = neighbours.sorted()
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? Double(sorted[mid - 1] + sorted[mid]) / 2 : Double(sorted[mid])
        guard median > 0 else { return nil }
        return 60_000 / median
    }

    /// Sort by second, keeping the incoming order inside a second (the stored emission order / the live
    /// packet order). Sorting by value inside a second would corrupt successive differences.
    static func stableSortedByTs(_ beats: [RRInterval]) -> [RRInterval] {
        if zip(beats, beats.dropFirst()).allSatisfy({ $0.ts <= $1.ts }) { return beats }
        return beats.enumerated()
            .sorted { $0.element.ts == $1.element.ts ? $0.offset < $1.offset : $0.element.ts < $1.element.ts }
            .map(\.element)
    }

    static func transportCode(_ beat: RRInterval) -> Int {
        beat.srcChannel?.rawValue ?? unlabelledTransport
    }

    /// WHOOP 4 sources in the store's hourly provenance order (`rrIntervals`): history, realtime, standard,
    /// unlabelled.
    static let whoop4Priority: [Int: Int] = [
        RRSourceChannel.whoop4Historical.rawValue: 1,
        RRSourceChannel.whoop4Realtime.rawValue: 2,
        RRSourceChannel.whoop4Standard.rawValue: 3,
        unlabelledTransport: 4,
    ]

    static func pinTransport(_ beats: [RRInterval]) -> (beats: [RRInterval], transport: Int?, dropped: Int) {
        guard !beats.isEmpty else { return ([], nil, 0) }
        var counts: [Int: Int] = [:]
        for beat in beats { counts[transportCode(beat), default: 0] += 1 }
        if counts.count == 1 { return (beats, counts.keys.first, 0) }

        let codes = Set(counts.keys)
        let whoop5Scored: Set<Int> = [RRSourceChannel.whoop5Historical.rawValue,
                                      RRSourceChannel.whoop5Standard.rawValue]
        let keep: (RRInterval) -> Bool
        if codes.isSubset(of: Set(whoop4Priority.keys)) {
            // WHOOP 4: one source per UTC hour, best provenance present in that hour (mirrors the store).
            var bestByHour: [Int: Int] = [:]
            for beat in beats {
                let hour = beat.ts / 3600
                let p = whoop4Priority[transportCode(beat)] ?? Int.max
                bestByHour[hour] = min(bestByHour[hour] ?? Int.max, p)
            }
            keep = { beat in
                (whoop4Priority[transportCode(beat)] ?? Int.max) == bestByHour[beat.ts / 3600]
            }
        } else if let lowest = codes.intersection(whoop5Scored).min() {
            // WHOOP 5: the lowest of {5, 7} present, for the whole window.
            keep = { transportCode($0) == lowest }
        } else {
            // Anything else: the fullest single transport (lowest code on a tie, deterministic).
            let best = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
            keep = { transportCode($0) == best }
        }
        let kept = beats.filter(keep)
        var keptCounts: [Int: Int] = [:]
        for beat in kept { keptCounts[transportCode(beat), default: 0] += 1 }
        let dominant = keptCounts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        return (kept, dominant, beats.count - kept.count)
    }
}

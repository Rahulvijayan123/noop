import Foundation
import WhoopStore

// Mapping between the typed interval model and the plain-string rows `WhoopStore` persists. `WhoopStore`
// does not know the taxonomy; this file is the only place the two vocabularies meet, so a class renamed
// here and not in the migration (or the reverse) is one grep away.

extension ActivityContextInterval {
    /// The row to persist for this interval.
    public var storeRow: ActivityContextIntervalRow {
        ActivityContextIntervalRow(
            startTs: start, endTs: end, activityClass: activityClass.rawValue, confidence: confidence,
            runnerUp: runnerUp?.rawValue, runnerUpConfidence: runnerUpConfidence, evidenceQuality: evidenceQuality,
            posture: posture?.rawValue, locomotion: locomotion?.rawValue, armBehavior: armBehavior?.rawValue,
            sleepState: sleep.rawValue, wearState: wear.rawValue, intensity: intensity,
            stepTicks: stepTicks, cadenceSpm: cadenceSpm, hrSamples: hrSamples, hrMean: hrMean,
            hrMin: hrMin, hrMax: hrMax, hrSlope: hrSlope, rmssd: rmssd, rrBeats: rrBeats,
            rrDiffSqSumMs2: rrDiffSqSumMs2, rrDiffCount: rrDiffCount,
            respRateBpm: respRateBpm, respBreaths: respBreaths)
    }

    /// Rebuilds an interval from a stored row. A code this build does not recognise (a row written by a
    /// newer taxonomy) reads as `unknown` rather than dropping the row, so older builds still account for
    /// the time even when they cannot name it.
    public init(row: ActivityContextIntervalRow) {
        self.init(
            start: row.startTs, end: row.endTs,
            activityClass: ActivityClass(rawValue: row.activityClass) ?? .unknown,
            confidence: row.confidence,
            runnerUp: row.runnerUp.flatMap(ActivityClass.init(rawValue:)),
            runnerUpConfidence: row.runnerUpConfidence, evidenceQuality: row.evidenceQuality,
            posture: row.posture.flatMap(PostureClass.init(rawValue:)),
            locomotion: row.locomotion.flatMap(LocomotionClass.init(rawValue:)),
            armBehavior: row.armBehavior.flatMap(ArmBehaviorClass.init(rawValue:)),
            sleep: SleepContextState(rawValue: row.sleepState) ?? .unknown,
            wear: WearContextState(rawValue: row.wearState) ?? .unknown,
            intensity: row.intensity, stepTicks: row.stepTicks, cadenceSpm: row.cadenceSpm,
            hrSamples: row.hrSamples, hrMean: row.hrMean, hrMin: row.hrMin, hrMax: row.hrMax,
            hrSlope: row.hrSlope, rmssd: row.rmssd, rrBeats: row.rrBeats,
            rrDiffSqSumMs2: row.rrDiffSqSumMs2, rrDiffCount: row.rrDiffCount,
            respRateBpm: row.respRateBpm, respBreaths: row.respBreaths)
    }
}

/// How a decoded day becomes the rows `WhoopStore.replaceActivityContext` writes.
public enum ActivityContextPersistence {
    /// How long after a local day ends its context is still expected to change: the night that runs over
    /// midnight is detected and staged the next morning, and a day decoded before then reads that night's
    /// first hours without it. A day derived (or confirmed) at least this long after it closed is `final`.
    public static let sleepSettleS = 12 * 3_600

    /// The ledger row for a day built from `document`, stamped with the versions and the derivation key that
    /// produced it.
    ///
    /// `dayEnd` is the end of the LOCAL calendar day when the caller knows it. The document's own end is
    /// where decoding stopped (now, for a day in progress; 24 h after the start otherwise), which is not the
    /// local day on a daylight-saving change and not a stable bound for a day still being written.
    ///
    /// `configTag` is the decoder config's tag (`ActivityDecoderConfig.cacheTag`, plus anything else the
    /// caller decodes with that the config does not name); `inputFingerprint` the witness of the day's input
    /// the caller planned the day from. `writtenAt` (default `computedAt`) decides finality.
    public static func dayRow(day: String, document: ActivityContextDayDocument, intervalCount: Int,
                              computedAt: Int, dayEnd: Int? = nil, configTag: String? = nil,
                              inputFingerprint: String? = nil, writtenAt: Int? = nil) -> ActivityContextDayRow {
        let end = dayEnd ?? document.dayEnd
        let v = document.versions
        return ActivityContextDayRow(
            day: day, dayStart: document.dayStart, dayEnd: end,
            taxonomyVersion: ActivityClassVersions.taxonomy,
            decoderVersion: v.decoder, ontologyVersion: v.ontology,
            intervalVersion: ActivityClassVersions.interval,
            dataThrough: document.dataThrough.map { min($0, end) }, observedSeconds: document.observedSeconds,
            intervalCount: intervalCount, computedAt: computedAt,
            featureSchema: v.featureSchema, encoderId: v.encoderId, encoderVersion: v.encoderVersion,
            motionHeads: v.motionHeads, gaitQuality: v.gaitQuality, configTag: configTag,
            inputFingerprint: inputFingerprint,
            finality: finality(sleepKnownOutsideSessions: document.sleepKnownOutsideSessions, dayEnd: end,
                               at: writtenAt ?? computedAt),
            decodeMode: ActivityContextDayRow.causal,
            sleepKnownOutsideSessions: document.sleepKnownOutsideSessions)
    }

    /// `final` once the day was decoded as a finished day (time outside logged sleep read as awake, not unknown)
    /// and `at` is at least `sleepSettleS` past its end; `provisional` otherwise.
    public static func finality(sleepKnownOutsideSessions: Bool, dayEnd: Int, at: Int) -> String {
        sleepKnownOutsideSessions && at >= dayEnd + sleepSettleS
            ? ActivityContextDayRow.final : ActivityContextDayRow.provisional
    }

    /// The decoder's transition events that belong to `[from, to)`, as rows for `activityContextTransition`.
    /// The store keys an event by `(ts, kind)`; two flags of one kind in the same second keep the likelier.
    public static func transitionRows(_ events: [ActivityTransitionEvent], from: Int, to: Int,
                                      decoderVersion: String) -> [ActivityContextTransitionRow] {
        var best: [String: ActivityTransitionEvent] = [:]
        for e in events where e.ts >= from && e.ts < to {
            let key = "\(e.ts)|\(e.kind.rawValue)"
            if let kept = best[key], kept.probability >= e.probability { continue }
            best[key] = e
        }
        return best.values
            .sorted { ($0.ts, $0.kind.rawValue) < ($1.ts, $1.kind.rawValue) }
            .map { ActivityContextTransitionRow(ts: $0.ts, kind: $0.kind.rawValue, probability: $0.probability,
                                                decoderVersion: decoderVersion) }
    }

    /// The part of `intervals` that belongs to `[from, to)`: whole intervals inside it, the crossing ones cut to
    /// it, everything outside dropped. The decoder's day is `dayStart + 86,400 s`, which on a daylight-saving
    /// day is not the local day, and one day's rows must never reach into the next day's range (replacing a
    /// day clears its range). Statistics are kept as measured: only the bounds move.
    public static func clipped(_ intervals: [ActivityContextInterval], from: Int, to: Int) -> [ActivityContextInterval] {
        guard to > from else { return [] }
        return intervals.compactMap { iv in
            guard iv.end > from, iv.start < to else { return nil }
            var cut = iv
            cut.start = max(iv.start, from)
            cut.end = min(iv.end, to)
            return cut
        }
    }

    /// One timeline from context read under several device ids. `lists` are in priority order (the active strap
    /// first): an interval that overlaps one already accepted from a higher-priority list is dropped, so no
    /// instant is described twice. Each day is stored under a single owner, so this only matters where owners
    /// changed mid-range (a strap swap, a time-zone change); the result is sorted and non-overlapping.
    public static func merged(_ lists: [[ActivityContextInterval]]) -> [ActivityContextInterval] {
        var accepted: [ActivityContextInterval] = []
        for list in lists {
            var additions: [ActivityContextInterval] = []
            for iv in list.sorted(by: { $0.start < $1.start }) where !overlaps(iv, accepted) {
                additions.append(iv)
            }
            if !additions.isEmpty { accepted = (accepted + additions).sorted { $0.start < $1.start } }
        }
        return accepted
    }

    /// `sorted` is non-overlapping and ordered by start, so only the last interval starting before `iv` ends can overlap it.
    private static func overlaps(_ iv: ActivityContextInterval, _ sorted: [ActivityContextInterval]) -> Bool {
        var lo = 0, hi = sorted.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].start < iv.end { lo = mid + 1 } else { hi = mid }
        }
        return lo > 0 && sorted[lo - 1].end > iv.start
    }

    /// Whether a stored day was derived by the current taxonomy, decoder, ontology, interval rules and feature
    /// schema — and, when the caller passes the config tag it decodes with now, by that config (heart-rate
    /// reference, gait lane, personal profile). A day that fails this is derived again from the sample streams,
    /// through the materializer's backlog limit. A row written before the ledger recorded its feature schema
    /// (pre-v50) fails it once.
    public static func isCurrent(_ ledger: ActivityContextDayRow, configTag: String? = nil) -> Bool {
        hasCurrentVersions(ledger)
            && ledger.featureSchema == ActivityContextVersions.featureSchema
            && (configTag == nil || ledger.configTag == configTag)
    }

    /// The four rule-set versions only: whether the day's labels mean what this build's labels mean.
    static func hasCurrentVersions(_ ledger: ActivityContextDayRow) -> Bool {
        ledger.taxonomyVersion == ActivityClassVersions.taxonomy
            && ledger.decoderVersion == ActivityContextVersions.decoder
            && ledger.ontologyVersion == ActivityContextVersions.ontology
            && ledger.intervalVersion == ActivityClassVersions.interval
    }

    /// How a stored day may be served to a reader that has not re-derived it.
    public enum ServingStatus: String, Equatable, Sendable {
        /// Derived by the current rules and config.
        case current
        /// Same labels and rules, but an older derivation key (config tag, feature schema, or a row from before
        /// the key was recorded): usable, flagged, and queued for re-derivation.
        case refreshing
        /// Derived by another taxonomy / decoder / ontology / interval rule set: its labels cannot be read as this
        /// build's. Not served.
        case stale
    }

    public static func servingStatus(_ ledger: ActivityContextDayRow, configTag: String? = nil) -> ServingStatus {
        guard hasCurrentVersions(ledger) else { return .stale }
        return isCurrent(ledger, configTag: configTag) ? .current : .refreshing
    }
}

extension ActivityContextLookup {
    /// A lookup over intervals read back from the store.
    public init(rows: [ActivityContextIntervalRow]) {
        self.init(intervals: rows.map(ActivityContextInterval.init(row:)))
    }
}

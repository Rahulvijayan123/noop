import Foundation
import WhoopProtocol
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
            respRateBpm: respRateBpm, respBreaths: respBreaths,
            inBed: inBed, uncertainty: uncertainty, experts: experts.map(Self.joined),
            transitionCount: transitionCount, absorbedSeconds: absorbedSeconds, precededByGapS: precededByGapS,
            settlingSeconds: settlingSeconds, absorbedClasses: absorbedClasses.map { Self.joined($0.map(\.rawValue)) },
            detail: detail?.rawValue, detailConfidence: detailConfidence, precedingClass: precedingClass?.rawValue,
            settledFromTs: settledFrom, hrMeanSettled: hrMeanSettled, hrSamplesSettled: hrSamplesSettled,
            rmssdSettled: rmssdSettled, rrDiffSqSumMs2Settled: rrDiffSqSumMs2Settled,
            rrDiffCountSettled: rrDiffCountSettled, derivation: derivation.rawValue)
    }

    /// A list column: codes joined by commas, "" for an empty list (recorded: none), NULL for nil (not recorded).
    static func joined(_ codes: [String]) -> String { codes.joined(separator: ",") }
    static func split(_ text: String) -> [String] {
        text.isEmpty ? [] : text.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }

    /// Rebuilds an interval from a stored row. A code this build does not recognise (a row written by a
    /// newer taxonomy) reads as `unknown` rather than dropping the row, so older builds still account for
    /// the time even when they cannot name it (an absorbed fragment's class likewise; an unknown detail or
    /// preceding class reads as not recorded). A NULL context column reads as nil: not recorded.
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
            respRateBpm: row.respRateBpm, respBreaths: row.respBreaths,
            inBed: row.inBed, uncertainty: row.uncertainty, experts: row.experts.map(Self.split),
            transitionCount: row.transitionCount,
            absorbedClasses: row.absorbedClasses.map { Self.split($0).map { ActivityClass(rawValue: $0) ?? .unknown } },
            absorbedSeconds: row.absorbedSeconds, precededByGapS: row.precededByGapS,
            settlingSeconds: row.settlingSeconds,
            detail: row.detail.flatMap(ActivityDetail.init(rawValue:)), detailConfidence: row.detailConfidence,
            precedingClass: row.precedingClass.flatMap(ActivityClass.init(rawValue:)),
            settledFrom: row.settledFromTs, hrMeanSettled: row.hrMeanSettled, hrSamplesSettled: row.hrSamplesSettled,
            rmssdSettled: row.rmssdSettled, rrDiffSqSumMs2Settled: row.rrDiffSqSumMs2Settled,
            rrDiffCountSettled: row.rrDiffCountSettled,
            // An unknown code is never read as causal (it must not reach a causal consumer).
            derivation: ActivityContextDerivation(rawValue: row.derivation) ?? .retrospective)
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
                              inputFingerprint: String? = nil, writtenAt: Int? = nil,
                              retrospectiveVersion: String? = nil) -> ActivityContextDayRow {
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
            sleepKnownOutsideSessions: document.sleepKnownOutsideSessions,
            retrospectiveVersion: retrospectiveVersion)
    }

    /// The retrospective intervals of a day (D8-10), clipped to `[from, to)`, or none when `finality` is not
    /// `final`: smoothing reads later seconds of the day, so it never describes a day that can still change, and
    /// it is never read by a causal consumer. Write them with `WhoopStore.replaceActivityContext(...,
    /// retrospective:)` and the ledger's `retrospectiveVersion = ActivityContextRetrospective.version`.
    public static func retrospectiveIntervals(document: ActivityContextDayDocument,
                                              events: [ActivityTransitionEvent]? = nil,
                                              hr: [HRSample] = [], steps: [StepSample] = [], rr: [RRInterval] = [],
                                              from: Int, to: Int, finality: String,
                                              config: ActivityContextRetrospective.Config = .init())
        -> [ActivityContextInterval] {
        guard finality == ActivityContextDayRow.final else { return [] }
        let built = ActivityContextRetrospective.intervals(runs: document.runs, events: events ?? document.events,
                                                           hr: hr, steps: steps, rr: rr, config: config)
        return clipped(built, from: from, to: to)
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
                                                onsetTs: $0.onsetTs, source: $0.source, decoderVersion: decoderVersion) }
    }

    /// Stored transition rows back as the decoder's events, oldest first. A kind this build does not know (a row
    /// written by a newer decoder) is left out: it cannot be told apart as postural or locomotion.
    public static func events(_ rows: [ActivityContextTransitionRow]) -> [ActivityTransitionEvent] {
        rows.compactMap { r in
            ActivityTransitionKind(rawValue: r.kind).map {
                ActivityTransitionEvent(kind: $0, probability: r.probability, ts: r.ts, onsetTs: r.onsetTs, source: r.source)
            }
        }.sorted { ($0.ts, $0.kind.rawValue) < ($1.ts, $1.kind.rawValue) }
    }

    /// How far before a day's start the canonical HRV windows need the previous day's events, so the day's first
    /// windows still see a change of position or the end of a walk just before midnight: the longest recovery the
    /// HRV-baseline policy needs before a window (`requiredLookbackS`), plus the decoder's detection lag.
    public static var hrvEventLookbackS: Int {
        let c = HRVWindowBuilder.Config()
        return max(120, c.recovery.requiredLookbackS + c.eventDetectionLagS)
    }

    /// The events the day's HRV windows and intervals are built with: the day's own, plus those of `previous` (the
    /// previous day's, from its stored rows or its document) flagged in the `lookbackS` before `dayStart`. A second
    /// flagged by both keeps the day's own reading. The interval build reads the tail only as settling anchors (a
    /// row's `transitionCount` counts the events inside it), so a row that opens the day just after a walk or a
    /// change of position still has its settling.
    public static func hrvEvents(day: [ActivityTransitionEvent], previous: [ActivityTransitionEvent], dayStart: Int,
                                 lookbackS: Int = hrvEventLookbackS) -> [ActivityTransitionEvent] {
        let own = Set(day.map { "\($0.ts)|\($0.kind.rawValue)" })
        let tail = previous.filter {
            $0.ts >= dayStart - lookbackS && $0.ts < dayStart && !own.contains("\($0.ts)|\($0.kind.rawValue)")
        }
        return tail.sorted { ($0.ts, $0.kind.rawValue) < ($1.ts, $1.kind.rawValue) } + day
    }

    /// How far before a day's start the canonical HRV windows need the previous day's intervals: the longest of
    /// `HRVWindowBuilder`'s "time since locomotion / exercise" gates, which read intervals, not events.
    public static var hrvIntervalLookbackS: Int {
        let c = HRVWindowBuilder.Config()
        return max(c.minSinceExerciseS, c.minSinceLocomotionS, hrvEventLookbackS)
    }

    /// The intervals the day's HRV windows look up: the day's own, after the part of `previous` (the previous
    /// day's stored rows) in the `lookbackS` before the day's first second, so the day's first windows see a walk
    /// or a workout that ended just before midnight. Only for that lookup: the day's stored rows are its own.
    public static func hrvIntervals(day: [ActivityContextInterval], previous: [ActivityContextInterval], dayStart: Int,
                                    lookbackS: Int = hrvIntervalLookbackS) -> [ActivityContextInterval] {
        let first = min(dayStart, day.map(\.start).min() ?? dayStart)
        return clipped(previous, from: first - lookbackS, to: first) + day
    }

    /// The part of the input fingerprint that witnesses the previous day's tail events (`hrvEvents`), which a day's
    /// stored rows now depend on (their settling): "" with no tail, so a day nothing came just before keeps the
    /// fingerprint it had; otherwise each event's second, kind and probability.
    public static func tailFingerprint(_ events: [ActivityTransitionEvent]) -> String {
        guard !events.isEmpty else { return "" }
        let sorted = events.sorted { ($0.ts, $0.kind.rawValue) < ($1.ts, $1.kind.rawValue) }
        return "|tail:" + sorted.map { "\($0.ts):\($0.kind.rawValue):\(String(format: "%.3f", $0.probability))" }
            .joined(separator: ",")
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
            // The settled part's start stays a second of the row, and the settling seconds are only those that can
            // lie inside the cut (`[cut.start, settledFrom)`). A cut that keeps none of the settled part has no
            // settled statistics: they describe seconds it no longer holds. Otherwise they are kept as measured.
            if let from = iv.settledFrom {
                let settled = min(max(from, cut.start), cut.end)
                cut.settledFrom = settled
                cut.settlingSeconds = iv.settlingSeconds.map { min($0, max(0, settled - cut.start)) }
                if settled >= cut.end {
                    cut.hrMeanSettled = nil; cut.hrSamplesSettled = nil
                    cut.rmssdSettled = nil; cut.rrDiffSqSumMs2Settled = nil; cut.rrDiffCountSettled = nil
                }
            }
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

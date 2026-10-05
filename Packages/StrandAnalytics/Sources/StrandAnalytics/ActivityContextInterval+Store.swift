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
            respRateBpm: row.respRateBpm, respBreaths: row.respBreaths)
    }
}

/// How a decoded day becomes the rows `WhoopStore.replaceActivityContext` writes.
public enum ActivityContextPersistence {
    /// The ledger row for a day built from `document`, stamped with the versions that produced it.
    ///
    /// `dayEnd` is the end of the LOCAL calendar day when the caller knows it. The document's own end is
    /// where decoding stopped (now, for a day in progress; 24 h after the start otherwise), which is not the
    /// local day on a daylight-saving change and not a stable bound for a day still being written.
    public static func dayRow(day: String, document: ActivityContextDayDocument, intervalCount: Int,
                              computedAt: Int, dayEnd: Int? = nil) -> ActivityContextDayRow {
        let end = dayEnd ?? document.dayEnd
        return ActivityContextDayRow(
            day: day, dayStart: document.dayStart, dayEnd: end,
            taxonomyVersion: ActivityClassVersions.taxonomy,
            decoderVersion: document.versions.decoder, ontologyVersion: document.versions.ontology,
            intervalVersion: ActivityClassVersions.interval,
            dataThrough: document.dataThrough.map { min($0, end) }, observedSeconds: document.observedSeconds,
            intervalCount: intervalCount, computedAt: computedAt)
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

    /// Whether a stored day was derived by the current taxonomy, decoder, ontology and interval rules.
    /// A day that fails this is derived again from the sample streams.
    public static func isCurrent(_ ledger: ActivityContextDayRow) -> Bool {
        ledger.taxonomyVersion == ActivityClassVersions.taxonomy
            && ledger.decoderVersion == ActivityContextVersions.decoder
            && ledger.ontologyVersion == ActivityContextVersions.ontology
            && ledger.intervalVersion == ActivityClassVersions.interval
    }
}

extension ActivityContextLookup {
    /// A lookup over intervals read back from the store.
    public init(rows: [ActivityContextIntervalRow]) {
        self.init(intervals: rows.map(ActivityContextInterval.init(row:)))
    }
}

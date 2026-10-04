import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// Everything the day-level activity inference reads for one day, loaded once so the state timeline and
/// the ActivityContext lane share a single pass over the database.
struct DayStreams {
    /// Stable key for the data source (the ids the day was read from), used to name on-disk caches.
    let sourceKey: String
    let start: Int
    let end: Int
    /// True while the day is still in progress (`end` is "now", not the next midnight).
    let isLiveDay: Bool
    let hr: [HRSample]
    let gravity: [GravitySample]
    /// Step samples merged by timestamp across ids, active strap first. Only the strap's per-record activity
    /// label may be read from this, never the counter, so merging cannot fabricate deltas.
    let stepLabels: [StepSample]
    /// One strap's step samples (the first id that has any). Safe to difference: two straps' cumulative
    /// counters are never interleaved.
    let stepCounter: [StepSample]
    let sleep: [DayStateSpan]
    let workouts: [DayStateWorkout]
    let offWrist: [DayStateSpan]
}

extension Repository {
    /// The streams for `[dayStart, min(dayStart + 24h, now))`; nothing is read for the future.
    func dayStreams(dayStart: Date) async -> DayStreams? {
        guard let store = await storeHandle() else { return nil }
        let start = Int(dayStart.timeIntervalSince1970)
        let now = Int(Date().timeIntervalSince1970)
        let end = min(start + 86_400, now)
        guard end > start else { return nil }

        let hr = await hrSamples(from: start, to: end, limit: 200_000)
        let gravity = await gravitySamplesUnion(from: start, to: end)

        var stepByTs: [Int: StepSample] = [:]
        var counter: [StepSample] = []
        var events: [WhoopEvent] = []
        for id in importedReadIds {
            let samples = (try? await store.stepSamples(deviceId: id, from: start, to: end, limit: 200_000)) ?? []
            if counter.isEmpty { counter = samples }
            for s in samples where stepByTs[s.ts] == nil { stepByTs[s.ts] = s }
            // Reach back so a WRIST_OFF before midnight still opens the span that runs into this day.
            events += (try? await store.events(deviceId: id, from: start - 6 * 3600, to: end, limit: 50_000)) ?? []
        }

        let daysBack = max(0, Int(Date().timeIntervalSince(dayStart) / 86_400)) + 2
        let sleep: [DayStateSpan] = await allSleepSessions(days: daysBack).compactMap { s in
            let lo = s.effectiveStartTs, hi = s.endTs
            return (hi > start && lo < end) ? DayStateSpan(start: lo, end: hi) : nil
        }
        let workouts: [DayStateWorkout] = await workoutRows(days: daysBack).compactMap { w in
            (w.endTs > start && w.startTs < end)
                ? DayStateWorkout(start: w.startTs, end: w.endTs, sport: w.sport) : nil
        }
        let offWrist: [DayStateSpan] = AnalyticsEngine
            .offWristIntervals(events: events, windowEnd: end, hr: hr)
            .filter { $0.end > start && $0.start < end }
            .map { DayStateSpan(start: $0.start, end: $0.end) }

        return DayStreams(sourceKey: importedReadIds.joined(separator: "+"), start: start, end: end,
                          isLiveDay: now < start + 86_400, hr: hr, gravity: gravity,
                          stepLabels: Array(stepByTs.values), stepCounter: counter,
                          sleep: sleep, workouts: workouts, offWrist: offWrist)
    }

    /// The inferred-state timeline for one day, from the strap's own stored signals.
    func dayStateTimeline(dayStart: Date) async -> [DayStateSegment] {
        guard let streams = await dayStreams(dayStart: dayStart) else { return [] }
        return await dayStateTimeline(from: streams)
    }

    func dayStateTimeline(from s: DayStreams) async -> [DayStateSegment] {
        await Task.detached(priority: .utility) {
            DayStateTimeline.build(dayStart: s.start, dayEnd: s.end, hr: s.hr, gravity: s.gravity,
                                   steps: s.stepLabels, sleep: s.sleep, workouts: s.workouts, offWrist: s.offWrist)
        }.value
    }
}

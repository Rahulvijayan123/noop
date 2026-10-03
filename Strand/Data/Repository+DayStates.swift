import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics

extension Repository {
    /// The inferred-state timeline for one day, from the strap's own stored signals. Covers
    /// `[dayStart, min(dayStart + 24h, now))`; nothing is read for the future.
    func dayStateTimeline(dayStart: Date) async -> [DayStateSegment] {
        guard let store = await storeHandle() else { return [] }
        let start = Int(dayStart.timeIntervalSince1970)
        let end = min(start + 86_400, Int(Date().timeIntervalSince1970))
        guard end > start else { return [] }

        let hr = await hrSamples(from: start, to: end, limit: 200_000)
        let gravity = await gravitySamplesUnion(from: start, to: end)

        // Only the strap's per-record activity label is used from the step stream, never the counter, so
        // merging ids by timestamp (active strap first) cannot fabricate deltas.
        var stepByTs: [Int: StepSample] = [:]
        var events: [WhoopEvent] = []
        for id in importedReadIds {
            for s in (try? await store.stepSamples(deviceId: id, from: start, to: end, limit: 200_000)) ?? []
            where stepByTs[s.ts] == nil {
                stepByTs[s.ts] = s
            }
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

        let steps = Array(stepByTs.values)
        return await Task.detached(priority: .utility) {
            DayStateTimeline.build(dayStart: start, dayEnd: end, hr: hr, gravity: gravity, steps: steps,
                                   sleep: sleep, workouts: workouts, offWrist: offWrist)
        }.value
    }
}

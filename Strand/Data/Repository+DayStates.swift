import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics

/// Everything the day-level activity inference reads for one day, loaded once so the state timeline and
/// the ActivityContext lane share a single pass over the database.
struct DayStreams {
    /// Stable key for the data source (the ids the day was read from), used to name on-disk caches.
    let sourceKey: String
    /// The raw id the day's context belongs to: the first id (active strap, other registered WHOOPs, canonical
    /// history) holding heart rate in the day — the same rule `Repository.activityContextOwner` uses. nil when
    /// no id has any. Server windows (HART, ElderNet) are produced from the active strap's uploads, so they are
    /// attached only to a day this id owns.
    var ownerId: String? = nil
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
    /// The nights' sleep epochs: each session's staged non-wake stretches (`DayStateSpan.asleep`), so lying
    /// awake in bed is not sleep here either.
    let sleep: [DayStateSpan]
    /// The nights' in-bed windows (whole sessions).
    let inBed: [DayStateSpan]
    let workouts: [DayStateWorkout]
    let offWrist: [DayStateSpan]
}

/// The raw per-second signals over one stretch, for the stretch detail sheet.
struct StretchSignals {
    let hr: [HRSample]
    let gravity: [GravitySample]
    let steps: [StepSample]
}

extension Repository {
    /// The strap's signals over `[start, end)`, starting a few seconds early so the first second has a
    /// previous sample to difference against. A stretch is minutes to hours, so this is a small read.
    func stretchSignals(from start: Int, to end: Int) async -> StretchSignals? {
        guard let store = await storeHandle(), end > start else { return nil }
        let from = start - 5
        let hr = await hrSamples(from: from, to: end, limit: 200_000)
        let gravity = await gravitySamplesUnion(from: from, to: end)
        var steps: [StepSample] = []
        for id in rawPhysiologyReadIds(store: store) {
            steps = (try? await store.stepSamples(deviceId: id, from: from, to: end, limit: 200_000)) ?? []
            if !steps.isEmpty { break }
        }
        return StretchSignals(hr: hr, gravity: gravity, steps: steps)
    }

    /// The local day that starts at `dayStart` ends here: the next local midnight (23 or 25 hours later on a
    /// daylight-saving change), or 24 h later for a start that is not a local midnight.
    nonisolated static func localDayEnd(startingAt start: Int, calendar: Calendar = .current) -> Int {
        let date = Date(timeIntervalSince1970: TimeInterval(start))
        guard Int(calendar.startOfDay(for: date).timeIntervalSince1970) == start,
              let next = calendar.date(byAdding: .day, value: 1, to: date) else { return start + 86_400 }
        return Int(next.timeIntervalSince1970)
    }

    /// The streams for `[dayStart, min(dayEnd, now))`; nothing is read for the future. `dayEnd` defaults to the
    /// local day's end, so a 25-hour fall-back day is read whole (the materializer passes its `Day.end`).
    ///
    /// Every stream — heart rate, motion, the step counter and the wrist on/off events — is read over the same
    /// raw-physiology ids (`rawPhysiologyReadIds`), so a day recorded by a retained strap that is neither the
    /// active one nor the canonical history decodes with its wear and step evidence too.
    func dayStreams(dayStart: Date, dayEnd: Date? = nil) async -> DayStreams? {
        guard let store = await storeHandle() else { return nil }
        let start = Int(dayStart.timeIntervalSince1970)
        let now = Int(Date().timeIntervalSince1970)
        let dayEndTs = dayEnd.map { Int($0.timeIntervalSince1970) } ?? Self.localDayEnd(startingAt: start)
        let end = min(dayEndTs, now)
        guard end > start else { return nil }

        let rawIds = rawPhysiologyReadIds(store: store)
        let hr = await hrSamples(from: start, to: end, limit: 200_000)
        let gravity = await gravitySamplesUnion(from: start, to: end)
        var ownerId: String?
        for id in rawIds where ownerId == nil {
            if (try? await store.newestHeartRateTs(deviceId: id, from: start, to: end)) != nil { ownerId = id }
        }

        var stepLists: [[StepSample]] = []
        var counter: [StepSample] = []
        var events: [WhoopEvent] = []
        for id in rawIds {
            let samples = (try? await store.stepSamples(deviceId: id, from: start, to: end, limit: 200_000)) ?? []
            if counter.isEmpty { counter = samples }
            stepLists.append(samples)
            // Reach back so a WRIST_OFF before midnight still opens the span that runs into this day.
            events += (try? await store.events(deviceId: id, from: start - 6 * 3600, to: end, limit: 50_000)) ?? []
        }

        let daysBack = max(0, Int(Date().timeIntervalSince(dayStart) / 86_400)) + 2
        let nights = await allSleepSessions(days: daysBack).filter { $0.endTs > start && $0.effectiveStartTs < end }
        let inBed = nights.map { DayStateSpan(start: $0.effectiveStartTs, end: $0.endTs) }
        let sleep = nights.flatMap {
            DayStateSpan.asleep(stagesJSON: $0.stagesJSON, start: $0.effectiveStartTs, end: $0.endTs)
        }
        let stored: [DayStateWorkout] = await workoutRows(days: daysBack).compactMap { w in
            (w.endTs > start && w.startTs < end)
                ? DayStateWorkout(start: w.startTs, end: w.endTs, sport: w.sport) : nil
        }
        let workouts = Self.withLoggedWorkouts(stored, logged: WorkoutModeStore.shared.spans(from: start, to: end, now: now))
        // Walks every heart-rate sample of the day, so it runs off the main actor.
        let offWrist: [DayStateSpan] = await Task.detached(priority: .userInitiated) { [events, hr] in
            AnalyticsEngine
                .offWristIntervals(events: events, windowEnd: end, hr: hr)
                .filter { $0.end > start && $0.start < end }
                .map { DayStateSpan(start: $0.start, end: $0.end) }
        }.value

        // The day's step rows deduped by second, the first id winning; off the main actor like the merges above.
        let stepLabels: [StepSample] = await Task.detached(priority: .userInitiated) { [stepLists] in
            var stepByTs: [Int: StepSample] = [:]
            for samples in stepLists {
                for s in samples where stepByTs[s.ts] == nil { stepByTs[s.ts] = s }
            }
            return Array(stepByTs.values)
        }.value

        return DayStreams(sourceKey: importedReadIds.joined(separator: "+"), ownerId: ownerId, start: start, end: end,
                          isLiveDay: now < dayEndTs, hr: hr, gravity: gravity,
                          stepLabels: stepLabels, stepCounter: counter,
                          sleep: sleep, inBed: inBed, workouts: workouts, offWrist: offWrist)
    }

    /// The day's workouts plus workout mode's logged ones (docs/context-watchdog/WORKOUTS.md): a running workout up to
    /// now, and a logged one whose saved row is missing (no heart rate streamed, or logged afterwards). A logged
    /// workout already saved as a row (same start) is that row. Its sport is the catalogue type's stored sport name,
    /// so the decoder reads the type's kind (`WorkoutKind(sport:)`, pinned by WorkoutTypeCatalogTests).
    nonisolated static func withLoggedWorkouts(_ stored: [DayStateWorkout],
                                               logged: [LoggedWorkoutSpan]) -> [DayStateWorkout] {
        var out = stored
        for span in logged where !stored.contains(where: { abs($0.start - span.startUnix) <= 60 }) {
            guard let type = span.type else { continue }
            out.append(DayStateWorkout(start: span.startUnix, end: span.endUnix, sport: type.sportName))
        }
        return out.sorted { ($0.start, $0.end) < ($1.start, $1.end) }
    }

    /// The inferred-state timeline for one day, from the strap's own stored signals.
    func dayStateTimeline(dayStart: Date) async -> [DayStateSegment] {
        guard let streams = await dayStreams(dayStart: dayStart) else { return [] }
        return await dayStateTimeline(from: streams)
    }

    func dayStateTimeline(from s: DayStreams) async -> [DayStateSegment] {
        await Task.detached(priority: .userInitiated) {
            DayStateTimeline.build(dayStart: s.start, dayEnd: s.end, hr: s.hr, gravity: s.gravity,
                                   steps: s.stepLabels, sleep: s.sleep, workouts: s.workouts, offWrist: s.offWrist)
        }.value
    }
}

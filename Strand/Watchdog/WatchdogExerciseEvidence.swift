import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

/// Per-minute movement evidence for the exercise-session rule (exercise-session-1), kept for the last 4 hours so a
/// session that began before the 30-minute Watchdog window — or before an app relaunch — is still known. Heart rate is
/// carried for the rule's load check only; evidence never comes from heart rate or the time of day.
///
/// Refreshed incrementally each tick: the trailing 15 minutes are re-read (late offloads and decoder intervals), the
/// rest is kept. Main-actor state; the store reads run in `load`, which takes values only.
@MainActor
final class WatchdogExerciseEvidence {
    private(set) var minutes: [Int: ExerciseSessionMinute] = [:]
    private var key = ""
    private var loadedThrough = 0
    static let refreshTailSeconds = 15 * 60

    func reset() {
        minutes = [:]
        key = ""
        loadedThrough = 0
    }

    /// The evidence for `[now − 4 h, now)`, refreshed from the store.
    func history(store: WhoopStore, readIds: [String], key: String, now: Int,
                 intervals: (Int, Int) async -> [ActivityContextIntervalRow]) async -> [ExerciseSessionMinute] {
        if key != self.key { reset(); self.key = key }
        let horizon = now - WatchdogExerciseContext.historySeconds
        let from = max(horizon - horizon % 60, loadedThrough - Self.refreshTailSeconds)
        let to = now - now % 60
        if to > from {
            let rows = await intervals(from, to)
            let fresh = await Self.load(store: store, readIds: readIds, from: from, to: to, intervals: rows)
            for m in fresh { minutes[m.minuteUnix] = m }
            loadedThrough = to
        }
        minutes = minutes.filter { $0.key >= horizon }
        return minutes.values.sorted { $0.minuteUnix < $1.minuteUnix }
    }

    /// Reads HR, dynamic acceleration and step classes for `[from, to)` (first id that holds a stream wins it) and
    /// builds one evidence minute per minute that has any of them.
    nonisolated static func load(store: WhoopStore, readIds: [String], from: Int, to: Int,
                                 intervals: [ActivityContextIntervalRow]) async -> [ExerciseSessionMinute] {
        let chunk = 1800
        var hr: [Int: (sum: Double, n: Int)] = [:]
        var dyn: [Int: (sum: Double, n: Int)] = [:]
        var steps: [Int: Int] = [:], walkRun: [Int: Int] = [:]
        func minute(_ ts: Int) -> Int { ts - ((ts % 60) + 60) % 60 }
        var hrDone = false, gravityDone = false, stepsDone = false
        for id in readIds {
            var t = from
            var hrHit = false, gHit = false, sHit = false
            while t < to {
                let end = min(to, t + chunk)
                if !hrDone {
                    let rows = (try? await store.hrSamples(deviceId: id, from: t, to: end, limit: 8_000)) ?? []
                    for r in rows { let m = minute(r.ts); hr[m, default: (0, 0)].sum += Double(r.bpm); hr[m, default: (0, 0)].n += 1 }
                    hrHit = hrHit || !rows.isEmpty
                }
                if !gravityDone {
                    let rows = (try? await store.gravitySamples(deviceId: id, from: t, to: end, limit: 8_000)) ?? []
                    for r in rows {
                        guard let d = r.dynAccel else { continue }
                        let m = minute(r.ts); dyn[m, default: (0, 0)].sum += d; dyn[m, default: (0, 0)].n += 1
                    }
                    gHit = gHit || !rows.isEmpty
                }
                if !stepsDone {
                    let rows = (try? await store.stepSamples(deviceId: id, from: t, to: end, limit: 8_000)) ?? []
                    for r in rows {
                        let m = minute(r.ts)
                        steps[m, default: 0] += 1
                        if r.activityClass == 1 || r.activityClass == 2 { walkRun[m, default: 0] += 1 }
                    }
                    sHit = sHit || !rows.isEmpty
                }
                t = end
            }
            hrDone = hrDone || hrHit
            gravityDone = gravityDone || gHit
            stepsDone = stepsDone || sHit
        }
        let sortedIntervals = intervals.sorted { $0.startTs < $1.startTs }
        var out: [ExerciseSessionMinute] = []
        for m in stride(from: minute(from), to: to, by: 60) {
            let h = hr[m].map { $0.sum / Double($0.n) }
            let d = dyn[m].map { $0.sum / Double($0.n) }
            let mid = m + 30
            let iv = sortedIntervals.last { $0.startTs <= mid && $0.endTs > mid }
            guard h != nil || d != nil || steps[m] != nil || iv != nil else { continue }
            out.append(ExerciseSessionRule.minute(minuteUnix: m, hr: h, dynMean: d, walkRunTicks: walkRun[m] ?? 0,
                                                  stepTicks: steps[m] ?? 0, interval: iv))
        }
        return out
    }
}

#if DEBUG
import Foundation
import WhoopStore

// MARK: - DEBUG-only sleep-detail demo seed
//
// `AppleDemoSeeder` writes each night's stage timeline but no per-epoch movement and no naps, so the Sleep
// night page's movement lane and nap rows could not be rendered in a simulator. With `--demo-sleep-detail`
// this adds, once: a synthetic movement series to the last 14 seeded nights, and one 30-minute afternoon nap
// on the day before last. Movement is only ever read from the on-device computed twin of a night
// (`<device>-noop`, see `Repository.sessionMotions`), as a strap night would have it, so each of those nights
// gets an identical computed twin carrying the series (the union read collapses the pair to one night).
// SYNTHETIC and deterministic: nothing here is real biometric data.
// The whole file is `#if DEBUG`, so Release builds do not contain it.
enum DemoSleepDetailSeeder {
    static var requested: Bool { CommandLine.arguments.contains("--demo-sleep-detail") }

    static func seedIfRequested(into store: WhoopStore, deviceId: String = "my-whoop") async {
        guard requested else { return }
        let now = Int(Date().timeIntervalSince1970)
        let sessions = (try? await store.sleepSessions(deviceId: deviceId, from: now - 16 * 86_400,
                                                       to: now, limit: 64)) ?? []
        let computedId = deviceId + "-noop"
        let nights = sessions.filter { $0.endTs - $0.startTs > 3 * 3_600 }.suffix(14)
        guard let newest = nights.last else { return }
        // Seed once: the newest night's twin already carrying movement means this ran on an earlier launch.
        if let existing = try? await store.sessionMotion(deviceId: computedId, sessionStart: newest.startTs),
           !existing.isEmpty { return }
        _ = try? await store.upsertSleepSessions(Array(nights), deviceId: computedId)

        var rng = SplitMix64(seed: 0x51EE9)
        for s in nights {
            let epochs = (s.endTs - s.startTs) / 30
            var values: [Double] = []
            values.reserveCapacity(epochs)
            for i in 0..<epochs {
                // A quiet night with a little restlessness near the start, a few turns through it, and the
                // stir before waking.
                let frac = Double(i) / Double(max(1, epochs - 1))
                var v = rng.nextDouble() * 0.06
                if frac < 0.04 || frac > 0.97 { v += rng.nextDouble() * 0.6 }
                if rng.nextDouble() < 0.012 { v += 0.4 + rng.nextDouble() * 0.6 }
                values.append((v * 1000).rounded() / 1000)
            }
            _ = try? await store.persistSessionMotion(deviceId: computedId, sessionStart: s.startTs, motionEpochs: values)
        }

        // One afternoon nap on the day before last (never in the future, never inside a night).
        let cal = Calendar.current
        if let dayBefore = cal.date(byAdding: .day, value: -2, to: cal.startOfDay(for: Date())),
           let napStart = cal.date(bySettingHour: 14, minute: 10, second: 0, of: dayBefore) {
            let start = Int(napStart.timeIntervalSince1970)
            let end = start + 30 * 60
            let stages = "[{\"start\":\(start),\"end\":\(start + 6 * 60),\"stage\":\"light\"},"
                + "{\"start\":\(start + 6 * 60),\"end\":\(start + 22 * 60),\"stage\":\"deep\"},"
                + "{\"start\":\(start + 22 * 60),\"end\":\(end),\"stage\":\"light\"}]"
            _ = try? await store.upsertSleepSessions(
                [CachedSleepSession(startTs: start, endTs: end, efficiency: 0.95, restingHr: nil, avgHrv: nil,
                                    stagesJSON: stages)],
                deviceId: deviceId)
        }
        NSLog("DemoSleepDetailSeeder: movement for \(nights.count) nights and one nap.")
    }
}
#endif

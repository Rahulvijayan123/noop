#if DEBUG
import Foundation
import WhoopProtocol
import WhoopStore
import StrandAnalytics

// MARK: - DEBUG-only Watchdog demo seed
//
// The Monitor tab's Watchdog card, alert timeline and alert sheets read two things a simulator never has:
// a live half-hour of per-second strap data, and an alert ledger built up over three weeks of wear. With
// `--demo-watchdog` this writes both, so those screens can be rendered and screenshotted with no strap:
//
// - per-second heart rate, RR intervals and a still wrist from 40 minutes ago to 20 minutes ahead, so the
//   real Watchdog engine (WatchdogService, untouched) scores a current, calm half-hour on every tick while
//   screenshots are taken;
// - eight alerts over the last 21 days into the ledger's own UserDefaults key, read by
//   `BaselineStore.loadWatchdogSidecars` when the service starts, plus one pending and one entered note.
//
// SYNTHETIC and deterministic: nothing here is real biometric data. The whole file is `#if DEBUG`.
enum DemoWatchdogSeeder {
    static var requested: Bool { CommandLine.arguments.contains("--demo-watchdog") }

    static func seedIfRequested(into store: WhoopStore, deviceId: String = "my-whoop",
                                defaults: UserDefaults = .standard) async {
        guard requested else { return }
        let now = Int(Date().timeIntervalSince1970)
        seedLedger(deviceId: deviceId, now: now, defaults: defaults)
        await seedLiveHalfHour(store: store, deviceId: deviceId, now: now)
    }

    // MARK: Live streams

    private static func seedLiveHalfHour(store: WhoopStore, deviceId: String, now: Int) async {
        let from = now - 40 * 60
        let to = now + 20 * 60
        let existing = (try? await store.hrSamples(deviceId: deviceId, from: now - 120, to: now + 120, limit: 5)) ?? []
        guard existing.isEmpty else { return }
        var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: from) ^ 0xD06)
        var hr: [HRSample] = []
        var rr: [RRInterval] = []
        var gravity: [GravitySample] = []
        for t in from..<to {
            let minute = Double(t - from) / 60
            let bpm = 61 + 2.5 * sin(minute / 6) + (rng.nextDouble() - 0.5) * 3
            hr.append(HRSample(ts: t, bpm: Int(bpm.rounded())))
            let base = 60_000 / bpm
            let jitter = (t % 2 == 0 ? 1 : -1) * (18 + rng.nextDouble() * 14)
            rr.append(RRInterval(ts: t, rrMs: Int((base + jitter).rounded())))
            gravity.append(GravitySample(ts: t, x: 0.04 + (rng.nextDouble() - 0.5) * 0.004,
                                         y: -0.18 + (rng.nextDouble() - 0.5) * 0.004,
                                         z: 0.98, dynAccel: 0.004))
        }
        _ = try? await store.insert(Streams(hr: hr, rr: rr, gravity: gravity), deviceId: deviceId)
        NSLog("DemoWatchdogSeeder: seeded \(to - from) s of live streams for \(deviceId)")
    }

    // MARK: Alert ledger

    private static func seedLedger(deviceId: String, now: Int, defaults: UserDefaults) {
        let ledgerKey = WatchdogEpisodeLedger.persistKey(deviceId: deviceId)
        guard defaults.data(forKey: ledgerKey) == nil else { return }
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        func at(daysAgo: Int, _ hour: Int, _ minute: Int) -> Int {
            let day = cal.date(byAdding: .day, value: -daysAgo, to: today) ?? today
            let date = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
            return Int(date.timeIntervalSince1970)
        }

        func evidence(_ name: String, _ observed: Double?, _ expected: Double, _ half: Double,
                      _ energy: Double, _ unit: String) -> WatchdogSignalEvidence {
            WatchdogSignalEvidence(name: name, observed: observed, usual: expected - 1, reconstructed: expected,
                                   energy: energy, unit: unit, trustPct: 78, rangeHalf: half)
        }

        func row(_ id: String, open: Int, minutes: Int, severity: String, delivery: String,
                 activity: String, label: WatchdogEventLabel, contributing: [String],
                 signals: [WatchdogSignalEvidence], headline: String) -> WatchdogEpisodeLedgerRow {
            let close = open + minutes * 60
            let ticks = stride(from: open, through: close, by: 5 * 60).map { $0 - $0 % 60 }
            return WatchdogEpisodeLedgerRow(
                episodeId: id, deviceId: deviceId, openedUnix: open, lastUnix: close, closedUnix: close,
                maxSeverity: severity, safety: severity == "severe", personalOff: contributing.count > 1,
                notifyDelivery: delivery, liveAlerts: true, offMinutes: ticks,
                unavailableMinutes: minutes > 40 ? 1 : 0,
                peakUnix: open + minutes * 60 / 2, peakEnergy: 2.4, peakSeverity: severity,
                headline: headline, eventLabel: label.rawValue, activityLabel: activity,
                contributing: contributing, signals: signals)
        }

        let quietTemp = evidence("Temp", 33.3, 33.2, 0.35, 0.2, "°C")
        let quietResp = evidence("Resp", 14.6, 14.2, 1.2, 0.3, "/min")
        let rows: [WatchdogEpisodeLedgerRow] = [
            row("demo-1", open: at(daysAgo: 0, 8, 12), minutes: 28, severity: "active", delivery: "sent",
                activity: "still", label: .abnormalStillTachycardia, contributing: ["HR", "HRV"],
                signals: [evidence("HR", 91, 64, 9, 3.1, "bpm"), evidence("HRV", 29, 46, 9, 1.8, "ms"),
                          quietResp, quietTemp],
                headline: "Heart rate is high for being still."),
            row("demo-2", open: at(daysAgo: 1, 18, 4), minutes: 27, severity: "candidate", delivery: "",
                activity: "still", label: .forecastDriftOnly, contributing: ["HR"],
                signals: [evidence("HR", 78, 66, 8, 1.4, "bpm"), evidence("HRV", 41, 44, 9, 0.3, "ms"), quietTemp],
                headline: "Heart rate is drifting above what Watchdog expected."),
            row("demo-3", open: at(daysAgo: 3, 3, 12), minutes: 34, severity: "candidate", delivery: "",
                activity: "still", label: .normalSleep, contributing: ["Resp"],
                signals: [evidence("Resp", 17.4, 14.1, 1.3, 1.6, "/min"), evidence("HR", 55, 53, 6, 0.2, "bpm"),
                          quietTemp],
                headline: "Breathing is faster than usual for sleep."),
            row("demo-4", open: at(daysAgo: 6, 13, 48), minutes: 16, severity: "candidate", delivery: "",
                activity: "walk", label: .postWorkout, contributing: ["HR"],
                signals: [evidence("HR", 104, 88, 10, 1.2, "bpm")],
                headline: "Heart rate stayed up after moving."),
            row("demo-5", open: at(daysAgo: 8, 23, 25), minutes: 62, severity: "severe", delivery: "sent",
                activity: "still", label: .abnormalMultiDirection, contributing: ["HR", "HRV", "Temp"],
                signals: [evidence("HR", 84, 57, 7, 3.4, "bpm"), evidence("HRV", 24, 45, 8, 2.2, "ms"),
                          evidence("Temp", 34.4, 33.2, 0.35, 1.9, "°C"), quietResp],
                headline: "Several vitals moved away from your usual together."),
            row("demo-6", open: at(daysAgo: 12, 7, 15), minutes: 21, severity: "active", delivery: "denied",
                activity: "stand", label: .abnormalStillTachycardia, contributing: ["HR"],
                signals: [evidence("HR", 88, 66, 8, 2.6, "bpm"), evidence("HRV", 38, 42, 9, 0.4, "ms")],
                headline: "Heart rate is high for standing."),
            row("demo-7", open: at(daysAgo: 15, 16, 2), minutes: 18, severity: "candidate", delivery: "",
                activity: "still", label: .forecastDriftOnly, contributing: ["HRV"],
                signals: [evidence("HRV", 30, 45, 9, 1.3, "ms"), evidence("HR", 66, 63, 8, 0.3, "bpm")],
                headline: "HRV is lower than Watchdog expected."),
            row("demo-8", open: at(daysAgo: 19, 10, 30), minutes: 14, severity: "candidate", delivery: "",
                activity: "still", label: .normalStillAwake, contributing: ["SpO2"],
                signals: [evidence("SpO2", 93, 97, 2, 1.1, "%"), evidence("HR", 62, 61, 7, 0.1, "bpm")],
                headline: "SpO₂ dipped below your usual."),
        ].filter { $0.openedUnix < now }

        if let data = try? JSONEncoder().encode(rows) { defaults.set(data, forKey: ledgerKey) }

        let notes: [WatchdogEpisodeAnnotation] = [
            WatchdogEpisodeAnnotation(episodeId: "demo-1", deviceId: deviceId, eventUnix: at(daysAgo: 0, 8, 12)),
            WatchdogEpisodeAnnotation(episodeId: "demo-5", deviceId: deviceId, eventUnix: at(daysAgo: 8, 23, 25),
                                      enteredUnix: at(daysAgo: 8, 23, 25) + 3_600, status: .entered,
                                      symptoms: "Headache, felt warm", exertion: .rest, stress: .high,
                                      illness: .feltOff),
        ]
        if let data = try? JSONEncoder().encode(notes) {
            defaults.set(data, forKey: WatchdogEpisodeAnnotation.persistKey(deviceId: deviceId))
        }
    }
}
#endif

#if DEBUG
import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - DEBUG-only intraday demo seed
//
// `AppleDemoSeeder` fills the daily tables; the Heart rate page reads the per-second streams (heart rate,
// gravity, step counter) instead. With `--demo-intraday` this writes yesterday and today-so-far as a
// believable day (asleep, a walk to work, desk blocks, a lunch walk, a run, an evening on the sofa) so the
// page can be rendered, timed and screenshotted in a simulator with no strap. SYNTHETIC and deterministic:
// nothing here is real biometric data. The whole file is `#if DEBUG`, so Release builds do not contain it.
/// Layout switches for simulator screenshots, where the page cannot be scrolled from outside the app.
enum DemoLayout {
    /// Lists start at the top of the page: no heart rate graph and no lane or summary cards above them.
    static var listsOnly: Bool { CommandLine.arguments.contains("--demo-lists-only") }
    static var hidesActivity: Bool { CommandLine.arguments.contains("--demo-skip-activity") }
}

enum DemoIntradaySeeder {
    static var requested: Bool { CommandLine.arguments.contains("--demo-intraday") }

    private enum Activity {
        case sleep, still, desk, fidget, walk, run, vehicle

        var hr: Double {
            switch self {
            case .sleep: return 53
            case .still: return 66
            case .desk: return 70
            case .fidget: return 76
            case .walk: return 104
            case .run: return 152
            case .vehicle: return 72
            }
        }
    }

    /// (start hour, end hour, activity) for one local day. Gaps default to `.still`.
    private static let plan: [(Double, Double, Activity)] = [
        (0.0, 6.75, .sleep), (6.75, 7.25, .fidget), (7.25, 7.75, .walk), (7.75, 8.5, .still),
        (8.5, 10.25, .desk), (10.25, 10.4, .walk), (10.4, 11.5, .desk), (11.5, 11.6, .walk),
        (11.6, 12.0, .desk), (12.0, 12.4, .walk), (12.4, 12.8, .still), (12.8, 15.0, .desk),
        (15.0, 15.3, .fidget), (15.3, 15.6, .run), (15.6, 16.0, .walk), (16.0, 17.5, .desk),
        (17.5, 18.1, .vehicle), (18.1, 19.0, .still), (19.0, 19.4, .fidget), (19.4, 22.5, .still),
        (22.5, 24.0, .sleep),
    ]

    static func seedIfRequested(into store: WhoopStore, deviceId: String = "my-whoop") async {
        guard requested else { return }
        let cal = Calendar.current
        let today = Int(cal.startOfDay(for: Date()).timeIntervalSince1970)
        let now = Int(Date().timeIntervalSince1970)
        for dayStart in [today - 86_400, today] {
            let end = min(dayStart + 86_400, now)
            guard end > dayStart else { continue }
            let existing = (try? await store.hrSamples(deviceId: deviceId, from: dayStart, to: end, limit: 10)) ?? []
            // Today keeps growing across launches, so only a day with nothing at all is seeded from scratch.
            guard existing.isEmpty else { continue }
            await seed(store: store, deviceId: deviceId, dayStart: dayStart, end: end)
        }
    }

    private static func seed(store: WhoopStore, deviceId: String, dayStart: Int, end: Int) async {
        var rng = SplitMix64(seed: UInt64(truncatingIfNeeded: dayStart) ^ 0xA11CE)
        var hr: [HRSample] = [], gravity: [GravitySample] = [], steps: [StepSample] = []
        var counter = Int(rng.nextDouble() * 20_000)
        var prev = (x: 0.04, y: -0.18, z: 0.98)
        let chunk = 6 * 3_600

        func flush() async {
            guard !hr.isEmpty else { return }
            try? await store.insert(Streams(hr: hr, gravity: gravity, steps: steps), deviceId: deviceId)
            hr.removeAll(keepingCapacity: true); gravity.removeAll(keepingCapacity: true)
            steps.removeAll(keepingCapacity: true)
        }

        for t in dayStart..<end {
            let hour = Double(t - dayStart) / 3600.0
            let activity = plan.first { hour >= $0.0 && hour < $0.1 }?.2 ?? .still
            let drift = 3.0 * sin(Double(t - dayStart) / 1_700.0)
            let noise = (rng.nextDouble() - 0.5) * 4
            hr.append(HRSample(ts: t, bpm: Int((activity.hr + drift + noise).rounded())))

            let jitter: Double
            let tick: Int
            let cls: Int
            switch activity {
            case .sleep: jitter = 0.003; tick = 0; cls = 0
            case .still: jitter = 0.006; tick = 0; cls = 0
            case .desk: jitter = rng.nextDouble() < 0.12 ? 0.05 : 0.012; tick = 0; cls = 0
            case .fidget: jitter = 0.09; tick = rng.nextDouble() < 0.08 ? 1 : 0; cls = 0
            case .walk: jitter = 0.34; tick = rng.nextDouble() < 0.9 ? 2 : 1; cls = 1
            case .run: jitter = 0.8; tick = 3; cls = 2
            case .vehicle: jitter = 0.04; tick = 0; cls = 0
            }
            // A slow roll of the wrist now and then so posture-change logic has something to see.
            if activity != .sleep, rng.nextDouble() < 0.0015 {
                prev = (x: prev.x + (rng.nextDouble() - 0.5) * 0.6, y: prev.y + (rng.nextDouble() - 0.5) * 0.6, z: prev.z)
            }
            let dx = (rng.nextDouble() - 0.5) * 2 * jitter
            let dy = (rng.nextDouble() - 0.5) * 2 * jitter
            let dz = (rng.nextDouble() - 0.5) * 2 * jitter
            let next = (x: prev.x + dx, y: prev.y + dy, z: prev.z + dz)
            let norm = max(0.2, (next.x * next.x + next.y * next.y + next.z * next.z).squareRoot())
            prev = (x: next.x / norm, y: next.y / norm, z: next.z / norm)
            gravity.append(GravitySample(ts: t, x: prev.x, y: prev.y, z: prev.z, dynAccel: jitter))

            counter = (counter + tick) & 0xFFFF
            steps.append(StepSample(ts: t, counter: counter, activityClass: cls))

            if (t - dayStart + 1) % chunk == 0 { await flush() }
        }
        await flush()
        NSLog("DemoIntradaySeeder: seeded \(end - dayStart) s for \(deviceId) from \(dayStart)")
    }
}
#endif

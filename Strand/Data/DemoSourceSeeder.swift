#if DEBUG
import Foundation
import WhoopStore
import StrandDesign

// MARK: - DEBUG-only per-source demo seed
//
// `AppleDemoSeeder` fills the strap's own tables; the Apple Health and Mi Band pages read the series those
// imports write under their own sources ("apple-health", "xiaomi-band"). With `--demo-sources` this writes a
// believable history for both (daily vitals and totals, weekly body composition, a few months of Mi sleep and
// the last night's stages) so the two pages and the metric pages they open can be screenshotted in a simulator
// with no export to import. SYNTHETIC and deterministic: nothing here is real biometric data. The whole file is
// `#if DEBUG`, so Release builds do not contain it. It only writes into a source that holds nothing yet.
enum DemoSourceSeeder {
    static var requested: Bool { CommandLine.arguments.contains("--demo-sources") }

    /// Days of history to write: `--demo-days N` when given (0 writes nothing), else 120.
    private static var days: Int {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--demo-days"), i + 1 < args.count, let n = Int(args[i + 1]) { return n }
        return 120
    }

    static func seedIfRequested(into store: WhoopStore) async {
        guard requested, days > 0 else { return }
        let today = Date()
        let existing = (try? await store.metricSeries(deviceId: "apple-health", key: "steps",
                                                      from: "0000-01-01", to: "9999-12-31")) ?? []
        guard existing.isEmpty else { return }
        var apple: [MetricPoint] = []
        var mi: [MetricPoint] = []
        var rng = SplitMix64(seed: 0x50_0C_E5)
        let cal = Calendar.current
        for back in stride(from: days - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -back, to: today) else { continue }
            let day = ChartDay.key(for: date)
            let phase = Double(days - back)
            let wave = sin(phase / 6.0)
            // A day or two missing now and then, as real exports have.
            if rng.nextDouble() < 0.06 { continue }
            apple.append(MetricPoint(day: day, key: "steps", value: (8_200 + 2_900 * wave + rng.nextDouble() * 1_800).rounded()))
            apple.append(MetricPoint(day: day, key: "active_kcal", value: (430 + 160 * wave + rng.nextDouble() * 90).rounded()))
            apple.append(MetricPoint(day: day, key: "resting_hr", value: (56 + 3 * sin(phase / 8.0) + rng.nextDouble() * 2).rounded()))
            apple.append(MetricPoint(day: day, key: "hrv", value: (46 + 9 * sin(phase / 9.0) + rng.nextDouble() * 6).rounded()))
            apple.append(MetricPoint(day: day, key: "resp_rate", value: 14.4 + 0.8 * sin(phase / 7.0) + rng.nextDouble() * 0.4))
            apple.append(MetricPoint(day: day, key: "asleep_min", value: (412 + 48 * sin(phase / 5.0 + 1.1) + rng.nextDouble() * 30).rounded()))
            if rng.nextDouble() < 0.6 {
                apple.append(MetricPoint(day: day, key: "spo2", value: (96 + rng.nextDouble() * 3).rounded()))
            }
            if Int(phase) % 7 == 0 {
                let weight = 77.5 - 1.6 * (phase / Double(max(days, 1))) + rng.nextDouble() * 0.6
                let fat = 19.0 - 1.2 * (phase / Double(max(days, 1))) + rng.nextDouble() * 0.4
                apple.append(MetricPoint(day: day, key: "weight", value: weight))
                apple.append(MetricPoint(day: day, key: "body_fat", value: fat))
                apple.append(MetricPoint(day: day, key: "lean_mass", value: weight * (1 - fat / 100)))
                apple.append(MetricPoint(day: day, key: "bmi", value: weight / (1.79 * 1.79)))
            }
            if Int(phase) % 10 == 0 {
                apple.append(MetricPoint(day: day, key: "vo2max", value: 44 + 1.5 * sin(phase / 30.0)))
            }

            mi.append(MetricPoint(day: day, key: "steps", value: (7_400 + 2_600 * wave + rng.nextDouble() * 1_500).rounded()))
            mi.append(MetricPoint(day: day, key: "distance_m", value: (5_300 + 1_900 * wave + rng.nextDouble() * 900).rounded()))
            mi.append(MetricPoint(day: day, key: "energy_kcal", value: (380 + 150 * wave + rng.nextDouble() * 80).rounded()))
            mi.append(MetricPoint(day: day, key: "intensity_min", value: (22 + 18 * wave + rng.nextDouble() * 15).rounded()))
            mi.append(MetricPoint(day: day, key: "rhr", value: (58 + 3 * sin(phase / 8.0) + rng.nextDouble() * 2).rounded()))
            mi.append(MetricPoint(day: day, key: "avg_hr", value: (74 + 4 * wave + rng.nextDouble() * 3).rounded()))
            mi.append(MetricPoint(day: day, key: "max_hr", value: (132 + 14 * wave + rng.nextDouble() * 10).rounded()))
            mi.append(MetricPoint(day: day, key: "spo2", value: (96 + rng.nextDouble() * 3).rounded()))
            let asleep = (418 + 44 * sin(phase / 5.0 + 0.6) + rng.nextDouble() * 25).rounded()
            mi.append(MetricPoint(day: day, key: "sleep_total_min", value: asleep))
            mi.append(MetricPoint(day: day, key: "sleep_deep_min", value: (asleep * 0.18).rounded()))
            mi.append(MetricPoint(day: day, key: "sleep_rem_min", value: (asleep * 0.22).rounded()))
            mi.append(MetricPoint(day: day, key: "sleep_light_min", value: (asleep * 0.60).rounded()))
            mi.append(MetricPoint(day: day, key: "sleep_score", value: (76 + 10 * sin(phase / 5.0) + rng.nextDouble() * 6).rounded()))
            mi.append(MetricPoint(day: day, key: "stress", value: (34 + 12 * sin(phase / 4.0) + rng.nextDouble() * 8).rounded()))
            if Int(phase) % 7 == 0 {
                mi.append(MetricPoint(day: day, key: "vitality", value: (58 + 6 * sin(phase / 25.0)).rounded()))
            }
        }
        _ = try? await store.upsertMetricSeries(apple, deviceId: "apple-health")
        _ = try? await store.upsertMetricSeries(mi, deviceId: "xiaomi-band")
        await seedMiNight(into: store)
    }

    /// Last night's Mi Band sleep, with its stage segments in the `[{start,end,stage}]` shape the importer stores.
    private static func seedMiNight(into store: WhoopStore) async {
        let cal = Calendar.current
        let midnight = cal.startOfDay(for: Date())
        let start = Int(midnight.timeIntervalSince1970) - 75 * 60      // 22:45 the evening before
        let plan: [(Int, String)] = [
            (14, "light"), (38, "deep"), (46, "light"), (22, "rem"), (8, "wake"), (34, "light"), (30, "deep"),
            (40, "light"), (26, "rem"), (42, "light"), (18, "deep"), (36, "light"), (30, "rem"), (6, "wake"),
            (24, "light"), (20, "rem"),
        ]
        var segments: [[String: Any]] = []
        var t = start
        for (minutes, stage) in plan {
            segments.append(["start": t, "end": t + minutes * 60, "stage": stage])
            t += minutes * 60
        }
        guard let data = try? JSONSerialization.data(withJSONObject: segments),
              let json = String(data: data, encoding: .utf8) else { return }
        let night = CachedSleepSession(startTs: start, endTs: t, efficiency: 93, restingHr: 57, avgHrv: nil,
                                       stagesJSON: json)
        _ = try? await store.upsertSleepSessions([night], deviceId: "xiaomi-band")
    }
}

#endif

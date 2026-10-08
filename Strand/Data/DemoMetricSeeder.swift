#if DEBUG
import Foundation
import WhoopStore

// MARK: - DEBUG-only metric-catalog demo seed
//
// `AppleDemoSeeder` fills the strap's daily tables and a handful of WHOOP-export series. The metric detail
// pages also draw series that only arrive with an import (Apple Health body metrics and steps, WHOOP-export
// heart-rate zones, day stress, average and max heart rate, time in bed, restorative sleep) and the mood
// check-ins. With `--demo-metrics` this writes those too, over the same `--demo-days` window, so every
// detail page can be rendered and screenshotted in a simulator. Calories for the last ten days are written
// under the on-device computed source, so the page's on-device estimate marks have something to mark.
//
// SYNTHETIC and deterministic (fixed seed): nothing here is real biometric data. The whole file is
// `#if DEBUG`, so Release builds do not contain it, and it only writes into a store that has none of these
// series yet.
enum DemoMetricSeeder {
    static var requested: Bool { CommandLine.arguments.contains("--demo-metrics") }

    private static let whoop = AppleDemoSeeder.whoop
    private static let apple = AppleDemoSeeder.apple

    static func seedIfRequested(into store: WhoopStore) async {
        guard requested, DemoLaunch.seedDays > 0 else { return }
        let existing = (try? await store.metricSeries(deviceId: apple, key: "steps", from: "0000-01-01", to: "9999-12-31")) ?? []
        guard existing.isEmpty else { return }
        do { try await seed(into: store, days: DemoLaunch.seedDays) }
        catch { NSLog("DemoMetricSeeder: seed failed — \(error)") }
    }

    private static func seed(into store: WhoopStore, days: Int) async throws {
        var rng = SplitMix64(seed: 0x5EED_0E77)
        let cal = Calendar.current
        let start = cal.date(byAdding: .day, value: -(days - 1), to: cal.startOfDay(for: Date()))!
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = .current
        fmt.dateFormat = "yyyy-MM-dd"

        var appleSeries: [MetricPoint] = []
        var whoopSeries: [MetricPoint] = []
        var computedSeries: [MetricPoint] = []
        var moodSeries: [MetricPoint] = []
        var weight = 80.2
        var vo2 = 44.0

        func gauss(_ mean: Double, _ sd: Double) -> Double {
            let u1 = max(1e-9, rng.nextDouble()), u2 = rng.nextDouble()
            return mean + sd * (sqrt(-2 * log(u1)) * cos(2 * .pi * u2))
        }
        func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

        for i in 0..<days {
            let date = cal.date(byAdding: .day, value: i, to: start)!
            let day = fmt.string(from: date)
            let weekday = cal.component(.weekday, from: date)
            let weekend = weekday == 1 || weekday == 7

            // Apple Health: steps and active energy every day, weigh-ins every two to four days, VO2 max
            // every week or so, body composition weekly.
            let steps = max(1_500, gauss(weekend ? 10_500 : 8_200, 2_400)).rounded()
            appleSeries.append(MetricPoint(day: day, key: "steps", value: steps))
            appleSeries.append(MetricPoint(day: day, key: "active_kcal", value: r1(max(150, steps * 0.045 + gauss(80, 60)))))
            weight += gauss(-0.015, 0.12)
            if i % 3 == 0 || rng.nextDouble() < 0.15 {
                appleSeries.append(MetricPoint(day: day, key: "weight", value: r1(weight + gauss(0, 0.25))))
                appleSeries.append(MetricPoint(day: day, key: "bmi", value: r1((weight / (1.8 * 1.8)) + gauss(0, 0.05))))
            }
            if i % 7 == 2 {
                appleSeries.append(MetricPoint(day: day, key: "body_fat", value: r1(19 - Double(i) * 0.01 + gauss(0, 0.3))))
                appleSeries.append(MetricPoint(day: day, key: "lean_mass", value: r1(weight * 0.81 + gauss(0, 0.2))))
            }
            if i % 8 == 4 {
                vo2 += 0.12
                appleSeries.append(MetricPoint(day: day, key: "vo2max", value: r1(vo2 + gauss(0, 0.4))))
            }

            // WHOOP export: heart rate, energy, time in bed, restorative sleep, day stress, measured steps.
            let avgHr = gauss(66, 3.5)
            whoopSeries.append(MetricPoint(day: day, key: "avg_hr", value: avgHr.rounded()))
            whoopSeries.append(MetricPoint(day: day, key: "max_hr", value: gauss(weekend ? 158 : 146, 12).rounded()))
            let energy = r1(gauss(2_450, 260))
            if i >= days - 10 {
                // The last ten days come from the on-device estimate (active energy only).
                computedSeries.append(MetricPoint(day: day, key: "energy_kcal", value: r1(gauss(620, 140))))
            } else {
                whoopSeries.append(MetricPoint(day: day, key: "energy_kcal", value: energy))
            }
            let inBed = gauss(470, 35)
            let asleep = inBed * gauss(0.9, 0.03)
            whoopSeries.append(MetricPoint(day: day, key: "in_bed_min", value: r1(inBed)))
            whoopSeries.append(MetricPoint(day: day, key: "hours_vs_needed_pct", value: r1(asleep / gauss(450, 20) * 100)))
            let restorative = asleep * gauss(0.43, 0.05)
            whoopSeries.append(MetricPoint(day: day, key: "restorative_min", value: r1(restorative)))
            whoopSeries.append(MetricPoint(day: day, key: "restorative_pct", value: r1(restorative / asleep * 100)))
            whoopSeries.append(MetricPoint(day: day, key: "stress", value: r1(min(3, max(0, gauss(1.1, 0.6))))))
            whoopSeries.append(MetricPoint(day: day, key: "steps", value: max(1_200, gauss(8_600, 2_500)).rounded()))

            // Heart-rate zones and strength time on workout days only.
            if rng.nextDouble() < (weekend ? 0.45 : 0.6) {
                let zones = [gauss(14, 5), gauss(26, 8), gauss(22, 7), gauss(12, 5), gauss(5, 3)].map { max(0, r1($0)) }
                for (index, minutes) in zones.enumerated() {
                    whoopSeries.append(MetricPoint(day: day, key: "hr_zone\(index + 1)_min", value: minutes))
                }
                whoopSeries.append(MetricPoint(day: day, key: "hr_zones13_min", value: r1(zones[0] + zones[1] + zones[2])))
                whoopSeries.append(MetricPoint(day: day, key: "hr_zones45_min", value: r1(zones[3] + zones[4])))
                whoopSeries.append(MetricPoint(day: day, key: "hr_zones_all_min", value: r1(zones.reduce(0, +))))
                if rng.nextDouble() < 0.35 {
                    whoopSeries.append(MetricPoint(day: day, key: "strength_min", value: r1(gauss(42, 12))))
                }
            }

            // Mood: a check-in on most days.
            if rng.nextDouble() < 0.72 {
                let mood = min(5, max(1, (gauss(weekend ? 3.9 : 3.4, 0.9)).rounded()))
                moodSeries.append(MetricPoint(day: day, key: "mood", value: mood))
            }
        }

        _ = try await store.upsertMetricSeries(appleSeries, deviceId: apple)
        _ = try await store.upsertMetricSeries(whoopSeries, deviceId: whoop)
        _ = try await store.upsertMetricSeries(computedSeries, deviceId: whoop + "-noop")
        _ = try await store.upsertMetricSeries(moodSeries, deviceId: "noop-mood")
        NSLog("DemoMetricSeeder: seeded \(appleSeries.count + whoopSeries.count + computedSeries.count + moodSeries.count) points over \(days) days.")
    }
}
#endif

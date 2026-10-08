#if DEBUG
import Foundation
import WhoopProtocol
import WhoopStore

// MARK: - DEBUG-only workout demo seed
//
// `AppleDemoSeeder` writes the workout rows; the workout pages also read the strap's per-second heart rate
// over each session (the session curve, zones from the strap, heart-rate recovery after it) and the GPS route
// store. With `--demo-workouts` this writes, for the newest seeded workouts that have already ended, a
// believable per-second trace (warm-up, work with surges, a hard finish, cool-down, five minutes of recovery),
// a route for the newest distance session, and one manual session, so those pages can be rendered and
// screenshotted in a simulator with no strap. SYNTHETIC and deterministic: nothing here is real biometric
// data. The whole file is `#if DEBUG`, so Release builds do not contain it.
enum DemoWorkoutSeeder {
    static var requested: Bool { CommandLine.arguments.contains("--demo-workouts") }

    /// How many of the newest finished workouts get a heart-rate trace.
    private static let tracedCount = 8

    static func seedIfRequested(into store: WhoopStore, deviceId: String = AppleDemoSeeder.whoop) async {
        guard requested else { return }
        let now = Int(Date().timeIntervalSince1970)
        let rows = ((try? await store.workouts(deviceId: deviceId, from: now - 120 * 86_400, to: now, limit: 5000)) ?? [])
            .filter { $0.endTs + 6 * 60 < now && $0.source != "manual" }
            .sorted { $0.startTs > $1.startTs }
        guard !rows.isEmpty else { return }

        for row in rows.prefix(tracedCount) {
            let existing = (try? await store.hrSamples(deviceId: deviceId, from: row.startTs, to: row.endTs, limit: 5)) ?? []
            guard existing.isEmpty else { continue }
            let hr = trace(for: row)
            _ = try? await store.insert(Streams(hr: hr, gravity: [], steps: []), deviceId: deviceId)
        }

        if let run = rows.first(where: { ["Running", "Cycling", "Walking"].contains($0.sport) }),
           RouteStore.load(startTs: run.startTs, sport: run.sport) == nil {
            let points = loop(meters: run.distanceM ?? 6_000)
            RouteStore.store(WorkoutRoute(polyline: RouteMath.encode(points), distanceM: RouteMath.totalMeters(points)),
                             startTs: run.startTs, sport: run.sport)
        }

        // One manual session yesterday evening, so the list carries an editable row.
        let cal = Calendar.current
        if let yesterday = cal.date(byAdding: .day, value: -1, to: cal.startOfDay(for: Date())) {
            let start = Int(yesterday.timeIntervalSince1970) + 7 * 3600 + 15 * 60
            let manual = WorkoutRow(startTs: start, endTs: start + 40 * 60, sport: "Strength Training", source: "manual",
                                    durationS: 40 * 60, energyKcal: 260, avgHr: nil, maxHr: nil, strain: nil,
                                    distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)
            let already = ((try? await store.workouts(deviceId: deviceId, from: start - 60, to: start + 60, limit: 10)) ?? [])
                .contains { $0.source == "manual" }
            if !already { _ = try? await store.upsertWorkouts([manual], deviceId: deviceId) }
        }
    }

    /// One sample a second from five minutes before the start to six minutes after the end.
    private static func trace(for row: WorkoutRow) -> [HRSample] {
        var seed = UInt64(truncatingIfNeeded: row.startTs) ^ 0x5EED
        func noise() -> Double {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(UInt64(1) << 31) - 0.5
        }
        let avg = Double(row.avgHr ?? 140)
        let peak = Double(row.maxHr ?? Int(avg) + 22)
        let start = row.startTs, end = row.endTs
        let span = Double(max(60, end - start))
        var out: [HRSample] = []
        var drift = 0.0
        for t in (start - 300)...(end + 360) {
            let bpm: Double
            if t < start {
                bpm = 82 + Double(t - (start - 300)) / 300 * 10
            } else if t <= end {
                let f: Double = Double(t - start) / span
                let warm: Double = min(1, f / 0.12)
                let headroom: Double = peak - avg
                let surge: Double = sin(f * Double.pi * 9) > 0.55 ? headroom * 0.7 : 0
                let finish: Double = f > 0.86 ? headroom * 0.85 : 0
                let cool: Double = f > 0.97 ? -(f - 0.97) / 0.03 * 12 : 0
                let base: Double = 96 + (avg - 96) * warm
                bpm = base + surge * warm + finish + cool
            } else {
                // Recovery: a fast first minute, then a slower slide toward an easy resting level.
                let s: Double = Double(t - end)
                let endHR: Double = peak - 6
                bpm = 92 + (endHR - 92) * exp(-s / 75)
            }
            drift += noise() * 0.6
            drift *= 0.96
            let jitter: Double = noise() * 2
            let value = Int((bpm + drift + jitter).rounded())
            out.append(HRSample(ts: t, bpm: max(50, min(205, value))))
        }
        return out
    }

    /// A closed loop of roughly `meters` around a park.
    private static func loop(meters: Double) -> [RouteMath.LatLng] {
        let center = (lat: 51.5074, lon: -0.1657)       // Hyde Park, London
        let radiusM: Double = max(300, meters / (2 * Double.pi))
        let n = 120
        return (0...n).map { (i: Int) -> RouteMath.LatLng in
            let a: Double = Double(i) / Double(n) * 2 * Double.pi
            let wobble: Double = 1 + 0.12 * sin(a * 3)
            let r: Double = radiusM * wobble
            let dLat: Double = r * cos(a) / 111_320
            let metersPerDegreeLon: Double = 111_320 * cos(center.lat * Double.pi / 180)
            let dLon: Double = r * 1.4 * sin(a) / metersPerDegreeLon
            return RouteMath.LatLng(center.lat + dLat, center.lon + dLon)
        }
    }
}
#endif

import Foundation
import WhoopProtocol
@testable import energybench

/// A deterministic, hand-built day for the harness tests. No health data: every number is invented here.
struct Segment {
    var minutes: Int
    var hr: Double
    var dyn: Double? = 0.02
    var cadence: Double? = 0
    var activityClass: Int? = 0
    var asleep = false
}

extension Segment {
    static func sitting(_ minutes: Int, hr: Double = 64) -> Segment { Segment(minutes: minutes, hr: hr) }
    static func walking(_ minutes: Int, hr: Double, cadence: Double = 105, dyn: Double = 0.22) -> Segment {
        Segment(minutes: minutes, hr: hr, dyn: dyn, cadence: cadence, activityClass: 1)
    }
    static func running(_ minutes: Int, hr: Double) -> Segment {
        Segment(minutes: minutes, hr: hr, dyn: 0.8, cadence: 165, activityClass: 2)
    }
    static func sleeping(_ minutes: Int, hr: Double = 50) -> Segment {
        Segment(minutes: minutes, hr: hr, dyn: 0.005, cadence: 0, activityClass: 0, asleep: true)
    }
}

struct TestDay {
    static let day = "2026-09-22"
    static let dayStart = 1_790_035_200
    static let profile = DayBundle.Profile(weightKg: 70, heightCm: 175, age: 35, sex: "male")

    private(set) var streams = Bench.Streams(hr: [], gravity: [], steps: [])
    private(set) var sleep: [DayBundle.SleepRow] = []
    /// The resting HR carried on the scored nights; nil makes the replayed day one with no resting HR.
    var sleepRestingHR: Int? = 50
    private(set) var cursor = TestDay.dayStart
    private var counter = 1000
    private var stepFraction = 0.0
    private var seed: UInt64 = 12345

    private mutating func noise() -> Double {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Double((seed >> 33) & 0xFFFFF) / Double(0xFFFFF) * 2 - 1
    }

    @discardableResult
    mutating func add(_ s: Segment) -> (start: Int, end: Int) {
        let start = cursor
        for _ in 0..<(s.minutes * 60) {
            streams.hr.append(HRSample(ts: cursor, bpm: Int((s.hr + 2 * noise()).rounded())))
            if let dyn = s.dyn {
                streams.gravity.append(GravitySample(ts: cursor, x: 0, y: 0, z: 1, dynAccel: max(0, dyn * (1 + 0.3 * noise()))))
            }
            if let cadence = s.cadence {
                stepFraction += cadence / 60
                let whole = Int(stepFraction)
                stepFraction -= Double(whole)
                counter = (counter + whole) & 0xFFFF
                streams.steps.append(StepSample(ts: cursor, counter: counter, activityClass: s.activityClass))
            }
            cursor += 1
        }
        if s.asleep { sleep.append(.init(start: start, end: cursor, restingHr: sleepRestingHR, nap: false)) }
        return (start, cursor)
    }

    func run(options: BenchOptions = BenchOptions(), asOf: Int? = nil) throws -> DayRun {
        try Bench.run(day: TestDay.day, tzOffsetSeconds: 0, dayStart: TestDay.dayStart, asOf: asOf,
                      profile: TestDay.profile, bundleRestingHR: 51, sleep: sleep, streams: streams, options: options)
    }
}

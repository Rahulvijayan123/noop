import Foundation
import WhoopProtocol
@testable import StrandAnalytics

// EnergyTestSupport.swift — deterministic synthetic days for the energy-fusion tests.
//
// A day is a list of segments (minutes of constant condition). Every second of a segment emits an HR row,
// a gravity row with `dynAccel`, and a step-counter row, with a seeded generator providing the jitter, so
// the same call always builds the same day.

struct EnergySegment {
    var minutes: Int
    var hr: Double
    var hrJitter: Double = 2.0
    /// Gravity-removed motion magnitude (g). nil → no gravity rows (WHOOP 4.0, or a day with no motion channel).
    var dyn: Double? = 0.02
    /// Steps per minute. nil → no step-counter rows.
    var cadence: Double? = 0
    /// 0 still / 1 walk / 2 run, as the strap's activity-class byte.
    var activityClass: Int? = 0
    var hrPresent = true
    var asleep = false
    var strapOff = false
}

struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double((state >> 33) & 0xFFFFF) / Double(0xFFFFF)
    }
    /// Uniform in [-1, 1].
    mutating func signed() -> Double { next() * 2 - 1 }
}

struct SyntheticDay {
    static let dayStart = 1_790_035_200
    static let profile = UserProfile(weightKg: 70, heightCm: 175, age: 35, sex: "male")
    static let restingHR = 51.0
    static let hrmax = 194.0

    var hr: [HRSample] = []
    var gravity: [GravitySample] = []
    var steps: [StepSample] = []
    var sleep: [EnergyInterval] = []
    private(set) var cursor: Int
    private var counter = 1000
    private var stepAccumulator = 0.0
    private var rng: SeededRandom

    init(seed: UInt64 = 7, start: Int = SyntheticDay.dayStart) {
        cursor = start
        rng = SeededRandom(seed: seed)
    }

    var dayStart: Int { SyntheticDay.dayStart }

    @discardableResult
    mutating func add(_ s: EnergySegment) -> (start: Int, end: Int) {
        let start = cursor
        let seconds = s.minutes * 60
        for _ in 0..<seconds {
            if !s.strapOff {
                if s.hrPresent {
                    let bpm = Int((s.hr + s.hrJitter * rng.signed()).rounded())
                    hr.append(HRSample(ts: cursor, bpm: bpm))
                }
                if let dyn = s.dyn {
                    let d = max(0, dyn * (1 + 0.3 * rng.signed()))
                    gravity.append(GravitySample(ts: cursor, x: 0, y: 0, z: 1, unit: "g", dynAccel: d))
                }
                if let cadence = s.cadence {
                    stepAccumulator += cadence / 60.0
                    let inc = Int(stepAccumulator)
                    stepAccumulator -= Double(inc)
                    counter = (counter + inc) & 0xFFFF
                    steps.append(StepSample(ts: cursor, counter: counter, activityClass: s.activityClass))
                }
            }
            cursor += 1
        }
        if s.asleep { sleep.append(EnergyInterval(start: start, end: cursor)) }
        return (start, cursor)
    }

    /// Pad to a full 24 h day with nothing (strap off).
    mutating func padToFullDay() {
        let end = SyntheticDay.dayStart + 86_400
        if cursor < end { cursor = end }
    }

    func input(profile: UserProfile = SyntheticDay.profile,
               asOf: Int? = nil,
               workouts: [EnergyWorkoutInterval] = [],
               epochs: [ActivityEpoch] = [],
               motionEvidence: [MotionEvidenceMinute] = [],
               restingHR: Double? = SyntheticDay.restingHR,
               hrmax: Double? = SyntheticDay.hrmax) -> EnergyDayInput {
        EnergyDayInput(dayStart: SyntheticDay.dayStart, dayEnd: SyntheticDay.dayStart + 86_400, asOf: asOf,
                       hr: hr, gravity: gravity, steps: steps, profile: profile, hrmax: hrmax,
                       restingHR: restingHR, sleepIntervals: sleep, workouts: workouts,
                       activityEpochs: epochs, motionEvidence: motionEvidence)
    }
}

/// Common building blocks.
extension EnergySegment {
    static func sitting(_ minutes: Int, hr: Double = 66, jitter: Double = 3) -> EnergySegment {
        EnergySegment(minutes: minutes, hr: hr, hrJitter: jitter, dyn: 0.02, cadence: 0, activityClass: 0)
    }
    static func walking(_ minutes: Int, hr: Double, cadence: Double = 105, dyn: Double = 0.22) -> EnergySegment {
        EnergySegment(minutes: minutes, hr: hr, hrJitter: 3, dyn: dyn, cadence: cadence, activityClass: 1)
    }
    static func running(_ minutes: Int, hr: Double, cadence: Double = 165, dyn: Double = 0.8) -> EnergySegment {
        EnergySegment(minutes: minutes, hr: hr, hrJitter: 3, dyn: dyn, cadence: cadence, activityClass: 2)
    }
    static func sleeping(_ minutes: Int, hr: Double = 50) -> EnergySegment {
        EnergySegment(minutes: minutes, hr: hr, hrJitter: 2, dyn: 0.005, cadence: 0, activityClass: 0, asleep: true)
    }
}

/// Mean over `range` of an `EnergyMinute` property.
func meanOf(_ minutes: ArraySlice<EnergyMinute>, _ f: (EnergyMinute) -> Double) -> Double {
    guard !minutes.isEmpty else { return 0 }
    return minutes.reduce(0.0) { $0 + f($1) } / Double(minutes.count)
}

func minuteSlice(_ e: DayEnergy, from: Int, to: Int) -> ArraySlice<EnergyMinute> {
    e.minutes[from..<to]
}

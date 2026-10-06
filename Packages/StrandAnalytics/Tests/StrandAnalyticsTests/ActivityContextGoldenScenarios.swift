import Foundation
import WhoopProtocol
@testable import StrandAnalytics

/// Representative ActivityContext decoder days whose complete output is pinned byte-for-byte in
/// `Goldens/ActivityContext/<name>/` (see `ActivityContextGoldenTests`).
///
/// The fixtures were recorded from the decoder at `ccd5f0dc` (`hsmm-1.3`), before the Inertia-1 motion-head
/// channels existed. They are the proof that a decoder with Inertia switched off (no config, or heads in the
/// input but no config) still produces exactly what it produced before, down to the last byte of every
/// published state and of the resumable snapshot.
///
/// Every scenario is deterministic: `ActivitySim` uses a fixed LCG and the decoder sums in fixed orders.
enum ActivityGoldenScenarios {

    /// A golden day: either ready-made observations (the streaming path) or stored streams (the track
    /// builder path, which also produces the persisted day document).
    enum Source {
        case observations([ActivityObservation])
        case input(ActivityContextTrackInput, generatedAt: Int)
    }

    struct Scenario {
        let name: String
        let config: ActivityDecoderConfig
        let source: Source
    }

    static let all: [Scenario] = [mixedObservations(), storedStreamsDay(), specialists(), resumedHalf()]

    // MARK: - Synthetic IMU / encoder windows

    /// A 4-s IMU feature window every 2 s, shaped like the stretch it describes.
    static func imu(accel: Double, gyro: Double, cadenceHz: Double?, strength: Double,
                    orientation: Double?) -> (Int) -> ImuWindowFeatures? {
        return { ts in
            guard ts % 2 == 1 else { return nil }
            return ImuWindowFeatures(startTs: ts - 4, endTs: ts, accelRmsG: accel, gyroRmsDps: gyro,
                                     jerkRms: accel * 0.4, cadenceHz: cadenceHz, cadenceStrength: strength,
                                     orientationChangeDeg: orientation)
        }
    }

    /// Heart rate that ramps up over `rampS`, holds, then recovers.
    static func effortHR(start: Int, rampS: Int, holdS: Int, recoverS: Int, rest: Int = 62, peak: Int = 150,
                         floorAfter: Int = 96) -> (Int) -> Int? {
        return { ts in
            if ts < start { return rest }
            let e = ts - start
            if e < rampS { return rest + 8 + Int(Double(e) / Double(rampS) * Double(peak - rest - 8)) }
            if e < rampS + holdS { return peak }
            let r = e - rampS - holdS
            return max(floorAfter, peak - Int(Double(r) / Double(recoverS) * Double(peak - floorAfter)))
        }
    }

    // MARK: - Scenarios

    /// Sleep, getting up, desk work with HART windows and IMU features, a walk, a run, a brisk walk, fidgeting,
    /// a gait-free workout with a heart-rate ramp, the strap off, a short gap and a gap long enough to reset.
    static func mixedObservations() -> Scenario {
        var sim = ActivitySim(start: 1_760_000_000, seed: 11)
        sim.sleeping(400)
        sim.postureShift(netDegrees: 70)
        sim.still(60)
        var desk = ActivitySim.Options()
        desk.encoder = SimEncoder.coarse("stationary")
        desk.imu = imu(accel: 0.03, gyro: 6, cadenceHz: nil, strength: 0.05, orientation: 3)
        sim.desk(240, opt: desk)
        sim.postureShift(netDegrees: -60, opt: desk)
        var walk = ActivitySim.Options()
        walk.encoder = SimEncoder.coarse("walking")
        walk.imu = imu(accel: 0.14, gyro: 40, cadenceHz: 1.8, strength: 0.6, orientation: 12)
        sim.walk(180, opt: walk)
        var run = ActivitySim.Options()
        run.encoder = SimEncoder.coarse("running", p: 0.85)
        sim.run(150, opt: run)
        sim.walk(60, brisk: true)
        sim.still(120)
        sim.fidget(150)
        var effort = ActivitySim.Options()
        effort.hrAt = effortHR(start: sim.ts, rampS: 60, holdS: 100, recoverS: 120)
        effort.workout = true
        effort.workoutKind = .other
        sim.vigorous(200, opt: effort)
        var recover = ActivitySim.Options()
        recover.hrAt = effort.hrAt
        sim.still(90, opt: recover)
        sim.offWrist(60)
        sim.gap(30)
        sim.desk(120)
        sim.gap(200)
        sim.desk(90)
        let config = ActivityDecoderConfig.personalized(restingHeartRate: 54, maxHeartRate: 185)
        return Scenario(name: "mixed_observations", config: config, source: .observations(sim.observations))
    }

    /// The stored-row path the app and the worker use: 1 Hz HR, gravity + dynAccel and the step counter,
    /// with a night (sleep epochs inside an in-bed window), a logged ride and a wrist-off span.
    static func storedStreamsDay() -> Scenario {
        var sim = ActivitySim(start: 1_760_100_000, seed: 23)
        let bedStart = sim.ts
        sim.still(120)
        let sleepStart = sim.ts
        sim.sleeping(600)
        let sleepEnd = sim.ts
        sim.still(90)
        let bedEnd = sim.ts
        sim.postureShift(netDegrees: 80)
        sim.walk(200)
        sim.desk(300)
        let rideStart = sim.ts
        sim.vigorous(240)
        let rideEnd = sim.ts
        sim.still(100)
        let offStart = sim.ts
        sim.still(80)
        let offEnd = sim.ts
        sim.walk(120)
        sim.desk(150)
        var input = sim.trackInput(sleep: [DayStateSpan(start: sleepStart, end: sleepEnd)],
                                   workouts: [DayStateWorkout(start: rideStart, end: rideEnd, sport: "Cycling")],
                                   offWrist: [DayStateSpan(start: offStart, end: offEnd)])
        input.inBed = [DayStateSpan(start: bedStart, end: bedEnd)]
        let config = ActivityDecoderConfig.personalized(restingHeartRate: 61, maxHeartRate: 192)
        return Scenario(name: "stored_streams_day", config: config,
                        source: .input(input, generatedAt: 1_760_200_000))
    }

    /// Specialist modes: stairs, a logged ride and a vehicle, each named by the encoder; an uncalibrated
    /// baseline encoder and an abstaining one; a run with a logged run.
    static func specialists() -> Scenario {
        var sim = ActivitySim(start: 1_760_300_000, seed: 5)
        sim.still(60)
        var stairs = ActivitySim.Options()
        stairs.encoder = SimEncoder.coarse("stairs", p: 0.7)
        sim.walk(90, opt: stairs)
        sim.still(40)
        var ride = ActivitySim.Options()
        ride.encoder = SimEncoder.coarse("cycling", p: 0.8)
        ride.workout = true
        ride.workoutKind = .cycling
        ride.hr = 128
        sim.vigorous(240, opt: ride)
        var car = ActivitySim.Options()
        car.encoder = SimEncoder.coarse("vehicle_motion", p: 0.75)
        sim.desk(300, opt: car)
        var baseline = ActivitySim.Options()
        baseline.encoder = SimEncoder.coarse("walking", baseline: true)
        sim.walk(120, opt: baseline)
        var abstain = ActivitySim.Options()
        abstain.encoder = { ts in
            guard ts % 2 == 0 else { return nil }
            return MotionEncoderOutput(encoderId: "hart", encoderVersion: "test-1", startTs: ts - 4, endTs: ts,
                                       classProbs: ["stationary": 0.3, "walking": 0.3, "running": 0.2,
                                                    "other_movement": 0.1, "unknown": 0.1],
                                       calibrated: true, abstained: true)
        }
        sim.fidget(120, opt: abstain)
        var logged = ActivitySim.Options()
        logged.workout = true
        logged.workoutKind = .running
        logged.encoder = SimEncoder.coarse("running")
        sim.run(200, opt: logged)
        sim.walk(60)
        sim.still(100)
        return Scenario(name: "specialists", config: ActivityDecoderConfig(), source: .observations(sim.observations))
    }

    /// The second half of a day decoded from the first half's snapshot after a JSON round trip (what a
    /// restart does). The golden output is the resumed half's states and the final snapshot.
    static func resumedHalf() -> Scenario {
        let mixed = mixedObservations()
        return Scenario(name: "resumed_half", config: mixed.config, source: mixed.source)
    }

    /// Split point of `resumed_half` (index into the observations).
    static let resumeSplit = 1_100
}

/// What a scenario produced, encoded exactly as the fixtures store it.
struct ActivityGoldenOutput: Equatable {
    var states: String
    var snapshot: String
    var versions: String
    var cacheTag: String
    var events: String
    var document: String?

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }

    static func text<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder().encode(value), as: UTF8.self)
    }

    init(states: [ActivityContextState], snapshot: ActivityDecoderSnapshot, events: [ActivityTransitionEvent],
         cacheTag: String, document: ActivityContextDayDocument?) throws {
        self.states = try states.map { try Self.text($0) }.joined(separator: "\n") + "\n"
        self.snapshot = try Self.text(snapshot) + "\n"
        self.versions = try Self.text(snapshot.versions) + "\n"
        self.cacheTag = cacheTag + "\n"
        self.events = try Self.text(events) + "\n"
        self.document = try document.map { try Self.text($0) + "\n" }
    }

    init(states: String, snapshot: String, versions: String, cacheTag: String, events: String, document: String?) {
        self.states = states; self.snapshot = snapshot; self.versions = versions
        self.cacheTag = cacheTag; self.events = events; self.document = document
    }
}

extension ActivityGoldenScenarios {

    /// Run a scenario. `transformObservations` / `transformInput` let a test feed the same day through a
    /// variant (heads attached, a different config) while keeping everything else identical.
    static func run(_ scenario: Scenario, config overrideConfig: ActivityDecoderConfig? = nil,
                    transformObservations: ([ActivityObservation]) -> [ActivityObservation] = { $0 },
                    transformInput: (ActivityContextTrackInput) -> ActivityContextTrackInput = { $0 }) throws
        -> ActivityGoldenOutput {
        let config = overrideConfig ?? scenario.config
        switch scenario.source {
        case .observations(let raw):
            let obs = transformObservations(raw)
            if scenario.name == "resumed_half" {
                let first = ActivityContextTrackBuilder.decode(Array(obs.prefix(resumeSplit)), config: config)
                let snapData = try ActivityGoldenOutput.encoder().encode(first.snapshot)
                let restored = try JSONDecoder().decode(ActivityDecoderSnapshot.self, from: snapData)
                let second = ActivityContextTrackBuilder.decode(Array(obs.dropFirst(resumeSplit)), config: config,
                                                                resuming: restored)
                guard second.restore == .resumed else {
                    throw NSError(domain: "golden", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "restore was \(second.restore)"])
                }
                return try ActivityGoldenOutput(states: second.states, snapshot: second.snapshot,
                                                events: second.events, cacheTag: config.cacheTag, document: nil)
            }
            let track = ActivityContextTrackBuilder.decode(obs, config: config)
            return try ActivityGoldenOutput(states: track.states, snapshot: track.snapshot, events: track.events,
                                            cacheTag: config.cacheTag, document: nil)
        case .input(let rawInput, let generatedAt):
            let input = transformInput(rawInput)
            // A first pass over two thirds of the day (decoded in progress chunks), then the full day resumed
            // from that document: both persisted-document paths in one fixture.
            var partial = input
            partial.dayEnd = input.dayStart + (input.dayEnd - input.dayStart) * 2 / 3
            let first = ActivityContextDayBuilder.update(cached: nil, input: partial, now: generatedAt - 600,
                                                         config: config, chunkObservations: 600,
                                                         progress: { _ in })
            let second = ActivityContextDayBuilder.update(cached: first.document, input: input, now: generatedAt,
                                                          config: config)
            guard case .resumed = second.how else {
                throw NSError(domain: "golden", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "update was \(second.how)"])
            }
            let track = ActivityContextTrackBuilder.build(input, config: config)
            return try ActivityGoldenOutput(states: track.states, snapshot: track.snapshot, events: track.events,
                                            cacheTag: config.cacheTag, document: second.document)
        }
    }
}

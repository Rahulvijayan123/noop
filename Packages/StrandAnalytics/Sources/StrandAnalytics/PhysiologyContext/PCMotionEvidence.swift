import Foundation

// PCMotionEvidence.swift — heart-rate independent motion evidence from the strap's gravity / dynamic-acceleration
// stream and step counter (used by Systems B, D and G).
//
// OWNER: signal & eligibility workstream.
//
// Output vocabulary (`MotionVocabulary`): `still`, `low_movement`, `stepping`, `other_movement`; seconds with no
// motion sample are uncovered (never still). Quiet motion is evidence of stillness only — never of wear, sleep or
// rest: an off-wrist strap on a table and a sleeping wearer both read `still`.
//
// Per-second magnitude, two bases (docs/physiology-context/notes/signal.md §Motion):
//   1. `dynAccelG` — the strap's own gravity-removed magnitude, computed on-device from the full-rate IMU
//      (`GravitySample.dynAccel`, `dynamic_acceleration@41`). Preferred whenever present.
//   2. Gravity delta — `|g_t − g_{t−1}|` between consecutive 1 Hz gravity vectors, the proxy the sleep spine and the
//      workout / sedentary detectors already use (`WorkoutDetector.activitySeries`). Used only when `dynAccelG` is
//      nil, and only between samples exactly `gravityDeltaStepS` apart: a delta across a gap is not movement. The
//      first sample after a gap therefore has no magnitude and is covered-unknown, not still.
// Each second's magnitude is smoothed with a trailing mean over `smoothingS` seconds (current second included,
// same basis only), so a label never depends on later data. Thresholds (g) on the smoothed value:
//   still ≤ 0.01  (SleepStager.gravityStillThresholdG / moveDeltaThresholdG; WhoopProtocol.dynAccelStillThresholdG)
//   low_movement ≤ 0.10  (upper edge of the smoothed desk band in SedentaryDetector's calibration, 0.05–0.10 g)
//   other_movement above.
// Locomotion comes only from the step counter (WHOOP 5.0/MG): a counted, plausible increment (StepsCounter's
// class gate, bout-block rule, wrap at 65536 and 4 ticks/s ceiling) labels the seconds `(previous, current]` as
// `stepping` when the previous step sample is at most `stepMaxAttributionS` earlier. Stepping overrides the
// magnitude label. A step sample with no increment is not stillness evidence. These thresholds are engineering
// defaults inherited from existing detectors; none is validated for this purpose (notes/signal.md §Limitations).

extension PhysiologyContext {

    public struct MotionEvidenceConfig: Codable, Equatable, Sendable {
        public var version = "pc-motion-1"
        /// `dynAccelG` basis: smoothed magnitude at or below this is `still` (g).
        public var dynStillMaxG = 0.01
        /// `dynAccelG` basis: smoothed magnitude at or below this (and above still) is `low_movement` (g).
        public var dynLowMovementMaxG = 0.10
        /// Gravity-delta basis: smoothed delta at or below this is `still` (g).
        public var gravityDeltaStillMaxG = 0.01
        /// Gravity-delta basis: smoothed delta at or below this (and above still) is `low_movement` (g).
        public var gravityDeltaLowMovementMaxG = 0.10
        /// A gravity delta is computed only between samples exactly this many seconds apart (never across gaps).
        public var gravityDeltaStepS = 1
        /// Trailing smoothing window in seconds (current second included).
        public var smoothingS = 5
        /// Step increments label the seconds since the previous step sample only when it is at most this far back.
        public var stepMaxAttributionS = 5
        public init() {}
    }

    /// Which measurement produced a strap-motion label.
    public enum MotionBasis: String, Codable, CaseIterable, Sendable {
        case dynamicAcceleration = "dynamic_acceleration"
        case gravityDelta = "gravity_delta"
        case stepCounter = "step_counter"
    }

    /// The strap track plus the evidence basis behind it. `ResolvedTrack` has no field for the basis, so callers
    /// that need it (availability matrix, diagnostics) read it here.
    public struct StrapMotionEvidence: Equatable, Sendable {
        public var track: ResolvedTrack
        /// Seconds per basis: `seconds.dynamic_acceleration`, `seconds.gravity_delta`, `seconds.stepping`,
        /// `seconds.stepping_without_motion_sample`, `seconds.unknown_magnitude`, `seconds.labelled`.
        public var counts: [Diagnostic]
        public var reasons: [ReasonCode]
        public init(track: ResolvedTrack, counts: [Diagnostic], reasons: [ReasonCode]) {
            self.track = track; self.counts = counts; self.reasons = reasons
        }
        public func count(_ name: String) -> Double { counts.first { $0.name == name }?.value ?? 0 }
    }

    public enum MotionEvidence {

        public static let version = "pc-motion-1"

        // MARK: Labels
        public static let still = "still"
        public static let lowMovement = "low_movement"
        public static let stepping = "stepping"
        public static let otherMovement = "other_movement"

        // MARK: Reason codes
        public static let basisDynamicAcceleration: ReasonCode = "motion_basis_dynamic_acceleration"
        public static let basisGravityDelta: ReasonCode = "motion_basis_gravity_delta"
        public static let stepCounterStepping: ReasonCode = "step_counter_stepping"
        public static let magnitudeUnavailable: ReasonCode = "motion_magnitude_unavailable"
        public static let noMotionSamples: ReasonCode = "no_motion_samples"

        public static let reasonCodes: [ReasonCode] = [
            basisDynamicAcceleration, basisGravityDelta, stepCounterStepping, magnitudeUnavailable, noMotionSamples,
        ]

        /// Per-second strap motion labels over `window`, resolved into spans (source `.strapMotion`).
        public static func strapTrack(motion: [MotionObservation], steps: [StepObservation], window: Interval,
                                      config: MotionEvidenceConfig) -> ResolvedTrack {
            strapEvidence(motion: motion, steps: steps, window: window, config: config).track
        }

        /// The strap track with its basis accounting.
        public static func strapEvidence(motion: [MotionObservation], steps: [StepObservation], window: Interval,
                                         config: MotionEvidenceConfig) -> StrapMotionEvidence {
            guard window.isValid else {
                return StrapMotionEvidence(track: .empty(.strapMotion), counts: [], reasons: [noMotionSamples])
            }
            // One sample per second (the sanitizer already de-duplicated; this keeps the function total).
            var rows: [MotionObservation] = []
            rows.reserveCapacity(motion.count)
            for m in motion.sorted(by: { $0.ts < $1.ts }) where window.contains(m.ts) {
                if let last = rows.last, last.ts == m.ts { continue }
                rows.append(m)
            }

            // 1. Per-sample magnitude and basis.
            var basis = [MotionBasis?](repeating: nil, count: rows.count)
            var magnitude = [Double](repeating: 0, count: rows.count)
            for i in rows.indices {
                let r = rows[i]
                if let d = r.dynAccelG, d.isFinite, d >= 0 {
                    basis[i] = .dynamicAcceleration; magnitude[i] = d
                } else if i > 0, rows[i - 1].ts == r.ts - max(1, config.gravityDeltaStepS),
                          let v = vector(r), let p = vector(rows[i - 1]) {
                    let dx = v.0 - p.0, dy = v.1 - p.1, dz = v.2 - p.2
                    let delta = (dx * dx + dy * dy + dz * dz).squareRoot()
                    if delta.isFinite { basis[i] = .gravityDelta; magnitude[i] = delta }
                }
            }

            // 2. Trailing smoothing per basis, then thresholds.
            let span = max(1, config.smoothingS)
            var labels = [String?](repeating: nil, count: rows.count)
            for i in rows.indices {
                guard let b = basis[i] else { continue }
                var sum = 0.0, n = 0
                var j = i
                while j >= 0, rows[j].ts > rows[i].ts - span {
                    if basis[j] == b { sum += magnitude[j]; n += 1 }
                    j -= 1
                }
                let smoothed = sum / Double(max(1, n))
                let (stillMax, lowMax) = b == .dynamicAcceleration
                    ? (config.dynStillMaxG, config.dynLowMovementMaxG)
                    : (config.gravityDeltaStillMaxG, config.gravityDeltaLowMovementMaxG)
                labels[i] = smoothed <= stillMax ? still : (smoothed <= lowMax ? lowMovement : otherMovement)
            }

            // 3. Stepping seconds from counted step-counter increments.
            let stepIntervals = steppingIntervals(steps, window: window, config: config)

            // 4. Per-second labels: motion seconds (stepping overrides), then stepping seconds without a sample.
            var perSecond: [(ts: Int, label: String?)] = []
            perSecond.reserveCapacity(rows.count)
            var dynS = 0, gravS = 0, unknownS = 0, steppingS = 0, steppingOnlyS = 0
            var k = 0
            func inStepping(_ t: Int) -> Bool {
                while k < stepIntervals.count, stepIntervals[k].end <= t { k += 1 }
                return k < stepIntervals.count && stepIntervals[k].contains(t)
            }
            var sampleSeconds = Set<Int>()
            sampleSeconds.reserveCapacity(rows.count)
            for i in rows.indices {
                let t = rows[i].ts
                sampleSeconds.insert(t)
                if inStepping(t) {
                    perSecond.append((t, stepping)); steppingS += 1
                } else {
                    perSecond.append((t, labels[i]))
                    switch basis[i] {
                    case .dynamicAcceleration?: dynS += 1
                    case .gravityDelta?: gravS += 1
                    default: unknownS += 1
                    }
                }
            }
            for iv in stepIntervals {
                for t in iv.start..<iv.end where !sampleSeconds.contains(t) {
                    perSecond.append((t, stepping)); steppingS += 1; steppingOnlyS += 1
                }
            }
            perSecond.sort { $0.ts < $1.ts }

            // 5. Runs of consecutive seconds with one label → records → resolved track.
            var records: [LabelRecord] = []
            var runStart: Int? = nil
            var runEnd = 0
            var runLabel: String? = nil
            func flush() {
                guard let s = runStart else { return }
                records.append(LabelRecord(interval: Interval(s, runEnd), label: runLabel,
                                           unknownFraction: runLabel == nil ? 1 : 0, revision: 0,
                                           availableAt: nil, tieBreak: "strap:\(s)"))
                runStart = nil
            }
            for (t, label) in perSecond {
                if runStart != nil, t == runEnd, label == runLabel {
                    runEnd = t + 1
                } else {
                    flush()
                    runStart = t; runEnd = t + 1; runLabel = label
                }
            }
            flush()
            let track = IntervalAlgebra.resolve(records, source: .strapMotion, heartRateDependent: false)

            var reasons: [ReasonCode] = []
            if rows.isEmpty { reasons.append(noMotionSamples) }
            if dynS > 0 { reasons.append(basisDynamicAcceleration) }
            if gravS > 0 { reasons.append(basisGravityDelta) }
            if steppingS > 0 { reasons.append(stepCounterStepping) }
            if unknownS > 0 { reasons.append(magnitudeUnavailable) }
            let counts = [
                Diagnostic("seconds.dynamic_acceleration", Double(dynS)),
                Diagnostic("seconds.gravity_delta", Double(gravS)),
                Diagnostic("seconds.labelled", Double(dynS + gravS + steppingS)),
                Diagnostic("seconds.stepping", Double(steppingS)),
                Diagnostic("seconds.stepping_without_motion_sample", Double(steppingOnlyS)),
                Diagnostic("seconds.unknown_magnitude", Double(unknownS)),
            ]
            return StrapMotionEvidence(track: track, counts: counts, reasons: reasons)
        }

        // MARK: Helpers

        /// The gravity vector when all three components are finite.
        static func vector(_ m: MotionObservation) -> (Double, Double, Double)? {
            guard let x = m.x, let y = m.y, let z = m.z, x.isFinite, y.isFinite, z.isFinite else { return nil }
            return (x, y, z)
        }

        /// Merged `[previous + 1, current + 1)` spans of counted step increments inside `window`.
        static func steppingIntervals(_ steps: [StepObservation], window: Interval,
                                      config: MotionEvidenceConfig) -> [Interval] {
            var rows: [StepObservation] = []
            for s in steps.sorted(by: { $0.ts < $1.ts }) {
                if let last = rows.last, last.ts == s.ts { continue }
                rows.append(s)
            }
            guard rows.count >= 2 else { return [] }
            let hasClasses = rows.contains { $0.activityClass != nil }
            var out: [Interval] = []
            for i in 1..<rows.count {
                let prev = rows[i - 1], cur = rows[i]
                let elapsed = cur.ts - prev.ts
                guard elapsed >= 1, elapsed <= config.stepMaxAttributionS else { continue }
                let delta = (cur.counter - prev.counter) & 0xFFFF
                let block = StepsCounter.isBoutBlock(previousTs: prev.ts, currentTs: cur.ts, delta: delta)
                guard StepsCounter.shouldCountDelta(activityClass: cur.activityClass, hasActivityClasses: hasClasses,
                                                    isBoutBlock: block),
                      StepsCounter.isPlausibleDelta(previousTs: prev.ts, currentTs: cur.ts, delta: delta),
                      let iv = Interval(prev.ts + 1, cur.ts + 1).intersection(window) else { continue }
                if var last = out.last, last.end >= iv.start {
                    last.end = max(last.end, iv.end)
                    out[out.count - 1] = last
                } else {
                    out.append(iv)
                }
            }
            return out
        }
    }
}

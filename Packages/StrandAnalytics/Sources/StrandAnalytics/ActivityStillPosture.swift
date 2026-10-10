import Foundation

// ActivityStillPosture.swift — what the length of a still stretch, and the change of height that began it, say about
// sitting versus standing (hsmm-2.0).
//
// The decoder's dwell priors (seated 900 s, upright 100 s) set how long a posture lasts once known, but since
// hsmm-1.8 the seated / upright split is clamped to posture EVIDENCE, and nothing counted elapsed stillness as
// evidence. So ninety motionless minutes read the same as ninety seconds: "Standing quietly" all afternoon if a weak
// cue leaned that way (the owner, 2026-10-09 16:45–18:30). People rarely stand still for long: in free living
// (Capture-24, 151 participants, camera-labelled) the share of still time spent standing falls steeply with the
// time since the person last moved (`durationTable`, measured in
// _build-scratch/bicep-posture/A-duration/REPORT.md). This file turns that into a bounded lean toward sitting.
//
// A measured change of height (`ActivityVerticalShift`: the shoulder rises ~0.3–0.5 m when standing up) anchors
// the posture it ended in for as long as the stillness after it lasts.

public enum ActivityStillPosture {
    // Still-stretch bookkeeping (decoder side).
    /// Moving (gait, vehicle, exercise) posterior mass that ends a still stretch.
    public static let breakMovingMass = 0.5
    /// Postural-transition mass that ends one (a change of position starts a new stretch).
    public static let breakTransitionMass = 0.2
    /// Gait presence (step counter or IMU rhythm) that counts a second as stepping, and how many stepping seconds in
    /// the last `gaitWindowS` end a stretch (and a measured shift's anchor): walking away, not a foot shuffle or a
    /// 3-second walk-class blip (the owner at 17:03 on 2026-10-09, seated, no height change in the raw IMU).
    public static let breakGaitPresence = 0.4
    public static let breakGaitSeconds = 6
    public static let gaitWindowS = 10
    /// Stationary mass at which a stretch may begin.
    public static let startStationaryMass = 0.6
    /// Seconds after a measured stand-up / sit-down during which a break is the event itself, not a new movement.
    public static let anchorEventSlackS = 30

    /// The most all still-stretch priors together may lean either way (log-odds of seated over upright).
    public static let maxPriorLean = log(8.0)

    /// Extra log-odds toward seated after `stillForS` seconds of uninterrupted stillness, relative to the first
    /// minute of a stretch: piecewise-linear in log time over `durationTable`, 0 before its first knot, flat after
    /// its last, never negative, capped at `maxDurationLean`.
    public static func durationLean(stillForS: Int) -> Double {
        let t = Double(stillForS)
        let knots = durationTable
        guard let first = knots.first, t > first.s else { return 0 }
        if let last = knots.last, t >= last.s { return min(maxDurationLean, max(0, last.lean)) }
        for i in 1..<knots.count where t < knots[i].s {
            let a = knots[i - 1], b = knots[i]
            let x = (log(t) - log(a.s)) / (log(b.s) - log(a.s))
            return min(maxDurationLean, max(0, a.lean + x * (b.lean - a.lean)))
        }
        return 0
    }

    /// (seconds still, extra log-odds toward seated). See `durationLean`.
    ///
    /// Capture-24 (151 free-living participants, camera labels; _build-scratch/bicep-posture/A-duration/REPORT.md):
    /// within uninterrupted sitting-or-standing stretches, the log-odds of sitting rise over the first minute's by
    ///   elapsed      1 m   2 m   3 m   5 m   7.5 m  10 m  15 m  30 m
    ///   V1 (main)    0.22  0.46  0.75  1.17  1.56   1.95  2.26  2.48
    ///   V2 (chores)  0.12  0.27  0.44  0.68  0.92   1.15  1.37  1.64
    /// (V1 fit: 2.8·(1 − e^(−t/500 s)) − 0.16; V2 counts household chores and manual work as still and not sitting,
    /// the conservative bound for a strap that cannot tell chores from stillness). The knots are roughly their midpoint.
    /// The effect holds within a person (per-participant intercepts agree within 0.1 logit). Standing bouts are short
    /// (median 2.3 min, p90 8 min, 6.8 % past 10 min); sitting bouts long (median 9.5 min). Only the
    /// duration-specific part is used, never the ~72 % base rate of sitting, so the first minute of a stretch stays even.
    public static let durationTable: [(s: Double, lean: Double)] = [
        (60, 0), (120, 0.16), (180, 0.36), (300, 0.6), (450, 0.93), (600, 1.25), (900, 1.6), (1200, 1.94),
        (1800, 2.12), (2700, 2.36),
    ]
    /// The duration prior alone. ln 8 lets a long stillness commit a hedged "Sitting" label (the commit bar is about
    /// ln 1.9 over neutral, reached after ~5 minutes) while the class confidence caps still apply.
    public static let maxDurationLean = log(8.0)

    // Measured change of height.
    /// |displacement| (m) at which a shift counts as a stand-up or sit-down, and the lean it then anchors.
    public static let anchorMinDisplacementM = ActivityVerticalShift.minDisplacementM
    /// A rise anchors standing at ln 3: with the duration prior it commits "Standing" for about the first three still
    /// minutes and fades to unresolved by about ten, matching standing bouts (median 2.2 min, p90 7 min). A drop
    /// anchors sitting at ln 5 (sitting bouts are long, and the duration prior only adds to it). Both stay under what
    /// the upper arm's measured precision supports (Opportunity, vshift-2 acceptance: drop ≈ +2.3, rise ≈ +1.5–1.9).
    public static let anchorLeanSeated = log(5.0)
    public static let anchorLeanUpright = log(3.0)
    public static let anchorMinQuality = 0.5

    /// Wrist anchors (D-wrist-shift, non-dominant wrist, config D: drop precision ⇒ +2.27, rise ⇒ +1.18 log-odds at a
    /// calibrated accelerometer, about +1.5 / +0.7 with realistic calibration error), scaled by the shift's quality.
    public static let wristAnchorLeanSeated = 1.5
    public static let wristAnchorLeanUpright = 0.7

    /// The anchor a measured shift sets for a strap worn at `placement`: > 0 (seated) after a drop, < 0 (upright)
    /// after a rise, nil when the shift is too small, too large (a bend), too slow for this placement, an old record
    /// without its peak velocity on the wrist, or too poorly measured to say.
    public static func anchorLean(_ shift: ActivityVerticalShiftEvidence,
                                  placement: ActivityWearPlacement = .bicep) -> Double? {
        let dh = shift.displacementM
        guard shift.quality >= max(anchorMinQuality, ActivityVerticalShift.minQuality), dh.isFinite,
              abs(dh) >= anchorMinDisplacementM, abs(dh) <= ActivityVerticalShift.maxDisplacementM else { return nil }
        if let v = shift.peakVelocity {
            guard v.isFinite, (v > 0) == (dh > 0),
                  abs(v) >= ActivityVerticalShift.minPeakVelocity(for: placement) else { return nil }
        } else if placement.wristPostureCues {
            return nil
        }
        if placement.wristPostureCues {
            return dh < 0 ? wristAnchorLeanSeated * shift.quality : -wristAnchorLeanUpright * shift.quality
        }
        return dh < 0 ? anchorLeanSeated : -anchorLeanUpright
    }
}

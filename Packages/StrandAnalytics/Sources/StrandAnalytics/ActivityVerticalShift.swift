import Foundation

// ActivityVerticalShift.swift — the strap's change of height across a stand-up or sit-down, from the raw IMU
// (hsmm-2.0).
//
// Standing up lifts the shoulder, and so an upper-arm strap, by roughly 0.3–0.5 m; sitting down drops it by the same.
// Over the few seconds of a transition that is measurable by integrating the gravity-aligned acceleration twice with
// the strap still (zero velocity) at both ends. Unlike the 1 Hz forearm-orientation rules this does not care how the
// arm is held, which is what makes it the upper arm's posture cue.

/// One measured shift, as the decoder reads it (`ActivityObservation.verticalShift`, on the second it completes).
public struct ActivityVerticalShiftEvidence: Codable, Equatable, Sendable {
    /// The second the shift's movement ended (the decoder sees it then).
    public var ts: Int
    /// The second its movement began.
    public var startTs: Int
    /// Net vertical displacement of the strap, metres (> 0 up).
    public var displacementM: Double
    /// 0…1: how well the measurement held (stillness at both ends, residual drift, sampling).
    public var quality: Double
    public var version: String

    public init(ts: Int, startTs: Int, displacementM: Double, quality: Double,
                version: String = ActivityVerticalShift.version) {
        self.ts = ts; self.startTs = startTs; self.displacementM = displacementM; self.quality = quality
        self.version = version
    }
}

public enum ActivityVerticalShift {
    public static let version = "vshift-1"
}

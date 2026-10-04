import Foundation

extension UserProfile {
    /// Everything about the profile the energy estimate depends on that is not already in the app's pass
    /// signature or a stream fingerprint, plus the model version. A cache of scored days compares this string
    /// to itself, so it need only be exact: Doubles go in by bit pattern.
    public var energyInputsSignature: String {
        let rmr = measuredRmrKcalPerDay.map { String($0.bitPattern) } ?? "nil"
        return "\(EnergyConfig.modelVersion):\(weightKg.bitPattern):\(heightCm.bitPattern):\(rmr)"
    }
}

import Foundation

// MotionEvidence.swift — the per-minute output of the Python motion models (`Tools/EnergyModels`).
//
// WristMET and the wrist CNN need raw 3-axis wrist acceleration (and, for WristMET, gyroscope). Those
// run offline in Python (numpy only, no TensorFlow) over the raw-IMU capture and hand Swift one record
// per minute. Swift never re-derives anything from the IMU; it only fuses these records with the rest of
// the evidence. A day recorded without raw IMU simply has no records, and the fusion carries on without
// them with lower confidence.
//
// Wire format (schema "energy-motion-evidence-v1"):
//   {"schema":"energy-motion-evidence-v1","minutes":[
//     {"t":1790035200,"imu_s":60,
//      "wristmet":{"met":2.9,"p_active":0.97,"ood":0.1,"model":"wristmet-v1-9135f0a2"},
//      "cnn":{"met":3.4,"ood":0.2,"model":"wrist-cnn-9ca77ea"},
//      "demog_ood":0.7}]}
// Other top-level keys (`provenance`, `note`) are for people reading the file and are ignored here. A
// document written by the Python side (`Tools/EnergyModels/tests/fixtures/energy_motion_evidence_v1.example.json`)
// is decoded by `MotionEvidenceContractTests`, so the two ends cannot drift apart.

/// One minute of motion-model output. Either estimator may be absent. The CNN is only run on minutes WristMET
/// calls non-sedentary: its regression head reads ~1.4 MET on motionless input (its labels are a waist-
/// ActiGraph proxy, not calorimetry), so running it on rest minutes would add an upward offset to the
/// largest block of the day for no information.
public struct MotionEvidenceMinute: Codable, Equatable, Sendable {
    public struct Estimate: Codable, Equatable, Sendable {
        /// Estimated MET (1.0 = rest).
        public let met: Double
        /// Out-of-distribution score in [0, 1]: 0 = typical of the model's training data, 1 = far outside.
        public let ood: Double
        /// WristMET only: probability the minute is non-sedentary (the gate in front of its regressor).
        public let pActive: Double?
        /// Model identifier, pinned to the weights/commit that produced the number.
        public let model: String

        public init(met: Double, ood: Double = 0, pActive: Double? = nil, model: String) {
            self.met = met; self.ood = ood; self.pActive = pActive; self.model = model
        }

        enum CodingKeys: String, CodingKey {
            case met, ood, pActive = "p_active", model
        }
    }

    /// Start of the minute (unix seconds, aligned to the day's minute grid).
    public let minuteStart: Int
    /// Seconds of raw IMU actually present in the minute (of 60).
    public let imuSeconds: Int
    public let wristMET: Estimate?
    public let cnn: Estimate?
    /// How far the wearer's age/BMI/sex sit from WristMET's training cohort (adults with obesity), in
    /// [0, 1]. WristMET's regressor takes these as inputs, so a wearer outside the cohort is
    /// extrapolation even when the motion itself looks typical.
    public let wristMETDemographicOOD: Double?

    public init(minuteStart: Int, imuSeconds: Int, wristMET: Estimate? = nil, cnn: Estimate? = nil,
                wristMETDemographicOOD: Double? = nil) {
        self.minuteStart = minuteStart; self.imuSeconds = imuSeconds
        self.wristMET = wristMET; self.cnn = cnn
        self.wristMETDemographicOOD = wristMETDemographicOOD
    }

    enum CodingKeys: String, CodingKey {
        case minuteStart = "t", imuSeconds = "imu_s", wristMET = "wristmet", cnn,
             wristMETDemographicOOD = "demog_ood"
    }
}

/// The JSON document the Python side writes.
public struct MotionEvidenceDocument: Codable, Equatable, Sendable {
    public static let schema = "energy-motion-evidence-v1"

    public let schema: String
    public let minutes: [MotionEvidenceMinute]

    public init(minutes: [MotionEvidenceMinute]) {
        self.schema = MotionEvidenceDocument.schema
        self.minutes = minutes
    }

    /// Decode, rejecting any schema other than the one this build understands.
    public static func decode(_ data: Data) throws -> MotionEvidenceDocument {
        let doc = try JSONDecoder().decode(MotionEvidenceDocument.self, from: data)
        guard doc.schema == schema else {
            throw DecodingError.dataCorrupted(.init(codingPath: [],
                debugDescription: "unsupported motion-evidence schema \(doc.schema)"))
        }
        return doc
    }
}

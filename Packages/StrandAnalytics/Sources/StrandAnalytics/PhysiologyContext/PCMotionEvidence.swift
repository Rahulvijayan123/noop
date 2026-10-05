import Foundation

// PCMotionEvidence.swift — heart-rate independent motion evidence from the strap's gravity / dynamic-acceleration
// stream and step counter (used by Systems B, D and G).
//
// OWNER: signal & eligibility workstream. SKELETON — signatures are the shared contract.
//
// Output vocabulary (`MotionVocabulary`): `still`, `low_movement`, `stepping`, `other_movement`; seconds with no
// motion sample are uncovered (never still). Quiet motion is evidence of stillness only — never of wear, sleep or
// rest.

extension PhysiologyContext {

    public struct MotionEvidenceConfig: Codable, Equatable, Sendable {
        public var version = "pc-motion-1"
        public init() {}
    }

    public enum MotionEvidence {

        public static let reasonCodes: [ReasonCode] = []

        /// Per-second strap motion labels over `window`, resolved into spans (source `.strapMotion`).
        public static func strapTrack(motion: [MotionObservation], steps: [StepObservation], window: Interval,
                                      config: MotionEvidenceConfig) -> ResolvedTrack {
            .empty(.strapMotion)
        }
    }
}

import Foundation
import WhoopProtocol

// EnergyWorkoutClass.swift — gives a detected workout its coarse class for the Compendium prior.
//
// Reuses the existing heuristic `WorkoutTypeClassifier` unchanged. The class only nudges an ambiguous
// minute toward a Compendium value, so a class below the classifier's own confidence bar, or `.other`
// ("no candidate cleared the bar"), contributes nothing rather than a guess.

extension AnalyticsEngine {
    static let energyWorkoutClassMinConfidence = 0.5

    static func workoutCoarseClass(_ w: ExerciseSession, hr: [HRSample], gravity: [GravitySample],
                                   steps: [StepSample], restingHR: Double?, maxHR: Double?) -> CoarseWorkoutClass? {
        guard let features = WorkoutTypeFeatureExtractor.extract(
            hr: hr, gravity: gravity, steps: steps, start: w.start, end: w.end,
            restingHR: restingHR, maxHR: maxHR, caloriesKcal: nil) else { return nil }
        let prediction = WorkoutTypeClassifier.classify(features)
        guard prediction.predictedClass != .other,
              prediction.confidence >= energyWorkoutClassMinConfidence else { return nil }
        return prediction.predictedClass
    }
}

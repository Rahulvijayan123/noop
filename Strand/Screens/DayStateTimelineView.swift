import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Wording for the strap's own day states
//
// What the strap's own signals say about a stretch (see `DayStateTimeline`): its logged sleep and workouts,
// wrist on and off, and its step counter. The Heart rate page no longer lists these as a second set of
// stretches. They are shown in the stretch sheet, as the cross-check on what the activity model read over
// the same time. A wrist sensor cannot tell sitting from standing, so both are one "Still" state.

extension DayState {
    var title: String {
        switch self {
        case .sleeping: return String(localized: "Sleeping")
        case .offWrist: return String(localized: "Off wrist")
        case .running: return String(localized: "Running")
        case .walking: return String(localized: "Walking")
        case .workout: return String(localized: "Workout")
        case .active: return String(localized: "Moving")
        case .still: return String(localized: "Still")
        case .wornUnknown: return String(localized: "Worn, motion unknown")
        case .noData: return String(localized: "No data")
        }
    }

    var detail: String? {
        switch self {
        case .still: return String(localized: "Sitting or standing")
        case .active: return String(localized: "Light activity")
        case .offWrist: return String(localized: "No pulse detected")
        default: return nil
        }
    }

    var color: Color {
        switch self {
        case .sleeping: return StrandPalette.sleepDeep
        case .offWrist: return StrandPalette.textTertiary
        case .running: return StrandPalette.metricRose
        case .walking: return StrandPalette.accent
        case .workout: return StrandPalette.metricPurple
        case .active: return StrandPalette.metricAmber
        case .still: return StrandPalette.metricCyan
        case .wornUnknown: return StrandPalette.textSecondary
        case .noData: return StrandPalette.surfaceInset
        }
    }

    var symbol: String {
        switch self {
        case .sleeping: return "bed.double.fill"
        case .offWrist: return "applewatch.slash"
        case .running: return "figure.run"
        case .walking: return "figure.walk"
        case .workout: return "figure.strengthtraining.traditional"
        case .active: return "figure.mixed.cardio"
        case .still: return "figure.stand"
        case .wornUnknown: return "questionmark.circle"
        case .noData: return "icloud.slash"
        }
    }
}

extension DayStateSegment {
    var basisText: String {
        switch basis {
        case .sleepSession:
            return String(localized: "From your logged sleep")
        case .wristEvent:
            return String(localized: "The strap reported the band came off")
        case .noPulseSignal:
            return String(localized: "No pulse for the whole stretch while the strap kept recording")
        case .loggedWorkout:
            return workoutSport.map { String(localized: "From a logged workout: \($0)") }
                ?? String(localized: "From a logged workout")
        case .strapActivityClass:
            let verb = state == .running ? String(localized: "running") : String(localized: "walking")
            guard let ticks = stepTicks, durationSeconds > 0 else {
                return String(localized: "The strap labelled this \(verb)")
            }
            let rate = String(format: "%.1f", Double(ticks) / Double(durationSeconds))
            return String(localized: "The strap labelled this \(verb) and its step counter ticked \(ticks) times, about \(rate) a second")
        case .motion:
            let g = motionG.map { String(format: "%.2f", $0) } ?? "–"
            return String(localized: "Wrist motion averaged \(g) g")
        case .noMotionData:
            return String(localized: "Heart rate only, no motion readings in this stretch")
        case .noRecords:
            return String(localized: "The strap recorded nothing here. Not synced yet, or it was off or charging.")
        }
    }

    var startDate: Date { Date(timeIntervalSince1970: TimeInterval(start)) }
    var endDate: Date { Date(timeIntervalSince1970: TimeInterval(end)) }
}

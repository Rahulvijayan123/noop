import SwiftUI
import StrandDesign

extension TodaySection {
    var customizationIcon: String {
        switch self {
        case .hero: return "gauge.with.dots.needle.67percent"
        case .synthesis: return "sparkles"
        case .keyMetrics: return "square.grid.2x2"
        case .workouts: return "figure.run"
        case .heartRate: return "waveform.path.ecg"
        case .menstrualCycle: return "drop.degreesign"
        case .journal: return "book.closed"
        case .addedCards: return "rectangle.stack.badge.plus"
        }
    }

    var customizationTint: Color {
        switch self {
        case .hero: return StrandPalette.chargeColor
        case .synthesis: return StrandPalette.textSecondary
        case .keyMetrics: return StrandPalette.metricPurple
        case .workouts: return StrandPalette.effortColor
        case .heartRate: return StrandPalette.metricRose
        case .menstrualCycle: return StrandPalette.restColor
        case .journal: return StrandPalette.metricAmber
        case .addedCards: return StrandPalette.textSecondary
        }
    }
}

extension KeyMetric {
    /// The tile's symbol, on the Today tile and in the editor alike.
    var customizationIcon: String {
        switch self {
        case .charge: return "bolt.heart"
        case .effort: return "bolt"
        case .rest: return "moon.stars"
        case .hrv: return "waveform.path.ecg"
        case .restingHr: return "heart.fill"
        case .bloodOxygen: return "drop.fill"
        case .respiratory: return "lungs.fill"
        case .steps: return "figure.walk"
        case .weight: return "scalemass"
        case .calories: return "flame.fill"
        // Same glyph the sibling "Your Cards" tile (`DashboardCard.skinTemp`) already uses.
        case .skinTemp: return "thermometer.medium"
        }
    }

    /// The metric's domain colour, on its icon only (the tile surface is never tinted). Interactive
    /// accent is not a data colour, so no metric uses it.
    var customizationTint: Color {
        switch self {
        case .charge: return StrandPalette.chargeColor
        case .effort: return StrandPalette.effortColor
        case .rest: return StrandPalette.restColor
        case .hrv, .respiratory: return StrandPalette.metricPurple
        case .restingHr: return StrandPalette.metricRose
        case .bloodOxygen, .steps: return StrandPalette.metricCyan
        case .calories, .skinTemp, .weight: return StrandPalette.metricAmber
        }
    }
}

extension DashboardCard {
    var customizationTint: Color {
        switch self {
        case .stress, .respiratory: return StrandPalette.accent
        case .fitnessAge: return StrandPalette.chargeColor
        case .vo2max: return StrandPalette.chargeColor
        case .vitality, .hrv: return StrandPalette.metricPurple
        case .restingHr: return StrandPalette.metricRose
        case .steps, .stepsAverage30, .bloodOxygen, .hydration: return StrandPalette.metricCyan
        case .skinTemp, .calories: return StrandPalette.metricAmber
        case .sleep: return StrandPalette.restColor
        case .coupled: return StrandPalette.chargeColor
        case .coach: return StrandPalette.accent
        }
    }
}

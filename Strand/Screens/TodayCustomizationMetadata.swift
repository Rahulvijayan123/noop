import SwiftUI
import StrandDesign

extension TodaySection {
    var customizationIcon: String {
        switch self {
        case .hero: return "gauge.with.dots.needle.67percent"
        case .liveSession: return "figure.run.circle"
        case .synthesis: return "sparkles"
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
        case .liveSession: return StrandPalette.metricCyan
        case .synthesis: return StrandPalette.accent
        case .workouts: return StrandPalette.effortColor
        case .heartRate: return StrandPalette.metricRose
        case .menstrualCycle: return StrandPalette.restColor
        case .journal: return StrandPalette.metricAmber
        case .addedCards: return StrandPalette.accent
        }
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - ActivityContext wording and pieces
//
// The decoded state, not one label: three independent heads (posture, locomotion, arm behaviour), each a
// probability distribution, plus intensity, confidence and the wear and sleep context. Composite labels such
// as "Desk sitting" are a derived view of those heads. The page that lists them is `DayStretchesSection`; this
// file holds the words and colours it and the stretch sheet share. A wrist cannot see body height, so sitting
// and standing are only ever "likely".

// MARK: Wording

extension PostureClass {
    var displayName: String {
        switch self {
        case .recumbent: return String(localized: "Lying down")
        case .seatedLikely: return String(localized: "Seated (likely)")
        case .uprightStationary: return String(localized: "Upright, still")
        case .posturalTransition: return String(localized: "Changing position")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension LocomotionClass {
    var displayName: String {
        switch self {
        case .stationary: return String(localized: "Stationary")
        case .walking: return String(localized: "Walking")
        case .briskWalking: return String(localized: "Brisk walking")
        case .running: return String(localized: "Running")
        case .stairs: return String(localized: "Stairs")
        case .cycling: return String(localized: "Cycling")
        case .vehicleMotion: return String(localized: "Vehicle motion")
        case .other: return String(localized: "Other movement")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension ArmBehaviorClass {
    var displayName: String {
        switch self {
        case .quiet: return String(localized: "Quiet")
        case .deskLike: return String(localized: "Desk-like")
        case .fidgeting: return String(localized: "Fidgeting")
        case .repetitiveHandMotion: return String(localized: "Repetitive hand motion")
        case .activeGesturing: return String(localized: "Gesturing")
        case .exerciseMotion: return String(localized: "Exercise motion")
        case .other: return String(localized: "Other")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension ActivityTransitionKind {
    var displayName: String {
        switch self {
        case .sitToStandLike: return String(localized: "Sit-to-stand-like")
        case .standToSitLike: return String(localized: "Stand-to-sit-like")
        case .lyingDownLike: return String(localized: "Lying-down-like")
        case .gettingUpLike: return String(localized: "Getting-up-like")
        case .walkStart: return String(localized: "Started walking")
        case .walkStop: return String(localized: "Stopped walking")
        case .runStart: return String(localized: "Started running")
        case .runStop: return String(localized: "Stopped running")
        }
    }
}

extension SleepContextState {
    var displayName: String {
        switch self {
        case .asleep: return String(localized: "Asleep")
        case .awake: return String(localized: "Awake")
        case .unknown: return String(localized: "Not known")
        }
    }
}

extension WearContextState {
    var displayName: String {
        switch self {
        case .onWrist: return String(localized: "On wrist")
        case .offWrist: return String(localized: "Off wrist")
        case .unknown: return String(localized: "Not known")
        }
    }
}

/// The colour family a display label belongs to. Many labels ("Desk sitting", "Sitting quietly") are one
/// family on the lane; the label itself stays in the list and the detail card.
enum ActivityFamily: CaseIterable, Hashable {
    case asleep, sitting, standing, stillUnsure, walking, running, otherMovement, changing, offWrist, unclear

    static func of(_ label: String) -> ActivityFamily {
        switch label {
        case ActivityDisplay.offWrist: return .offWrist
        case ActivityDisplay.unclear: return .unclear
        case "Asleep", "Resting in bed", "Lying down": return .asleep
        case "Running": return .running
        case "Walking", "Brisk walking", "Taking stairs": return .walking
        case "Cycling", "In a vehicle", "Exercising", "Moving": return .otherMovement
        case "Changing position": return .changing
        case "Still, sitting or standing", "Hands busy, sitting or standing", "Stationary": return .stillUnsure
        default:
            if label.hasPrefix("Sitting") || label == "Desk sitting" { return .sitting }
            if label.hasPrefix("Standing") { return .standing }
            return .unclear
        }
    }

    var title: String {
        switch self {
        case .asleep: return String(localized: "Asleep or lying down")
        case .sitting: return String(localized: "Sitting")
        case .standing: return String(localized: "Standing")
        case .stillUnsure: return String(localized: "Still, sitting or standing")
        case .walking: return String(localized: "Walking")
        case .running: return String(localized: "Running")
        case .otherMovement: return String(localized: "Other movement")
        case .changing: return String(localized: "Changing position")
        case .offWrist: return String(localized: "Off wrist")
        case .unclear: return String(localized: "Unclear")
        }
    }

    var color: Color {
        switch self {
        case .asleep: return StrandPalette.sleepDeep
        case .sitting: return StrandPalette.metricCyan
        case .standing: return StrandPalette.metricPurple
        case .stillUnsure: return StrandPalette.metricCyan.opacity(0.5)
        case .walking: return StrandPalette.accent
        case .running: return StrandPalette.metricRose
        case .otherMovement: return StrandPalette.metricAmber
        case .changing: return StrandPalette.metricAmber.opacity(0.6)
        case .offWrist: return StrandPalette.textTertiary
        case .unclear: return StrandPalette.surfaceInset
        }
    }

    var symbol: String {
        switch self {
        case .asleep: return "bed.double.fill"
        case .sitting, .stillUnsure: return "chair.lounge.fill"
        case .standing: return "figure.stand"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .otherMovement: return "figure.mixed.cardio"
        case .changing: return "arrow.up.arrow.down"
        case .offWrist: return "applewatch.slash"
        case .unclear: return "questionmark.circle"
        }
    }

    static let displayOrder: [ActivityFamily] = [
        .asleep, .sitting, .stillUnsure, .standing, .changing, .walking, .running, .otherMovement, .offWrist, .unclear,
    ]
}

// MARK: Pieces

/// Marks the newest stretch in a list.
struct LatestTag: View {
    var body: some View {
        Text("Latest")
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(StrandPalette.accent.opacity(0.14)))
    }
}

struct ProbabilityBar: View {
    let value: Double
    let tint: Color
    var width: CGFloat = 96

    var body: some View {
        Capsule()
            .fill(tint.opacity(0.18))
            .frame(width: width, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: width * CGFloat(min(1, max(0, value))), height: 6)
            }
    }
}

struct HeadBlock: View {
    let title: String
    let rows: [(name: String, p: Double)]
    let tint: Color

    /// The strongest answers of a head, most likely first. Anything under 5% is noise at this resolution.
    static func rows<C: RawRepresentable & Hashable & CaseIterable & Sendable>(
        _ head: HeadProbabilities<C>, name: KeyPath<C, String>, limit: Int = 3
    ) -> [(name: String, p: Double)] where C.RawValue == String {
        head.values
            .filter { $0.value >= 0.05 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .prefix(limit)
            .map { (name: $0.key[keyPath: name], p: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .textCase(.uppercase)
            if rows.isEmpty {
                Text("No reading")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.name)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    ProbabilityBar(value: row.p, tint: tint)
                    Text("\(Int((row.p * 100).rounded()))%")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}

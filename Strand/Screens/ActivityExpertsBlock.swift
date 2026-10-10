import SwiftUI
import StrandDesign
import StrandAnalytics

/// Which evidence sources the activity decoder used over a stretch, and what ElderNet read from the raw
/// motion: shown inside the stretch sheet's "How this was read" so a reading is traceable to its sources.
struct ActivityExpertsSummary: Equatable {
    struct Gait: Equatable {
        var probability: Double
        var cadenceSpm: Double?
        var speedMps: Double?
        var windows: Int
    }

    var experts: [String]
    var detail: ActivityDetail?
    var gait: Gait?

    /// Whether any run recorded an expert, a specific reading or a gait reading.
    var hasContent: Bool { !experts.isEmpty || detail != nil || gait != nil }

    private static let order = ["encoder", "hart_fine", "transition", "eldernet", "motion_heads"]

    /// The runs overlapping [start, end), weighted by the seconds they overlap it.
    static func over(start: Int, end: Int, runs: [ActivityContextRun]) -> ActivityExpertsSummary {
        var experts = Set<String>()
        var detailSeconds: [ActivityDetail: Int] = [:]
        var gaitWeight = 0.0, gaitProb = 0.0
        var cadenceWeight = 0.0, cadence = 0.0
        var speedWeight = 0.0, speed = 0.0
        var gaitWindows = 0
        for run in runs {
            let seconds = min(run.end, end) - max(run.start, start)
            guard seconds > 0 else { continue }
            experts.formUnion(run.experts)
            if let d = run.classification.detail { detailSeconds[d, default: 0] += seconds }
            if let g = run.gait, g.windows > 0 {
                let w = Double(g.windows)
                gaitWeight += w; gaitProb += g.gaitProbability * w
                if let c = g.cadenceSpm { let cw = Double(max(1, g.cadenceWindows)); cadenceWeight += cw; cadence += c * cw }
                if let s = g.speedMps { let sw = Double(max(1, g.speedWindows)); speedWeight += sw; speed += s * sw }
                gaitWindows += g.windows
            } else if run.gaitStates > 0, let p = run.gaitProbability {
                let w = Double(run.gaitStates)
                gaitWeight += w; gaitProb += p * w
                if let c = run.gaitCadenceSpm { cadenceWeight += w; cadence += c * w }
                gaitWindows += run.gaitStates
            }
        }
        if gaitWeight > 0 { experts.insert("eldernet") }
        let ordered = order.filter(experts.contains) + experts.subtracting(order).sorted()
        let gait = gaitWeight > 0
            ? Gait(probability: gaitProb / gaitWeight,
                   cadenceSpm: cadenceWeight > 0 ? cadence / cadenceWeight : nil,
                   speedMps: speedWeight > 0 ? speed / speedWeight : nil,
                   windows: gaitWindows)
            : nil
        return ActivityExpertsSummary(experts: ordered,
                                      detail: detailSeconds.max { $0.value < $1.value }?.key,
                                      gait: gait)
    }

    static func name(_ expert: String) -> String {
        switch expert {
        case "encoder": return String(localized: "Activity model")
        case "hart_fine": return String(localized: "Full activity breakdown")
        case "transition": return String(localized: "Position-change expert")
        case "eldernet": return String(localized: "ElderNet gait")
        case "motion_heads": return String(localized: "ActiNet motion heads")
        default: return expert
        }
    }

    static func name(_ detail: ActivityDetail) -> String {
        switch detail {
        case .stairs: return String(localized: "Taking stairs")
        case .inVehicle: return String(localized: "In a vehicle")
        case .posturalTransition: return String(localized: "Changing position")
        }
    }
}

struct ActivityExpertsBlock: View {
    let summary: ActivityExpertsSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider().opacity(0.4)
            Text("Evidence used")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            if summary.experts.isEmpty {
                Text("The strap's motion, steps and heart rate")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(summary.experts.map(ActivityExpertsSummary.name).joined(separator: " · "))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let detail = summary.detail {
                row(String(localized: "Specific reading"), ActivityExpertsSummary.name(detail))
            }
            if let gait = summary.gait {
                row(String(localized: "ElderNet: walking"), "\(Int((gait.probability * 100).rounded()))%")
                if let cadence = gait.cadenceSpm {
                    row(String(localized: "ElderNet: cadence"), "\(Int(cadence.rounded())) steps/min")
                }
                if let speed = gait.speedMps {
                    row(String(localized: "ElderNet: speed"), String(format: "%.1f m/s", speed))
                }
            } else {
                row(String(localized: "ElderNet gait"), String(localized: "No reading here"))
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
            Spacer(minLength: 8)
            Text(value)
                .font(StrandFont.footnote.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
        }
    }
}

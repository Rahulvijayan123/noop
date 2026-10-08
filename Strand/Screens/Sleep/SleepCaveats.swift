import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - Stage caveats
//
// The four honest notes a night's stages can carry (H9 low confidence, #345 may be incomplete, #1716 partly
// recorded, the Oura raw-stages note). The gates are the SAME shared rules the screens always called
// (`SleepView.isStagingLowConfidence`, `SleepView.stageSparseNoteApplies`, `HypnogramCoverage`), resolved
// here once instead of in two private copies. The copy is verbatim.
//
// Where they show: the night page prints every applicable note in full; the Sleep tab and Today's Stages
// card show only the first one's badge (a glance), and the badge opens the night page.

enum SleepCaveat: Hashable, Identifiable {
    case lowConfidence
    case incomplete
    case partlyRecorded(percent: Int)
    case ouraRawStages

    var id: String {
        switch self {
        case .lowConfidence: return "lowConfidence"
        case .incomplete: return "incomplete"
        case .partlyRecorded: return "partlyRecorded"
        case .ouraRawStages: return "ouraRawStages"
        }
    }

    /// The badge word.
    var badge: LocalizedStringKey {
        switch self {
        case .lowConfidence: return "Low confidence"
        case .incomplete: return "May be incomplete"
        case .partlyRecorded: return "Partly recorded"
        case .ouraRawStages: return "Raw on-device stages"
        }
    }

    var tone: StrandTone {
        switch self {
        case .ouraRawStages: return .neutral
        default: return .warning
        }
    }

    /// The full note, verbatim from the stage card it used to sit under.
    var message: String {
        switch self {
        case .lowConfidence:
            return String(localized: "This night scored high efficiency but very little deep or REM, more likely a staging estimate miss than a real restorative shortfall. The totals are kept as-is; read the split with care.")
        case .incomplete:
            return String(localized: "Your strap recorded little movement overnight (common on WHOOP 4.0), so this night may be under-detected and the sleep total can read short. Make sure the strap fully synced; the numbers are kept as-is.")
        case .partlyRecorded(let pct):
            return String(localized: "Only \(pct)% of this night's window has stage data. The stage totals cover only that part of the night.")
        case .ouraRawStages:
            return String(localized: "This split is the ring's raw on-device classification read over Bluetooth, not the adjusted stages the Oura app shows. Expect more Awake and less Deep/REM here than in the Oura app for the same night.")
        }
    }

    /// Every caveat that applies to `night`, in the order the stage card always listed them.
    ///
    /// - Parameters:
    ///   - todayEfficiency: `repo.today?.efficiency`, the fallback the H9 gate has always used.
    ///   - isOura: `repo.activeDeviceIsOura`.
    static func applicable(to night: Night, todayEfficiency: Double?, isOura: Bool) -> [SleepCaveat] {
        var out: [SleepCaveat] = []
        // H9: a high-efficiency night whose deep+REM share is implausibly low (a likely staging miss).
        let s = night.stages
        if let effPct = gateEfficiencyPct(night, todayEfficiency: todayEfficiency),
           SleepView.isStagingLowConfidence(asleepMin: s.asleep, deepMin: s.deep, remMin: s.rem,
                                            efficiency: effPct / 100.0) {
            out.append(.lowConfidence)
        }
        // #345: staged on sparse motion AND actually reading short.
        if SleepView.stageSparseNoteApplies(stagingSparse: night.sourceBlocks.contains { $0.stagingSparse == true },
                                            asleepMin: night.stages.asleep) {
            out.append(.incomplete)
        }
        // #1716: the timeline accounts for less than the coverage floor of the window. Floored, never
        // rounded, so 94.8 % cannot print as 95 % beside a gate that flagged it.
        let group = SleepView.mainNightGroup(night.sourceBlocks, habitualMidsleepSec: night.habitualMidsleepSec)
        if let coverage = HypnogramCoverage.groupFraction(group.isEmpty ? night.sourceBlocks : group),
           coverage < HypnogramCoverage.minCoverage {
            out.append(.partlyRecorded(percent: Int((coverage * 100).rounded(.down))))
        }
        if isOura { out.append(.ouraRawStages) }
        return out
    }

    /// The efficiency the H9 gate reads, in percent: the stored session value, else today's stored value,
    /// else asleep over the staged time in bed. Verbatim of the stage card's `efficiencyPct`, kept for the
    /// gate so the badge can never disagree with the persisted Rest confidence. (Displays read
    /// `SleepNightFacts.efficiencyPct`, which does not borrow today's value for an older night.)
    static func gateEfficiencyPct(_ night: Night, todayEfficiency: Double?) -> Double? {
        if let stored = night.session.efficiency ?? todayEfficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }
}

/// One caveat as a badge (the glance surfaces).
struct SleepCaveatBadge: View {
    let caveat: SleepCaveat
    var body: some View {
        StatePill(caveat.badge, tone: caveat.tone)
    }
}

/// Every applicable caveat in full, one row each (the night page).
struct SleepCaveatList: View {
    let caveats: [SleepCaveat]

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                ForEach(Array(caveats.enumerated()), id: \.element.id) { index, caveat in
                    if index > 0 { NoopListDivider(leadingInset: 0) }
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        SleepCaveatBadge(caveat: caveat)
                        Text(caveat.message)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

// MARK: - Per-night facts (display)

/// The numbers a night's summary prints, resolved once from the model the screen already holds.
enum SleepNightFacts {
    /// The night's efficiency as the Sleep surfaces DISPLAY it: the stored daily value for the night's wake
    /// day (the same field the Sleep efficiency page charts), else the stored session value, else asleep
    /// over staged time in bed. Unlike the H9 gate it never borrows TODAY's value for an older night.
    static func efficiencyPct(_ night: Night, days: [DailyMetric]) -> Double? {
        let wakeDay = SleepFormat.wakeDayKey(night.session.endTs)
        if let e = days.last(where: { $0.day == wakeDay })?.efficiency {
            return e <= 1.0 ? e * 100 : e
        }
        if let stored = night.session.efficiency {
            return stored <= 1.0 ? stored * 100 : stored
        }
        let bed = night.timeInBed
        guard bed > 0 else { return nil }
        return Swift.min(100, night.stages.asleep / bed * 100)
    }

    /// The window from the displayed bedtime to wake, in minutes (what "In bed" means on the summary).
    static func windowMinutes(_ night: Night) -> Double {
        Double(max(0, night.session.endTs - night.session.effectiveStartTs)) / 60
    }
}

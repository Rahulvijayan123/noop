import SwiftUI
import StrandDesign

/// The card at the top of Pair & connect: what state the link is in, in words, and the one thing to do next.
///
/// Every part has a fixed place and a fixed size. The state pill and the battery pill share one line; the
/// strap row is as tall as the model picker whether the picker or the strap's name is showing; the message sits
/// in a box that scrolls rather than grows; the lead button has its slot whether or not there is a button. So
/// connecting, dropping, searching and pairing change what is written in the card, never how big it is.
struct StrapStatusCard: View {
    let status: StrapConnectionStatus
    let link: StrapLinkInputs
    let selectedModel: WhoopModel
    let onPickModel: (WhoopModel) -> Void
    let onLead: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Lines the message box holds before it scrolls. Most messages are two or three; the box is taller at the
    /// accessibility text sizes, where the same sentence runs to many more lines.
    static func messageLines(for size: DynamicTypeSize) -> Int { size.isAccessibilitySize ? 6 : 4 }

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                pillRow
                strapRow
                FixedMessageArea(text: status.detail, lines: Self.messageLines(for: dynamicTypeSize))
                leadSlot
            }
        }
        .animation(reduceMotion ? nil : PairingMotion.settle, value: status.phase)
    }

    // MARK: Pills

    private var pillRow: some View {
        HStack(spacing: NoopMetrics.space2) {
            StatePill("\(status.title)", tone: status.tone)
                .id(status.phase)
                .transition(.opacity)
            Spacer(minLength: NoopMetrics.space2)
            batteryPill
        }
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }

    @ViewBuilder private var batteryPill: some View {
        if let pct = link.batteryPct {
            let rounded = Int(pct.rounded())
            Group {
                if !link.connected {
                    StatePill("Last battery \(rounded)%", tone: Self.batteryTone(pct), showsDot: false)
                } else if link.charging == true {
                    StatePill("Battery \(rounded)% · Charging", tone: Self.batteryTone(pct), showsDot: false)
                } else {
                    StatePill("Battery \(rounded)%", tone: Self.batteryTone(pct), showsDot: false)
                }
            }
            .transition(.opacity)
        }
    }

    static func batteryTone(_ pct: Double) -> StrandTone {
        if pct <= 15 { return .critical }
        if pct <= 30 { return .warning }
        return .positive
    }

    // MARK: Strap

    /// Whether the row offers a strap-family choice. It never does: WHOOP 5.0/MG is the only WHOOP model (4.0 was
    /// retired), so there is nothing to choose and the row always names the strap. The picker view stays in the
    /// row, hidden, so the card keeps the fixed height every pairing state relies on.
    static func showsModelPicker(_ phase: StrapConnectionStatus.Phase) -> Bool { false }

    /// "WHOOP 5.0 / MG · Firmware 50.40.1.0" while a link is up, just the model otherwise.
    var strapSummary: String {
        guard link.connected, let firmware = link.firmware, !firmware.isEmpty else {
            return selectedModel.displayName
        }
        return selectedModel.displayName + " · " + String(localized: "Firmware \(firmware)")
    }

    private var strapRow: some View {
        let picking = Self.showsModelPicker(status.phase)
        // No "Your strap" caption over the name: the card is the strap's, so the label only repeated it.
        return VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            ZStack(alignment: .leading) {
                modelPicker
                    .opacity(picking ? 1 : 0)
                    .allowsHitTesting(picking)
                    .accessibilityHidden(!picking)
                Text(verbatim: strapSummary)
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(picking ? 0 : 1)
                    .accessibilityHidden(picking)
            }
        }
        .animation(reduceMotion ? nil : PairingMotion.settle, value: picking)
    }

    private var modelPicker: some View {
        SegmentedPillControl(
            WhoopModel.allCases,
            selection: Binding(get: { selectedModel }, set: onPickModel),
            adaptsToAvailableWidth: true,
            label: { $0.displayName }
        )
    }

    // MARK: Lead action

    private var leadSlot: some View {
        NoopButton("Find my strap", fullWidth: true) { }
            .hidden()
            .accessibilityHidden(true)
            .overlay {
                if let title = status.leadTitle {
                    NoopButton(LocalizedStringKey(title), systemImage: Self.leadSymbol(status.lead), fullWidth: true) {
                        onLead()
                    }
                    .id(title)
                    .transition(.opacity)
                }
            }
    }

    static func leadSymbol(_ lead: StrapConnectionStatus.LeadAction?) -> String? {
        switch lead {
        case .connect: return "arrow.clockwise"
        case .findStrap: return "magnifyingglass"
        case .repair: return "link"
        case nil: return nil
        }
    }
}

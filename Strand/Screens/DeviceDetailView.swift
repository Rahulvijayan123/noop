import SwiftUI
import StrandDesign
import WhoopStore

// MARK: - Device page
//
// One band, one tap down from its Devices card: its state, what it records and what Nara uses it for, the
// connection details (firmware, pack voltage, history format, clock) and the honest caveats. Read-only: every
// action stays in the card's ⋯ menu, where the confirmations that guard them are presented. The values are
// the ones the Devices list already computed for the card (the card builds this page), so the two can never
// disagree.

struct DeviceDetailView: View {
    let device: PairedDevice
    let profile: DeviceCapabilityProfile
    let pillLabel: String
    let pillTone: StrandTone
    let lastSeen: String
    var batteryPct: Int?
    var batteryMv: Int?
    var firmware: String?
    var historyLayout: Int?
    var clockLine: String?
    var clockWarning: String?
    var syncLine: String?
    var syncNote: String?
    var bondHint: String?

    private var isWhoop: Bool {
        device.id == "my-whoop" || device.brand.caseInsensitiveCompare("WHOOP") == .orderedSame
    }

    var body: some View {
        ScreenScaffold(title: LocalizedStringKey(device.displayName), titleDisplay: .navigationBar) {
            if let bondHint {
                InlineNotice(bondHint, title: String(localized: "Connected, but not paired"), tone: .warning)
            }
            if let clockWarning {
                InlineNotice(clockWarning, tone: .warning)
            }

            NoopListSection("Status") {
                row("State") { StatePill(LocalizedStringKey(pillLabel), tone: pillTone) }
                NoopListDivider()
                valueRow("Model", profile.displayModel)
                NoopListDivider()
                valueRow("Seen", lastSeen)
                if let batteryPct {
                    NoopListDivider()
                    valueRow("Battery", "\(batteryPct) %")
                }
                if let syncLine {
                    NoopListDivider()
                    valueRow("Strap history", syncLine)
                }
            }

            NoopListSection("Records", footer: profile.footnote.isEmpty ? nil : LocalizedStringKey(profile.footnote)) {
                paragraph(profile.captures)
            }

            NoopListSection("Nara uses it for") {
                paragraph(profile.powers)
            }

            if hasConnectionDetails {
                NoopListSection("Connection", footer: syncNote.map { LocalizedStringKey($0) }) {
                    VStack(spacing: 0) {
                        if let firmware { valueRow("Firmware", firmware, divider: false) }
                        if let batteryMv {
                            if firmware != nil { NoopListDivider() }
                            valueRow("Battery voltage", String(format: "%.2f V", Double(batteryMv) / 1000.0), divider: false)
                        }
                        if let historyLayout {
                            if firmware != nil || batteryMv != nil { NoopListDivider() }
                            valueRow("History format", "v\(historyLayout)", divider: false)
                        }
                        if let clockLine {
                            if firmware != nil || batteryMv != nil || historyLayout != nil { NoopListDivider() }
                            paragraph(clockLine)
                        }
                    }
                }
            } else if let syncNote {
                InlineNotice(syncNote, tone: .neutral)
            }

            if isWhoop {
                NoopListSection {
                    NavigationLink {
                        NoopLimitationsView()
                    } label: {
                        NoopListRow(icon: "checklist", iconColor: StrandPalette.accent,
                                    title: "What each WHOOP can read")
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var hasConnectionDetails: Bool {
        firmware != nil || batteryMv != nil || historyLayout != nil || clockLine != nil
    }

    private func row<Trailing: View>(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(title)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            trailing()
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight)
    }

    private func valueRow(_ title: LocalizedStringKey, _ value: String, divider: Bool = false) -> some View {
        NoopListRow(icon: nil, title: title, value: value, showsChevron: false)
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, NoopMetrics.cardPadding)
            .padding(.vertical, NoopMetrics.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

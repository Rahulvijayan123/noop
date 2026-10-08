import SwiftUI
import StrandDesign

/// First-run acknowledgment gate (clickwrap). Shown over EVERYTHING — before onboarding, pairing, or
/// any Bluetooth access — until the current `Terms.currentVersion` is accepted, and again if the
/// terms materially change. The user must tick the (un-pre-checked) box and tap Accept; the accepted
/// version is then stored locally, the on-device equivalent of a consent record. See `Terms` / `TERMS.md`.
struct TermsGateView: View {
    let onAccept: () -> Void
    /// One flag per `Terms.attestations` entry; every one must be ticked before Accept enables.
    @State private var checks: [Bool] = Array(repeating: false, count: Terms.attestations.count)

    private var allChecked: Bool { checks.allSatisfy { $0 } }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                        Text("Before you use Nara")
                            .font(StrandFont.title1)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .accessibilityAddTraits(.isHeader)
                        Text("Read and confirm each point.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                    }

                    NoopCard(padding: 0) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(Terms.points.enumerated()), id: \.offset) { index, point in
                                if index > 0 { NoopListDivider() }
                                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                                    Text(point.0)
                                        .font(StrandFont.headline)
                                        .foregroundStyle(StrandPalette.textPrimary)
                                    Text(point.1)
                                        .font(StrandFont.subhead)
                                        .foregroundStyle(StrandPalette.textSecondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                .padding(NoopMetrics.cardPadding)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }

                    NoopListSection("Please confirm each of these:", footer: "The full terms are in TERMS.md, shipped with the app. This summary is not legal advice.") {
                        ForEach(Array(Terms.attestations.enumerated()), id: \.offset) { idx, line in
                            if idx > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                            attestationRow(idx, line)
                        }
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, NoopMetrics.space6)
                .padding(.bottom, NoopMetrics.space4)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold. Shown before onboarding/pairing,
            // on top of everything, so this is the very first screen a new install sees.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif

            Rectangle()
                .fill(StrandPalette.hairline)
                .frame(height: NoopMetrics.hairlineWidth)

            NoopButton("Accept and continue", kind: .primary, fullWidth: true, action: onAccept)
                .disabled(!allChecked)
                .keyboardShortcut(.defaultAction)
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space4)
        }
        .frame(maxWidth: 560, maxHeight: 760)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    /// One statement to confirm: a checkmark the person ticks themselves (never pre-ticked), the whole row the
    /// tap target.
    private func attestationRow(_ idx: Int, _ line: String) -> some View {
        Button {
            checks[idx].toggle()
        } label: {
            HStack(alignment: .top, spacing: NoopMetrics.space3) {
                Image(systemName: checks[idx] ? "checkmark.circle.fill" : "circle")
                    .font(StrandFont.icon(.row))
                    .foregroundStyle(checks[idx] ? StrandPalette.accent : StrandPalette.textTertiary)
                    .frame(width: 28)
                Text(line)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, NoopMetrics.cardPadding)
            .padding(.vertical, NoopMetrics.space3)
            .frame(minHeight: NoopMetrics.listRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(MoreRowPressStyle())
        .accessibilityAddTraits(checks[idx] ? .isSelected : [])
        .accessibilityHint("Double-tap to confirm")
    }
}

import SwiftUI

// MARK: - InlineNotice
//
// The one notice: a state the page needs to say in a sentence (the strap needs re-pairing, history is still
// syncing, Apple Health is not connected, a backup is unencrypted), with at most one action. It replaces the
// per-screen banners (coloured strokes, tinted fills, icon tiles), so a warning looks the same everywhere.
// The tone is carried by the symbol and its colour; the fill stays neutral.

/// A one- or two-line notice with a tone symbol and an optional action.
///
/// ```swift
/// InlineNotice("Your strap needs re-pairing before it can sync.", tone: .warning,
///              action: .init("Re-pair") { showRepair = true })
/// InlineNotice("History is still syncing from your strap.", title: "Syncing", tone: .neutral)
/// // Inside a card, on its inset well:
/// InlineNotice("Apple Health is not connected.", tone: .neutral, placement: .inCard)
/// ```
///
/// - `placement: .page` (default) draws it as a card on the canvas; `.inCard` on `NoopInsetSurface`
///   inside a card. Never a coloured border or a tinted fill.
/// - `tone` picks the symbol (`info.circle`, `exclamationmark.triangle`, `xmark.octagon`,
///   `checkmark.circle`) and its colour; the text is always `textPrimary` / `textSecondary`.
/// - The message wraps (this is the one place a short sentence belongs on a top-level page); keep it to
///   one or two lines. The action is a single accent text button with a 44 pt target.
/// - One VoiceOver element for the text; the action stays its own button.
public struct InlineNotice: View {
    /// The notice's one action.
    public struct Action {
        let label: LocalizedStringKey
        let perform: () -> Void
        public init(_ label: LocalizedStringKey, perform: @escaping () -> Void) {
            self.label = label
            self.perform = perform
        }
    }

    public enum Placement: Sendable {
        /// On the page canvas, as a card.
        case page
        /// Inside a card, on the inset well.
        case inCard
    }

    private let message: String
    private let title: String?
    private let tone: StrandTone
    private let action: Action?
    private let placement: Placement

    public init(_ message: String, title: String? = nil, tone: StrandTone = .neutral,
                action: Action? = nil, placement: Placement = .page) {
        self.message = message
        self.title = title
        self.tone = tone
        self.action = action
        self.placement = placement
    }

    /// The symbol for a tone. Pure.
    public static func symbol(for tone: StrandTone) -> String {
        switch tone {
        case .warning: return "exclamationmark.triangle"
        case .critical: return "xmark.octagon"
        case .positive: return "checkmark.circle"
        case .neutral, .accent: return "info.circle"
        }
    }

    public var body: some View {
        let content = HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            Image(systemName: Self.symbol(for: tone))
                .font(StrandFont.icon(.row))
                .foregroundStyle(tone == .neutral ? StrandPalette.textSecondary : tone.color)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                if let title {
                    Text(title)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                }
                Text(message)
                    .font(StrandFont.subhead)
                    .foregroundStyle(title == nil ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if let action {
                // The tap area is grown to 44 pt and the growth given back, so the action makes the notice
                // no taller (the same trick as `SectionHeaderAction`).
                let grow = max(0, (NoopMetrics.minimumHitTarget - 20) / 2)
                Button(action: action.perform) {
                    Text(action.label)
                        .font(StrandFont.subhead.weight(.medium))
                        .foregroundStyle(StrandPalette.accent)
                        .lineLimit(1)
                        .padding(.vertical, grow)
                        .padding(.leading, NoopMetrics.space2)
                        .contentShape(Rectangle())
                        .padding(.vertical, -grow)
                }
                .buttonStyle(.plain)
                .fixedSize()
            }
        }
        switch placement {
        case .page:
            content
                .padding(.horizontal, NoopMetrics.cardPadding)
                .padding(.vertical, NoopMetrics.space3)
                .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget, alignment: .leading)
                .background(NoopPanelSurface())
        case .inCard:
            content
                .padding(.horizontal, NoopMetrics.space3)
                .padding(.vertical, NoopMetrics.space2 + NoopMetrics.spaceHalf)
                .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget, alignment: .leading)
                .background(NoopInsetSurface())
        }
    }
}

#if DEBUG
#Preview("InlineNotice") {
    VStack(spacing: NoopMetrics.gap) {
        InlineNotice("Your strap needs re-pairing before it can sync.", tone: .warning,
                     action: .init("Re-pair") {})
        InlineNotice("History is still syncing from your strap.", title: "Syncing")
        NoopCard {
            InlineNotice("Apple Health is not connected.", tone: .neutral, placement: .inCard)
        }
    }
    .padding(NoopMetrics.screenHPadding)
    .background(StrandPalette.surfaceBase)
}
#endif

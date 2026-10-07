import SwiftUI

// MARK: - PeriodStepper
//
// One look for stepping through time: a night on Sleep, a day on the heart-rate timeline, a week on
// Trends. Each of those had its own chevrons and date chip; this is the single control they share.

/// "‹ Last night · Mon 6 – Tue 7 Oct ›": back and forward chevrons around the period's name and dates.
///
/// ```swift
/// PeriodStepper(title: nightTitle, subtitle: ReadoutContent.dateLine(wakeDay, period: .night),
///               canGoBack: hasOlderNight, canGoForward: offset > 0,
///               onBack: { offset += 1 }, onForward: { offset -= 1 },
///               onTitleTap: { showsNightPicker = true })
/// ```
///
/// - Both chevrons are 44 pt targets. An end that cannot move is drawn in `textTertiary` and disabled,
///   so the newest period never offers a forward step into the future.
/// - `onTitleTap` makes the centre a button (open a date picker); without it the centre is plain text.
/// - Each step plays the light selection haptic. The control does not animate the change: the page's
///   content swaps to the new period.
/// - Fixed height (44 pt): the title and subtitle share one line and scale down rather than wrap, so the
///   page below never moves when the dates get longer.
public struct PeriodStepper: View {
    private let title: String
    private let subtitle: String?
    private let canGoBack: Bool
    private let canGoForward: Bool
    private let onBack: () -> Void
    private let onForward: () -> Void
    private let onTitleTap: (() -> Void)?

    public init(title: String, subtitle: String? = nil, canGoBack: Bool, canGoForward: Bool,
                onBack: @escaping () -> Void, onForward: @escaping () -> Void,
                onTitleTap: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.onBack = onBack
        self.onForward = onForward
        self.onTitleTap = onTitleTap
    }

    public var body: some View {
        HStack(spacing: 0) {
            chevron("chevron.left", enabled: canGoBack, action: onBack)
                .accessibilityLabel(Text("Previous", bundle: .module))
            Spacer(minLength: NoopMetrics.space1)
            if let onTitleTap {
                Button(action: onTitleTap) { centre }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Choose a date", bundle: .module))
            } else {
                centre
            }
            Spacer(minLength: NoopMetrics.space1)
            chevron("chevron.right", enabled: canGoForward, action: onForward)
                .accessibilityLabel(Text("Next", bundle: .module))
        }
        .frame(height: NoopMetrics.minimumHitTarget)
    }

    private var centre: some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
            if let subtitle, !subtitle.isEmpty {
                Text("·")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Text(subtitle)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(minHeight: NoopMetrics.minimumHitTarget)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    private func chevron(_ symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button {
            StrandHaptic.selection.play()
            action()
        } label: {
            Image(systemName: symbol)
                .font(StrandFont.icon(.row).weight(.semibold))
                .foregroundStyle(enabled ? StrandPalette.accent : StrandPalette.textTertiary.opacity(0.5))
                .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

#if DEBUG
private struct PeriodStepperPreview: View {
    @State private var offset = 0
    var body: some View {
        VStack(spacing: NoopMetrics.sectionGap) {
            PeriodStepper(title: offset == 0 ? "Last night" : "\(offset + 1) nights ago",
                          subtitle: "Mon 6 – Tue 7 Oct",
                          canGoBack: offset < 3, canGoForward: offset > 0,
                          onBack: { offset += 1 }, onForward: { offset -= 1 }, onTitleTap: {})
            NoopCard(padding: 0) {
                PeriodStepper(title: "This week", subtitle: "29 Sep – 5 Oct",
                              canGoBack: true, canGoForward: false, onBack: {}, onForward: {})
            }
            PeriodStepper(title: "Today", canGoBack: true, canGoForward: false, onBack: {}, onForward: {})
        }
        .padding(NoopMetrics.screenHPadding)
        .frame(width: 390)
        .background(StrandPalette.surfaceBase)
    }
}

#Preview("PeriodStepper — light") {
    PeriodStepperPreview().preferredColorScheme(.light)
}

#Preview("PeriodStepper — dark") {
    PeriodStepperPreview().preferredColorScheme(.dark)
}
#endif

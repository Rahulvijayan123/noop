import StrandDesign
import SwiftUI

/// What Sana is doing, said honestly and quietly.
///
/// `.working` is one line while the turn runs and no answer text has arrived yet: the system spinner and the
/// phase the view model actually reports ("Looking up your data…" only while a lookup is running). It does not
/// advance on a clock or list steps that may not be happening. `.summary` sits under a finished answer when
/// Sana read the wearer's data: a collapsed "Looked at your data" line that opens to the sources it read.
struct CoachThinkingTrace: View {
    enum Part { case working, summary }

    let message: CoachChatMessage
    let phase: CoachThinkingPhase
    let part: Part

    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isWorking: Bool { message.isStreaming && !message.didStall }
    private var awaitingAnswer: Bool {
        isWorking && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        switch part {
        case .working:
            if awaitingAnswer { workingLine }
        case .summary:
            if !isWorking, !message.toolNames.isEmpty { summary }
        }
    }

    private var workingLabel: String {
        switch phase {
        case .analyzingImage, .lookingUpData: return phase.label
        case .idle, .generating: return String(localized: "Thinking…")
        }
    }

    private var workingLine: some View {
        HStack(spacing: NoopMetrics.space2) {
            ProgressView()
                .controlSize(.small)
                .tint(StrandPalette.accent)
            Text(workingLabel)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .lineLimit(1)
        }
        .frame(minHeight: 28, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(spacing: NoopMetrics.space1) {
                    Text("Looked at your data")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(StrandFont.icon(.inline))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(expanded ? Text("Expanded") : Text("Collapsed"))
            if expanded {
                Text(message.toolNames.joined(separator: " · "))
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }
}

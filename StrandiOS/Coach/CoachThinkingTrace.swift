import StrandDesign
import SwiftUI

/// A compact, expandable trace of the assistant's work. The header always reads "Thinking…" and the body is
/// the same short list of numbered steps every time; the steps tick forward as the answer gets closer, so the
/// block never rewrites itself while it is open.
struct CoachThinkingTrace: View {
    private enum RowStatus { case active, complete, neutral }

    private struct Row: Identifiable {
        let id: String
        let primary: String
        let secondary: String?
        let icon: String
        let status: RowStatus
        let isReasoning: Bool
    }

    let message: CoachChatMessage
    let phase: CoachThinkingPhase
    let phaseLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var manualExpanded: Bool?
    /// The furthest step reached this turn. Steps only ever move forward, even across repeated lookups.
    @State private var reached = 0
    @State private var now = Date()

    /// True for the whole turn: the orb stays up from the first token to the last, through every tool round.
    private var isWorking: Bool { message.isStreaming && !message.didStall }

    /// True until answer text arrives. The steps are open for this stretch and fold away as the answer starts
    /// to stream. Narration before a lookup never reaches the answer text (the view model keeps it in the
    /// trace), so this does not flip back and forth across tool rounds.
    private var isAwaitingAnswer: Bool {
        isWorking && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTraceData: Bool {
        isWorking
            || !message.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.toolNames.isEmpty
            || message.vizPhase != .none
    }

    private var expanded: Bool { manualExpanded ?? isAwaitingAnswer }

    var body: some View {
        if hasTraceData {
            VStack(alignment: .leading, spacing: 0) {
                header
                if expanded {
                    let rows = traceRows
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(rows) { traceRow($0) }
                    }
                    .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: rows.count)
                    .padding(.leading, 9)
                    .padding(.top, 3)
                    .padding(.bottom, 4)
                    .overlay(alignment: .leading) {
                        Rectangle().fill(StrandPalette.hairline).frame(width: 1).padding(.leading, 13)
                    }
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.horizontal, isWorking ? 12 : 4)
            .padding(.vertical, isWorking ? 8 : 0)
            .background {
                if isWorking {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceRaised)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StrandPalette.hairline.opacity(0.5), lineWidth: 0.5))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: expanded)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isWorking)
            .onChange(of: rawStage) { _, new in reached = max(reached, new) }
            .task(id: isWorking) {
                // Re-reads the clock once a second while the turn is running, to pace the steps.
                while isWorking, !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    now = Date()
                }
            }
        }
    }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { manualExpanded = !expanded }
        } label: {
            HStack(spacing: 8) {
                if isWorking {
                    ThinkingOrb(state: .solving, size: 20)
                    Text("Thinking…")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                } else {
                    Text(completedLabel)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 4)
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .frame(minHeight: 26)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(expanded ? "Hide thinking details" : "Show thinking details")
        .accessibilityValue(completedLabel)
    }

    private var completedLabel: String {
        if let duration = message.thinkingDuration {
            let seconds = max(1, Int(duration.rounded()))
            return "Thought for \(seconds) \(seconds == 1 ? "second" : "seconds")"
        }
        return message.toolNames.isEmpty ? "Thought through your request" : "Looked at your data"
    }

    /// The steps, then the visual being drawn (if any).
    private var traceRows: [Row] { stepRows + visualRows }

    private var visualRows: [Row] {
        switch message.vizPhase {
        case .none:
            return []
        case .generating:
            return [Row(id: "viz-draw", primary: "Drawing a visual and checking its figures", secondary: nil, icon: "chart.bar", status: .active, isReasoning: false)]
        case .ready:
            return [
                Row(id: "viz-draw", primary: "Drew a visual", secondary: nil, icon: "chart.bar", status: .complete, isReasoning: false),
                Row(id: "viz-check", primary: "Checked every figure against your data", secondary: nil, icon: "checkmark.seal", status: .complete, isReasoning: false),
            ]
        }
    }

    private static let steps = ["Understanding your request", "Checking your data", "Comparing relevant signals", "Writing your answer"]

    /// Where the turn really is: a lookup under way is step 2, results in hand is step 3, answer text is step 4.
    private var eventStage: Int {
        if !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return 3 }
        if !message.toolMarks.isEmpty, phase != .lookingUpData { return 2 }
        if phase == .lookingUpData || !message.toolMarks.isEmpty { return 1 }
        return 0
    }

    /// Keeps a turn with no lookup moving too: it steps forward on a slow clock, but never into the last step,
    /// which is reserved for the answer actually arriving.
    private var timeStage: Int {
        let elapsed = now.timeIntervalSince(message.createdAt)
        return elapsed < 2.5 ? 0 : (elapsed < 7 ? 1 : 2)
    }

    private var rawStage: Int { isWorking ? max(eventStage, timeStage) : Self.steps.count }

    /// The step in progress; `steps.count` once the turn is over.
    private var stage: Int {
        guard isWorking else { return Self.steps.count }
        return isAwaitingAnswer ? min(max(reached, rawStage), 2) : 3
    }

    private var stepRows: [Row] {
        // A finished answer that never looked anything up did not check or compare anything.
        let shown = isWorking || !message.toolNames.isEmpty
            ? Array(Self.steps.enumerated())
            : [(0, Self.steps[0]), (3, Self.steps[3])]
        return shown.enumerated().map { position, step in
            let status: RowStatus = step.0 < stage ? .complete : step.0 == stage ? .active : .neutral
            return Row(id: "step-\(step.0)", primary: step.1, secondary: nil,
                       icon: status == .neutral ? "\(position + 1).circle" : "circle", status: status, isReasoning: false)
        }
    }

    private func traceRow(_ row: Row) -> some View {
        HStack(alignment: row.isReasoning ? .top : .center, spacing: 8) {
            indicator(row)
            Text(row.primary)
                .font(row.isReasoning ? StrandFont.caption : Font.system(size: 11, design: .rounded))
                .foregroundStyle(row.status == .neutral ? StrandPalette.textTertiary
                                 : (row.isReasoning ? StrandPalette.textSecondary : StrandPalette.textPrimary))
                .lineLimit(row.isReasoning ? 3 : 2)
                .fixedSize(horizontal: false, vertical: row.isReasoning)
            if let secondary = row.secondary {
                Spacer(minLength: 4)
                Text(secondary)
                    .font(Font.system(size: 10, design: .rounded))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, minHeight: row.isReasoning ? 26 : 28, alignment: .leading)
        .padding(.horizontal, 7)
        .padding(.vertical, row.isReasoning ? 4 : 1)
        .accessibilityElement(children: .combine)
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private func indicator(_ row: Row) -> some View {
        switch row.status {
        case .active:
            ProgressView()
                .progressViewStyle(.circular)
                .tint(StrandPalette.accent)
                .scaleEffect(0.62)
                .frame(width: 14, height: 14)
                .accessibilityLabel("In progress")
        case .complete where row.icon == "circle":
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 14, height: 14)
        default:
            Image(systemName: row.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(width: 14, height: 14)
        }
    }
}

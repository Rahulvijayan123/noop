import StrandDesign
import SwiftUI

/// A compact, expandable trace of the assistant's work. Rows come from the reasoning the model streamed
/// and the tools it actually called; nothing is invented to make the animation look busy.
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

    /// True until the first answer token arrives; the live steps belong to this phase only.
    private var isThinking: Bool {
        message.isStreaming && !message.didStall && message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasTraceData: Bool {
        isThinking
            || !message.thinking.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !message.toolNames.isEmpty
            || message.vizPhase != .none
    }

    private var expanded: Bool { manualExpanded ?? isThinking }

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
            .padding(.horizontal, isThinking ? 12 : 4)
            .padding(.vertical, isThinking ? 8 : 0)
            .background {
                if isThinking {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceRaised)
                        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(StrandPalette.hairline.opacity(0.5), lineWidth: 0.5))
                }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.28), value: expanded)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isThinking)
        }
    }

    private var header: some View {
        Button {
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.28)) { manualExpanded = !expanded }
        } label: {
            HStack(spacing: 8) {
                if isThinking {
                    CoachTypingDots()
                    CoachElapsedLabel(base: phaseLabel.isEmpty ? "Coach is thinking…" : phaseLabel)
                } else {
                    Image(systemName: "sparkles")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
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

    /// One numbered step per finding, lookup and visual, in the order they happened.
    private var traceRows: [Row] {
        var rows: [Row] = []
        func stepIcon() -> String { rows.count < 50 ? "\(rows.count + 1).circle" : "circle" }

        func addSnippets(_ segment: String, complete: Bool, key: String) {
            for (index, line) in CoachTraceSnippets.extract(from: segment, isComplete: complete).enumerated() {
                rows.append(Row(id: "\(key)-snippet-\(index)", primary: line, secondary: nil, icon: stepIcon(), status: .neutral, isReasoning: true))
            }
        }

        let marks = message.toolMarks
        let raw = message.thinking
        var previous = 0
        for (markIndex, mark) in marks.enumerated() {
            let segment = String(raw.dropFirst(previous).prefix(max(0, mark.offset - previous)))
            addSnippets(segment, complete: true, key: "m\(markIndex)")
            for (labelIndex, label) in mark.labels.enumerated() {
                let running = isThinking && phase == .lookingUpData && markIndex == marks.count - 1 && labelIndex == mark.labels.count - 1
                rows.append(Row(id: "m\(markIndex)-tool-\(labelIndex)", primary: label, secondary: "your data",
                                icon: stepIcon(), status: running ? .active : .complete, isReasoning: false))
            }
            previous = max(previous, mark.offset)
        }
        addSnippets(String(raw.dropFirst(previous)), complete: !isThinking, key: "tail")

        if marks.isEmpty {
            for (index, label) in message.toolNames.enumerated() {
                rows.append(Row(id: "tool-\(index)", primary: label, secondary: "your data", icon: stepIcon(), status: .complete, isReasoning: false))
            }
        }
        for row in visualRows {
            rows.append(Row(id: row.id, primary: row.primary, secondary: nil, icon: row.icon, status: row.status, isReasoning: false))
        }
        return rows.isEmpty ? stepRows : rows
    }

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

    private var stepRows: [Row] {
        let labels = ["Understanding your request", "Checking your data", "Comparing relevant signals", "Writing your answer"]
        let current: Int
        switch phase {
        case .analyzingImage: current = 1
        case .lookingUpData: current = 2
        case .generating: current = 3
        case .idle: current = isThinking ? 3 : labels.count
        }
        return labels.enumerated().map { index, label in
            let status: RowStatus = (index < current || !isThinking) ? .complete : index == current ? .active : .neutral
            return Row(id: "step-\(index)", primary: label, secondary: nil, icon: "circle", status: status, isReasoning: false)
        }
    }

    private func traceRow(_ row: Row) -> some View {
        HStack(alignment: row.isReasoning ? .top : .center, spacing: 8) {
            indicator(row)
            Text(row.primary)
                .font(row.isReasoning ? StrandFont.caption : Font.system(size: 11, design: .rounded))
                .foregroundStyle(row.isReasoning ? StrandPalette.textSecondary : StrandPalette.textPrimary)
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

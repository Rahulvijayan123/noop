import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - What the wearer has said, and whether it got sent
//
// Opened from the Heart rate page. Lists every answer given about a stretch, newest first, with the model's
// label next to the wearer's, and says plainly for each one whether the server has it.

/// The words and symbol for where one saved answer stands, shared by the stretch sheet and the list so the two
/// never tell different stories.
struct StretchFeedbackStatusLine: Equatable {
    let symbol: String
    let text: String
    /// True when the answer is stuck for a reason the wearer can act on or should know about.
    let needsAttention: Bool

    init(_ standing: StretchFeedbackCenter.Standing) {
        switch standing {
        case .sent:
            symbol = "checkmark.icloud"
            text = String(localized: "Saved and sent.")
            needsAttention = false
        case .sending:
            symbol = "arrow.triangle.2.circlepath.icloud"
            text = String(localized: "Saved. Sending…")
            needsAttention = false
        case .waiting:
            symbol = "tray.and.arrow.up"
            text = String(localized: "Saved on this phone. Waiting to send.")
            needsAttention = false
        case .willRetry:
            symbol = "icloud.slash"
            text = String(localized: "Saved on this phone. Couldn't reach the server, so it will try again.")
            needsAttention = false
        case .needsSignIn:
            symbol = "person.crop.circle.badge.exclamationmark"
            text = String(localized: "Saved on this phone. Sign in to Nara to send it.")
            needsAttention = true
        case .noServer:
            symbol = "exclamationmark.icloud"
            text = String(localized: "Saved on this phone. This build has no cloud address to send to.")
            needsAttention = true
        case .refused(let reason):
            symbol = "exclamationmark.triangle"
            text = String(localized: "Saved on this phone, but the server turned it down (\(reason)).")
            needsAttention = true
        }
    }
}

/// The row on the Heart rate page that opens the list.
struct StretchFeedbackLinkRow: View {
    @ObservedObject private var center = StretchFeedbackCenter.shared

    var body: some View {
        HStack(spacing: 8) {
            Text("Your answers about stretches")
            Spacer(minLength: 8)
            Text(detail)
                .foregroundStyle(center.waitingToUpload > 0 ? StrandPalette.statusWarning : StrandPalette.textTertiary)
            Image(systemName: "chevron.right")
        }
        .font(StrandFont.subhead)
        .foregroundStyle(StrandPalette.accent)
        .padding(.horizontal, NoopMetrics.space1)
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        let saved = center.records.count
        if saved == 0 { return String(localized: "None yet") }
        let waiting = center.waitingToUpload
        return waiting == 0 ? String(localized: "\(saved) saved") : String(localized: "\(waiting) not sent yet")
    }
}

struct StretchFeedbackHistoryView: View {
    @ObservedObject private var center = StretchFeedbackCenter.shared

    private struct Day {
        let start: Date
        let records: [StretchFeedback]
    }

    private var days: [Day] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: center.records) {
            calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval($0.startTs)))
        }
        return grouped.keys.sorted(by: >).map { day in
            Day(start: day, records: (grouped[day] ?? []).sorted { $0.startTs > $1.startTs })
        }
    }

    var body: some View {
        ScreenScaffold(title: "Your answers",
                       subtitle: "What you've said about each stretch, and whether it has been sent.",
                       lazy: true) {
            summaryCard
            if center.records.isEmpty {
                DataPendingNote(title: "No answers yet",
                                message: "Open a stretch on the Heart rate page and say whether it's right. Your answers show up here.",
                                symbol: "checkmark.bubble")
            } else {
                ForEach(days, id: \.start) { day in
                    VStack(alignment: .leading, spacing: 10) {
                        Text(day.start, format: .dateTime.weekday(.wide).month().day())
                            .strandOverline()
                        ForEach(day.records) { record in
                            AnswerRow(feedback: record, standing: center.standing(of: record))
                        }
                    }
                }
            }
        }
    }

    private var summaryCard: some View {
        let total = center.records.count
        let wrong = center.records.filter { $0.verdict == .incorrect }.count
        let waiting = center.waitingToUpload
        let stuck = center.records.first(where: \.needsSync).map { StretchFeedbackStatusLine(center.standing(of: $0)) }
        return NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("\(total) answers")
                    .font(StrandFont.rounded(24))
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(wrong) said wrong, \(total - wrong) said right")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                if total > 0 {
                    if waiting == 0 {
                        Label("All of them are saved to your Nara account.", systemImage: "checkmark.icloud")
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.statusPositive)
                    } else if let stuck {
                        Label("\(waiting) not sent yet. \(stuck.text)", systemImage: stuck.symbol)
                            .font(StrandFont.footnote)
                            .foregroundStyle(stuck.needsAttention ? StrandPalette.statusWarning : StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        NoopButton(center.delivery == .sending ? "Sending…" : "Send now",
                                   systemImage: "arrow.up.circle", kind: .secondary, fullWidth: true) {
                            Task { await center.flushAndWait() }
                        }
                        .disabled(center.delivery == .sending)
                    }
                }
            }
        }
    }
}

private struct AnswerRow: View {
    let feedback: StretchFeedback
    let standing: StretchFeedbackCenter.Standing

    var body: some View {
        let from = Date(timeIntervalSince1970: TimeInterval(feedback.startTs))
        let to = Date(timeIntervalSince1970: TimeInterval(feedback.endTs))
        let seconds = feedback.durationSeconds < 300
        let line = StretchFeedbackStatusLine(standing)
        NoopCard(padding: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(StretchFormat.clock(from, seconds: seconds)) – \(StretchFormat.clock(to, seconds: seconds))")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                    Text(StretchFormat.duration(feedback.durationSeconds))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    Spacer(minLength: 8)
                    StretchVerdictBadge(feedback: feedback)
                }
                Text("The model said: \(feedback.predictedLabel)")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                if let note = feedback.note, !note.isEmpty {
                    Text("“\(note)”")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 6) {
                    Image(systemName: line.symbol)
                    Text(line.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(StrandFont.footnote)
                .foregroundStyle(line.needsAttention ? StrandPalette.statusWarning : StrandPalette.textTertiary)
            }
        }
    }
}

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

/// The row on the Heart rate page that opens the list. A one-row card on its own; pass `inCard: false` to
/// put it in a card of rows.
struct StretchFeedbackLinkRow: View {
    var inCard = true
    @ObservedObject private var center = StretchFeedbackCenter.shared

    var body: some View {
        if inCard {
            NoopCard(padding: 0) { row }
        } else {
            row
        }
    }

    private var row: some View {
        NoopListRow(icon: "checkmark.bubble", title: "Your answers about stretches", value: detail,
                    valueTone: center.waitingToUpload > 0 ? .warning : .neutral)
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
        ScreenScaffold(title: "Your answers", titleDisplay: .navigationBar, lazy: true) {
            if center.records.isEmpty {
                Text("Open a stretch on the Heart rate page and say whether it's right. Your answers show up here.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                summary
                ForEach(days, id: \.start) { day in
                    NoopListSection("\(ReadoutContent.dateLine(day.start, period: .day))") {
                        ForEach(Array(day.records.enumerated()), id: \.element.id) { index, record in
                            if index > 0 { NoopListDivider() }
                            AnswerRow(feedback: record, standing: center.standing(of: record))
                        }
                    }
                }
            }
        }
    }

    /// The counts, and whether everything has reached the server (with a way to send what has not).
    @ViewBuilder
    private var summary: some View {
        let total = center.records.count
        let wrong = center.records.filter { $0.verdict == .incorrect }.count
        let waiting = center.waitingToUpload
        let stuck = center.records.first(where: \.needsSync).map { StretchFeedbackStatusLine(center.standing(of: $0)) }
        StatGrid([
            StatItem(String(localized: "Answers"), value: "\(total)"),
            StatItem(String(localized: "Said right"), value: "\(total - wrong)"),
            StatItem(String(localized: "Said wrong"), value: "\(wrong)"),
        ], columns: 3)
        if waiting == 0 {
            InlineNotice(String(localized: "All of them are saved to your Nara account."), tone: .positive)
        } else if let stuck {
            InlineNotice(String(localized: "\(waiting) not sent yet. \(stuck.text)"),
                         tone: stuck.needsAttention ? .warning : .neutral,
                         action: center.delivery == .sending ? nil
                            : InlineNotice.Action("Send now") { Task { await center.flushAndWait() } })
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
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                Text("\(StretchFormat.clock(from, seconds: seconds)) – \(StretchFormat.clock(to, seconds: seconds))")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                Text(StretchFormat.duration(feedback.durationSeconds))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: NoopMetrics.space2)
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
            Label {
                Text(line.text).fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: line.symbol)
            }
            .font(StrandFont.footnote)
            .foregroundStyle(line.needsAttention ? StrandPalette.statusWarning : StrandPalette.textTertiary)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

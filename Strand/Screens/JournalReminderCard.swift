import SwiftUI
import StrandDesign

// MARK: - Journal widget (Today screen) — #627
//
// A persistent Today widget for the Journal: a WHOOP-style strip of the last `stripDays` days
// (filled = a journal entry that day, today ringed) plus an always-present tap-through to the journal.
// The Journal (behavioural logging that feeds Insights / "What Moves You") is otherwise only reachable
// inside the Insights screen, which isn't a primary destination — easy to forget, and the only proactive
// prompt is the once-a-morning sleep sheet — missed on any day you don't open Sleep. This surfaces it on
// Today where it can't be missed, and doubles as the "direct link to Insights" the report (#627) asked for.
//
// Opt-out via `PuffinExperiment.journalReminderKey` (default ON — the same key also gates the Android
// morning sleep sheet twin). Read-only: it never writes a journal entry. Twin of Android
// `JournalReminderCard` (android/.../ui/JournalReminder.kt). The plain NoopCard: a title row with today's
// state word, then the strip with a weekday letter under each bar.

struct JournalReminderCard: View {

    @EnvironmentObject var repo: Repository
    @EnvironmentObject var router: NavRouter

    /// Default ON so the reminder works out of the box; the Settings toggle / this key opt out.
    @AppStorage(PuffinExperiment.journalReminderKey) private var reminderEnabled = true

    /// Which of the last `stripDays` day-keys carry a native journal entry. nil = still loading / read
    /// error.
    @State private var loggedDays: Set<String>?
    /// True once the first read has finished, so a read error renders nothing (never a misleading
    /// all-empty strip) while a first load holds the card's place, redacted, so it does not pop in.
    @State private var hasLoaded = false

    private static let stripDays = 7

    var body: some View {
        Group {
            if reminderEnabled {
                if let logged = loggedDays {
                    card(logged)
                } else if !hasLoaded {
                    card([]).loadingPlaceholder(true)
                }
            }
        }
        // Re-read whenever a sync bumps refreshSeq or the toggle flips (mirrors AutoWorkoutCard's task id),
        // so the strip and the "logged today" state stay current after the user logs and comes back.
        .task(id: JournalReminderLoadKey(seq: repo.refreshSeq, enabled: reminderEnabled)) {
            await reload()
            hasLoaded = true
        }
    }

    private func card(_ logged: Set<String>) -> some View {
        let keys = Self.dayKeys()
        let todayKey = keys.last ?? ""
        let todayLogged = logged.contains(todayKey)
        // No outer Button: each bar is its own tap target that deep-links the journal to THAT day (#656),
        // and nested SwiftUI buttons don't work — so the title row carries its own onTapGesture (→ today)
        // and the bars carry theirs. The regions do not overlap, so a tap lands on exactly one.
        return NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Image(systemName: "book.closed")
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(StrandPalette.metricAmber)
                        .accessibilityHidden(true)
                    Text(String(localized: "Journal"))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: NoopMetrics.space2)
                    Text(todayLogged ? String(localized: "Logged today") : String(localized: "Not logged today"))
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(StrandFont.icon(.inline))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
                .contentShape(Rectangle())
                .onTapGesture { router.openJournal() }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isButton)
                .accessibilityHint(Text(String(localized: "Open journal")))
                // The last-N-days strip: one equal-width bar per day over its weekday letter, each its own
                // tap target. Filled = logged; today is ringed. Tapping a bar deep-links the journal to that
                // day (#656).
                HStack(spacing: 6) {
                    ForEach(keys.indices, id: \.self) { i in
                        let key = keys[i]
                        let off = Self.stripDays - 1 - i          // keys[0] = 6 days ago … last = today
                        let isLogged = logged.contains(key)
                        VStack(spacing: NoopMetrics.space1) {
                            Color.clear
                                .frame(maxWidth: .infinity)
                                .frame(height: 22)                // taller invisible tap target
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(isLogged ? StrandPalette.accent : StrandPalette.textTertiary.opacity(0.22))
                                        .frame(height: 10)
                                        .overlay {
                                            if off == 0, !isLogged {
                                                RoundedRectangle(cornerRadius: 3)
                                                    .strokeBorder(StrandPalette.accent, lineWidth: 1)
                                            }
                                        }
                                }
                            Text(Self.weekdayLetter(offset: off))
                                .font(StrandFont.footnote)
                                .foregroundStyle(off == 0 ? StrandPalette.textSecondary : StrandPalette.textTertiary)
                                .lineLimit(1)
                                .accessibilityHidden(true)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { router.openJournal(day: off) }
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .accessibilityLabel(Self.barLabel(off))
                        .accessibilityValue(isLogged ? Text(String(localized: "Logged")) : Text(""))
                    }
                }
            }
        }
    }

    /// The one-letter weekday under a strip bar, in the user's locale.
    private static func weekdayLetter(offset: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date()) ?? Date()
        return day.formatted(.dateTime.weekday(.narrow).locale(AppLanguage.activeLocale))
    }

    /// Screen-reader label for a strip bar (#656): the day it deep-links to. Twin of JournalLogCard's
    /// day-picker labels; "%lld days ago" is a String Catalog key so it stays localized.
    private static func barLabel(_ offset: Int) -> LocalizedStringKey {
        switch offset {
        case 0: return "Today"
        case 1: return "Yesterday"
        default: return "\(offset) days ago"
        }
    }

    private func reload() async {
        guard reminderEnabled else { loggedDays = nil; return }
        let keys = Self.dayKeys()
        loggedDays = await repo.nativeJournalDays(from: keys.first ?? "", to: keys.last ?? "")
    }

    /// The `stripDays` local-day keys (yyyy-MM-dd), oldest → today, matching Android's `journalDayKey`
    /// (civil-day arithmetic via Calendar so a DST edge can't mislabel a day).
    private static func dayKeys() -> [String] {
        let cal = Calendar.current
        let today = Date()
        return (0..<stripDays).reversed().map { n in
            Repository.localDayKey(cal.date(byAdding: .day, value: -n, to: today) ?? today)
        }
    }
}

/// Reload key: a sync (seq) or toggle flip re-reads completion. Mirrors `AutoWorkoutLoadKey`.
private struct JournalReminderLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
}

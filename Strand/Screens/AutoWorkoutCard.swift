import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Auto-detected workout prompt (Today screen)
//
// A single, dismissible Today card that appears ONLY when the opt-in "Auto-detect workouts"
// toggle is on and `Repository.autoDetectCandidate()` finds a recent sustained-elevated HR
// window that isn't already saved and wasn't previously dismissed.
//
// It only ever SUGGESTS: tapping Save creates a manual-style "Workout" for the window (via the
// same manual-save path the edit sheet uses); "Not a workout" dismisses it durably so it never
// re-prompts. Nothing is created automatically. The plain NoopCard with the shared NoopButtons.

struct AutoWorkoutCard: View {

    @EnvironmentObject var repo: Repository

    /// Whether the toggle is on. Read here too so the card disappears the instant it's switched off.
    @AppStorage(PuffinExperiment.autoDetectWorkoutsKey) private var autoDetectEnabled = false

    /// The current suggestion, loaded in `.task`. nil → nothing to show.
    @State private var candidate: DetectedWorkout?
    /// Hide immediately on Save / Not a workout without waiting for the next reload (avoids a flash of the old card).
    @State private var handledThisSession = false
    /// Guards the Save button while the write is in flight.
    @State private var saving = false

    var body: some View {
        Group {
            if autoDetectEnabled, !handledThisSession, let w = candidate {
                card(for: w)
            }
        }
        // Re-scan whenever the data refreshes (a sync bumps refreshSeq) or the toggle flips on.
        .task(id: AutoWorkoutLoadKey(seq: repo.refreshSeq, enabled: autoDetectEnabled)) {
            await reload()
        }
    }

    @ViewBuilder
    private func card(for w: DetectedWorkout) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space2) {
                    Image(systemName: "figure.run")
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(StrandPalette.effortColor)
                        .accessibilityHidden(true)
                    Text("Looks like a workout")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 0)
                }

                Text(dataLine(w))
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                // "Not a workout" is the dismiss: it records the window as handled so it never re-prompts.
                HStack(spacing: NoopMetrics.space3) {
                    NoopButton("Save it", systemImage: "checkmark", kind: .primary) { save(w) }
                        .disabled(saving)
                    NoopButton("Not a workout", kind: .secondary) { dismiss(w) }
                        .disabled(saving)
                        .accessibilityHint(Text("Dismiss this workout suggestion"))
                    Spacer(minLength: 0)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    /// "14:05-14:32 · 27 min · avg 148 bpm", prefixed with "Yesterday" or the date for an older bout.
    /// Three whole-phrase variants (today / yesterday / dated, #719) so translators see complete phrases
    /// rather than a stitched day-label fragment.
    private func dataLine(_ w: DetectedWorkout) -> String {
        let startDate = Date(timeIntervalSince1970: TimeInterval(w.startSec))
        let start = Self.timeFmt.string(from: startDate)
        let end = Self.timeFmt.string(from: Date(timeIntervalSince1970: TimeInterval(w.endSec)))
        let cal = Calendar.current
        if cal.isDateInToday(startDate) {
            return String(localized: "\(start)-\(end) · \(w.durationMin) min · avg \(w.avgBpm) bpm")
        }
        if cal.isDateInYesterday(startDate) {
            return String(localized: "Yesterday \(start)-\(end) · \(w.durationMin) min · avg \(w.avgBpm) bpm")
        }
        return String(localized: "\(Self.dateFmt.string(from: startDate)) \(start)-\(end) · \(w.durationMin) min · avg \(w.avgBpm) bpm")
    }

    private func reload() async {
        guard autoDetectEnabled else { candidate = nil; return }
        let next = await repo.autoDetectCandidate()
        // A fresh scan resets the session guard so a NEW window can surface after one is handled.
        if next != candidate { handledThisSession = false }
        candidate = next
    }

    private func save(_ w: DetectedWorkout) {
        saving = true
        handledThisSession = true
        Task {
            _ = await repo.saveDetectedWorkout(w)
            await repo.refresh()   // surfaces the new workout + drops it from re-suggestion
            saving = false
        }
    }

    private func dismiss(_ w: DetectedWorkout) {
        repo.dismissDetectedSuggestion(w)
        handledThisSession = true
        candidate = nil
    }

    /// HH:mm in the user's locale/timezone.
    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var timeFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    /// Localized medium date ("Jun 23, 2026") for a bout older than yesterday.
    private static let dateFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = AppLanguage.activeLocale
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()
}

/// Reload key: a new sync (seq) or a toggle flip re-runs detection.
private struct AutoWorkoutLoadKey: Equatable {
    let seq: Int
    let enabled: Bool
}

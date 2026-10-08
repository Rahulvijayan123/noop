import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// The Lift Log: build a program once, then run it in the gym by tapping through it.
//
// This screen is the front door — it lists the saved programs and (from a later phase) the sessions
// run from them. It lives in the Effort colour world, like Workouts, because a finished session
// lands in the `workout` table beside every other workout.
//
// EFFORT IS NEVER MODIFIED HERE (load-bearing). NOOP's Effort is computed from heart rate alone
// (Karvonen %HRR → Edwards TRIMP, `StrainScorer`), and there is no validated public path from typed
// sets/reps/weight to a cardiovascular-strain equivalent — WHOOP's own muscular load runs
// velocity-based algorithms over strap accelerometer/gyroscope data under an unpublished model.
// So the lifting figures are shown BESIDE Effort and never folded into it, matching the choice the
// imported-lifting path already made (`strain: nil, // never a fabricated cardiovascular strain`).

struct LiftLogView: View {
    @EnvironmentObject var repo: Repository

    /// Saved programs, most-recently-touched first. Loaded off the store on appear/refresh.
    @State private var programs: [LiftProgramRow] = []
    @State private var loaded = false

    /// The program being created or edited (nil = the editor is closed).
    @State private var editing: ProgramEditTarget?
    @State private var importing = false
    /// The live session, owned at the app root so it survives this screen going away.
    @EnvironmentObject private var session: LiftSessionController
    /// Recent finished sessions, newest first.
    @State private var history: [LiftSessionRow] = []
    /// This week's fractional sets per muscle.
    @State private var weekCounts: [LiftMuscle: Double] = [:]
    /// The session whose detail sheet is open.
    @State private var viewing: SessionDetailTarget?

    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.imperial.rawValue
    private var unitSystem: UnitSystem { UnitSystem(rawValue: unitSystemRaw) ?? .imperial }

    var body: some View {
        ScreenScaffold(title: "Lift log", titleDisplay: .navigationBar, onRefresh: { await load() }) {
            programsSection
            weekSection
            historySection
            AboutDisclosure("About the lift log", paragraphs: [
                String(localized: "Build a program once, then tap through it at the gym. Kept on \(Platform.deviceNounPhrase)."),
                String(localized: "Lifting adds volume and set counts. It never changes your Effort, which stays measured from heart rate."),
                String(localized: "A program is a name and an ordered list of exercises with your targets — working sets, reps, weight, rest and your own technique note."),
                String(localized: "Counted from the muscles you assigned each exercise: direct sets count once, indirect ones half. The tick is about 4 sets a week — below that, studies across GROUPS of people stop reliably detecting growth. It is a research reference, not a target for you, and above it gains continue with strongly diminishing returns and no clear ceiling, so the bar has no \"full\"."),
            ])
        }
        // Also on a saved session: the session sheet lives above this screen and cannot tell it
        // directly, and a save does not always bump `refreshSeq`.
        .task(id: "\(repo.refreshSeq)-\(session.savedSessions)") { await load() }
        .sheet(item: $editing) { target in
            LiftProgramEditorSheet(program: target.program) {
                await load()
            }
        }
        .sheet(isPresented: $importing) {
            LiftProgramImportSheet { await load() }
        }
        .sheet(item: $viewing) { target in
            LiftSessionDetailSheet(session: target.session) { await load() }
        }
    }

    // MARK: - Programs

    private var programsSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Programs")

            if !loaded {
                WorkoutRowsPlaceholder(count: 2)
            } else if programs.isEmpty {
                Text("No programs yet")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                NoopCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(programs.enumerated()), id: \.element.id) { index, program in
                            if index > 0 { NoopListDivider() }
                            programRow(program)
                        }
                    }
                }
            }

            HStack(spacing: NoopMetrics.gap) {
                NoopButton("New program", systemImage: "plus", kind: .secondary, fullWidth: true) {
                    editing = ProgramEditTarget(id: "new", program: nil)
                }
                // Filling a dozen exercise lines by hand on a phone is the most tedious thing in the
                // feature; a spreadsheet on a computer does it in a couple of minutes.
                NoopButton("Import", systemImage: "tablecells", kind: .secondary, fullWidth: true) {
                    importing = true
                }
            }
        }
    }

    /// One program: its name and note (a tap edits it), and Start.
    private func programRow(_ program: LiftProgramRow) -> some View {
        HStack(spacing: NoopMetrics.gap) {
            Button {
                editing = ProgramEditTarget(id: program.id, program: program)
            } label: {
                VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                    Text(program.name)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    if let note = program.note, !note.isEmpty {
                        Text(note)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(Text("Edit this program"))

            NoopButton(session.isActive ? "Running" : "Start", kind: .primary) { Task { await start(program) } }
                .fixedSize()
                .accessibilityLabel("Start this program")
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(minHeight: NoopMetrics.listRowMinHeight)
    }

    // MARK: - Start a session

    /// Flatten a program into the plan the session runs. The plan is SNAPSHOT at start: editing or
    /// deleting the program mid-session cannot change what is being tapped through.
    private func start(_ program: LiftProgramRow) async {
        guard let store = await repo.storeHandle() else { return }
        let items = (try? await store.liftProgramItems(programId: program.id)) ?? []
        guard !items.isEmpty else { return }
        let vocabulary = (try? await store.liftExercises(deviceId: repo.deviceId)) ?? []

        let plan = items.map { item -> LiftPlanItem in
            // The classification comes from the exercise vocabulary, which is the one place that owns
            // it — the program line deliberately stores no muscle of its own to drift from.
            let known = vocabulary.first { $0.name == item.exercise }
            return LiftPlanItem(exercise: item.exercise,
                                primaryMuscle: known?.primaryMuscle,
                                secondaryMuscles: known?.secondaryMuscles ?? [],
                                targetSets: item.targetSets,
                                restSec: item.restSec,
                                targetRepsLow: item.targetRepsLow,
                                targetRepsHigh: item.targetRepsHigh,
                                targetRpe: item.targetRpe,
                                targetWeightKg: item.targetWeightKg,
                                note: item.note,
                                // Carried so a set added or dropped mid-session can be written back
                                // onto the line it came from, and be there next time.
                                programItemId: item.id)
        }
        // Refuse to start a second session over a running one: two live sessions would both claim
        // the strap gesture and both write the in-flight snapshot.
        guard !session.isActive else {
            session.isPresented = true
            return
        }
        session.start(plan: plan, programId: program.id, programName: program.name)
    }

    // MARK: - This week, per muscle

    private var weekSection: some View {
        let ordered = LiftMuscle.ordered.filter { (weekCounts[$0] ?? 0) > 0 }
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sets per muscle", trailing: String(localized: "Last 7 days"))
            if ordered.isEmpty {
                Text("Once you've logged a session, this shows how many sets each muscle got this week, against what the research associates with growth.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                NoopCard {
                    VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                        ForEach(ordered, id: \.self) { muscle in
                            muscleBar(muscle, sets: weekCounts[muscle] ?? 0)
                        }
                    }
                }
            }
        }
    }

    /// The span the weekly bar is drawn across.
    ///
    /// A DRAWING choice, not a dose. The evidence puts a floor at about 4 sets a week and identifies
    /// NO ceiling for hypertrophy — gains continue above it with strongly diminishing returns — so
    /// any bar maximum is arbitrary and must never be read as a target. 20 is chosen only because it
    /// comfortably contains the range people actually train in, which puts the floor tick early on
    /// the bar and makes a normal week read as progress rather than as "finished".
    ///
    /// The NUMBER beside the bar is the truth. The bar is context for it, and a count past 20 fills
    /// the bar while the number keeps counting.
    private static let weeklySetsBarSpan = 20.0

    /// One muscle's week: the count, and where it sits relative to the evidence.
    ///
    /// This used to scale the bar 0...4 and turn it FULL and GREEN at four sets — so the screen said
    /// "done" at the exact point the research says growth merely becomes *detectable*. It was telling
    /// the user to stop at the starting line, and it contradicted the caption printed directly below
    /// it. Now four sets is a TICK a fifth of the way along, and nothing on the bar ever reads as
    /// complete, because nothing about the dose is.
    private func muscleBar(_ muscle: LiftMuscle, sets: Double) -> some View {
        let floor = LiftMetrics.ReferenceDose.hypertrophyMinimumSetsPerWeek
        let atOrAboveFloor = sets >= floor
        let fill = min(1.0, sets / Self.weeklySetsBarSpan)
        let tick = min(1.0, floor / Self.weeklySetsBarSpan)

        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                Text(muscle.displayName)
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
                // Deliberately NOT a success colour. There is no success point to signal, and a
                // green number is exactly what made four sets read as an achievement.
                Text(LiftFormat.trim(sets))
                    .font(StrandFont.bodyNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("sets")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule()
                        // Muted below the floor — below it growth is not reliably detectable, which
                        // is worth showing — and the ordinary accent above it. Never a "done" colour.
                        .fill(StrandPalette.effortColor.opacity(atOrAboveFloor ? 1.0 : 0.45))
                        .frame(width: max(2, geo.size.width * fill))
                    // The floor, marked where it actually falls.
                    Capsule()
                        .fill(StrandPalette.textPrimary.opacity(0.45))
                        .frame(width: 2)
                        .offset(x: max(0, geo.size.width * tick - 1))
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 6)
            .accessibilityElement(children: .combine)
            .accessibilityLabel(atOrAboveFloor
                                ? String(localized: "\(muscle.displayName): \(LiftFormat.trim(sets)) sets, at or above the weekly floor of \(LiftFormat.trim(floor))")
                                : String(localized: "\(muscle.displayName): \(LiftFormat.trim(sets)) sets, below the weekly floor of \(LiftFormat.trim(floor))"))
        }
    }

    // MARK: - History

    private var historySection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Sessions")
            if history.isEmpty {
                Text("Finished sessions land here, with every set you logged.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            } else {
                NoopCard(padding: 0) {
                    VStack(spacing: 0) {
                        ForEach(Array(history.enumerated()), id: \.element.id) { index, session in
                            if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                            Button {
                                viewing = SessionDetailTarget(id: session.id, session: session)
                            } label: {
                                NoopListRow(icon: "dumbbell", iconColor: StrandPalette.effortColor,
                                            title: "\(session.programName ?? String(localized: "Session"))",
                                            subtitle: Date(timeIntervalSince1970: TimeInterval(session.startTs))
                                                .formatted(date: .abbreviated, time: .shortened))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Load

    private func load() async {
        guard let store = await repo.storeHandle() else { return }
        programs = (try? await store.liftPrograms(deviceId: repo.deviceId)) ?? []

        let now = Int(Date().timeIntervalSince1970)
        history = ((try? await store.liftSessions(deviceId: repo.deviceId,
                                                  fromTs: now - 180 * 86_400,
                                                  toTs: now)) ?? [])
            .filter { $0.endTs != nil }                 // an abandoned session is not history
            .sorted { $0.startTs > $1.startTs }
        weekCounts = (try? await store.liftSetCounts(deviceId: repo.deviceId,
                                                      fromTs: now - 7 * 86_400,
                                                      toTs: now).fractional) ?? [:]
        loaded = true
    }
}

/// The session whose detail is being read back. A wrapper rather than a retroactive `Identifiable`
/// on `LiftSessionRow`, keeping the store's row types free of app-layer conformances.
private struct SessionDetailTarget: Identifiable {
    let id: String
    let session: LiftSessionRow
}


/// Identifies what the editor sheet is editing. A wrapper rather than a retroactive `Identifiable`
/// on `LiftProgramRow`, so the store's row types stay free of app-layer conformances — and so
/// "new program" has an identity of its own to present on.
private struct ProgramEditTarget: Identifiable {
    let id: String
    let program: LiftProgramRow?
}

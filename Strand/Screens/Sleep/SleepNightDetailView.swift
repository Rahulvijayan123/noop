import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

// MARK: - One night (the Sleep tab's drill-down)
//
// Everything about ONE night, one tap below the Sleep tab's summary: the stage timeline with sleeping heart
// rate and movement on one clock axis (scrub to read any moment), the stage caveats in full, the stage
// split against the wearer's own typical range, the clock times with an explicit Edit, the naps with an
// always-available Add nap, the body-clock dial, and the hosted sleep features and analytics.
//
// Routed by the night's local WAKE DAY (`TabRoute.sleepNight(wakeDay:)`), never by carousel index: the
// carousel index shifts every time a newer night lands, the wake day does not. "latest" opens the newest.
//
// The edit / delete / undo / add-nap flows moved here from the tab root verbatim (same repo calls, same
// await order: write, `intelligence.analyzeRecent()`, `repo.refresh()`). The session loads are the same
// three calls, in the same order, the tab root makes, and are skipped when the tab root's own result for
// this refresh is in hand (`SleepSessionsCache`).

struct SleepNightDetailView: View {
    /// "yyyy-MM-dd" wake day, or "latest".
    let wakeDay: String

    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var intelligence: IntelligenceEngine
    @EnvironmentObject private var router: NavRouter

    /// The night on screen, by wake day. Starts at the routed one; the stepper moves it.
    @State private var currentWakeDay: String?
    @State private var snapshot: SleepSessionsCache.Snapshot?
    @State private var resolved: ResolvedNight?
    /// Sleeping heart rate for the night on screen (1-min buckets). nil while loading.
    @State private var nightHR: [HRBucket]?
    @State private var highlighted: SleepStage?
    @State private var selection: Date?

    @State private var wakeEdit: WakeEdit?
    @State private var addNap: AddNapSeed?
    @State private var sleepUndo: SleepUndoBanner?
    @State private var sleepUndoTask: Task<Void, Never>?

    /// The night and everything derived from it, resolved once per night (never per scrub frame).
    private struct ResolvedNight {
        let wakeDay: String
        let night: Night
        /// The day's index in the browse list (0 = newest) and the list length.
        let index: Int
        let dayCount: Int
        let newerWakeDay: String?
        let olderWakeDay: String?
        /// A real, persisted stage timeline (on-device staging). Imported nights carry totals only.
        let hasTimeline: Bool
        let isStub: Bool
        let timeline: NightTimeline?
        /// "Last night" / "N nights ago", counted in calendar nights (`SleepNightLabel.nightsAgo`).
        let relativeTitle: String
    }

    var body: some View {
        let r = resolved
        // Both halves: this page's blocks, and the repository's day rows the score and efficiency read.
        let loaded = snapshot != nil && repo.loaded
        ScreenScaffold(title: LocalizedStringKey(stringLiteral: r.map { SleepFormat.nightDateLine($0.night.session.endTs) }
                                                    ?? String(localized: "Night")),
                       titleDisplay: .navigationBar,
                       isLoading: !loaded) {
            // The page's date is its title; the stepper names the night relative to today and steps it.
            PeriodStepper(title: r?.relativeTitle ?? SleepFormat.relativeNight(0),
                          canGoBack: r?.olderWakeDay != nil, canGoForward: r?.newerWakeDay != nil,
                          onBack: { step(to: r?.olderWakeDay) }, onForward: { step(to: r?.newerWakeDay) })
            readout(r)
            chartCard(r)
            if let r, !r.isStub {
                let caveats = SleepCaveat.applicable(to: r.night, todayEfficiency: repo.today?.efficiency,
                                                     isOura: repo.activeDeviceIsOura)
                if !caveats.isEmpty { SleepCaveatList(caveats: caveats) }
                stagesSection(r.night)
            }
            timesSection(r)
            if let r { napsSection(r.night) }
            if let r, !r.isStub {
                BodyClockDialSection(actualBedHour: SleepView.localClockHour(r.night.session.effectiveStartTs),
                                     actualWakeHour: SleepView.localClockHour(r.night.session.endTs))
            }
            // The hosted sections render nothing until a document exists for this night, and bring their
            // own gap below them when one does, so an absent section leaves no empty band above About.
            VStack(alignment: .leading, spacing: 0) {
                if let r { hostedSections(r.night) }
                about(r)
            }
        }
        .overlay(alignment: .bottom) {
            if let sleepUndo {
                undoToast(sleepUndo)
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                    .padding(.bottom, NoopMetrics.space4)
                    .transition(.opacity)
            }
        }
        .onAppear {
            if currentWakeDay == nil { currentWakeDay = wakeDay }
            if snapshot == nil,
               let cached = SleepSessionsCache.shared.snapshot(refreshSeq: repo.refreshSeq, deviceId: repo.deviceId) {
                snapshot = cached
                resolve()
            }
        }
        // The same three loads, in the same order, the Sleep tab makes (SleepView's refresh task), re-run on
        // every sync, import or edit. Skipped when the tab's own result for this refresh is in hand.
        .task(id: repo.refreshSeq) {
            if let cached = SleepSessionsCache.shared.snapshot(refreshSeq: repo.refreshSeq, deviceId: repo.deviceId) {
                snapshot = cached
                resolve()
                return
            }
            let refresh = repo.refreshSeq
            let sessions = await repo.allSleepSessions()
            let habitual = await repo.habitualMidsleepSec()
            let motions = await repo.sessionMotions(sessions: sessions)
            guard !Task.isCancelled, refresh == repo.refreshSeq else { return }
            let snap = SleepSessionsCache.Snapshot(refreshSeq: refresh, deviceId: repo.deviceId, sessions: sessions,
                                                   habitualMidsleepSec: habitual, motionByStart: motions)
            SleepSessionsCache.shared.record(snap)
            snapshot = snap
            resolve()
        }
        // 1-min sleeping-HR buckets for the night on screen, reloaded only when the night changes (the same
        // call the stage card made).
        .task(id: resolved?.night.session.startTs) {
            guard let night = resolved?.night, resolved?.hasTimeline == true else { nightHR = []; return }
            nightHR = nil
            let buckets = await repo.hrBuckets(from: night.session.startTs,
                                               to: night.session.endTs,
                                               bucketSeconds: 60)
            guard !Task.isCancelled, resolved?.night.session.startTs == night.session.startTs else { return }
            nightHR = buckets
        }
        .onChangeCompat(of: currentWakeDay) { _ in resolve() }
        .sheet(item: $wakeEdit) { edit in
            // The night's RECORDED coverage for the #940 guards: from the immutable detected
            // onset (where the strap actually saw the night; an earlier hand-set onset widens
            // it) through the current wake. A corrected window that abandons this range has no
            // data to stage from, so the editor confirms the move instead of silently creating
            // a phantom night.
            let coverageLo = min(edit.detectedStartTs, edit.bedTs)
            SleepTimeEditor(bedTs: edit.bedTs, wakeTs: edit.wakeTs,
                            coverage: coverageLo...max(edit.wakeTs, coverageLo + 1),
                            suppressesReDetection: !edit.userEdited,
                            onSave: { newBedTs, newWakeTs in
                await repo.editSleepTimes(detectedStartTs: edit.detectedStartTs, oldEndTs: edit.wakeTs,
                                          storedStagesJSON: edit.stagesJSON,
                                          newStartTs: newBedTs, newEndTs: newWakeTs)
                // Re-score the day so the dashboard aggregates (Rest / recovery) honor the corrected
                // sleep window, not just the Sleep tab's session view; then refresh the read cache.
                await intelligence.analyzeRecent()
                await repo.refresh()
            }, onDelete: {
                // Delete = the edit path minus the re-insert: drop this session so every metric
                // recomputes immediately as if the night were never recorded, durably tombstoned so a
                // re-detect doesn't bring it back, then re-score + refresh exactly like an edit. (#68)
                // #65: the returned snapshot lets the user UNDO within a few seconds. It restores the
                // deleted row into its ORIGINAL namespace and lifts the tombstone.
                let deleted = await repo.deleteSleepSession(detectedStartTs: edit.detectedStartTs,
                                                            endTs: edit.wakeTs)
                await intelligence.analyzeRecent()
                await repo.refresh()
                // `edit.bedTs` is the effective (displayed) onset, so the banner shows the same clock
                // time the user saw for this night.
                if let deleted { presentSleepUndo(deleted, displayStart: edit.bedTs, windowEnd: edit.wakeTs) }
            })
        }
        // Manually add a missed nap (#508): same picker, but the chosen window is staged from raw and
        // stored as its OWN separate session — never folded into main sleep (which would mislabel the
        // awake daytime gap as light sleep).
        .sheet(item: $addNap) { seed in
            SleepTimeEditor(bedTs: seed.bedTs, wakeTs: seed.wakeTs,
                            title: "Add a nap",
                            blurb: "Pick when the nap started and ended. Nara stages it from your data as its own session, separate from the night's sleep.",
                            bedLabel: "Nap started", wakeLabel: "Nap ended") { startTs, endTs in
                await repo.addManualNap(startTs: startTs, endTs: endTs)
                // Re-score so the day's aggregates pick up the new session, exactly like an edit.
                await intelligence.analyzeRecent()
                await repo.refresh()
            }
        }
    }

    // MARK: - Resolution

    private func step(to day: String?) {
        guard let day else { return }
        selection = nil
        highlighted = nil
        currentWakeDay = day
    }

    /// Resolve the night for the current wake day from the loaded blocks (or the one-per-night list until
    /// they load). Pure reads through the shared `SleepModel` statics; the decode runs here, once per
    /// night change, never per render.
    private func resolve() {
        let sessions = snapshot.map { $0.sessions.isEmpty ? repo.sleeps : $0.sessions } ?? repo.sleeps
        let habitual = snapshot?.habitualMidsleepSec
        let motions = snapshot?.motionByStart ?? [:]
        let days = SleepModel.navDays(navSessions: sessions)
        let wanted = currentWakeDay ?? wakeDay
        let index: Int?
        if wanted == "latest" {
            index = days.isEmpty ? nil : 0
        } else {
            index = SleepModel.navIndex(wakeDay: wanted, navDays: days)
        }
        guard let index else { resolved = nil; return }
        func key(_ i: Int) -> String? {
            guard days.indices.contains(i), let end = days[i].first?.endTs else { return nil }
            return SleepFormat.wakeDayKey(end)
        }
        let blocks = days[index]
        let night: Night
        let isStub: Bool
        if let merged = SleepModel.decodedNight(at: index, navDays: days, habitualMidsleepSec: habitual,
                                                 motionByStart: motions) {
            night = merged
            isStub = false
        } else if let stubSession = SleepView.stubDaySession(blocks, habitualMidsleepSec: habitual) {
            // The honest stage-less stub (#940): the day's real blocks keep the edit affordance reachable.
            night = Night(session: stubSession, stages: Stages(awake: 0, light: 0, deep: 0, rem: 0),
                          sourceBlocks: blocks, habitualMidsleepSec: habitual)
            isStub = true
        } else {
            resolved = nil
            return
        }
        let hasTimeline = (night.realSegments?.count ?? 0) >= 2
        let timeline = hasTimeline
            ? NightTimeline(onset: night.onsetDate,
                            end: Date(timeIntervalSince1970: TimeInterval(night.session.endTs)),
                            intervals: night.intervals, motionFragments: night.motionFragments)
            : nil
        let nightsAgo = SleepNightLabel.nightsAgo(
            wakeTimestamps: days.map { $0.first.map { s in Int(s.endTs) } },
            offset: index,
            today: Repository.logicalDay(Date()))
        resolved = ResolvedNight(wakeDay: key(index) ?? wanted, night: night, index: index, dayCount: days.count,
                                 newerWakeDay: index > 0 ? key(index - 1) : nil,
                                 olderWakeDay: key(index + 1),
                                 hasTimeline: hasTimeline, isStub: isStub, timeline: timeline,
                                 relativeTitle: SleepFormat.relativeNight(nightsAgo))
    }

    /// The Rest score for the night on screen: the imported WHOOP figure for its wake day, else the
    /// resolved Rest composite for that day (the same read the Sleep tab's ring makes).
    private func performanceScore(for night: Night) -> Double? {
        let wakeDay = Repository.localDayKey(Date(timeIntervalSince1970: TimeInterval(night.session.endTs)))
        if let p = repo.importedSleep[wakeDay]?.performancePct { return p }
        guard let daily = repo.days.last(where: { $0.day == wakeDay }) else { return nil }
        return AnalyticsEngine.Rest.composite(daily: daily)
    }

    // MARK: - Readout

    private func readout(_ r: ResolvedNight?) -> some View {
        ValueReadout(readoutContent(r), isScrubbing: selection != nil, isLoading: snapshot == nil || !repo.loaded)
    }

    private func readoutContent(_ r: ResolvedNight?) -> ReadoutContent {
        guard let r else {
            return ReadoutContent(dateLine: " ", value: nil, unit: nil, context: nil)
        }
        let night = r.night
        if let selected = selection, let timeline = r.timeline, let seg = timeline.segment(at: selected) {
            // Scrubbing: the moment under the finger. The stage is the value; heart rate the context.
            let time = Night.clockString(Int(selected.timeIntervalSince1970))
            var context: [String] = []
            if let hr = nightHR, let b = NightTimelineChart.bucket(at: selected, in: hr) {
                context.append(String(localized: "\(Int(b.bpm.rounded())) bpm"))
            }
            context.append(String(localized: "\(SleepFormat.duration(seg.duration / 60)) in this stage"))
            return ReadoutContent(dateLine: time, value: seg.stage.label, unit: nil,
                                  context: context.joined(separator: " · "))
        }
        let score = r.isStub ? nil : performanceScore(for: night)
        let need = SleepModel.debtNeedMin(days: repo.days)
        var context: [String] = []
        if let score { context.append(SleepFormat.restWord(score)) }
        if !r.isStub {
            context.append(String(localized: "Asleep \(SleepFormat.duration(night.stages.asleep)) of \(SleepFormat.duration(need)) need"))
        }
        return ReadoutContent(dateLine: String(localized: "Rest"), value: SleepFormat.score(score), unit: nil,
                              context: context.isEmpty ? nil : context.joined(separator: " · "))
    }

    // MARK: - Primary chart

    @ViewBuilder
    private func chartCard(_ r: ResolvedNight?) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                if let r, let timeline = r.timeline {
                    NightTimelineChart(timeline: timeline,
                                       heartRate: nightHR.map { .ready($0) } ?? .loading,
                                       showsMovement: true,
                                       highlighted: highlighted,
                                       selection: $selection,
                                       stageHeight: 140)
                    StageLegendRow(stages: r.night.stages, highlighted: $highlighted)
                } else if let r, !r.isStub {
                    // An imported night carries stage TOTALS only: no timeline is drawn for it (the old
                    // card reconstructed a "plausible architecture", which read as a measured night).
                    Text("Stage totals only")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                    StageCompositionBar(stages: r.night.stages, highlighted: highlighted, height: 20)
                    StageLegendRow(stages: r.night.stages, highlighted: $highlighted, showsShare: true)
                } else if snapshot == nil {
                    ChartPlaceholder(height: 140 + NightTimelineChart.hrHeight + 60)
                } else {
                    EmptyChartMessage(r == nil ? String(localized: "No sleep recorded for this night")
                                               : String(localized: "No stage data recorded for this night."),
                                      height: 160)
                }
            }
        }
    }

    // MARK: - Stages vs typical

    private func stagesSection(_ night: Night) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Stages")
            StagesVsTypicalCard(stages: night.stages)
        }
    }

    // MARK: - Times

    @ViewBuilder
    private func timesSection(_ r: ResolvedNight?) -> some View {
        let night = r?.night
        let target = night?.editTarget
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            if let target {
                SectionHeader("Times", action: .button(label: "Edit") {
                    wakeEdit = WakeEdit(detectedStartTs: target.startTs,
                                        bedTs: target.effectiveStartTs,
                                        wakeTs: target.endTs,
                                        stagesJSON: target.stagesJSON,
                                        userEdited: target.userEdited)
                })
            } else {
                SectionHeader("Times")
            }
            let items = timeItems(night)
            StatGrid(items, columns: items.count == 4 ? 2 : 3, isLoading: snapshot == nil)
        }
    }

    private func timeItems(_ night: Night?) -> [StatItem] {
        guard let night else {
            return [StatItem("In bed", value: nil), StatItem("Asleep", value: nil), StatItem("Woke", value: nil)]
        }
        var items: [StatItem] = [StatItem(String(localized: "In bed"), value: night.onsetText)]
        // Asleep only when it differs from In bed (lying awake before the first sleep stage); the same
        // time twice reads like a duplicate.
        if let asleep = night.asleepText, asleep != night.onsetText {
            items.append(StatItem(String(localized: "Asleep"), value: asleep))
        }
        items.append(StatItem(String(localized: "Woke"), value: night.wakeText))
        items.append(StatItem(String(localized: "Time in bed"),
                              value: SleepFormat.duration(SleepNightFacts.windowMinutes(night))))
        if let eff = SleepNightFacts.efficiencyPct(night, days: repo.days) {
            items.append(StatItem(String(localized: "Efficiency"), value: "\(Int(eff.rounded()))", unit: "%"))
        }
        return items
    }

    // MARK: - Naps

    /// The day's sleep blocks OTHER than the night's bridged main group (#508, #555, #561), each editable
    /// with the same durable mechanism main sleep uses, plus Add nap, always available.
    @ViewBuilder
    private func napsSection(_ night: Night) -> some View {
        let groupStarts = night.mainGroupStarts
        let naps = night.sourceBlocks
            .filter { !groupStarts.contains($0.startTs) }
            .sorted { $0.effectiveStartTs < $1.effectiveStartTs }
        let mainMin = night.stages.total
        let napMin = naps.reduce(0.0) { $0 + Double($1.endTs - $1.effectiveStartTs) / 60.0 }
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Naps")
            if !naps.isEmpty {
                // Daily split (#518): Total = main + naps, the time that drives the day's Rest.
                StatGrid([StatItem(String(localized: "Main sleep"), value: SleepFormat.duration(mainMin)),
                          StatItem(String(localized: "Nap(s)"), value: SleepFormat.duration(napMin)),
                          StatItem(String(localized: "Total"), value: SleepFormat.duration(mainMin + napMin))],
                         columns: 3)
            }
            NoopListSection {
                ForEach(naps, id: \.startTs) { nap in
                    Button {
                        wakeEdit = WakeEdit(detectedStartTs: nap.startTs,
                                            bedTs: nap.effectiveStartTs,
                                            wakeTs: nap.endTs,
                                            stagesJSON: nap.stagesJSON,
                                            userEdited: true)   // a nap row is always manually added → no tombstone on delete
                    } label: {
                        NoopListRow(icon: "powersleep", iconColor: StrandPalette.restColor,
                                    title: LocalizedStringKey(stringLiteral: SleepFormat.window(nap.effectiveStartTs, nap.endTs)),
                                    subtitle: SleepFormat.duration(Double(nap.endTs - nap.effectiveStartTs) / 60.0),
                                    value: nap.userEdited ? String(localized: "Edited") : nil)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint(Text("Edit nap times"))
                    NoopListDivider(leadingInset: NoopListDivider.iconRowInset)
                }
                Button { addNap = AddNapSeed(forNight: night) } label: {
                    NoopListRow(icon: "plus.circle", iconColor: StrandPalette.accent, title: "Add nap",
                                showsChevron: false)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a nap")
            }
        }
    }

    // MARK: - Hosted sections

    @ViewBuilder
    private func hostedSections(_ night: Night) -> some View {
        // Sleep details (spec 7.5): rendered only when a hosted sleep-features document exists for this
        // night. With no payload this renders nothing.
        let session = night.session
        // Sleep analytics (docs/sleep-analytics/spec.md §8 app step 3): the Phase-1
        // `daily.sleep_analytics_v1` document, rendered only when it exists for THIS night AND passes the
        // staleness guard (the night's main-night GROUP is what the guard matches the document's fragments
        // against). No payload, or a stale pre-edit document, renders nothing.
        let group = SleepView.mainNightGroup(night.sourceBlocks, habitualMidsleepSec: night.habitualMidsleepSec)
        let currentSessions = group.isEmpty ? [night.session] : group
        SleepFeatureSection(startTs: session.effectiveStartTs, endTs: session.endTs, currentSessions: currentSessions)
        SleepAnalyticsSection(startTs: night.session.effectiveStartTs, endTs: night.session.endTs,
                              currentSessions: currentSessions)
    }

    // MARK: - About

    private func about(_ r: ResolvedNight?) -> some View {
        AboutDisclosure("About this night") {
            AboutParagraphs(aboutParagraphs(r))
        }
    }

    private func aboutParagraphs(_ r: ResolvedNight?) -> [String] {
        var out: [String] = []
        if repo.activeDeviceIsOura {
            out.append(String(localized: "Stages here are the ring's raw on-device classification, read over Bluetooth."))
        } else if r?.hasTimeline == true {
            out.append(String(localized: "Stages are approximate: Nara estimates them from your strap's heart rate and movement. The chart smooths very short stage changes so the night reads clearly; the totals use every recorded stage."))
        } else {
            out.append(String(localized: "This night was imported with stage totals only, so there is no timeline to draw."))
        }
        out.append(String(localized: "In bed runs from when you settled to when you woke. Asleep starts with the first sleep stage."))
        if let night = r?.night, night.sourceBlocks.contains(where: { !night.mainGroupStarts.contains($0.startTs) }) {
            // The "why this is a nap" note that used to sit behind an info button on every nap row.
            out.append(String(localized: "Logged as a nap. Wrong? Tap Edit to adjust your sleep and wake times."))
        }
        if r != nil, r?.olderWakeDay == nil {
            out.append(String(localized: "No earlier night stored yet. Earlier nights sync in the morning."))
        }
        return out
    }

    // MARK: - Delete undo (#65)

    /// Show the transient UNDO banner after a suppressing delete, and arm the 7-second auto-dismiss. A
    /// second delete replaces the banner (its old auto-dismiss task is cancelled first) so only the most
    /// recent delete is undoable. Single-level and transient, matching the WorkoutsView postLogNote idiom.
    private func presentSleepUndo(_ snapshot: SleepDeletionSnapshot, displayStart: Int, windowEnd: Int) {
        sleepUndoTask?.cancel()
        withAnimation(.easeOut(duration: 0.2)) {
            sleepUndo = SleepUndoBanner(snapshot: snapshot, identityStart: snapshot.session.startTs,
                                        displayStart: displayStart, windowEnd: windowEnd)
        }
        let armed = snapshot.session.startTs
        sleepUndoTask = Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Only clear if this is still the banner we armed (a newer delete would have replaced it).
                if sleepUndo?.identityStart == armed {
                    withAnimation(.easeOut(duration: 0.2)) { sleepUndo = nil }
                }
            }
        }
    }

    /// Undo the most recent suppressing delete: restore the row into its ORIGINAL namespace, lift the
    /// tombstone, re-score, then dismiss the banner.
    private func undoSleepDelete(_ banner: SleepUndoBanner) async {
        sleepUndoTask?.cancel()
        await repo.undoDeleteSleepSession(banner.snapshot)
        await intelligence.analyzeRecent()
        await repo.refresh()
        await MainActor.run { withAnimation(.easeOut(duration: 0.2)) { sleepUndo = nil } }
    }

    /// Locale-formatted clock time (no date) for the banner's window range.
    private func clockTime(_ ts: Int) -> String {
        Date(timeIntervalSince1970: TimeInterval(ts))
            .formatted(Date.FormatStyle(date: .omitted, time: .shortened)
                .locale(AppClock.formattingLocale))   // #1821
    }

    /// The undo toast over the bottom of the page: it never pushes the page down.
    @ViewBuilder
    private func undoToast(_ banner: SleepUndoBanner) -> some View {
        // Branch the copy on userEdited: a hand-edited/added night writes NO tombstone (it is never
        // re-detected), so the suppression promise would be false for it. Only a DETECTED delete writes a
        // tombstone, so only it gets the "won't detect ... again" wording. (#65 banner honesty.)
        let message = banner.snapshot.session.userEdited
            ? String(localized: "Sleep deleted.")
            : String(localized: "Sleep deleted. Nara won't detect sleep between \(clockTime(banner.displayStart)) and \(clockTime(banner.windowEnd)) again.")
        SleepToast(message: message, actionTitle: "Undo", actionAccessibilityLabel: "Undo sleep deletion") {
            Task { await undoSleepDelete(banner) }
        }
    }
}

// MARK: - Toast

/// A transient one-line status over the bottom of a Sleep page (the undo after a delete, "Sleep result
/// updated"). An overlay, so it never moves the content when it comes or goes.
struct SleepToast: View {
    let message: String
    var actionTitle: LocalizedStringKey? = nil
    var actionAccessibilityLabel: LocalizedStringKey? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(message)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let actionTitle, let action {
                Button(action: action) {
                    Text(actionTitle)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(minWidth: NoopMetrics.minimumHitTarget, minHeight: NoopMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(actionAccessibilityLabel.map { Text($0) } ?? Text(actionTitle))
            }
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .background(NoopPanelSurface(cornerRadius: NoopMetrics.cardRadius, elevated: true))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Edit plumbing (moved verbatim from SleepView)

/// The transient UNDO banner state after a suppressing delete (#65). `identityStart` is the immutable
/// detected key so a stale auto-dismiss task can tell whether it still owns the current banner;
/// `displayStart` is the effective (shown) onset for the message clock.
private struct SleepUndoBanner {
    let snapshot: SleepDeletionSnapshot
    let identityStart: Int
    let displayStart: Int
    let windowEnd: Int
}

/// Identifies the night being edited for `.sheet(item:)`. A night's `startTs` is its stable natural
/// key (wake-time edits never move it), so it doubles as the sheet identity.
private struct WakeEdit: Identifiable {
    let detectedStartTs: Int   // immutable detected key the edit writes against
    let bedTs: Int             // current effective onset (seeds the bed picker)
    let wakeTs: Int            // current wake (seeds the wake picker)
    let stagesJSON: String?
    /// True for a hand-edited / manually-added (nap) night. Such a delete writes NO tombstone (it is
    /// never re-detected), so the editor's delete-confirm copy must NOT promise re-detection suppression
    /// for it. Mirrors the undo-banner branch (#65 banner/confirm honesty).
    let userEdited: Bool
    var id: Int { detectedStartTs }
}

/// Seeds the "Add nap" picker (#508). A nap is short, so seed a 30-minute window anchored to the night's
/// wake (a natural place to look for a missed afternoon nap), clamped to never start before the night's
/// onset. The identity is the seed start so `.sheet(item:)` presents once per request.
private struct AddNapSeed: Identifiable {
    let bedTs: Int
    let wakeTs: Int
    var id: Int { bedTs }
    init(forNight night: Night) {
        // Anchor an hour after the night's wake; a 30-min default window the user adjusts.
        let anchor = night.session.endTs + 3_600
        self.bedTs = anchor
        self.wakeTs = anchor + 30 * 60
    }
}

/// A small sheet to hand-correct a night's bed (onset) and wake (end) instants. Seeds both pickers with
/// the current values, including each calendar date. Hands the chosen unix-second (bed, wake) back via
/// `onSave`. Pure presentation + a single async save — persistence lives in the repo.
private struct SleepTimeEditor: View {
    let onSave: (Int, Int) async -> Void
    /// Optional destructive delete (#68). Non-nil for an existing main-sleep / nap edit (the editor then
    /// shows a "Delete this sleep" button gated behind a confirmation); nil for the "Add a nap" sheet,
    /// which has nothing to delete yet.
    let onDelete: (() async -> Void)?
    private let title: LocalizedStringKey
    private let blurb: LocalizedStringKey
    private let bedLabel: LocalizedStringKey
    private let wakeLabel: LocalizedStringKey
    private let deleteLabel: LocalizedStringKey
    /// The night's RECORDED coverage (detected onset ... current wake, unix seconds) for the #940
    /// guards: a time-only bed roll past the wake auto-decrements the date, and a corrected window
    /// fully outside this range gets an explicit confirm instead of silent acceptance. nil for the
    /// "Add a nap" sheet, whose window deliberately sits outside the night (only the future-bed
    /// guard applies there).
    private let coverage: ClosedRange<Int>?
    /// True when deleting THIS session writes a re-detection tombstone (a DETECTED night). false for a
    /// userEdited/nap row, which is never re-detected, so the delete-confirm copy drops the suppression
    /// promise for it, matching the undo banner. (#65 confirm honesty.)
    private let suppressesReDetection: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var bed: Date
    @State private var wake: Date
    @State private var saving = false
    @State private var confirmingDelete = false
    /// The bed value BEFORE the in-flight picker change, so the #940 auto-correct can tell a
    /// time-only roll (same calendar day: rescue it) from a deliberate date change (respect it).
    @State private var previousBed: Date
    /// True while the #940 "no recorded data there" confirm is up; Save proceeds only on consent.
    @State private var confirmingDisjoint = false

    /// `title`/`blurb`/`bedLabel`/`wakeLabel` default to the edit-an-existing-night wording; the
    /// "Add a nap" caller (#508) overrides them. The save logic is identical either way — adding a nap
    /// is just an edit whose "existing" window is a seed. `onDelete` (#68) is the optional destructive
    /// action; `deleteLabel` lets the nap editor say "Delete this nap".
    init(bedTs: Int, wakeTs: Int,
         title: LocalizedStringKey = "Edit sleep times",
         blurb: LocalizedStringKey = "Correct when you went to bed and woke. Stages are re-derived from your data; the edit is kept through the next strap sync.",
         bedLabel: LocalizedStringKey = "In bed",
         wakeLabel: LocalizedStringKey = "Woke",
         deleteLabel: LocalizedStringKey = "Delete this sleep",
         coverage: ClosedRange<Int>? = nil,
         suppressesReDetection: Bool = true,
         onSave: @escaping (Int, Int) async -> Void,
         onDelete: (() async -> Void)? = nil) {
        self.onSave = onSave
        self.onDelete = onDelete
        self.title = title; self.blurb = blurb
        self.bedLabel = bedLabel; self.wakeLabel = wakeLabel
        self.deleteLabel = deleteLabel
        self.coverage = coverage
        self.suppressesReDetection = suppressesReDetection
        // A bed can never be seeded in the future (#940): the "Add a nap" anchor is wake+1h, which is
        // ahead of the clock right after a morning sync; clamp so the picker opens inside its bound.
        let seedBed = min(bedTs, Int(Date().timeIntervalSince1970))
        _bed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _previousBed = State(initialValue: Date(timeIntervalSince1970: TimeInterval(seedBed)))
        _wake = State(initialValue: Date(timeIntervalSince1970: TimeInterval(wakeTs)))
    }

    /// The current edit window after the same future/inverted/duration guards used by persistence.
    private var validatedWindow: (start: Int, end: Int)? {
        SleepEditGuard.clampedEditWindow(
            start: Int(bed.timeIntervalSince1970),
            end: Int(wake.timeIntervalSince1970),
            now: Int(Date().timeIntervalSince1970))
    }

    /// The single save funnel: both the direct Save and the #940 disjoint confirm land here.
    private func commit(start: Int, end: Int) {
        saving = true
        Task {
            await onSave(start, end)
            dismiss()
        }
    }

    var body: some View {
        let canSave = validatedWindow != nil

        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(title).font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text(blurb)
                .font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            NoopCard(padding: NoopMetrics.cardPadding) {
                VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                    // Bed is bounded to the PAST (#940): a sleep can't start in the future, and an
                    // unbounded picker let a cross-midnight time roll land the bed on the coming
                    // evening, creating a future-dated night the tab couldn't render.
                    DatePicker(bedLabel, selection: $bed, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.accent)
                    NoopListDivider(leadingInset: 0)
                    // The wake date and time are both editable so corrections preserve the exact
                    // endpoint selected by the user (#970).
                    DatePicker(wakeLabel, selection: $wake, in: ...Date(),
                               displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.compact)
                        .font(StrandFont.body)
                        .tint(StrandPalette.accent)
                }
            }

            // Destructive delete for an existing night/nap (#68). Confirmation-gated so a tap can't clear
            // a night by accident; nil for the "Add a nap" sheet (nothing to delete). Sits below the
            // pickers, visually separated from the primary Save action.
            if onDelete != nil {
                Button(role: .destructive) { confirmingDelete = true } label: {
                    Label(deleteLabel, systemImage: "trash")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.statusCritical)
                        .frame(minHeight: NoopMetrics.minimumHitTarget)
                }
                .buttonStyle(.plain)
                .disabled(saving)
                .accessibilityLabel(deleteLabel)
            }

            HStack(spacing: NoopMetrics.gap) {
                NoopButton("Cancel", kind: .tertiary) { dismiss() }
                    .disabled(saving)
                Spacer()
                Button(saving ? "Saving…" : "Save") {
                    // #940 guard 2: a corrected window that no longer touches the night's recorded
                    // coverage has no data to stage from. Silently accepting it fabricated an
                    // all-awake phantom night; ask first.
                    guard let window = validatedWindow else { return }
                    if let coverage, SleepEditGuard.isDisjoint(
                        newStart: window.start, newEnd: window.end,
                        coverageStart: coverage.lowerBound, coverageEnd: coverage.upperBound) {
                        confirmingDisjoint = true
                    } else {
                        commit(start: window.start, end: window.end)
                    }
                }
                .buttonStyle(NoopButtonStyle(.primary))
                .disabled(saving || !canSave)
                .opacity(canSave ? 1 : 0.55)
            }
        }
        .padding(NoopMetrics.screenHPadding)
        .frame(minWidth: 360)
        .background(StrandPalette.surfaceBase)
        // #940 guard 1: a time-only roll that lands the bed in the future, or at/after the night's
        // wake, almost always means the PREVIOUS evening (23:00 "yesterday", not tonight). Snap the
        // date back a day so the picker visibly shows the night the user meant. Pure rule + tests:
        // SleepEditGuard.autoCorrectedBed (Android twin in com.noop.analytics).
        .onChangeCompat(of: bed) { newBed in
            let corrected = SleepEditGuard.autoCorrectedBed(
                previousBed: previousBed, candidateBed: newBed,
                originalWake: coverage.map { Date(timeIntervalSince1970: TimeInterval($0.upperBound)) },
                now: Date())
            previousBed = corrected
            if corrected != newBed { bed = corrected }
        }
        // #940 guard 2's consent step. On-brand role-tagged .alert, same shape as the delete confirm.
        .alert("Move this sleep?", isPresented: $confirmingDisjoint) {
            Button("Cancel", role: .cancel) { }
            Button("Move anyway") {
                guard let window = SleepEditGuard.clampedEditWindow(
                    start: Int(bed.timeIntervalSince1970),
                    end: Int(wake.timeIntervalSince1970),
                    now: Int(Date().timeIntervalSince1970)) else { return }
                commit(start: window.start, end: window.end)
            }
        } message: {
            Text("This moves the night to a time with no recorded data. Stages can't be derived there, so it may show as empty until data covers it.")
        }
        // On-brand destructive confirm — the same role-tagged .alert DevicesView uses for "Remove this
        // device?", not a bare default. (#68 — Android parity: "Delete this sleep session?")
        .alert("Delete this sleep session?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                saving = true
                Task {
                    await onDelete?()
                    dismiss()
                }
            }
        } message: {
            // A detected night is tombstoned so it won't re-detect; a userEdited/nap row writes no
            // tombstone, so its copy drops that (false) promise. Mirrors the undo banner. (#65)
            Text(suppressesReDetection
                 ? "Removes this recorded sleep and recomputes the day without it. Nara won't re-detect sleep in this window. You can undo for a few seconds after."
                 : "Removes this sleep and recomputes the day without it. You can undo for a few seconds after.")
        }
    }
}

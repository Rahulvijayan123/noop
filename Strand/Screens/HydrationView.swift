import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - Hydration detail (MVP, opt-in, local-only)
//
// Hydration has a real goal, so its glance is a goal ring: today's litres against the goal. Below it the
// quick-log buttons (Sip / Cup / Bottle / a custom size), today's logged drinks (tap to edit, trash to
// delete), and the last seven days as bars with the goal rule. BYTE-PARITY twin of the Android
// `HydrationScreen` for the data: the day total + history come from the local-only `HydrationStore`
// series (additive day total), and the goal is the pure `HydrationGoal` engine (profile sex + today's
// Effort bump).
struct HydrationView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var profile: ProfileStore

    /// Today's running total (ml) + the 7-day history (oldest→newest), loaded off the gesture path and
    /// refreshed after each log. A reload key the taps bump so the `.task` re-reads the store.
    @State private var totalML: Double = 0
    @State private var history: [(day: String, value: Double)] = []
    @State private var reloadTick = 0
    @State private var loaded = false
    /// The day under the finger on the week chart.
    @State private var selectedDay: Date?
    /// #798 - today's individual logged drinks (for swipe-to-delete + tap-to-edit), and the entry being
    /// edited in the amount sheet (nil when the sheet is closed).
    @State private var entries: [HydrationEntry] = []
    /// Water imported from Apple Health for today (#949) — part of `totalML`, surfaced separately so the
    /// drinks card can show it as its own, non-editable line.
    @State private var importedML: Double = 0
    @State private var editingEntry: HydrationEntry?
    /// #798 - the user's custom container size (ml), editable from the custom-size sheet. Persisted local-only.
    @AppStorage(HydrationStore.customSizeKey) private var customSizeML = HydrationGoal.cupML
    @State private var showCustomSizeSheet = false

    private var goalML: Int { repo.hydrationGoalML(profileSex: profile.sex) }
    private var fraction: Double { HydrationGoal.fraction(totalML: totalML, goalML: goalML) }
    private var percent: Int { min(100, Int((fraction * 100).rounded(.towardZero))) }

    private func litres(_ ml: Double) -> String { String(format: "%.1f", HydrationGoal.litres(fromML: ml)) }

    var body: some View {
        ScreenScaffold(title: "Hydration", titleDisplay: .navigationBar, isLoading: !loaded,
                       onRefresh: { await reload() }) {
            ringSection
            logSection
            entriesSection
            historySection
            AboutDisclosure(paragraphs: [
                String(localized: "A simple goal that adjusts to your effort. General wellness guidance, not medical advice."),
                String(localized: "Your fluid intake today, on \(Platform.deviceNounPhrase) only."),
            ])
        }
        .task(id: reloadTick) { await reload() }
        // #798 - edit a logged drink's amount.
        .sheet(item: $editingEntry) { entry in
            HydrationAmountSheet(title: "Edit drink", initialML: entry.amountMl) { newML in
                editingEntry = nil
                Task { await updateEntry(entry, to: newML) }
            } onCancel: { editingEntry = nil }
        }
        // #798 - set the custom container size.
        .sheet(isPresented: $showCustomSizeSheet) {
            HydrationAmountSheet(title: "Custom size", initialML: customSizeML) { newML in
                customSizeML = newML
                showCustomSizeSheet = false
            } onCancel: { showCustomSizeSheet = false }
        }
    }

    // MARK: - Goal ring (today's litres toward the goal)

    private var ringSection: some View {
        NoopCard {
            HStack(spacing: NoopMetrics.space5) {
                ScoreRing(fraction: fraction, value: litres(totalML),
                          caption: String(localized: "of \(litres(Double(goalML))) L"),
                          color: StrandPalette.metricCyan, diameter: 132, isLoading: !loaded)
                VStack(alignment: .leading, spacing: NoopMetrics.space1) {
                    Text("Today").strandLabel()
                    HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space1) {
                        Text("\(Int(totalML))")
                            .font(StrandFont.number(28))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("ml").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                    }
                    Text("\(percent)% of today's goal")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Hydration today")
            .accessibilityValue("\(litres(totalML)) of \(litres(Double(goalML))) litres")
        }
    }

    // MARK: - Quick log (Sip / Cup / Bottle, secondary style)

    private var logSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Log a drink")
            HStack(spacing: NoopMetrics.gap) {
                logButton("Sip", systemImage: "drop", ml: HydrationGoal.sipML)
                logButton("Cup", systemImage: "cup.and.saucer.fill", ml: HydrationGoal.cupML)
                logButton("Bottle", systemImage: "drop.fill", ml: HydrationGoal.bottleML)
            }
            // #798 - a custom container the user sizes themselves. Tapping logs it; the pencil opens the
            // size editor so a one-off mug / flask / glass can be set once and reused.
            HStack(spacing: NoopMetrics.gap) {
                NoopButton("Custom \(customSizeML) ml", systemImage: "drop.circle", kind: .secondary, fullWidth: true) {
                    Task { await add(ml: customSizeML) }
                }
                .accessibilityLabel("Log custom \(customSizeML) millilitres")
                Button { showCustomSizeSheet = true } label: {
                    Image(systemName: "pencil")
                        .font(StrandFont.icon(.row))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: NoopMetrics.controlHeight, height: NoopMetrics.controlHeight)
                        .background(NoopInsetSurface())
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Set custom container size")
            }
        }
    }

    /// One quick-add button: the container and its size, so no separate key is needed.
    private func logButton(_ title: LocalizedStringKey, systemImage: String, ml: Int) -> some View {
        Button {
            Task { await add(ml: ml) }
        } label: {
            VStack(spacing: NoopMetrics.spaceHalf) {
                Label(title, systemImage: systemImage)
                    .font(StrandFont.subhead.weight(.medium))
                Text("\(ml) ml")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(NoopButtonStyle(.secondary))
        .accessibilityLabel("Log \(title)")
    }

    // MARK: - Today's logged drinks (#798) - tap to edit, trash to delete

    @ViewBuilder private var entriesSection: some View {
        // Also shown when the only water today came from Apple Health (#949) — otherwise the ring would
        // count drinks the screen never accounts for, and the day would look like it appeared from nowhere.
        if !entries.isEmpty || importedML > 0 {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Today's drinks")
                NoopListSection {
                    if importedML > 0 { importedRow }
                    // #842 — rows in a plain VStack inside the page ScrollView (no nested List): tap a row to
                    // edit; the trailing trash deletes.
                    ForEach(Array(entries.enumerated()), id: \.element.id) { idx, entry in
                        if idx > 0 || importedML > 0 { NoopListDivider() }
                        entryRow(entry)
                    }
                }
            }
        }
    }

    /// Water Apple Health already had, from a hydration app or a smart bottle (#949).
    ///
    /// Deliberately not tappable and with no trash: Nara does not own these drinks, and "deleting" one
    /// here would be a lie — the next sync re-reads the same day from Health and the figure would come
    /// straight back. Removing it for real means removing it in the app that logged it.
    private var importedRow: some View {
        NoopListRow(icon: "heart.text.square", title: "From Apple Health",
                    value: "\(Int(importedML.rounded())) ml", showsChevron: false)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(Int(importedML.rounded())) millilitres from Apple Health. Edit it in the app that logged it.")
    }

    /// One logged-drink row: the time it was logged + its amount (tap to edit) with a trailing trash.
    private func entryRow(_ entry: HydrationEntry) -> some View {
        HStack(spacing: 0) {
            Button { editingEntry = entry } label: {
                NoopListRow(icon: "drop.fill", iconColor: StrandPalette.metricCyan,
                            title: LocalizedStringKey(Self.entryTimeFmt.string(from: entry.loggedAt)),
                            value: "\(entry.amountMl) ml", showsChevron: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Logged \(entry.amountMl) millilitres at \(Self.entryTimeFmt.string(from: entry.loggedAt))")
            .accessibilityHint("Tap to edit the amount")
            Button(role: .destructive) {
                Task { await deleteEntry(entry) }
            } label: {
                Image(systemName: "trash")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(.trailing, NoopMetrics.space2)
            .accessibilityLabel("Delete the \(entry.amountMl) millilitre drink logged at \(Self.entryTimeFmt.string(from: entry.loggedAt))")
        }
    }

    /// #1821: routed through AppClock so the Clock format setting reaches this label. Was a `static
    /// let`, which would have frozen the reader's choice at first use until the app relaunched.
    private static var entryTimeFmt: DateFormatter { AppClock.hourMinuteFormatter() }

    // MARK: - The last 7 days (daily totals against the goal)

    private var historyPoints: [DailyPoint] {
        history.compactMap { DailyPoint(key: $0.day, value: HydrationGoal.litres(fromML: $0.value)) }
    }

    private var historySection: some View {
        let points = historyPoints
        let window = ChartAxis.window(.week, firstDataDay: points.first?.day)
        let goal = HydrationGoal.litres(fromML: Double(goalML))
        let shown = selectedDay.flatMap { ChartSelection.point(for: $0, in: points) }
        let inWindow = points.filter { window.contains($0.day) }
        let avg = inWindow.isEmpty ? nil : inWindow.map(\.value).reduce(0, +) / Double(inWindow.count)
        return VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Last 7 days")
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    InsightsCardReadout(
                        value: (selectedDay == nil ? avg : shown?.value).map { String(format: "%.1f", $0) },
                        unit: "L",
                        context: selectedDay.map { ReadoutContent.dateLine($0, period: .day) }
                            ?? String(localized: "Average · \(ChartRange.week.accessibilityName)"))
                    DailyBarChart.totals(points, color: StrandPalette.metricCyan,
                                         goal: ChartReference(goal, label: String(localized: "Goal")),
                                         bin: .day,
                                         state: !loaded ? .loading
                                             : (points.isEmpty ? .empty(String(localized: "No history yet.")) : .ready),
                                         window: window, xStyle: .weekday,
                                         y: ChartValueAxis(unit: "L", domain: .fitted(minSpan: 1, includeZero: true),
                                                           format: ChartValueAxis.decimals(1)),
                                         selection: $selectedDay, height: NoopMetrics.chartHeightSecondary,
                                         accessibilityTitle: String(localized: "Hydration"))
                }
            }
        }
    }

    // MARK: - Data

    /// Log `ml` (additive day total + a per-entry row, #798) and refresh.
    private func add(ml: Int) async {
        guard ml > 0 else { return }
        _ = await repo.logHydration(amountMl: ml)
        reloadTick &+= 1
    }

    /// #798 - delete a logged drink, re-deriving the day total, then refresh.
    private func deleteEntry(_ entry: HydrationEntry) async {
        _ = await repo.deleteHydrationEntry(id: entry.id)
        reloadTick &+= 1
    }

    /// #798 - set a logged drink's amount, re-deriving the day total, then refresh.
    private func updateEntry(_ entry: HydrationEntry, to ml: Int) async {
        _ = await repo.updateHydrationEntry(id: entry.id, amountMl: ml)
        reloadTick &+= 1
    }

    /// Load today's total + the 7-day history + today's per-entry list from the store.
    private func reload() async {
        totalML = await repo.hydrationTotal(day: Repository.localDayKey(Date()))
        history = await repo.hydrationHistory(days: 7)
        entries = repo.hydrationEntries()
        // #949: `totalML` already includes this; read it separately so the drinks card can name where
        // the difference came from instead of leaving an unexplained gap between the ring and the list.
        importedML = await repo.hydrationImportedTotal(day: Repository.localDayKey(Date()))
        loaded = true
    }
}

// MARK: - Amount sheet (#798) - edit a drink / set the custom size

/// A small stepper sheet for an ml amount. Reused by the edit-entry and custom-size flows. Tokens only,
/// NoopButton actions, ARIA labels. Clamps to a sane range so the value stays a real container size.
private struct HydrationAmountSheet: View {
    let title: LocalizedStringKey
    let initialML: Int
    let onSave: (Int) -> Void
    let onCancel: () -> Void

    @State private var ml: Int

    /// Bounds for a plausible single container (10 ml up to 3 L), stepping in 10 ml increments.
    private static let minML = 10
    private static let maxML = 3000
    private static let stepML = 10

    init(title: LocalizedStringKey, initialML: Int, onSave: @escaping (Int) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.initialML = initialML
        self.onSave = onSave
        self.onCancel = onCancel
        _ml = State(initialValue: Self.clamp(initialML))
    }

    static func clamp(_ value: Int) -> Int { min(maxML, max(minML, value)) }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            Text(title)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            HStack {
                Text("Amount")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer()
                Text("\(ml) ml")
                    .font(StrandFont.number(28))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
            }
            Stepper(value: $ml, in: Self.minML...Self.maxML, step: Self.stepML) {
                Text("Adjust amount")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .accessibilityLabel("Amount in millilitres")
            .accessibilityValue("\(ml) millilitres")
            HStack(spacing: NoopMetrics.gap) {
                NoopButton("Cancel", kind: .secondary, fullWidth: true) { onCancel() }
                NoopButton("Save", kind: .primary, fullWidth: true) { onSave(Self.clamp(ml)) }
            }
        }
        .padding(NoopMetrics.space5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        // iOS-only sheet sizing - macOS sheets are free-floating windows and reject detents (see the
        // shared `noopSheetPresentation` note); the call site stays cross-platform via this guard.
        #if os(iOS)
        .presentationDetents([.height(300)])
        .presentationDragIndicator(.visible)
        #endif
    }
}

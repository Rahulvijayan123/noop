import SwiftUI
import StrandDesign
import WhoopStore

/// Carries the measured natural height of the Sport picker's floating suggestion panel up to the
/// view, so the overlay can size itself to its content (capped) rather than to the text field.
private struct SuggestionsHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// MARK: - Manual workout sheet
//
// Add a workout you tracked elsewhere, or edit one you already logged. Six inputs — sport,
// start, duration, distance, average HR, calories — validated by WorkoutSource.buildManualRow (the same
// honest-row rules the engine uses). On save the caller persists it under the strap source via
// Repository.saveManualWorkout. Captured-but-unexposed fields (maxHr / strain / zones) on an edited
// row are carried over by WorkoutSource.preservingCaptured so editing a live-tracked session's
// sport/duration never silently wipes its real strain.
//
// `editing` is non-nil when editing an existing row (its values pre-fill the form and it is passed
// as `replacing:` so a changed natural key deletes the old row). nil = a fresh add.

struct ManualWorkoutSheet: View {
    /// The row being edited, or nil for a new manual workout.
    let editing: WorkoutRow?
    /// Called with the validated row (and the original, when editing) once the user taps Save.
    let onSave: (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var sport: String
    @State private var start: Date
    /// #2034: the span is `start` + `end`. Duration is DERIVED (`durationBinding`), never a second stored
    /// copy, so the two cannot drift; the row has always been stored as `startTs`/`endTs` anyway, and
    /// routing the save through whole minutes was what silently reshaped an edited session's end.
    @State private var end: Date
    @State private var avgHrText: String
    @State private var kcalText: String
    /// Distance as ENTERED, in the user's unit (km or mi) — converted to stored metres on save (#1195).
    @State private var distanceText: String

    /// Exercise-distance choice. Unset follows the original combined setting for existing installs.
    @AppStorage(UnitPrefs.systemKey) private var unitSystemRaw = UnitSystem.metric.rawValue
    @AppStorage(UnitPrefs.distanceSystemKey) private var distanceSystemRaw = ""
    private var distanceUnitSystem: UnitSystem {
        UnitPrefs.resolveDistance(
            system: UnitSystem(rawValue: unitSystemRaw) ?? .metric,
            override: distanceSystemRaw)
    }
    private var distanceUnit: String { UnitFormatter.distanceUnit(distanceUnitSystem) }

    /// Focus for the numeric (Avg HR / Calories / Distance) fields so the keyboard Done button can resign
    /// them — the decimal pad has no return key. iOS-only effect; the enum keeps both platforms compiling.
    private enum NumberField: Hashable { case avgHr, calories, distance }
    @FocusState private var focusedField: NumberField?

    /// Whether the Sport text field is being edited — drives whether the catalogue suggestions show
    /// beneath it. The list also stays hidden once the typed text exactly matches a catalogue sport
    /// (a settled choice), so the form isn't permanently half-covered.
    @FocusState private var sportFocused: Bool

    /// Measured natural height of the floating suggestion panel's content, so the overlay can size
    /// itself (capped at 168) instead of being squeezed to the text field's height. See `suggestionList`.
    @State private var suggestionsHeight: CGFloat = 0

    init(editing: WorkoutRow? = nil,
         onSave: @escaping (_ row: WorkoutRow, _ replacing: WorkoutRow?) -> Void) {
        self.editing = editing
        self.onSave = onSave
        // Pre-fill from the edited row (display "detected" as "Activity" so a re-label starts clean).
        let e = editing
        // Seeds the LOCALE-STABLE editable form, not the localized display: the field's content is
        // persisted verbatim on save, and a translated word would split cross-source dedup per language.
        _sport = State(initialValue: e.map { WorkoutSource.editableSport($0.sport) } ?? "")
        // A fresh add opens on a VALID 45 minute session ending now, keeping the long-standing 45 minute
        // default length. It used to start at `Date()` with a 45 minute duration, so the implied end was
        // always 45 minutes in the future and `buildManualRow` rejected it: the sheet opened with Save
        // already disabled. That was invisible while the only complaint was the catch-all "Check the
        // values and try again."; now that an end in the future says so by name, it would greet every
        // fresh add with a red line. Anchoring to the end is also the truer default for the retroactive
        // entry this sheet is for.
        let defaultEnd = Date()
        _start = State(initialValue: e.map { Date(timeIntervalSince1970: TimeInterval($0.startTs)) }
                       ?? defaultEnd.addingTimeInterval(-45 * 60))
        _end = State(initialValue: e.map { Date(timeIntervalSince1970: TimeInterval($0.endTs)) }
                     ?? defaultEnd)
        _avgHrText = State(initialValue: e?.avgHr.map(String.init) ?? "")
        _kcalText = State(initialValue: e?.energyKcal.map { String(Int($0.rounded())) } ?? "")
        // Pre-fill the distance in the user's unit so an untouched edit round-trips the stored metres
        // (buildManualRow then re-stores exactly what's shown). @AppStorage isn't usable pre-init, so read
        // the same key directly.
        let bodySystem = UnitSystem(
            rawValue: UserDefaults.standard.string(forKey: UnitPrefs.systemKey) ?? "") ?? .metric
        let sys = UnitPrefs.resolveDistance(
            system: bodySystem,
            override: UserDefaults.standard.string(forKey: UnitPrefs.distanceSystemKey) ?? "")
        _distanceText = State(initialValue: e?.distanceM.map { Self.distanceEntryString($0, system: sys) } ?? "")
    }

    /// The stored metres shown as a clean editable number in `system`'s unit (km/mi) — trailing zeros and a
    /// dangling decimal trimmed so the field reads "5.2", not "5.20". Two decimals (~10 m) is plenty for a
    /// hand-entered distance; the field's purpose is manual entry, not preserving GPS's metre precision.
    private static func distanceEntryString(_ meters: Double, system: UnitSystem) -> String {
        let km = meters / 1000.0
        let value = system == .imperial ? km * UnitFormatter.milesPerKilometer : km
        var s = String(format: "%.2f", value)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    var body: some View {
        NavigationStack {
            #if os(macOS)
            formContent
                .padding(NoopMetrics.space6)
                .frame(width: 420)
                .navigationTitle(title)
                .toolbar { toolbarItems }
                // Lets the user dismiss the decimal pad (which has no return key) and reach Cancel/Add.
                .keyboardDoneToolbar($focusedField)
            #else
            // #450 raised the sheet to .large so the keyboard had room. The form scrolls so that iOS's
            // keyboard-avoidance has somewhere to scroll INSTEAD of rigidly displacing fixed content,
            // which once pushed the Sport field (and the top of its floating suggestion overlay) off the
            // top of the screen. Cancel and Add live in the navigation bar, clear of the keyboard's own
            // Done accessory.
            ScrollView {
                formContent
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                    .padding(.vertical, NoopMetrics.space4)
            }
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            .scrollDismissesKeyboard(.interactively)
            // A fixed 420pt is right for the free-floating macOS sheet, but on iPhone it's wider than
            // the screen (#185). iOS fills the presented sheet's width.
            .frame(maxWidth: .infinity)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarItems }
            // Lets the user dismiss the decimal pad (which has no return key).
            .keyboardDoneToolbar($focusedField)
            #endif
        }
        #if os(iOS)
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private var title: LocalizedStringKey { editing == nil ? "Add workout" : "Edit workout" }

    @ToolbarContentBuilder
    private var toolbarItems: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button(editing == nil ? "Add" : "Save") { save() }
                .disabled(builtRow == nil)
                .accessibilityLabel(editing == nil ? "Add workout" : "Save workout")
        }
    }

    private var formContent: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            NoopCard {
                field(String(localized: "Sport")) {
                    sportPicker
                }
            }
            // Raise the Sport card above the following cards so its floating suggestion dropdown (an
            // overlay, see `sportPicker`) draws ON TOP of Start / End / Duration, not behind them.
            .zIndex(1)
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    formRow(String(localized: "Start")) {
                        DatePicker("", selection: startBinding, in: ...Date(),
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .accessibilityLabel("Start date and time")
                    }
                    NoopListDivider()
                    formRow(String(localized: "End")) {
                        DatePicker("", selection: $end, in: ...Date(),
                                   displayedComponents: [.date, .hourAndMinute])
                            .labelsHidden()
                            .accessibilityLabel("End date and time")
                    }
                    NoopListDivider()
                    formRow(String(localized: "Duration")) {
                        Stepper(value: durationBinding, in: 1...(24 * 60), step: 5) {
                            Text(durationLabel)
                                .font(StrandFont.bodyNumber)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .accessibilityLabel("Duration in minutes")
                    }
                }
            }
            NoopCard(padding: 0) {
                VStack(spacing: 0) {
                    formRow(String(localized: "Distance")) {
                        numberInput(String(localized: "optional"), text: $distanceText, unit: distanceUnit, field: .distance)
                            .accessibilityLabel("Distance, optional")
                    }
                    NoopListDivider()
                    formRow(String(localized: "Avg HR")) {
                        numberInput(String(localized: "optional"), text: $avgHrText, unit: "bpm", field: .avgHr)
                            .accessibilityLabel("Average heart rate in beats per minute, optional")
                    }
                    NoopListDivider()
                    formRow(String(localized: "Calories")) {
                        numberInput(String(localized: "optional"), text: $kcalText, unit: "kcal", field: .calories)
                            .accessibilityLabel("Calories in kilocalories, optional")
                    }
                }
            }
            // An empty sport needs no notice: the field is first, and Add stays disabled until it is filled.
            if let validationNote, !sport.trimmingCharacters(in: .whitespaces).isEmpty {
                InlineNotice(validationNote, tone: .warning)
            }
            if avgHrEditedNote {
                InlineNotice(String(localized: "Avg HR is shown as typed. The HR graph, zones and Effort stay from the recorded session."))
            }
        }
    }

    // MARK: - Sport picker
    //
    // A searchable PICKER over the shared WorkoutCatalog (the same named-sport list the live tracker
    // uses, incl. Padel) with a free-text FALLBACK: the text field IS the value, so an unusual sport
    // NOOP doesn't enumerate still saves exactly as typed (#519). Typing filters the catalogue
    // beneath the field; tapping a match fills it; the list collapses on a settled / off-catalogue
    // entry so the short form isn't permanently covered. Mirrors Android WorkoutsScreen.SportPickerField.

    /// Suggestions for the current text — the whole catalogue while empty, else a case-insensitive
    /// name filter. Empty list ⇒ a free-typed sport with no match (keeps whatever was typed).
    private var sportSuggestions: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(sport) }

    /// Show the list only while the field is focused, there are matches, and the text isn't already an
    /// exact catalogue name (a settled choice collapses it).
    private var showSportSuggestions: Bool {
        sportFocused && !sportSuggestions.isEmpty && WorkoutCatalog.sport(named: sport) == nil
    }

    /// #297: the user's last selections, one tap away above the full catalogue. Raw stored names —
    /// this picker allows free text, so an off-catalogue recent stays selectable here (it just
    /// carries no GPS hint). Only rendered while the field is empty (typing means searching).
    private var recentSports: [String] { RecentSportsPrefs.recent() }

    private var showRecentSports: Bool {
        sport.trimmingCharacters(in: .whitespaces).isEmpty && !recentSports.isEmpty
    }

    private var sportPicker: some View {
        TextField("e.g. Running", text: $sport)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .focused($sportFocused)
            .padding(.horizontal, NoopMetrics.space3).padding(.vertical, NoopMetrics.space2 + 2)
            .background(StrandPalette.surfaceInset, in: inputShape)
            .accessibilityLabel("Sport")
            // The suggestion list FLOATS below the field as an overlay instead of sitting inline in the
            // form. Inline it was the only height-flexible element, so on iPhone with the keyboard up
            // the fixed-height fields below won the vertical space and squeezed it to nothing — the
            // #297 Recent block (and even the catalogue matches) never showed. As an overlay it doesn't
            // take part in the form's layout, so it renders at full height over the rows below; the
            // parent raises this field's zIndex so it draws on top of them.
            .overlay(alignment: .bottom) {
                if showSportSuggestions {
                    suggestionList
                        // Pin the panel's TOP to the field's BOTTOM (its own top stands in as the
                        // bottom-alignment anchor), then nudge it down for a small gap.
                        .alignmentGuide(.bottom) { $0[.top] }
                        .offset(y: 6)
                }
            }
    }

    /// The floating suggestion panel (Recent + full catalogue). An overlay proposes the field's small
    /// height to its content, which would re-squeeze a plain `.frame(maxHeight:)` ScrollView — so we
    /// MEASURE the content's natural height and set an explicit frame capped at 168, letting it scroll
    /// only past that. This is the same list the inline version rendered, just floated + self-sized.
    private var suggestionList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if showRecentSports {
                    Text("Recent").strandLabel()
                        .padding(.horizontal, 12).padding(.top, 8)
                    ForEach(recentSports, id: \.self) { name in
                        suggestionRow(name, isDistance: WorkoutCatalog.sport(named: name)?.isDistanceSport == true)
                    }
                    Text("All activities").strandLabel()
                        .padding(.horizontal, 12).padding(.top, 8)
                }
                ForEach(sportSuggestions) { sp in
                    suggestionRow(sp.name, isDistance: sp.isDistanceSport)
                }
            }
            .background(GeometryReader { geo in
                Color.clear.preference(key: SuggestionsHeightKey.self, value: geo.size.height)
            })
        }
        // #697 parity: this screen builds its OWN ScrollView rather than going through
        // ScreenScaffold, so it never inherited the scaffold's horizontal-bounce suppression and
        // could still rubber-band left-right on a purely vertical scroll. Same modifier, same
        // guard. `.basedOnSize` permits horizontal bounce only when content genuinely overflows
        // the width, so nothing that is meant to scroll sideways is affected. (#1532 follow-up)
        #if os(iOS)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        .frame(height: min(max(suggestionsHeight, 1), 168))
        .onPreferenceChange(SuggestionsHeightKey.self) { suggestionsHeight = $0 }
        .background(NoopPanelSurface(cornerRadius: NoopMetrics.insetRadius, elevated: true))
    }

    /// One tappable suggestion row — shared by the #297 Recent block and the full catalogue list.
    private func suggestionRow(_ name: String, isDistance: Bool) -> some View {
        Button {
            sport = name
            sportFocused = false
        } label: {
            HStack(spacing: 6) {
                Text(name)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if isDistance {
                    Text("· GPS")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Pick \(name)")
    }

    // MARK: - Fields

    /// A labelled field (the Sport text field and its suggestions).
    private func field<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            Text(label).strandLabel()
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// One form row: the label leading, the control trailing, at the list-row height.
    private func formRow<Content: View>(_ label: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize()
            Spacer(minLength: NoopMetrics.space2)
            content()
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space1)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight)
    }

    private func numberInput(_ placeholder: String, text: Binding<String>, unit: String, field: NumberField) -> some View {
        HStack(spacing: NoopMetrics.space2) {
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textPrimary)
                .multilineTextAlignment(.trailing)
                // Numeric entry → decimal pad on iOS (digits + "."), not the QWERTY default; no-op on macOS.
                .numericKeyboard()
                .focused($focusedField, equals: field)
            Text(unit).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.horizontal, NoopMetrics.space3)
        .padding(.vertical, NoopMetrics.space2)
        // One width for the three boxes so the column of values lines up (#234).
        .frame(width: 150)
        .background(NoopInsetSurface())
    }

    // MARK: - Validation / build

    private var inputShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: NoopMetrics.insetRadius, style: .continuous)
    }

    /// Moving the START keeps the workout's LENGTH and carries the end with it, which is what correcting
    /// "this began an hour earlier" means. Computed from the old start before it is reassigned.
    ///
    /// Clamped so the carried end cannot land in the future: dragging the start forward would otherwise
    /// push the end past now and invalidate the sheet on a move that looks entirely reasonable. Clamping
    /// the START keeps the length the user set, where clamping the end would silently shorten the session.
    private var startBinding: Binding<Date> {
        Binding(get: { start },
                set: { picked in
                    let span = end.timeIntervalSince(start)
                    let newStart = min(picked, Date().addingTimeInterval(-span))
                    end = WorkoutSource.endAfterStartMove(oldStart: start, oldEnd: end, newStart: newStart)
                    start = newStart
                })
    }

    /// Duration is a VIEW of the span, not a stored copy. Reading clamps into the Stepper's own range so
    /// an end that is currently before the start cannot hand it an out-of-range value; the honest verdict
    /// on that state comes from `validationNote`, not from this label. Writing moves the end.
    private var durationBinding: Binding<Int> {
        Binding(get: { min(24 * 60, max(1, WorkoutSource.spanDurationMin(start: start, end: end))) },
                set: { end = WorkoutSource.endForDuration(start: start, durationMin: $0) })
    }

    private var durationLabel: String {
        let durationMin = durationBinding.wrappedValue
        let h = durationMin / 60, m = durationMin % 60
        if h > 0 && m > 0 { return String(localized: "\(h) h \(m) m") }
        if h > 0 { return String(localized: "\(h) h") }
        return String(localized: "\(m) min")
    }

    /// Parsed avg-HR — nil for blank, an out-of-band sentinel handled by buildManualRow otherwise.
    private var avgHr: Int? { Int(avgHrText.trimmingCharacters(in: .whitespaces)) }
    private var kcal: Double? { Double(kcalText.trimmingCharacters(in: .whitespaces)) }

    /// Parsed distance in stored METRES — nil for blank (no distance), or when the typed value can't be a
    /// non-negative number. The user enters km/mi; convert to metres for the row. (#1195)
    private var distanceMeters: Double? {
        let t = distanceText.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, let v = Double(t), v >= 0 else { return nil }
        let km = distanceUnitSystem == .imperial ? v / UnitFormatter.milesPerKilometer : v
        return km * 1000.0
    }

    /// The validated row, or nil when the inputs can't make an honest one (drives the disabled Save +
    /// the inline note). Built through the same WorkoutSource.buildManualRow the engine trusts.
    private var builtRow: WorkoutRow? {
        // A typed-but-unparseable number is invalid (e.g. "abc" in Avg HR) — guard before building.
        if !avgHrText.trimmingCharacters(in: .whitespaces).isEmpty && avgHr == nil { return nil }
        if !kcalText.trimmingCharacters(in: .whitespaces).isEmpty && kcal == nil { return nil }
        if !distanceText.trimmingCharacters(in: .whitespaces).isEmpty && distanceMeters == nil { return nil }
        guard let base = WorkoutSource.buildManualRowFromSpan(start: start, end: end,
                                                              sport: sport, avgHr: avgHr, energyKcal: kcal,
                                                              distanceM: distanceMeters)
        else { return nil }
        // Carry over captured-but-unexposed fields when editing an existing strap session.
        return WorkoutSource.preservingCaptured(base, from: editing)
    }

    /// #18: true when this edit changes the Avg HR on a row that carries CAPTURED strain/zones from a
    /// recorded session. preservingCaptured keeps the old strain/zonesJSON verbatim, so a typed Avg HR is
    /// saved while the HR graph, zones and Effort stay from the recording. That mismatch is silent, so we
    /// surface a one-line note. We do NOT re-score from a single number (that would fabricate a strain),
    /// this is purely an honest disclosure. nil for a fresh add, or when nothing captured would go stale.
    private var avgHrEditedNote: Bool {
        guard let editing, let built = builtRow else { return false }
        let captured = editing.strain != nil || editing.zonesJSON != nil
        return captured && built.avgHr != editing.avgHr
    }

    private var validationNote: String? {
        guard builtRow == nil else { return nil }
        if sport.trimmingCharacters(in: .whitespaces).isEmpty { return String(localized: "Enter a sport.") }
        if start > Date() { return String(localized: "Start can't be in the future.") }
        // The failure this feature introduces, so it gets its own line rather than the catch-all below.
        if end <= start { return String(localized: "End must be after the start.") }
        if end > Date() { return String(localized: "End can't be in the future.") }
        // Its own line rather than the catch-all below: "Check the values and try again." gives a wearer
        // no way to know a 30-second entry is the thing being refused. Matches the live-session floor, so
        // the same session is treated the same whether it was tracked or typed in.
        if Int(end.timeIntervalSince1970) - Int(start.timeIntervalSince1970) < WorkoutSource.minManualSpanSeconds {
            return String(localized: "A workout must be at least 1 minute.")
        }
        if !avgHrText.trimmingCharacters(in: .whitespaces).isEmpty, avgHr == nil || !(25...250).contains(avgHr ?? -1) {
            return String(localized: "Average HR must be 25-250 bpm.")
        }
        if !kcalText.trimmingCharacters(in: .whitespaces).isEmpty, kcal == nil || (kcal ?? -1) < 0 || (kcal ?? 0) > 20_000 {
            return String(localized: "Calories must be 0-20,000.")
        }
        if !distanceText.trimmingCharacters(in: .whitespaces).isEmpty,
           distanceMeters == nil || (distanceMeters ?? -1) < 0 || (distanceMeters ?? 0) > 1_000_000 {
            return distanceUnitSystem == .imperial
                ? String(localized: "Distance must be 0–621 mi.")
                : String(localized: "Distance must be 0–1,000 km.")
        }
        return String(localized: "Check the values and try again.")
    }

    private func save() {
        guard let row = builtRow else { return }
        // #297: a confirmed save is a real selection — fold the (validated) sport into the recents.
        RecentSportsPrefs.recordSelection(row.sport)
        onSave(row, editing)
        dismiss()
    }
}

#if DEBUG
#Preview("Add") {
    ManualWorkoutSheet { _, _ in }
        .preferredColorScheme(.dark)
}

#Preview("Edit") {
    ManualWorkoutSheet(editing: WorkoutRow(
        startTs: Int(Date().timeIntervalSince1970) - 3600, endTs: Int(Date().timeIntervalSince1970),
        sport: "Running", source: "manual", durationS: 3600, energyKcal: 540,
        avgHr: 148, maxHr: 172, strain: 12.4, distanceM: nil, zonesJSON: nil, notes: nil, steps: nil)) { _, _ in }
        .preferredColorScheme(.dark)
}
#endif

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Caregiver tab: add / edit / calendar-log treatments. Shares `BaselineStore` with Baseline.
///
/// Top to bottom: the month calendar of logged days, the open course with its two actions (or the button
/// that starts one), the watch list, the log (newest first; a row opens its editor), the Baseline link and
/// the About card. Starting a treatment, logging a dose, ending a course and editing a log entry are the
/// shared editor sheets (NavigationStack, Form, Cancel and the action in the toolbar).
struct TreatmentCaregiverView: View {
    @EnvironmentObject var repo: Repository
    @EnvironmentObject var store: BaselineStore
    @EnvironmentObject var router: NavRouter
    @State private var month = Date()
    @State private var selectedDay = ""
    @State private var formName = ""
    @State private var formDose = ""
    @State private var formKind: LBTreatmentKind = .medication
    @State private var formDay = Date()
    @State private var formTime = Date()
    @State private var formOnset = 7
    @State private var formWashout = 7
    @State private var formPrimaries: Set<LBSeries> = []
    @State private var formNotes = ""
    @State private var formSchedule: LBMedSchedule = .daily
    @State private var showingStart = false

    private var days: [DailyMetric] { store.displayDays(from: repo.days) }

    var body: some View {
        ScreenScaffold(
            title: "Treatment",
            titleDisplay: .navigationBar,
            onRefresh: { await repo.refresh(); store.rescore(days: days) }
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: NoopMetrics.sectionGap) {
                    calendarCard
                        .frame(width: 260)
                    formAndLog
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    calendarCard
                    formAndLog
                }
            }
        }
        .onAppear {
            let tape = days
            if store.evaluation == nil, let last = tape.last?.day {
                store.asOf = last
                store.longAsOf = last
            }
            if selectedDay.isEmpty { selectedDay = store.asOf }
            if let selected = TreatmentStamp.date(fromISO: selectedDay) {
                month = selected
                formDay = selected
            }
            store.rescore(days: tape)
            #if DEBUG
            DemoTreatmentSeeder.seedIfRequested(into: store, days: tape)
            openDemoSheetIfRequested()
            #endif
        }
        .sheet(isPresented: Binding(
            get: { store.editingEventIndex != nil },
            set: { if !$0 { store.editingEventIndex = nil } }
        )) {
            if let index = store.editingEventIndex {
                TreatmentEditSheet(store: store, index: index)
                    #if os(iOS)
                    .noopSheetPresentation(largeFirst: true)
                    #endif
            }
        }
        .sheet(isPresented: $store.showDoseForm) {
            TreatmentDoseSheet(store: store, defaultDay: selectedDay)
                #if os(iOS)
                .noopSheetPresentation(largeFirst: true)
                #endif
        }
        .sheet(isPresented: $store.showEndForm) {
            TreatmentEndSheet(store: store, defaultDay: selectedDay)
                #if os(iOS)
                .noopSheetPresentation(largeFirst: true)
                #endif
        }
        .sheet(isPresented: $showingStart) {
            startSheet
                #if os(iOS)
                .noopSheetPresentation(largeFirst: true)
                #endif
        }
    }

    private var calendarCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                PeriodStepper(title: TreatmentStamp.monthTitle(month), canGoBack: true, canGoForward: true,
                              onBack: { shiftMonth(-1) }, onForward: { shiftMonth(1) })
                TreatmentMonthGrid(month: month, selectedDay: selectedDay,
                                   markedDays: store.eventDays) { day in
                    selectedDay = day
                    if let date = TreatmentStamp.date(fromISO: day) {
                        formDay = date
                    }
                }
            }
        }
    }

    private var formAndLog: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
            if store.activeStart != nil {
                activeCourseCard
            }
            NoopButton("Start a treatment", systemImage: "plus",
                       kind: store.activeStart == nil ? .primary : .secondary, fullWidth: true) {
                showingStart = true
            }
            if store.activeStart != nil {
                watchListSection
            }
            logSection
            baselineLink
            AboutDisclosure(paragraphs: [
                String(localized: "Starting a treatment sets your usual without it from the nights before its start time. Baseline then reads the course against that usual."),
                String(localized: "The watch list is ranked by how solid each usual is today (its trust and nights), not by how much it moved after the start. Unpinned series stay on Baseline as exploratory."),
                String(localized: "Treatment logs stay on this device."),
            ])
        }
    }

    private var baselineLink: some View {
        NoopListSection {
            Button { router.openBaseline() } label: {
                NoopListRow(icon: "rectangle.split.2x1", title: "Baseline")
            }
            .accessibilityLabel("Open Baseline")
        }
        .buttonStyle(.plain)
    }

    /// The start form, as a sheet: the longest block on the page and used once per course.
    private var startSheet: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Name") {
                        TextField("Treatment name", text: $formName)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Kind", selection: $formKind) {
                        ForEach(LBTreatmentKind.allCases, id: \.self) { kind in
                            Text(kind.displayLabel).tag(kind)
                        }
                    }
                    LabeledContent("Dose") {
                        TextField("Optional", text: $formDose)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("How you take it", selection: $formSchedule) {
                        ForEach(LBMedSchedule.allCases, id: \.self) { sched in
                            Text(sched.displayLabel).tag(sched)
                        }
                    }
                }
                .eventEditorRow()
                Section {
                    DatePicker("Start day", selection: $formDay, displayedComponents: .date)
                    DatePicker("Clock time", selection: $formTime, displayedComponents: .hourAndMinute)
                } footer: {
                    Text("Nights before this time set your usual without treatment.")
                }
                .eventEditorRow()
                Section {
                    Stepper(value: $formOnset, in: 1...60) {
                        Text("Expected onset: \(formOnset) days")
                    }
                    Stepper(value: $formWashout, in: 1...60) {
                        Text("Expected washout: \(formWashout) days")
                    }
                    LabeledContent("Notes") {
                        TextField("From the clinic or label", text: $formNotes)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .eventEditorRow()
                Section {
                    primaryPicker
                } header: {
                    Text("Watch")
                } footer: {
                    Text("Optional. Leave blank and Nara watches the three steadiest.")
                }
                .eventEditorRow()
            }
            .eventEditorForm()
            .navigationTitle("Start a treatment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showingStart = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        startTreatment()
                        showingStart = false
                    }
                    .disabled(formName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: NoopMetrics.editorSheetMinWidth, minHeight: NoopMetrics.editorSheetMinHeight)
        #endif
    }

    /// Logs the start exactly as the inline form did, then clears the form.
    private func startTreatment() {
        let stamp = TreatmentStamp.split(day: formDay, time: formTime)
        store.logStart(name: formName.trimmingCharacters(in: .whitespaces),
                       dose: formDose.isEmpty ? nil : formDose,
                       civilDay: stamp.day, clockTime: stamp.clock,
                       enteredBy: .caregiver,
                       kind: formKind, days: days,
                       onsetDays: formOnset, washoutDays: formWashout,
                       primarySeries: Array(formPrimaries),
                       notes: formNotes.isEmpty ? nil : formNotes,
                       schedule: formSchedule)
        selectedDay = stamp.day
        formName = ""
        formDose = ""
        formNotes = ""
        formPrimaries = []
    }

    private var primaryPicker: some View {
        let options = store.displayedSeries
        return ForEach(options, id: \.rawValue) { s in
            let on = formPrimaries.contains(s)
            Button {
                if on {
                    formPrimaries.remove(s)
                } else if formPrimaries.count < 3 {
                    formPrimaries.insert(s)
                }
            } label: {
                HStack {
                    Text(store.shortTitle(for: s))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Image(systemName: on ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(on ? StrandPalette.accent : StrandPalette.textTertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private var watchListSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Watch list", trailing: String(localized: "Pin up to three"))
            NoopListSection {
                ForEach(Array(store.watchCandidates.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
                    Button {
                        store.toggleWatch(row.series, days: days)
                    } label: {
                        NoopListRow(icon: row.pinned ? "pin.fill" : "pin",
                                    iconColor: row.pinned ? StrandPalette.accent : StrandPalette.textTertiary,
                                    title: verbatimKey(store.shortTitle(for: row.series)),
                                    subtitle: row.established
                                        ? String(localized: "Usual established · Trust \(row.trust)%")
                                        : String(localized: "Still building · Trust \(row.trust)%"),
                                    value: row.pinned ? String(localized: "Watching") : nil, valueTone: .accent,
                                    showsChevron: false)
                    }
                    .disabled(!row.pinned && (store.activeStart?.primarySeries.count ?? 0) >= 3)
                }
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var activeCourseCard: some View {
        if let start = store.activeStart {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                        Text("Open course")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                        Text(verbatim: start.bannerName)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack(spacing: NoopMetrics.space3) {
                        NoopButton("Log dose", kind: .secondary, fullWidth: true) { store.showDoseForm = true }
                        NoopButton("End course", kind: .secondary, fullWidth: true) { store.showEndForm = true }
                    }
                }
            }
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            SectionHeader("Log")
            NoopListSection {
                if store.events.isEmpty {
                    Text("Nothing logged yet.")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .padding(.horizontal, NoopMetrics.cardPadding)
                        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
                } else {
                    // Newest first, like every other list in the app; a row opens its editor.
                    let rows = store.events.enumerated().sorted {
                        ($0.element.civilDay, $0.element.clockTime) > ($1.element.civilDay, $1.element.clockTime)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, pair in
                        if rowIdx > 0 { NoopListDivider() }
                        Button { store.beginEdit(index: pair.offset) } label: {
                            NoopListRow(icon: nil, title: verbatimKey(pair.element.bannerName),
                                        subtitle: "\(BaselinePlotScale.mediumDate(pair.element.civilDay)) · \(pair.element.clockTime)",
                                        value: Self.typeLabel(pair.element.type))
                        }
                        .accessibilityHint("Edit")
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    static func typeLabel(_ type: LBTreatmentEventType) -> String {
        switch type {
        case .start: return String(localized: "Start")
        case .dose: return String(localized: "Dose")
        case .doseChange: return String(localized: "Dose change")
        case .stop: return String(localized: "Ended")
        case .interruption: return String(localized: "Pause")
        case .restart: return String(localized: "Restart")
        }
    }

    static func reasonLabel(_ reason: LBStopReason) -> String {
        switch reason {
        case .completed: return String(localized: "Completed")
        case .doctorStopped: return String(localized: "Stopped by a doctor")
        case .sideEffects: return String(localized: "Side effects")
        case .missedSupply: return String(localized: "Ran out")
        case .other: return String(localized: "Other")
        }
    }

    #if DEBUG
    /// `--demo-treatment-sheet start|dose|end|edit`: open one sheet for a screenshot (DEBUG only).
    private func openDemoSheetIfRequested() {
        switch DemoLaunch.stringArg("--demo-treatment-sheet") {
        case "start": showingStart = true
        case "dose": store.showDoseForm = true
        case "end": store.showEndForm = true
        case "edit" where !store.events.isEmpty: store.beginEdit(index: 0)
        default: break
        }
    }
    #endif

    private func shiftMonth(_ delta: Int) {
        if let next = Calendar.current.date(byAdding: .month, value: delta, to: month) {
            month = next
        }
    }
}

struct TreatmentMonthGrid: View {
    let month: Date
    let selectedDay: String
    let markedDays: Set<String>
    let onSelect: (String) -> Void

    private var cells: [String?] {
        let cal = Calendar.current
        let start = cal.date(from: cal.dateComponents([.year, .month], from: month)) ?? month
        let weekday = cal.component(.weekday, from: start)
        let pad = weekday - cal.firstWeekday
        let leading = (pad + 7) % 7
        let daysInMonth = cal.range(of: .day, in: .month, for: start)?.count ?? 30
        var out: [String?] = Array(repeating: nil, count: leading)
        for d in 1...daysInMonth {
            if let date = cal.date(byAdding: .day, value: d - 1, to: start) {
                out.append(TreatmentStamp.iso(from: date))
            }
        }
        return out
    }

    var body: some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
        VStack(spacing: 6) {
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(Self.weekdaySymbols().enumerated()), id: \.offset) { _, w in
                    Text(w)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity)
                }
            }
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(Array(cells.enumerated()), id: \.offset) { _, day in
                    if let day {
                        Button { onSelect(day) } label: {
                            Text("\(Int(day.split(separator: "-").last ?? "0") ?? 0)")
                                .font(StrandFont.captionNumber)
                                .frame(maxWidth: .infinity, minHeight: NoopMetrics.minimumHitTarget)
                                .background(cellFill(day), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .overlay(alignment: .bottom) {
                                    // A day with an entry is also marked by a dot, so the fill is not the only cue.
                                    if markedDays.contains(day) {
                                        Circle().fill(StrandPalette.statusPositive).frame(width: 5, height: 5).padding(.bottom, 5)
                                    }
                                }
                                .foregroundStyle(day == selectedDay ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(Text(verbatim: day))
                        .accessibilityValue(markedDays.contains(day) ? Text("Has an entry") : Text(""))
                        .accessibilityAddTraits(day == selectedDay ? .isSelected : [])
                    } else {
                        Color.clear.frame(minHeight: NoopMetrics.minimumHitTarget)
                    }
                }
            }
        }
    }

    /// The header letters in the calendar's own week order, so they sit over the columns the grid fills
    /// (the grid starts its weeks on `firstWeekday`; a fixed Sunday-first row put every date under the
    /// wrong letter in Monday-first locales).
    static func weekdaySymbols(calendar: Calendar = .current) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        guard symbols.count == 7 else { return symbols }
        let shift = ((calendar.firstWeekday - 1) % 7 + 7) % 7
        return Array(symbols[shift...] + symbols[..<shift])
    }

    private func cellFill(_ day: String) -> Color {
        if day == selectedDay { return StrandPalette.accent.opacity(0.28) }
        if markedDays.contains(day) { return StrandPalette.statusPositive.opacity(0.22) }
        return Color.clear
    }
}

struct TreatmentEditSheet: View {
    @ObservedObject var store: BaselineStore
    @EnvironmentObject var repo: Repository
    let index: Int
    @State private var name = ""
    @State private var dose = ""
    @State private var kind: LBTreatmentKind = .medication
    @State private var day = Date()
    @State private var time = Date()
    @State private var confirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.events.indices.contains(index) {
                        LabeledContent("Entry", value: TreatmentCaregiverView.typeLabel(store.events[index].type))
                    }
                    LabeledContent("Name") {
                        TextField("Treatment name", text: $name)
                            .multilineTextAlignment(.trailing)
                    }
                    Picker("Kind", selection: $kind) {
                        ForEach(LBTreatmentKind.allCases, id: \.self) { k in
                            Text(k.displayLabel).tag(k)
                        }
                    }
                    LabeledContent("Dose") {
                        TextField("Optional", text: $dose)
                            .multilineTextAlignment(.trailing)
                    }
                }
                .eventEditorRow()
                Section {
                    DatePicker("Day", selection: $day, displayedComponents: .date)
                    DatePicker("Clock time", selection: $time, displayedComponents: .hourAndMinute)
                }
                .eventEditorRow()
                Section {
                    Button("Delete entry", role: .destructive) { confirmingDelete = true }
                }
                .eventEditorRow()
            }
            .eventEditorForm()
            .navigationTitle("Edit treatment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.editingEventIndex = nil }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let stamp = TreatmentStamp.split(day: day, time: time)
                        store.updateEvent(at: index,
                                          name: name.trimmingCharacters(in: .whitespaces),
                                          dose: dose.isEmpty ? nil : dose,
                                          civilDay: stamp.day, clockTime: stamp.clock,
                                          enteredBy: .caregiver,
                                          kind: kind,
                                          days: store.displayDays(from: repo.days))
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .confirmationDialog("Delete this entry?", isPresented: $confirmingDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    store.deleteEvent(at: index, days: store.displayDays(from: repo.days))
                }
                Button("Cancel", role: .cancel) {}
            }
            .onAppear { load() }
        }
        #if os(macOS)
        .frame(minWidth: NoopMetrics.editorSheetMinWidth, minHeight: NoopMetrics.editorSheetMinHeight)
        #endif
    }

    private func load() {
        guard store.events.indices.contains(index) else { return }
        let e = store.events[index]
        name = e.displayName
        dose = e.doseText ?? ""
        kind = e.kind
        day = TreatmentStamp.date(fromISO: e.civilDay) ?? Date()
        time = TreatmentStamp.time(fromClock: e.clockTime) ?? Date()
    }
}

struct TreatmentDoseSheet: View {
    @ObservedObject var store: BaselineStore
    @EnvironmentObject var repo: Repository
    var defaultDay: String
    @State private var dose = ""
    @State private var day = Date()
    @State private var time = Date()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Dose") {
                        TextField("Optional", text: $dose)
                            .multilineTextAlignment(.trailing)
                    }
                    DatePicker("Day", selection: $day, displayedComponents: .date)
                    DatePicker("Clock time", selection: $time, displayedComponents: .hourAndMinute)
                }
                .eventEditorRow()
            }
            .eventEditorForm()
            .navigationTitle("Log dose")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.showDoseForm = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let stamp = TreatmentStamp.split(day: day, time: time)
                        store.logDose(civilDay: stamp.day, clockTime: stamp.clock,
                                      dose: dose.isEmpty ? nil : dose,
                                      days: store.displayDays(from: repo.days))
                    }
                }
            }
            .onAppear {
                day = TreatmentStamp.date(fromISO: defaultDay.isEmpty ? store.asOf : defaultDay) ?? Date()
            }
        }
        #if os(macOS)
        .frame(minWidth: NoopMetrics.editorSheetMinWidth, minHeight: NoopMetrics.editorSheetMinHeight)
        #endif
    }
}

struct TreatmentEndSheet: View {
    @ObservedObject var store: BaselineStore
    @EnvironmentObject var repo: Repository
    var defaultDay: String
    @State private var day = Date()
    @State private var time = Date()
    @State private var reason: LBStopReason = .completed
    @State private var washoutDays = 7
    @State private var lastDoseDay = Date()
    @State private var lastDoseTime = Date()
    @State private var useLastDose = false
    @State private var patientClear = false
    @State private var stillFeeling = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("End day", selection: $day, displayedComponents: .date)
                    DatePicker("Clock time", selection: $time, displayedComponents: .hourAndMinute)
                    Picker("Reason", selection: $reason) {
                        ForEach(LBStopReason.allCases, id: \.self) { r in
                            Text(TreatmentCaregiverView.reasonLabel(r)).tag(r)
                        }
                    }
                }
                .eventEditorRow()
                Section {
                    Toggle("Last dose time is later than this end", isOn: $useLastDose)
                        .tint(StrandPalette.accent)
                    if useLastDose {
                        DatePicker("Last dose day", selection: $lastDoseDay, displayedComponents: .date)
                        DatePicker("Last dose clock", selection: $lastDoseTime, displayedComponents: .hourAndMinute)
                    }
                }
                .eventEditorRow()
                Section {
                    Stepper(value: $washoutDays, in: 1...60) {
                        Text("Expected washout: \(washoutDays) days")
                    }
                    Toggle("I already feel it’s out of my system", isOn: $patientClear)
                        .tint(StrandPalette.accent)
                    Toggle("Still feeling effects", isOn: $stillFeeling)
                        .tint(StrandPalette.accent)
                } footer: {
                    Text("Used only to label Settling in and Washing out.")
                }
                .eventEditorRow()
            }
            .eventEditorForm()
            .navigationTitle("End treatment")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.showEndForm = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let stamp = TreatmentStamp.split(day: day, time: time)
                        store.logEnd(civilDay: stamp.day, clockTime: stamp.clock,
                                     reason: reason, days: store.displayDays(from: repo.days),
                                     washoutDays: washoutDays,
                                     lastDoseDay: useLastDose ? TreatmentStamp.split(day: lastDoseDay, time: lastDoseTime).day : nil,
                                     lastDoseClock: useLastDose ? TreatmentStamp.split(day: lastDoseDay, time: lastDoseTime).clock : nil,
                                     patientSaysClear: patientClear,
                                     patientStillFeeling: stillFeeling && !patientClear)
                    }
                }
            }
            .onAppear {
                day = TreatmentStamp.date(fromISO: defaultDay.isEmpty ? store.asOf : defaultDay) ?? Date()
            }
        }
        #if os(macOS)
        .frame(minWidth: 360, minHeight: 280)
        #endif
    }
}

enum TreatmentStamp {
    static func date(fromISO day: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: day)
    }

    static func iso(from date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    static func time(fromClock clock: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "HH:mm"
        return f.date(from: clock)
    }

    static func split(day: Date, time: Date) -> (day: String, clock: String) {
        let cal = Calendar.current
        let d = cal.dateComponents([.year, .month, .day], from: day)
        let t = cal.dateComponents([.hour, .minute], from: time)
        var merged = DateComponents()
        merged.year = d.year
        merged.month = d.month
        merged.day = d.day
        merged.hour = t.hour
        merged.minute = t.minute
        let date = cal.date(from: merged) ?? day
        let clock: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = .current
            f.dateFormat = "HH:mm"
            return f.string(from: date)
        }()
        return (iso(from: date), clock)
    }

    static func monthTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = .current
        f.setLocalizedDateFormatFromTemplate("MMMMyyyy")
        return f.string(from: date)
    }
}

import SwiftUI
import StrandDesign
import StrandAnalytics
import WhoopStore

/// Caregiver tab: add / edit / calendar-log treatments. Shares `BaselineStore` with Baseline.
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

    private var days: [DailyMetric] { store.displayDays(from: repo.days) }

    var body: some View {
        ScreenScaffold(
            title: "Treatment",
            subtitle: "Log a start to freeze non-treatment usual. Baseline reads this course.",
            onRefresh: { await repo.refresh(); store.rescore(days: days) },
            topBackground: liquidScaffoldSky()
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
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
                Text("Events stay on this device. Open any past day to edit it.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
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
    }

    private var calendarCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Button { shiftMonth(-1) } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                    Spacer()
                    Text(TreatmentStamp.monthTitle(month))
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Button { shiftMonth(1) } label: {
                        Image(systemName: "chevron.right")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }
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
            baselineBridge
            addForm
            if store.activeStart != nil {
                activeCourseRow
                watchListCard
            }
            logCard
        }
    }

    private var baselineBridge: some View {
        NoopCard {
            Button { router.openBaseline() } label: {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "rectangle.split.2x1")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 22)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Baseline")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Read this course’s usuals, TRUST, and nights outside range.")
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Text("Open")
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.accent)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .accessibilityHidden(true)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open Baseline")
        }
    }

    private var addForm: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Start a treatment")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Nights before this clock time freeze the expected path without treatment. You can add another course after one has ended.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                TextField("Treatment name", text: $formName)
                    .textFieldStyle(.roundedBorder)
                Picker("Kind", selection: $formKind) {
                    ForEach(LBTreatmentKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue.replacingOccurrences(of: "_", with: " ")).tag(kind)
                    }
                }
                TextField("Dose (optional)", text: $formDose)
                    .textFieldStyle(.roundedBorder)
                Picker("How you take it", selection: $formSchedule) {
                    ForEach(LBMedSchedule.allCases, id: \.self) { sched in
                        Text(sched.displayLabel).tag(sched)
                    }
                }
                DatePicker("Start day", selection: $formDay, displayedComponents: .date)
                DatePicker("Clock time", selection: $formTime, displayedComponents: .hourAndMinute)
                VStack(alignment: .leading, spacing: 6) {
                    Text("When I expect it to start working")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Stepper(value: $formOnset, in: 1...60) {
                        Text("\(formOnset) days")
                            .font(StrandFont.captionNumber)
                            .monospacedDigit()
                    }
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("If I stop, how long until I expect it out of my system")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Stepper(value: $formWashout, in: 1...60) {
                        Text("\(formWashout) days")
                            .font(StrandFont.captionNumber)
                            .monospacedDigit()
                    }
                }
                TextField("Notes from clinic / label (optional)", text: $formNotes)
                    .textFieldStyle(.roundedBorder)
                Text("What to watch (optional)")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                Text("You don’t need to know which biometric matters. Leave this blank and we’ll watch the three series with the most solid usuals at the start — ranked by how complete and stable the tape is, not by how much they moved after the drug.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                primaryPicker
                NoopButton("Start treatment and freeze usual", systemImage: "plus") {
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
                .disabled(formName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private var primaryPicker: some View {
        let options = store.displayedSeries
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(options, id: \.rawValue) { s in
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
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer()
                        Image(systemName: on ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(on ? StrandPalette.accent : StrandPalette.textTertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var watchListCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("Watch list")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Ranked by how solid the usual is today (TRUST and nights), not by who moved after the start. Pin up to three. Unpinned series stay on Baseline as exploratory.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                ForEach(store.watchCandidates) { row in
                    Button {
                        store.toggleWatch(row.series, days: days)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: row.pinned ? "pin.fill" : "pin")
                                .foregroundStyle(row.pinned ? StrandPalette.accent : StrandPalette.textTertiary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(store.shortTitle(for: row.series))
                                    .font(StrandFont.subhead)
                                    .foregroundStyle(StrandPalette.textPrimary)
                                Text(row.established
                                     ? "Usual established · TRUST \(row.trust)%"
                                     : "Still building · TRUST \(row.trust)%")
                                    .font(StrandFont.caption)
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            Spacer()
                            if row.pinned {
                                Text("WATCHING")
                                    .font(StrandFont.caption.weight(.semibold))
                                    .foregroundStyle(StrandPalette.accent)
                                    .tracking(0.6)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(!row.pinned && (store.activeStart?.primarySeries.count ?? 0) >= 3)
                }
            }
        }
    }

    private var activeCourseRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                activeCourseTitle
                Spacer(minLength: 8)
                activeCourseActions
            }
            VStack(alignment: .leading, spacing: 8) {
                activeCourseTitle
                activeCourseActions
            }
        }
        .font(StrandFont.body)
    }

    @ViewBuilder private var activeCourseTitle: some View {
        if let start = store.activeStart {
            Text("Open course · \(start.bannerName)")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var activeCourseActions: some View {
        HStack(spacing: 16) {
            Button("Log dose") { store.showDoseForm = true }
                .foregroundStyle(StrandPalette.accent)
            Button("End course") { store.showEndForm = true }
                .foregroundStyle(StrandPalette.statusWarning)
        }
    }

    private var logCard: some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Log")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .padding(.horizontal, NoopMetrics.cardInnerSpacing)
                    .padding(.top, NoopMetrics.cardInnerSpacing)
                    .padding(.bottom, 8)
                if store.events.isEmpty {
                    Text("Nothing logged yet.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.horizontal, NoopMetrics.cardInnerSpacing)
                        .padding(.bottom, NoopMetrics.cardInnerSpacing)
                } else {
                    let rows = store.events.enumerated().sorted {
                        ($0.element.civilDay, $0.element.clockTime) < ($1.element.civilDay, $1.element.clockTime)
                    }
                    ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, pair in
                        eventRow(pair.element, index: pair.offset, showDivider: rowIdx < rows.count - 1)
                    }
                }
            }
        }
    }

    private func eventRow(_ event: LBTreatmentEvent, index: Int, showDivider: Bool = false) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 10) {
                Text(Self.typeLabel(event.type))
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(StrandPalette.surfaceInset, in: Capsule())
                VStack(alignment: .leading, spacing: 2) {
                    Text(event.bannerName)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text("\(BaselinePlotScale.mediumDate(event.civilDay)) · \(event.clockTime)")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .monospacedDigit()
                }
                Spacer()
                Button("Edit") { store.beginEdit(index: index) }
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.accent)
            }
            .padding(.horizontal, NoopMetrics.cardInnerSpacing)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onTapGesture {
                selectedDay = event.civilDay
                if let date = TreatmentStamp.date(fromISO: event.civilDay) {
                    month = date
                    formDay = date
                }
            }
            if showDivider {
                Rectangle()
                    .fill(StrandPalette.hairline)
                    .frame(height: 1)
                    .padding(.leading, NoopMetrics.cardInnerSpacing)
            }
        }
    }

    private static func typeLabel(_ type: LBTreatmentEventType) -> String {
        switch type {
        case .start: return "Start"
        case .dose: return "Dose"
        case .doseChange: return "Dose change"
        case .stop: return "Ended"
        case .interruption: return "Pause"
        case .restart: return "Restart"
        }
    }

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
                ForEach(Array(["S", "M", "T", "W", "T", "F", "S"].enumerated()), id: \.offset) { _, w in
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
                                .frame(maxWidth: .infinity, minHeight: 28)
                                .background(cellFill(day), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                                .foregroundStyle(day == selectedDay ? StrandPalette.textPrimary : StrandPalette.textSecondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Color.clear.frame(minHeight: 28)
                    }
                }
            }
        }
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

    var body: some View {
        NavigationStack {
            Form {
                if store.events.indices.contains(index) {
                    Text(store.events[index].type.rawValue)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
                TextField("Treatment name", text: $name)
                Picker("Kind", selection: $kind) {
                    ForEach(LBTreatmentKind.allCases, id: \.self) { k in
                        Text(k.rawValue.replacingOccurrences(of: "_", with: " ")).tag(k)
                    }
                }
                TextField("Dose (optional)", text: $dose)
                DatePicker("Day", selection: $day, displayedComponents: .date)
                DatePicker("Clock time", selection: $time, displayedComponents: .hourAndMinute)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Edit treatment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.editingEventIndex = nil }
                }
                ToolbarItem(placement: .destructiveAction) {
                    Button("Delete") {
                        store.deleteEvent(at: index, days: store.displayDays(from: repo.days))
                    }
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
                TextField("Dose (optional)", text: $dose)
                DatePicker("Day", selection: $day, displayedComponents: .date)
                DatePicker("Clock time", selection: $time, displayedComponents: .hourAndMinute)
                Text("A dose stays on the same course. It does not start a new freeze.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("Log dose")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.showDoseForm = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Log dose") {
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
                DatePicker("End day", selection: $day, displayedComponents: .date)
                DatePicker("Clock time", selection: $time, displayedComponents: .hourAndMinute)
                Picker("Reason", selection: $reason) {
                    ForEach(LBStopReason.allCases, id: \.self) { r in
                        Text(r.rawValue.replacingOccurrences(of: "_", with: " ")).tag(r)
                    }
                }
                Toggle("Last dose time is later than this end", isOn: $useLastDose)
                if useLastDose {
                    DatePicker("Last dose day", selection: $lastDoseDay, displayedComponents: .date)
                    DatePicker("Last dose clock", selection: $lastDoseTime, displayedComponents: .hourAndMinute)
                }
                HStack {
                    Text("I expect washout to take (days)")
                    Spacer()
                    Stepper("\(washoutDays)", value: $washoutDays, in: 1...60)
                }
                Toggle("I already feel it’s out of my system", isOn: $patientClear)
                Toggle("Still feeling effects", isOn: $stillFeeling)
                Text("These clocks label Settling in / Washing out. They do not change the expected path or z.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
            }
            .scrollContentBackground(.hidden)
            .navigationTitle("End treatment")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { store.showEndForm = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("End treatment") {
                        let stamp = TreatmentStamp.split(day: day, time: time)
                        store.logEnd(civilDay: stamp.day, clockTime: stamp.clock,
                                     reason: reason, days: store.displayDays(from: repo.days),
                                     washoutDays: washoutDays,
                                     lastDoseDay: useLastDose ? TreatmentStamp.split(day: lastDoseDay, time: lastDoseTime).day : nil,
                                     lastDoseClock: useLastDose ? TreatmentStamp.split(day: lastDoseDay, time: lastDoseTime).clock : nil,
                                     patientSaysClear: patientClear,
                                     patientStillFeeling: stillFeeling && !patientClear)
                    }
                    .foregroundStyle(StrandPalette.statusWarning)
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

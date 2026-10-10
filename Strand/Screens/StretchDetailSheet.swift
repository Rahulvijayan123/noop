import SwiftUI
import Charts
import StrandDesign
import StrandAnalytics

// MARK: - A stretch up close, and the wearer's verdict on it
//
// Opened by tapping a stretch on the Heart rate page. It shows what the strap recorded
// inside the stretch at a finer grain than the page does (heart rate, wrist motion and steps in short slices),
// what the model based its label on, and asks whether the label is right. The answer is saved on the phone at
// once and sent to the server with the model's reading, so labelled stretches can be used to tune the model.

/// A stretch to open, plus the other source's reading over the same time.
struct StretchSheetInput: Identifiable {
    let target: StretchTarget
    /// ActivityContext runs that overlap the stretch.
    let runs: [ActivityContextRun]
    /// Strap-derived segments that overlap the stretch.
    let segments: [DayStateSegment]

    var id: String { target.id }

    init(target: StretchTarget, document: ActivityContextDayDocument?, segments allSegments: [DayStateSegment]) {
        self.target = target
        self.runs = (document?.runs ?? []).filter { $0.end > target.start && $0.start < target.end }
        self.segments = allSegments.filter { $0.end > target.start && $0.start < target.end }
    }

    /// How far to widen the heart rate graph around the stretch so it is seen in context.
    var zoomRange: ClosedRange<Date> {
        let from = Date(timeIntervalSince1970: TimeInterval(target.start))
        let to = Date(timeIntervalSince1970: TimeInterval(target.end))
        let dur = Double(target.durationSeconds)
        let pad: TimeInterval = dur < 600 ? max(90, dur * 2) : dur * 0.15
        return from.addingTimeInterval(-pad)...to.addingTimeInterval(pad)
    }
}

extension StretchTarget {
    /// How the stretch is drawn: the same colour, symbol and wording its list uses.
    var presentation: (title: String, symbol: String, color: Color) {
        switch self {
        case .activity(let e):
            let family = ActivityFamily.of(e.label)
            return (e.label, family.symbol, family.color)
        case .strap(let s):
            return (s.state.title, s.state.symbol, s.state.color)
        }
    }
}

// MARK: Verdict badge (shared with the two lists)

struct StretchVerdictBadge: View {
    let feedback: StretchFeedback?

    var body: some View {
        if let feedback {
            let right = feedback.verdict == .correct
            StatePill("\(text(for: feedback, right: right))", tone: right ? .positive : .warning, showsDot: false)
                .fixedSize()
        }
    }

    private func text(for feedback: StretchFeedback, right: Bool) -> String {
        if right { return String(localized: "You said right") }
        if let c = feedback.correctedLabel { return String(localized: "You said \(c.title)") }
        return String(localized: "You said wrong")
    }
}

// MARK: Sheet

struct StretchDetailSheet: View {
    let input: StretchSheetInput
    let deviceId: String
    let onZoom: (ClosedRange<Date>) -> Void

    @EnvironmentObject private var repo: Repository
    @ObservedObject private var feedback = StretchFeedbackCenter.shared
    @Environment(\.dismiss) private var dismiss

    private enum Load { case loading, ready(StretchDetail), failed }
    @State private var load: Load = .loading

    @State private var verdict: StretchVerdict?
    @State private var correction: StretchCorrection?
    @State private var note = ""
    @State private var primed = false

    private enum Anchor: Hashable { case model, validation }

    #if DEBUG
    // Simulator screenshots cannot scroll the sheet from outside the app: `--demo-sheet-scroll=model|validation`.
    private static var demoAnchor: Anchor? {
        let prefix = "--demo-sheet-scroll="
        guard let arg = CommandLine.arguments.first(where: { $0.hasPrefix(prefix) }) else { return nil }
        switch arg.dropFirst(prefix.count) {
        case "model": return .model
        case "validation": return .validation
        default: return nil
        }
    }
    #endif

    private var target: StretchTarget { input.target }
    private var stored: StretchFeedback? {
        feedback.feedback(kind: target.kind, start: target.start, end: target.end)
    }

    @State private var hrSelection: Date?

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                        signals
                        validationCard.id(Anchor.validation)
                        howItWasRead.id(Anchor.model)
                    }
                    .padding(.horizontal, NoopMetrics.screenHPadding)
                    .padding(.vertical, NoopMetrics.space4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                #if DEBUG
                .task(id: Self.demoAnchor) {
                    guard let anchor = Self.demoAnchor else { return }
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    proxy.scrollTo(anchor, anchor: .top)
                }
                #endif
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text(target.presentation.title))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { finish() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
        .task { await loadDetail() }
        .onAppear(perform: primeFromStored)
        .onDisappear { persistIfNoteChanged() }
    }

    /// "2:14 PM – 2:31 PM · 17 min".
    private var spanLine: String {
        let from = Date(timeIntervalSince1970: TimeInterval(target.start))
        let to = Date(timeIntervalSince1970: TimeInterval(target.end))
        let seconds = target.durationSeconds < 300
        return "\(StretchFormat.clock(from, seconds: seconds)) – \(StretchFormat.clock(to, seconds: seconds)) · \(StretchFormat.duration(target.durationSeconds))"
    }

    // MARK: What the strap recorded

    private var detail: StretchDetail? {
        if case .ready(let d) = load { return d }
        return nil
    }

    /// The readout (the stretch's average, or the slice under the finger), the heart-rate slices with their
    /// low-to-high range, wrist movement and the step counter on the same time axis, and the figures.
    /// Every frame is drawn at its final size while the stretch is read.
    @ViewBuilder
    private var signals: some View {
        let d = detail
        let isLoading: Bool = { if case .loading = load { return true }; return false }()
        let hrSamples = d.map(Self.hrSamples) ?? []
        ValueReadout(hrReadout(d, samples: hrSamples), isScrubbing: hrSelection != nil, isLoading: isLoading)
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if let d {
                    StretchSignalChart(detail: d, kind: .heartRate, selection: $hrSelection)
                    if d.bins.contains(where: { $0.motionG != nil }) {
                        StretchSignalChart(detail: d, kind: .wristMovement, selection: $hrSelection)
                    }
                    if (d.stepTicks ?? 0) > 0 {
                        StretchSignalChart(detail: d, kind: .stepTicks, selection: $hrSelection)
                    }
                } else {
                    Text(isLoading ? String(localized: "Reading the strap's stored data…") : emptyText)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .leading)
                }
            }
        }
        StatGrid(stats(d), columns: 2, isLoading: isLoading)
    }

    private var emptyText: String {
        if case .failed = load { return String(localized: "This stretch could not be read from the strap's stored data.") }
        return String(localized: "The strap recorded nothing in this stretch.")
    }

    private func window(_ d: StretchDetail?) -> ClosedRange<Date> {
        let start = d?.start ?? target.start, end = d?.end ?? target.end
        return Date(timeIntervalSince1970: TimeInterval(start))...Date(timeIntervalSince1970: TimeInterval(max(end, start + 1)))
    }

    /// One sample per slice at its middle: the slice's average with its lowest and highest as the envelope.
    /// A slice with no heart rate is left out, so the line breaks across it.
    static func hrSamples(_ d: StretchDetail) -> [IntradayChart.Sample] {
        d.bins.compactMap { b in
            guard let avg = b.avgHr else { return nil }
            return IntradayChart.Sample(time: Date(timeIntervalSince1970: TimeInterval(b.start) + Double(b.durationSeconds) / 2),
                                        value: Double(avg), low: b.minHr.map(Double.init), high: b.maxHr.map(Double.init))
        }
    }

    private func hrReadout(_ d: StretchDetail?, samples: [IntradayChart.Sample]) -> ReadoutContent {
        if let hrSelection, let s = ChartSelection.sample(for: hrSelection, in: samples) {
            let range = s.low.flatMap { lo in s.high.map { "\(Int(lo))–\(Int($0)) bpm" } }
            return .intraday(s, unit: "bpm", format: { "\(Int($0.rounded()))" }, context: range)
        }
        return ReadoutContent(dateLine: spanLine, value: d?.avgHr.map { "\($0)" }, unit: "bpm",
                              context: d.flatMap { d in d.minHr.flatMap { lo in d.maxHr.map { "\(lo)–\($0) bpm" } } })
    }

    private func stats(_ d: StretchDetail?) -> [StatItem] {
        var items: [StatItem] = []
        let mean = d?.meanMotionG
        items.append(StatItem(String(localized: "Wrist movement"), value: mean.map { String(format: "%.2f", $0) },
                              unit: "g",
                              detail: d?.peakMotionG.map { String(localized: "Peak \(String(format: "%.2f", $0)) g") }))
        let ticks = d?.stepTicks
        items.append(StatItem(String(localized: "Step counter"), value: ticks.map { "\($0)" },
                              detail: ticks.map { t in
                                  t == 0 ? String(localized: "No steps counted")
                                         : String(localized: "About \(String(format: "%.1f", Double(t) / Double(max(1, d?.durationSeconds ?? 1)))) a second")
                              }))
        items.append(StatItem(String(localized: "Heart rate coverage"),
                              value: d.map { "\(Int(($0.hrCoverage * 100).rounded()))" }, unit: "%",
                              detail: String(localized: "of the seconds")))
        items.append(StatItem(String(localized: "Slice"), value: d.map { StretchFormat.duration($0.binSeconds) }))
        return items
    }

    // MARK: How this was read

    /// The model's reasoning, one tap down: what it based the label on, the strap's own reading of the same
    /// time, the runs inside the stretch, and how the answer is used.
    private var howItWasRead: some View {
        AboutDisclosure("How this was read", initiallyExpanded: isDemoModelAnchor) {
            ForEach(StretchNarrative.paragraphs(narrativeInput())) { paragraph in
                VStack(alignment: .leading, spacing: 4) {
                    Text(paragraph.title)
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                    Text(paragraph.text)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let experts = expertsSummary {
                ActivityExpertsBlock(summary: experts)
            }
            Text(target.kind == .activityContext
                 ? String(localized: "Read by the activity model")
                 : String(localized: "Worked out from the strap's own signals"))
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
            Text("Your answer is saved with this stretch and what the model saw, and helps tune it.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// The evidence the activity model used over an activity stretch; nil for a strap stretch (its label is not the
    /// model's) and when no run inside it recorded any.
    private var expertsSummary: ActivityExpertsSummary? {
        guard case .activity(let e) = target else { return nil }
        let summary = ActivityExpertsSummary.over(start: e.start, end: e.end, runs: input.runs)
        return summary.hasContent ? summary : nil
    }

    /// The facts the written reading is built from: the model's answers, what the strap recorded, the evidence
    /// used and what the other source said over the same time.
    private func narrativeInput() -> StretchNarrative.Input {
        let d = detail
        func choices(_ rows: [(name: String, p: Double)]) -> [StretchNarrative.Choice] {
            rows.map { StretchNarrative.Choice(name: $0.name, p: $0.p) }
        }
        func other(source: String, _ lines: [StretchModelContext.Overlap]) -> StretchNarrative.Other? {
            lines.isEmpty ? nil : StretchNarrative.Other(source: source, labels: lines.map { ($0.label, $0.seconds) })
        }
        switch target {
        case .activity(let e):
            let experts = ActivityExpertsSummary.over(start: e.start, end: e.end, runs: input.runs)
            var i = StretchNarrative.Input(label: e.label, confidence: e.confidence,
                                           durationSeconds: d?.durationSeconds ?? target.durationSeconds)
            i.posture = choices(HeadBlock.rows(e.posture, name: \.displayName))
            i.movement = choices(HeadBlock.rows(e.locomotion, name: \.displayName))
            i.arm = choices(HeadBlock.rows(e.armBehavior, name: \.displayName))
            i.experts = experts.experts.map(ActivityExpertsSummary.name)
            i.specific = experts.detail.map(ActivityExpertsSummary.name)
            i.gaitProbability = experts.gait?.probability
            i.gaitCadence = experts.gait?.cadenceSpm
            i.gaitSpeed = experts.gait?.speedMps
            i.runCount = input.runs.count
            i.other = other(source: String(localized: "the strap's own labels"),
                            StretchOverlap.strapStates(over: e.start, e.end, segments: input.segments))
            fill(&i, from: d)
            return i
        case .strap(let s):
            let experts = ActivityExpertsSummary.over(start: s.start, end: s.end, runs: input.runs)
            var i = StretchNarrative.Input(label: s.state.title, confidence: nil,
                                           durationSeconds: d?.durationSeconds ?? s.durationSeconds)
            i.strapBasis = s.basisText
            i.strapDetail = s.state.detail
            i.avgHr = s.avgHr; i.minHr = s.minHr; i.maxHr = s.maxHr
            i.meanMotionG = s.motionG
            i.stepTicks = s.stepTicks
            i.experts = experts.experts.map(ActivityExpertsSummary.name)
            i.specific = experts.detail.map(ActivityExpertsSummary.name)
            i.gaitProbability = experts.gait?.probability
            i.gaitCadence = experts.gait?.cadenceSpm
            i.gaitSpeed = experts.gait?.speedMps
            i.other = other(source: String(localized: "the activity model"),
                            StretchOverlap.activityLabels(over: s.start, s.end, runs: input.runs))
            fill(&i, from: d)
            return i
        }
    }

    /// The finer readings of the loaded stretch win over the summary the list carried.
    private func fill(_ i: inout StretchNarrative.Input, from d: StretchDetail?) {
        guard let d else { return }
        i.avgHr = d.avgHr ?? i.avgHr; i.minHr = d.minHr ?? i.minHr; i.maxHr = d.maxHr ?? i.maxHr
        i.meanMotionG = d.meanMotionG ?? i.meanMotionG
        i.peakMotionG = d.peakMotionG
        i.stepTicks = d.stepTicks ?? i.stepTicks
    }

    private var isDemoModelAnchor: Bool {
        #if DEBUG
        return Self.demoAnchor == .model
        #else
        return false
        #endif
    }

    // MARK: Verdict

    private var validationCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("Is this right?")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)

                HStack(spacing: NoopMetrics.space2) {
                    verdictButton(.correct, title: "Yes, that's right", symbol: "checkmark")
                    verdictButton(.incorrect, title: "No, it was wrong", symbol: "xmark")
                }

                if verdict == .incorrect {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        Text("What was it?").strandLabel()
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: NoopMetrics.space2, alignment: .leading)],
                                  alignment: .leading, spacing: NoopMetrics.space2) {
                            ForEach(StretchCorrection.allCases, id: \.self) { c in
                                correctionChip(c)
                            }
                        }
                    }
                }

                if verdict != nil {
                    VStack(alignment: .leading, spacing: NoopMetrics.space2) {
                        TextField("Add a note (optional)", text: $note, axis: .vertical)
                            .lineLimit(1...4)
                            .font(StrandFont.body)
                            .textFieldStyle(.plain)
                            .padding(NoopMetrics.space3)
                            .background(NoopInsetSurface())
                        if noteIsDirty {
                            NoopButton("Save note", kind: .secondary, fullWidth: true) { persist() }
                        }
                        saveStatus
                    }
                }
            }
        }
    }

    /// The selected answer is the filled (primary) button; the other stays secondary.
    private func verdictButton(_ value: StretchVerdict, title: LocalizedStringKey, symbol: String) -> some View {
        let selected = verdict == value
        return Button {
            withAnimation(StrandMotion.interactive) {
                verdict = value
                if value == .correct { correction = nil }
            }
            persist()
        } label: {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(NoopButtonStyle(selected ? .primary : .secondary, fullWidth: true))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func correctionChip(_ c: StretchCorrection) -> some View {
        let selected = correction == c
        return Button {
            withAnimation(StrandMotion.interactive) { correction = selected ? nil : c }
            persist()
        } label: {
            Text(c.title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(NoopButtonStyle(selected ? .primary : .secondary, fullWidth: true))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private var saveStatus: some View {
        if let stored {
            let line = StretchFeedbackStatusLine(feedback.standing(of: stored))
            HStack(spacing: 6) {
                Image(systemName: line.symbol)
                Text(line.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .font(StrandFont.footnote)
            .foregroundStyle(line.needsAttention ? StrandPalette.statusWarning : StrandPalette.textTertiary)
        }
    }

    // MARK: Saving

    private var noteIsDirty: Bool {
        guard verdict != nil else { return false }
        let saved = stored?.note ?? ""
        return note.trimmingCharacters(in: .whitespacesAndNewlines) != saved
    }

    private func primeFromStored() {
        guard !primed else { return }
        primed = true
        if let stored {
            verdict = stored.verdict
            correction = stored.correctedLabel
            note = stored.note ?? ""
        }
        #if DEBUG
        if stored == nil, CommandLine.arguments.contains("--demo-verdict") {
            verdict = .incorrect
            correction = .walking
            note = "I was making tea."
            persist()
        }
        #endif
    }

    private func finish() {
        persistIfNoteChanged()
        dismiss()
    }

    private func persistIfNoteChanged() {
        if noteIsDirty { persist() }
    }

    /// Save the verdict as it stands now. Called on every answer, so closing the sheet never loses one.
    private func persist() {
        guard let verdict else { return }
        let existing = stored
        let overlap: [StretchModelContext.Overlap]
        switch target {
        case .activity(let e): overlap = StretchOverlap.strapStates(over: e.start, e.end, segments: input.segments)
        case .strap(let s): overlap = StretchOverlap.activityLabels(over: s.start, s.end, runs: input.runs)
        }
        let info = Bundle.main.infoDictionary
        var record = StretchFeedback(
            kind: target.kind, startTs: target.start, endTs: target.end, deviceId: deviceId,
            predictedLabel: target.predictedLabel, predictedClass: target.predictedClass,
            predictedConfidence: target.predictedConfidence,
            verdict: verdict, correctedLabel: correction, note: note,
            context: target.modelContext(overlapping: overlap, runCount: input.runs.count),
            appVersion: info?["CFBundleShortVersionString"] as? String,
            appBuild: info?["CFBundleVersion"] as? String,
            tzOffsetS: TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(target.start))))
        if let existing {
            guard existing.verdict != record.verdict || existing.correctedLabel != record.correctedLabel
                    || existing.note != record.note else { return }
            record = record.continuing(existing)
        }
        feedback.save(record)
    }

    // MARK: Reading

    private func loadDetail() async {
        let start = target.start, end = target.end
        guard let signals = await repo.stretchSignals(from: start, to: end) else {
            load = .failed
            return
        }
        let built = await Task.detached(priority: .userInitiated) {
            StretchDetailBuilder.build(start: start, end: end, hr: signals.hr,
                                       gravity: signals.gravity, steps: signals.steps)
        }.value
        load = .ready(built)
    }
}

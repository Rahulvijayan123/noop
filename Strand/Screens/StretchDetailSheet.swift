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
    @State private var showAllRuns = false

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
                        zoomButton
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
            IntradayChart(samples: hrSamples, bucketSeconds: max(1, d?.binSeconds ?? 30), legend: [],
                          state: isLoading ? .loading
                            : (hrSamples.isEmpty ? .empty(emptyText) : .ready),
                          window: window(d),
                          y: ChartValueAxis(unit: "bpm", domain: .fitted(minSpan: 20)),
                          selection: $hrSelection, height: NoopMetrics.chartHeightSecondary,
                          accessibilityTitle: String(localized: "Heart rate over the stretch"))
        }
        if let d, d.bins.contains(where: { $0.motionG != nil }) || (d.stepTicks ?? 0) > 0 {
            NoopCard {
                VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                    if d.bins.contains(where: { $0.motionG != nil }) {
                        Text("Wrist movement").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        SliceBars(detail: d, tint: StrandPalette.metricCyan, unit: "g", decimals: 2,
                                  selection: $hrSelection) { $0.motionG }
                    }
                    if (d.stepTicks ?? 0) > 0 {
                        Text("Step counter ticks").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        SliceBars(detail: d, tint: StrandPalette.metricPurple, unit: nil, decimals: 0,
                                  selection: $hrSelection) { $0.stepTicks.map(Double.init) }
                    }
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
            modelCard
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

    private var isDemoModelAnchor: Bool {
        #if DEBUG
        return Self.demoAnchor == .model
        #else
        return false
        #endif
    }

    // MARK: What the model said

    @ViewBuilder
    private var modelCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            switch target {
            case .activity(let e): activityModel(e)
            case .strap(let s): strapModel(s)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func activityModel(_ e: ActivityEpisode) -> some View {
        let tint = ActivityFamily.of(e.label).color
        HStack(spacing: 10) {
            Text("Confidence")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            if e.confidence < 0.55 {
                StatePill("Low confidence", tone: .warning, showsDot: false).fixedSize()
            }
            Spacer(minLength: 8)
            ProbabilityBar(value: e.confidence, tint: tint)
            Text("\(Int((e.confidence * 100).rounded()))%")
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
                .frame(width: 44, alignment: .trailing)
        }
        HeadBlock(title: String(localized: "Posture"), rows: HeadBlock.rows(e.posture, name: \.displayName), tint: tint)
        HeadBlock(title: String(localized: "Movement"), rows: HeadBlock.rows(e.locomotion, name: \.displayName), tint: tint)
        HeadBlock(title: String(localized: "Arm"), rows: HeadBlock.rows(e.armBehavior, name: \.displayName), tint: tint)
        ActivityExpertsBlock(summary: .over(start: e.start, end: e.end, runs: input.runs))
        let strap = StretchOverlap.strapStates(over: e.start, e.end, segments: input.segments)
        if !strap.isEmpty {
            Divider().opacity(0.4)
            overlapLines(title: String(localized: "The strap's own labels over this time"), strap)
        }
        if input.runs.count > 1 { runList }
    }

    @ViewBuilder
    private func strapModel(_ s: DayStateSegment) -> some View {
        Text(s.basisText)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        if let detail = s.state.detail {
            Text(detail)
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        let model = StretchOverlap.activityLabels(over: s.start, s.end, runs: input.runs)
        if !model.isEmpty {
            Divider().opacity(0.4)
            overlapLines(title: String(localized: "The activity model read this time as"), model)
        }
        ActivityExpertsBlock(summary: .over(start: s.start, end: s.end, runs: input.runs))
    }

    private func overlapLines(title: String, _ lines: [StretchModelContext.Overlap]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack {
                    Text(line.label)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer(minLength: 8)
                    Text(StretchFormat.duration(line.seconds))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .monospacedDigit()
                }
            }
        }
    }

    /// The model's reading inside the stretch, a few minutes at a time, for a stretch that is more than one run.
    private var runList: some View {
        let ordered = input.runs.sorted { $0.start > $1.start }
        let visible = showAllRuns ? ordered : Array(ordered.prefix(6))
        return VStack(alignment: .leading, spacing: 6) {
            Divider().opacity(0.4)
            Text("Inside this stretch")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
            ForEach(Array(visible.enumerated()), id: \.offset) { _, run in
                let from = Date(timeIntervalSince1970: TimeInterval(max(run.start, target.start)))
                let to = Date(timeIntervalSince1970: TimeInterval(min(run.end, target.end)))
                HStack {
                    Text("\(StretchFormat.clock(from, seconds: true)) – \(StretchFormat.clock(to, seconds: true))")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .monospacedDigit()
                    Spacer(minLength: 8)
                    Text(run.displayContext ?? ActivityContextEpisodes.unclear)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Text("\(Int((run.overallConfidence * 100).rounded()))%")
                        .font(StrandFont.footnote.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                        .frame(width: 40, alignment: .trailing)
                }
            }
            if ordered.count > 6 {
                Button {
                    withAnimation(StrandMotion.interactive) { showAllRuns.toggle() }
                } label: {
                    Text(showAllRuns ? String(localized: "Show fewer") : String(localized: "Show all \(ordered.count)"))
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }
        }
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
            Label(title, systemImage: symbol)
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

    private var zoomButton: some View {
        NoopButton("Show on the heart rate graph", systemImage: "magnifyingglass", kind: .secondary, fullWidth: true) {
            onZoom(input.zoomRange)
            dismiss()
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

// MARK: Pieces

/// One value per slice as a bar spanning the slice, on the stretch's clock axis with the unit on the value
/// axis. The selection is shared with the heart-rate chart above, so one scrub reads all three.
private struct SliceBars: View {
    let detail: StretchDetail
    let tint: Color
    let unit: String?
    let decimals: Int
    @Binding var selection: Date?
    let value: (StretchBin) -> Double?

    var body: some View {
        let bars = detail.bins.compactMap { b -> (id: Int, from: Date, to: Date, mid: Date, v: Double)? in
            value(b).map { (b.start, Self.date(b.start), Self.date(b.end),
                            Date(timeIntervalSince1970: TimeInterval(b.start) + Double(b.durationSeconds) / 2), $0) }
        }
        let window = Self.date(detail.start)...Self.date(max(detail.end, detail.start + 1))
        let axis = ChartValueAxis(unit: unit, domain: .fitted(minSpan: decimals > 0 ? 0.05 : 2, includeZero: true),
                                  tickCount: 2, format: ChartValueAxis.decimals(decimals))
        let yLayout = axis.layout(for: bars.map(\.v))
        let picked = selection.flatMap { s in bars.first { $0.from <= s && s < $0.to } }
        Chart {
            ForEach(bars, id: \.id) { b in
                BarMark(xStart: .value("From", b.from), xEnd: .value("To", b.to), y: .value("Value", b.v))
                    .foregroundStyle(tint.opacity(picked == nil || picked?.id == b.id ? 1 : NaraChartStyle.dimmedOpacity))
            }
            SelectionRule(selection, unit: nil)
        }
        .naraChartAxes(x: ChartAxis.layout(window, style: .hours, target: 4), y: yLayout)
        .chartScrub(xs: bars.map(\.mid), selection: $selection)
        .frame(height: 72)
        .accessibilityLabel(Text("Readings over the stretch"))
    }

    private static func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }
}

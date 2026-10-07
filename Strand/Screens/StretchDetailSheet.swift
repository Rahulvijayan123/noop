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
            let tint = right ? StrandPalette.statusPositive : StrandPalette.statusWarning
            HStack(spacing: 4) {
                Image(systemName: right ? "checkmark.circle.fill" : "xmark.circle.fill")
                Text(text(for: feedback, right: right))
                    .lineLimit(1)
            }
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
            .accessibilityElement(children: .combine)
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

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                        header
                        signalsCard
                        modelCard.id(Anchor.model)
                        validationCard.id(Anchor.validation)
                        zoomButton
                    }
                    .padding(NoopMetrics.space4)
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

    // MARK: Header

    private var header: some View {
        let p = target.presentation
        let from = Date(timeIntervalSince1970: TimeInterval(target.start))
        let to = Date(timeIntervalSince1970: TimeInterval(target.end))
        let seconds = target.durationSeconds < 300
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: p.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(p.color)
                .frame(width: 44, height: 44)
                .background(Circle().fill(p.color.opacity(0.16)))
            VStack(alignment: .leading, spacing: 4) {
                Text(p.title)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("\(StretchFormat.clock(from, seconds: seconds)) – \(StretchFormat.clock(to, seconds: seconds)) · \(StretchFormat.duration(target.durationSeconds))")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .monospacedDigit()
                Text(target.kind == .activityContext
                     ? String(localized: "Read by the activity model")
                     : String(localized: "Worked out from the strap's own signals"))
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: What the strap recorded

    private var signalsCard: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("What the strap recorded")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            switch load {
            case .loading:
                HStack(spacing: 10) {
                    ProgressView()
                    Text("Reading this stretch…")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .frame(maxWidth: .infinity, minHeight: 80)
            case .failed:
                Text("This stretch could not be read from the strap's stored data.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            case .ready(let detail):
                if detail.hasSignal {
                    signals(detail)
                } else {
                    Text("The strap recorded nothing in this stretch.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 20))
    }

    @ViewBuilder
    private func signals(_ d: StretchDetail) -> some View {
        let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]
        LazyVGrid(columns: columns, spacing: 10) {
            if let avg = d.avgHr {
                StatTile(title: String(localized: "Heart rate"), value: "\(avg)",
                         unit: "bpm", caption: d.minHr.flatMap { lo in d.maxHr.map { "\(lo)–\($0) bpm" } })
            }
            if let mean = d.meanMotionG {
                StatTile(title: String(localized: "Wrist movement"), value: String(format: "%.2f", mean), unit: "g",
                         caption: d.peakMotionG.map { String(localized: "Peak \(String(format: "%.2f", $0)) g") })
            }
            if let ticks = d.stepTicks {
                let perSecond = Double(ticks) / Double(max(1, d.durationSeconds))
                StatTile(title: String(localized: "Step counter"), value: "\(ticks)", unit: nil,
                         caption: ticks == 0
                            ? String(localized: "No steps counted")
                            : String(localized: "About \(String(format: "%.1f", perSecond)) a second"))
            }
            StatTile(title: String(localized: "Heart rate coverage"),
                     value: "\(Int((d.hrCoverage * 100).rounded()))", unit: "%",
                     caption: String(localized: "of the seconds"))
        }

        let slice = StretchFormat.duration(d.binSeconds)
        Text("Each bar or point covers \(slice).")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)

        if d.bins.contains(where: { $0.avgHr != nil }) {
            SliceTitle(String(localized: "Heart rate"))
            HeartRateSlices(detail: d)
        }
        if d.bins.contains(where: { $0.motionG != nil }) {
            SliceTitle(String(localized: "Wrist movement"))
            SliceBars(detail: d, tint: StrandPalette.metricCyan) { $0.motionG }
        }
        if (d.stepTicks ?? 0) > 0 {
            SliceTitle(String(localized: "Step counter ticks"))
            SliceBars(detail: d, tint: StrandPalette.accent) { $0.stepTicks.map(Double.init) }
        }
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
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 20))
    }

    @ViewBuilder
    private func activityModel(_ e: ActivityEpisode) -> some View {
        let tint = ActivityFamily.of(e.label).color
        Text("What the model made of it")
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
        HStack(spacing: 10) {
            Text("Confidence")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
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
        if e.confidence < 0.55 {
            Text("Conflicting or thin evidence here, so treat this as a guess.")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
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
        Text("How this was worked out")
            .font(StrandFont.headline)
            .foregroundStyle(StrandPalette.textPrimary)
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
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            Text("Is this right?")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Your answer is saved with this stretch and what the model saw, and helps tune it.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)

            HStack(spacing: 10) {
                verdictButton(.correct, title: String(localized: "Yes, that's right"),
                              symbol: "checkmark.circle.fill", tint: StrandPalette.statusPositive)
                verdictButton(.incorrect, title: String(localized: "No, it was wrong"),
                              symbol: "xmark.circle.fill", tint: StrandPalette.statusWarning)
            }

            if verdict == .incorrect {
                VStack(alignment: .leading, spacing: 8) {
                    Text("What was it?")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)],
                              alignment: .leading, spacing: 8) {
                        ForEach(StretchCorrection.allCases, id: \.self) { c in
                            correctionChip(c)
                        }
                    }
                }
            }

            if verdict != nil {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Add a note (optional)", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .font(StrandFont.body)
                        .textFieldStyle(.plain)
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StrandPalette.surfaceInset))
                    if noteIsDirty {
                        NoopButton("Save note", kind: .secondary, fullWidth: true) { persist() }
                    }
                    saveStatus
                }
            }
        }
        .padding(NoopMetrics.space3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(NoopPanelSurface(cornerRadius: 20))
    }

    private func verdictButton(_ value: StretchVerdict, title: String, symbol: String, tint: Color) -> some View {
        let selected = verdict == value
        return Button {
            withAnimation(StrandMotion.interactive) {
                verdict = value
                if value == .correct { correction = nil }
            }
            persist()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                Text(title)
                    .lineLimit(2)
                    .minimumScaleFactor(0.85)
                    .multilineTextAlignment(.leading)
            }
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(selected ? StrandPalette.goldDeepText : tint)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 8)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? tint : tint.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(selected ? 0 : 0.35), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func correctionChip(_ c: StretchCorrection) -> some View {
        let selected = correction == c
        let tint = StrandPalette.accent
        return Button {
            withAnimation(StrandMotion.interactive) { correction = selected ? nil : c }
            persist()
        } label: {
            Text(c.title)
                .font(StrandFont.subhead)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(selected ? StrandPalette.goldDeepText : StrandPalette.textPrimary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Capsule().fill(selected ? tint : StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
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

private struct StatTile: View {
    let title: String
    let value: String
    let unit: String?
    let caption: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .textCase(.uppercase)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(StrandFont.rounded(24))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
                if let unit {
                    Text(unit)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Text(caption ?? " ")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(StrandPalette.surfaceInset))
    }
}

private struct SliceTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(StrandFont.subhead.weight(.semibold))
            .foregroundStyle(StrandPalette.textSecondary)
            .padding(.top, 4)
    }
}

private func date(_ ts: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(ts)) }

private extension View {
    func sliceTimeAxis(_ detail: StretchDetail) -> some View {
        let style: Date.FormatStyle = detail.durationSeconds < 900
            ? Date.FormatStyle().hour().minute().second()
            : Date.FormatStyle().hour().minute()
        return self
            .chartXScale(domain: date(detail.start)...date(max(detail.end, detail.start + 1)))
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: detail.durationSeconds < 900 ? 3 : 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel(format: style)
                }
            }
    }
}

/// Heart rate over the stretch: the average of each slice, with its lowest-to-highest range behind it.
private struct HeartRateSlices: View {
    let detail: StretchDetail

    var body: some View {
        let points = detail.bins.compactMap { b -> (id: Int, mid: Date, avg: Int, lo: Int, hi: Int)? in
            guard let avg = b.avgHr, let lo = b.minHr, let hi = b.maxHr else { return nil }
            return (b.start, date(b.start + b.durationSeconds / 2), avg, lo, hi)
        }
        let low = (points.map(\.lo).min() ?? 40) - 5
        let high = (points.map(\.hi).max() ?? 120) + 5
        Chart {
            ForEach(points, id: \.id) { p in
                AreaMark(x: .value("Time", p.mid), yStart: .value("Lowest", p.lo), yEnd: .value("Highest", p.hi))
                    .foregroundStyle(StrandPalette.metricRose.opacity(0.18))
                    .interpolationMethod(.monotone)
            }
            ForEach(points, id: \.id) { p in
                LineMark(x: .value("Time", p.mid), y: .value("Average", p.avg))
                    .foregroundStyle(StrandPalette.metricRose)
                    .interpolationMethod(.monotone)
            }
            ForEach(points.count <= 24 ? points : [], id: \.id) { p in
                PointMark(x: .value("Time", p.mid), y: .value("Average", p.avg))
                    .foregroundStyle(StrandPalette.metricRose)
                    .symbolSize(18)
            }
        }
        .chartYScale(domain: low...high)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .sliceTimeAxis(detail)
        .frame(height: 130)
        .accessibilityLabel(Text("Heart rate over the stretch"))
    }
}

/// One value per slice as a bar spanning the slice.
private struct SliceBars: View {
    let detail: StretchDetail
    let tint: Color
    let value: (StretchBin) -> Double?

    var body: some View {
        let bars = detail.bins.compactMap { b -> (id: Int, from: Date, to: Date, v: Double)? in
            value(b).map { (b.start, date(b.start), date(b.end), $0) }
        }
        let top = max(0.05, (bars.map(\.v).max() ?? 0) * 1.15)
        Chart {
            ForEach(bars, id: \.id) { b in
                BarMark(xStart: .value("From", b.from), xEnd: .value("To", b.to), y: .value("Value", b.v))
                    .foregroundStyle(tint)
            }
        }
        .chartYScale(domain: 0...top)
        .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
        .sliceTimeAxis(detail)
        .frame(height: 90)
        .accessibilityLabel(Text("Readings over the stretch"))
    }
}

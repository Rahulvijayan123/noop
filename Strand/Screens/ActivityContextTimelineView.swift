import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - ActivityContext wording and pieces
//
// The decoded state, not one label: three independent heads (posture, locomotion, arm behaviour), each a
// probability distribution, plus intensity, confidence and the wear and sleep context. Composite labels such
// as "Desk sitting" are a derived view of those heads. The page that lists them is `DayStretchesSection`; this
// file holds the words and colours it and the stretch sheet share. A wrist cannot see body height, so sitting
// and standing are only ever "likely".

// MARK: Wording

extension PostureClass {
    var displayName: String {
        switch self {
        case .recumbent: return String(localized: "Lying down")
        case .seatedLikely: return String(localized: "Seated (likely)")
        case .uprightStationary: return String(localized: "Upright, still")
        case .posturalTransition: return String(localized: "Changing position")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension LocomotionClass {
    var displayName: String {
        switch self {
        case .stationary: return String(localized: "Stationary")
        case .walking: return String(localized: "Walking")
        case .briskWalking: return String(localized: "Brisk walking")
        case .running: return String(localized: "Running")
        case .stairs: return String(localized: "Stairs")
        case .cycling: return String(localized: "Cycling")
        case .vehicleMotion: return String(localized: "Vehicle motion")
        case .other: return String(localized: "Other movement")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension ArmBehaviorClass {
    var displayName: String {
        switch self {
        case .quiet: return String(localized: "Quiet")
        case .deskLike: return String(localized: "Desk-like")
        case .fidgeting: return String(localized: "Fidgeting")
        case .repetitiveHandMotion: return String(localized: "Repetitive hand motion")
        case .activeGesturing: return String(localized: "Gesturing")
        case .exerciseMotion: return String(localized: "Exercise motion")
        case .other: return String(localized: "Other")
        case .unknown: return String(localized: "Unknown")
        }
    }
}

extension ActivityTransitionKind {
    var displayName: String {
        switch self {
        case .sitToStandLike: return String(localized: "Sit-to-stand-like")
        case .standToSitLike: return String(localized: "Stand-to-sit-like")
        case .lyingDownLike: return String(localized: "Lying-down-like")
        case .gettingUpLike: return String(localized: "Getting-up-like")
        case .walkStart: return String(localized: "Started walking")
        case .walkStop: return String(localized: "Stopped walking")
        case .runStart: return String(localized: "Started running")
        case .runStop: return String(localized: "Stopped running")
        }
    }
}

extension SleepContextState {
    var displayName: String {
        switch self {
        case .asleep: return String(localized: "Asleep")
        case .awake: return String(localized: "Awake")
        case .unknown: return String(localized: "Not known")
        }
    }
}

extension WearContextState {
    var displayName: String {
        switch self {
        case .onWrist: return String(localized: "On wrist")
        case .offWrist: return String(localized: "Off wrist")
        case .unknown: return String(localized: "Not known")
        }
    }
}

/// The colour family a display label belongs to. Many labels ("Desk sitting", "Sitting quietly") are one
/// family on the lane; the label itself stays in the list and the detail card.
enum ActivityFamily: CaseIterable, Hashable {
    case asleep, inBed, sitting, standing, stillUnsure, walking, running, otherMovement, changing, offWrist, unclear

    static func of(_ label: String) -> ActivityFamily {
        switch label {
        case ActivityDisplay.offWrist: return .offWrist
        case ActivityDisplay.unclear: return .unclear
        case "Asleep": return .asleep
        // Lying awake in bed is not sleep, and is drawn in the hypnogram's awake colour so the lane and the
        // sleep page tell the same story about a night.
        case "Resting in bed", "Lying down": return .inBed
        case "Running": return .running
        case "Walking", "Brisk walking", "Taking stairs": return .walking
        case "Cycling", "In a vehicle", "Exercising", "Moving": return .otherMovement
        case "Changing position": return .changing
        case "Still, sitting or standing", "Hands busy, sitting or standing", "Stationary": return .stillUnsure
        default:
            if label.hasPrefix("Sitting") || label == "Desk sitting" { return .sitting }
            if label.hasPrefix("Standing") { return .standing }
            return .unclear
        }
    }

    var title: String {
        switch self {
        case .asleep: return String(localized: "Asleep")
        case .inBed: return String(localized: "Lying down or in bed")
        case .sitting: return String(localized: "Sitting")
        case .standing: return String(localized: "Standing")
        case .stillUnsure: return String(localized: "Still, sitting or standing")
        case .walking: return String(localized: "Walking")
        case .running: return String(localized: "Running")
        case .otherMovement: return String(localized: "Other movement")
        case .changing: return String(localized: "Changing position")
        case .offWrist: return String(localized: "Off wrist")
        case .unclear: return String(localized: "Unclear")
        }
    }

    var color: Color {
        switch self {
        case .asleep: return StrandPalette.sleepDeep
        case .inBed: return StrandPalette.sleepAwake
        case .sitting: return StrandPalette.metricCyan
        case .standing: return StrandPalette.metricPurple
        case .stillUnsure: return StrandPalette.metricCyan.opacity(0.5)
        case .walking: return StrandPalette.accent
        case .running: return StrandPalette.metricRose
        case .otherMovement: return StrandPalette.metricAmber
        case .changing: return StrandPalette.metricAmber.opacity(0.6)
        case .offWrist: return StrandPalette.textTertiary
        case .unclear: return StrandPalette.surfaceInset
        }
    }

    var symbol: String {
        switch self {
        case .asleep: return "bed.double.fill"
        case .inBed: return "bed.double"
        case .sitting, .stillUnsure: return "chair.lounge.fill"
        case .standing: return "figure.stand"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .otherMovement: return "figure.mixed.cardio"
        case .changing: return "arrow.up.arrow.down"
        case .offWrist: return "applewatch.slash"
        case .unclear: return "questionmark.circle"
        }
    }

    static let displayOrder: [ActivityFamily] = [
        .asleep, .inBed, .sitting, .stillUnsure, .standing, .changing, .walking, .running, .otherMovement, .offWrist, .unclear,
    ]
}

// MARK: Pieces

/// Marks the newest stretch in a list.
struct LatestTag: View {
    var body: some View {
        Text("Latest")
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(StrandPalette.accent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(StrandPalette.accent.opacity(0.14)))
    }
}

struct ProbabilityBar: View {
    let value: Double
    let tint: Color
    var width: CGFloat = 96

    var body: some View {
        Capsule()
            .fill(tint.opacity(0.18))
            .frame(width: width, height: 6)
            .overlay(alignment: .leading) {
                Capsule().fill(tint).frame(width: width * CGFloat(min(1, max(0, value))), height: 6)
            }
    }
}

struct HeadBlock: View {
    let title: String
    let rows: [(name: String, p: Double)]
    let tint: Color

    /// The strongest answers of a head, most likely first. Anything under 5% is noise at this resolution.
    static func rows<C: RawRepresentable & Hashable & CaseIterable & Sendable>(
        _ head: HeadProbabilities<C>, name: KeyPath<C, String>, limit: Int = 3
    ) -> [(name: String, p: Double)] where C.RawValue == String {
        head.values
            .filter { $0.value >= 0.05 }
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.rawValue < $1.key.rawValue }
            .prefix(limit)
            .map { (name: $0.key[keyPath: name], p: $0.value) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(StrandFont.caption.weight(.semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .textCase(.uppercase)
            if rows.isEmpty {
                Text("No reading")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 10) {
                    Text(row.name)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Spacer(minLength: 8)
                    ProbabilityBar(value: row.p, tint: tint)
                    Text("\(Int((row.p * 100).rounded()))%")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .monospacedDigit()
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }
}

// MARK: - Help improve activity detection
//
// The day page can ask the wearer about a few stretches the model is least sure of: each answer becomes a
// weak ground-truth label (and a stretch-feedback correction when the wearer names one thing), so the
// labels train the activity model instead of only the verdict history. This section is deliberately
// self-contained: feed it the decoded episodes the day page already built and the day's start, and it
// turns up to five candidate stretches (from `ActivityLabelCandidateSelector`) into one-tap questions.
// Candidates are keyed by the same stretch key the feedback store uses (`"activity_context:<startTs>"`),
// so a stretch is never asked twice, and a per-day budget keeps the queue to five questions a day.

/// Where the "Help improve activity detection" queue keeps its state: which stretches were already asked
/// (a `Set<String>` of stretch keys), and how many of the day's five questions were used (a
/// `[dayKey: Int]` dictionary, pruned of old days). Both live in UserDefaults so an answer survives a
/// relaunch; the day key is the local calendar date of the day being shown.
enum ActivityImprovementQueue {
    static let answeredDefaultsKey = "activity-label-candidates-answered-v1"
    static let dayBudgetDefaultsKey = "activity-label-candidates-day-v1"
    /// The queue never asks more than this many stretches in one day (the section's own cap, on top of
    /// the selector's per-call limit).
    static let dayLimit = 5
    /// How many calendar days of prompt counts are kept before the dictionary drops the older ones.
    static let keepDays = 14

    static func answeredKeys(_ defaults: UserDefaults = .standard) -> Set<String> {
        Set(defaults.stringArray(forKey: answeredDefaultsKey) ?? [])
    }

    /// How many of the day's questions were used. Reads prune the dictionary as a side effect, so a
    /// stale `[dayKey: count]` never grows without bound.
    static func dayCount(for dayKey: String, defaults: UserDefaults = .standard) -> Int {
        var days = (defaults.dictionary(forKey: dayBudgetDefaultsKey) as? [String: Int]) ?? [:]
        prune(&days)
        return days[dayKey] ?? 0
    }

    /// Record one asked stretch: it is answered for good (so the selector never offers it again) and the
    /// day it was asked counts against that day's prompt budget.
    static func markAnswered(_ stretchKey: String, dayKey: String, defaults: UserDefaults = .standard) {
        var keys = answeredKeys(defaults)
        keys.insert(stretchKey)
        defaults.set(Array(keys), forKey: answeredDefaultsKey)
        var days = (defaults.dictionary(forKey: dayBudgetDefaultsKey) as? [String: Int]) ?? [:]
        days[dayKey, default: 0] += 1
        prune(&days)
        defaults.set(days, forKey: dayBudgetDefaultsKey)
    }

    /// A stable per-day key for the budget dictionary: the day's local calendar date, `yyyy-MM-dd`.
    static func dayKey(for dayStart: Date) -> String {
        Self.formatter.string(from: dayStart)
    }

    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Drop budget keys older than `keepDays` calendar days. The keys are `yyyy-MM-dd` strings, so the
    /// cutoff compares lexicographically, which is chronological for this format.
    private static func prune(_ days: inout [String: Int]) {
        let today = formatter.string(from: Date())
        guard let todayDate = formatter.date(from: today) else { return }
        let cutoff = formatter.string(from: todayDate.addingTimeInterval(-Double(keepDays - 1) * 86_400))
        days = days.filter { $0.key >= cutoff }
    }
}

/// The day's "Help improve activity detection" card. Empty when the day has no stretch worth asking about
/// or the day's five questions are used up. Drop it into the day page next to the other sections; it
/// needs only the episodes the page already decoded (`ActivityContextEpisodes.build(document.runs)`).
struct ActivityImprovementSection: View {
    let episodes: [ActivityEpisode]
    /// The day these episodes belong to; its local date is the prompt-budget key.
    let dayStart: Date
    let deviceId: String?
    /// A short section title in place of the full heading and explanation.
    let compactTitle: LocalizedStringKey?
    /// How many rows show here; the rest are one "See all" away. nil shows every row.
    let inlineLimit: Int?
    let showsHeader: Bool

    /// The stretch being asked about, or nil when no sheet is up.
    @State private var asking: ActivityImprovementPrompt?

    init(episodes: [ActivityEpisode], dayStart: Date, deviceId: String? = nil,
         compactTitle: LocalizedStringKey? = nil, inlineLimit: Int? = nil, showsHeader: Bool = true) {
        self.episodes = episodes
        self.dayStart = dayStart
        self.deviceId = deviceId
        self.compactTitle = compactTitle
        self.inlineLimit = inlineLimit
        self.showsHeader = showsHeader
    }

    init(document: ActivityContextDayDocument?, dayStart: Date, deviceId: String? = nil) {
        self.init(episodes: document.map { ActivityContextEpisodes.build($0.runs) } ?? [],
                  dayStart: dayStart, deviceId: deviceId)
    }

    private var dayKey: String { ActivityImprovementQueue.dayKey(for: dayStart) }

    /// The one decoupled description per episode the selector is pure over. Built once per episode set
    /// (each input classifies its episode), not on every render: the section re-renders on each zoom/pan.
    /// A reference box, so filling it while rendering is not a state change.
    private final class InputsCache {
        var key: String?
        var inputs: [ActivityCandidateStretchInput] = []
    }
    @State private var cache = InputsCache()

    private var inputs: [ActivityCandidateStretchInput] {
        let key = "\(deviceId ?? "")|\(episodes.count)|\(episodes.first?.start ?? 0)|\(episodes.last?.end ?? 0)"
        if cache.key != key {
            cache.inputs = ActivityLabelCandidateInputs.fromEpisodes(episodes, deviceId: deviceId)
            cache.key = key
        }
        return cache.inputs
    }

    /// The stretches worth asking about today, capped by the day's prompt budget. Re-reads the answered
    /// set and the day count on every render, so an answer removes its row at once.
    private var visibleCandidates: [ActivityLabelCandidate] {
        let selected = ActivityLabelCandidateSelector.select(
            from: inputs, answeredKeys: ActivityImprovementQueue.answeredKeys(), limit: 5)
        let remaining = max(0, ActivityImprovementQueue.dayLimit - ActivityImprovementQueue.dayCount(for: dayKey))
        return Array(selected.prefix(remaining))
    }

    private var inputByStart: [Int: ActivityCandidateStretchInput] {
        Dictionary(inputs.map { ($0.startTs, $0) }, uniquingKeysWith: { a, _ in a })
    }

    var body: some View {
        let candidates = visibleCandidates
        let shown = inlineLimit.map { Array(candidates.prefix($0)) } ?? candidates
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                if showsHeader { header(hasMore: shown.count < candidates.count) }
                ForEach(shown) { candidate in
                    ActivityImprovementRow(candidate: candidate) {
                        open(candidate)
                    }
                }
            }
            .sheet(item: $asking) { prompt in
                ActivityImprovementSheet(input: prompt.input, dayKey: dayKey)
            }
        }
    }

    @ViewBuilder private func header(hasMore: Bool) -> some View {
        if let compactTitle {
            DaySectionHeader(title: compactTitle) {
                if hasMore {
                    NavigationLink {
                        ScreenScaffold(title: compactTitle,
                                       subtitle: "A few stretches were unclear. Tell me what you were doing and the labels get better.") {
                            ActivityImprovementSection(episodes: episodes, dayStart: dayStart, deviceId: deviceId,
                                                       showsHeader: false)
                        }
                    } label: {
                        SeeAllLabel(text: "See all")
                    }
                    .buttonStyle(.plain)
                }
            }
        } else {
            fullHeader
        }
    }

    private var fullHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Help improve activity detection")
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("A few stretches were unclear. Tell me what you were doing and the labels get better.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
        }
        .padding(.horizontal, NoopMetrics.space1)
    }

    private func open(_ candidate: ActivityLabelCandidate) {
        let input = inputByStart[candidate.startTs] ?? ActivityCandidateStretchInput(
            startTs: candidate.startTs, endTs: candidate.endTs, deviceId: candidate.deviceId,
            predictedLabel: candidate.predictedLabel)
        asking = ActivityImprovementPrompt(input: input)
    }
}

/// One candidate in the queue: its time range, what the model guessed, and the badges that say why it is
/// being asked (Uncertain / Disagreement / Rare). Tapping opens the one-tap answer sheet.
struct ActivityImprovementRow: View {
    let candidate: ActivityLabelCandidate
    let action: () -> Void

    var body: some View {
        let from = Date(timeIntervalSince1970: TimeInterval(candidate.startTs))
        let to = Date(timeIntervalSince1970: TimeInterval(candidate.endTs))
        let short = candidate.endTs - candidate.startTs < 300
        return Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(StretchFormat.clock(from, seconds: short)) – \(StretchFormat.clock(to, seconds: short))")
                        .font(StrandFont.subhead.weight(.semibold))
                        .foregroundStyle(StrandPalette.textPrimary)
                        .monospacedDigit()
                    Text(candidate.predictedLabel ?? ActivityContextEpisodes.unclear)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    ForEach(candidate.reasons, id: \.self) { reason in
                        reasonBadge(reason)
                    }
                }
                Image(systemName: "chevron.right")
                    .font(StrandFont.caption.weight(.semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            .padding(NoopMetrics.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(NoopPanelSurface(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Lets you say what you were doing")
    }

    private func reasonBadge(_ reason: String) -> some View {
        let (text, tint) = ActivityImprovementReason.presentation(for: reason)
        return Text(text)
            .font(StrandFont.caption.weight(.semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.14)))
            .accessibilityLabel(text)
    }
}

/// The selector's reason codes, as the wearer sees them on the row.
enum ActivityImprovementReason {
    static func presentation(for reason: String) -> (text: String, tint: Color) {
        switch reason {
        case ActivityLabelCandidateSelector.reasonUncertainty:
            return (String(localized: "Uncertain"), StrandPalette.statusWarning)
        case ActivityLabelCandidateSelector.reasonDisagreement:
            return (String(localized: "Disagreement"), StrandPalette.metricAmber)
        case ActivityLabelCandidateSelector.reasonCoverage:
            return (String(localized: "Rare"), StrandPalette.metricPurple)
        default:
            return (reason, StrandPalette.textTertiary)
        }
    }
}

/// The question being asked, so the sheet can present exactly one stretch.
private struct ActivityImprovementPrompt: Identifiable {
    let input: ActivityCandidateStretchInput
    var id: String { ActivityLabelCandidateSelector.stretchKey(start: input.startTs) }
}

/// The compact one-tap answer sheet: "3:42–3:46 PM was unclear. What were you mainly doing?" with the
/// correction options (one tap answers), plus Mixed / Not sure / Skip. A correction also saves a
/// stretch-feedback correction; a correction, Mixed or Not sure answer also saves a weak ground-truth
/// label; Skip only marks the stretch answered.
struct ActivityImprovementSheet: View {
    let input: ActivityCandidateStretchInput
    let dayKey: String

    @Environment(\.dismiss) private var dismiss

    private var stretchKey: String {
        ActivityLabelCandidateSelector.stretchKey(start: input.startTs)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                    header
                    Text("What were you mainly doing?")
                        .font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 8, alignment: .leading)],
                              alignment: .leading, spacing: 8) {
                        ForEach(StretchCorrection.allCases, id: \.self) { c in
                            answerChip(c.title) { answer(c) }
                        }
                        answerChip(String(localized: "Mixed")) { answerMixed() }
                        answerChip(String(localized: "Unsure")) { answerUnsure() }
                        answerChip(String(localized: "Skip")) { answerSkip() }
                    }
                    Text("One tap is all it takes. Your answer is saved with what the model saw and sent to make the activity model better.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(NoopMetrics.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            #if os(macOS)
            .frame(minWidth: 480, minHeight: 560)
            #endif
        }
    }

    private var header: some View {
        let from = Date(timeIntervalSince1970: TimeInterval(input.startTs))
        let to = Date(timeIntervalSince1970: TimeInterval(input.endTs))
        let short = input.endTs - input.startTs < 300
        let range = "\(StretchFormat.clock(from, seconds: short)) – \(StretchFormat.clock(to, seconds: short))"
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 40, height: 40)
                    .background(Circle().fill(StrandPalette.accent.opacity(0.16)))
                Text(range)
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .monospacedDigit()
            }
            Text("\(range) was unclear. What were you mainly doing?")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func answerChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(StrandFont.subhead)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 38)
                .background(Capsule().fill(StrandPalette.surfaceInset))
        }
        .buttonStyle(.plain)
    }

    // MARK: Answers

    private func answer(_ correction: StretchCorrection) {
        submit(correction: correction, note: correction.title, userUnsure: false)
        dismiss()
    }

    private func answerMixed() {
        // More than one thing at once: the label says nothing about a single head, but it is a real answer.
        submit(correction: nil, note: String(localized: "Mixed"), userUnsure: false)
        dismiss()
    }

    private func answerUnsure() {
        submit(correction: nil, note: String(localized: "Unsure"), userUnsure: true)
        dismiss()
    }

    private func answerSkip() {
        ActivityImprovementQueue.markAnswered(stretchKey, dayKey: dayKey)
        dismiss()
    }

    /// One answer, stored two ways: a stretch-feedback correction (when the wearer named one thing) and a
    /// weak ground-truth label. The stretch is marked answered in both cases.
    private func submit(correction: StretchCorrection?, note: String, userUnsure: Bool) {
        let heads = correction.map(StretchCorrection.partialHeads(for:))
            ?? (posture: nil, locomotion: nil, armBehavior: nil)
        let info = Bundle.main.infoDictionary
        let tz = TimeZone.current.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(input.startTs)))
        var context = StretchModelContext()
        context.displayLabel = input.predictedLabel
        context.uncertainty = input.overallUncertainty

        if let correction {
            let confirms = correction.activityClass.map { $0.rawValue == input.predictedClass } ?? false
            let record = StretchFeedback(
                kind: .activityContext, startTs: input.startTs, endTs: input.endTs, deviceId: input.deviceId,
                predictedLabel: input.predictedLabel ?? ActivityContextEpisodes.unclear,
                predictedClass: input.predictedClass,
                predictedConfidence: nil,
                verdict: confirms ? .correct : .incorrect, correctedLabel: confirms ? nil : correction,
                context: context,
                appVersion: info?["CFBundleShortVersionString"] as? String,
                appBuild: info?["CFBundleVersion"] as? String,
                tzOffsetS: tz)
            StretchFeedbackCenter.shared.save(record)
        }

        let label = ActivityGroundTruthLabel(
            source: .stretchFeedback,
            stretchKey: stretchKey,
            startTs: input.startTs, endTs: input.endTs,
            deviceId: input.deviceId,
            posture: heads.posture, locomotion: heads.locomotion, armBehavior: heads.armBehavior,
            userUnsure: userUnsure,
            note: note,
            modelContextAtLabelTime: ["display": input.predictedLabel ?? ActivityContextEpisodes.unclear],
            appVersion: info?["CFBundleShortVersionString"] as? String,
            appBuild: info?["CFBundleVersion"] as? String)
        ActivityGroundTruthStore.shared.upsert(label)

        ActivityImprovementQueue.markAnswered(stretchKey, dayKey: dayKey)
    }
}

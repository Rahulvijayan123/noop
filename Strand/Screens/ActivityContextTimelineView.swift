import SwiftUI
import StrandDesign
import StrandAnalytics

// MARK: - ActivityContext wording and pieces
//
// The decoded state, not one label: three independent heads (posture, locomotion, arm behaviour), each a
// probability distribution, plus intensity, confidence and the wear and sleep context. Composite labels such
// as "Desk sitting" are a derived view of those heads. The Heart rate day page shows them on its ribbon and
// lists them one tap down; this file holds the words and colours those pages and the stretch sheet share. A wrist cannot see body height, so sitting
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
        // Moving is warm (amber walking, rose running, a lighter rose for other movement), being still is
        // cool (cyan, violet), sleep is the sleep hue: no two neighbouring kinds share a colour.
        case .walking: return StrandPalette.metricAmber
        case .running: return StrandPalette.metricRose
        case .otherMovement: return StrandPalette.metricRose.opacity(0.55)
        case .changing: return StrandPalette.metricAmber.opacity(0.6)
        case .offWrist: return StrandPalette.textTertiary
        // Drawn hatched wherever it is shown, so it needs a visible colour on an inset track.
        case .unclear: return StrandPalette.textTertiary.opacity(0.6)
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
        StatePill("Latest", tone: .neutral, showsDot: false)
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
                .strandLabel()
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

/// The day's uncertain stretches worth asking about, cached per episode set. The selector is pure over one
/// decoupled description per episode; building those classifies every episode, so it is done once per set,
/// not on every render (the page re-renders while scrubbing). The answered set and the day's budget are
/// re-read on every call, so an answer removes its stretch at once.
final class ActivityImprovementCandidates: ObservableObject {
    private var key: String?
    private var cachedInputs: [ActivityCandidateStretchInput] = []

    func inputs(episodes: [ActivityEpisode], deviceId: String?) -> [ActivityCandidateStretchInput] {
        let key = "\(deviceId ?? "")|\(episodes.count)|\(episodes.first?.start ?? 0)|\(episodes.last?.end ?? 0)"
        if self.key != key {
            cachedInputs = ActivityLabelCandidateInputs.fromEpisodes(episodes, deviceId: deviceId)
            self.key = key
        }
        return cachedInputs
    }

    /// The stretches worth asking about today, capped by the day's prompt budget.
    func candidates(episodes: [ActivityEpisode], dayStart: Date, deviceId: String?) -> [ActivityLabelCandidate] {
        let selected = ActivityLabelCandidateSelector.select(
            from: inputs(episodes: episodes, deviceId: deviceId),
            answeredKeys: ActivityImprovementQueue.answeredKeys(), limit: 5)
        let dayKey = ActivityImprovementQueue.dayKey(for: dayStart)
        let remaining = max(0, ActivityImprovementQueue.dayLimit - ActivityImprovementQueue.dayCount(for: dayKey))
        return Array(selected.prefix(remaining))
    }

    /// The full description of a candidate, for the answer sheet.
    func input(for candidate: ActivityLabelCandidate, episodes: [ActivityEpisode],
               deviceId: String?) -> ActivityCandidateStretchInput {
        let byStart = Dictionary(inputs(episodes: episodes, deviceId: deviceId).map { ($0.startTs, $0) },
                                 uniquingKeysWith: { a, _ in a })
        return byStart[candidate.startTs] ?? ActivityCandidateStretchInput(
            startTs: candidate.startTs, endTs: candidate.endTs, deviceId: candidate.deviceId,
            predictedLabel: candidate.predictedLabel)
    }
}

/// The day's "Help improve activity detection" list. Empty when the day has no stretch worth asking about
/// or the day's five questions are used up. It needs only the episodes the page already decoded
/// (`ActivityContextEpisodes.build(document.runs)`).
struct ActivityImprovementSection: View {
    let episodes: [ActivityEpisode]
    /// The day these episodes belong to; its local date is the prompt-budget key.
    let dayStart: Date
    let deviceId: String?

    /// The stretch being asked about, or nil when no sheet is up.
    @State private var asking: ActivityImprovementPrompt?
    @StateObject private var model = ActivityImprovementCandidates()

    init(episodes: [ActivityEpisode], dayStart: Date, deviceId: String? = nil) {
        self.episodes = episodes
        self.dayStart = dayStart
        self.deviceId = deviceId
    }

    init(document: ActivityContextDayDocument?, dayStart: Date, deviceId: String? = nil) {
        self.init(episodes: document.map { ActivityContextEpisodes.build($0.runs) } ?? [],
                  dayStart: dayStart, deviceId: deviceId)
    }

    private var dayKey: String { ActivityImprovementQueue.dayKey(for: dayStart) }

    var body: some View {
        let candidates = model.candidates(episodes: episodes, dayStart: dayStart, deviceId: deviceId)
        if !candidates.isEmpty {
            VStack(alignment: .leading, spacing: NoopMetrics.gap) {
                SectionHeader("Help improve activity detection")
                ActivityImprovementList(candidates: candidates) { open($0) }
            }
            .sheet(item: $asking) { prompt in
                ActivityImprovementSheet(input: prompt.input, dayKey: dayKey)
            }
        }
    }

    private func open(_ candidate: ActivityLabelCandidate) {
        asking = ActivityImprovementPrompt(input: model.input(for: candidate, episodes: episodes, deviceId: deviceId))
    }
}

/// The page behind the Heart rate page's "Check stretches" row: the day's few uncertain stretches, one tap
/// each to say what the wearer was doing.
struct ActivityImprovementListView: View {
    let episodes: [ActivityEpisode]
    let dayStart: Date
    let deviceId: String?

    @State private var asking: ActivityImprovementPrompt?
    @StateObject private var model = ActivityImprovementCandidates()

    private var dayKey: String { ActivityImprovementQueue.dayKey(for: dayStart) }

    var body: some View {
        let candidates = model.candidates(episodes: episodes, dayStart: dayStart, deviceId: deviceId)
        ScreenScaffold(title: "Check stretches", titleDisplay: .navigationBar) {
            Text("A few stretches were unclear. Say what you were doing and the labels get better.")
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if candidates.isEmpty {
                ComingSoon(what: "Nothing left to check for this day.")
            } else {
                ActivityImprovementList(candidates: candidates) { candidate in
                    asking = ActivityImprovementPrompt(
                        input: model.input(for: candidate, episodes: episodes, deviceId: deviceId))
                }
            }
        }
        .sheet(item: $asking) { prompt in
            ActivityImprovementSheet(input: prompt.input, dayKey: dayKey)
        }
    }
}

/// The candidates as rows of one list card.
struct ActivityImprovementList: View {
    let candidates: [ActivityLabelCandidate]
    let open: (ActivityLabelCandidate) -> Void

    var body: some View {
        NoopListSection {
            ForEach(Array(candidates.enumerated()), id: \.element.id) { index, candidate in
                if index > 0 { NoopListDivider() }
                ActivityImprovementRow(candidate: candidate) { open(candidate) }
            }
        }
    }
}

/// One candidate in the queue: its time range, what the model guessed, and why it is being asked
/// (Uncertain / Disagreement / Rare). Tapping opens the one-tap answer sheet.
struct ActivityImprovementRow: View {
    let candidate: ActivityLabelCandidate
    let action: () -> Void

    var body: some View {
        let from = Date(timeIntervalSince1970: TimeInterval(candidate.startTs))
        let to = Date(timeIntervalSince1970: TimeInterval(candidate.endTs))
        let short = candidate.endTs - candidate.startTs < 300
        let span = "\(StretchFormat.clock(from, seconds: short)) – \(StretchFormat.clock(to, seconds: short))"
        let reasons = candidate.reasons.map { ActivityImprovementReason.presentation(for: $0).text }
        return Button(action: action) {
            NoopListRow(icon: nil, title: LocalizedStringKey(span),
                        subtitle: candidate.predictedLabel ?? ActivityContextEpisodes.unclear,
                        value: reasons.joined(separator: ", "))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Lets you say what you were doing")
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
                    Text("Your answer is saved with what the model saw and sent to make the activity model better.")
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(NoopMetrics.space4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
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
        return VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
            Text(range)
                .font(StrandFont.title2)
                .foregroundStyle(StrandPalette.textPrimary)
                .monospacedDigit()
            Text(input.predictedLabel ?? ActivityContextEpisodes.unclear)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }

    private func answerChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .buttonStyle(NoopButtonStyle(.secondary, fullWidth: true))
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

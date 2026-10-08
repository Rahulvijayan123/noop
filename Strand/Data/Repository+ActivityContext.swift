import Foundation
import WhoopProtocol
import StrandAnalytics

extension Repository {
    /// The heart-rate reference the activity decoder judges effort against for this wearer: their typical
    /// resting rate (median of recent nights) and maximum, each used only when plausible. The Heart rate
    /// page and the persisted context both decode with it, so a day is the same day wherever it is read.
    ///
    /// No expert evidence (ElderNet, motion heads) is part of it: which stored expert rows may shape a day is decided
    /// per day by the shared policy (`ActivityPhoneEvidence`), from the release each row recorded.
    ///
    /// The wearer's personal profile joins once a fit from their guided calibration runs beat the defaults on
    /// held-out runs (`ActivityPersonalProfileStore`); its tag is part of `cacheTag`, so cached days re-decode.
    var activityDecoderConfig: ActivityDecoderConfig {
        var config = activityBaseDecoderConfig
        config.personalProfile = ActivityPersonalProfileStore.shared.adoptedProfile
        return config
    }

    /// `activityDecoderConfig` without the personal profile: what a personal fit is replayed with and has to beat.
    var activityBaseDecoderConfig: ActivityDecoderConfig {
        ActivityDecoderConfig.personalized(
            restingHeartRate: ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: days.map(\.restingHr)),
            maxHeartRate: activityMaxHeartRate)
    }

    var dayStateSourceKey: String { importedReadIds.joined(separator: "+") }

    /// What is already stored for the day, without decoding anything. The Heart rate page draws this the
    /// moment it opens, then brings it up to date. nil when the day has never been decoded, or was decoded by
    /// an older decoder.
    func cachedActivityContext(dayStart: Date) async -> ActivityContextDayDocument? {
        let reads = importedReadIds.joined(separator: "+")
        let base = activityDecoderConfig
        let start = Int(dayStart.timeIntervalSince1970)
        let end = Int((Calendar.current.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart.addingTimeInterval(86_400))
            .timeIntervalSince1970)
        return await Task.detached(priority: .userInitiated) {
            // Keyed like `activityContext(from:)`: by the config the day's canonical decode runs with, heart-rate
            // reference included (a decoder resumed from state built against another reference would carry that
            // reference's reading of effort into the new one).
            let config = ActivityPhoneEvidence.canonical(ActivityContextTrackInput(dayStart: start, dayEnd: end),
                                                         base: base).config
            return ActivityContextFileStore.shared.load(source: "\(reads)@\(config.cacheTag)", dayStart: start)
                .flatMap { $0.isCurrent ? $0 : nil }
        }.value
    }

    func cachedDayStates(dayStart: Date) async -> DayStateFileStore.Record? {
        let source = dayStateSourceKey
        let start = Int(dayStart.timeIntervalSince1970)
        return await Task.detached(priority: .userInitiated) {
            DayStateFileStore.shared.load(source: source, dayStart: start)
        }.value
    }

    func storeDayStates(_ segments: [DayStateSegment], from s: DayStreams) {
        let source = dayStateSourceKey
        Task.detached(priority: .utility) {
            DayStateFileStore.shared.save(segments: segments, source: source, dayStart: s.start, dayEnd: s.end)
        }
    }

    /// The day's ActivityContext: read from the on-disk cache when it is still valid, extended with whatever
    /// the strap has recorded since, or decoded from the start of the day. Decoding runs off the main actor
    /// (see `ActivityContextWorker`).
    ///
    /// `progress` is called, off the main actor, with the day so far while a whole day is being decoded from
    /// scratch, so the page can fill in from the left instead of waiting for the end.
    func activityContext(from s: DayStreams,
                         lane: ActivityContextWorker.Lane = .page,
                         progress: (@Sendable (ActivityContextDayDocument) -> Void)? = nil)
        async -> ActivityContextDayDocument? {
        var input = ActivityContextTrackInput(
            dayStart: s.start, dayEnd: s.end,
            hr: s.hr, gravity: s.gravity, steps: s.stepCounter,
            sleep: s.sleep, inBed: s.inBed,
            // A finished day has been through sleep detection; a live one has not seen the present yet.
            sleepKnownOutsideSessions: !s.isLiveDay,
            workouts: s.workouts, offWrist: s.offWrist)
        // HART's verdicts on the raw motion this phone uploaded, when the server has produced any for the
        // day. They arrive minutes after the strap's own streams; the day builder re-decodes when they do.
        input = ActivityPhoneEvidence.attachingEncoderWindows(input)
        // Expert evidence (ElderNet's gait windows) only as the shared policy allows for the canonical decode: a
        // shadow or candidate row leaves the day exactly as without it.
        let decode = ActivityPhoneEvidence.canonical(input, base: activityDecoderConfig)
        return await ActivityContextWorker.shared.document(
            source: "\(s.sourceKey)@\(decode.config.cacheTag)", input: decode.input, config: decode.config,
            lane: lane, progress: progress)
    }
}

/// The phone's own decode of a day under the shared expert-authority policy (`ActivityExpertSelection`,
/// docs/model-integration/activity-authority.md): the stored expert rows become the policy's sources with the release,
/// pins, prior and input revision each recorded, and the decode the wearer sees is the policy's canonical one. So it
/// uses the same selected evidence and config as the server's published document, and a shadow or candidate row
/// (every row today) decodes exactly as no row. There is no experimental preview on the phone; a candidate arm would
/// have to be decoded and stored apart from this.
///
/// Motion heads have no phone readback: their rows are shadow/candidate only, so the canonical decode could not use
/// them (`motionHeads` is always empty here).
enum ActivityPhoneEvidence {
    struct Decode {
        var input: ActivityContextTrackInput
        var config: ActivityDecoderConfig
        var selection: ActivityExpertSelection
    }

    /// `input` with HART's stored windows for its span attached, and the expert outputs stored beside them (the
    /// transition expert's and the HART-embedded ElderNet windows), as the server's stream day reads them
    /// (`ActivityContextDays.buildStreamDay`). The embedded gait windows are evidence only if the policy admits them.
    static func attachingEncoderWindows(_ input: ActivityContextTrackInput,
                                        store: ActivityEncoderWindowStore = .shared) -> ActivityContextTrackInput {
        guard let encoder = store.windows(from: input.dayStart, to: input.dayEnd) else { return input }
        var out = input
        out.encoderWindows = encoder.windows
        out.imuWindows = encoder.features
        out.encoderId = encoder.encoderId
        out.encoderVersion = encoder.encoderVersion
        out.transitionWindows = encoder.transitions
        out.gaitWindows = encoder.gaitWindows
        return out
    }

    /// The policy's selection over what the stores hold for `input`'s span, and its canonical decode.
    static func canonical(_ input: ActivityContextTrackInput, base: ActivityDecoderConfig,
                          encoders: ActivityEncoderWindowStore = .shared,
                          gait: GaitWindowStore = .shared) -> Decode {
        canonical(input, base: base,
                  revisions: encoders.inputRevisions(from: input.dayStart, to: input.dayEnd),
                  gaitQuality: gait.sources(from: input.dayStart, to: input.dayEnd),
                  embeddedGaitRelease: encoders.embeddedGaitRelease(from: input.dayStart, to: input.dayEnd))
    }

    /// The same with the sources given: `input.gaitWindows` (the HART-embedded ElderNet route) is offered at
    /// `embeddedGaitRelease`, every other expert entry `input` or `base` carries is replaced by what the policy admits
    /// for the canonical decode.
    static func canonical(_ input: ActivityContextTrackInput, base: ActivityDecoderConfig,
                          revisions: [String: Int64], gaitQuality: [GaitQualitySource],
                          embeddedGaitRelease: ActivityReleaseMode = .shadow) -> Decode {
        let selection = ActivityExpertSelection.select(
            revisions: revisions, gaitQuality: gaitQuality, motionHeads: [],
            embeddedGait: EmbeddedGaitSource(windows: input.gaitWindows, releaseMode: embeddedGaitRelease))
        let decode = selection.canonical(input, base: base)
        return Decode(input: decode.input, config: decode.config, selection: selection)
    }
}

/// Runs ActivityContext updates one after another within a lane, off the main actor.
///
/// The Heart rate page can be asked to refresh whenever fresh strap data lands. Without this, a refresh that
/// arrives mid-decode would start a second full decode of the same day alongside the first. Queued behind it
/// instead, the second job finds the first one's result on disk and only decodes what is new.
///
/// There are two lanes. The page the wearer is looking at has its own, so it never waits behind the
/// background pass that decodes up to 120 earlier days for the history screens.
actor ActivityContextWorker {
    static let shared = ActivityContextWorker()

    enum Lane: Hashable {
        /// The Heart rate page: someone is waiting for it.
        case page
        /// Filling in past days for history. Yields to the page.
        case background

        var priority: TaskPriority {
            switch self {
            case .page: return .userInitiated
            case .background: return .utility
            }
        }
    }

    private var tails: [Lane: Task<Void, Never>] = [:]

    func document(source: String, input: ActivityContextTrackInput,
                  config: ActivityDecoderConfig = ActivityDecoderConfig(),
                  files: ActivityContextFileStore = .shared,
                  lane: Lane = .background,
                  progress: (@Sendable (ActivityContextDayDocument) -> Void)? = nil) async -> ActivityContextDayDocument {
        let previous = tails[lane]
        let job = Task.detached(priority: lane.priority) { () -> ActivityContextDayDocument in
            _ = await previous?.value
            let cached = files.load(source: source, dayStart: input.dayStart)
            let (document, how) = ActivityContextDayBuilder.update(
                cached: cached, input: input, now: Int(Date().timeIntervalSince1970), config: config,
                progress: progress)
            if how != .reused { files.save(document, source: source) }
            return document
        }
        tails[lane] = Task { _ = await job.value }
        return await job.value
    }
}

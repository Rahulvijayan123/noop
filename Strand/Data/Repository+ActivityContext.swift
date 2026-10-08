import Foundation
import WhoopProtocol
import StrandAnalytics

extension Repository {
    /// The heart-rate reference the activity decoder judges effort against for this wearer: their typical
    /// resting rate (median of recent nights) and maximum, each used only when plausible. The Heart rate
    /// page and the persisted context both decode with it, so a day is the same day wherever it is read.
    ///
    /// ElderNet's gait evidence joins once the server has sent any (pinned to `GaitWindowStore.Pins`). A day without
    /// its windows decodes exactly as without the entry (`ActivityContextTrackBuilder.effectiveConfig`).
    ///
    /// The wearer's personal profile joins once a fit from their guided calibration runs beat the defaults on
    /// held-out runs (`ActivityPersonalProfileStore`); its tag is part of `cacheTag`, so cached days re-decode.
    ///
    /// This is today's config. A day decodes with `activityDecoderConfig(forDayStart:)`, whose resting rate is
    /// taken as of that day.
    var activityDecoderConfig: ActivityDecoderConfig { activityDecoderConfig(beforeDay: nil) }

    /// The config the local day starting at `dayStart` decodes with: the resting-rate reference is the median of
    /// the latest 14 nights BEFORE that day (D1-14). Not the day's own night either: that sleep ends on the morning
    /// of the day, so its seconds after midnight would be judged against data from hours later, and the decode is
    /// recorded as causal. A day with no earlier night uses the default reference. A past day's context
    /// therefore does not depend on later nights, and its config tag — which the persisted ledger compares —
    /// stays put as new nights arrive, so a moving reference re-derives only the days it actually applies to.
    func activityDecoderConfig(forDayStart dayStart: Int) -> ActivityDecoderConfig {
        activityDecoderConfig(beforeDay: Self.dayString(Date(timeIntervalSince1970: TimeInterval(dayStart))))
    }

    private func activityDecoderConfig(beforeDay: String?) -> ActivityDecoderConfig {
        var config = activityBaseDecoderConfig(beforeDay: beforeDay)
        config.personalProfile = ActivityPersonalProfileStore.shared.adoptedProfile
        return config
    }

    /// `activityDecoderConfig` without the personal profile: what a personal fit is replayed with and has to beat.
    var activityBaseDecoderConfig: ActivityDecoderConfig { activityBaseDecoderConfig(beforeDay: nil) }

    /// `beforeDay` (`yyyy-MM-dd`) limits the resting reference to the nights keyed strictly before it; nil uses
    /// every night.
    private func activityBaseDecoderConfig(beforeDay: String?) -> ActivityDecoderConfig {
        let nights = beforeDay.map { key in days.filter { $0.day < key } } ?? days
        var config = ActivityDecoderConfig.personalized(
            restingHeartRate: ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: nights.map(\.restingHr)),
            maxHeartRate: activityMaxHeartRate)
        if let model = GaitWindowStore.shared.latestModel {
            let evidence = GaitWindowStore.evidenceConfig(model: model)
            if evidence.evidenceRefusal == nil { config.gaitQuality = evidence }
        }
        return config
    }

    /// The tag the persisted context's ledger records for the config the day starting at `dayStart` decodes with
    /// (`activityContextDay.configTag`): the config's own `cacheTag` (heart-rate reference as of the day, Inertia /
    /// ElderNet evidence, personal profile) plus the server's mode for the ElderNet windows the phone decodes with,
    /// which the config does not name. A day stored under another tag is derived again.
    func activityContextLedgerConfigTag(dayStart: Int) -> String {
        let config = activityDecoderConfig(forDayStart: dayStart)
        var tag = config.cacheTag
        if config.gaitQuality != nil, let mode = GaitWindowStore.shared.latestMode {
            tag += "-gm\(mode)"
        }
        return tag
    }

    /// Whether the server's windows (HART, ElderNet) may be attached to a day: they are computed from the raw
    /// motion THIS phone uploads for the active strap, so a day owned by another id (an older strap, the canonical
    /// history) never decodes with them. A day with no owner yet is the active strap's.
    func serverWindowsApply(toDayOwnedBy ownerId: String?) -> Bool {
        ownerId == nil || ownerId == deviceId
    }

    /// The cache key carries the heart-rate reference: a decoder resumed from state built against another
    /// reference would carry that reference's reading of effort into the new one.
    func activityContextSourceKey(dayStart: Int) -> String {
        "\(importedReadIds.joined(separator: "+"))@\(activityDecoderConfig(forDayStart: dayStart).cacheTag)"
    }

    var dayStateSourceKey: String { importedReadIds.joined(separator: "+") }

    /// What is already stored for the day, without decoding anything. The Heart rate page draws this the
    /// moment it opens, then brings it up to date. nil when the day has never been decoded, or was decoded by
    /// an older decoder.
    func cachedActivityContext(dayStart: Date) async -> ActivityContextDayDocument? {
        let start = Int(dayStart.timeIntervalSince1970)
        let source = activityContextSourceKey(dayStart: start)
        return await Task.detached(priority: .userInitiated) {
            ActivityContextFileStore.shared.load(source: source, dayStart: start).flatMap { $0.isCurrent ? $0 : nil }
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
        // Only for a day the active strap owns: the windows describe that strap's uploads (D5-15).
        let windowsApply = serverWindowsApply(toDayOwnedBy: s.ownerId)
        if windowsApply, let encoder = ActivityEncoderWindowStore.shared.windows(from: s.start, to: s.end) {
            input.encoderWindows = encoder.windows
            input.imuWindows = encoder.features
            input.encoderId = encoder.encoderId
            input.encoderVersion = encoder.encoderVersion
            // The experts stored beside the windows, so the phone decodes the same evidence as the
            // server's stream day (ActivityContextDays.buildStreamDay).
            input.transitionWindows = encoder.transitions
            input.gaitWindows = encoder.gaitWindows
        }
        let config = activityDecoderConfig(forDayStart: s.start)
        // ElderNet's gait windows for the same seconds: walking or not, and how (cadence, speed), at 5 s steps.
        if windowsApply, let gait = config.gaitQuality,
           let windows = GaitWindowStore.shared.trackInput(from: s.start, to: s.end, model: gait.model) {
            input.gaitQuality = windows
        }
        return await ActivityContextWorker.shared.document(
            source: "\(s.sourceKey)@\(config.cacheTag)", input: input, config: config,
            lane: lane, progress: progress)
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

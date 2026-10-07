import Foundation
import WhoopProtocol
import StrandAnalytics

extension Repository {
    /// The heart-rate reference the activity decoder judges effort against for this wearer: their typical
    /// resting rate (median of recent nights) and maximum, each used only when plausible. The Heart rate
    /// page and the persisted context both decode with it, so a day is the same day wherever it is read.
    var activityDecoderConfig: ActivityDecoderConfig {
        ActivityDecoderConfig.personalized(
            restingHeartRate: ActivityDecoderConfig.typicalRestingHeartRate(fromNightly: days.map(\.restingHr)),
            maxHeartRate: activityMaxHeartRate)
    }

    /// The cache key carries the heart-rate reference: a decoder resumed from state built against another
    /// reference would carry that reference's reading of effort into the new one.
    var activityContextSourceKey: String {
        "\(importedReadIds.joined(separator: "+"))@\(activityDecoderConfig.cacheTag)"
    }

    var dayStateSourceKey: String { importedReadIds.joined(separator: "+") }

    /// What is already stored for the day, without decoding anything. The Heart rate page draws this the
    /// moment it opens, then brings it up to date. nil when the day has never been decoded, or was decoded by
    /// an older decoder.
    func cachedActivityContext(dayStart: Date) async -> ActivityContextDayDocument? {
        let source = activityContextSourceKey
        let start = Int(dayStart.timeIntervalSince1970)
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
        if let encoder = ActivityEncoderWindowStore.shared.windows(from: s.start, to: s.end) {
            input.encoderWindows = encoder.windows
            input.imuWindows = encoder.features
            input.encoderId = encoder.encoderId
            input.encoderVersion = encoder.encoderVersion
            // The experts stored beside the windows, so the phone decodes the same evidence as the
            // server's stream day (ActivityContextDays.buildStreamDay).
            input.transitionWindows = encoder.transitions
            input.gaitWindows = encoder.gaitWindows
        }
        let config = activityDecoderConfig
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

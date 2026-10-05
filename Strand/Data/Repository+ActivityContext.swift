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

    /// The day's ActivityContext: read from the on-disk cache when it is still valid, extended with whatever
    /// the strap has recorded since, or decoded from the start of the day. Decoding runs off the main actor,
    /// one day at a time (see `ActivityContextWorker`).
    func activityContext(from s: DayStreams) async -> ActivityContextDayDocument? {
        let input = ActivityContextTrackInput(
            dayStart: s.start, dayEnd: s.end,
            hr: s.hr, gravity: s.gravity, steps: s.stepCounter,
            sleep: s.sleep,
            // A finished day has been through sleep detection; a live one has not seen the present yet.
            sleepKnownOutsideSessions: !s.isLiveDay,
            workouts: s.workouts, offWrist: s.offWrist)
        // The cache key carries the heart-rate reference: a decoder resumed from state built against another
        // reference would carry that reference's reading of effort into the new one.
        let config = activityDecoderConfig
        return await ActivityContextWorker.shared.document(
            source: "\(s.sourceKey)@\(config.cacheTag)", input: input, config: config)
    }
}

/// Runs ActivityContext updates strictly one after another, at utility priority.
///
/// The Heart rate page restarts its loading task whenever fresh strap data lands. Without this, a refresh
/// that arrives mid-decode would start a second full decode of the same day alongside the first. Queued
/// behind it instead, the second job finds the first one's result on disk and only decodes what is new.
actor ActivityContextWorker {
    static let shared = ActivityContextWorker()

    private var tail: Task<Void, Never>?

    func document(source: String, input: ActivityContextTrackInput,
                  config: ActivityDecoderConfig = ActivityDecoderConfig(),
                  files: ActivityContextFileStore = .shared) async -> ActivityContextDayDocument {
        let previous = tail
        let job = Task.detached(priority: .utility) { () -> ActivityContextDayDocument in
            _ = await previous?.value
            let cached = files.load(source: source, dayStart: input.dayStart)
            let (document, how) = ActivityContextDayBuilder.update(
                cached: cached, input: input, now: Int(Date().timeIntervalSince1970), config: config)
            if how != .reused { files.save(document, source: source) }
            return document
        }
        tail = Task { _ = await job.value }
        return await job.value
    }
}

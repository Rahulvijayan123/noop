import Foundation

/// The server's `manual-event-context-1` document for one logged event (GET /scores/manual-events/context):
/// what the strap measured and the models concluded before, during and after the event, aligned to its own
/// start and end. Built from the published worker outputs (activity classes, canonical HRV, baselines) and
/// plain summaries of measured samples; see supabase/migrations/20261008100000_manual_event_context.sql.
/// Every field is optional so a newer server document never fails to decode.
struct ManualEventContext: Decodable, Equatable, Sendable {
    enum Status: String, Decodable, Sendable { case running, awaitingData = "awaiting_data", insufficientData = "insufficient_data", ready }

    struct Event: Decodable, Equatable, Sendable {
        var id: UUID?
        var revisionId: UUID?
        var activityKind: String?
        var start: Double?
        var end: Double?
        var point: Bool?
    }
    struct Device: Decodable, Equatable, Sendable { var id: UUID?; var resolution: String? }
    struct HRStats: Decodable, Equatable, Sendable {
        var n: Int?
        var coverage: Double?
        var mean: Double?
        var min: Double?
        var max: Double?
        var p10: Double?
        var p50: Double?
        var p90: Double?
    }
    struct Trace: Decodable, Equatable, Sendable {
        var binS: Int?
        /// [t, mean, min, max, n]
        var bins: [[Double]]?
    }
    struct HeartRate: Decodable, Equatable, Sendable {
        var pre: HRStats?
        var during: HRStats?
        var post: HRStats?
        var trace: Trace?
    }
    struct SeriesValue: Decodable, Equatable, Sendable { var value: Double?; var buckets: Int?; var coverage: Double? }
    struct Series: Decodable, Equatable, Sendable {
        var hrvRmssdMs: SeriesValue?
        var restingHrBpm: SeriesValue?
        var respRateBpm: SeriesValue?
        var steps: SeriesValue?
        var caloriesKcal: SeriesValue?
    }
    struct Windows: Decodable, Equatable, Sendable { var pre: Series?; var during: Series?; var post: Series? }
    struct ActivityClass: Decodable, Equatable, Sendable { var `class`: String; var seconds: Double; var confidence: Double? }
    struct ActivityWindow: Decodable, Equatable, Sendable {
        var coveredS: Double?
        var coverage: Double?
        var source: String?
        var classes: [ActivityClass]?
        var sleepS: Double?
        var offWristS: Double?
    }
    struct Agreement: Decodable, Equatable, Sendable {
        var status: String?
        var activityKind: String?
        var matchedShare: Double?
    }
    struct Activity: Decodable, Equatable, Sendable {
        var pre: ActivityWindow?
        var during: ActivityWindow?
        var post: ActivityWindow?
        var agreement: Agreement?
    }
    struct Baseline: Decodable, Equatable, Sendable { var value: Double?; var buckets: Int? }
    struct Episode: Decodable, Equatable, Sendable {
        var seriesKey: String?
        var state: String?
        var direction: Int?
    }
    struct Baselines: Decodable, Equatable, Sendable {
        var restingHr7d: Baseline?
        var hrvRmssd7d: Baseline?
        var episodes: [Episode]?
    }
    struct Comparisons: Decodable, Equatable, Sendable {
        var hrDuringMinusPreBpm: Double?
        var hrPostMinusPreBpm: Double?
        var hrDuringMinusResting7dBpm: Double?
        var hrvDuringMinus7dMs: Double?
        var hrDuringMinusTypeTypicalBpm: Double?
    }
    struct Watchdog: Decodable, Equatable, Sendable { var start: Double?; var channels: [String]?; var severity: String?; var direction: Int? }
    struct Exposure: Decodable, Equatable, Sendable { var kind: String?; var label: String?; var offsetS: Double? }
    struct Concurrent: Decodable, Equatable, Sendable { var label: String? }
    struct History: Decodable, Equatable, Sendable {
        var previousCount: Int?
        var typicalHrDuringMean: Double?
        var typicalFrom: Int?
    }
    struct Projection: Decodable, Equatable, Sendable { var status: String?; var reason: String? }
    struct Projections: Decodable, Equatable, Sendable { var activityGroundTruth: Projection? }
    struct Quality: Decodable, Equatable, Sendable { var dataThrough: Double?; var missing: [String]? }

    var version: String?
    var status: Status?
    var final: Bool?
    var computedAt: Double?
    var event: Event?
    var device: Device?
    var heartRate: HeartRate?
    var series: Windows?
    var activity: Activity?
    var baselines: Baselines?
    var comparisons: Comparisons?
    var watchdog: [Watchdog]?
    var exposures: [Exposure]?
    var concurrentEvents: [Concurrent]?
    var history: History?
    var projections: Projections?
    var quality: Quality?

    static func decode(_ data: Data) -> ManualEventContext? {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try? decoder.decode(Self.self, from: data)
    }

    /// The classifier's leading class during the event, with its share of the classified time.
    var dominantClass: (name: String, share: Double, confidence: Double?)? {
        guard let during = activity?.during, let covered = during.coveredS, covered > 0,
              let top = during.classes?.first else { return nil }
        return (top.class, top.seconds / covered, top.confidence)
    }

    /// The classifier's class names, as people read them.
    static func title(forClass name: String) -> String {
        switch name {
        case "sitting_desk": "Sitting at a desk"
        case "lying_down": "Lying down"
        case "brisk_walking": "Brisk walking"
        case "light_activity": "Light activity"
        case "vigorous_activity": "Vigorous activity"
        case "off_wrist": "Off wrist"
        default: name.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

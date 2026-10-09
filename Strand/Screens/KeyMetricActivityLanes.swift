import Foundation
import StrandAnalytics

/// The phone's own activity classification, laid under the key-metric readings. The activity decoder already
/// labels every stretch of the day (`ActivityContextDayDocument.runs`), so a reading never needs to be "unclear"
/// just because the server's window carried no label: its time is looked up in the decoder's runs and it takes the
/// label of the run it falls in (the label covering most of its seconds, for a window that spans several).
///
/// A reading stays unclear only where no run covers it, or where the decoder itself had no posture or movement
/// to go on. The server's own wear and sleep verdicts still win when it gave one (this only fills `unclear`).
@MainActor
final class KeyMetricActivityLanes: ObservableObject {
    static let shared = KeyMetricActivityLanes()

    /// Bumped when a day's runs arrive, so a screen showing readings from that day draws again.
    @Published private(set) var epoch = 0

    private var days: [Int: [KeyMetricContextSpan]] = [:]

    /// Read (from the on-disk cache, no decoding) the runs of the local day starting at `dayStart`.
    func load(dayStart: Date, repo: Repository) async {
        let key = Int(dayStart.timeIntervalSince1970)
        guard let document = await repo.cachedActivityContext(dayStart: dayStart) else { return }
        let spans = Self.spans(document.runs)
        guard days[key] != spans else { return }
        days[key] = spans
        Self.publish(days.values.flatMap { $0 })
        epoch &+= 1
    }

    // The reads happen in pure statics on any thread, so the merged lane lives behind a lock.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var merged: [KeyMetricContextSpan] = []

    private static func publish(_ spans: [KeyMetricContextSpan]) {
        lock.lock(); defer { lock.unlock() }
        merged = spans.sorted { $0.start < $1.start }
    }

    nonisolated static var all: [KeyMetricContextSpan] {
        lock.lock(); defer { lock.unlock() }
        return merged
    }

    // MARK: Pure rules

    /// What the wearer was doing during one run: off the wrist, asleep, moving (by the movement head), or the
    /// posture head's most likely body position; still when the wrist was quiet with no posture to name.
    nonisolated static func context(of run: ActivityContextRun) -> KeyMetricWindowContext {
        if run.wear == .offWrist { return .offWrist }
        if run.sleep == .asleep { return .sleep }
        let movement = run.locomotion.values.filter { $0.key != .stationary && $0.key != .unknown }
        let moving = movement.values.reduce(0, +)
        if moving >= 0.5 { return .moving }
        if run.inBed, run.posture[.recumbent] >= 0.3 { return .lyingDown }
        let postures: [(PostureClass, KeyMetricWindowContext)] = [
            (.recumbent, .lyingDown), (.seatedLikely, .sitting), (.uprightStationary, .standing),
        ]
        if let best = postures.max(by: { run.posture[$0.0] < run.posture[$1.0] }), run.posture[best.0] >= 0.3 {
            return best.1
        }
        if run.locomotion[.stationary] >= 0.4 || run.armBehavior[.quiet] >= 0.4 { return .still }
        if moving >= 0.3 { return .moving }
        return .unclear
    }

    /// The runs as a lane, neighbours with one context joined.
    nonisolated static func spans(_ runs: [ActivityContextRun]) -> [KeyMetricContextSpan] {
        var out: [KeyMetricContextSpan] = []
        for run in runs.sorted(by: { $0.start < $1.start }) where run.end > run.start {
            let context = context(of: run)
            if let last = out.last, last.context == context, run.start - last.end <= 30 {
                out[out.count - 1] = KeyMetricContextSpan(start: last.start, end: max(last.end, run.end), context: context)
            } else {
                out.append(KeyMetricContextSpan(start: run.start, end: run.end, context: context))
            }
        }
        return out
    }

    /// The label covering most of `[start, end)`, ignoring stretches the decoder could not name; nil with none.
    nonisolated static func dominant(start: Int, end: Int, in lane: [KeyMetricContextSpan]) -> KeyMetricWindowContext? {
        var seconds: [KeyMetricWindowContext: Int] = [:]
        for span in lane where span.end > start && span.start < max(end, start + 1) && span.context != .unclear {
            seconds[span.context, default: 0] += max(1, min(end, span.end) - max(start, span.start))
        }
        return seconds.max { $0.value < $1.value }?.key
    }

    /// `context` unless it is unclear, in which case the decoder's label for the same time.
    nonisolated static func filled(_ context: KeyMetricWindowContext, start: Int, end: Int,
                                   lane: [KeyMetricContextSpan] = KeyMetricActivityLanes.all) -> KeyMetricWindowContext {
        guard context == .unclear else { return context }
        return dominant(start: start, end: end, in: lane) ?? .unclear
    }

    /// A lane with every unclear stretch re-cut by the decoder's lane, so the bar under the chart agrees with the
    /// dots above it.
    nonisolated static func filled(_ spans: [KeyMetricContextSpan],
                                   lane: [KeyMetricContextSpan] = KeyMetricActivityLanes.all) -> [KeyMetricContextSpan] {
        guard !lane.isEmpty else { return spans }
        var out: [KeyMetricContextSpan] = []
        for span in spans {
            guard span.context == .unclear else { out.append(span); continue }
            var cursor = span.start
            for piece in lane where piece.end > span.start && piece.start < span.end && piece.context != .unclear {
                let a = max(piece.start, span.start), b = min(piece.end, span.end)
                if a > cursor { out.append(KeyMetricContextSpan(start: cursor, end: a, context: .unclear)) }
                out.append(KeyMetricContextSpan(start: max(a, cursor), end: b, context: piece.context))
                cursor = b
            }
            if cursor < span.end { out.append(KeyMetricContextSpan(start: cursor, end: span.end, context: .unclear)) }
        }
        return out
    }
}

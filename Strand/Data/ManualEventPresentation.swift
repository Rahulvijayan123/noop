import Foundation

/// Logged events as the Events tab's `HealthEvent`s, so they drive its latest-reaction card, timeline, event
/// page and recovery history. The curves come from each event's server context (ManualEventContext): heart
/// rate on the context's bins, canonical HRV buckets and wrist movement (milli-g), each point carrying the seconds
/// it stands for. An event without a synced context has no physiology yet and still appears.
enum ManualEventPresentation {
    @MainActor
    static func events(_ center: ManualEventCenter) -> [HealthEvent] {
        guard let owner = center.owner else { return [] }
        let types = Dictionary(center.entries.filter { $0.kind == .eventType }.map { ($0.id, $0) },
                               uniquingKeysWith: { a, _ in a })
        return center.events.compactMap { entry -> HealthEvent? in
            guard let start = entry.start else { return nil }
            // The label is the one logged (renaming a type never relabels history); the icon follows the type.
            let type = entry.typeId.flatMap { types[$0] }
            return HealthEvent(id: entry.id.uuidString, date: start, title: entry.label, detail: entry.note,
                               symbol: type?.symbol ?? entry.symbol, tone: .normal, origin: .reported,
                               physiology: physiology(entry, center.contexts[entry.id]), recovery: nil,
                               typeId: entry.typeId, ownerId: owner, deviceId: entry.deviceId, endDate: entry.end)
        }
        .sorted { $0.date > $1.date }
    }

    /// The context's traces as event physiology, or nil when there is nothing measured to draw.
    static func physiology(_ entry: ManualEventEntry, _ context: ManualEventContext?) -> EventPhysiology? {
        guard let context, let start = entry.start, let bins = context.heartRate?.trace?.bins else { return nil }
        let binSeconds = Double(context.heartRate?.trace?.binS ?? 60)
        func points(_ rows: [[Double]]?, value: Int, support: (([Double]) -> Double)) -> [PhysiologyPoint] {
            (rows ?? []).compactMap { row in
                guard row.count > value, row[value].isFinite else { return nil }
                return PhysiologyPoint(time: Date(timeIntervalSince1970: row[0]), value: row[value], supportSeconds: support(row))
            }
        }
        let metrics = [
            PhysiologyMetric(name: "Heart rate", unit: "bpm", higherIsBetter: false,
                             points: points(bins, value: 1) { _ in binSeconds }),
            PhysiologyMetric(name: "HRV", unit: "ms", higherIsBetter: true,
                             points: points(context.traces?.hrvRmssdMs, value: 1) { $0.count > 2 ? $0[2] : 300 }),
            // Milli-g: the tab formats whole numbers on a 20-unit minimum axis, where 0.03 g would read "0".
            // "Higher is better: false" makes the page lead with the peak, the reading that matters here.
            PhysiologyMetric(name: "Movement", unit: "mg", higherIsBetter: false,
                             points: points(context.traces?.movementG?.map { row in
                                 row.enumerated().map { $0.offset == 1 ? $0.element * 1000 : $0.element }
                             }, value: 1) { $0.count > 2 ? $0[2] : binSeconds }),
        ].filter { !$0.points.isEmpty }
        guard !metrics.isEmpty else { return nil }
        let pad: TimeInterval = 1800
        let end = entry.end ?? Date(timeIntervalSince1970: context.event?.end ?? Date().timeIntervalSince1970)
        let windowEnd = entry.end == nil ? Date() : end.addingTimeInterval(pad)
        return EventPhysiology(metrics: metrics, windowStart: start.addingTimeInterval(-pad), eventStart: start,
                               eventEnd: max(start, min(end, windowEnd)), windowEnd: windowEnd)
    }
}

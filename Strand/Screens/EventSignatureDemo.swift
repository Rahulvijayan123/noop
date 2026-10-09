#if DEBUG
import SwiftUI
import StrandDesign

/// Screenshot fixtures for the signature card (`--demo-screen eventsignature` / `eventsignaturenone`). Sample
/// numbers in an in-memory account with no cloud URL; nothing here is uploaded or read from a server.
struct EventSignatureDemo: View {
    enum Fixture { case emerging, noReliable }
    @StateObject private var manual: ManualEventCenter
    @StateObject private var detection: EventDetectionCenter
    private let type: ManualEventEntry

    init(fixture: Fixture = .emerging) {
        let identity = CloudPushIdentity(ownerId: "11111111-1111-4111-8111-111111111111",
            sourceId: "33333333-3333-4333-8333-333333333333", tokenId: "fixture", uploadToken: "fixture")
        let manual = ManualEventCenter(store: try! ManualEventStore(path: ":memory:"), automaticallySync: false,
            identity: { identity }, endpoint: { nil })
        manual.bindAccount()
        let type = ManualEventEntry(id: UUID(uuidString: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")!, kind: .eventType,
            label: "Absence", symbol: "brain.head.profile", favorite: true, activityKind: "other")
        _ = manual.save(type, for: identity.ownerId)
        let now = Date().timeIntervalSince1970
        for day in 0..<(fixture == .emerging ? 8 : 7) {
            let start = now - Double(day) * 86_400 - 3_600 - Double(day % 3) * 5_400
            _ = manual.save(ManualEventEntry(id: UUID(), kind: .event, label: type.label, symbol: type.symbol, typeId: type.id,
                startUnixSeconds: start, endUnixSeconds: start + 40, activityKind: "other",
                onsetUncertaintyMinutes: day % 2 == 0 ? 5 : 15), for: identity.ownerId)
        }
        _ = manual.save(.observation(start: Date(timeIntervalSince1970: now - 5 * 3600), end: Date(timeIntervalSince1970: now - 3600),
                                     note: "At home all afternoon"), for: identity.ownerId)
        let detection = EventDetectionCenter(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            automaticallySync: false, syncManual: {}, identity: { identity }, endpoint: { nil })
        detection.bindAccount()
        let json = fixture == .emerging ? Self.emerging(type: type.id, now: now) : Self.noReliable(type: type.id, now: now)
        if let data = try? JSONSerialization.data(withJSONObject: json), let report = SignatureReport.decode(data) {
            detection.showSignatureForPreview(report, for: type.id)
        }
        self.type = type
        _manual = StateObject(wrappedValue: manual); _detection = StateObject(wrappedValue: detection)
    }

    var body: some View {
        // `--demo-signature-offset N` shows the card alone, moved up N points, to capture its lower part.
        if let offset = DemoLaunch.intArg("--demo-signature-offset") {
            VStack(alignment: .leading) {
                EventSignatureCard(report: detection.signatures[type.id],
                                   loggedEvents: manual.events.filter { $0.typeId == type.id }.count)
                Spacer(minLength: 0)
            }
            .padding(20).offset(y: -CGFloat(offset))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top).clipped()
            .background(StrandPalette.surfaceBase)
        } else {
            DetectorDetailSheet(type: type, owner: manual.owner, detection: detection, manual: manual)
        }
    }

    /// A heart-rate profile as JSON: about 64 bpm before, a rise of `peak` bpm 3 minutes after onset, then recovery.
    private static func profile(peak: Double, spread: Double) -> String {
        let lags = Array(-30...30).map(Double.init)
        var mean: [Double] = [], low: [Double] = [], high: [Double] = []
        for t in lags {
            let base: Double = 64 + sin(t / 7) * 0.8
            let rise: Double = t >= 0 ? peak * (t / 3) * exp(1 - t / 3) : 0
            let value = ((base + rise) * 10).rounded() / 10
            let width: Double = spread * (t >= 0 ? 1 + 0.4 * exp(-t / 6) : 1)
            mean.append(value); low.append(((value - width) * 10).rounded() / 10); high.append(((value + width) * 10).rounded() / 10)
        }
        let channel: [String: Any] = ["unit": "bpm", "mean": mean, "ci_lo": low, "ci_hi": high]
        let object: [String: Any] = ["lags": [-30, 30], "channels": ["hr": channel]]
        return String(decoding: (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8), as: UTF8.self)
    }

    private static func fill(_ template: String, type: UUID, now: Double, profile: String) -> [String: Any] {
        let text = template.replacingOccurrences(of: "__TYPE__", with: type.uuidString.lowercased())
            .replacingOccurrences(of: "__GENERATED__", with: String(Int(now)))
            .replacingOccurrences(of: "__CUTOFF__", with: String(Int(now - 2 * 86_400)))
            .replacingOccurrences(of: "__PROFILE__", with: profile)
        return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any] ?? [:]
    }

    static func emerging(type: UUID, now: Double) -> [String: Any] {
        fill("""
        {"version": "signature-report-1", "type_id": "__TYPE__", "generated_at": __GENERATED__,
         "engine": {"version": "sig-4", "normalization": "context"}, "status": "emerging",
         "evidence": {"events": 9, "event_days": 6, "observation_hours": 12.5, "confirmed_detections": 0,
                      "rejected_detections": 0, "negative_intervals": 1, "monitored_days": 9.1,
                      "events_used": 8, "events_dropped": {"fewer than 3 matched controls": 1}},
         "signatures": [{"id": "s1", "label": "all events", "events": 8, "event_days": 6, "event_ids": [],
            "p_value": 0.03, "p_min_possible": 0.031, "replicated": false,
            "context_at_onset": {"asleep": 0.0, "still": 0.62, "walking": 0.12, "active": 0.25, "unknown": 0.01},
            "findings": [
              {"channel": "hr", "unit": "SD", "basis": "joint", "window": [0, 5], "direction": "up", "change": 3.1,
               "change_ci": [2.0, 4.2], "change_z": 3.1, "consistency": 0.875, "events_with_data": 8,
               "combined_z": 3.1, "combined_z_ci": [2.0, 4.2],
               "channels": [{"channel": "hr", "weight": 0.8, "change_z": 2.8, "change": 18.2, "unit": "bpm"},
                            {"channel": "motion", "weight": 0.5, "change_z": 1.9, "change": 0.02, "unit": "g"}],
               "text": "Heart rate rose (+2.8 SD) and movement rose (+1.9 SD) together from before onset, within 5 min after onset, in 7 of 8 events (combined +3.1 SD)."},
              {"channel": "hr", "unit": "bpm", "window": [0, 5], "direction": "up", "change": 18.2, "change_ci": [12.1, 24.0],
               "change_z": 2.1, "consistency": 0.875, "events_with_data": 8,
               "text": "Heart rate rose 18 bpm (12–24) from before onset, within 5 min after onset, in 7 of 8 events.",
               "basis": "change_from_before", "movement_accompanied": false},
              {"channel": "ln_rmssd", "unit": "ms", "window": [5, 15], "direction": "down", "change": -9.4, "change_ci": [-15.2, -3.1],
               "change_z": -1.2, "consistency": 0.75, "events_with_data": 8,
               "text": "HRV was 9 ms (3–15) below what is usual for the activity and time of day from 5 to 15 min after onset in 6 of 8 events.",
               "basis": "vs_usual_for_context"}],
            "profile": __PROFILE__}],
         "detectability": {"d": 1.8, "d_ci": [1.1, 2.4], "expected_recall": {"0.5": 0.12, "1": 0.30, "2": 0.45},
                           "expected_recall_ci": {"0.5": [0.03, 0.40], "1": [0.10, 0.62], "2": [0.18, 0.74]},
                           "assessment": "too_weak_for_alerts"},
         "retrospective": {"evaluated": true, "training_cutoff": __CUTOFF__, "method": "logistic", "events": 5, "recall": 0.6, "recall_ci": [0.23, 0.88],
                           "false_alerts_per_day": 0.8, "false_alerts_ci": [0.2, 2.1], "latency_median_min": 3,
                           "monitored_days": 4.2, "baselines": {"hr_rule_raw": {}}, "promoted": false,
                           "reason": "Alerts are disabled in this phase."},
         "data_quality": {"monitored_fraction": 0.82, "channels": {"hr": 0.97, "hrv": 0.4, "resp": 0.0, "temp": 0.95, "motion": 0.3},
                          "notes": ["Breathing rate is not available for this strap yet.",
                                    "HRV is measured only when the wrist is still, so it is missing for 60% of the time."]},
         "limitations": ["Based on 8 events on 6 days. The pattern may change as more events are logged.",
                         "Heart rate also rises with movement; each event is compared with times of similar activity."],
         "alerts_enabled": false, "future_field": {"kept": "ignored"}}
        """, type: type, now: now - 1_800, profile: profile(peak: 18, spread: 3.2))
    }

    static func noReliable(type: UUID, now: Double) -> [String: Any] {
        fill("""
        {"version": "signature-report-1", "type_id": "__TYPE__", "generated_at": __GENERATED__,
         "engine": {"version": "sig-4", "normalization": "context"}, "status": "no_reliable_signature",
         "evidence": {"events": 7, "event_days": 7, "observation_hours": 4.0, "confirmed_detections": 0,
                      "rejected_detections": 0, "negative_intervals": 0, "monitored_days": 11.3},
         "signatures": [{"id": "s1", "label": "all events", "events": 7, "event_days": 7, "p_value": 0.41,
            "p_min_possible": 0.016, "replicated": false, "findings": [], "profile": __PROFILE__}],
         "detectability": {"d": 0.4, "d_ci": [0.0, 0.9], "expected_recall": {"0.5": 0.01, "1": 0.02, "2": 0.04},
                           "assessment": "too_weak_for_alerts"},
         "retrospective": {"evaluated": false, "reason": "No reliable signature to evaluate."},
         "data_quality": {"monitored_fraction": 0.64, "channels": {"hr": 0.91, "hrv": 0.2, "resp": 0.0, "temp": 0.9, "motion": 0.4},
                          "notes": ["The strap was off the wrist for 2 of the 7 events."]},
         "limitations": ["A signature may still appear with more events, or this event may not change these readings."],
         "alerts_enabled": false}
        """, type: type, now: now - 7_200, profile: profile(peak: 1.5, spread: 4.5))
    }
}
#endif

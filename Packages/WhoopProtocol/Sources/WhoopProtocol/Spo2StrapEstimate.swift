import Foundation

/// The 5/MG strap's SpO₂ estimate (`@82`) as it travels to the cloud.
///
/// The strap computes its own SpO₂ percentage and writes it into the v18 aux byte at `@82`, but only in
/// 30-second windows while it believes the wearer is asleep and still, so a night holds a few hundred
/// readings and a day holds none. The phone banks every second of it locally (`V18AuxSample`); this is the
/// shape a reading takes on the wire so the server can keep and reduce the same readings:
/// one `event` row per in-band second, `kind` = `eventKind`, `{"pct": 97}` as its payload.
///
/// A strap estimate, NOT a validated blood-oxygen measurement: independent checks of it disagree (see
/// `AnalyticsEngine.nightlySpo2CandidateMean`), so it is carried as the byte the strap reported and
/// labelled that way wherever it is shown. It never feeds a score.
public enum Spo2StrapEstimate {
    /// `noop_events.kind` of one reading. Event rows are keyed by `(ts, kind)`, so a second carries one.
    public static let eventKind = "SPO2_STRAP_EST"

    /// The in-band window, the same one the decoder applies when it emits `spo2_candidate_82`: sub-70
    /// nonzero bytes are diagnostic codes and bit-7 values are saturation sentinels, so neither is a percentage.
    public static let band = 70...100

    public struct Reading: Equatable, Sendable {
        public let ts: Int
        public let percent: Int
        public init(ts: Int, percent: Int) { self.ts = ts; self.percent = percent }
    }

    /// The in-band readings of `aux`, oldest first, one per second.
    public static func readings(from aux: [V18AuxSample]) -> [Reading] {
        var bySecond: [Int: Int] = [:]
        for sample in aux {
            guard let value = sample.auxByte82, band.contains(value) else { continue }
            bySecond[sample.ts] = value
        }
        return bySecond.keys.sorted().map { Reading(ts: $0, percent: bySecond[$0] ?? 0) }
    }

    public static func payloadJSON(percent: Int) -> String { "{\"pct\":\(percent)}" }

    private struct Payload: Decodable { let pct: Int }

    /// The percentage in an event payload, or nil when it is absent, not a whole number, or out of band.
    public static func percent(fromPayloadJSON json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              band.contains(payload.pct) else { return nil }
        return payload.pct
    }
}

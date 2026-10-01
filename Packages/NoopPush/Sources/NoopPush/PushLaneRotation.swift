import Foundation

/// Stable scheduling positions; these never replace a source cursor or a prepared selection.
enum PushLaneRotation {
    static let fingerprintVersion = "fresh-history-raw-rounds-v2"
    static let appendOrder: [PushAppendTable] = [.hrSample, .gravitySample, .rrInterval, .rrPacketProvenance,
        .standardHRReceipt, .event, .battery, .spo2Sample, .skinTempSample, .respSample,
        .stepSample, .sleepStateSample, .ppgHrSample]

    static let lanes: [(PushSourceCommit.Kind, String)] = {
        let otherFresh = appendOrder.filter { $0 != .hrSample && $0 != .gravitySample }
        let history: [(PushSourceCommit.Kind, String)] = appendOrder.map { (.append, $0.wireName) }
            + [PushMutableTable.dailyMetric, .sleepSession, .workout, .journal].map { (.mutable, $0.wireName) }
            + PushBinaryTable.allCases.map { (.binary, $0.wireName) }
        let raw: (PushSourceCommit.Kind, String) = (.binary, PushBinaryTable.rawBatch.wireName)
        var rounds = history.flatMap { [$0, raw] }
        // Whole fresh-table cycles preserve the bound across a saved-position wrap too.
        while rounds.count % otherFresh.count != 0 { rounds.append(raw) }
        return rounds.enumerated().flatMap { index, old in
            [(.freshAppend, PushAppendTable.hrSample.wireName),
             (.freshAppend, PushAppendTable.gravitySample.wireName),
             (.freshAppend, otherFresh[index % otherFresh.count].wireName), old]
        }
    }()
}

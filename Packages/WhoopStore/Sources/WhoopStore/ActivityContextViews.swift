import Foundation

/// SQL views that attach "what was the wearer doing" to physiological samples at read time.
///
/// The activity label is never copied onto raw samples: a sample's context is the one
/// `activityContextInterval` row whose half-open `[startTs, endTs)` covers the sample's `ts`, found with an
/// as-of lookup on that table's primary key (`MAX(startTs) <= ts`, then checked against `endTs`). A sample in
/// a gap — the strap was off, the phone had not decoded that stretch yet — still appears, with every `ctx*`
/// column NULL, so a downstream `GROUP BY ctxClass` shows the gap instead of silently dropping it.
///
/// Which device's intervals: the day's OWNER. The materializer stores each local day's context under one id
/// (the first raw id holding heart rate that day) while the streams are read across every raw id, so a
/// sample recorded under another id (a strap swap, a re-paired strap, the canonical history) must still join
/// the context that describes its second. The owner is the ledger row (`activityContextDay`) covering the
/// sample — the sample's own device's when it has one, else whichever device's does — and the sample's own
/// id when no ledger covers it. The same day's `decoderVersion` rides along as `ctxDecoderVersion`, and
/// `ctxProvisional` is 1 while that context can still change (the day was live or its sleep unsettled when
/// it was decoded, or the interval reaches past where decoding had data), 0 once it is final.
///
/// Every view keeps the source table's columns under their own names (minus the `synced` upload flag) and
/// adds the same `ctx*` columns, so
///
///     SELECT ctxClass, COUNT(*), AVG(bpm)
///     FROM hrSampleCtx WHERE deviceId = ? AND ts BETWEEN ? AND ? GROUP BY ctxClass
///
/// is one statement and `deviceId = ? AND ts BETWEEN ? AND ?` is still answered from the source table's
/// primary key (pinned by a query-plan test).
public enum ActivityContextViews {
    struct Spec: Sendable {
        let view: String
        let table: String
        let columns: [String]
    }

    static let specs: [Spec] = [
        Spec(view: "hrSampleCtx", table: "hrSample",
             columns: ["deviceId", "ts", "bpm"]),
        Spec(view: "rrIntervalCtx", table: "rrInterval",
             columns: ["deviceId", "ts", "rrMs", "seq", "ord", "srcChannel", "tsSuspect"]),
        Spec(view: "ppgHrSampleCtx", table: "ppgHrSample",
             columns: ["deviceId", "ts", "bpm", "conf"]),
        Spec(view: "spo2SampleCtx", table: "spo2Sample",
             columns: ["deviceId", "ts", "red", "ir"]),
        Spec(view: "skinTempSampleCtx", table: "skinTempSample",
             columns: ["deviceId", "ts", "raw", "aux1Raw", "aux2Raw"]),
        Spec(view: "respSampleCtx", table: "respSample",
             columns: ["deviceId", "ts", "raw"]),
        Spec(view: "gravitySampleCtx", table: "gravitySample",
             columns: ["deviceId", "ts", "x", "y", "z", "dynAccel"]),
        Spec(view: "stepSampleCtx", table: "stepSample",
             columns: ["deviceId", "ts", "counter", "activityClass"]),
    ]

    /// Per-day seconds spent in each canonical class, for materialized days only.
    public static let dayClassView = "activityContextDayClass"

    /// Every `*Ctx` view, one per physiological stream table.
    public static var sampleViewNames: [String] { specs.map(\.view) }

    /// Context columns added to each view, in order. Mirrors the `activityContextInterval` columns they come from.
    public static let contextColumns: [String] = [
        "ctxStartTs", "ctxEndTs", "ctxClass", "ctxConfidence", "ctxRunnerUp", "ctxEvidenceQuality",
        "ctxPosture", "ctxLocomotion", "ctxArmBehavior", "ctxSleep", "ctxWear", "ctxIntensity",
        "ctxDeviceId", "ctxDecoderVersion", "ctxProvisional",
    ]

    private static let contextProjection = """
        c.startTs AS ctxStartTs, c.endTs AS ctxEndTs, c.activityClass AS ctxClass, \
        c.confidence AS ctxConfidence, c.runnerUp AS ctxRunnerUp, c.evidenceQuality AS ctxEvidenceQuality, \
        c.posture AS ctxPosture, c.locomotion AS ctxLocomotion, c.armBehavior AS ctxArmBehavior, \
        c.sleepState AS ctxSleep, c.wearState AS ctxWear, c.intensity AS ctxIntensity, \
        c.deviceId AS ctxDeviceId, \
        CASE WHEN c.startTs IS NULL THEN NULL ELSE d.decoderVersion END AS ctxDecoderVersion, \
        CASE WHEN c.startTs IS NULL THEN NULL \
             WHEN d.finality = 'final' AND c.endTs <= COALESCE(d.dataThrough, d.dayStart) THEN 0 \
             ELSE 1 END AS ctxProvisional
        """

    /// The device whose ledger covers `x.ts`: the sample's own when it has one, else any (the newest day
    /// starting at or before the sample), else the sample's own id. Every lookup is an as-of seek on an index.
    static func ownerExpression(_ x: String) -> String {
        """
        COALESCE(\
        (SELECT o.deviceId FROM activityContextDay o WHERE o.deviceId = \(x).deviceId AND o.dayEnd > \(x).ts \
        AND o.dayStart = (SELECT MAX(p.dayStart) FROM activityContextDay p \
        WHERE p.deviceId = \(x).deviceId AND p.dayStart <= \(x).ts)), \
        (SELECT o.deviceId FROM activityContextDay o WHERE o.dayEnd > \(x).ts \
        AND o.dayStart = (SELECT MAX(p.dayStart) FROM activityContextDay p WHERE p.dayStart <= \(x).ts) \
        ORDER BY o.deviceId LIMIT 1), \
        \(x).deviceId)
        """
    }

    static func createStatement(for spec: Spec) -> String {
        let inner = spec.columns.map { "x.\($0) AS \($0)" }.joined(separator: ", ")
        let projection = spec.columns.map { "s.\($0) AS \($0)" }.joined(separator: ", ")
        return """
            CREATE VIEW IF NOT EXISTS \(spec.view) AS
            SELECT \(projection), \(contextProjection)
            FROM (SELECT \(inner), \(ownerExpression("x")) AS ctxOwner FROM \(spec.table) x) s
            LEFT JOIN activityContextInterval c
              ON c.deviceId = s.ctxOwner
             AND c.startTs = (SELECT MAX(i.startTs) FROM activityContextInterval i
                              WHERE i.deviceId = s.ctxOwner AND i.startTs <= s.ts)
             AND s.ts < c.endTs
            LEFT JOIN activityContextDay d
              ON d.deviceId = s.ctxOwner
             AND d.dayStart = (SELECT MAX(q.dayStart) FROM activityContextDay q
                               WHERE q.deviceId = s.ctxOwner AND q.dayStart <= s.ts)
             AND s.ts < d.dayEnd
            """
    }

    private static let dayClassStatement = """
        CREATE VIEW IF NOT EXISTS \(dayClassView) AS
        SELECT d.deviceId AS deviceId, d.day AS day, c.activityClass AS activityClass,
               SUM(c.endTs - c.startTs) AS seconds, COUNT(*) AS intervals
        FROM activityContextDay d
        JOIN activityContextInterval c
          ON c.deviceId = d.deviceId AND c.startTs >= d.dayStart AND c.startTs < d.dayEnd
        GROUP BY d.deviceId, d.day, c.activityClass
        """

    /// Each stored interval with the number of the decoder's transition events flagged inside its half-open
    /// `[startTs, endTs)`: the short real changes of position the interval builder may have folded away.
    public static let intervalTransitionsView = "activityContextIntervalTransitions"

    private static let intervalTransitionsStatement = """
        CREATE VIEW IF NOT EXISTS \(intervalTransitionsView) AS
        SELECT c.deviceId AS deviceId, c.startTs AS startTs, c.endTs AS endTs, c.activityClass AS activityClass,
               (SELECT COUNT(*) FROM activityContextTransition t
                WHERE t.deviceId = c.deviceId AND t.ts >= c.startTs AND t.ts < c.endTs) AS transitionEvents
        FROM activityContextInterval c
        """

    /// The statements the latest migration that touches the views runs (`v50-activity-context-provenance`),
    /// and the ones any later migration that rebuilds a stream table must re-run after dropping the views.
    /// The transitions view reads `activityContextTransition`, so it exists from v50 on.
    public static var createStatements: [String] {
        specs.map(createStatement(for:)) + [dayClassStatement, intervalTransitionsStatement]
    }

    /// The views exactly as `v48-activity-context` created them (same-device join, twelve `ctx*` columns), frozen
    /// so that migration keeps running against the v48 schema; v50 drops and replaces them.
    static var v48CreateStatements: [String] {
        let v48Projection = """
            c.startTs AS ctxStartTs, c.endTs AS ctxEndTs, c.activityClass AS ctxClass, \
            c.confidence AS ctxConfidence, c.runnerUp AS ctxRunnerUp, c.evidenceQuality AS ctxEvidenceQuality, \
            c.posture AS ctxPosture, c.locomotion AS ctxLocomotion, c.armBehavior AS ctxArmBehavior, \
            c.sleepState AS ctxSleep, c.wearState AS ctxWear, c.intensity AS ctxIntensity
            """
        return specs.map { spec in
            let projection = spec.columns.map { "s.\($0) AS \($0)" }.joined(separator: ", ")
            return """
                CREATE VIEW IF NOT EXISTS \(spec.view) AS
                SELECT \(projection), \(v48Projection)
                FROM \(spec.table) s
                LEFT JOIN activityContextInterval c
                  ON c.deviceId = s.deviceId
                 AND c.startTs = (SELECT MAX(i.startTs) FROM activityContextInterval i
                                  WHERE i.deviceId = s.deviceId AND i.startTs <= s.ts)
                 AND s.ts < c.endTs
                """
        } + [dayClassStatement]
    }

    /// `DROP VIEW` for every view, for migrations that rebuild a table the views read.
    public static var dropStatements: [String] {
        (sampleViewNames + [dayClassView, intervalTransitionsView]).map { "DROP VIEW IF EXISTS \($0)" }
    }
}

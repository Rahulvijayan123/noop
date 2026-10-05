import Foundation

/// SQL views that attach "what was the wearer doing" to physiological samples at read time.
///
/// The activity label is never copied onto raw samples: a sample's context is the one
/// `activityContextInterval` row whose half-open `[startTs, endTs)` covers the sample's `ts` for the same
/// device, found with an as-of lookup on that table's primary key (`MAX(startTs) <= ts`, then checked
/// against `endTs`). A sample in a gap — the strap was off, the phone had not decoded that stretch yet —
/// still appears, with every `ctx*` column NULL, so a downstream `GROUP BY ctxClass` shows the gap
/// instead of silently dropping it.
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
    ]

    private static let contextProjection = """
        c.startTs AS ctxStartTs, c.endTs AS ctxEndTs, c.activityClass AS ctxClass, \
        c.confidence AS ctxConfidence, c.runnerUp AS ctxRunnerUp, c.evidenceQuality AS ctxEvidenceQuality, \
        c.posture AS ctxPosture, c.locomotion AS ctxLocomotion, c.armBehavior AS ctxArmBehavior, \
        c.sleepState AS ctxSleep, c.wearState AS ctxWear, c.intensity AS ctxIntensity
        """

    static func createStatement(for spec: Spec) -> String {
        let projection = spec.columns.map { "s.\($0) AS \($0)" }.joined(separator: ", ")
        return """
            CREATE VIEW IF NOT EXISTS \(spec.view) AS
            SELECT \(projection), \(contextProjection)
            FROM \(spec.table) s
            LEFT JOIN activityContextInterval c
              ON c.deviceId = s.deviceId
             AND c.startTs = (SELECT MAX(i.startTs) FROM activityContextInterval i
                              WHERE i.deviceId = s.deviceId AND i.startTs <= s.ts)
             AND s.ts < c.endTs
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

    /// The statements `v48-activity-context` runs, and the ones any later migration that rebuilds a stream
    /// table must re-run after dropping the views.
    public static var createStatements: [String] {
        specs.map(createStatement(for:)) + [dayClassStatement]
    }

    /// `DROP VIEW` for every view, for migrations that rebuild a table the views read.
    public static var dropStatements: [String] {
        (sampleViewNames + [dayClassView]).map { "DROP VIEW IF EXISTS \($0)" }
    }
}

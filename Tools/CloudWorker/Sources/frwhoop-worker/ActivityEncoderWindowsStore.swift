import Foundation
import StrandAnalytics

/// HART's per-window output for one UTC day, kept in `activity_encoder_windows` so the phone's decoder (and
/// this worker's stream-day decoder) can use it. The raw-IMU lane writes it next to the v1 epochs and the day
/// document; the format is the shared `ActivityEncoderWindowSet` (`hart-windows-1`).
enum ActivityEncoderWindowsStore {

    /// The decoder's view of a job's windows, limited to the ones that END inside the UTC day: the decoder
    /// keys a window by its end second, so that is the day the window belongs to.
    static func windowSet(windows: [ActivityPythonService.WindowPrediction], dayStart: Int, dayEnd: Int,
                          modelVersion: String,
                          transitionVersion: String = "none",
                          preprocessingVersion: String = "unknown") -> ActivityEncoderWindowSet {
        let encoderId = windows.contains { !$0.baseline } ? "hart" : "baseline"
        // Transition windows are optional: the version marker "none" is the documented
        // "no expert ran" state and produces an empty list, exactly like a set built
        // before the expert existed (the persisted doc then omits the `t` rows).
        let transitions: [ActivityTransitionWindow]
        if transitionVersion == "none" {
            transitions = []
        } else {
            transitions = windows.compactMap {
                ActivityContextDays.transitionWindow($0, modelVersion: transitionVersion,
                                                     preprocessingVersion: preprocessingVersion)
            }
        }
        return ActivityEncoderWindowSet(
            encoderId: encoderId, encoderVersion: modelVersion,
            windows: windows.compactMap(ActivityContextDays.encoderWindow),
            features: windows.compactMap(ActivityContextDays.imuFeatures),
            transitions: transitions)
            .clipped(from: dayStart, to: dayEnd)
    }

    /// The `publish_activity_encoder_windows` payload.
    static func payload(set: ActivityEncoderWindowSet, day: String, dayStart: Int,
                        preprocessingVersion: String) throws -> String {
        var envelope: [String: Any] = [
            "day": day,
            "encoder_id": set.encoderId,
            "model_version": set.encoderVersion,
            "preprocessing_version": preprocessingVersion,
            "windows": set.jsonObject(dayStart: dayStart),
        ]
        if !set.features.isEmpty { envelope["feature_schema"] = ActivityContextVersions.featureSchema }
        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkerError.malformed("activity windows encoding failed")
        }
        return text
    }

    /// Write through the fenced RPC under a savepoint, like the day document: a rejection (or a database the
    /// migration has not reached yet) leaves the surrounding transaction usable for the v1 publish. Only a
    /// lost connection propagates.
    static func publish(db: PostgresClient, token: String, revision: Int64,
                        payload: String) throws -> ActivityContextDays.PublishOutcome {
        do {
            let out = try db.isolatingFailures {
                try db.callFunctionForJSONRaw(
                    "SELECT public.publish_activity_encoder_windows($1::uuid,$2::bigint,$3::jsonb)::text",
                    [token, String(revision), payload])
            }
            if let stored = Int64(out ?? ""), stored > 0 { return .stored(revision: stored) }
            return .fenced
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            throw e
        } catch {
            return .rejected(ActivityContextDays.safeReason(error))
        }
    }

    /// The stored windows of one UTC day, or nil when there are none (or the table does not exist yet).
    static func load(db: PostgresClient, userId: String, deviceId: String, day: String) throws -> ActivityEncoderWindowSet? {
        let rows: [[String: String]]
        do {
            rows = try db.isolatingFailures {
                try db.query("""
                    select encoder_id, model_version, windows::text as windows
                    from public.activity_encoder_windows
                    where user_id=$1::uuid and device_id=$2::uuid and day=$3::date
                      and algorithm_version='hart-activity-1'
                    """, [userId, deviceId, day])
            }
        } catch let e as PostgresClient.Error where e.kind == .connectionLost {
            throw e
        } catch {
            return nil
        }
        guard let row = rows.first, let text = row["windows"], let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return ActivityEncoderWindowSet.decode(object, encoderId: row["encoder_id"] ?? "hart",
                                               encoderVersion: row["model_version"] ?? "unknown")
    }
}

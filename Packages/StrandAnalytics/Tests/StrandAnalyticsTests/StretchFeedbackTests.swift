import XCTest
@testable import StrandAnalytics

final class StretchFeedbackTests: XCTestCase {

    private let t0 = 1_760_000_000

    private func make(_ verdict: StretchVerdict, kind: StretchKind = .activityContext, start: Int? = nil,
                      corrected: StretchCorrection? = nil, note: String? = nil) -> StretchFeedback {
        StretchFeedback(kind: kind, startTs: start ?? t0, endTs: (start ?? t0) + 600, deviceId: "my-whoop",
                        predictedLabel: "Walking", predictedClass: "walking", predictedConfidence: 0.8,
                        verdict: verdict, correctedLabel: corrected, note: note,
                        now: Date(timeIntervalSince1970: 1_760_000_100))
    }

    func testTheKeyNamesTheKindAndTheStart() {
        XCTAssertEqual(StretchFeedback.key(kind: .activityContext, start: 42), "activity_context:42")
        XCTAssertEqual(make(.correct, kind: .strapState).stretchKey, "strap_state:\(t0)")
    }

    func testACorrectionOnlySurvivesAWrongVerdict() {
        XCTAssertNil(make(.correct, corrected: .sitting).correctedLabel)
        XCTAssertEqual(make(.incorrect, corrected: .sitting).correctedLabel, .sitting)
    }

    func testNotesAreTrimmedAndBounded() {
        XCTAssertNil(make(.correct, note: "   \n ").note)
        XCTAssertEqual(make(.correct, note: "  on the sofa ").note, "on the sofa")
        let long = String(repeating: "x", count: 500)
        XCTAssertEqual(make(.correct, note: long).note?.count, StretchFeedback.maxNoteLength)
    }

    func testRevisingKeepsTheRecordButMovesTheClock() {
        let first = make(.correct)
        XCTAssertTrue(first.needsSync)
        var synced = first
        synced.syncedAt = first.updatedAt
        XCTAssertFalse(synced.needsSync)

        let second = synced.revised(verdict: .incorrect, correctedLabel: .cycling, note: "bike",
                                    now: Date(timeIntervalSince1970: 1_760_000_050))
        XCTAssertEqual(second.id, first.id)
        XCTAssertEqual(second.stretchKey, first.stretchKey)
        XCTAssertEqual(second.createdAt, first.createdAt)
        XCTAssertGreaterThan(second.updatedAt, synced.updatedAt)   // never earlier than what was already sent
        XCTAssertTrue(second.needsSync)
        XCTAssertEqual(second.correctedLabel, .cycling)

        let flipped = second.revised(verdict: .correct, correctedLabel: .cycling, note: nil)
        XCTAssertNil(flipped.correctedLabel)
    }

    func testAReissuedAnswerKeepsTheIdentityOfTheEarlierOne() {
        var earlier = make(.correct, start: t0)
        earlier.syncedAt = earlier.updatedAt
        // The stretch's start moved after a re-decode, and the wearer changed their mind.
        let now = StretchFeedback(kind: .activityContext, startTs: t0 + 20, endTs: t0 + 900, deviceId: "my-whoop",
                                  predictedLabel: "Sitting", predictedClass: "sitting_desk", predictedConfidence: 0.6,
                                  verdict: .incorrect, correctedLabel: .standing,
                                  now: earlier.updatedAt.addingTimeInterval(-5))
        let next = now.continuing(earlier)
        XCTAssertEqual(next.id, earlier.id)
        XCTAssertEqual(next.stretchKey, earlier.stretchKey)
        XCTAssertEqual(next.createdAt, earlier.createdAt)
        XCTAssertGreaterThan(next.updatedAt, earlier.updatedAt)
        XCTAssertTrue(next.needsSync)
        XCTAssertEqual(next.startTs, t0 + 20)
        XCTAssertEqual(next.predictedLabel, "Sitting")
        XCTAssertEqual(next.correctedLabel, .standing)
    }

    func testConfidenceIsClampedToAProbability() {
        let f = StretchFeedback(kind: .activityContext, startTs: t0, endTs: t0 + 60, deviceId: nil,
                                predictedLabel: "Sitting", predictedClass: nil, predictedConfidence: 1.7,
                                verdict: .correct)
        XCTAssertEqual(f.predictedConfidence, 1)
    }

    func testTheWireFormUsesTheAgreedKeys() throws {
        var context = StretchModelContext()
        context.displayLabel = "Walking"
        context.posture = ["upright": 0.7]
        context.runCount = 3
        context.overlapping = [.init(source: "strap_state", label: "Active", seconds: 420)]
        var f = make(.incorrect, corrected: .inVehicle, note: "bus")
        f.context = context
        f.appVersion = "11.8.0"; f.appBuild = "431"; f.tzOffsetS = -25_200

        let data = try JSONEncoder().encode(StretchFeedbackWire(f))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(json["stretch_key"] as? String, "activity_context:\(t0)")
        XCTAssertEqual(json["kind"] as? String, "activity_context")
        XCTAssertEqual(json["device_id"] as? String, "my-whoop")
        XCTAssertEqual(json["start_ts"] as? Int, t0)
        XCTAssertEqual(json["end_ts"] as? Int, t0 + 600)
        XCTAssertEqual(json["predicted_label"] as? String, "Walking")
        XCTAssertEqual(json["predicted_class"] as? String, "walking")
        XCTAssertEqual(json["predicted_confidence"] as? Double, 0.8)
        XCTAssertEqual(json["verdict"] as? String, "incorrect")
        XCTAssertEqual(json["corrected_label"] as? String, "in_vehicle")
        XCTAssertEqual(json["note"] as? String, "bus")
        XCTAssertEqual(json["app_version"] as? String, "11.8.0")
        XCTAssertEqual(json["app_build"] as? String, "431")
        XCTAssertEqual(json["tz_offset_s"] as? Int, -25_200)
        XCTAssertEqual((json["id"] as? String)?.count, 36)
        XCTAssertEqual(json["id"] as? String, f.id.uuidString.lowercased())

        let createdAt = try XCTUnwrap(json["client_created_at"] as? String)
        XCTAssertNotNil(ISO8601DateFormatter.fractional.date(from: createdAt), createdAt)

        let ctx = try XCTUnwrap(json["model_context"] as? [String: Any])
        XCTAssertEqual(ctx["display_label"] as? String, "Walking")
        XCTAssertEqual(ctx["run_count"] as? Int, 3)
        XCTAssertNil(ctx["avg_hr"], "unset fields are left out")
        let overlap = try XCTUnwrap((ctx["overlapping"] as? [[String: Any]])?.first)
        XCTAssertEqual(overlap["seconds"] as? Int, 420)
    }

    func testTheCorrectionCodesMatchWhatTheServerAccepts() {
        XCTAssertEqual(Set(StretchCorrection.allCases.map(\.rawValue)),
                       ["sitting", "standing", "lying_down", "asleep", "walking", "running", "cycling",
                        "in_vehicle", "exercise", "other_movement", "not_wearing", "other"])
    }

    func testStorageRoundTrips() throws {
        var f = make(.incorrect, corrected: .walking, note: "dog walk")
        f.syncedAt = f.updatedAt
        let back = try JSONDecoder().decode(StretchFeedback.self, from: JSONEncoder().encode(f))
        XCTAssertEqual(back, f)
    }

    func testMatchingPrefersTheExactKeyThenTheBestOverlap() {
        let a = make(.correct, start: t0)                      // t0 ..< t0+600
        let b = make(.incorrect, start: t0 + 1_000)            // t0+1000 ..< t0+1600
        let other = make(.correct, kind: .strapState, start: t0 + 1_000)
        let all = [a, b, other]

        XCTAssertEqual(StretchFeedbackMatch.best(kind: .activityContext, start: t0, end: t0 + 600, in: all)?.id, a.id)
        // The stretch's start moved by ten seconds after a re-decode: still the same stretch.
        XCTAssertEqual(StretchFeedbackMatch.best(kind: .activityContext, start: t0 + 10, end: t0 + 620, in: all)?.id, a.id)
        XCTAssertEqual(StretchFeedbackMatch.best(kind: .strapState, start: t0 + 1_000, end: t0 + 1_600, in: all)?.id, other.id)
        // Barely touching, or a different kind with no record: no match.
        XCTAssertNil(StretchFeedbackMatch.best(kind: .activityContext, start: t0 + 590, end: t0 + 1_000, in: all))
        XCTAssertNil(StretchFeedbackMatch.best(kind: .strapState, start: t0, end: t0 + 600, in: all))
    }
}

private extension ISO8601DateFormatter {
    static let fractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}

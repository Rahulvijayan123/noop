import XCTest
@testable import Strand

/// docs/PHENOTYPE_SIGNATURES.md on the app side: observation periods, onset uncertainty, and the
/// signature-report-1 card (decoding, status wording, fetching and caching per owner).
@MainActor
final class PhenotypeSignatureTests: XCTestCase {
    private let owner = "11111111-1111-4111-8111-111111111111"
    private let other = "22222222-2222-4222-8222-222222222222"
    private let source = "33333333-3333-4333-8333-333333333333"
    private let typeId = UUID(uuidString: "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA")!

    private func identity(_ owner: String) -> CloudPushIdentity {
        CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: UUID().uuidString, uploadToken: "noop_fixture")
    }
    private func event(_ start: Double = 1_791_000_000, type: UUID? = nil) -> ManualEventEntry {
        ManualEventEntry(id: UUID(), kind: .event, label: "Absence", typeId: type ?? typeId,
                         startUnixSeconds: start, endUnixSeconds: start + 30)
    }
    private func observation(_ start: Double = 1_790_998_000, hours: Double = 2) -> ManualEventEntry {
        .observation(start: Date(timeIntervalSince1970: start), end: Date(timeIntervalSince1970: start + hours * 3600))
    }
    private func center(session: URLSession = .shared, endpoint: URL? = nil) -> (ManualEventCenter, ManualEventStore) {
        let store = try! ManualEventStore(path: ":memory:")
        let id = identity(owner)
        let center = ManualEventCenter(store: store, session: session, automaticallySync: false,
                                       identity: { id }, endpoint: { endpoint })
        center.bindAccount()
        return (center, store)
    }

    // MARK: Observation periods

    func testObservationValidationMatchesTheServer() throws {
        XCTAssertNoThrow(try observation().validate())
        XCTAssertNoThrow(try observation(hours: 24).validate())
        let o = observation()
        XCTAssertEqual(o.kind, .observation); XCTAssertEqual(o.label, "Observation"); XCTAssertNil(o.typeId)
        var bad = observation(hours: 24.01); XCTAssertThrowsError(try bad.validate(), "longer than 24 h")
        bad = observation(hours: 0); XCTAssertThrowsError(try bad.validate(), "end must be after start")
        bad = observation(); bad.endUnixSeconds = nil; XCTAssertThrowsError(try bad.validate(), "an observation is closed")
        bad = observation(); bad.startUnixSeconds = 1000; bad.endUnixSeconds = 2000; XCTAssertThrowsError(try bad.validate())
        bad = observation(); bad.typeId = typeId; XCTAssertThrowsError(try bad.validate(), "no type of its own")
        bad = observation(); bad.activityKind = "rest"; XCTAssertThrowsError(try bad.validate())
        bad = observation(); bad.durationMinutes = 60; XCTAssertThrowsError(try bad.validate())
        bad = observation(); bad.onsetUncertaintyMinutes = 5; XCTAssertThrowsError(try bad.validate())
        XCTAssertNotNil(ManualObservationCopy.problem(start: Date(), end: Date()))
        XCTAssertNotNil(ManualObservationCopy.problem(start: Date(), end: Date().addingTimeInterval(86_401)))
        XCTAssertNil(ManualObservationCopy.problem(start: Date(), end: Date().addingTimeInterval(3600)))
    }

    func testObservationsAreNeverEventsAndArchiveLikeOtherEntries() throws {
        let (center, store) = center()
        let logged = event(1_791_000_000), outside = event(1_791_100_000), watched = observation()
        XCTAssertTrue(center.save(logged, for: owner)); XCTAssertTrue(center.save(outside, for: owner))
        XCTAssertTrue(center.save(watched, for: owner))
        XCTAssertEqual(Set(center.events.map(\.id)), [logged.id, outside.id])
        XCTAssertEqual(center.observations.map(\.id), [watched.id])
        XCTAssertEqual(center.events(during: watched).map(\.id), [logged.id])
        XCTAssertEqual(Set(ManualEventPresentation.events(center).map(\.id)), [logged.id.uuidString, outside.id.uuidString])
        let detection = EventDetectionCenter(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString),
            automaticallySync: false, syncManual: {}, identity: { [owner, source] in
                CloudPushIdentity(ownerId: owner, sourceId: source, tokenId: "t", uploadToken: "u") }, endpoint: { nil })
        detection.bindAccount()
        XCTAssertFalse(PersonalEventPresentation.events(manual: center, detection: detection)
            .contains { $0.id == watched.id.uuidString }, "the Events timeline leaves observations out")
        center.archive(watched)
        XCTAssertTrue(center.observations.isEmpty)
        XCTAssertEqual(center.archived.map(\.id), [watched.id])
        let archived = try XCTUnwrap(center.archived.first)
        XCTAssertEqual(archived.endUnixSeconds, watched.endUnixSeconds, "archiving keeps the period's own end")
        center.restore(archived)
        XCTAssertEqual(center.observations.map(\.id), [watched.id])
        XCTAssertEqual(try store.history(owner: owner).filter { $0.entry.id == watched.id }.count, 3)
    }

    func testObservationsSyncAndAnUnreadableCloudRevisionIsSkipped() async throws {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SignatureURLProtocol.self]
        let (center, store) = center(session: URLSession(configuration: config), endpoint: URL(string: "https://example.invalid/manual-events"))
        try store.markSynced(owner: owner, ids: store.pending(owner: owner).map(\.revisionId))
        let watched = observation()
        XCTAssertTrue(center.save(watched, for: owner))
        let remote = observation(1_791_200_000, hours: 1)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let remoteJSON = try JSONSerialization.jsonObject(with: encoder.encode(
            ManualEventRevision(revisionId: UUID(), updatedAtMs: 1_791_200_000_000, entry: remote)))
        // A kind from a newer app, which this version cannot read: skipped, never blocking the page.
        let future: [String: Any] = ["revision_id": UUID().uuidString, "updated_at_ms": 1_791_200_000_001,
            "entry": ["id": UUID().uuidString, "kind": "medication_dose", "label": "Dose", "archived": false]]
        let ownIdentity = ["userId": owner, "sourceId": source]
        var uploaded: [[String: Any]] = []
        SignatureURLProtocol.handler = { request in
            if request.httpMethod == "GET" {
                if request.url!.path.hasSuffix("/context") { return (404, Data()) }
                return (200, try JSONSerialization.data(withJSONObject: ["revisions": [future, remoteJSON], "next": "2",
                    "has_more": false, "identity": ownIdentity]))
            }
            let body = try JSONSerialization.jsonObject(with: SignatureURLProtocol.body(request)) as! [String: Any]
            let revisions = body["revisions"] as! [[String: Any]]
            uploaded += revisions
            return (200, try JSONSerialization.data(withJSONObject: ["saved": revisions.map { $0["revision_id"]! },
                "identity": ownIdentity]))
        }
        await center.syncNow()
        XCTAssertTrue(center.pendingIds.isEmpty)
        XCTAssertEqual((uploaded.first?["entry"] as? [String: Any])?["kind"] as? String, "observation")
        XCTAssertEqual((uploaded.first?["entry"] as? [String: Any])?["label"] as? String, "Observation")
        XCTAssertEqual(Set(center.observations.map(\.id)), [watched.id, remote.id])
        XCTAssertEqual(try store.cursor(owner: owner), "2")
    }

    // MARK: Onset uncertainty

    func testOnsetUncertaintyRoundTripsAndIsOmittedWhenAbsent() throws {
        for minutes in ManualEventEntry.onsetUncertaintyChoices {
            var e = event(); e.onsetUncertaintyMinutes = minutes; XCTAssertNoThrow(try e.validate())
        }
        for minutes in [1, 10, 30, -5, 1440] {
            var e = event(); e.onsetUncertaintyMinutes = minutes; XCTAssertThrowsError(try e.validate(), "\(minutes)")
        }
        var type = ManualEventEntry(id: UUID(), kind: .eventType, label: "Absence"); type.onsetUncertaintyMinutes = 5
        XCTAssertThrowsError(try type.validate(), "only events carry an onset")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        for seed in ManualEventEntry.defaultTypes + ManualEventEntry.defaultPresets {
            XCTAssertFalse(String(decoding: try encoder.encode(seed), as: UTF8.self).contains("onsetUncertainty"),
                           "factory seed bytes stay unchanged")
        }
        XCTAssertFalse(String(decoding: try encoder.encode(event()), as: UTF8.self).contains("onsetUncertainty"))
        let store = try ManualEventStore(path: ":memory:")
        var e = event(); e.onsetUncertaintyMinutes = 15
        let saved = try store.save(e, owner: owner)
        XCTAssertTrue(String(decoding: try encoder.encode(saved), as: UTF8.self).contains("\"onsetUncertaintyMinutes\":15"))
        XCTAssertEqual(try store.latest(owner: owner).first?.onsetUncertaintyMinutes, 15)
        let decoded = try JSONDecoder().decode(ManualEventRevision.self, from: encoder.encode(saved))
        XCTAssertEqual(decoded, saved)
        XCTAssertEqual(ManualEventEntry.defaultOnsetUncertaintyMinutes, 5)
        XCTAssertEqual(ManualEventEntry.onsetUncertaintyChoices.map(ManualObservationCopy.onsetTitle),
                       ["Exact", "±5 min", "±15 min", "±1 h"])
    }

    // MARK: Signature report decoding

    /// The contract's example (docs/PHENOTYPE_SIGNATURES.md) with its placeholders filled in, plus fields this
    /// version does not know.
    private func specExample(status: String = "emerging") -> String {
        let mean = (0..<61).map { i in String(64 + (i > 30 ? 10 : 0)) }.joined(separator: ",")
        let low = (0..<61).map { i in i == 5 ? "null" : String(60 + (i > 30 ? 10 : 0)) }.joined(separator: ",")
        let high = (0..<61).map { i in String(68 + (i > 30 ? 10 : 0)) }.joined(separator: ",")
        return """
        {
          "version": "signature-report-1",
          "type_id": "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", "generated_at": 1791600000,
          "engine": {"version": "sig-1", "normalization": "context"},
          "status": "\(status)",
          "evidence": {"events": 8, "event_days": 6, "observation_hours": 12.5, "confirmed_detections": 0,
                       "rejected_detections": 0, "negative_intervals": 1, "monitored_days": 9.1},
          "signatures": [{
            "id": "s1", "label": "all events", "events": 8, "event_days": 6, "event_ids": ["uuid"],
            "p_value": 0.03, "p_min_possible": 0.031, "replicated": true,
            "context_at_onset": {"asleep": 0.0, "still": 0.62, "walking": 0.12, "active": 0.25, "unknown": 0.01},
            "findings": [{"channel": "hr", "unit": "bpm", "window": [0, 5], "direction": "up",
                          "change": 18.2, "change_ci": [12.1, 24.0], "change_z": 2.1, "consistency": 0.875,
                          "events_with_data": 8,
                          "text": "Heart rate rose 18 bpm (12–24) within 5 min after onset in 7 of 8 events.",
                          "future_finding_field": {"a": 1}}],
            "profile": {"lags": [-30, 30], "channels": {"hr": {"unit": "bpm", "mean": [\(mean)],
                        "ci_lo": [\(low)], "ci_hi": [\(high)]}}}
          }],
          "detectability": {"d": 1.8, "d_ci": [1.1, 2.4], "expected_recall": {"0.5": 0.12, "1": 0.30, "2": 0.45},
                            "assessment": "promising"},
          "retrospective": {"evaluated": true, "method": "logistic", "events": 5, "recall": 0.6, "recall_ci": [0.23, 0.88],
                            "false_alerts_per_day": 0.8, "false_alerts_ci": [0.2, 2.1], "latency_median_min": 3,
                            "monitored_days": 4.2, "baselines": {"hr_rule_raw": {}, "hr_rule_context": {}, "template": {}},
                            "promoted": false, "reason": "text"},
          "data_quality": {"monitored_fraction": 0.82, "channels": {"hr": 0.97, "hrv": 0.4, "resp": 0.0, "temp": 0.95,
                           "motion": 0.3}, "notes": ["Breathing rate is not available for this strap yet."]},
          "limitations": ["text"],
          "alerts_enabled": false,
          "a_field_from_a_newer_engine": [1, 2, 3]
        }
        """
    }

    func testDecodesTheContractExampleIncludingUnknownFields() throws {
        let report = try XCTUnwrap(SignatureReport.decode(Data(specExample().utf8)))
        XCTAssertEqual(report.status, .emerging); XCTAssertEqual(report.typeId, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        XCTAssertEqual(report.generated, Date(timeIntervalSince1970: 1_791_600_000))
        XCTAssertEqual(report.engine?.normalization, "context")
        XCTAssertEqual(report.evidence?.events, 8); XCTAssertEqual(report.evidence?.eventDays, 6)
        XCTAssertEqual(report.evidence?.observationHours, 12.5); XCTAssertEqual(report.evidence?.monitoredDays, 9.1)
        let signature = try XCTUnwrap(report.primary)
        XCTAssertEqual(signature.pValue, 0.03); XCTAssertEqual(signature.replicated, true)
        XCTAssertEqual(signature.contextAtOnset["still"], 0.62); XCTAssertEqual(signature.eventIds, ["uuid"])
        let finding = try XCTUnwrap(signature.findings.first)
        XCTAssertEqual(finding.window, [0, 5]); XCTAssertEqual(finding.changeCI, [12.1, 24.0])
        XCTAssertEqual(finding.consistentEvents, 7); XCTAssertEqual(SignaturePresentation.consistency(finding), "7 of 8 events")
        XCTAssertEqual(SignaturePresentation.change(finding), "+18 bpm (12 to 24)")
        XCTAssertEqual(SignaturePresentation.window(finding.window), "0–5 min after onset")
        XCTAssertEqual(SignaturePresentation.directionSymbol(finding), "arrow.up.right")
        let hr = try XCTUnwrap(signature.profile?.channels["hr"])
        XCTAssertEqual(hr.mean.count, 61); XCTAssertNil(hr.ciLo[5], "a null keeps its position")
        let points = SignaturePresentation.profilePoints(hr, lags: signature.profile?.lags ?? [])
        XCTAssertEqual(points.count, 61); XCTAssertEqual(points.first?.minute, -30); XCTAssertEqual(points.last?.minute, 30)
        XCTAssertEqual(points[30].minute, 0); XCTAssertNil(points[5].low)
        XCTAssertEqual(SignaturePresentation.profileChannel(signature)?.key, "hr")
        XCTAssertEqual(report.detectability?.recallAtOnePerDay, 0.30); XCTAssertEqual(report.detectability?.dCI, [1.1, 2.4])
        XCTAssertEqual(report.retrospective?.recallCI, [0.23, 0.88]); XCTAssertEqual(report.retrospective?.latencyMedianMin, 3)
        XCTAssertEqual(report.dataQuality?.channels["hrv"], 0.4); XCTAssertEqual(report.dataQuality?.notes.count, 1)
        XCTAssertEqual(report.limitations, ["text"]); XCTAssertEqual(report.alertsEnabled, false)
    }

    func testDecodingIsTolerantButRefusesAnotherContract() throws {
        let messy = """
        {"version": "signature-report-1", "status": "emerging", "evidence": {"events": "8", "event_days": 6.0},
         "signatures": [{"findings": [{"text": "kept", "change": "big", "events_with_data": 8}, 7, null],
                         "profile": {"lags": [-30, "x", 30], "channels": {"hr": {"mean": [1, null, "no", 3]}, "bad": 4}}},
                        "not a signature"],
         "limitations": "not a list", "alerts_enabled": "no"}
        """
        let report = try XCTUnwrap(SignatureReport.decode(Data(messy.utf8)))
        XCTAssertNil(report.evidence?.events, "a mistyped field is dropped"); XCTAssertEqual(report.evidence?.eventDays, 6)
        XCTAssertEqual(report.signatures.count, 1)
        XCTAssertEqual(report.primary?.findings.map(\.text), ["kept"]); XCTAssertNil(report.primary?.findings.first?.change)
        XCTAssertEqual(report.primary?.profile?.lags, [-30, 30])
        XCTAssertEqual(report.primary?.profile?.channels["hr"]?.mean, [1, nil, nil, 3])
        XCTAssertEqual(report.limitations, []); XCTAssertNil(report.alertsEnabled)
        XCTAssertNil(SignatureReport.decode(Data(#"{"version": "signature-report-2", "status": "established"}"#.utf8)))
        XCTAssertNil(SignatureReport.decode(Data("[]".utf8)))
        XCTAssertNotNil(SignatureReport.decode(Data(#"{"version": "signature-report-1"}"#.utf8)), "every field is optional")
        XCTAssertNil(try XCTUnwrap(SignatureReport.decode(Data(#"{"version": "signature-report-1", "status": "diagnosed"}"#.utf8))).status)
    }

    func testDecodesTheSig2OptionalFields() throws {
        let json = """
        {"version": "signature-report-1", "engine": {"version": "sig-2"}, "status": "emerging",
         "evidence": {"events": 9, "event_days": 6, "events_used": 7,
                      "events_dropped": {"fewer than 3 matched controls": 1, "strap not worn before onset": 1, "bad": "x"}},
         "signatures": [{"findings": [
            {"channel": "hr", "basis": "change_from_before", "movement_accompanied": true, "text": "a"},
            {"channel": "ln_rmssd", "basis": "vs_usual_for_context", "text": "b"},
            {"channel": "steps", "basis": "something_new", "text": "c"}]}],
         "detectability": {"assessment": "too_weak_for_alerts", "expected_recall": {"0.5": 0.1, "1": 0.33, "2": 0.5},
                           "expected_recall_ci": {"0.5": [0.02, 0.4], "1": [0.10, 0.70], "2": [null, null]}},
         "retrospective": {"evaluated": true, "training_cutoff": 1791500000, "champion": null}}
        """
        let report = try XCTUnwrap(SignatureReport.decode(Data(json.utf8)))
        XCTAssertEqual(report.evidence?.eventsUsed, 7)
        XCTAssertEqual(report.evidence?.eventsDropped, [:], "a mistyped count drops the whole map rather than guessing")
        let findings = try XCTUnwrap(report.primary?.findings)
        XCTAssertEqual(findings.map(SignaturePresentation.basis), ["vs the minutes before", "vs usual for the activity", nil])
        XCTAssertEqual(SignaturePresentation.channelTitle(findings[2].channel), "Steps")
        XCTAssertEqual(findings.map(\.movementAccompanied), [true, nil, nil])
        XCTAssertEqual(findings.map(SignaturePresentation.movement), ["with more movement", nil, nil])
        let moved = try XCTUnwrap(SignatureReport.decode(Data(#"""
        {"version": "signature-report-1", "signatures": [{"findings": [
          {"channel": "hr", "direction": "down", "movement_accompanied": true},
          {"channel": "hrv", "direction": "down", "movement_accompanied": true},
          {"channel": "hrv", "direction": "up", "movement_accompanied": true},
          {"channel": "hr", "direction": "up", "movement_accompanied": false}]}]}
        """#.utf8)))
        XCTAssertEqual(moved.primary?.findings.map(SignaturePresentation.movement),
                       ["with less movement", "with more movement", "with less movement", nil])
        XCTAssertEqual(report.detectability?.recallCIAtOnePerDay, [0.10, 0.70])
        XCTAssertNil(report.detectability?.expectedRecallCI["2"], "a null interval is left out")
        XCTAssertEqual(report.retrospective?.trainingCutoff, 1_791_500_000)
        XCTAssertEqual(SignaturePresentation.detectability(report).detail,
                       "About 33% (10%–70%) of events would be caught at 1 false alert per day.")

        let dropped = try XCTUnwrap(SignatureReport.decode(Data(#"""
        {"version": "signature-report-1", "evidence": {"events": 9,
         "events_dropped": {"strap not worn before onset": 1, "fewer than 3 matched controls": 2}}}
        """#.utf8)))
        XCTAssertEqual(SignaturePresentation.droppedNote(dropped),
                       "3 of 9 events were left out: fewer than 3 matched controls (2), strap not worn before onset (1).")
        XCTAssertNil(SignaturePresentation.droppedNote(try XCTUnwrap(SignatureReport.decode(Data(#"{"version": "signature-report-1", "evidence": {"events_dropped": {}}}"#.utf8)))))
        // A sig-1 report without these keys still decodes and reads as before.
        let old = try XCTUnwrap(SignatureReport.decode(Data(specExample().utf8)))
        XCTAssertNil(old.primary?.findings.first?.basis); XCTAssertNil(old.detectability?.recallCIAtOnePerDay)
        XCTAssertNil(SignaturePresentation.droppedNote(old))
    }

    func testDecodesAJointFinding() throws {
        let json = #"""
        {"version": "signature-report-1", "engine": {"version": "sig-4"}, "status": "established",
         "signatures": [{"findings": [{"channel": "motion", "unit": "SD", "basis": "joint", "window": [0, 5],
           "direction": "up", "change": 3.5, "change_ci": [2.1, 4.8], "change_z": 3.5, "consistency": 1.0,
           "events_with_data": 12, "combined_z": 3.5, "combined_z_ci": [2.1, 4.8],
           "channels": [{"channel": "hr", "weight": 0.4, "change_z": 2.3, "change": 11.0, "unit": "bpm"},
                        {"channel": "motion", "weight": 0.9, "change_z": 13.6, "change": 0.05, "unit": "g"},
                        "bad"],
           "text": "Movement rose (+13.6 SD) and heart rate rose (+2.3 SD) together from before onset, within 5 min after onset, in 12 of 12 events (combined +3.5 SD)."}]}]}
        """#
        let finding = try XCTUnwrap(SignatureReport.decode(Data(json.utf8))?.primary?.findings.first)
        XCTAssertEqual(finding.basis, "joint"); XCTAssertEqual(finding.combinedZ, 3.5); XCTAssertEqual(finding.combinedZCI, [2.1, 4.8])
        XCTAssertEqual(finding.channels.count, 2, "an unreadable channel entry is dropped")
        XCTAssertEqual(SignaturePresentation.jointParts(finding), ["Movement +13.6 SD", "Heart rate +2.3 SD"])
        XCTAssertEqual(SignaturePresentation.basis(finding), "readings combined")
        XCTAssertEqual(SignaturePresentation.change(finding), "+3.5 SD (2.1 to 4.8)")
        XCTAssertNil(SignaturePresentation.movement(finding), "movement is part of a joint signature, not a caveat")
    }


    private func report(_ json: String) throws -> SignatureReport {
        let text = "{\"version\": \"signature-report-1\", " + json + "}"
        return try XCTUnwrap(SignatureReport.decode(Data(text.utf8)))
    }

    func testStatusCopyForEveryState() throws {
        XCTAssertEqual(SignaturePresentation.status(nil, loggedEvents: 2),
                       .init(title: "Learning", detail: SignaturePresentation.learningDetail, symbol: "hourglass"))
        XCTAssertEqual(SignaturePresentation.learningDetail,
                       "Showing each event's context; a signature needs at least 3 events on 3 different days.")
        XCTAssertEqual(SignaturePresentation.status(nil, loggedEvents: 4).title, "Learning")
        XCTAssertEqual(SignaturePresentation.status(try report(#""status": "insufficient_events""#), loggedEvents: 2).detail,
                       SignaturePresentation.learningDetail)
        let individual = SignaturePresentation.status(try report(#""status": "individual_context", "evidence": {"events": 4, "event_days": 2}"#), loggedEvents: 4)
        XCTAssertEqual(individual.title, "Individual context"); XCTAssertTrue(individual.detail.hasPrefix("4 events on 2 days"))
        XCTAssertTrue(individual.detail.contains("at least 3 different days"))
        // With 3–5 days the analysis ran but cannot reach significance yet: the copy asks for 6 days, not 3.
        let fiveDays = SignaturePresentation.status(try report(#""status": "individual_context", "evidence": {"events": 5, "event_days": 5}"#), loggedEvents: 5)
        XCTAssertTrue(fiveDays.detail.contains("at least 6 different days")); XCTAssertFalse(fiveDays.detail.contains("at least 3 different"))
        XCTAssertFalse(SignaturePresentation.showsProfile(try report(#""status": "individual_context""#)))
        XCTAssertFalse(SignaturePresentation.showsProfile(try report(#""status": "insufficient_events""#)))
        XCTAssertTrue(SignaturePresentation.showsProfile(try report(#""status": "emerging""#)))
        let emerging = SignaturePresentation.status(try XCTUnwrap(SignatureReport.decode(Data(specExample().utf8))), loggedEvents: 8)
        XCTAssertEqual(emerging.title, "Emerging signature")
        XCTAssertTrue(emerging.detail.contains("p = 0.03 across 6 days") && emerging.detail.contains("not yet confirmed"))
        let established = SignaturePresentation.status(try XCTUnwrap(SignatureReport.decode(Data(specExample(status: "established").utf8))), loggedEvents: 8)
        XCTAssertEqual(established.title, "Established signature"); XCTAssertTrue(established.detail.contains("held on events logged later"))

        let fewDays = try report(#""status": "no_reliable_signature", "evidence": {"event_days": 4}, "signatures": [{"p_value": 0.4, "p_min_possible": 0.125}]"#)
        let inconsistent = try report(#""status": "no_reliable_signature", "evidence": {"event_days": 9}, "signatures": [{"p_value": 0.41, "p_min_possible": 0.004, "replicated": false}]"#)
        let unreplicated = try report(#""status": "no_reliable_signature", "evidence": {"event_days": 9}, "signatures": [{"p_value": 0.02, "replicated": false}]"#)
        XCTAssertEqual(SignaturePresentation.noSignatureReasonKind(fewDays), .tooFewDays)
        XCTAssertEqual(SignaturePresentation.noSignatureReasonKind(inconsistent), .notConsistent)
        XCTAssertEqual(SignaturePresentation.noSignatureReasonKind(unreplicated), .notReplicated)
        let borderline = try report(#""status": "no_reliable_signature", "evidence": {"event_days": 9}, "signatures": [{"p_value": 0.07, "p_min_possible": 0.004, "replicated": false}]"#)
        XCTAssertEqual(SignaturePresentation.noSignatureReasonKind(borderline), .notConsistent, "emerging needs p < 0.05 since sig-2")
        XCTAssertEqual(SignaturePresentation.status(fewDays, loggedEvents: 5).title, "No reliable signature yet")
        XCTAssertTrue(SignaturePresentation.status(fewDays, loggedEvents: 5).detail.hasPrefix("Too few days: events on 4 different days"))
        XCTAssertTrue(SignaturePresentation.status(inconsistent, loggedEvents: 9).detail.hasPrefix("Not consistent"))
        XCTAssertTrue(SignaturePresentation.status(unreplicated, loggedEvents: 9).detail.hasPrefix("Not replicated"))

        let promising = SignaturePresentation.detectability(try XCTUnwrap(SignatureReport.decode(Data(specExample().utf8))))
        XCTAssertEqual(promising.title, "Promising"); XCTAssertTrue(promising.detail.contains("About 30% of events"))
        XCTAssertTrue(promising.detail.contains("1 false alert per day"))
        let weak = SignaturePresentation.detectability(try report(#""detectability": {"assessment": "too_weak_for_alerts", "expected_recall": {"1.0": 0.02}}"#))
        XCTAssertEqual(weak.title, "Not reliable enough for alerts yet"); XCTAssertTrue(weak.detail.contains("About 2%"))
        XCTAssertTrue(SignaturePresentation.alertsOff.hasPrefix("Alerts are off."))
        // Nothing here may read as a diagnosis.
        let all = [SignaturePresentation.learningDetail, emerging.detail, established.detail, promising.detail, weak.detail,
                   SignaturePresentation.alertsOff] + [fewDays, inconsistent, unreplicated].map(SignaturePresentation.noSignatureReason)
        for text in all { XCTAssertFalse(text.lowercased().contains("diagnos"), text) }
    }

    // MARK: Fetching and caching

    func testSignatureIsFetchedForTheOwnerCachedAndClearedWhenGone() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        var current: CloudPushIdentity? = identity(owner)
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SignatureURLProtocol.self]
        let body = try JSONSerialization.jsonObject(with: Data(specExample().utf8))
        var replyOwner = owner, report: Any = body, requested: [URL] = []
        SignatureURLProtocol.handler = { request in
            requested.append(request.url!)
            return (200, try JSONSerialization.data(withJSONObject: ["report": report,
                "identity": ["userId": replyOwner, "sourceId": self.source]]))
        }
        let detection = EventDetectionCenter(directory: directory, session: URLSession(configuration: config), automaticallySync: false,
            syncManual: {}, identity: { current }, endpoint: { URL(string: "https://example.invalid/event-detection") })
        detection.bindAccount()
        await detection.loadSignature(for: typeId)
        XCTAssertEqual(requested.last?.path, "/event-detection/signature")
        XCTAssertEqual(requested.last?.query, "typeId=\(typeId.uuidString.lowercased())")
        XCTAssertEqual(detection.signatures[typeId]?.status, .emerging); XCTAssertTrue(detection.signaturesChecked.contains(typeId))
        XCTAssertEqual(detection.signatureStatus(typeId, loggedEvents: 8), "Off", "a type that is not learning reads Off")

        // Cached per owner: a restart shows it offline; another account never sees it.
        let offline = EventDetectionCenter(directory: directory, automaticallySync: false, syncManual: {}, identity: { current }, endpoint: { nil })
        offline.bindAccount(); XCTAssertEqual(offline.signatures[typeId]?.status, .emerging)
        current = identity(other); offline.bindAccount(); XCTAssertTrue(offline.signatures.isEmpty)
        current = identity(owner)

        // A reply for another owner, or a report of another type, changes nothing.
        replyOwner = other; report = NSNull()
        await detection.loadSignature(for: typeId)
        XCTAssertNotNil(detection.signatures[typeId])
        replyOwner = owner
        var otherType = body as! [String: Any]; otherType["type_id"] = UUID().uuidString.lowercased(); report = otherType
        await detection.loadSignature(for: typeId)
        XCTAssertEqual(detection.signatures[typeId]?.typeId, "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa")
        // None yet: the saved report goes.
        report = NSNull()
        await detection.loadSignature(for: typeId)
        XCTAssertNil(detection.signatures[typeId])
        let reloaded = EventDetectionCenter(directory: directory, automaticallySync: false, syncManual: {}, identity: { current }, endpoint: { nil })
        reloaded.bindAccount(); XCTAssertNil(reloaded.signatures[typeId])
    }

    override func tearDown() { SignatureURLProtocol.handler = nil; super.tearDown() }
}

private final class SignatureURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let handler = Self.handler else { throw URLError(.cannotConnectToHost) }
            let (status, data) = try handler(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
    static func body(_ request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n))
        }
        return data
    }
}

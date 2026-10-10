import XCTest
import StrandAnalytics
@testable import frwhoop_worker

/// The worker side of the release authority (docs/model-integration/activity-authority.md), as a deterministic replay
/// through the stub children (no torch, no model, no database): one day inferred with the experts off, in shadow, in
/// candidate and in production mode, then every decode the lane makes from that job's selection.
///
/// - Shadow and candidate expert rows never change what is published (v1 epochs and the v2 day document are
///   byte-identical with the experts off, shadow or candidate, and equal to HART alone as decoded before the policy).
/// - Production experts shape the published v2 day document (the v1 epochs stay HART's), their rows carry no
///   comparison document, and the joint candidate's arm of exactly the production channels is the published document.
/// - The joint candidate: all off == HART alone == the published document; disabling an expert reproduces its
///   ablation exactly; reused documents equal fresh decodes; the joint decode is one decode with both channels.
/// - ElderNet has one route: the HART-embedded windows never shape a published or candidate decode while the
///   standalone route exists, and are shadow without it.
final class ActivityAuthorityReplayTests: XCTestCase {

    private let dayStart = 1_789_430_400          // 2026-09-15 00:00:00 UTC
    private var dayEnd: Int { dayStart + 86_400 }
    private let day = "2026-09-15"
    private let revision: Int64 = 3
    private let generatedAt = 1_789_500_000
    private let eldernetVersion = "eldernet-437a38b"
    private let bundleSha = String(repeating: "ab", count: 32)
    private var services: [ActivityPythonService] = []

    override func tearDown() {
        for s in services { s.shutdown() }
        services = []
        super.tearDown()
    }

    // MARK: - Stub children

    private func stub(_ name: String) -> String? {
        for c in ["Tests/frwhoop-workerTests/\(name)", "../../Tests/frwhoop-workerTests/\(name)"]
        where FileManager.default.fileExists(atPath: c) { return c }
        return nil
    }

    private func hartService() throws -> ActivityPythonService {
        guard let path = stub("stub_activity_service.py") else { throw XCTSkip("stub_activity_service.py not found") }
        let s = ActivityPythonService(config: ActivityPythonService.Config(
            pythonBin: "/usr/bin/python3", activityHome: FileManager.default.currentDirectoryPath, modelDir: nil,
            serveArgs: [path], requestTimeoutSeconds: 5, maxRequestBytes: 64 * 1024 * 1024,
            maxResponseLineBytes: 16 * 1024 * 1024, restartCap: 8, restartCooldownSeconds: 30))
        services.append(s)
        return s
    }

    /// The weights digest the ElderNet stub serves (its per-head sha256 of "stub-eldernet-<head>-stub").
    private func eldernetDigest() throws -> String {
        var w: [String: String] = [:]
        for h in GaitQualityWire.weightNames {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            p.arguments = ["python3", "-c", "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())",
                           "stub-eldernet-\(h)-stub"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            p.waitUntilExit()
            w[h] = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return ElderNetStage.weightsDigest(of: w)
    }

    private func eldernet(_ mode: ElderNetSettings.Mode) throws -> ElderNetStage {
        guard let path = stub("stub_eldernet_service.py") else { throw XCTSkip("stub_eldernet_service.py not found") }
        let settings = ElderNetSettings.fromEnvironment([
            "FRWHOOP_ELDERNET_ENABLED": "1", "FRWHOOP_ELDERNET_WEIGHTS_DIR": "/opt/eldernet",
            "FRWHOOP_ELDERNET_UPSTREAM_DIR": "/u"], activityPython: "/usr/bin/python3")
        var config = try XCTUnwrap(settings.serviceConfig(activityHome: FileManager.default.currentDirectoryPath))
        config.serveArgs = [path, "--behaviour", "ok"]
        let s = ActivityPythonService(config: config)
        services.append(s)
        return ElderNetStage(service: s, mode: mode,
                             expectedModelVersion: mode != .shadow ? eldernetVersion : nil,
                             expectedWeightsDigest: mode != .shadow ? try eldernetDigest() : nil,
                             gaitPrior: 0.2)
    }

    private func inertia(_ mode: InertiaSettings.Mode, kind: String, tier: String) throws -> InertiaStage {
        guard let path = stub("stub_inertia_service.py") else { throw XCTSkip("stub_inertia_service.py not found") }
        var settings = InertiaSettings.fromEnvironment([
            "FRWHOOP_INERTIA_ENABLED": "1", "FRWHOOP_INERTIA_BUNDLE_DIR": "/opt/bundle"], activityPython: "/usr/bin/python3")
        settings.mode = mode
        var config = try XCTUnwrap(settings.serviceConfig(activityHome: FileManager.default.currentDirectoryPath))
        config.serveArgs = [path, "--behaviour", "ok", "--kind", kind, "--tier", tier]
        let s = ActivityPythonService(config: config)
        services.append(s)
        return InertiaStage(service: s, mode: mode, expectedBundleSHA256: mode != .shadow ? bundleSha : nil)
    }

    /// Three 2-minute chunks inside the day (column payloads are not inspected by the stubs).
    private func requests() -> [ActivityPythonService.RunRequest] {
        let t0 = dayStart + 36_000
        let column = Data(repeating: 0, count: 1200).base64EncodedString()
        return (0..<3).map { i in
            ActivityPythonService.RunRequest(startTs: t0 + i * 120, endTs: t0 + (i + 1) * 120,
                                             columnsB64: Array(repeating: column, count: 120), headB64: [], tailB64: [])
        }
    }

    private func infer(eldernet: ElderNetStage?, inertia: InertiaStage?) throws -> ActivityLane.ChunkInference {
        var stats = ActivityLane.Stats()
        return try ActivityLane.inferChunks(
            requests(), service: try hartService(), inertia: inertia, eldernet: eldernet,
            versions: (ActivityLane.baselineModelVersion, ActivityLane.baselinePreprocessingVersion),
            stats: &stats, renew: { true })
    }

    /// The day's decoder input: still, walk, still (the stored streams and HART windows the published decode reads).
    private func contextInput(embedded: [ActivityGaitWindow] = []) -> ActivityContextTrackInput {
        var sim = DaySim(start: dayStart + 36_000)
        sim.still(120); sim.walk(120); sim.still(120)
        return ActivityContextDays.trackInput(windows: sim.windows, streams: sim.streams, sleep: [], exercise: [],
                                              dayStart: dayStart, dayEnd: dayEnd, sleepKnownOutsideSessions: false,
                                              encoderVersion: "stub-model", gaitWindows: embedded)
    }

    /// HART-embedded ElderNet windows over the walk (what `--gait-expert eldernet` would add to hart-windows-1).
    private func embeddedWindows() -> [ActivityGaitWindow] {
        stride(from: dayStart + 36_130, to: dayStart + 36_240, by: 5).map {
            ActivityGaitWindow(startTs: $0 - 10, endTs: $0, gaitProb: 0.97, isGait: true, cadenceSpm: 112,
                               speedMps: 1.3, modelVersion: eldernetVersion)
        }
    }

    private struct Job {
        var inferred: ActivityLane.ChunkInference
        var selection: ActivityExpertSelection
        var eldernet: ElderNetStage?
        var inertia: InertiaStage?
    }

    private func job(eldernet: ElderNetStage?, inertia: InertiaStage?, embedded: [ActivityGaitWindow] = []) throws -> Job {
        let inferred = try infer(eldernet: eldernet, inertia: inertia)
        let selection = ActivityCandidateDays.selection(
            day: day, inputRevision: revision, gait: eldernet == nil ? nil : inferred.gaitQuality.trackInput,
            eldernet: eldernet, heads: inertia == nil ? nil : inferred.motionHeads.trackInput, inertia: inertia,
            embedded: embedded)
        return Job(inferred: inferred, selection: selection, eldernet: eldernet, inertia: inertia)
    }

    /// What the lane publishes for a job: the v1 epochs document and the v2 day document (its canonical decode).
    private func published(_ job: Job, input: ActivityContextTrackInput) throws -> (v1: String, v2: String) {
        var doc = try ActivityLane.activityDocument(
            windows: job.inferred.windows, sleepIntervals: [], exerciseIntervals: [], dayStart: dayStart, dayEnd: dayEnd,
            inputRevision: revision, modelVersion: job.inferred.versions.model,
            preprocessingVersion: job.inferred.versions.preprocessing, dataThrough: dayStart + 36_360)
        let v1 = try ActivityLane.dayStampedJSONText(doc: &doc, day: day)
        let canonical = job.selection.canonical(input, base: ActivityDecoderConfig())
        let v2 = try ActivityContextDays.build(input: canonical.input, day: day, modelVersion: job.inferred.versions.model,
                                               preprocessingVersion: job.inferred.versions.preprocessing,
                                               generatedAt: generatedAt, config: canonical.config).payloadText
        return (v1, v2)
    }

    /// HART alone as the lane decoded it before the policy existed: the input as built, the default config.
    private func legacyHartAlone(_ inferred: ActivityLane.ChunkInference) throws -> String {
        try ActivityContextDays.build(input: contextInput(), day: day, modelVersion: inferred.versions.model,
                                      preprocessingVersion: inferred.versions.preprocessing,
                                      generatedAt: generatedAt).payloadText
    }

    // MARK: - Published output

    func testShadowAndCandidateExpertRowsNeverChangeWhatIsPublished() throws {
        let off = try job(eldernet: nil, inertia: nil)
        let shadow = try job(eldernet: try eldernet(.shadow), inertia: try inertia(.shadow, kind: "standin", tier: "shadow"))
        let candidate = try job(eldernet: try eldernet(.candidate),
                                inertia: try inertia(.candidate, kind: "inertia1", tier: "candidate"))
        // The experts really ran, and in candidate mode the policy admitted both for candidate decodes.
        XCTAssertFalse(try XCTUnwrap(candidate.inferred.gaitQuality.trackInput).windows.isEmpty)
        XCTAssertFalse(try XCTUnwrap(candidate.inferred.motionHeads.trackInput).windows.isEmpty)
        XCTAssertEqual(candidate.selection.use(of: .gaitQuality), .candidate)
        XCTAssertEqual(candidate.selection.use(of: .motionHeads), .candidate)
        XCTAssertEqual(shadow.selection.candidateChannels, [])
        for j in [off, shadow, candidate] { XCTAssertEqual(j.selection.canonicalChannels, [], "no expert here is production") }

        let input = contextInput()
        let reference = try published(off, input: input)
        XCTAssertEqual(reference.v2, try legacyHartAlone(off.inferred), "the policy leaves HART alone byte-identical")
        for j in [shadow, candidate] {
            let p = try published(j, input: input)
            XCTAssertEqual(p.v1, reference.v1, "v1 epochs")
            XCTAssertEqual(p.v2, reference.v2, "v2 day document")
        }

        // The single-expert candidate rows decode from the same selection, and still never touch the published one.
        let context = ActivityLane.ContextDayBuild(built: nil, input: input, generatedAt: generatedAt,
                                                   selection: candidate.selection, inputRevision: revision)
        var stats = ActivityLane.Stats()
        let gaitRow = ActivityLane.gaitWindowsRow(day: day, eldernet: try XCTUnwrap(candidate.eldernet),
                                                  collector: candidate.inferred.gaitQuality, context: context,
                                                  stats: &stats)
        let motionRow = ActivityLane.motionHeadsRow(day: day, inertia: try XCTUnwrap(candidate.inertia),
                                                    collector: candidate.inferred.motionHeads, context: context,
                                                    stats: &stats)
        guard case .document(let gaitDoc, _)? = gaitRow.candidate else { return XCTFail("gait candidate withheld") }
        guard case .document(let motionDoc, _)? = motionRow.candidate else { return XCTFail("motion candidate withheld") }
        XCTAssertNotNil(gaitDoc.versions.gaitQuality)
        XCTAssertNotNil(motionDoc.versions.motionHeads)
        XCTAssertEqual(try published(candidate, input: input).v2, reference.v2)

        // Each row carries the authority block the migration copies out, with the release it may be used under.
        for (text, channel) in [(gaitRow.payload, "gait_quality"), (motionRow.payload, "motion_heads")] {
            let p = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(text).utf8)) as? [String: Any])
            let authority = try XCTUnwrap((p["summary"] as? [String: Any])?["authority"] as? [String: Any])
            XCTAssertEqual(authority["channel"] as? String, channel)
            XCTAssertEqual(authority["policy"] as? String, ActivityExpertSelection.policy)
            XCTAssertEqual(authority["release_mode"] as? String, "candidate")
            XCTAssertEqual(authority["use"] as? String, "candidate")
            XCTAssertEqual(authority["input_revision"] as? String, String(revision))
        }
        // A shadow row says so.
        let shadowContext = ActivityLane.ContextDayBuild(built: nil, input: input, generatedAt: generatedAt,
                                                         selection: shadow.selection, inputRevision: revision)
        let shadowText = ActivityLane.motionHeadsPayload(day: day, inertia: try XCTUnwrap(shadow.inertia),
                                                         collector: shadow.inferred.motionHeads, context: shadowContext,
                                                         stats: &stats)
        let sp = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(shadowText).utf8)) as? [String: Any])
        let sa = try XCTUnwrap((sp["summary"] as? [String: Any])?["authority"] as? [String: Any])
        XCTAssertEqual(sa["release_mode"] as? String, "shadow")
        XCTAssertEqual(sa["use"] as? String, "none")
    }

    func testProductionExpertsShapeThePublishedDecode() throws {
        let off = try job(eldernet: nil, inertia: nil)
        let production = try job(eldernet: try eldernet(.production),
                                 inertia: try inertia(.production, kind: "inertia1", tier: "production"))
        XCTAssertEqual(production.selection.canonicalChannels, [.gaitQuality, .motionHeads])
        XCTAssertEqual(production.selection.candidateChannels, [.gaitQuality, .motionHeads])

        let input = contextInput()
        let reference = try published(off, input: input)
        let p = try published(production, input: input)
        XCTAssertEqual(p.v1, reference.v1, "the v1 epochs stay HART's alone")
        XCTAssertNotEqual(p.v2, reference.v2, "production evidence reaches the published day document")
        let canonical = production.selection.canonical(input, base: ActivityDecoderConfig())
        let publishedDoc = ActivityContextDays.dayDocument(input: canonical.input, generatedAt: generatedAt,
                                                           config: canonical.config)
        XCTAssertNotNil(publishedDoc.versions.gaitQuality)
        XCTAssertNotNil(publishedDoc.versions.motionHeads)
        // The canonical decode is exactly the selection's decode of its production channels.
        let both = production.selection.decode(input, base: ActivityDecoderConfig(), channels: [.gaitQuality, .motionHeads])
        XCTAssertEqual(ActivityCandidateDays.documentDigest(publishedDoc),
                       ActivityCandidateDays.documentDigest(ActivityContextDays.dayDocument(
                        input: both.input, generatedAt: generatedAt, config: both.config)))

        // The rows: no comparison decode, no withheld reason, released as production and used canonically.
        let built = try ActivityContextDays.build(input: canonical.input, day: day, modelVersion: "m",
                                                  preprocessingVersion: "p", generatedAt: generatedAt,
                                                  config: canonical.config)
        let context = ActivityLane.ContextDayBuild(built: built, input: input, generatedAt: generatedAt,
                                                   selection: production.selection, inputRevision: revision)
        var stats = ActivityLane.Stats()
        let gaitRow = ActivityLane.gaitWindowsRow(day: day, eldernet: try XCTUnwrap(production.eldernet),
                                                  collector: production.inferred.gaitQuality, context: context,
                                                  stats: &stats)
        let motionRow = ActivityLane.motionHeadsRow(day: day, inertia: try XCTUnwrap(production.inertia),
                                                    collector: production.inferred.motionHeads, context: context,
                                                    stats: &stats)
        guard case .notRequested? = gaitRow.candidate, case .notRequested? = motionRow.candidate else {
            return XCTFail("production rows make no comparison decode")
        }
        for (text, channel) in [(gaitRow.payload, "gait_quality"), (motionRow.payload, "motion_heads")] {
            let row = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try XCTUnwrap(text).utf8)) as? [String: Any])
            XCTAssertEqual(row["mode"] as? String, "production", channel)
            XCTAssertTrue(row["candidate_document"] is NSNull, channel)
            XCTAssertTrue(row["withheld_reason"] is NSNull, channel)
            let authority = try XCTUnwrap((row["summary"] as? [String: Any])?["authority"] as? [String: Any])
            XCTAssertEqual(authority["channel"] as? String, channel)
            XCTAssertEqual(authority["release_mode"] as? String, "production")
            XCTAssertEqual(authority["use"] as? String, "canonical")
        }

        // The joint candidate still runs: its arm of exactly the production channels is the published document, and
        // reusing that document decodes to the same bytes as a fresh decode of every arm.
        let text = try XCTUnwrap(ActivityLane.candidateDayPayload(
            day: day, inputRevision: revision, context: context,
            motionCandidate: motionRow.candidate, gaitCandidate: gaitRow.candidate, stats: &stats))
        let decoded = ActivityCandidateDays.decode(selection: production.selection, input: input, generatedAt: generatedAt)
        XCTAssertEqual(Set(decoded.arms.keys), ["hart", "hart+gait_quality", "hart+motion_heads", "joint"])
        XCTAssertEqual(decoded.arms["joint"]?.documentSha256, ActivityCandidateDays.documentDigest(publishedDoc))
        XCTAssertEqual(decoded.arms["hart"]?.documentSha256,
                       ActivityCandidateDays.documentDigest(ActivityContextDays.dayDocument(input: input,
                                                                                            generatedAt: generatedAt)))
        XCTAssertEqual(text, try ActivityCandidateDays.payload(day: day, inputRevision: revision,
                                                               selection: production.selection, decoded: decoded))
        let row = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let decisions = try XCTUnwrap(row["decisions"] as? [[String: Any]])
        XCTAssertEqual(Set(decisions.compactMap { $0["use"] as? String }), ["canonical"])

        // One production channel beside a candidate one: only the production channel is published.
        let mixed = try job(eldernet: try eldernet(.candidate),
                            inertia: try inertia(.production, kind: "inertia1", tier: "production"))
        XCTAssertEqual(mixed.selection.canonicalChannels, [.motionHeads])
        XCTAssertEqual(mixed.selection.use(of: .gaitQuality), .candidate)
        let mixedCanonical = mixed.selection.canonical(input, base: ActivityDecoderConfig())
        let mixedDoc = ActivityContextDays.dayDocument(input: mixedCanonical.input, generatedAt: generatedAt,
                                                       config: mixedCanonical.config)
        XCTAssertNil(mixedDoc.versions.gaitQuality, "a candidate channel never reaches the published decode")
        XCTAssertNotNil(mixedDoc.versions.motionHeads)
    }

    // MARK: - Joint candidate

    func testJointCandidateInvariants() throws {
        let both = try job(eldernet: try eldernet(.candidate),
                           inertia: try inertia(.candidate, kind: "inertia1", tier: "candidate"))
        let input = contextInput()
        let decoded = ActivityCandidateDays.decode(selection: both.selection, input: input, generatedAt: generatedAt)
        XCTAssertEqual(Set(decoded.arms.keys), ["hart", "hart+gait_quality", "hart+motion_heads", "joint"])
        let joint = try XCTUnwrap(decoded.joint, decoded.withheldReason ?? "joint withheld")
        XCTAssertNotNil(joint.versions.gaitQuality)
        XCTAssertNotNil(joint.versions.motionHeads, "one decode with both channels")
        XCTAssertNil(decoded.arms["joint"]?.sameAs)

        // All off == HART alone == the published (canonical) document.
        let canonical = both.selection.canonical(input, base: ActivityDecoderConfig())
        let publishedDoc = ActivityContextDays.dayDocument(input: canonical.input, generatedAt: generatedAt,
                                                           config: canonical.config)
        XCTAssertEqual(decoded.arms["hart"]?.documentSha256, ActivityCandidateDays.documentDigest(publishedDoc))
        let legacy = ActivityContextDays.dayDocument(input: input, generatedAt: generatedAt)
        XCTAssertEqual(ActivityCandidateDays.documentDigest(legacy), ActivityCandidateDays.documentDigest(publishedDoc))
        let none = try job(eldernet: nil, inertia: nil)
        XCTAssertTrue(none.selection.candidateArms.isEmpty)
        XCTAssertNil(ActivityCandidateDays.decode(selection: none.selection, input: input, generatedAt: generatedAt).joint)

        // Disabling an expert reproduces its ablation exactly.
        let gaitOnly = try job(eldernet: try eldernet(.candidate), inertia: nil)
        let motionOnly = try job(eldernet: nil, inertia: try inertia(.candidate, kind: "inertia1", tier: "candidate"))
        let g = ActivityCandidateDays.decode(selection: gaitOnly.selection, input: input, generatedAt: generatedAt)
        let m = ActivityCandidateDays.decode(selection: motionOnly.selection, input: input, generatedAt: generatedAt)
        XCTAssertEqual(ActivityCandidateDays.documentDigest(try XCTUnwrap(g.joint)),
                       decoded.arms["hart+gait_quality"]?.documentSha256)
        XCTAssertEqual(ActivityCandidateDays.documentDigest(try XCTUnwrap(m.joint)),
                       decoded.arms["hart+motion_heads"]?.documentSha256)
        XCTAssertEqual(g.arms["joint"]?.sameAs, "hart+gait_quality", "one expert: the joint arm is its ablation")
        XCTAssertEqual(g.arms["hart"]?.documentSha256, decoded.arms["hart"]?.documentSha256)

        // The single-expert rows' documents, reused as ablations, equal fresh decodes byte for byte.
        let context = ActivityLane.ContextDayBuild(built: nil, input: input, generatedAt: generatedAt,
                                                   selection: both.selection, inputRevision: revision)
        var stats = ActivityLane.Stats()
        let gaitRow = ActivityLane.gaitWindowsRow(day: day, eldernet: try XCTUnwrap(both.eldernet),
                                                  collector: both.inferred.gaitQuality, context: context, stats: &stats)
        let motionRow = ActivityLane.motionHeadsRow(day: day, inertia: try XCTUnwrap(both.inertia),
                                                    collector: both.inferred.motionHeads, context: context, stats: &stats)
        let text = try XCTUnwrap(ActivityLane.candidateDayPayload(
            day: day, inputRevision: revision,
            context: ActivityLane.ContextDayBuild(built: try ActivityContextDays.build(
                input: canonical.input, day: day, modelVersion: "m", preprocessingVersion: "p",
                generatedAt: generatedAt, config: canonical.config),
                input: input, generatedAt: generatedAt, selection: both.selection, inputRevision: revision),
            motionCandidate: motionRow.candidate, gaitCandidate: gaitRow.candidate, stats: &stats))
        let fresh = try ActivityCandidateDays.payload(day: day, inputRevision: revision, selection: both.selection,
                                                      decoded: decoded)
        XCTAssertEqual(text, fresh, "reused documents decode to the same bytes")
        XCTAssertEqual(stats.candidateJointDocuments, 1)

        // The stored payload is what the fenced RPC validates.
        let p = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(p["schema"] as? String, "activity-candidate-1")
        XCTAssertEqual(p["policy"] as? String, ActivityExpertSelection.policy)
        XCTAssertEqual(p["selection_digest"] as? String, both.selection.digest)
        XCTAssertEqual((p["input_revision"] as? NSNumber)?.int64Value, revision)
        XCTAssertTrue(p["withheld_reason"] is NSNull)
        let arms = try XCTUnwrap(p["arms"] as? [String: Any])
        for (_, value) in arms {
            let arm = try XCTUnwrap(value as? [String: Any])
            XCTAssertEqual((arm["document_sha256"] as? String)?.count, 64)
            XCTAssertNotNil(arm["summary"] as? [String: Any])
        }
    }

    func testOnlyCandidateModeStoresAJointCandidate() throws {
        let shadow = try job(eldernet: try eldernet(.shadow), inertia: try inertia(.shadow, kind: "standin", tier: "shadow"))
        let decoded = ActivityCandidateDays.decode(selection: shadow.selection, input: contextInput(), generatedAt: generatedAt)
        XCTAssertNil(decoded.joint)
        XCTAssertTrue(decoded.arms.isEmpty)
        XCTAssertTrue(decoded.withheldReason?.hasPrefix("no_candidate_channel") ?? false)
        // A stand-in encoder in candidate mode never qualifies: its channel stays out of every candidate arm.
        let standin = try job(eldernet: nil, inertia: try inertia(.candidate, kind: "standin", tier: "candidate"))
        XCTAssertEqual(standin.selection.use(of: .motionHeads), .none)
        XCTAssertEqual(standin.selection.decision(for: .motionHeads)?.reason, "encoder_kind_standin")
        XCTAssertNil(ActivityCandidateDays.decode(selection: standin.selection, input: contextInput(),
                                                  generatedAt: generatedAt).joint)
    }

    // MARK: - ElderNet route

    func testElderNetHasOneRouteAndTheEmbeddedCopyNeverVotes() throws {
        let embedded = embeddedWindows()
        let withEmbedded = contextInput(embedded: embedded)
        // Without the standalone route: the embedded copy is shadow, so the published decode is HART alone.
        let hartOnly = try job(eldernet: nil, inertia: nil, embedded: embedded)
        XCTAssertEqual(hartOnly.selection.use(of: .embeddedGait), .none)
        XCTAssertEqual(hartOnly.selection.decision(for: .embeddedGait)?.reason, "release_mode_shadow")
        let off = try job(eldernet: nil, inertia: nil)
        XCTAssertEqual(try published(hartOnly, input: withEmbedded).v2, try published(off, input: contextInput()).v2)
        // The embedded windows do reach a decode that is handed them directly: the exclusion is the policy's.
        XCTAssertNotEqual(try legacyHartAlone(off.inferred),
                          try ActivityContextDays.build(input: withEmbedded, day: day, modelVersion: off.inferred.versions.model,
                                                        preprocessingVersion: off.inferred.versions.preprocessing,
                                                        generatedAt: generatedAt).payloadText,
                          "the fixture's embedded windows would change the decode if they were admitted")

        // With the standalone route: it supersedes the embedded copy, and the candidate decodes equal those of a day
        // that never had embedded windows (no double count).
        let both = try job(eldernet: try eldernet(.candidate), inertia: nil, embedded: embedded)
        XCTAssertEqual(both.selection.decision(for: .embeddedGait)?.reason, "superseded_by_standalone_route")
        XCTAssertEqual(both.selection.candidateChannels, [.gaitQuality])
        let plain = try job(eldernet: try eldernet(.candidate), inertia: nil)
        let a = ActivityCandidateDays.decode(selection: both.selection, input: withEmbedded, generatedAt: generatedAt)
        let b = ActivityCandidateDays.decode(selection: plain.selection, input: contextInput(), generatedAt: generatedAt)
        XCTAssertEqual(a.arms["hart+gait_quality"]?.documentSha256, b.arms["hart+gait_quality"]?.documentSha256)
        XCTAssertEqual(a.arms["hart"]?.documentSha256, b.arms["hart"]?.documentSha256)
        XCTAssertEqual(try published(both, input: withEmbedded).v2, try published(plain, input: contextInput()).v2)
    }

    /// The stream-day decode (stored HART windows, no raw IMU) reads the same policy: stored embedded windows are
    /// shadow and never reach the published stream-day document.
    func testStreamDaysIgnoreStoredEmbeddedGaitWindows() throws {
        var sim = DaySim(start: dayStart + 36_000)
        sim.still(120); sim.walk(120); sim.still(120)
        let plain = ActivityEncoderWindowsStore.windowSet(windows: sim.windows, dayStart: dayStart, dayEnd: dayEnd,
                                                          modelVersion: "stub-model", preprocessingVersion: "stub-preprocess")
        let embedded = ActivityEncoderWindowsStore.windowSet(windows: sim.windows, dayStart: dayStart, dayEnd: dayEnd,
                                                             modelVersion: "stub-model",
                                                             preprocessingVersion: "stub-preprocess",
                                                             gaitWindows: embeddedWindows())
        XCTAssertFalse(embedded.gaitWindows.isEmpty)
        let now = dayEnd + 20 * 3600
        let a = try XCTUnwrap(try ActivityContextDays.buildStreamDay(day: day, dayBounds: (dayStart, dayEnd),
                                                                     streams: sim.streams, sleep: [], exercise: [],
                                                                     now: now, encoder: plain))
        let b = try XCTUnwrap(try ActivityContextDays.buildStreamDay(day: day, dayBounds: (dayStart, dayEnd),
                                                                     streams: sim.streams, sleep: [], exercise: [],
                                                                     now: now, encoder: embedded))
        XCTAssertEqual(a.payloadText, b.payloadText)
    }

    // MARK: - Children and heartbeat identity

    /// The HART child runs with its thread caps and without its in-process ElderNet copy (one ElderNet route).
    func testTheHartChildIsCappedAndRunsNoElderNetCopy() {
        typealias Config = ActivityPythonService.Config
        XCTAssertEqual(Config.hartThreads([:]), 1)
        XCTAssertEqual(Config.hartThreads(["FRWHOOP_ACTIVITY_THREADS": "2"]), 2)
        XCTAssertEqual(Config.hartThreads(["FRWHOOP_ACTIVITY_THREADS": "99"]), 1, "out of range falls back to 1")
        let c = Config(pythonBin: "/usr/bin/python3", activityHome: "/x", modelDir: nil, serveArgs: [],
                       requestTimeoutSeconds: 5, maxRequestBytes: 1, maxResponseLineBytes: 1, restartCap: 1,
                       restartCooldownSeconds: 1).hartChild(threads: 2)
        XCTAssertEqual(c.extraEnvironment["ACTIVITY_GAIT_EXPERT"], "")
        XCTAssertEqual(c.extraEnvironment["ACTIVITY_THREADS"], "2")
        XCTAssertEqual(c.numericalThreads, 2)
    }

    /// The heartbeat identity names what each child measured it loaded, the policy and the last selection.
    func testTheLaneIdentityNamesMeasuredDigestsAndTheSelection() throws {
        let hart = try hartService()
        _ = try hart.ping()
        let stage = try eldernet(.shadow)
        _ = stage.begin()
        let id = ActivityLane.identity(service: hart, inertia: nil, eldernet: stage, selectionDigest: "abc")
        XCTAssertEqual(id["expert_policy"], ActivityExpertSelection.policy)
        XCTAssertEqual(id["selection_digest"], "abc")
        XCTAssertEqual(id["hart.loaded_digest"], hart.loadedDigest)
        XCTAssertNotNil(id["hart.checkpoint_sha256"])
        XCTAssertEqual(id["eldernet.weights_digest"], try eldernetDigest())
        XCTAssertEqual(id["eldernet.mode"], "shadow")
        XCTAssertNil(id["inertia.mode"])
    }
}

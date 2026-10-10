import XCTest
@testable import StrandAnalytics

/// The expert-authority policy (`ActivityExpertSelection`, docs/model-integration/activity-authority.md): shadow and
/// candidate rows never shape the canonical decode while production rows (ElderNet gait, ActiNet motion heads) with
/// their pins do, the joint candidate is the union of its ablations under the shared budget, ElderNet has one route,
/// and the final-output comparison the candidate rows store.
final class ActivityContextAuthorityTests: XCTestCase {

    private let pinVersion = GaitKit.version
    private var pinDigest: String { GaitKit.model().weightsDigest }

    /// A day with desk work, a walk and stillness, its HART windows every 2 s (walking during the walk), as stored
    /// rows: the input the worker's raw-IMU job and the phone both decode.
    private func day() -> (input: ActivityContextTrackInput, walk: ClosedRange<Int>) {
        var sim = ActivitySim(start: 1_760_000_000, seed: 11)
        sim.desk(240); let walkStart = sim.ts; sim.walk(300); let walkEnd = sim.ts; sim.still(240)
        var input = sim.trackInput()
        input.encoderWindows = stride(from: input.dayStart + 4, to: input.dayEnd, by: 2).map { e in
            let walking = e > walkStart + 4 && e <= walkEnd
            let probs = walking ? ["walking": 0.82, "stationary": 0.08, "running": 0.04, "other_movement": 0.06]
                : ["stationary": 0.86, "walking": 0.06, "running": 0.02, "other_movement": 0.06]
            return ActivityWindowPrediction(startTs: e - 4, endTs: e, label: walking ? .walking : .stationary,
                                            probs: probs)
        }
        input.encoderVersion = "hart-test-1"
        return (input, walkStart...walkEnd)
    }

    private func gaitWindows(_ input: ActivityContextTrackInput, walk: ClosedRange<Int>) -> [GaitQualityWindow] {
        stride(from: input.dayStart + 10, to: input.dayEnd, by: 5).map { e in
            GaitKit.window(endingAt: e, p: walk.contains(e - 5) ? 0.96 : 0.03)
        }
    }

    private func motionWindows(_ input: ActivityContextTrackInput, walk: ClosedRange<Int>) -> [MotionHeadsWindow] {
        let loco = MotionHead.locomotion.classOrder
        let post = MotionHead.posture.classOrder
        let arm = MotionHead.armBehavior.classOrder
        return stride(from: input.dayStart + 10, to: input.dayEnd, by: 5).map { e in
            let walking = walk.contains(e - 5)
            return MotionHeadsKit.window(endingAt: e,
                                         posture: MotionHeadsKit.peaked(post, walking ? "upright_stationary" : "seated_likely", 0.7),
                                         locomotion: MotionHeadsKit.peaked(loco, walking ? "walking" : "stationary", 0.8),
                                         arm: MotionHeadsKit.peaked(arm, walking ? "other" : "desk_like", 0.6))
        }
    }

    private func gaitSource(_ input: ActivityContextTrackInput, walk: ClosedRange<Int>, release: ActivityReleaseMode,
                            pinned: Bool = true, prior: Double? = 0.085, revision: Int64? = 7,
                            day: String? = "2025-10-09") -> GaitQualitySource {
        GaitQualitySource(track: GaitQualityTrackInput(model: GaitKit.model(), windows: gaitWindows(input, walk: walk)),
                          releaseMode: release, route: .standalone,
                          expectedModelVersion: pinned ? pinVersion : nil, expectedWeightsDigest: pinned ? pinDigest : nil,
                          gaitPrior: prior, inputRevision: revision, day: day)
    }

    private func motionSource(_ input: ActivityContextTrackInput, walk: ClosedRange<Int>, mode: ActivityReleaseMode,
                              bundle: MotionHeadsBundleInfo = MotionHeadsKit.bundle(), pinned: Bool = true,
                              revision: Int64? = 7) -> MotionHeadsSource {
        MotionHeadsSource(track: MotionHeadsTrackInput(bundle: bundle, windows: motionWindows(input, walk: walk)),
                          mode: mode, expectedBundleSHA256: pinned ? bundle.bundleSha256 : nil,
                          inputRevision: revision, day: "2025-10-09")
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    private func document(_ decode: (input: ActivityContextTrackInput, config: ActivityDecoderConfig))
        -> ActivityContextDayDocument {
        ActivityContextDayBuilder.update(cached: nil, input: decode.input, now: decode.input.dayEnd,
                                         config: decode.config).document
    }

    // MARK: - Release modes

    func testARecordedModeIsNeverRaised() {
        XCTAssertEqual(ActivityReleaseMode(recorded: nil), .shadow)
        XCTAssertEqual(ActivityReleaseMode(recorded: "promoted"), .shadow)
        XCTAssertEqual(ActivityReleaseMode(recorded: "Candidate"), .candidate)
        XCTAssertEqual(ActivityReleaseMode.production.lowered(to: .candidate), .candidate)
        XCTAssertEqual(ActivityReleaseMode.shadow.lowered(to: .production), .shadow)
        // A candidate row without its pins or π is shadow; a stand-in or shadow-tier bundle is shadow.
        let (input, walk) = day()
        let unpinned = ActivityExpertSelection.select(gaitQuality: [gaitSource(input, walk: walk, release: .candidate,
                                                                                pinned: false)])
        XCTAssertEqual(unpinned.decisions.first?.releaseMode, .shadow)
        XCTAssertEqual(unpinned.decisions.first?.reason, "model_not_pinned")
        let noPrior = ActivityExpertSelection.select(gaitQuality: [gaitSource(input, walk: walk, release: .candidate,
                                                                               prior: nil)])
        XCTAssertEqual(noPrior.decisions.first?.reason, "gait_prior_not_set")
        XCTAssertEqual(motionSource(input, walk: walk, mode: .candidate,
                                    bundle: MotionHeadsKit.bundle(kind: .standin)).releaseMode, .shadow)
        XCTAssertEqual(motionSource(input, walk: walk, mode: .production,
                                    bundle: MotionHeadsKit.bundle(tier: .candidate)).releaseMode, .candidate)
    }

    // MARK: - Acceptance: shadow / candidate rows never shape the canonical decode

    /// The replay the spec asks for, on the client side: the stored HART windows plus a shadow ElderNet row, a
    /// candidate ElderNet row and a candidate Inertia row decode to exactly HART alone, byte for byte, through the
    /// shared selection the phone and the worker use; and the production config the phone used to build from such a
    /// row is refused by the track builder itself.
    func testShadowAndCandidateRowsCannotChangeTheCanonicalDecode() throws {
        let (input, walk) = day()
        let hartAlone = document((input, ActivityDecoderConfig()))
        let base = ActivityDecoderConfig()
        let mixes: [(String, [GaitQualitySource], [MotionHeadsSource])] = [
            ("shadow gait", [gaitSource(input, walk: walk, release: .shadow)], []),
            ("candidate gait", [gaitSource(input, walk: walk, release: .candidate)], []),
            ("candidate heads", [], [motionSource(input, walk: walk, mode: .candidate)]),
            ("both candidate", [gaitSource(input, walk: walk, release: .candidate)],
             [motionSource(input, walk: walk, mode: .candidate)]),
            ("production tier bundle, candidate mode", [],
             [motionSource(input, walk: walk, mode: .candidate, bundle: MotionHeadsKit.bundle(tier: .production))]),
        ]
        for (label, gait, heads) in mixes {
            let selection = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], gaitQuality: gait,
                                                           motionHeads: heads)
            XCTAssertTrue(selection.canonicalChannels.isEmpty, label)
            let canonical = selection.canonical(input, base: base)
            XCTAssertNil(canonical.input.gaitQuality, label)
            XCTAssertNil(canonical.input.motionHeads, label)
            XCTAssertNil(canonical.config.gaitQuality, label)
            XCTAssertNil(canonical.config.motionHeads, label)
            XCTAssertEqual(canonical.config.cacheTag, base.cacheTag, label)
            XCTAssertEqual(try json(document(canonical)), try json(hartAlone), label)
        }

        // The pre-fix phone: a production config built around a candidate row's windows. The track builder refuses
        // production evidence from windows that are not released at production, so the day decodes as HART alone.
        var stored = input
        var track = GaitQualityTrackInput(model: GaitKit.model(), windows: gaitWindows(input, walk: walk))
        track.releaseMode = .candidate
        stored.gaitQuality = track
        let upgraded = GaitKit.config(mode: .production, prior: 0.085, pinVersion: pinVersion, pinDigest: pinDigest)
        XCTAssertNil(upgraded.gaitQuality?.evidenceRefusal, "the config itself is valid")
        XCTAssertFalse(ActivityContextTrackBuilder.acceptsGaitQuality(for: stored, config: upgraded))
        XCTAssertEqual(TrackKit.builtTrack(stored, config: upgraded).gaitQuality?.refusal, "release_mode_candidate")
        XCTAssertEqual(try json(document((stored, upgraded))), try json(hartAlone))
        // Unrecorded windows (built in memory) cannot feed a production decode either.
        stored.gaitQuality?.releaseMode = nil
        XCTAssertEqual(TrackKit.builtTrack(stored, config: upgraded).gaitQuality?.refusal, "release_mode_unrecorded")
        // A shadow track feeds nothing, not even a candidate decode.
        stored.gaitQuality?.releaseMode = .shadow
        XCTAssertEqual(TrackKit.builtTrack(stored, config: GaitKit.config(prior: 0.085)).gaitQuality?.refusal,
                       "release_mode_shadow")

        // The same rule for motion heads.
        var heads = MotionHeadsTrackInput(bundle: MotionHeadsKit.bundle(tier: .production),
                                          windows: motionWindows(input, walk: walk))
        heads.releaseMode = .candidate
        var withHeads = input
        withHeads.motionHeads = heads
        let production = MotionHeadsKit.config(MotionHeadsKit.bundle(tier: .production), mode: .production)
        XCTAssertNil(production.motionHeads?.evidenceRefusal)
        XCTAssertEqual(TrackKit.builtTrack(withHeads, config: production).motionHeads?.refusal, "release_mode_candidate")
        XCTAssertEqual(try json(document((withHeads, production))), try json(hartAlone))
    }

    /// The extension point: a row released at production (with its pins and π) shapes the canonical decode, with the
    /// config built from the row, so a worker and a phone that hold the row decode the same evidence.
    func testAProductionRowShapesTheCanonicalDecodeWithTheRowsOwnConfig() throws {
        let (input, walk) = day()
        let source = gaitSource(input, walk: walk, release: .production)
        let selection = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], gaitQuality: [source])
        XCTAssertEqual(selection.canonicalChannels, [.gaitQuality])
        let canonical = selection.canonical(input, base: ActivityDecoderConfig())
        let config = try XCTUnwrap(canonical.config.gaitQuality)
        XCTAssertEqual(config.mode, .production)
        XCTAssertEqual(config.gaitPrior, 0.085)
        XCTAssertEqual(config.expectedWeightsDigest, pinDigest)
        XCTAssertEqual(canonical.input.gaitQuality?.releaseMode, .production)
        let doc = document(canonical)
        XCTAssertEqual(doc.versions.gaitQuality, config.provenanceStamp)
        // Built twice from the same row: the same config, the same cache tag.
        let again = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], gaitQuality: [source])
            .canonical(input, base: ActivityDecoderConfig())
        XCTAssertEqual(again.config, canonical.config)
        XCTAssertEqual(try json(document(again)), try json(doc))
        // A row from another input revision of the day is not combined with these HART windows.
        let stale = ActivityExpertSelection.select(revisions: ["2025-10-09": 8], gaitQuality: [source])
        XCTAssertTrue(stale.canonicalChannels.isEmpty)
        XCTAssertEqual(stale.decisions.first?.reason, "input_revision_mismatch")
    }

    /// Production ActiNet motion heads, pinned and evaluated at production tier, shape the canonical decode with the
    /// config built from the row, and the runs they shaped name them; the same windows at candidate never do.
    func testProductionMotionHeadsShapeTheCanonicalDecode() throws {
        let (input, walk) = day()
        let base = ActivityDecoderConfig()
        let hartAlone = try json(document((input, base)))
        let bundle = MotionHeadsKit.bundle(kind: .actinet, tier: .production)
        let source = motionSource(input, walk: walk, mode: .production, bundle: bundle)
        let selection = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], motionHeads: [source])
        XCTAssertEqual(selection.canonicalChannels, [.motionHeads])
        XCTAssertEqual(selection.decision(for: .motionHeads)?.use, .canonical)
        let canonical = selection.canonical(input, base: base)
        let config = try XCTUnwrap(canonical.config.motionHeads)
        XCTAssertEqual(config.mode, .production)
        XCTAssertEqual(config.expectedBundleSHA256, bundle.bundleSha256)
        XCTAssertFalse(config.allowStandInEvidenceForTesting)
        XCTAssertEqual(canonical.input.motionHeads?.releaseMode, .production)
        XCTAssertNotEqual(canonical.config.cacheTag, base.cacheTag)
        let doc = document(canonical)
        XCTAssertEqual(doc.versions.motionHeads, config.provenanceStamp)
        XCTAssertTrue(config.provenanceStamp?.hasPrefix("actinet:") ?? false)
        XCTAssertNotEqual(try json(doc), hartAlone)
        XCTAssertTrue(doc.runs.contains { $0.experts.contains("motion_heads") })
        // Built twice from the same row: the same config, the same document.
        let again = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], motionHeads: [source])
            .canonical(input, base: base)
        XCTAssertEqual(again.config, canonical.config)
        XCTAssertEqual(try json(document(again)), try json(doc))

        // A candidate arm of candidate heads uses them but never names them as production evidence.
        let candidate = ActivityExpertSelection.select(revisions: ["2025-10-09": 7],
                                                       motionHeads: [motionSource(input, walk: walk, mode: .candidate,
                                                                                  bundle: bundle)])
        XCTAssertTrue(candidate.canonicalChannels.isEmpty)
        let arm = document(candidate.decode(input, base: base, channels: [.motionHeads]))
        XCTAssertNotNil(arm.versions.motionHeads)
        XCTAssertFalse(arm.runs.contains { $0.experts.contains("motion_heads") })

        // Production gait and production heads together: both shape the canonical decode.
        let both = ActivityExpertSelection.select(revisions: ["2025-10-09": 7],
                                                  gaitQuality: [gaitSource(input, walk: walk, release: .production)],
                                                  motionHeads: [source])
        XCTAssertEqual(both.canonicalChannels, [.gaitQuality, .motionHeads])
        let joint = both.canonical(input, base: base)
        XCTAssertEqual(joint.config.gaitQuality?.mode, .production)
        XCTAssertEqual(joint.config.motionHeads?.mode, .production)
        // Production gait beside candidate heads: only the gait reaches the canonical decode.
        let mixed = ActivityExpertSelection.select(revisions: ["2025-10-09": 7],
                                                   gaitQuality: [gaitSource(input, walk: walk, release: .production)],
                                                   motionHeads: [motionSource(input, walk: walk, mode: .candidate,
                                                                              bundle: bundle)])
        XCTAssertEqual(mixed.canonicalChannels, [.gaitQuality])
        XCTAssertEqual(mixed.candidateChannels, [.gaitQuality, .motionHeads])
        XCTAssertNil(mixed.canonical(input, base: base).config.motionHeads)
    }

    /// A row recorded at production is lowered exactly as a candidate one: no pin, a stand-in encoder, a bundle tier
    /// below production or another input revision keep it out of the canonical decode.
    func testProductionRowsAreStillLoweredByPinsTierEncoderAndRevision() throws {
        let (input, walk) = day()
        let base = ActivityDecoderConfig()
        let hartAlone = try json(document((input, base)))
        let cases: [(String, MotionHeadsSource, ActivityExpertSelection.Use, String?)] = [
            ("unpinned", motionSource(input, walk: walk, mode: .production,
                                      bundle: MotionHeadsKit.bundle(kind: .actinet, tier: .production), pinned: false),
             .none, "bundle_sha256_not_pinned"),
            ("stand-in", motionSource(input, walk: walk, mode: .production,
                                      bundle: MotionHeadsKit.bundle(kind: .standin, tier: .production)),
             .none, "encoder_kind_standin"),
            ("shadow tier", motionSource(input, walk: walk, mode: .production,
                                         bundle: MotionHeadsKit.bundle(kind: .actinet, tier: .shadow)),
             .none, "evidence_tier_shadow"),
            ("candidate tier", motionSource(input, walk: walk, mode: .production,
                                            bundle: MotionHeadsKit.bundle(kind: .actinet, tier: .candidate)),
             .candidate, nil),
            ("other revision", motionSource(input, walk: walk, mode: .production,
                                            bundle: MotionHeadsKit.bundle(kind: .actinet, tier: .production), revision: 8),
             .none, "input_revision_mismatch"),
        ]
        for (label, source, use, reason) in cases {
            let s = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], motionHeads: [source])
            XCTAssertEqual(s.use(of: .motionHeads), use, label)
            XCTAssertEqual(s.decision(for: .motionHeads)?.reason, reason, label)
            XCTAssertTrue(s.canonicalChannels.isEmpty, label)
            let canonical = s.canonical(input, base: base)
            XCTAssertNil(canonical.config.motionHeads, label)
            XCTAssertEqual(try json(document(canonical)), hartAlone, label)
        }
        // ElderNet the same way: a production row without its pins or π is shadow.
        for (label, source, reason) in [
            ("gait unpinned", gaitSource(input, walk: walk, release: .production, pinned: false), "model_not_pinned"),
            ("gait without prior", gaitSource(input, walk: walk, release: .production, prior: nil), "gait_prior_not_set"),
        ] {
            let s = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], gaitQuality: [source])
            XCTAssertEqual(s.decision(for: .gaitQuality)?.releaseMode, .shadow, label)
            XCTAssertEqual(s.decision(for: .gaitQuality)?.reason, reason, label)
            XCTAssertTrue(s.canonicalChannels.isEmpty, label)
        }
    }

    // MARK: - Joint candidate

    func testJointCandidateIsTheUnionOfItsAblationsUnderTheSharedBudget() throws {
        let (input, walk) = day()
        let base = ActivityDecoderConfig()
        let gait = gaitSource(input, walk: walk, release: .candidate)
        let heads = motionSource(input, walk: walk, mode: .candidate)
        let selection = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], gaitQuality: [gait],
                                                       motionHeads: [heads])
        XCTAssertEqual(selection.candidateArms.map(\.name),
                       ["hart", "hart+gait_quality", "hart+motion_heads", "joint"])
        XCTAssertEqual(selection.jointArm?.channels, [.gaitQuality, .motionHeads])

        let arms = Dictionary(uniqueKeysWithValues: selection.candidateArms.map {
            ($0.name, selection.decode(input, base: base, channels: $0.channels))
        })
        let joint = try XCTUnwrap(arms["joint"])
        // The joint config is exactly the two single-expert configs together: the same tempered channels, the same
        // weights, and one accelerometer budget the decoder shares between them (ELDERNET.md §5).
        XCTAssertEqual(joint.config.gaitQuality, arms["hart+gait_quality"]?.config.gaitQuality)
        XCTAssertEqual(joint.config.motionHeads, arms["hart+motion_heads"]?.config.motionHeads)
        XCTAssertEqual(joint.config.gaitQuality?.accelerometerBudget, joint.config.motionHeads?.bodyBudget)
        // HART's own windows are untouched in every arm: nothing is averaged into the encoder channel.
        for (_, arm) in arms { XCTAssertEqual(arm.input.encoderWindows, input.encoderWindows) }
        let jointTrack = TrackKit.builtTrack(joint.input, config: joint.config)
        XCTAssertNotNil(jointTrack.snapshot.versions.gaitQuality)
        XCTAssertNotNil(jointTrack.snapshot.versions.motionHeads)
        XCTAssertGreaterThan(jointTrack.gaitQuality?.evidenceSeconds ?? 0, 0)
        XCTAssertGreaterThan(jointTrack.motionHeads?.evidenceSeconds ?? 0, 0)
        // One budget for both: scored with the joint arm's own configs, the two experts together move no mode by
        // more than T · B · ln 10 (B = the shared accelerometer budget), even when each alone is sure.
        var bare = ActivitySim(start: 1_760_000_000, seed: 9)
        var options = ActivitySim.Options()
        options.steps = false
        bare.walk(60, opt: options)
        var window = ActivityFeatureWindow()
        var last: ActivityFeatures?
        for obs in bare.observations {
            last = window.push(obs, restingHR: 60, maxHR: 190, motionHeadsHoldS: 5, gaitQualityHoldS: 5)
        }
        var f = try XCTUnwrap(last)
        f.motionHeads = MotionHeadsKit.window(endingAt: f.ts, locomotion: MotionHeadsKit.peaked(
            MotionHead.locomotion.classOrder, "walking", 0.999))
        f.gaitQuality = GaitKit.window(endingAt: f.ts, p: 0.999)
        let mh = try XCTUnwrap(PreparedMotionHeads.prepare(joint.config.motionHeads).prepared)
        let g = try XCTUnwrap(PreparedGaitQuality.prepare(joint.config.gaitQuality).0)
        let T = joint.config.evidenceTemperature
        let unscored = ActivityContextModel.score(f, temperature: T)
        let both = ActivityContextModel.score(f, temperature: T, motionHeads: mh, gaitQuality: g)
        let bound = T * max(joint.config.gaitQuality!.accelerometerBudget, joint.config.motionHeads!.bodyBudget) * log(10)
        for m in 0..<BodyMode.count {
            XCTAssertLessThanOrEqual(abs(both.logL[m] - unscored.logL[m]), bound + 1e-12, "mode \(m)")
        }
        XCTAssertGreaterThan(both.logL[BodyMode.walk.rawValue] - unscored.logL[BodyMode.walk.rawValue], 0)

        // Disabling an expert reproduces the matching ablation exactly.
        let docs = arms.mapValues { document($0) }
        let withoutHeads = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], gaitQuality: [gait],
                                                          motionHeads: [motionSource(input, walk: walk, mode: .shadow)])
        let withoutGait = ActivityExpertSelection.select(revisions: ["2025-10-09": 7],
                                                         gaitQuality: [gaitSource(input, walk: walk, release: .shadow)],
                                                         motionHeads: [heads])
        XCTAssertEqual(try json(document(withoutHeads.decode(input, base: base, channels: withoutHeads.jointArm!.channels))),
                       try json(docs["hart+gait_quality"]!))
        XCTAssertEqual(try json(document(withoutGait.decode(input, base: base, channels: withoutGait.jointArm!.channels))),
                       try json(docs["hart+motion_heads"]!))
        XCTAssertNotEqual(try json(docs["joint"]!), try json(docs["hart+gait_quality"]!))
        XCTAssertNotEqual(try json(docs["joint"]!), try json(docs["hart+motion_heads"]!))

        // All experts off: no candidate arm, and HART alone == the canonical decode == the decode of the plain input.
        let off = ActivityExpertSelection.select(revisions: ["2025-10-09": 7],
                                                 gaitQuality: [gaitSource(input, walk: walk, release: .shadow)],
                                                 motionHeads: [motionSource(input, walk: walk, mode: .shadow)])
        XCTAssertTrue(off.candidateArms.isEmpty)
        XCTAssertNil(off.jointArm)
        let plain = try json(document((input, base)))
        XCTAssertEqual(try json(docs["hart"]!), plain)
        XCTAssertEqual(try json(document(off.canonical(input, base: base))), plain)
        XCTAssertEqual(try json(document(ActivityExpertSelection.select().canonical(input, base: base))), plain)
    }

    func testStandInsAndUnevaluatedBundlesNeverQualifyARealEncoder() {
        let (input, walk) = day()
        let cases: [(MotionHeadsBundleInfo, Bool, String)] = [
            (MotionHeadsKit.bundle(kind: .standin), true, "encoder_kind_standin"),
            (MotionHeadsKit.bundle(kind: .actinet, tier: .shadow), true, "evidence_tier_shadow"),
            (MotionHeadsKit.bundle(kind: .inertia1, tier: .candidate), false, "bundle_sha256_not_pinned"),
        ]
        for (bundle, pinned, reason) in cases {
            let s = ActivityExpertSelection.select(motionHeads: [motionSource(input, walk: walk, mode: .candidate,
                                                                              bundle: bundle, pinned: pinned)])
            XCTAssertEqual(s.decisions.first?.reason, reason)
            XCTAssertEqual(s.use(of: .motionHeads), .none)
            XCTAssertTrue(s.candidateArms.isEmpty)
        }
        // The pinned ActiNet kind at candidate tier is a real encoder bundle: it qualifies for candidate arms, and the
        // selection never sets the test-only stand-in override.
        let actinet = ActivityExpertSelection.select(motionHeads: [motionSource(input, walk: walk, mode: .candidate,
                                                                                bundle: MotionHeadsKit.bundle(kind: .actinet))])
        XCTAssertEqual(actinet.use(of: .motionHeads), .candidate)
        XCTAssertEqual(actinet.motionHeadsConfig?.allowStandInEvidenceForTesting, false)
    }

    // MARK: - ElderNet: one route

    func testElderNetNeverVotesThroughBothRoutes() {
        let (input, walk) = day()
        let embedded = stride(from: input.dayStart + 10, to: input.dayEnd, by: 5).map {
            ActivityGaitWindow(startTs: $0 - 10, endTs: $0, gaitProb: 0.9, isGait: true, modelVersion: GaitKit.version)
        }
        for release in ActivityReleaseMode.allCases {
            for embeddedRelease in ActivityReleaseMode.allCases {
                let s = ActivityExpertSelection.select(
                    revisions: ["2025-10-09": 7], gaitQuality: [gaitSource(input, walk: walk, release: release)],
                    embeddedGait: EmbeddedGaitSource(windows: embedded, releaseMode: embeddedRelease))
                let decision = s.decisions.first { $0.channel == .embeddedGait }
                XCTAssertEqual(decision?.reason, "superseded_by_standalone_route")
                for arm in s.candidateArms + [ActivityExpertSelection.Arm(name: "canonical", channels: s.canonicalChannels)] {
                    let d = s.decode(input, base: ActivityDecoderConfig(), channels: arm.channels)
                    XCTAssertTrue(d.input.gaitWindows.isEmpty, "\(release) / \(embeddedRelease) / \(arm.name)")
                }
            }
        }
        // Without a standalone source the embedded windows carry no release of their own: shadow, never evidence.
        let alone = ActivityExpertSelection.select(embeddedGait: EmbeddedGaitSource(windows: embedded))
        XCTAssertEqual(alone.decisions.first?.reason, "release_mode_shadow")
        XCTAssertTrue(alone.canonical(input, base: ActivityDecoderConfig()).input.gaitWindows.isEmpty)
        // Stored HART sets still carrying them decode as without them.
        var withEmbedded = input
        withEmbedded.gaitWindows = embedded
        XCTAssertEqual(try json(document(alone.canonical(withEmbedded, base: ActivityDecoderConfig()))),
                       try json(document((input, ActivityDecoderConfig()))))
    }

    func testOnlyOneModelPerDecodeAcrossUTCDays() {
        let (input, walk) = day()
        var today = gaitSource(input, walk: walk, release: .candidate, day: "2025-10-09")
        var yesterday = gaitSource(input, walk: walk, release: .candidate, day: "2025-10-08")
        XCTAssertNotEqual(GaitKit.model(seed: "b"), GaitKit.model())
        yesterday.track = GaitQualityTrackInput(model: GaitKit.model(seed: "b"), windows: yesterday.track.windows)
        yesterday.expectedWeightsDigest = GaitKit.model(seed: "b").weightsDigest
        let s = ActivityExpertSelection.select(gaitQuality: [yesterday, today])
        XCTAssertEqual(s.gaitQualityConfig?.model, GaitKit.model())
        XCTAssertEqual(s.decisions.first { $0.day == "2025-10-08" }?.reason, "model_differs_within_decode")
        today.day = nil
        XCTAssertEqual(ActivityExpertSelection.select(gaitQuality: [today]).use(of: .gaitQuality), .candidate)
    }

    // MARK: - Final-output comparison

    func testComparisonReportsFinalOutputDiffsAndCoverage() throws {
        let ref = [
            ActivityOutputSegment(start: 0, end: 100, activityClass: .sitting, confidence: 0.8, display: "Sitting"),
            ActivityOutputSegment(start: 100, end: 200, activityClass: .unknown, confidence: 0, display: nil),
            ActivityOutputSegment(start: 200, end: 300, activityClass: .offWrist, confidence: 1, display: "Off wrist"),
        ]
        let cand = [
            ActivityOutputSegment(start: 0, end: 50, activityClass: .sitting, confidence: 0.9, display: "Sitting"),
            ActivityOutputSegment(start: 50, end: 150, activityClass: .walking, confidence: 0.7, display: "Walking"),
            ActivityOutputSegment(start: 150, end: 200, activityClass: .unknown, confidence: 0, display: "Unclear"),
            ActivityOutputSegment(start: 200, end: 300, activityClass: .offWrist, confidence: 1, display: "Off wrist"),
        ]
        let c = ActivityOutputComparison.compare(reference: ref, candidate: cand)
        XCTAssertEqual(c.commonSeconds, 300)
        XCTAssertEqual(c.classAgreementSeconds, 50 + 50 + 100)
        XCTAssertEqual(c.changes, ["sitting>walking": 50, "unknown>walking": 50])
        XCTAssertEqual(c.differences.map { [$0.start, $0.end] }, [[50, 100], [100, 150]])
        XCTAssertEqual(c.reference.onWristSeconds, 200)
        XCTAssertEqual(c.reference.coverage, 0.5)
        XCTAssertEqual(c.candidate.coverage, 0.75)
        XCTAssertEqual(c.reference.displayCoverage, 0.5)
        XCTAssertEqual(c.candidate.displayCoverage, 0.75)
        XCTAssertEqual(c.reference.classSeconds["off_wrist"], 100)
        // Over real documents: an expert arm against HART alone.
        let (input, walk) = day()
        let s = ActivityExpertSelection.select(gaitQuality: [gaitSource(input, walk: walk, release: .candidate)])
        let hart = document(s.decode(input, base: ActivityDecoderConfig(), channels: []))
        let eg = document(s.decode(input, base: ActivityDecoderConfig(), channels: [.gaitQuality]))
        let self_ = ActivityOutputComparison.compare(reference: hart, candidate: hart)
        XCTAssertEqual(self_.classAgreement, 1)
        XCTAssertTrue(self_.differences.isEmpty)
        let diff = ActivityOutputComparison.compare(reference: hart, candidate: eg)
        XCTAssertEqual(diff.commonSeconds, diff.reference.seconds)
        XCTAssertGreaterThan(diff.reference.seconds, 0)
        XCTAssertNoThrow(try json(diff))
    }

    // MARK: - Row authority block

    /// The block a producer stores round-trips, and a consumer that rebuilds its source from a stored row reaches the
    /// producer's decision; a row without a block (or one whose block claims more than the row) is never raised.
    func testTheRowAuthorityBlockRebuildsTheProducersSourceAndNeverRaisesIt() throws {
        let (input, walk) = day()
        let produced = gaitSource(input, walk: walk, release: .candidate)
        let selection = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], gaitQuality: [produced])
        let decision = try XCTUnwrap(selection.decision(for: .gaitQuality))
        XCTAssertEqual(decision.use, .candidate)
        let block = ActivityExpertAuthority(decision: decision, mode: .candidate, pinnedModelVersion: pinVersion,
                                            pinnedWeightsDigest: pinDigest, gaitPrior: 0.085)
        let text = try json(block)
        XCTAssertTrue(text.contains("\"input_revision\":\"7\""), "int64 travels as a decimal string")
        XCTAssertTrue(text.contains("\"pinned_model_version\""))
        XCTAssertFalse(text.contains("pinned_bundle_sha256"), "a gait block names no bundle")
        let decoded = try JSONDecoder().decode(ActivityExpertAuthority.self, from: Data(text.utf8))
        XCTAssertEqual(decoded, block)

        // The consumer's rebuild selects exactly what the producer did.
        let rebuilt = ActivityExpertAuthority.gaitSource(decoded, track: produced.track, recordedRelease: .candidate,
                                                         inputRevision: 7, day: "2025-10-09")
        XCTAssertEqual(rebuilt, produced)
        let again = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], gaitQuality: [rebuilt])
        XCTAssertEqual(again.digest, selection.digest)

        // No block (an older row): no pins, so shadow; the canonical decode is HART alone.
        let bare = ActivityExpertAuthority.gaitSource(nil, track: produced.track, recordedRelease: .candidate,
                                                      inputRevision: 7, day: "2025-10-09")
        let bareSelection = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], gaitQuality: [bare])
        XCTAssertEqual(bareSelection.use(of: .gaitQuality), .none)
        XCTAssertEqual(bareSelection.decision(for: .gaitQuality)?.reason, "model_not_pinned")

        // A block that claims production on a shadow-mode row decodes as shadow, and cannot lift a shadow row.
        let claim = text.replacingOccurrences(of: "\"release_mode\":\"candidate\"", with: "\"release_mode\":\"production\"")
            .replacingOccurrences(of: "\"mode\":\"candidate\"", with: "\"mode\":\"shadow\"")
        let lifted = try JSONDecoder().decode(ActivityExpertAuthority.self, from: Data(claim.utf8))
        XCTAssertEqual(lifted.releaseMode, .shadow)
        let unknown = text.replacingOccurrences(of: "\"release_mode\":\"candidate\"", with: "\"release_mode\":\"released\"")
        XCTAssertEqual(try JSONDecoder().decode(ActivityExpertAuthority.self, from: Data(unknown.utf8)).releaseMode, .shadow)
        let shadowRow = ActivityExpertAuthority.gaitSource(decoded, track: produced.track, recordedRelease: .shadow,
                                                           inputRevision: 7, day: "2025-10-09")
        XCTAssertEqual(shadowRow.releaseMode, .shadow)

        // Motion heads: the same rebuild.
        let motion = motionSource(input, walk: walk, mode: .candidate)
        let ms = ActivityExpertSelection.select(revisions: ["2025-10-09": 7], motionHeads: [motion])
        let mBlock = ActivityExpertAuthority(decision: try XCTUnwrap(ms.decision(for: .motionHeads)), mode: .candidate,
                                             pinnedBundleSHA256: motion.expectedBundleSHA256)
        let mText = try json(mBlock)
        XCTAssertTrue(mText.contains("pinned_bundle_sha256") && !mText.contains("gait_prior"))
        let mDecoded = try JSONDecoder().decode(ActivityExpertAuthority.self, from: Data(mText.utf8))
        XCTAssertEqual(ActivityExpertAuthority.motionSource(mDecoded, track: motion.track, recordedRelease: .candidate,
                                                            inputRevision: 7, day: "2025-10-09"), motion)
        XCTAssertNil(ActivityExpertAuthority.motionSource(nil, track: motion.track, recordedRelease: .candidate,
                                                          inputRevision: 7, day: "2025-10-09").expectedBundleSHA256)
    }

    // MARK: - Shadow-only channels

    /// RecGym exercise recognition is registered with the policy as a channel no source carries: whatever else the
    /// day holds, nothing selects it, so it can shape neither the canonical decode nor a candidate arm.
    func testExerciseRecognitionIsShadowOnlyAndNeverSelected() throws {
        XCTAssertEqual(Array(ActivityExpertSelection.Channel.allCases.prefix(3)), [.gaitQuality, .motionHeads, .embeddedGait],
                       "appended: the existing channels keep their order")
        let (input, walk) = day()
        let selection = ActivityExpertSelection.select(
            revisions: ["2025-10-09": 7],
            gaitQuality: [gaitSource(input, walk: walk, release: .production)],
            motionHeads: [motionSource(input, walk: walk, mode: .production)])
        XCTAssertEqual(selection.use(of: .exerciseRecognition), .none)
        XCTAssertNil(selection.decision(for: .exerciseRecognition))
        XCTAssertFalse(selection.canonicalChannels.contains(.exerciseRecognition))
        XCTAssertFalse(selection.candidateChannels.contains(.exerciseRecognition))

        let block = ActivityExpertAuthority.shadowOnly(channel: .exerciseRecognition, inputRevision: 7,
                                                       pinnedModelVersion: "recgym-cnn-transformer-e085ac0",
                                                       pinnedWeightsDigest: String(repeating: "a", count: 64))
        XCTAssertEqual(block.channel, .exerciseRecognition)
        XCTAssertEqual(block.mode, .shadow)
        XCTAssertEqual(block.releaseMode, .shadow)
        XCTAssertEqual(block.use, .none)
        XCTAssertEqual(block.reason, "shadow_only")
        let text = try json(block)
        XCTAssertTrue(text.contains("\"channel\":\"exercise_recognition\""))
        XCTAssertTrue(text.contains("\"input_revision\":\"7\""))
        XCTAssertEqual(try JSONDecoder().decode(ActivityExpertAuthority.self, from: Data(text.utf8)), block)
        let claim = text.replacingOccurrences(of: "\"release_mode\":\"shadow\"", with: "\"release_mode\":\"production\"")
        XCTAssertEqual(try JSONDecoder().decode(ActivityExpertAuthority.self, from: Data(claim.utf8)).releaseMode, .shadow,
                       "a block that claims more than its shadow mode reads as shadow")
    }
}

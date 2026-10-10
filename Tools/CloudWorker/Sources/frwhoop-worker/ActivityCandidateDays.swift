import Foundation
import StrandAnalytics

// ActivityCandidateDays.swift — the joint candidate decode of one job day and its ablations
// (docs/model-integration/activity-authority.md, "Joint candidate").
//
// One decode with HART plus every expert channel the shared policy (`ActivityExpertSelection`) admits for candidate
// decodes: the decoder's own tempered channels, correlation discounts and shared accelerometer budget, never an
// average of output vectors. Beside it, the ablations a regression is located with: HART alone and HART with each
// admitted expert alone (the single-expert documents themselves stay in their own rows' `candidate_document`), each
// with its final-output summary and its comparison against HART alone (`ActivityOutputComparison`). Stored in
// `activity_candidate_days` through its own fenced RPC under a savepoint, only while some expert runs in candidate or
// production mode (a production channel appears in the arms too, so its effect on the published decode stays
// measurable against HART alone); never published, never read by scoring or the app.

enum ActivityCandidateDays {

    static let schema = "activity-candidate-1"
    /// Rows whose `computed_at` is older than this are deleted by `prune_activity_candidate_days`.
    static let retentionDays = 30
    static let pruneBatchRows = 10_000
    static let pruneSQL = "SELECT public.prune_activity_candidate_days($1::integer, $2::integer)::text"

    enum PublishOutcome: Equatable {
        case stored(revision: Int64)
        case fenced
        case rejected(String)
    }

    /// One decode the comparison stores.
    struct Arm: Encodable {
        var channels: [String]
        /// The expert stamps on the decode (`versions.motion_heads` / `versions.gait_quality`), present only for
        /// the channels that really shaped it.
        var stamps: [String: String]
        /// sha256 of the arm's day document (sorted keys): equal digests are byte-identical decodes.
        var documentSha256: String
        var summary: ActivityOutputSummary
        /// Against HART alone; nil for the HART arm itself.
        var comparison: ActivityOutputComparison?
        var gaitQuality: GaitQualityTrackReport?
        var motionHeads: MotionHeadsTrackReport?
        /// The arm that decoded exactly the same channels (the joint arm when only one expert was admitted).
        var sameAs: String?

        enum CodingKeys: String, CodingKey {
            case channels, stamps, documentSha256 = "document_sha256", summary, comparison
            case gaitQuality = "gait_quality", motionHeads = "motion_heads", sameAs = "same_as"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(channels, forKey: .channels)
            try c.encode(stamps, forKey: .stamps)
            try c.encode(documentSha256, forKey: .documentSha256)
            try c.encode(summary, forKey: .summary)
            try c.encodeIfPresent(comparison, forKey: .comparison)
            try c.encodeIfPresent(gaitQuality, forKey: .gaitQuality)
            try c.encodeIfPresent(motionHeads, forKey: .motionHeads)
            try c.encodeIfPresent(sameAs, forKey: .sameAs)
        }
    }

    /// What the comparison decoded: the arms by name and the joint document (nil when no channel was admitted).
    struct Decoded {
        var arms: [String: Arm]
        var documents: [String: ActivityContextDayDocument]
        var joint: ActivityContextDayDocument?
        var withheldReason: String?
    }

    struct Payload: Encodable {
        var day: String
        var schema = ActivityCandidateDays.schema
        var policy = ActivityExpertSelection.policy
        var selectionDigest: String
        var inputRevision: Int64
        var decisions: [ActivityExpertSelection.Decision]
        var arms: [String: Arm]
        var jointDocument: ActivityContextDayDocument?
        var withheldReason: String?

        enum CodingKeys: String, CodingKey {
            case day, schema, policy, selectionDigest = "selection_digest", inputRevision = "input_revision"
            case decisions, arms, jointDocument = "joint_document", withheldReason = "withheld_reason"
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(day, forKey: .day); try c.encode(schema, forKey: .schema); try c.encode(policy, forKey: .policy)
            try c.encode(selectionDigest, forKey: .selectionDigest); try c.encode(inputRevision, forKey: .inputRevision)
            try c.encode(decisions, forKey: .decisions); try c.encode(arms, forKey: .arms)
            if let jointDocument { try c.encode(jointDocument, forKey: .jointDocument) }
            else { try c.encodeNil(forKey: .jointDocument) }
            if let withheldReason { try c.encode(withheldReason, forKey: .withheldReason) }
            else { try c.encodeNil(forKey: .withheldReason) }
        }
    }

    /// The shared policy's selection for one raw-IMU job, from the job's own expert results: each stage's windows
    /// under the release its mode allows, with the pins and π it enforced, the job's input revision and day. The
    /// HART-embedded ElderNet windows join as their own (shadow) route; the standalone source supersedes them.
    /// Every decode of the job (the published one, each single-expert candidate, the joint candidate and its
    /// ablations) reads this one selection.
    static func selection(day: String, inputRevision: Int64,
                          gait: GaitQualityTrackInput?, eldernet: ElderNetStage?,
                          heads: MotionHeadsTrackInput?, inertia: InertiaStage?,
                          embedded: [ActivityGaitWindow] = []) -> ActivityExpertSelection {
        var gaitSources: [GaitQualitySource] = []
        if let gait, let eldernet {
            gaitSources.append(GaitQualitySource(
                track: gait, releaseMode: eldernet.mode.release, route: .standalone,
                expectedModelVersion: eldernet.expectedModelVersion, expectedWeightsDigest: eldernet.expectedWeightsDigest,
                gaitPrior: eldernet.gaitPrior, inputRevision: inputRevision, day: day))
        }
        var motionSources: [MotionHeadsSource] = []
        if let heads, let inertia {
            motionSources.append(MotionHeadsSource(
                track: heads, mode: inertia.mode.release,
                expectedBundleSHA256: inertia.expectedBundleSHA256, inputRevision: inputRevision, day: day))
        }
        return ActivityExpertSelection.select(
            revisions: [day: inputRevision], gaitQuality: gaitSources, motionHeads: motionSources,
            embeddedGait: embedded.isEmpty ? nil : EmbeddedGaitSource(windows: embedded))
    }

    /// The authority block stored with an expert row (`summary.authority`): the selection's decision for the row's
    /// channel and the pins the stage ran with. nil when the selection has no source for the channel.
    static func authority(_ selection: ActivityExpertSelection, gait eldernet: ElderNetStage) -> ActivityExpertAuthority? {
        selection.decision(for: .gaitQuality).map {
            ActivityExpertAuthority(decision: $0, mode: eldernet.mode.release,
                                    pinnedModelVersion: eldernet.expectedModelVersion,
                                    pinnedWeightsDigest: eldernet.expectedWeightsDigest, gaitPrior: eldernet.gaitPrior)
        }
    }

    static func authority(_ selection: ActivityExpertSelection, motion inertia: InertiaStage) -> ActivityExpertAuthority? {
        selection.decision(for: .motionHeads).map {
            ActivityExpertAuthority(decision: $0, mode: inertia.mode.release,
                                    pinnedBundleSHA256: inertia.expectedBundleSHA256)
        }
    }

    static func documentDigest(_ document: ActivityContextDayDocument) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return sha256Hex((try? encoder.encode(document)) ?? Data())
    }

    /// A decode already made for an arm, with the track reports of that same decode.
    struct Reused {
        var document: ActivityContextDayDocument
        var gaitQuality: GaitQualityTrackReport? = nil
        var motionHeads: MotionHeadsTrackReport? = nil
    }

    /// Decode every candidate arm of `selection` over `input` (the published decode's own input), with the published
    /// decode's `base` config and warm-up `lookback`. `reuse` holds decodes already made for an arm name (the
    /// canonical document is the arm of exactly the production channels, HART alone when there are none; the
    /// single-expert arms are the rows' candidate documents with their reports), so no arm is decoded twice.
    static func decode(selection: ActivityExpertSelection, input: ActivityContextTrackInput?, generatedAt: Int,
                       base: ActivityDecoderConfig = ActivityDecoderConfig(),
                       lookback: ActivityContextTrackInput? = nil,
                       reuse: [String: Reused] = [:]) -> Decoded {
        let arms = selection.candidateArms
        guard !arms.isEmpty else {
            let reason = selection.decisions.compactMap(\.reason).first.map { "no_candidate_channel: \($0)" }
                ?? "no_candidate_channel"
            return Decoded(arms: [:], documents: [:], joint: nil, withheldReason: reason)
        }
        guard let input else { return Decoded(arms: [:], documents: [:], joint: nil, withheldReason: "context_days_disabled") }
        var documents: [String: ActivityContextDayDocument] = [:]
        var reports: [String: (GaitQualityTrackReport?, MotionHeadsTrackReport?)] = [:]
        for arm in arms {
            if let cached = reuse[arm.name] {
                documents[arm.name] = cached.document
                reports[arm.name] = (cached.gaitQuality, cached.motionHeads)
                continue
            }
            let d = selection.decode(input, base: base, channels: arm.channels)
            let warm = lookback.map { selection.decode($0, base: base, channels: arm.channels).input }
            let built = ActivityContextDays.dayDocumentAndTrack(input: d.input, generatedAt: generatedAt, config: d.config,
                                                                lookback: warm)
            documents[arm.name] = built.document
            reports[arm.name] = (built.track.gaitQuality, built.track.motionHeads)
        }
        let hart = documents["hart"]
        let hartSegments = hart.map { ActivityOutputSegment.of($0) } ?? []
        var out: [String: Arm] = [:]
        for arm in arms {
            guard let doc = documents[arm.name] else { continue }
            var stamps: [String: String] = [:]
            if let s = doc.versions.gaitQuality { stamps[ActivityExpertSelection.Channel.gaitQuality.rawValue] = s }
            if let s = doc.versions.motionHeads { stamps[ActivityExpertSelection.Channel.motionHeads.rawValue] = s }
            out[arm.name] = Arm(
                channels: arm.channels.map(\.rawValue), stamps: stamps, documentSha256: documentDigest(doc),
                summary: ActivityOutputSummary(ActivityOutputSegment.of(doc)),
                comparison: arm.channels.isEmpty ? nil
                    : ActivityOutputComparison.compare(reference: hartSegments, candidate: ActivityOutputSegment.of(doc)),
                gaitQuality: reports[arm.name]?.0, motionHeads: reports[arm.name]?.1, sameAs: nil)
        }
        let joint = selection.jointArm
        if let joint, joint.name != "joint" {
            // One admitted expert: the joint decode is that single arm (recorded once, named twice).
            out["joint"] = out[joint.name].map { var a = $0; a.sameAs = joint.name; return a }
        }
        let jointDocument = joint.flatMap { documents[$0.name] }
        guard let jointDocument, jointDocument.versions.gaitQuality != nil || jointDocument.versions.motionHeads != nil else {
            return Decoded(arms: out, documents: documents, joint: nil, withheldReason: "joint_not_accepted")
        }
        return Decoded(arms: out, documents: documents, joint: jointDocument, withheldReason: nil)
    }

    /// The RPC payload (sorted keys).
    static func payload(day: String, inputRevision: Int64, selection: ActivityExpertSelection,
                        decoded: Decoded) throws -> String {
        let payload = Payload(day: day, selectionDigest: selection.digest, inputRevision: inputRevision,
                              decisions: selection.decisions, arms: decoded.arms, jointDocument: decoded.joint,
                              withheldReason: decoded.joint == nil ? (decoded.withheldReason ?? "joint_not_accepted") : nil)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(payload)
        guard let text = String(data: data, encoding: .utf8) else {
            throw WorkerError.malformed("candidate day payload encoding failed")
        }
        return text
    }

    /// Write the candidate row through its fenced RPC, under a savepoint when a transaction is open: a rejection
    /// (or a database without the migration) leaves the transaction usable for the publishes around it. Only a lost
    /// connection propagates.
    static func publish(db: PostgresClient, token: String, revision: Int64, payload: String) throws -> PublishOutcome {
        do {
            let out = try db.isolatingFailures {
                try db.callFunctionForJSONRaw(
                    "SELECT public.publish_activity_candidate_day($1::uuid,$2::bigint,$3::jsonb)::text",
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

    /// Retention: delete rows computed more than `keepDays` ago (at most `maxRows` per call).
    static func prune(db: PostgresClient, keepDays: Int = retentionDays, maxRows: Int = pruneBatchRows) throws -> Int {
        let out = try db.callFunctionForJSONRaw(pruneSQL, [String(keepDays), String(maxRows)])
        return Int(out ?? "") ?? 0
    }
}

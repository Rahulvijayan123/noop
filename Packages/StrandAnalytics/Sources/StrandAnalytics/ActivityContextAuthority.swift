import Foundation

// ActivityContextAuthority.swift — which expert evidence may shape which decode (docs/model-integration/
// activity-authority.md). One policy for the worker's published documents, its candidate comparisons and the
// phone's own decode, so no consumer can promote what a producer ran as shadow or candidate.
//
// Every expert output carries the release it was produced under (`ActivityReleaseMode`). The selection reads the
// stored outputs of one day (their release, model identity and input revision) and decides, per source, the highest
// decode it may shape: `production` sources shape the canonical (published) decode and every candidate arm,
// `candidate` sources only the candidate arms, `shadow` sources nothing. Releases are only ever lowered here
// (missing pins, a stand-in encoder, a bundle tier below the mode, an input revision that is not the HART windows'),
// never raised. The evidence configs a decode runs with are built here and nowhere else, from the stored rows, so a
// worker and a phone holding the same rows build the same config.
//
// ElderNet has one execution route: the worker's own ElderNet service (`ElderNetRoute.standalone`). Gait-expert
// windows from the ElderNet copy that HART's service can load (`hartEmbedded`, carried in `hart-windows-1`) never
// shape a decode while a standalone source exists, and carry no release of their own, so they read as shadow.

/// How far an output has been released, weakest first. A cache, route, store or decoder may lower it, never raise it.
public enum ActivityReleaseMode: String, Codable, CaseIterable, Comparable, Sendable {
    /// Computed and stored for inspection; never decoder evidence.
    case shadow
    /// Decoder evidence in candidate (comparison) decodes only; never published.
    case candidate
    /// Evidence in the canonical, published decode.
    case production

    private var rank: Int {
        switch self {
        case .shadow: return 0
        case .candidate: return 1
        case .production: return 2
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }

    /// The mode a stored row recorded. Missing or unrecognised reads as shadow, never as production.
    public init(recorded: String?) {
        self = recorded.flatMap { Self(rawValue: $0.trimmingCharacters(in: .whitespaces).lowercased()) } ?? .shadow
    }

    /// The weaker of this mode and `cap`.
    public func lowered(to cap: Self) -> Self { Swift.min(self, cap) }
}

/// Where an ElderNet window was computed.
public enum ElderNetRoute: String, Codable, Sendable {
    /// The worker's ElderNet service (`activity_context.eldernet.serve`): pinned, budgeted, stored in its own rows.
    case standalone
    /// The gait expert inside HART's service (`--gait-expert eldernet`), carried in `hart-windows-1` (`g_*`).
    case hartEmbedded = "hart_embedded"
}

// MARK: - Sources

/// ElderNet gait-quality windows of one stored row (one UTC day) or one job, with the release they were produced under.
public struct GaitQualitySource: Equatable, Sendable {
    public var track: GaitQualityTrackInput
    /// The release the producer recorded (the row's mode, or its own lower `authority.release_mode`).
    public var releaseMode: ActivityReleaseMode
    public var route: ElderNetRoute
    /// The pins the producer enforced (FRWHOOP_ELDERNET_MODEL_VERSION / _WEIGHTS_SHA256); nil = not pinned.
    public var expectedModelVersion: String?
    public var expectedWeightsDigest: String?
    /// π the producer decoded with (FRWHOOP_ELDERNET_GAIT_PRIOR); nil = not set.
    public var gaitPrior: Double?
    /// The raw-IMU input revision the windows were computed from; nil when the row does not say.
    public var inputRevision: Int64?
    /// The UTC day ("yyyy-MM-dd") the row belongs to; nil for a whole-job source.
    public var day: String?

    public init(track: GaitQualityTrackInput, releaseMode: ActivityReleaseMode, route: ElderNetRoute = .standalone,
                expectedModelVersion: String? = nil, expectedWeightsDigest: String? = nil, gaitPrior: Double? = nil,
                inputRevision: Int64? = nil, day: String? = nil) {
        self.track = track; self.releaseMode = releaseMode; self.route = route
        self.expectedModelVersion = expectedModelVersion; self.expectedWeightsDigest = expectedWeightsDigest
        self.gaitPrior = gaitPrior; self.inputRevision = inputRevision; self.day = day
    }
}

/// Inertia / ActiNet motion-head windows of one stored row or one job.
public struct MotionHeadsSource: Equatable, Sendable {
    public var track: MotionHeadsTrackInput
    /// The mode the producer ran under (FRWHOOP_INERTIA_MODE). The bundle's own tier and encoder kind lower it
    /// (`releaseMode`).
    public var mode: ActivityReleaseMode
    /// The bundle digest the producer pinned (FRWHOOP_INERTIA_BUNDLE_SHA256); nil = not pinned.
    public var expectedBundleSHA256: String?
    public var inputRevision: Int64?
    public var day: String?

    public init(track: MotionHeadsTrackInput, mode: ActivityReleaseMode, expectedBundleSHA256: String? = nil,
                inputRevision: Int64? = nil, day: String? = nil) {
        self.track = track; self.mode = mode; self.expectedBundleSHA256 = expectedBundleSHA256
        self.inputRevision = inputRevision; self.day = day
    }

    /// The release these windows actually carry: the producer's mode, never above the bundle's evaluated tier, and
    /// shadow for an encoder that is not a pinned checkpoint (a stand-in never qualifies a bundle).
    public var releaseMode: ActivityReleaseMode {
        guard track.bundle.encoderKind.isPinned else { return .shadow }
        return mode.lowered(to: ActivityReleaseMode(recorded: track.bundle.evidenceTierMax.rawValue))
    }
}

/// Gait-expert windows found in a stored HART window set (the HART-embedded ElderNet route).
public struct EmbeddedGaitSource: Equatable, Sendable {
    public var windows: [ActivityGaitWindow]
    /// No producer records a release for this route, so it is shadow unless one says otherwise.
    public var releaseMode: ActivityReleaseMode

    public init(windows: [ActivityGaitWindow], releaseMode: ActivityReleaseMode = .shadow) {
        self.windows = windows; self.releaseMode = releaseMode
    }
}

// MARK: - Selection

/// The policy's decision for one day's expert sources, and the decode inputs and configs it allows.
public struct ActivityExpertSelection: Equatable, Sendable {
    /// Version of the rules below; stored with every candidate row and reported in the heartbeat.
    public static let policy = "expert-authority-1"

    public enum Channel: String, Codable, CaseIterable, Comparable, Sendable {
        case gaitQuality = "gait_quality"
        case motionHeads = "motion_heads"
        case embeddedGait = "embedded_gait"

        private var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rank < rhs.rank }
    }

    /// The decodes a source may shape.
    public enum Use: String, Codable, Sendable {
        case none
        /// Candidate arms only.
        case candidate
        /// The canonical decode and every candidate arm.
        case canonical
    }

    /// What the policy decided for one source.
    public struct Decision: Codable, Equatable, Sendable {
        public var channel: Channel
        public var route: String
        /// The release the source carries after every lowering.
        public var releaseMode: ActivityReleaseMode
        public var use: Use
        /// Why the source shapes less than its recorded release would allow (nil when it shapes all it may).
        public var reason: String?
        public var identity: [String: String]
        public var inputRevision: Int64?
        public var day: String?
        public var windows: Int

        enum CodingKeys: String, CodingKey {
            case channel, route, releaseMode = "release_mode", use, reason, identity
            case inputRevision = "input_revision", day, windows
        }
    }

    /// One decode the candidate comparison stores: the channels it adds to HART and the strap streams.
    public struct Arm: Equatable, Sendable {
        public var name: String
        public var channels: [Channel]
    }

    public private(set) var decisions: [Decision]
    /// Decoded configs for the admitted channels (never set for a channel whose `use` is none).
    private var gait: AdmittedGait?
    private var motion: AdmittedMotion?
    private var embedded: [ActivityGaitWindow]?
    private var uses: [Channel: Use] = [:]

    private struct AdmittedGait: Equatable, Sendable {
        var track: GaitQualityTrackInput
        var config: GaitQualityEvidenceConfig
    }

    private struct AdmittedMotion: Equatable, Sendable {
        var track: MotionHeadsTrackInput
        var config: MotionHeadsEvidenceConfig
    }

    private init(decisions: [Decision]) { self.decisions = decisions }

    /// Decide for one decode. `revisions` maps a UTC day to the raw-IMU input revision of the HART windows the decode
    /// uses for that day: an expert row computed from another revision of the same day is not combined with them.
    /// `gaitQuality` may hold one source per UTC day (a local day spans two); only one ElderNet model can be active
    /// in a decode, so eligible days whose model or release config differs from the newest eligible day's are left
    /// out. Motion heads follow the same rule per bundle.
    public static func select(revisions: [String: Int64] = [:], gaitQuality: [GaitQualitySource] = [],
                              motionHeads: [MotionHeadsSource] = [],
                              embeddedGait: EmbeddedGaitSource? = nil) -> ActivityExpertSelection {
        var out = ActivityExpertSelection(decisions: [])

        // ElderNet (standalone): per source, its release after the pins and π it was produced with.
        var gaitAdmitted: [(index: Int, source: GaitQualitySource, config: GaitQualityEvidenceConfig)] = []
        for source in gaitQuality {
            let (release, lowered) = gaitRelease(source)
            var decision = Decision(channel: .gaitQuality, route: source.route.rawValue, releaseMode: release,
                                    use: .none, reason: lowered, identity: gaitIdentity(source),
                                    inputRevision: source.inputRevision, day: source.day,
                                    windows: source.track.windows.count)
            if decision.reason == nil {
                decision.reason = revisionMismatch(day: source.day, revision: source.inputRevision, revisions: revisions)
            }
            var config: GaitQualityEvidenceConfig?
            if decision.reason == nil {
                if release >= .candidate {
                    let c = gaitConfig(source, release: release)
                    if let refusal = c.evidenceRefusal { decision.reason = refusal } else { config = c }
                } else {
                    decision.reason = "release_mode_\(release.rawValue)"
                }
            }
            if let config {
                decision.use = release == .production ? .canonical : .candidate
                gaitAdmitted.append((out.decisions.count, source, config))
            }
            out.decisions.append(decision)
        }
        // One model per decode: the canonical sources first, then the newest day; the others join only with exactly
        // its model and config.
        if let lead = gaitAdmitted.min(by: { lhs, rhs in
            precedes(lhs.config.mode == .production, lhs.source.day, rhs.config.mode == .production, rhs.source.day)
        }) {
            var windows: [GaitQualityWindow] = []
            var starts: Set<Int> = []
            for admitted in gaitAdmitted {
                guard admitted.source.track.model == lead.source.track.model, admitted.config == lead.config else {
                    out.decisions[admitted.index].use = .none
                    out.decisions[admitted.index].reason = "model_differs_within_decode"
                    continue
                }
                for w in admitted.source.track.windows where starts.insert(w.startTs).inserted { windows.append(w) }
            }
            windows.sort { $0.startTs < $1.startTs }
            var track = GaitQualityTrackInput(model: lead.source.track.model, windows: windows)
            track.releaseMode = lead.config.mode == .production ? .production : .candidate
            out.gait = AdmittedGait(track: track, config: lead.config)
            out.uses[.gaitQuality] = lead.config.mode == .production ? .canonical : .candidate
        }

        // Inertia / ActiNet heads: one bundle per decode, the same way.
        var motionAdmitted: [(index: Int, source: MotionHeadsSource, config: MotionHeadsEvidenceConfig)] = []
        for source in motionHeads {
            let (release, lowered) = motionRelease(source)
            var decision = Decision(channel: .motionHeads, route: "standalone", releaseMode: release,
                                    use: .none, reason: lowered, identity: motionIdentity(source),
                                    inputRevision: source.inputRevision, day: source.day,
                                    windows: source.track.windows.count)
            if decision.reason == nil {
                decision.reason = revisionMismatch(day: source.day, revision: source.inputRevision, revisions: revisions)
            }
            var config: MotionHeadsEvidenceConfig?
            if decision.reason == nil {
                if release >= .candidate {
                    let c = MotionHeadsEvidenceConfig(mode: release == .production ? .production : .candidate,
                                                      bundle: source.track.bundle,
                                                      expectedBundleSHA256: source.expectedBundleSHA256)
                    if let refusal = c.evidenceRefusal { decision.reason = refusal } else { config = c }
                } else {
                    decision.reason = "release_mode_\(release.rawValue)"
                }
            }
            if let config {
                decision.use = release == .production ? .canonical : .candidate
                motionAdmitted.append((out.decisions.count, source, config))
            }
            out.decisions.append(decision)
        }
        if let lead = motionAdmitted.min(by: { lhs, rhs in
            precedes(lhs.config.mode == .production, lhs.source.day, rhs.config.mode == .production, rhs.source.day)
        }) {
            var windows: [MotionHeadsWindow] = []
            var starts: Set<Int> = []
            for admitted in motionAdmitted {
                guard admitted.source.track.bundle == lead.source.track.bundle, admitted.config == lead.config else {
                    out.decisions[admitted.index].use = .none
                    out.decisions[admitted.index].reason = "bundle_differs_within_decode"
                    continue
                }
                for w in admitted.source.track.windows where starts.insert(w.startTs).inserted { windows.append(w) }
            }
            windows.sort { $0.startTs < $1.startTs }
            var track = MotionHeadsTrackInput(bundle: lead.source.track.bundle, windows: windows)
            track.releaseMode = lead.config.mode == .production ? .production : .candidate
            out.motion = AdmittedMotion(track: track, config: lead.config)
            out.uses[.motionHeads] = lead.config.mode == .production ? .canonical : .candidate
        }

        // The HART-embedded ElderNet route: never beside a standalone ElderNet source (the same network would vote
        // twice), and only as far as its own recorded release allows.
        if let embeddedGait, !embeddedGait.windows.isEmpty {
            var decision = Decision(channel: .embeddedGait, route: ElderNetRoute.hartEmbedded.rawValue,
                                    releaseMode: embeddedGait.releaseMode, use: .none, reason: nil,
                                    identity: ["model_version": embeddedGait.windows.first?.modelVersion ?? "unknown"],
                                    inputRevision: nil, day: nil, windows: embeddedGait.windows.count)
            if !gaitQuality.isEmpty {
                decision.reason = "superseded_by_standalone_route"
            } else if embeddedGait.releaseMode == .shadow {
                decision.reason = "release_mode_shadow"
            } else {
                decision.use = embeddedGait.releaseMode == .production ? .canonical : .candidate
                out.embedded = embeddedGait.windows
                out.uses[.embeddedGait] = decision.use
            }
            out.decisions.append(decision)
        }
        return out
    }

    /// Lead order: a canonical source before a candidate one, then the newer UTC day.
    private static func precedes(_ lhsCanonical: Bool, _ lhsDay: String?, _ rhsCanonical: Bool,
                                 _ rhsDay: String?) -> Bool {
        if lhsCanonical != rhsCanonical { return lhsCanonical }
        return (lhsDay ?? "") > (rhsDay ?? "")
    }

    // MARK: Reading the decision

    /// How far `channel` was admitted (none when it has no source or none qualified).
    public func use(of channel: Channel) -> Use { uses[channel] ?? .none }

    /// Channels that shape the canonical (published) decode.
    public var canonicalChannels: [Channel] { uses.filter { $0.value == .canonical }.map(\.key).sorted() }

    /// Channels that may shape a candidate arm (every canonical channel included).
    public var candidateChannels: [Channel] { uses.filter { $0.value != .none }.map(\.key).sorted() }

    /// The candidate comparison's arms: HART alone, HART with each admitted channel alone, and (with more than one
    /// channel) all of them together. Empty when no channel was admitted.
    public var candidateArms: [Arm] {
        let channels = candidateChannels
        guard !channels.isEmpty else { return [] }
        var arms = [Arm(name: "hart", channels: [])]
        for c in channels { arms.append(Arm(name: "hart+\(c.rawValue)", channels: [c])) }
        if channels.count > 1 { arms.append(Arm(name: "joint", channels: channels)) }
        return arms
    }

    /// The arm the joint candidate document is: every admitted channel together (a single arm when only one was).
    public var jointArm: Arm? {
        let arms = candidateArms
        return arms.first { $0.name == "joint" } ?? (arms.count == 2 ? arms[1] : nil)
    }

    /// The release config of the admitted ElderNet channel (nil when none was admitted).
    public var gaitQualityConfig: GaitQualityEvidenceConfig? { gait?.config }
    public var motionHeadsConfig: MotionHeadsEvidenceConfig? { motion?.config }

    /// `input` decoded for `channels` exactly: their windows attached and their configs installed, every other
    /// expert entry removed from both (whatever `input` or `base` carried before).
    public func decode(_ input: ActivityContextTrackInput, base: ActivityDecoderConfig,
                       channels: [Channel]) -> (input: ActivityContextTrackInput, config: ActivityDecoderConfig) {
        var out = input
        var config = base
        out.gaitQuality = nil; out.motionHeads = nil; out.gaitWindows = []
        config.gaitQuality = nil; config.motionHeads = nil
        let wanted = Set(channels)
        if wanted.contains(.gaitQuality), let gait {
            out.gaitQuality = gait.track
            config.gaitQuality = gait.config
        }
        if wanted.contains(.motionHeads), let motion {
            out.motionHeads = motion.track
            config.motionHeads = motion.config
        }
        if wanted.contains(.embeddedGait), let embedded { out.gaitWindows = embedded }
        return (out, config)
    }

    /// The canonical decode: production channels only.
    public func canonical(_ input: ActivityContextTrackInput,
                          base: ActivityDecoderConfig) -> (input: ActivityContextTrackInput, config: ActivityDecoderConfig) {
        decode(input, base: base, channels: canonicalChannels)
    }

    /// SHA-256 over the decisions (sorted keys): what the candidate row is keyed by.
    public var digest: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(decisions)) ?? Data()
        return GaitSHA256.hex(Array((Self.policy + "\n").utf8) + Array(data))
    }

    // MARK: Rules

    static func gaitIdentity(_ s: GaitQualitySource) -> [String: String] {
        var out = ["model_version": s.track.model.modelVersion, "weights_digest": s.track.model.weightsDigest]
        if let v = s.expectedModelVersion { out["pinned_model_version"] = v }
        if let d = s.expectedWeightsDigest { out["pinned_weights_digest"] = d }
        return out
    }

    static func motionIdentity(_ s: MotionHeadsSource) -> [String: String] {
        let b = s.track.bundle
        var out = ["bundle_sha256": b.bundleSha256, "bundle_id": b.headsVersion, "encoder_id": b.encoderId,
                   "encoder_kind": b.encoderKind.rawValue, "evidence_tier_max": b.evidenceTierMax.rawValue,
                   "mode": s.mode.rawValue]
        if let c = b.checkpointSha256 { out["checkpoint_sha256"] = c }
        if let p = s.expectedBundleSHA256 { out["pinned_bundle_sha256"] = p }
        return out
    }

    /// The release a gait source carries and, when it was lowered, why. Candidate and production need both pins and π
    /// (the worker refuses candidate mode without them; a row that lacks them is treated as shadow).
    static func gaitRelease(_ s: GaitQualitySource) -> (ActivityReleaseMode, String?) {
        guard s.releaseMode >= .candidate else { return (s.releaseMode, nil) }
        guard s.expectedModelVersion != nil, s.expectedWeightsDigest != nil else { return (.shadow, "model_not_pinned") }
        guard s.gaitPrior != nil else { return (.shadow, "gait_prior_not_set") }
        return (s.releaseMode, nil)
    }

    static func motionRelease(_ s: MotionHeadsSource) -> (ActivityReleaseMode, String?) {
        let b = s.track.bundle
        guard s.mode >= .candidate else { return (s.mode, nil) }
        guard b.encoderKind.isPinned else { return (.shadow, "encoder_kind_\(b.encoderKind.rawValue)") }
        let tier = ActivityReleaseMode(recorded: b.evidenceTierMax.rawValue)
        guard tier >= .candidate else { return (.shadow, "evidence_tier_\(b.evidenceTierMax.rawValue)") }
        guard s.expectedBundleSHA256 != nil else { return (.shadow, "bundle_sha256_not_pinned") }
        return (s.mode.lowered(to: tier), nil)
    }

    static func gaitConfig(_ s: GaitQualitySource, release: ActivityReleaseMode) -> GaitQualityEvidenceConfig {
        GaitQualityEvidenceConfig(mode: release == .production ? .production : .candidate, model: s.track.model,
                                  gaitPrior: s.gaitPrior ?? GaitQualityEvidenceConfig.defaultGaitPrior,
                                  expectedModelVersion: s.expectedModelVersion,
                                  expectedWeightsDigest: s.expectedWeightsDigest)
    }

    static func revisionMismatch(day: String?, revision: Int64?, revisions: [String: Int64]) -> String? {
        guard let revision else { return nil }
        if let day, let expected = revisions[day], expected != revision { return "input_revision_mismatch" }
        if day == nil, revisions.count == 1, let expected = revisions.values.first, expected != revision {
            return "input_revision_mismatch"
        }
        return nil
    }
}

// MARK: - Row authority block

/// What a producer stores with an expert row (inside its `summary.authority`, copied into the row's `authority`
/// column) and the scores route returns with it: the policy inputs the row was produced under and the producer's own
/// decision for it. A consumer rebuilds the policy's source from it (`gaitSource` / `motionSource`) and re-runs the
/// policy; `use` and `reason` are the producer's view, for inspection only. Decoding is lenient: an unknown release
/// reads as shadow, never as production.
public struct ActivityExpertAuthority: Codable, Equatable, Sendable {
    public var policy: String
    public var channel: ActivityExpertSelection.Channel
    public var route: String
    /// The mode the producer ran under.
    public var mode: ActivityReleaseMode
    /// The release after the policy's lowering.
    public var releaseMode: ActivityReleaseMode
    public var use: ActivityExpertSelection.Use
    public var reason: String?
    /// The raw-IMU input revision of the job (a decimal string on the wire: int64 does not survive JSON numbers).
    public var inputRevision: Int64?
    public var pinnedModelVersion: String?
    public var pinnedWeightsDigest: String?
    public var gaitPrior: Double?
    public var pinnedBundleSHA256: String?

    enum CodingKeys: String, CodingKey {
        case policy, channel, route, mode, releaseMode = "release_mode", use, reason, inputRevision = "input_revision"
        case pinnedModelVersion = "pinned_model_version", pinnedWeightsDigest = "pinned_weights_digest"
        case gaitPrior = "gait_prior", pinnedBundleSHA256 = "pinned_bundle_sha256"
    }

    public init(decision: ActivityExpertSelection.Decision, mode: ActivityReleaseMode,
                pinnedModelVersion: String? = nil, pinnedWeightsDigest: String? = nil, gaitPrior: Double? = nil,
                pinnedBundleSHA256: String? = nil) {
        policy = ActivityExpertSelection.policy
        channel = decision.channel; route = decision.route; self.mode = mode
        releaseMode = decision.releaseMode.lowered(to: mode); use = decision.use; reason = decision.reason
        inputRevision = decision.inputRevision
        self.pinnedModelVersion = pinnedModelVersion; self.pinnedWeightsDigest = pinnedWeightsDigest
        self.gaitPrior = gaitPrior; self.pinnedBundleSHA256 = pinnedBundleSHA256
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        policy = try c.decode(String.self, forKey: .policy)
        channel = try c.decode(ActivityExpertSelection.Channel.self, forKey: .channel)
        route = try c.decodeIfPresent(String.self, forKey: .route) ?? ElderNetRoute.standalone.rawValue
        let recordedMode = ActivityReleaseMode(recorded: try c.decodeIfPresent(String.self, forKey: .mode))
        mode = recordedMode
        releaseMode = ActivityReleaseMode(recorded: try c.decodeIfPresent(String.self, forKey: .releaseMode))
            .lowered(to: recordedMode)
        use = (try? c.decodeIfPresent(ActivityExpertSelection.Use.self, forKey: .use)) ?? ActivityExpertSelection.Use.none
        reason = try c.decodeIfPresent(String.self, forKey: .reason)
        if let text = try? c.decodeIfPresent(String.self, forKey: .inputRevision) { inputRevision = Int64(text) }
        else { inputRevision = try? c.decodeIfPresent(Int64.self, forKey: .inputRevision) }
        pinnedModelVersion = try c.decodeIfPresent(String.self, forKey: .pinnedModelVersion)
        pinnedWeightsDigest = try c.decodeIfPresent(String.self, forKey: .pinnedWeightsDigest)
        gaitPrior = try c.decodeIfPresent(Double.self, forKey: .gaitPrior)
        pinnedBundleSHA256 = try c.decodeIfPresent(String.self, forKey: .pinnedBundleSHA256)
    }

    /// Every key, nil ones as JSON null (the documented wire shape).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(policy, forKey: .policy); try c.encode(channel, forKey: .channel)
        try c.encode(route, forKey: .route); try c.encode(mode, forKey: .mode)
        try c.encode(releaseMode, forKey: .releaseMode); try c.encode(use, forKey: .use)
        try c.encode(reason, forKey: .reason)
        try c.encode(inputRevision.map(String.init), forKey: .inputRevision)
        if channel == .motionHeads {
            try c.encode(pinnedBundleSHA256, forKey: .pinnedBundleSHA256)
        } else {
            try c.encode(pinnedModelVersion, forKey: .pinnedModelVersion)
            try c.encode(pinnedWeightsDigest, forKey: .pinnedWeightsDigest)
            try c.encode(gaitPrior, forKey: .gaitPrior)
        }
    }

    /// The policy source for a stored gait row: its recorded release (the row's `release_mode`), never above this
    /// block's, with the pins and π the producer ran with. Without a block (an older row) pass nil: the row then has
    /// no pins and the policy reads it as shadow.
    public static func gaitSource(_ authority: Self?, track: GaitQualityTrackInput, recordedRelease: ActivityReleaseMode,
                                  inputRevision: Int64?, day: String?) -> GaitQualitySource {
        GaitQualitySource(track: track,
                          releaseMode: authority.map { recordedRelease.lowered(to: $0.releaseMode) } ?? recordedRelease,
                          route: authority.flatMap { ElderNetRoute(rawValue: $0.route) } ?? .standalone,
                          expectedModelVersion: authority?.pinnedModelVersion,
                          expectedWeightsDigest: authority?.pinnedWeightsDigest,
                          gaitPrior: authority?.gaitPrior, inputRevision: inputRevision ?? authority?.inputRevision,
                          day: day)
    }

    /// The policy source for a stored motion-heads row, the same way (no block: no pinned bundle, so shadow).
    public static func motionSource(_ authority: Self?, track: MotionHeadsTrackInput, recordedRelease: ActivityReleaseMode,
                                    inputRevision: Int64?, day: String?) -> MotionHeadsSource {
        MotionHeadsSource(track: track,
                          mode: authority.map { recordedRelease.lowered(to: $0.releaseMode) } ?? recordedRelease,
                          expectedBundleSHA256: authority?.pinnedBundleSHA256,
                          inputRevision: inputRevision ?? authority?.inputRevision, day: day)
    }
}

extension ActivityExpertSelection {
    /// The first decision for `channel` (nil when the selection had no source for it).
    public func decision(for channel: Channel) -> Decision? { decisions.first { $0.channel == channel } }
}

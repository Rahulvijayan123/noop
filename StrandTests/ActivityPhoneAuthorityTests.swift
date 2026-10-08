import XCTest
import StrandAnalytics
import WhoopProtocol
@testable import Strand

/// The phone side of the expert-authority policy (docs/model-integration/activity-authority-phone.md): what the stores
/// hold for a day reaches the decoder only through `ActivityExpertSelection`'s canonical decode, so a shadow or
/// candidate row can never shape what the wearer sees; records stored before the release fields read as their
/// recorded mode; and the gait windows are fetched whatever became of HART's fetch.
@MainActor
final class ActivityPhoneAuthorityTests: XCTestCase {

    private let dayStart = 1_791_158_400   // 2026-10-05T00:00:00Z
    private let day = "2026-10-05"
    private var from: Int { dayStart + 3_600 }
    private var to: Int { from + 1_800 }
    /// The walk inside `[from, to)`.
    private var walk: Range<Int> { (from + 600)..<(from + 1_200) }
    private let scope = ActivityEncoderWindowStore.Scope(ownerId: "owner-1", deviceId: "whoop-A")

    // MARK: Fixtures

    private func tempDirectory(_ name: String) -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func encoderStore() throws -> ActivityEncoderWindowStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "activity-phone-authority-\(UUID().uuidString)"))
        let store = ActivityEncoderWindowStore(directory: tempDirectory("activity-windows"), defaults: defaults)
        store.setScope(scope)
        return store
    }

    private func gaitStore() -> (store: GaitWindowStore, directory: URL) {
        let dir = tempDirectory("gait-windows")
        let scope = self.scope
        return (GaitWindowStore(directory: dir, scope: { scope }), dir)
    }

    private func model() -> GaitQualityModelInfo {
        var weights: [String: String] = [:]
        for (i, name) in GaitQualityWire.weightNames.enumerated() {
            weights[name] = String(repeating: String(Array("0123456789abcdef")[i + 1]), count: 64)
        }
        return GaitQualityModelInfo(modelVersion: "eldernet-437a38b", weights: weights,
                                    upstreamCommit: "437a38bcc69f42717fe73c1f7dbea7e1f7a50d23", hopS: 5)
    }

    /// A `gait-windows-1` object covering `[from, to)` on a 5-s hop: walking (with metrics) during `walk`.
    private func windowsJSON() throws -> String {
        let starts = Array(stride(from: from - 10, to: to, by: 5))
        let gait = starts.map { walk.contains($0 + 5) }
        let object: [String: Any] = [
            "format": "gait-windows-1", "n": starts.count, "w": 10, "h": 5, "s0": starts[0],
            "ds": [0] + Array(repeating: 5, count: starts.count - 1),
            "gp": gait.map { $0 ? 960 : 30 }, "g": gait.map { $0 ? 1 : 0 },
            "sp": gait.map { $0 ? 120 : -1 }, "cad": gait.map { $0 ? 108 : -1 }, "st": gait.map { $0 ? 130 : -1 },
            "rg": gait.map { $0 ? 80 : -1 }, "stp": gait.map { $0 ? 180 : -1 }, "pf": gait.map { _ in 0 },
        ]
        return String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func gaitRecord(mode: String, releaseMode: String? = nil, pinned: Bool = false, prior: Double? = nil,
                            inputRevision: Int64? = nil) throws -> GaitWindowStore.DayRecord {
        let m = model()
        return GaitWindowStore.DayRecord(
            day: day, resultRevision: "41", mode: mode, model: m, windowsJSON: try windowsJSON(),
            releaseMode: releaseMode, inputRevision: inputRevision,
            pinnedModelVersion: pinned ? m.modelVersion : nil, pinnedWeightsDigest: pinned ? m.weightsDigest : nil,
            gaitPrior: prior)
    }

    /// The strap's own streams for `[from, to)`: desk work, a walk, then stillness.
    private func input() -> ActivityContextTrackInput {
        var hr: [HRSample] = [], gravity: [GravitySample] = []
        for ts in from..<to {
            let walking = walk.contains(ts)
            let sway = walking ? 0.2 * sin(Double(ts) * 3.7) : 0
            hr.append(HRSample(ts: ts, bpm: walking ? 102 : 68))
            gravity.append(GravitySample(ts: ts, x: 0.1 + sway, y: 0.2 - sway / 2, z: 0.97,
                                         dynAccel: walking ? 0.28 : 0.01))
        }
        return ActivityContextTrackInput(dayStart: from, dayEnd: to, hr: hr, gravity: gravity)
    }

    /// HART's windows for the span (walking during the walk), optionally with HART-embedded ElderNet windows.
    private func hartRecord(embeddedGait: Bool, embeddedRelease: String? = nil,
                            inputRevision: Int64? = nil) throws -> ActivityEncoderWindowStore.DayRecord {
        let windows = stride(from: from + 4, to: to, by: 2).map { e -> ActivityWindowPrediction in
            let walking = walk.contains(e)
            return ActivityWindowPrediction(
                startTs: e - 4, endTs: e, label: walking ? .walking : .stationary,
                probs: walking ? ["walking": 0.82, "stationary": 0.08, "running": 0.04, "other_movement": 0.06]
                    : ["stationary": 0.86, "walking": 0.06, "running": 0.02, "other_movement": 0.06])
        }
        let gait = embeddedGait ? stride(from: from + 10, to: to, by: 10).map { e -> ActivityGaitWindow in
            let walking = walk.contains(e - 5)
            return ActivityGaitWindow(startTs: e - 10, endTs: e, gaitProb: walking ? 0.95 : 0.02, isGait: walking,
                                      cadenceSpm: walking ? 108 : nil, speedMps: walking ? 1.2 : nil,
                                      modelVersion: "eldernet-437a38b")
        } : []
        let set = ActivityEncoderWindowSet(encoderId: "hart", encoderVersion: "hart-wisdm-v0", windows: windows,
                                           gaitWindows: gait)
        let json = String(decoding: try JSONSerialization.data(withJSONObject: set.jsonObject(dayStart: dayStart)),
                          as: UTF8.self)
        return .init(day: day, resultRevision: "9", encoderId: "hart", modelVersion: "hart-wisdm-v0",
                     windowsJSON: json, inputRevision: inputRevision, releaseMode: "production",
                     embeddedGaitReleaseMode: embeddedRelease)
    }

    private func json<T: Encodable>(_ value: T) throws -> String {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return String(decoding: try e.encode(value), as: UTF8.self)
    }

    /// The phone's decode of the span from the stores, exactly as `Repository.activityContext(from:)` runs it.
    private func phoneDecode(encoders: ActivityEncoderWindowStore, gait: GaitWindowStore)
        -> (document: ActivityContextDayDocument, decode: ActivityPhoneEvidence.Decode) {
        let attached = ActivityPhoneEvidence.attachingEncoderWindows(input(), store: encoders)
        let decode = ActivityPhoneEvidence.canonical(attached, base: ActivityDecoderConfig(), encoders: encoders,
                                                     gait: gait)
        let document = ActivityContextDayBuilder.update(cached: nil, input: decode.input, now: to,
                                                        config: decode.config).document
        return (document, decode)
    }

    // MARK: Replay: stores → decoder

    func testShadowAndCandidateGaitRowsCannotChangeThePhonesDecode() throws {
        let encoders = try encoderStore()
        XCTAssertTrue(encoders.save(try hartRecord(embeddedGait: false, inputRevision: 7), scope: scope))
        let empty = gaitStore().store
        let baseline = phoneDecode(encoders: encoders, gait: empty)
        let baselineJSON = try json(baseline.document)
        XCTAssertNil(baseline.decode.config.gaitQuality)

        let rows: [(String, GaitWindowStore.DayRecord)] = [
            // Today's server: mode only (no release fields, no authority block).
            ("shadow, old server", try gaitRecord(mode: "shadow")),
            ("candidate, old server", try gaitRecord(mode: "candidate")),
            // The release-authority route: pinned, with a prior, the same input revision as HART's windows.
            ("shadow, pinned", try gaitRecord(mode: "shadow", releaseMode: "shadow", pinned: true, prior: 0.085,
                                              inputRevision: 7)),
            ("candidate, pinned", try gaitRecord(mode: "candidate", releaseMode: "candidate", pinned: true,
                                                 prior: 0.085, inputRevision: 7)),
            // A route field claiming more than the row's mode is lowered to the mode.
            ("candidate claiming production", try gaitRecord(mode: "candidate", releaseMode: "production",
                                                             pinned: true, prior: 0.085, inputRevision: 7)),
        ]
        for (name, record) in rows {
            let gait = gaitStore().store
            XCTAssertTrue(gait.save(record, scope: scope), name)
            XCTAssertEqual(gait.sources(from: from, to: to).count, 1, name)
            let decoded = phoneDecode(encoders: encoders, gait: gait)
            XCTAssertEqual(try json(decoded.document), baselineJSON, name)
            XCTAssertEqual(decoded.decode.config.cacheTag, baseline.decode.config.cacheTag, name)
            XCTAssertNil(decoded.decode.config.gaitQuality, name)
            XCTAssertNil(decoded.decode.input.gaitQuality, name)
            XCTAssertTrue(decoded.decode.selection.canonicalChannels.isEmpty, name)
        }

        // The pinned candidate row is valid evidence for a candidate arm: only an upgrade would let it shape the day,
        // and it would (the replay can see a difference).
        let gait = gaitStore().store
        gait.save(try gaitRecord(mode: "candidate", releaseMode: "candidate", pinned: true, prior: 0.085,
                                 inputRevision: 7), scope: scope)
        let candidate = phoneDecode(encoders: encoders, gait: gait).decode
        XCTAssertEqual(candidate.selection.use(of: .gaitQuality), .candidate)
        let attached = ActivityPhoneEvidence.attachingEncoderWindows(input(), store: encoders)
        let arm = candidate.selection.decode(attached, base: ActivityDecoderConfig(), channels: [.gaitQuality])
        let armDocument = ActivityContextDayBuilder.update(cached: nil, input: arm.input, now: to,
                                                           config: arm.config).document
        XCTAssertNotEqual(try json(armDocument), baselineJSON)
    }

    func testAProductionRowWithItsPinsShapesTheCanonicalDecode() throws {
        // No server can record production today; this shows the path the policy would open when one does.
        let encoders = try encoderStore()
        XCTAssertTrue(encoders.save(try hartRecord(embeddedGait: false, inputRevision: 7), scope: scope))
        let baseline = try json(phoneDecode(encoders: encoders, gait: gaitStore().store).document)
        let gait = gaitStore().store
        gait.save(try gaitRecord(mode: "production", releaseMode: "production", pinned: true, prior: 0.085,
                                 inputRevision: 7), scope: scope)
        let decoded = phoneDecode(encoders: encoders, gait: gait)
        XCTAssertEqual(decoded.decode.selection.canonicalChannels, [.gaitQuality])
        XCTAssertNotEqual(try json(decoded.document), baseline)

        // The same row computed from other uploads than HART's windows is not combined with them.
        let stale = gaitStore().store
        stale.save(try gaitRecord(mode: "production", releaseMode: "production", pinned: true, prior: 0.085,
                                  inputRevision: 6), scope: scope)
        XCTAssertEqual(try json(phoneDecode(encoders: encoders, gait: stale).document), baseline)
    }

    func testEmbeddedGaitWindowsInHartRecordsStayOutOfTheCanonicalDecode() throws {
        let plain = try encoderStore()
        plain.save(try hartRecord(embeddedGait: false), scope: scope)
        let baseline = try json(phoneDecode(encoders: plain, gait: gaitStore().store).document)
        for release in [nil, "shadow", "candidate", "bogus"] as [String?] {
            let encoders = try encoderStore()
            encoders.save(try hartRecord(embeddedGait: true, embeddedRelease: release), scope: scope)
            XCTAssertFalse(try XCTUnwrap(encoders.windows(from: from, to: to)).gaitWindows.isEmpty)
            let decoded = phoneDecode(encoders: encoders, gait: gaitStore().store)
            XCTAssertEqual(try json(decoded.document), baseline, String(describing: release))
            XCTAssertTrue(decoded.decode.input.gaitWindows.isEmpty)
        }
    }

    // MARK: Stored records

    func testRecordsStoredBeforeTheReleaseFieldsReadAsTheirRecordedModeNeverProduction() throws {
        let (gait, dir) = gaitStore()
        // The layout the base build wrote: no release, revision, pins or prior.
        let m = model()
        let old: [String: Any] = [
            "day": day, "resultRevision": "41", "mode": "candidate",
            "model": try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)),
            "windowsJSON": try windowsJSON(),
        ]
        let file = dir.appendingPathComponent(scope.ownerId).appendingPathComponent(scope.deviceId)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: old).write(to: file.appendingPathComponent("\(day).json"))

        let sources = gait.sources(from: from, to: to)
        XCTAssertEqual(sources.count, 1)
        let source = try XCTUnwrap(sources.first)
        XCTAssertEqual(source.releaseMode, .candidate)
        XCTAssertNil(source.expectedModelVersion)
        XCTAssertNil(source.gaitPrior)
        XCTAssertNil(source.inputRevision)
        let selection = ActivityExpertSelection.select(gaitQuality: sources)
        XCTAssertEqual(selection.use(of: .gaitQuality), .none)
        XCTAssertEqual(selection.decisions.first?.releaseMode, .shadow)
        XCTAssertEqual(selection.decisions.first?.reason, "model_not_pinned")

        // The recorded release is the weakest stored field; nothing reads as more than its mode.
        func release(_ mode: String, _ releaseMode: String?) throws -> ActivityReleaseMode {
            try gaitRecord(mode: mode, releaseMode: releaseMode).recordedRelease
        }
        XCTAssertEqual(try release("shadow", nil), .shadow)
        XCTAssertEqual(try release("candidate", nil), .candidate)
        XCTAssertEqual(try release("candidate", "shadow"), .shadow)
        XCTAssertEqual(try release("candidate", "production"), .candidate)
        XCTAssertEqual(try release("shadow", "candidate"), .shadow)
        XCTAssertEqual(try release("weird", nil), .shadow)
        XCTAssertEqual(try release("candidate", "weird"), .shadow)
    }

    func testHartRecordsStoredBeforeTheFieldsReadWithoutRevisionAndShadowEmbeddedGait() throws {
        let dir = tempDirectory("activity-windows")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "activity-phone-authority-\(UUID().uuidString)"))
        let store = ActivityEncoderWindowStore(directory: dir, defaults: defaults)
        store.setScope(scope)
        let current = try hartRecord(embeddedGait: true)
        let old: [String: Any] = ["day": day, "resultRevision": "9", "encoderId": "hart",
                                  "modelVersion": "hart-wisdm-v0", "windowsJSON": current.windowsJSON]
        let file = dir.appendingPathComponent(scope.ownerId).appendingPathComponent(scope.deviceId)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: old).write(to: file.appendingPathComponent("\(day).json"))
        XCTAssertNotNil(store.windows(from: from, to: to))
        XCTAssertEqual(store.inputRevisions(from: from, to: to), [:])
        XCTAssertEqual(store.embeddedGaitRelease(from: from, to: to), .shadow)
        XCTAssertEqual(store.revisions(days: [day]), [day: "9"])
    }

    func testAnUnchangedDayCanOnlyBeLoweredInPlace() throws {
        let gait = gaitStore().store
        gait.save(try gaitRecord(mode: "candidate", releaseMode: "candidate", pinned: true, prior: 0.085), scope: scope)
        XCTAssertFalse(gait.lowerRelease(day: day, to: .production, scope: scope))
        XCTAssertFalse(gait.lowerRelease(day: day, to: .candidate, scope: scope))
        XCTAssertEqual(gait.sources(from: from, to: to).first?.releaseMode, .candidate)
        XCTAssertTrue(gait.lowerRelease(day: day, to: .shadow, scope: scope))
        XCTAssertEqual(gait.sources(from: from, to: to).first?.releaseMode, .shadow)
        XCTAssertEqual(gait.revisions(days: [day]), [day: "41"])
        // Another account's scope never writes.
        XCTAssertFalse(gait.lowerRelease(day: day, to: .shadow,
                                         scope: .init(ownerId: "owner-2", deviceId: "whoop-A")))
    }

    // MARK: Route parsing

    func testGaitRouteParsingOldAndNewServer() throws {
        let m = model()
        let modelObject: [String: Any] = try {
            var o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(m)) as! [String: Any]
            o["weights_digest"] = m.weightsDigest
            return o
        }()
        let windows = try JSONSerialization.jsonObject(with: Data(try windowsJSON().utf8))
        let body: [String: Any] = ["days": [
            // Today's server.
            ["day": "2026-10-04", "result_revision": "40", "mode": "candidate", "model_version": m.modelVersion,
             "model": modelObject, "windows": windows],
            // The release-authority route.
            ["day": "2026-10-05", "result_revision": "41", "mode": "candidate", "model_version": m.modelVersion,
             "release_mode": "candidate", "input_revision": "7", "model": modelObject, "windows": windows,
             "identity": ["model_id": "eldernet", "model_version": m.modelVersion, "weights_digest": m.weightsDigest],
             "authority": ["policy": "expert-authority-1", "release_mode": "shadow", "use": "none",
                           "reason": "model_not_pinned", "input_revision": "7",
                           "pinned_model_version": m.modelVersion, "pinned_weights_digest": m.weightsDigest,
                           "gait_prior": 0.085]],
            // A row written before the authority block; unchanged at the stored revision.
            ["day": "2026-10-06", "result_revision": "42", "mode": "candidate", "model_version": m.modelVersion,
             "release_mode": "candidate", "input_revision": "8", "unchanged": true, "authority": NSNull()],
            // An identity that names another model: the windows are not trusted.
            ["day": "2026-10-07", "result_revision": "43", "mode": "candidate", "model_version": m.modelVersion,
             "model": modelObject, "windows": windows,
             "identity": ["model_version": m.modelVersion, "weights_digest": String(repeating: "f", count: 64)]],
        ]]
        let days = ServerScoreRepository.gaitWindowsDays(from: body)
        XCTAssertEqual(days.map(\.day), ["2026-10-04", "2026-10-05", "2026-10-06", "2026-10-07"])

        let old = days[0]
        XCTAssertNil(old.releaseMode); XCTAssertNil(old.inputRevision); XCTAssertNil(old.pinnedModelVersion)
        let oldRecord = try XCTUnwrap(GaitWindowStore.DayRecord(old))
        XCTAssertEqual(oldRecord.recordedRelease, .candidate)

        let new = days[1]
        XCTAssertEqual(new.releaseMode, "shadow")          // the weaker of the row's and the authority block's
        XCTAssertEqual(new.inputRevision, 7)
        XCTAssertEqual(new.pinnedModelVersion, m.modelVersion)
        XCTAssertEqual(new.pinnedWeightsDigest, m.weightsDigest)
        XCTAssertEqual(new.gaitPrior, 0.085)
        XCTAssertEqual(new.producerReason, "model_not_pinned")
        XCTAssertEqual(new.identity?["model_id"], "eldernet")
        let newRecord = try XCTUnwrap(GaitWindowStore.DayRecord(new))
        XCTAssertEqual(newRecord.recordedRelease, .shadow)

        XCTAssertTrue(days[2].unchanged)
        XCTAssertEqual(days[2].releaseMode, "candidate")
        XCTAssertEqual(days[2].inputRevision, 8)
        XCTAssertNil(days[2].pinnedModelVersion)
        XCTAssertNil(GaitWindowStore.DayRecord(days[2]))

        XCTAssertNil(days[3].model)
        XCTAssertNil(GaitWindowStore.DayRecord(days[3]))
    }

    func testActivityWindowsRouteParsingCarriesRevisionAndReleases() {
        let body: [String: Any] = ["days": [
            ["day": "2026-10-04", "result_revision": "7", "unchanged": true, "encoder_id": "hart",
             "model_version": "hart-wisdm-v0"],
            ["day": "2026-10-05", "result_revision": "12", "encoder_id": "hart", "model_version": "hart-wisdm-v0",
             "input_revision": "31", "release_mode": "production", "embedded_gait_release_mode": "shadow",
             "windows": ["format": "hart-windows-1", "t0": dayStart]],
        ]]
        let days = ServerScoreRepository.activityWindowsDays(from: body)
        XCTAssertNil(days[0].inputRevision)
        XCTAssertNil(days[0].embeddedGaitReleaseMode)
        XCTAssertEqual(days[1].inputRevision, 31)
        XCTAssertEqual(days[1].releaseMode, "production")
        XCTAssertEqual(days[1].embeddedGaitReleaseMode, "shadow")
        XCTAssertNil(ServerScoreRepository.revisionNumber("x"))
        XCTAssertNil(ServerScoreRepository.revisionNumber(true))
        XCTAssertEqual(ServerScoreRepository.revisionNumber(NSNumber(value: 5)), 5)
    }

    // MARK: Fetch independence

    private struct FetchFailed: Error {}

    func testGaitFetchRunsWhenHartFetchFails() async {
        let sync = ActivityWindowsSync(minimumInterval: 300)
        var gaitRan = false
        let outcome = await sync.run(now: Date(timeIntervalSince1970: 1_000),
                                     hart: { throw FetchFailed() },
                                     gait: { gaitRan = true; return true })
        XCTAssertTrue(gaitRan)
        XCTAssertEqual(outcome, .init(hartChanged: false, gaitChanged: true, hartFailed: true, gaitFailed: false))
        XCTAssertEqual(outcome?.changed, true)

        // And the other way round.
        let other = ActivityWindowsSync(minimumInterval: 300)
        let reversed = await other.run(hart: { true }, gait: { throw FetchFailed() })
        XCTAssertEqual(reversed, .init(hartChanged: true, gaitChanged: false, hartFailed: false, gaitFailed: true))
    }

    func testOnePassAtATime() async {
        let sync = ActivityWindowsSync(minimumInterval: 300)
        var release: CheckedContinuation<Void, Never>?
        var hartCalls = 0, gaitCalls = 0
        let first = Task { @MainActor in
            await sync.run(now: Date(timeIntervalSince1970: 1_000), hart: {
                hartCalls += 1
                await withCheckedContinuation { release = $0 }
                return false
            }, gait: { gaitCalls += 1; return false })
        }
        while release == nil { await Task.yield() }
        XCTAssertTrue(sync.inFlight)
        // A pass asked for while one is in flight is dropped.
        let second = await sync.run(now: Date(timeIntervalSince1970: 2_000), hart: { hartCalls += 1; return true },
                                    gait: { gaitCalls += 1; return true })
        XCTAssertNil(second)
        release?.resume()
        let firstOutcome = await first.value
        XCTAssertNotNil(firstOutcome)
        XCTAssertEqual(hartCalls, 1); XCTAssertEqual(gaitCalls, 1)
        XCTAssertFalse(sync.inFlight)

        func pass(at seconds: TimeInterval) async -> ActivityWindowsSync.Outcome? {
            await sync.run(now: Date(timeIntervalSince1970: seconds), hart: { true }, gait: { true })
        }
        // Throttled until the interval has passed since the last start.
        let early = await pass(at: 1_100)
        XCTAssertNil(early)
        let due = await pass(at: 1_300)
        XCTAssertNotNil(due)
        // A reset (sign-out) lifts the wait.
        let again = await pass(at: 1_310)
        XCTAssertNil(again)
        sync.reset()
        let afterReset = await pass(at: 1_310)
        XCTAssertNotNil(afterReset)
    }
}

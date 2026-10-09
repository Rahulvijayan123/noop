import XCTest
import CZstd
import StrandAnalytics
@testable import frwhoop_worker

/// The on-host cache that keeps a raw-IMU day job from re-downloading and re-inferring the whole day each
/// time one more object of it turns ready.
final class ActivityLocalCacheTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("activity-cache-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func makeCache() throws -> ActivityLocalCache {
        try XCTUnwrap(ActivityLocalCache(path: directory.path))
    }

    func testNoDirectoryMeansNoCache() {
        XCTAssertNil(ActivityLocalCache(path: nil))
        XCTAssertNil(ActivityLocalCache(path: ""))
    }

    // MARK: Objects

    /// A second job over the same object reads it from the cache: no lease renewal, no download.
    func testLoadObjectsReusesACachedObject() throws {
        let cache = try makeCache()
        let (wire, digest) = try object(ts: 1_758_000_000)
        let objects = [(id: "o1", digest: digest, key: "k1")]

        var downloads = 0, renews = 0
        _ = try ActivityLane.loadObjects(objects: objects, renew: { renews += 1; return true },
                                         download: { _ in downloads += 1; return wire }, cache: cache)
        XCTAssertEqual(downloads, 1)

        var reused = -1
        let again = try ActivityLane.loadObjects(objects: objects, renew: { renews += 1; return true },
                                                 download: { _ in downloads += 1; return wire },
                                                 cache: cache, reused: { reused = $0 })
        XCTAssertEqual(downloads, 1, "the cached copy is used")
        XCTAssertEqual(renews, 1, "nothing is downloaded, so no lease renewal is needed for it")
        XCTAssertEqual(reused, 1)
        XCTAssertEqual(again.map(\.ts), [1_758_000_000])
    }

    /// A cached copy that no longer matches the job's digest is never trusted: it is dropped and the object
    /// downloaded again.
    func testACorruptCachedObjectIsDownloadedAgain() throws {
        let cache = try makeCache()
        let (wire, digest) = try object(ts: 1_758_000_100)
        cache.storeObject(Data("not zstd".utf8), digest: digest)

        var downloads = 0
        let records = try ActivityLane.loadObjects(objects: [(id: "o1", digest: digest, key: "k1")],
                                                   renew: { true },
                                                   download: { _ in downloads += 1; return wire }, cache: cache)
        XCTAssertEqual(downloads, 1)
        XCTAssertEqual(records.map(\.ts), [1_758_000_100])
        XCTAssertEqual(cache.object(digest: digest), wire, "the good copy replaces the corrupt one")
    }

    // MARK: Inference

    func testInferenceKeyChangesWithEveryInputItDependsOn() {
        let base = ActivityPythonService.RunRequest(startTs: 100, endTs: 104, columnsB64: ["AA", "BB"],
                                                    headB64: ["CC"], tailB64: [])
        let identity = ["checkpoint_sha256": "c1", "code_sha256": "k1"]
        let versions = ["model": "m1", "preprocessing": "p1"]
        let key = ActivityLocalCache.inferenceKey(request: base, identity: identity, versions: versions)
        XCTAssertNotNil(key)
        XCTAssertEqual(key, ActivityLocalCache.inferenceKey(request: base, identity: identity, versions: versions))
        var later = base; later.startTs = 101; later.endTs = 105
        var grown = base; grown.columnsB64.append("DD")
        var tail = base; tail.tailB64 = ["EE"]
        // Moving a second from the head into the body must not collide with the original.
        var shifted = base; shifted.headB64 = []; shifted.columnsB64 = ["CC", "AA", "BB"]
        let variants = [
            ActivityLocalCache.inferenceKey(request: base, identity: identity,
                                            versions: ["model": "m2", "preprocessing": "p1"]),
            ActivityLocalCache.inferenceKey(request: base, identity: identity,
                                            versions: ["model": "m1", "preprocessing": "p2"]),
            ActivityLocalCache.inferenceKey(request: base, identity: ["checkpoint_sha256": "c2", "code_sha256": "k1"],
                                            versions: versions),
            ActivityLocalCache.inferenceKey(request: base, identity: ["checkpoint_sha256": "c1", "code_sha256": "k2"],
                                            versions: versions),
            ActivityLocalCache.inferenceKey(request: later, identity: identity, versions: versions),
            ActivityLocalCache.inferenceKey(request: grown, identity: identity, versions: versions),
            ActivityLocalCache.inferenceKey(request: tail, identity: identity, versions: versions),
            ActivityLocalCache.inferenceKey(request: shifted, identity: identity, versions: versions),
        ]
        XCTAssertFalse(variants.contains(nil))
        XCTAssertEqual(Set(variants + [key]).count, variants.count + 1)
    }

    func testChangedWeightBytesUnderAReusedLabelAreANewKey() {
        // The label a child reports stays "hart-v1" while the checkpoint bytes it measured change: the earlier
        // answer must not be reused.
        let req = ActivityPythonService.RunRequest(startTs: 1, endTs: 2, columnsB64: ["AA"], headB64: [], tailB64: [])
        let versions = ["model": "hart-v1", "preprocessing": "1.0.0"]
        let before = ActivityLocalCache.inferenceKey(request: req, identity: ["checkpoint_sha256": "aa"],
                                                     versions: versions)
        let after = ActivityLocalCache.inferenceKey(request: req, identity: ["checkpoint_sha256": "bb"],
                                                    versions: versions)
        XCTAssertNotNil(before)
        XCTAssertNotEqual(before, after)
    }

    func testNoMeasuredIdentityMeansNoKey() {
        // A child older than this worker reports no measured identity; its answers are not cached at all.
        let req = ActivityPythonService.RunRequest(startTs: 1, endTs: 2, columnsB64: ["AA"], headB64: [], tailB64: [])
        XCTAssertNil(ActivityLocalCache.inferenceKey(request: req, identity: [:], versions: ["model": "m"]))
    }

    func testInferenceRoundTripsWindowsAndFeatures() throws {
        let cache = try makeCache()
        let result = ActivityPythonService.InferResult(
            ok: true, modelVersion: "hart-wisdm-v0", preprocessingVersion: "1.0.0",
            windows: [ActivityPythonService.WindowPrediction(
                start: 100, end: 104, label: "walking",
                probs: ["walking": 0.9, "stationary": 0.1], baseline: false,
                features: ["accel_rms_g": 0.12, "cadence_hz": 1.8])],
            error: nil, errorKind: nil, featureSchema: "imu-feat-1")
        let key = String(repeating: "a", count: 64)
        cache.storeInference(result, key: key)
        let back = try XCTUnwrap(cache.inference(key: key))
        XCTAssertTrue(back.ok)
        XCTAssertEqual(back.modelVersion, "hart-wisdm-v0")
        XCTAssertEqual(back.featureSchema, "imu-feat-1")
        XCTAssertEqual(back.windows.count, 1)
        XCTAssertEqual(back.windows[0].label, "walking")
        XCTAssertEqual(back.windows[0].probs, ["walking": 0.9, "stationary": 0.1])
        XCTAssertEqual(back.windows[0].features, ["accel_rms_g": 0.12, "cadence_hz": 1.8])
    }

    func testInferenceRoundTripsFineAndGaitWindows() throws {
        let cache = try makeCache()
        let gait = [
            ActivityGaitWindow(startTs: 100, endTs: 110, gaitProb: 0.93, isGait: true, cadenceSpm: 108.5,
                               speedMps: 1.21, strideM: 1.3, regularity: 0.81, steps: 18, modelVersion: "en-1"),
            ActivityGaitWindow(startTs: 105, endTs: 115, gaitProb: 0, isGait: false, prefiltered: true,
                               modelVersion: "en-1"),
        ]
        let result = ActivityPythonService.InferResult(
            ok: true, modelVersion: "hart", preprocessingVersion: "1.0.0",
            windows: [ActivityPythonService.WindowPrediction(
                start: 100, end: 104, label: "stationary", probs: ["stationary": 1], baseline: false,
                fine: ["sitting": 0.8, "typing": 0.2])],
            error: nil, errorKind: nil, fineSchema: "wisdm-act-1", gaitWindows: gait,
            gaitSchema: "gait-quality-1", gaitModelVersion: "en-1", gaitStatus: "gait_loaded")
        let key = String(repeating: "c", count: 64)
        cache.storeInference(result, key: key)
        let back = try XCTUnwrap(cache.inference(key: key))
        XCTAssertEqual(back.windows[0].fine, ["sitting": 0.8, "typing": 0.2])
        XCTAssertEqual(back.fineSchema, "wisdm-act-1")
        XCTAssertEqual(back.gaitWindows, gait)
        XCTAssertEqual(back.gaitSchema, "gait-quality-1")
        XCTAssertEqual(back.gaitStatus, "gait_loaded")
    }

    func testGaitVersionChangesTheInferenceKeyOnlyWhenPresent() {
        let req = ActivityPythonService.RunRequest(startTs: 1, endTs: 2, columnsB64: ["AA"], headB64: [], tailB64: [])
        let identity = ["checkpoint_sha256": "c"]
        let plain = ActivityLocalCache.inferenceKey(request: req, identity: identity,
                                                    versions: ["model": "m", "preprocessing": "p"])
        XCTAssertEqual(plain, ActivityLocalCache.inferenceKey(request: req, identity: identity,
                                                              versions: ["preprocessing": "p", "model": "m"]))
        XCTAssertNotEqual(plain, ActivityLocalCache.inferenceKey(request: req, identity: identity,
                                                                 versions: ["model": "m", "preprocessing": "p",
                                                                            "gait": "en-1"]))
    }

    func testFailedAnswersAndUnsafeKeysAreNotStored() throws {
        let cache = try makeCache()
        let failed = ActivityPythonService.InferResult(ok: false, modelVersion: nil, preprocessingVersion: nil,
                                                       windows: [], error: "x", errorKind: "model_missing")
        let key = String(repeating: "b", count: 64)
        cache.storeInference(failed, key: key)
        XCTAssertNil(cache.inference(key: key))
        let ok = ActivityPythonService.InferResult(ok: true, modelVersion: "m", preprocessingVersion: "p",
                                                   windows: [], error: nil, errorKind: nil)
        cache.storeInference(ok, key: "../../etc/passwd")
        XCTAssertNil(cache.inference(key: "../../etc/passwd"))
        cache.storeObject(Data([1]), digest: "../x")
        XCTAssertNil(cache.object(digest: "../x"))
    }

    func testPruneRemovesOnlyOldEntries() throws {
        let cache = try makeCache()
        let old = String(repeating: "c", count: 64), fresh = String(repeating: "d", count: 64)
        cache.storeObject(Data([1, 2, 3]), digest: old)
        cache.storeObject(Data([4, 5, 6]), digest: fresh)
        let oldFile = directory.appendingPathComponent("objects/\(old).zst")
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-4 * 86_400)],
                                              ofItemAtPath: oldFile.path)
        XCTAssertEqual(cache.prune(), 1)
        XCTAssertNil(cache.object(digest: old))
        XCTAssertNotNil(cache.object(digest: fresh))
    }

    // MARK: Helpers

    private func object(ts: Int64) throws -> (wire: Data, digest: String) {
        let record = Npb1ImuDecoder.Record(rowId: ts, ts: ts, columns: [Int16](repeating: 3, count: 600))
        let packed = try Npb1ImuDecoder.pack(records: [record])
        return (try zstd(packed), sha256Hex(packed))
    }

    private func zstd(_ data: Data) throws -> Data {
        let bound = Int(ZSTD_compressBound(data.count))
        var dst = [UInt8](repeating: 0, count: bound)
        let written: Int = data.withUnsafeBytes { src in
            dst.withUnsafeMutableBytes { out in
                Int(ZSTD_compress(out.baseAddress, out.count, src.baseAddress, src.count, 3))
            }
        }
        guard ZSTD_isError(written) == 0, written > 0 else { throw NSError(domain: "test", code: 1) }
        return Data(dst[0..<written])
    }
}

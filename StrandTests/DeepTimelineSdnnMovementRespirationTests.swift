import XCTest
import Foundation
import WhoopStore
import WhoopProtocol
import StrandAnalytics
@testable import Strand

/// The Deep Timeline tracks that read the heartbeat rhythm and the gravity vector: the windowed SDNN line,
/// the Movement track (it used to plot the gravity vector's length, a constant ~1 g), and the breathing
/// track (empty for every WHOOP 5/MG until it was estimated from the R-R rhythm).
final class DeepTimelineSdnnMovementRespirationTests: XCTestCase {
    private let base = 1_780_000_000

    // MARK: Titles, pill order, window choosers

    func testTitlesNameWhatIsPlotted() {
        XCTAssertEqual(Repository.TimelineMetric.sdnn.title, "Windowed SDNN")
        XCTAssertEqual(Repository.TimelineMetric.motion.title, "Movement")
        XCTAssertEqual(Repository.TimelineMetric.ouraMovement.title, "Ring Movement")
        XCTAssertNotEqual(Repository.TimelineMetric.motion.title, Repository.TimelineMetric.ouraMovement.title,
                          "two pills must not carry the same name")
    }

    func testSdnnPillSitsBesideTheRmssdPill() throws {
        let all = Repository.TimelineMetric.allCases
        let hrv = try XCTUnwrap(all.firstIndex(of: .hrv))
        XCTAssertEqual(all[hrv + 1], .sdnn)
    }

    func testSdnnWindowIsNeverNarrowerThanFiveMinutes() {
        XCTAssertEqual(Repository.sdnnRollingWindowSec(spanSeconds: 1), 300)
        XCTAssertEqual(Repository.sdnnRollingWindowSec(spanSeconds: 9_000), 300)
        XCTAssertEqual(Repository.sdnnRollingWindowSec(spanSeconds: 12_000), 400)
        XCTAssertEqual(Repository.sdnnRollingWindowSec(spanSeconds: 86_400), 600)
        XCTAssertGreaterThanOrEqual(Repository.sdnnRollingWindowSec(spanSeconds: 600),
                                    Repository.hrvRollingWindowSec(spanSeconds: 600))
    }

    func testRespirationStepIsAQuarterWindowWithAFloor() {
        XCTAssertEqual(Repository.respRollingStepSec(windowSec: 120), 30)
        XCTAssertEqual(Repository.respRollingStepSec(windowSec: 600), 150)
        XCTAssertEqual(Repository.respRollingStepSec(windowSec: 60), 30)
    }

    // MARK: Movement

    /// The old track plotted the vector's length. Rotating a unit vector through 90° between two seconds
    /// leaves that length at exactly 1 g, so a track built on it could not show the wrist moving.
    func testMovementSeesARotationThatLeavesTheVectorLengthUnchanged() {
        let still = (0..<5).map { GravitySample(ts: base + $0, x: 0, y: 0, z: 1) }
        let turned = [GravitySample(ts: base + 5, x: 1, y: 0, z: 0)]
        let pts = Repository.movementTimelinePoints(still + turned)
        XCTAssertEqual(pts.count, 5)
        XCTAssertEqual(pts.prefix(4).map(\.value), [0, 0, 0, 0])
        XCTAssertEqual(pts[4].value, 2.0.squareRoot(), accuracy: 1e-9)
        for g in still + turned {
            XCTAssertEqual((g.x * g.x + g.y * g.y + g.z * g.z).squareRoot(), 1, accuracy: 1e-12)
        }
    }

    func testMovementDropsDeltasAcrossASensorGap() {
        let a = GravitySample(ts: base, x: 0, y: 0, z: 1)
        let b = GravitySample(ts: base + 1, x: 0, y: 0.1, z: 1)
        let afterGap = GravitySample(ts: base + 600, x: 1, y: 0, z: 0)
        let next = GravitySample(ts: base + 601, x: 1, y: 0, z: 0)
        let pts = Repository.movementTimelinePoints([a, b, afterGap, next])
        XCTAssertEqual(pts.map { Int($0.date.timeIntervalSince1970) }, [base + 1, base + 601],
                       "the jump across 10 minutes is a dropout, not a 1.4 g spike")
        XCTAssertEqual(pts[0].value, 0.1, accuracy: 1e-9)
        XCTAssertEqual(pts[1].value, 0, accuracy: 1e-12)
    }

    func testMovementIsEmptyWithoutTwoSamples() {
        XCTAssertTrue(Repository.movementTimelinePoints([]).isEmpty)
        XCTAssertTrue(Repository.movementTimelinePoints([GravitySample(ts: base, x: 0, y: 0, z: 1)]).isEmpty)
    }

    @MainActor
    func testMovementSeriesReadsTheGravityStream() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        // Resting for two minutes, then walking: the vector swings 0.4 g between consecutive seconds.
        var gravity = (0..<120).map { GravitySample(ts: base + $0, x: 0, y: 0, z: 1) }
        gravity += (120..<240).map { GravitySample(ts: base + $0, x: 0, y: $0.isMultiple(of: 2) ? 0.4 : 0, z: 1) }
        try await store.insert(Streams(gravity: gravity), deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)

        let series = await repo.timelineSeries(metric: .motion, from: base, to: base + 240, targetPoints: 600)
        XCTAssertTrue(series.isRaw)
        let resting = series.points.filter { $0.date.timeIntervalSince1970 < Double(base + 120) }
        let walking = series.points.filter { $0.date.timeIntervalSince1970 >= Double(base + 121) }
        XCTAssertFalse(resting.isEmpty)
        XCTAssertFalse(walking.isEmpty)
        XCTAssertTrue(resting.allSatisfy { $0.value < 0.01 })
        XCTAssertTrue(walking.allSatisfy { $0.value > 0.3 })
    }

    // MARK: SDNN

    /// 1 s-spaced beats alternating 900 / 1100 ms: a known 100 ms spread, beat-accurate, fully covered.
    private func steadyBeats(_ count: Int) -> [RRInterval] {
        (0..<count).map { RRInterval(ts: base + $0, rrMs: $0.isMultiple(of: 2) ? 900 : 1_100) }
    }

    @MainActor
    func testSdnnSeriesReadsTheBeatSpreadNotTheSuccessiveDifference() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        try await store.insert(Streams(rr: steadyBeats(1_800)), deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)

        let from = base + 600, to = base + 1_800
        let sdnn = await repo.timelineSeries(metric: .sdnn, from: from, to: to, targetPoints: 600)
        XCTAssertFalse(sdnn.points.isEmpty)
        XCTAssertFalse(sdnn.derivedFromRR)
        for p in sdnn.points { XCTAssertEqual(p.value, 100, accuracy: 3.0) }

        // The rMSSD line over the same beats reads the 200 ms beat-to-beat swing, a different number.
        let rmssd = await repo.timelineSeries(metric: .hrv, from: from, to: to, targetPoints: 600)
        XCTAssertFalse(rmssd.points.isEmpty)
        for p in rmssd.points { XCTAssertEqual(p.value, 200, accuracy: 3.0) }
    }

    @MainActor
    func testSdnnFirstPointsAreFullWindowsAndNothingPrecedesTheView() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        try await store.insert(Streams(rr: steadyBeats(1_800)), deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)

        // Beats start 600 s before the view: the very first second already has a full five-minute window.
        let from = base + 600
        let series = await repo.timelineSeries(metric: .sdnn, from: from, to: from + 600, targetPoints: 600)
        let first = try XCTUnwrap(series.points.first)
        XCTAssertGreaterThanOrEqual(first.date.timeIntervalSince1970, Double(from))
        XCTAssertLessThan(first.date.timeIntervalSince1970, Double(from + 60),
                          "the lookback must let the line start at the left edge instead of a window later")
    }

    @MainActor
    func testSdnnSeriesIsEmptyWhenTheStreamIsOverCounted() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        // The same beat stored under two different channels doubles the heart-time per wall-clock second.
        let doubled = steadyBeats(1_200).flatMap {
            [RRInterval(ts: $0.ts, rrMs: $0.rrMs), RRInterval(ts: $0.ts, rrMs: $0.rrMs + 1)]
        }
        try await store.insert(Streams(rr: doubled), deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)
        let series = await repo.timelineSeries(metric: .sdnn, from: base, to: base + 1_200, targetPoints: 600)
        XCTAssertTrue(series.points.isEmpty, "an over-counted capture must leave a gap, not an inflated spread")
    }

    // MARK: Respiration

    private func rsaBeats(perMinute: Double, seconds: Int) -> [RRInterval] {
        var out: [RRInterval] = []
        var t = Double(base)
        let end = Double(base + seconds)
        while t < end {
            let rr = 900 + 60 * sin(2 * Double.pi * (t - Double(base)) * perMinute / 60.0)
            out.append(RRInterval(ts: Int(t), rrMs: Int(rr.rounded())))
            t += rr / 1000.0
        }
        return out
    }

    @MainActor
    func testRespirationIsEstimatedFromTheHeartbeatWhenTheStrapSendsNoBreathingChannel() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        try await store.insert(Streams(rr: rsaBeats(perMinute: 14, seconds: 1_800)), deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)

        let series = await repo.timelineSeries(metric: .respiration, from: base + 300, to: base + 1_800,
                                               targetPoints: 600)
        XCTAssertTrue(series.derivedFromRR, "the view must be told this is an estimate, not a sensor channel")
        XCTAssertFalse(series.points.isEmpty)
        let rates = series.points.map(\.value)
        XCTAssertTrue(rates.allSatisfy { (8.0...25.0).contains($0) }, "breaths per minute, not an ADC waveform")
        XCTAssertEqual(rates.sorted()[rates.count / 2], 14, accuracy: 2.0)
        XCTAssertTrue(series.points.allSatisfy { $0.date.timeIntervalSince1970 >= Double(base + 300) })
    }

    @MainActor
    func testRawBreathingChannelWinsOverTheEstimate() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        let resp = (0..<300).map { RespSample(ts: base + $0, raw: 2_000 + $0 % 7) }
        try await store.insert(Streams(rr: rsaBeats(perMinute: 14, seconds: 1_800), resp: resp), deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)

        let series = await repo.timelineSeries(metric: .respiration, from: base, to: base + 300, targetPoints: 600)
        XCTAssertFalse(series.points.isEmpty)
        XCTAssertFalse(series.derivedFromRR, "a real channel must be plotted as itself, never replaced by an estimate")
        XCTAssertTrue(series.points.allSatisfy { $0.value >= 2_000 })
    }

    @MainActor
    func testRespirationIsEmptyForAStretchWithNoSteadyBeats() async throws {
        let store = try await WhoopStore.inMemory()
        let dev = "my-whoop"
        try await store.upsertDevice(id: dev, mac: nil, name: "WHOOP")
        try await store.insert(Streams(rr: [RRInterval(ts: base, rrMs: 900), RRInterval(ts: base + 1, rrMs: 910)]),
                               deviceId: dev)
        let repo = Repository(deviceId: dev)
        repo.setStoreForTesting(store)
        let series = await repo.timelineSeries(metric: .respiration, from: base, to: base + 600, targetPoints: 600)
        XCTAssertTrue(series.points.isEmpty)
        XCTAssertFalse(series.derivedFromRR)
    }

    // MARK: Pills per device

    @MainActor
    func testRingMovementPillIsOnlyOfferedForARing() {
        let strap = Repository(deviceId: "my-whoop").timelineMetrics()
        XCTAssertFalse(strap.contains(.ouraMovement), "a strap can never fill the ring's movement track")
        XCTAssertTrue(strap.contains(.motion))
        XCTAssertTrue(strap.contains(.sdnn))
        XCTAssertTrue(strap.contains(.respiration))

        let ring = Repository(deviceId: "oura-1A2B3C").timelineMetrics()
        XCTAssertTrue(ring.contains(.ouraMovement))
        XCTAssertEqual(ring.count, strap.count + 1)
    }
}

import XCTest
@testable import StrandAnalytics
import WhoopProtocol
import WhoopStore

/// BW2 reliability: notification spacing, stale queued deliveries, carry persistence.
final class WatchdogNotifySpacingTests: XCTestCase {

    // MARK: - Carry

    func testCarryDecodesWithoutQueuedAtAndRoundTrips() throws {
        let legacy = Data(#"{"notifyDelivery":"queued","lastNotifiedAt":123}"#.utf8)
        let decoded = try JSONDecoder().decode(WatchdogCarry.self, from: legacy)
        XCTAssertNil(decoded.notifyQueuedAtUnix)
        XCTAssertEqual(decoded.notifyDelivery, "queued")
        var carry = WatchdogCarry.empty
        carry.notifyQueuedAtUnix = 456
        let again = try JSONDecoder().decode(WatchdogCarry.self, from: JSONEncoder().encode(carry))
        XCTAssertEqual(again.notifyQueuedAtUnix, 456)
    }

    // MARK: - Notification policy

    /// Ticks the pure policy the way the service does: a push is queued, then its delivery lands as `delivered`.
    private struct PushSim {
        var carry = WatchdogCarry.empty
        var pushes: [(Int, String)] = []
        var delivered = "sent"

        mutating func tick(now: Int, severity: WatchdogSeverity, safety: Bool, episodeId: String,
                           recon: Double = 2.5, label: WatchdogEventLabel = .safetyBound) {
            let (want, reason) = WatchdogNotifyPolicy.decision(
                severity: severity, openedEpisode: false, safety: safety, previousSafety: carry.lastSafety,
                fused: recon, previousFused: carry.lastJointEnergy, recon: recon,
                previousRecon: carry.lastJointEnergy, eventLabel: label, episodeId: episodeId,
                notifiedSevereEpisodeId: carry.notifiedSevereEpisodeId, lastNotifiedAt: carry.lastNotifiedAt,
                nowUnix: now, notifyDelivery: carry.notifyDelivery, notifyQueuedAtUnix: carry.notifyQueuedAtUnix)
            if want {
                pushes.append((now, reason))
                carry.lastNotifiedAt = now
                carry.notifyDelivery = "queued"
                carry.notifyQueuedAtUnix = now
                carry.notifyDelivery = delivered
                if delivered == "sent" { carry.notifiedSevereEpisodeId = episodeId }
            }
            carry.lastSafety = safety
            carry.lastJointEnergy = recon
        }
    }

    func testSafetyFlappingForThirtyMinutesPagesExactlyOnce() {
        var sim = PushSim()
        let t0 = 5_000_000
        for t in stride(from: t0, to: t0 + 30 * 60, by: WatchdogConfig.tickSeconds) {
            let on = ((t - t0) / 40) % 2 == 0
            sim.tick(now: t, severity: on ? .severe : .active, safety: on, episodeId: "wd-safety-\(t0)")
        }
        XCTAssertEqual(sim.pushes.count, 1)
        XCTAssertEqual(sim.pushes.first?.0, t0)
    }

    func testSafetyReNotifyInsideAnEpisodeWaitsAnHour() {
        let t0 = 6_000_000
        var carry = WatchdogCarry.empty
        carry.lastNotifiedAt = t0
        carry.notifyDelivery = "sent"
        carry.notifiedSevereEpisodeId = "wd-1"
        func edge(at now: Int) -> (Bool, String) {
            WatchdogNotifyPolicy.decision(severity: .severe, openedEpisode: false, safety: true,
                                          previousSafety: false, fused: 2.5, previousFused: 2.5,
                                          eventLabel: .safetyBound, episodeId: "wd-1",
                                          notifiedSevereEpisodeId: carry.notifiedSevereEpisodeId,
                                          lastNotifiedAt: carry.lastNotifiedAt, nowUnix: now,
                                          notifyDelivery: carry.notifyDelivery)
        }
        XCTAssertEqual(edge(at: t0 + 40).1, "safety-cooldown")
        XCTAssertEqual(edge(at: t0 + 59 * 60).1, "safety-cooldown")
        let after = edge(at: t0 + 60 * 60)
        XCTAssertTrue(after.0)
        XCTAssertEqual(after.1, "safety")
    }

    func testNewEpisodePagesAfterFifteenMinutesButNotWithinTen() {
        let t0 = 7_000_000
        var sim = PushSim()
        sim.tick(now: t0, severity: .severe, safety: true, episodeId: "wd-1")
        XCTAssertEqual(sim.pushes.count, 1)
        // Episode 1 resolves and re-arms (nextState clears the notified id).
        sim.tick(now: t0 + 20, severity: .withinLimits, safety: false, episodeId: "wd-1")
        sim.carry.notifiedSevereEpisodeId = ""
        // A second episode 5 minutes later is held by the 10-minute floor…
        sim.tick(now: t0 + 300, severity: .severe, safety: true, episodeId: "wd-2")
        XCTAssertEqual(sim.pushes.count, 1)
        let (early, earlyReason) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: true, safety: true, previousSafety: false, fused: 2.5,
            previousFused: 0, episodeId: "wd-2", notifiedSevereEpisodeId: "", lastNotifiedAt: t0, nowUnix: t0 + 300)
        XCTAssertFalse(early)
        XCTAssertEqual(earlyReason, "min-gap")
        // …and a new episode 15 minutes after the last push pages.
        sim.tick(now: t0 + 900, severity: .withinLimits, safety: false, episodeId: "wd-2")
        sim.tick(now: t0 + 920, severity: .severe, safety: false, episodeId: "wd-3")
        XCTAssertEqual(sim.pushes.count, 2)
        XCTAssertEqual(sim.pushes.last?.1, "first-severe")
    }

    func testEscalateCooldownStillApplies() {
        let t = 8_000_000
        let (inside, rIn) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 3.2, previousFused: 2.4, recon: 3.2, previousRecon: 2.4,
            eventLabel: .abnormalMultiDirection, episodeId: "wd-1", notifiedSevereEpisodeId: "wd-1",
            lastNotifiedAt: t, nowUnix: t + 15 * 60, notifyDelivery: "sent")
        XCTAssertFalse(inside)
        XCTAssertEqual(rIn, "cooldown")
        let (after, rAfter) = WatchdogNotifyPolicy.decision(
            severity: .severe, openedEpisode: false, safety: false, previousSafety: false,
            fused: 3.2, previousFused: 2.4, recon: 3.2, previousRecon: 2.4,
            eventLabel: .abnormalMultiDirection, episodeId: "wd-1", notifiedSevereEpisodeId: "wd-1",
            lastNotifiedAt: t, nowUnix: t + WatchdogConfig.notifyCooldownSeconds, notifyDelivery: "sent")
        XCTAssertTrue(after)
        XCTAssertEqual(rAfter, "escalate")
    }

    func testStaleQueuedDeliveryBecomesRetryable() {
        let t0 = 9_000_000
        func decide(_ now: Int, queuedAt: Int?) -> (Bool, String) {
            WatchdogNotifyPolicy.decision(severity: .severe, openedEpisode: false, safety: false,
                                          previousSafety: false, fused: 2.5, previousFused: 2.5,
                                          episodeId: "wd-1", notifiedSevereEpisodeId: "",
                                          lastNotifiedAt: t0, nowUnix: now, notifyDelivery: "queued",
                                          notifyQueuedAtUnix: queuedAt)
        }
        XCTAssertEqual(decide(t0 + 60, queuedAt: t0).1, "in-flight")
        XCTAssertEqual(decide(t0 + 120, queuedAt: t0).1, "in-flight")
        // Killed mid-post: after 120 s the queued push counts as failed, retried after the cooldown.
        XCTAssertEqual(decide(t0 + 121, queuedAt: t0).1, "retry-wait")
        let retry = decide(t0 + WatchdogConfig.notifyCooldownSeconds, queuedAt: t0)
        XCTAssertTrue(retry.0)
        XCTAssertEqual(retry.1, "retry")
        // A carry persisted before the field existed falls back to lastNotifiedAt (stamped with the queue).
        XCTAssertEqual(decide(t0 + WatchdogConfig.notifyCooldownSeconds, queuedAt: nil).1, "retry")
        XCTAssertEqual(WatchdogNotifyPolicy.effectiveDelivery("queued", queuedAtUnix: t0, nowUnix: t0 + 121), "failed")
        XCTAssertEqual(WatchdogNotifyPolicy.effectiveDelivery("queued", queuedAtUnix: nil, nowUnix: t0 + 9999), "queued")
        XCTAssertEqual(WatchdogNotifyPolicy.effectiveDelivery("sent", queuedAtUnix: t0, nowUnix: t0 + 9999), "sent")
    }
}

import XCTest
@testable import StrandAnalytics

final class DayStretchLayoutTests: XCTestCase {

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    /// A midnight, UTC.
    private let day = 1_760_000_000 - (1_760_000_000 % 86_400)

    private func at(_ hour: Int, _ minute: Int = 0) -> Int { day + hour * 3_600 + minute * 60 }

    private func episode(_ label: String = "Desk sitting", from start: Int, minutes: Int = 10) -> ActivityEpisode {
        ActivityEpisode(
            start: start, end: start + minutes * 60, label: label,
            posture: HeadProbabilities([.seatedLikely: 0.8]),
            locomotion: HeadProbabilities([.stationary: 0.9]),
            armBehavior: HeadProbabilities([.deskLike: 0.7]),
            intensity: 0.1, confidence: 0.7, uncertainty: 0.3, sleep: .awake, wear: .onWrist)
    }

    private func layout(_ episodes: [ActivityEpisode], recent: Int = 5) -> DayStretchLayout {
        DayStretchLayout(episodes: episodes, recentCount: recent, calendar: utc)
    }

    // MARK: Parts of the day

    func testTheHourDecidesThePartOfTheDay() {
        XCTAssertEqual(StretchDayPart.of(at(0), calendar: utc), .overnight)
        XCTAssertEqual(StretchDayPart.of(at(4, 59), calendar: utc), .overnight)
        XCTAssertEqual(StretchDayPart.of(at(5), calendar: utc), .morning)
        XCTAssertEqual(StretchDayPart.of(at(11, 59), calendar: utc), .morning)
        XCTAssertEqual(StretchDayPart.of(at(12), calendar: utc), .midday)
        XCTAssertEqual(StretchDayPart.of(at(16, 59), calendar: utc), .midday)
        XCTAssertEqual(StretchDayPart.of(at(17), calendar: utc), .evening)
        XCTAssertEqual(StretchDayPart.of(at(23, 59), calendar: utc), .evening)
    }

    func testThePartIsReadInTheCalendarsOwnTimeZone() {
        var pacific = Calendar(identifier: .gregorian)
        pacific.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // 19:00 UTC is noon in Los Angeles in October.
        XCTAssertEqual(StretchDayPart.of(at(19), calendar: utc), .evening)
        XCTAssertEqual(StretchDayPart.of(at(19), calendar: pacific), .midday)
    }

    // MARK: The newest few, then the rest

    func testTheNewestFiveLeadAndTheRestAreGroupedByPartOfDay() {
        var stretches: [ActivityEpisode] = []
        for h in [1, 2, 6, 7, 8, 13, 14, 18, 19, 20] { stretches.append(episode(from: at(h))) }

        let result = layout(stretches)

        XCTAssertEqual(result.recent.map(\.start), [at(20), at(19), at(18), at(14), at(13)])
        XCTAssertEqual(result.earlier.map(\.part), [.morning, .overnight])
        XCTAssertEqual(result.earlier[0].stretches.map(\.start), [at(8), at(7), at(6)])
        XCTAssertEqual(result.earlier[1].stretches.map(\.start), [at(2), at(1)])
        XCTAssertEqual(result.count, 10)
    }

    func testEveryStretchAppearsExactlyOnce() {
        let stretches = (0..<40).map { episode(from: at(0) + $0 * 1_800, minutes: 20) }
        let result = layout(stretches)
        let shown = result.recent + result.earlier.flatMap(\.stretches)
        XCTAssertEqual(shown.count, 40)
        XCTAssertEqual(Set(shown.map(\.start)).count, 40)
    }

    func testGroupsGoLatestPartOfTheDayFirstAndEmptyOnesAreLeftOut() {
        let result = layout([
            episode(from: at(23)), episode(from: at(22)), episode(from: at(21)),
            episode(from: at(20)), episode(from: at(19)),
            episode(from: at(13)), episode(from: at(3)),
        ])
        XCTAssertEqual(result.earlier.map(\.part), [.midday, .overnight])
    }

    func testADayWithFiveOrFewerStretchesHasNothingEarlier() {
        let result = layout([episode(from: at(9)), episode(from: at(10)), episode(from: at(11))])
        XCTAssertEqual(result.recent.count, 3)
        XCTAssertTrue(result.earlier.isEmpty)
    }

    func testBlipsUnderAMinuteAreLeftOff() {
        let blip = ActivityEpisode(
            start: at(10), end: at(10) + 45, label: "Walking",
            posture: HeadProbabilities(), locomotion: HeadProbabilities(), armBehavior: HeadProbabilities(),
            intensity: nil, confidence: 0.5, uncertainty: 0.5, sleep: .awake, wear: .onWrist)
        let result = layout([blip, episode(from: at(9))])
        XCTAssertEqual(result.recent.map(\.start), [at(9)])
    }

    func testAStretchBelongsToThePartItStartedIn() {
        // Starts at 11:50 and runs well into the midday.
        let result = layout([episode(from: at(11, 50), minutes: 90)], recent: 0)
        XCTAssertEqual(result.earlier.map(\.part), [.morning])
    }

    func testNoStretchesMeansNothingToShow() {
        let result = layout([])
        XCTAssertTrue(result.recent.isEmpty)
        XCTAssertTrue(result.earlier.isEmpty)
        XCTAssertEqual(result.count, 0)
    }

    // MARK: Position changes

    private func event(_ kind: ActivityTransitionKind, at ts: Int, _ p: Double = 0.7) -> ActivityTransitionEvent {
        ActivityTransitionEvent(kind: kind, probability: p, ts: ts)
    }

    func testOnlyLikelyEventsAreShownNewestFirst() {
        let events = [event(.sitToStandLike, at: at(9)), event(.standToSitLike, at: at(11)),
                      event(.lyingDownLike, at: at(10), 0.2)]
        XCTAssertEqual(PositionChanges.all(events).map(\.ts), [at(11), at(9)])
    }

    func testEventsBelongToStretchesTheyFallInOrJustOutside() {
        let sitting = episode("Desk sitting", from: at(9), minutes: 30)       // 09:00 - 09:30
        let events = [
            event(.sitToStandLike, at: at(9, 10)),                              // inside
            event(.standToSitLike, at: at(9, 31)),                              // 60 s after the end
            event(.lyingDownLike, at: at(9, 40)),                               // well after
            event(.gettingUpLike, at: at(8, 59)),                               // 60 s before the start
        ]
        let near = PositionChanges.near([sitting], in: events)
        XCTAssertEqual(Set(near.map(\.kind)), [.sitToStandLike, .standToSitLike, .gettingUpLike])
    }

    func testNoStretchesMeansNoEventsBelongToThem() {
        XCTAssertTrue(PositionChanges.near([], in: [event(.walkStart, at: at(9))]).isEmpty)
    }

    func testAnEventNearTwoStretchesIsListedOnce() {
        let a = episode(from: at(9), minutes: 10)
        let b = episode(from: at(9, 10), minutes: 10)
        let near = PositionChanges.near([a, b], in: [event(.sitToStandLike, at: at(9, 10))])
        XCTAssertEqual(near.count, 1)
    }
}

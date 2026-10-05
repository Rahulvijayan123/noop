import Foundation
import SwiftUI
import StrandAnalytics

/// Everything the Heart rate day page shows beneath the graph: the strap's own stretches ("Through the day")
/// and the ActivityContext decode, loaded so the page is useful at once and then corrected.
///
/// - Stored results are drawn first, from memory or from disk, so opening the page does not start from a
///   blank list.
/// - The live read then runs. The strap's stretches are built the moment the streams are in, in parallel with
///   the decoder, so the newest stretch does not wait for the slower decode.
/// - The decoder reports the day so far while it works through a day it has not seen, so the lane fills from
///   the left instead of appearing all at once.
/// - A refresh that arrives mid-run (fresh strap data lands often) is remembered and run once afterwards,
///   never stacked beside the one in flight, and never closer than `minimumGap` to the last.
@MainActor
final class DayTimelineModel: ObservableObject {
    @Published private(set) var dayStates: [DayStateSegment] = []
    /// The end of the data the shown stretches were built from, so the page can say how fresh they are.
    @Published private(set) var statesReach: Date?
    /// True from the start of a run until the strap's stretches for it have landed.
    @Published private(set) var statesBusy = true

    @Published private(set) var activityContext: ActivityContextDayDocument?
    /// True from the start of a run until the decoder's final document for it has landed.
    @Published private(set) var activityBusy = true
    /// How far into the day the shown document reaches while it is still a partial one; nil once complete.
    @Published private(set) var activityPartialReach: Date?

    /// Wait this long between two runs for the same day.
    static let minimumGap: TimeInterval = 2.5

    private struct Remembered {
        var states: [DayStateSegment]?
        var statesReach: Int?
        var context: ActivityContextDayDocument?
    }

    private static var memory: [Int: Remembered] = [:]
    private static var memoryOrder: [Int] = []
    private static let memoryDays = 4

    private var shownDay: Int?
    private var wanted: Date?
    private var runner: Task<Void, Never>?
    private var repo: Repository?
    private var runToken = 0
    private var contextFinal = false
    private var lastRunDay: Int?
    private var lastRunEnded: Date?

    /// Ask for `dayStart` to be shown and brought up to date. Cheap to call as often as needed: calls made
    /// while a run is in flight are folded into one follow-up run.
    func request(dayStart: Date, repo: Repository) {
        self.repo = repo
        let day = Int(dayStart.timeIntervalSince1970)
        if shownDay != day { show(day) }
        wanted = dayStart
        guard runner == nil else { return }
        runner = Task { [weak self] in
            await self?.drain()
        }
    }

    // MARK: Showing a day

    /// Switch to `day`. Stretches of the previous day are never left on screen under the new date.
    private func show(_ day: Int) {
        shownDay = day
        contextFinal = false
        activityPartialReach = nil
        let remembered = Self.memory[day]
        dayStates = remembered?.states ?? []
        statesReach = remembered?.statesReach.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        activityContext = remembered?.context
        statesBusy = true
        activityBusy = true
    }

    private func remember(_ day: Int, _ change: (inout Remembered) -> Void) {
        var entry = Self.memory[day] ?? Remembered()
        change(&entry)
        Self.memory[day] = entry
        Self.memoryOrder.removeAll { $0 == day }
        Self.memoryOrder.append(day)
        while Self.memoryOrder.count > Self.memoryDays {
            Self.memory[Self.memoryOrder.removeFirst()] = nil
        }
    }

    // MARK: Runs

    private func drain() async {
        while let next = wanted {
            let day = Int(next.timeIntervalSince1970)
            if day == lastRunDay, let ended = lastRunEnded {
                let wait = Self.minimumGap - Date().timeIntervalSince(ended)
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            guard let dayStart = wanted, let repo else { break }
            wanted = nil
            await run(dayStart: dayStart, repo: repo)
            lastRunDay = Int(dayStart.timeIntervalSince1970)
            lastRunEnded = Date()
        }
        runner = nil
    }

    private func isShowing(_ day: Int) -> Bool { shownDay == day }

    private func run(dayStart: Date, repo: Repository) async {
        let day = Int(dayStart.timeIntervalSince1970)
        runToken += 1
        let token = runToken
        contextFinal = false
        statesBusy = true
        activityBusy = true
        defer {
            if isShowing(day), token == runToken {
                statesBusy = false
                activityBusy = false
                activityPartialReach = nil
            }
        }

        if dayStates.isEmpty || activityContext == nil {
            async let storedStates = repo.cachedDayStates(dayStart: dayStart)
            async let storedContext = repo.cachedActivityContext(dayStart: dayStart)
            let (states, context) = await (storedStates, storedContext)
            guard isShowing(day) else { return }
            if dayStates.isEmpty, let states {
                dayStates = states.segments
                statesReach = Date(timeIntervalSince1970: TimeInterval(states.dayEnd))
            }
            if activityContext == nil, let context { activityContext = context }
        }

        guard let streams = await repo.dayStreams(dayStart: dayStart) else {
            guard isShowing(day) else { return }
            dayStates = []
            statesReach = nil
            activityContext = nil
            return
        }
        guard isShowing(day) else { return }

        // Unstructured on purpose: if the wearer moves to another day, this run returns at once instead of
        // waiting for a decode whose result nobody wants.
        let strapStretches = Task { await repo.dayStateTimeline(from: streams) }
        let progress: @Sendable (ActivityContextDayDocument) -> Void = { [weak self] partial in
            Task { @MainActor in self?.accept(partial: partial, day: day, token: token) }
        }
        let decoded = Task { await repo.activityContext(from: streams, lane: .page, progress: progress) }

        let timeline = await strapStretches.value
        guard isShowing(day) else { return }
        dayStates = timeline
        statesReach = Date(timeIntervalSince1970: TimeInterval(streams.end))
        statesBusy = false
        repo.storeDayStates(timeline, from: streams)
        remember(day) { $0.states = timeline; $0.statesReach = streams.end }

        let context = await decoded.value
        guard isShowing(day) else { return }
        contextFinal = true
        activityPartialReach = nil
        if let context {
            activityContext = context
            remember(day) { $0.context = context }
        }
    }

    /// A partial decode of a day being read from scratch. Shown only while it reaches further than what is
    /// already on screen (a stored document that is merely out of date should not be replaced by a shorter one).
    private func accept(partial: ActivityContextDayDocument, day: Int, token: Int) {
        guard isShowing(day), token == runToken, !contextFinal else { return }
        let reach = partial.dataThrough ?? 0
        guard reach > (activityContext?.dataThrough ?? 0) else { return }
        activityContext = partial
        activityPartialReach = Date(timeIntervalSince1970: TimeInterval(reach))
    }
}

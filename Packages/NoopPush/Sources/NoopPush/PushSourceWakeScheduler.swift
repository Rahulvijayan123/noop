import Foundation

/// Coalesces source hints for one captured runtime/writer. Durable database debt remains the
/// authority across suspension and process death; a hint never waits for a periodic timer.
public actor PushSourceWakeScheduler<Key: Hashable & Sendable> {
    private struct Request: Sendable {
        let isCurrent: @Sendable () -> Bool
        let run: @Sendable () async -> Void
        let continueDurably: @Sendable () -> Void
    }
    private struct Pending {
        let id: UUID
        let task: Task<Void, Never>
        var trailing: Request?
    }
    private let clock: @Sendable () -> TimeInterval
    private var pending: [Key: Pending] = [:]
    private var completed: [Key: TimeInterval] = [:]

    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    /// At most two passes run per hint burst. Continuing ingress is retained as durable debt,
    /// preventing a hot source from keeping an application wake alive indefinitely.
    @discardableResult
    public func request(key: Key, sourceReady: Bool, interval: TimeInterval,
                        isCurrent: @escaping @Sendable () -> Bool,
                        run: @escaping @Sendable () async -> Void,
                        continueDurably: @escaping @Sendable () -> Void) -> Task<Void, Never>? {
        guard isCurrent() else { return nil }
        let request = Request(isCurrent: isCurrent, run: run, continueDurably: continueDurably)
        if var active = pending[key] {
            if sourceReady { active.trailing = request; pending[key] = active }
            return active.task
        }
        if !sourceReady, let last = completed[key], clock() - last < max(0, interval) { return nil }
        let id = UUID()
        let task = Task { await self.drain(request, key: key, id: id) }
        pending[key] = Pending(id: id, task: task)
        return task
    }

    private func drain(_ first: Request, key: Key, id: UUID) async {
        var request = first
        for pass in 0..<2 {
            guard !Task.isCancelled, request.isCurrent(), pending[key]?.id == id else { break }
            await request.run()
            guard !Task.isCancelled, request.isCurrent(), pending[key]?.id == id else { break }
            if pass == 0, let trailing = pending[key]?.trailing {
                pending[key]?.trailing = nil
                request = trailing
            } else { break }
        }
        guard pending[key]?.id == id else { return }
        pending.removeValue(forKey: key)
        // Only periodic polling uses this memory. It does not replace any durable cursor.
        if completed.count >= 64 { completed.removeAll(keepingCapacity: true) }
        completed[key] = clock()
        if request.isCurrent() { request.continueDurably() }
    }

    public func cancel(key: Key) {
        pending.removeValue(forKey: key)?.task.cancel()
        completed.removeValue(forKey: key)
    }

    public func resetThrottle() { completed.removeAll(keepingCapacity: true) }
}

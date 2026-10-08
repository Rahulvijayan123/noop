import Foundation
import WhoopStore

/// The last set of sleep blocks the Sleep tab loaded, so the night page opened from it renders at once
/// instead of re-reading every block on the push.
///
/// Presentation plumbing only. The Sleep tab still runs its own three loads in their own order
/// (`repo.allSleepSessions()`, `repo.habitualMidsleepSec()`, `repo.sessionMotions(sessions:)`) and only
/// records the result here; the night page reads it when it was taken at the same `refreshSeq` for the
/// same device, and otherwise runs the same three loads itself. A stale entry is never used: any sync,
/// import or edit bumps `refreshSeq`.
@MainActor
final class SleepSessionsCache {
    static let shared = SleepSessionsCache()

    struct Snapshot {
        let refreshSeq: Int
        let deviceId: String
        let sessions: [CachedSleepSession]
        let habitualMidsleepSec: Int?
        let motionByStart: [Int: [Double]]
    }

    private var latest: Snapshot?

    func record(_ snapshot: Snapshot) { latest = snapshot }

    /// The recorded snapshot when it is current for `refreshSeq` and `deviceId`, else nil.
    func snapshot(refreshSeq: Int, deviceId: String) -> Snapshot? {
        guard let latest, latest.refreshSeq == refreshSeq, latest.deviceId == deviceId else { return nil }
        return latest
    }
}

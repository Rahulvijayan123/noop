#if DEBUG && os(iOS)
import UIKit

/// DEBUG-only `--demo-tour`: walks the frontmost page from top to bottom one screenful at a time, so a host
/// script can `simctl io screenshot` every part of a long page without being able to scroll it.
///
/// The app and the host take turns through files in the app's Documents folder, which the simulator shares
/// with the Mac: the app writes `demo-tour/<n>.ready` once step n has settled, the host captures it and writes
/// `demo-tour/<n>.done`, and after the last step the app writes `demo-tour/finished`. `--demo-tour-delay S`
/// (default 8) is the wait before the first step, for the first load to land. `Tools/UITour/tour.sh` is the
/// host side.
@MainActor
enum DemoTour {
    static func startIfRequested() {
        guard CommandLine.arguments.contains("--demo-tour") else { return }
        Task { @MainActor in await run() }
    }

    private static func run() async {
        let fm = FileManager.default
        let dir = fm.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("demo-tour")
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try? await Task.sleep(nanoseconds: UInt64((DemoLaunch.doubleArg("--demo-tour-delay") ?? 8) * 1e9))

        for step in 0..<40 {
            fm.createFile(atPath: dir.appendingPathComponent("\(step).ready").path, contents: nil)
            // The host has 30 s to take its screenshot; a host that went away should not leave the app stuck.
            for _ in 0..<300 where !fm.fileExists(atPath: dir.appendingPathComponent("\(step).done").path) {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let scroll = frontmostScrollView() else { break }
            let maxY = scroll.contentSize.height + scroll.adjustedContentInset.bottom - scroll.bounds.height
            guard scroll.contentOffset.y < maxY - 2 else { break }
            // Overlap consecutive steps by a fifth of a screen so nothing falls between two captures.
            let next = min(maxY, scroll.contentOffset.y + scroll.bounds.height * 0.8)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: next), animated: false)
            try? await Task.sleep(nanoseconds: 1_200_000_000)
        }
        fm.createFile(atPath: dir.appendingPathComponent("finished").path, contents: nil)
    }

    /// The page's vertical scroll view: inside the topmost presented controller, at least most of the screen
    /// wide (which leaves out horizontal chart scrollers), and the largest such view on screen.
    private static func frontmostScrollView() -> UIScrollView? {
        let windows = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        guard let window = windows.first(where: \.isKeyWindow) ?? windows.first,
              var top = window.rootViewController else { return nil }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        var best: UIScrollView?
        var bestArea: CGFloat = 0
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            if let scroll = view as? UIScrollView, scroll.isScrollEnabled,
               scroll.bounds.width >= window.bounds.width * 0.8,
               scroll.contentSize.height > scroll.bounds.height + 4 {
                let frame = scroll.convert(scroll.bounds, to: window).intersection(window.bounds)
                let area = frame.isNull ? 0 : frame.width * frame.height
                if area > bestArea { best = scroll; bestArea = area }
            }
            view.subviews.forEach(visit)
        }
        visit(top.view)
        return best
    }
}
#endif

#if os(iOS)
import SwiftUI
import UIKit

/// Turns off the navigation controller's swipe-back gestures while the screen is on show.
///
/// The heart rate day page is built for horizontal finger work (hold to read the graph, drag along it).
/// With swipe-back live, a sideways drag started anywhere near the left side, or anywhere at all on
/// iOS 26's full-width back swipe, slides the whole screen across to reveal the one behind it. The back
/// button in the navigation bar still works, and so does re-tapping the tab.
struct PopGestureLock: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ uiViewController: Controller, context: Context) {}

    final class Controller: UIViewController {
        private var saved: [(recognizer: UIGestureRecognizer, wasEnabled: Bool)] = []

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            lock()
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            unlock()
        }

        private func lock() {
            guard saved.isEmpty else { return }
            NSLog("ZLOCK nav=%@", navigationController == nil ? "nil" : "found")
            guard let nav = navigationController else { return }
            var recognizers: [UIGestureRecognizer] = []
            if let edge = nav.interactivePopGestureRecognizer { recognizers.append(edge) }
            if #available(iOS 26.0, *), let content = nav.interactiveContentPopGestureRecognizer {
                recognizers.append(content)
            }
            saved = recognizers.map { ($0, $0.isEnabled) }
            for recognizer in recognizers { recognizer.isEnabled = false }
            NSLog("ZLOCK locked=%d", recognizers.count)
        }

        private func unlock() {
            for entry in saved { entry.recognizer.isEnabled = entry.wasEnabled }
            saved = []
        }
    }
}
#endif

#if os(iOS)
import SwiftUI
import UIKit

/// A transparent touch surface for scrubbing a chart sideways inside a vertically scrolling page.
///
/// A SwiftUI `DragGesture` on a chart claims every touch that lands on it, so a finger that starts a
/// scroll on the chart moves the chart's readout and not the page. Delaying the drag behind a long press
/// only narrows the window: a swipe that starts slowly still ends up inside the gesture.
///
/// This decides by direction instead. It is a pan recogniser that declines to begin unless the finger is
/// moving more sideways than up or down, so a vertical swipe never belongs to it and the enclosing scroll
/// view receives it untouched, from the first point. A sideways drag scrubs.
struct HorizontalScrubSurface: UIViewRepresentable {
    /// Called with the finger's x position, in this surface's own coordinate space, while scrubbing.
    var onScrub: (CGFloat) -> Void
    /// Called when the finger lifts or the system takes the touch away.
    var onEnd: () -> Void
    /// Called with the x position of a single tap; nil leaves taps to the views underneath (the default).
    var onTap: ((CGFloat) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        if onTap != nil {
            let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
            view.addGestureRecognizer(tap)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onScrub = onScrub
        context.coordinator.onEnd = onEnd
        context.coordinator.onTap = onTap
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onScrub: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onTap: ((CGFloat) -> Void)?

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onTap?(recognizer.location(in: recognizer.view).x)
        }

        @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                onScrub(recognizer.location(in: recognizer.view).x)
            case .ended, .cancelled, .failed:
                onEnd()
            default:
                break
            }
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            return Self.isSideways(pan.velocity(in: pan.view), fallback: pan.translation(in: pan.view))
        }

        /// A pan is sideways when its horizontal component dominates. Velocity is the better signal, but it
        /// can be zero on the first callback of a slow drag, so the distance moved so far decides then.
        static func isSideways(_ velocity: CGPoint, fallback translation: CGPoint) -> Bool {
            if velocity != .zero { return abs(velocity.x) > abs(velocity.y) }
            return abs(translation.x) > abs(translation.y)
        }
    }
}
#endif

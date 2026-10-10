#if canImport(UIKit) && os(iOS)
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
/// view receives it untouched, from the first point. A sideways drag scrubs. An optional tap reports where
/// the finger lifted without moving, which the chart kit uses to pin a selection.
///
/// Place it over the plot in a `chartOverlay`'s `GeometryReader`; the x positions it reports are in its
/// own coordinate space, which is the reader's.
///
/// ```swift
/// .chartOverlay { proxy in
///     GeometryReader { geo in
///         HorizontalScrubSurface(onScrub: { select(x: $0) }, onEnd: { selection = nil })
///     }
/// }
/// ```
public struct HorizontalScrubSurface: UIViewRepresentable {
    /// Whether any scrub surface is scrubbing now, or stopped within `settle` seconds. An ancestor
    /// sideways gesture (the tab bar's swipe-between-tabs) recognises alongside the scrub, so it must check
    /// this and stand down rather than switching tabs at the end of a scrub.
    @MainActor public static func isScrubbing(settle: TimeInterval = 0.35) -> Bool {
        activeScrubs > 0 || Date().timeIntervalSince(lastScrubEnd) < settle
    }

    @MainActor static var activeScrubs = 0
    @MainActor static var lastScrubEnd = Date.distantPast

    /// For a surface that handles its own sideways drags (a web view's sliders, say) without this view: call
    /// `beginScrub` when a finger goes down on it and `endScrub` exactly once when that finger lifts.
    @MainActor public static func beginScrub() { activeScrubs += 1 }
    @MainActor public static func endScrub() {
        activeScrubs = max(0, activeScrubs - 1)
        lastScrubEnd = Date()
    }

    /// Called with the finger's x position, in this surface's own coordinate space, while scrubbing.
    public var onScrub: (CGFloat) -> Void
    /// Called when the finger lifts or the system takes the touch away.
    public var onEnd: () -> Void
    /// Called with the x position of a tap. Nil leaves taps to whatever sits underneath.
    public var onTap: ((CGFloat) -> Void)?

    public init(onScrub: @escaping (CGFloat) -> Void,
                onEnd: @escaping () -> Void,
                onTap: ((CGFloat) -> Void)? = nil) {
        self.onScrub = onScrub
        self.onEnd = onEnd
        self.onTap = onTap
    }

    public func makeCoordinator() -> Coordinator { Coordinator() }

    public func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        let pan = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.pan(_:)))
        pan.delegate = context.coordinator
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        context.coordinator.tapRecognizer = tap
        return view
    }

    public func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onScrub = onScrub
        context.coordinator.onEnd = onEnd
        context.coordinator.onTap = onTap
    }

    public final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onScrub: (CGFloat) -> Void = { _ in }
        var onEnd: () -> Void = {}
        var onTap: ((CGFloat) -> Void)?
        weak var tapRecognizer: UITapGestureRecognizer?

        @MainActor @objc func pan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began:
                HorizontalScrubSurface.activeScrubs += 1
                onScrub(recognizer.location(in: recognizer.view).x)
            case .changed:
                onScrub(recognizer.location(in: recognizer.view).x)
            case .ended, .cancelled, .failed:
                HorizontalScrubSurface.activeScrubs = max(0, HorizontalScrubSurface.activeScrubs - 1)
                HorizontalScrubSurface.lastScrubEnd = Date()
                onEnd()
            default:
                break
            }
        }

        @objc func tap(_ recognizer: UITapGestureRecognizer) {
            guard recognizer.state == .ended else { return }
            onTap?(recognizer.location(in: recognizer.view).x)
        }

        public func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            if gestureRecognizer === tapRecognizer { return onTap != nil }
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return true }
            return Self.isSideways(pan.velocity(in: pan.view), fallback: pan.translation(in: pan.view))
        }

        /// A pan is sideways when its horizontal component dominates. Velocity is the better signal, but it
        /// can be zero on the first callback of a slow drag, so the distance moved so far decides then.
        public static func isSideways(_ velocity: CGPoint, fallback translation: CGPoint) -> Bool {
            if velocity != .zero { return abs(velocity.x) > abs(velocity.y) }
            return abs(translation.x) > abs(translation.y)
        }
    }
}
#endif

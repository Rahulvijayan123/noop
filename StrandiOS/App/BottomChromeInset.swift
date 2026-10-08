import SwiftUI

// How much room the floating glass tab bar (and the running-workout bar above it) takes at the bottom of the
// tab content. With Liquid Glass on the platform bar is hidden and `RootTabView` draws its own bar in a
// bottom safe-area inset, but that inset does not reach the tab roots: a screen that pins something to the
// bottom (the Sana composer) would sit underneath the bar. `RootTabView` measures the bar and hands the height
// down here; it is 0 whenever no glass bar is on screen (glass off, or the keyboard is up and the bar steps
// aside). Scrolling screens already leave their own room at the end of the scroll content.

private struct NoopBottomChromeInsetKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    var noopBottomChromeInset: CGFloat {
        get { self[NoopBottomChromeInsetKey.self] }
        set { self[NoopBottomChromeInsetKey.self] = newValue }
    }
}

struct NoopBottomChromeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

extension View {
    /// Reports this view's height through `NoopBottomChromeHeightKey`.
    func reportsBottomChromeHeight() -> some View {
        background {
            GeometryReader { geo in
                Color.clear.preference(key: NoopBottomChromeHeightKey.self, value: geo.size.height)
            }
        }
    }
}

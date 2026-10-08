//  LiquidSky.swift
//  Nara · the scaffold backdrop.
//
//  What is left of the time-of-day sky: the screens that still pass `liquidScaffoldSky()` to
//  `ScreenScaffold(topBackground:)` get the flat canvas. The animated sky (`LiquidSky`), its static twin
//  and the starfield had no call site left and were removed with their test (`LiquidSkyMotionTests`).

import SwiftUI
import StrandDesign

/// The backdrop every `ScreenScaffold` that passes `liquidScaffoldSky()` gets: the flat canvas and nothing
/// else.
///
/// This used to paint the time-of-day sky (or a picked photo) behind the page. The design system now puts
/// every screen on the plain `StrandPalette.surfaceBase` (docs/DESIGN_SYSTEM.md, Canvas and surfaces), so
/// the view draws only that. It stays a view, and the call sites stay as they are, so the screens that pass
/// it need no change. The preference keys it used to read (`SceneBackgroundPrefs`, `SkyBehindCardsPrefs`,
/// the background-image store) are kept where they are defined for backups and Android parity; nothing
/// reads them here any more.
struct LiquidScaffoldSky: View {
    var height: CGFloat = 240

    var body: some View {
        StrandPalette.surfaceBase
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

func liquidScaffoldSky(height: CGFloat = 240) -> AnyView {
    AnyView(LiquidScaffoldSky(height: height))
}

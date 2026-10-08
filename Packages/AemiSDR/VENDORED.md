# AemiSDR (vendored)

Source: https://github.com/Aemi-Studio/AemiSDR at commit `56bd2ed5834ec777c6cb6b7af6f896a587b20c23`.
Licensed by Aemi Studio under either the MIT License (`LICENSE-MIT`) or the Mozilla Public License 2.0
(`LICENSE`), at your option. The files keep those terms; they are not covered by NOOP's own license.

The app uses it for the Liquid Glass look (`Packages/StrandDesign/Sources/StrandDesign/NoopLiquidGlass.swift`):
`BackdropBlurView` behind cards, chrome and controls, and the `liquidBackground` Metal lens on the floating
controls and the tab bar. StrandDesign links it on iOS only.

## Differences from upstream

- **No `aemi` dependency.** `Internal/_InternedKeys.swift` declared its keys with `@Interned` from the
  `InternedStrings` product; they are plain `static let` strings here. Nothing else in the sources changed.
- **No shader build plugin.** Upstream compiles `Sources/AemiSDR/Shaders/*.metal` with its own
  `MetalShaderBuildPlugin` on every build, which needs the plugin trust prompt and the Metal toolchain on each
  machine. Here the shaders are excluded from the target and their compiled libraries are checked in under
  `Sources/AemiSDR/Resources/` (`AemiSDR.*.metallib`, `LiquidLens.*.metallib`, one per iOS, iOS Simulator and
  macOS), with the same file names and flags the plugin produces, so the runtime loader is unchanged.
- **Tools version 6.2** instead of 6.3, so it builds with the Xcode the project pins.
- **Platform minimums iOS 16 / macOS 13** (upstream: iOS 18 / macOS 15), matching StrandDesign. The sources
  compile against those targets without availability errors.
- **`Previews/` removed**, along with upstream's `Examples/`, `Tests/` and `Plugins/`.

## Updating

1. Copy `Sources/AemiSDR` from the new upstream commit over this one, keeping `Resources/` and dropping
   `Previews/`.
2. Re-apply the `_InternedKeys.swift` change above.
3. If any `.metal` file changed, run `Tools/compile-shaders.sh` (needs the Metal toolchain:
   `xcodebuild -downloadComponent MetalToolchain`) and commit the regenerated metallibs.
4. Update the commit hash here and in `Package.swift`.

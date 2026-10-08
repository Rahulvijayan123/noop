import SwiftUI

// MARK: - Liquid Glass search field and control chrome
//
// Shared search chrome for every in-app filter/search bar, and the glass chrome helpers for header and
// workout controls. With the Liquid Glass setting on, all of them draw AemiSDR glass (`noopGlassControl`,
// `NoopGlassButtonStyle`) at the chosen intensity on every iOS version. With it at 0 they keep their
// original rendering: the platform `glassEffect` on iOS 26, a solid elevated pill elsewhere. macOS never
// enables the setting. Clear control, magnifying-glass glyph, and accessibility wiring stay identical
// across call sites.

/// Full-width rounded search field in Liquid Glass.
public struct NoopLiquidGlassSearchField: View {
    @Binding private var text: String
    private let prompt: String
    private let accessibilityPrompt: String
    private var externalFocus: FocusState<Bool>.Binding?
    @FocusState private var internalFocus: Bool

    public init(text: Binding<String>,
                prompt: String,
                accessibilityLabel: String? = nil,
                isFocused: FocusState<Bool>.Binding? = nil) {
        self._text = text
        self.prompt = prompt
        self.accessibilityPrompt = accessibilityLabel ?? prompt
        self.externalFocus = isFocused
    }

    public var body: some View {
        HStack(spacing: NoopMetrics.space2) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityHidden(true)
            TextField(prompt, text: $text)
                .textFieldStyle(.plain)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .focused(focusBinding)
                .submitLabel(.search)
                #if os(iOS)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                #endif
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Clear search"))
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space3)
        .nativeLiquidGlassSearchChrome()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(accessibilityPrompt))
    }

    private var focusBinding: FocusState<Bool>.Binding {
        externalFocus ?? $internalFocus
    }
}

public extension View {
    /// Capsule Liquid Glass search chrome. The search field sits in scrolling content, so its glass is a
    /// blur without the Metal lens.
    func nativeLiquidGlassSearchChrome() -> some View {
        LiquidGlassSwitch {
            self.noopGlassControl(in: Capsule(style: .continuous), refraction: false)
        } original: {
            self.originalLiquidGlassSearchChrome()
        }
    }

    /// Circular / capsule Liquid Glass button chrome (Home header, live-workout controls,
    /// workout-selection close/chips). With the setting at 0, iOS 26 keeps the platform `.glass` style and
    /// every other platform keeps the caller's `fallback` (standard material / press style) unchanged.
    func nativeLiquidGlassButtonChrome<Fallback: View>(
        controlSize: ControlSize = .small,
        capsule: Bool = false,
        @ViewBuilder fallback: () -> Fallback
    ) -> some View {
        let original = fallback()
        return LiquidGlassSwitch {
            if capsule {
                self.buttonStyle(NoopGlassButtonStyle(shape: Capsule(style: .continuous), controlSize: controlSize))
            } else {
                self.buttonStyle(NoopGlassButtonStyle(shape: Circle(), controlSize: controlSize))
            }
        } original: {
            self.originalLiquidGlassButtonChrome(controlSize: controlSize, capsule: capsule, fallback: original)
        }
    }

    /// Circular glass finish layer (e.g. Home profile photo over glass): the rim and sheen drawn over the
    /// composed control so the photo still reads as a piece of glass. No-op with the setting at 0 outside
    /// iOS 26.
    func nativeLiquidGlassCircleFinish() -> some View {
        LiquidGlassSwitch {
            self.modifier(LiquidGlassCircleFinish())
        } original: {
            self.originalLiquidGlassCircleFinish()
        }
    }
}

private struct LiquidGlassCircleFinish: ViewModifier {
    @Environment(\.liquidGlass) private var level

    func body(content: Content) -> some View {
        content.overlay {
            LiquidGlassHighlights(shape: Circle(), level: level)
        }
    }
}

private extension View {
    @ViewBuilder
    func originalLiquidGlassSearchChrome() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Capsule())
        } else {
            self.noopStandardSearchChrome()
        }
        #else
        self.noopStandardSearchChrome()
        #endif
    }

    @ViewBuilder
    func originalLiquidGlassButtonChrome<Fallback: View>(
        controlSize: ControlSize,
        capsule: Bool,
        fallback: Fallback
    ) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
                .buttonStyle(.glass)
                .buttonBorderShape(capsule ? .capsule : .circle)
                .controlSize(controlSize)
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    @ViewBuilder
    func originalLiquidGlassCircleFinish() -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self
        }
        #else
        self
        #endif
    }

    func noopStandardSearchChrome() -> some View {
        self.background(
            NoopPanelSurface(cornerRadius: NoopVisualStyle.pillRadius, elevated: false)
        )
    }
}

//
//  _InternedKeys.swift
//  AemiSDR
//

/// Centralized storage for the private runtime names used across the framework.
package enum _InternedKeys {
    // MARK: - Filter Identifiers

    static let caLayerFilterClass = "CAFilter"
    static let filterCreationSelector = "filterWithType:"
    static let blurFilterID = "gaussianBlur"
    static let compositeFilterID = "sourceOver"
    static let saturateFilterID = "colorSaturate"
    static let brightnessFilterID = "colorBrightness"

    // MARK: - Filter Parameters

    static let radiusParam = "inputRadius"
    static let normalizeParam = "inputNormalizeEdges"
    static let maskParam = "inputMaskImage"
    static let amountParam = "inputAmount"

    // MARK: - Key Paths

    static let filterListKey = "filters"
    static let kindKey = "filterType"
    static let kindFallbackA = "type"
    static let kindFallbackB = "name"
    static let scaleFactorKey = "scale"
    static let tintColorKey = "colorTint"
    static let tintAlphaKey = "colorTintAlpha"
    static let radiusValueKey = "blurRadius"
    static let saturationKey = "saturationDeltaFactor"
    static let grayLevelKey = "grayscaleTintLevel"
    static let grayAlphaKey = "grayscaleTintAlpha"
    static let burnLevelKey = "colorBurnTintLevel"
    static let burnAlphaKey = "colorBurnTintAlpha"
    static let darkAlphaKey = "darkeningTintAlpha"
    static let darkHueKey = "darkeningTintHue"
    static let darkSatKey = "darkeningTintSaturation"
    static let zoomKey = "zoom"
    static let lightenGrayFlag = "lightenGrayscaleWithSourceOver"
    static let darkenCompFlag = "darkenWithSourceOver"

    // MARK: - iOS-Only Keys

    #if os(iOS)
        static let maskedBlurFilterID = "variableBlur"

        // Effect View Classes
        static let customBlurEffectClass = "_UICustomBlurEffect"
        static let backdropViewClass = "_UIVisualEffectBackdropView"
        static let overlaySubviewClass = "_UIVisualEffectSubview"

        // Key Paths
        static let effectsListKey = "viewEffects"
        static let pendingValuesKey = "requestedValues"
        static let scaleHintKey = "requestedScaleHint"
        static let colorKey = "color"

        // Backdrop Settings
        static let backdropViewSettingsClass = "_UIBackdropViewSettings"
        static let settingsCreationSelector = "settingsForStyle:"
        static let grayTintEnabledKey = "usesGrayscaleTintView"
        static let tintEnabledKey = "usesColorTintView"
        static let burnTintEnabledKey = "usesColorBurnTintView"

        // Selectors
        static let applyEffectSelector = "applyRequestedEffectToView:"
        static let commitFiltersSelector = "applyRequestedFilterEffects"

        // Private UIKit Properties
        static let screenCornerRadiusKey = "_displayCornerRadius"

        // CABackdropLayer (private API — capture composited content behind a view)
        static let backdropLayerClass = "CABackdropLayer"
        static let backdropGroupNameKey = "groupName"

        // Legacy keys (removed in iOS 26)
        static let coreImageFiltersKey = "layerUsesCoreImageFilters"
        static let windowServerAwareKey = "windowServerAware"

        // iOS 26+ CABackdropLayer keys
        static let backdropEnabledKey = "enabled"
        static let backdropCaptureOnlyKey = "captureOnly"
        static let backdropDisablesOccludedKey = "disablesOccludedBackdropBlurs"
        static let backdropReducesBitDepthKey = "reducesCaptureBitDepth"
        static let backdropAllowsInPlaceKey = "allowsInPlaceFiltering"
        static let backdropRectKey = "backdropRect"
        static let backdropUpdateRateKey = "updateRate"
    #endif

    // MARK: - macOS-Only Keys

    #if os(macOS)
        static let backdropLayerRef = "_backdropLayer"
        static let backdropLayerClassName = "CABackdropLayer"
    #endif
}

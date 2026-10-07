import SwiftUI
import CoreText
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

// MARK: - Strand Typography — the Nara type system
//
// SF Pro throughout, in three weights only (Regular, Medium, Semibold), sentence case. Every role
// scales with Dynamic Type: named roles are anchored to a system text style, and fixed-size numerals
// are scaled through `UIFontMetrics` so a metric grows with the text around it.
//
//   Hero metric        36–42 Medium      `display(_:)`, and any `number`/`rounded` ≥ 34pt
//   Page title         28 Semibold       `title1`
//   Section title      20 Semibold       `title2`
//   Card title         16 Semibold       `headline`
//   Body               16 Regular        `body`
//   Secondary / label  14 Regular        `subhead` (the Label role: `Text.strandLabel()`)
//   Compact label      13 Medium         `overline` (older; not used on content screens)
//   Metadata / charts  11–12             `caption`, `footnote`, `captionNumber`, `axis`
//   Symbols            by text style     `icon(_:)`
//
// Metric numerals never exceed `heroMaxSize`: an oversized score implies more precision than a
// wearable estimate has. All numeric styles use `.monospacedDigit()` so live values never reflow.
//
// Söhne is the optional brand face for onboarding and hero moments only (`brandDisplay(_:)`). It is a
// licensed font and is not checked in: drop the Söhne .otf/.ttf files into the app bundle and they are
// registered on first use; without them `brandDisplay` falls back to SF Pro.

public enum StrandFont {

    /// The largest point size any metric numeral renders at, before Dynamic Type.
    public static let heroMaxSize: CGFloat = 42

    // MARK: Weight + size policy

    /// Collapse any requested weight onto the three the system allows.
    static func allowed(_ weight: Font.Weight) -> Font.Weight {
        switch weight {
        case .ultraLight, .thin, .light, .regular: return .regular
        case .medium: return .medium
        default: return .semibold
        }
    }

    /// Numerals at hero size are Medium; smaller numerals keep their (allowed) weight.
    static func numeralWeight(_ size: CGFloat, _ weight: Font.Weight) -> Font.Weight {
        size >= 34 ? .medium : allowed(weight)
    }

    // MARK: Scaled fixed-size fonts

    #if canImport(UIKit)
    private struct ScaledKey: Hashable {
        let size: CGFloat, weight: Int, style: String, probe: CGFloat
    }
    private static var scaledCache: [ScaledKey: Font] = [:]
    private static let scaledLock = NSLock()

    private static func uiWeight(_ weight: Font.Weight) -> (UIFont.Weight, Int) {
        switch allowed(weight) {
        case .regular: return (.regular, 0)
        case .medium: return (.medium, 1)
        default: return (.semibold, 2)
        }
    }
    #endif

    /// SF Pro at an exact point size that still follows Dynamic Type, relative to `style`. Hero sizes
    /// are held to a smaller growth ceiling so ring and gauge centres keep their geometry.
    static func scaled(_ size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) -> Font {
        #if canImport(UIKit)
        let metrics = UIFontMetrics(forTextStyle: uiTextStyle(style))
        let (w, wKey) = uiWeight(weight)
        let key = ScaledKey(size: size, weight: wKey, style: "\(style)", probe: metrics.scaledValue(for: 100))
        scaledLock.lock()
        if let hit = scaledCache[key] { scaledLock.unlock(); return hit }
        scaledLock.unlock()
        let ceiling = size * (size >= 28 ? 1.3 : 1.8)
        let font = Font(metrics.scaledFont(for: UIFont.systemFont(ofSize: size, weight: w), maximumPointSize: ceiling))
        scaledLock.lock()
        if scaledCache.count > 256 { scaledCache.removeAll(keepingCapacity: true) }
        scaledCache[key] = font
        scaledLock.unlock()
        return font
        #else
        return .system(size: size, weight: allowed(weight))
        #endif
    }

    #if canImport(UIKit)
    private static func uiTextStyle(_ style: Font.TextStyle) -> UIFont.TextStyle {
        switch style {
        case .largeTitle: return .largeTitle
        case .title: return .title1
        case .title2: return .title2
        case .title3: return .title3
        case .headline: return .headline
        case .callout: return .callout
        case .subheadline: return .subheadline
        case .footnote: return .footnote
        case .caption: return .caption1
        case .caption2: return .caption2
        default: return .body
        }
    }
    #endif

    /// The text style a numeral of `size` should grow alongside.
    private static func anchorStyle(_ size: CGFloat) -> Font.TextStyle {
        switch size {
        case 30...: return .largeTitle
        case 24..<30: return .title
        case 19..<24: return .title3
        case 15..<19: return .body
        case 13..<15: return .subheadline
        default: return .caption
        }
    }

    // MARK: Numerals

    /// The hero metric numeral (36–42 Medium). Any requested size is capped at `heroMaxSize`.
    public static func display(_ size: CGFloat = 40) -> Font {
        let s = min(size, heroMaxSize)
        return scaled(s, weight: .medium, relativeTo: .largeTitle).monospacedDigit()
    }

    /// Tracking for display numerals. SF Pro's optical sizing already tightens large figures, so this
    /// is a whisper rather than the old -0.04em.
    public static func displayTracking(_ size: CGFloat = 40) -> CGFloat {
        -min(size, heroMaxSize) * 0.01
    }

    /// A numeral at an arbitrary size. The name predates the switch to SF Pro; the face is no longer
    /// rounded. Capped at `heroMaxSize`, Medium at hero sizes, tabular digits.
    public static func rounded(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        number(size, weight: weight)
    }

    /// A numeric style at an arbitrary size/weight, for live values. Capped at `heroMaxSize`, Medium at
    /// hero sizes, tabular digits, Dynamic Type aware.
    public static func number(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        let s = min(size, heroMaxSize)
        return scaled(s, weight: numeralWeight(s, weight), relativeTo: anchorStyle(s)).monospacedDigit()
    }

    /// Inline live value beside body text (16 Medium, tabular).
    public static let bodyNumber = Font.system(.callout, weight: .medium).monospacedDigit()

    /// Small live value — chips, chart readouts (12 Medium, tabular).
    public static let captionNumber = Font.system(.caption, weight: .medium).monospacedDigit()

    // MARK: Text roles

    /// Page title — 28 Semibold.
    public static let title1 = Font.system(.title, weight: .semibold)

    /// Section title — 20 Semibold.
    public static let title2 = Font.system(.title3, weight: .semibold)

    /// Card title — 16 Semibold.
    public static let headline = Font.system(.callout, weight: .semibold)

    /// Body — 16 Regular.
    public static let body = Font.system(.callout, weight: .regular)

    /// Secondary text — 14 Regular.
    public static var subhead: Font { scaled(14, weight: .regular, relativeTo: .subheadline) }

    /// Metadata — 12 Regular.
    public static let caption = Font.system(.caption, weight: .regular)

    /// Metadata and chart labels — 12 Regular, anchored to the footnote style.
    public static var footnote: Font { scaled(12, weight: .regular, relativeTo: .footnote) }

    /// A quiet sentence-case label above a value or group — 13 Medium. Also the face for compact status
    /// copy in constrained chrome (the Today header's sync capsule).
    public static var overline: Font { scaled(13, weight: .medium, relativeTo: .footnote) }

    /// `overline` at a custom size for tight containers, floored at the 11pt metadata minimum.
    public static func overlineScaled(_ size: CGFloat) -> Font {
        scaled(max(size, 11), weight: .medium, relativeTo: .caption2)
    }

    /// Chart tick labels: the metadata size (12 Regular, anchored to footnote) with tabular digits, so
    /// a column of y-axis values stays right-aligned and the x labels do not shift while scrubbing.
    public static var axis: Font { footnote.monospacedDigit() }

    /// Where an SF Symbol sits, which decides the size it renders at. Each role follows a system text
    /// style, so icons grow with Dynamic Type alongside the text beside them (a fixed `.system(size:)`
    /// does not).
    public enum IconRole: Sendable {
        /// Inside a line of metadata or a chip (the trend arrow, a source glyph): ~11 pt.
        case inline
        /// Beside a tile or stat label (the `MetricTile` icon): ~13 pt.
        case tile
        /// The leading icon of a list row, a chevron, a header button: ~17 pt.
        case row
        /// A large symbol standing on its own (an empty state, a hero): ~28 pt.
        case hero
    }

    /// The symbol font for `role`.
    public static func icon(_ role: IconRole) -> Font {
        switch role {
        case .inline: return .system(.caption2, weight: .semibold)
        case .tile:   return .system(.footnote, weight: .medium)
        case .row:    return .system(.body, weight: .regular)
        case .hero:   return .system(.title, weight: .regular)
        }
    }

    /// Mono 13 (SF Mono) — raw / log views only.
    public static let mono = Font.system(size: 13, weight: .regular, design: .monospaced)

    /// Mono at an arbitrary size.
    public static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: allowed(weight), design: .monospaced)
    }

    /// Sentence-case labels are not letter-spaced. Kept so existing `.tracking(overlineTracking)` call
    /// sites resolve to no tracking.
    public static let overlineTracking: CGFloat = 0

    // MARK: Brand display (Söhne, optional)

    /// Söhne for onboarding and major hero moments only — never for metrics or body copy. Falls back
    /// to SF Pro at the same size and weight when the licensed font files are not bundled.
    public static func brandDisplay(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        if let name = BrandFonts.soehnePostScriptName(for: allowed(weight)) {
            return .custom(name, size: size, relativeTo: .largeTitle)
        }
        return scaled(size, weight: weight, relativeTo: .largeTitle)
    }
}

// MARK: - Söhne registration

enum BrandFonts {
    /// Klim's PostScript names for the three allowed weights (Buch, Kräftig, Halbfett).
    private static let names: [Font.Weight: String] = [
        .regular: "Soehne-Buch", .medium: "Soehne-Kraftig", .semibold: "Soehne-Halbfett",
    ]

    /// Registers any Söhne files shipped in the main bundle, once per process.
    private static let registered: Bool = {
        let urls = ["otf", "ttf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
            .filter { $0.lastPathComponent.lowercased().hasPrefix("soehne") || $0.lastPathComponent.lowercased().hasPrefix("söhne") }
        guard !urls.isEmpty else { return false }
        CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
        return true
    }()

    static func soehnePostScriptName(for weight: Font.Weight) -> String? {
        guard registered, let name = names[weight] else { return nil }
        #if canImport(UIKit)
        return UIFont(name: name, size: 12) != nil ? name : nil
        #elseif canImport(AppKit)
        return NSFont(name: name, size: 12) != nil ? name : nil
        #else
        return nil
        #endif
    }
}

// MARK: - Text helpers

public extension String {
    /// First letter upper-cased, the rest lower-cased, in the current locale: "RECOVERY VITALS" →
    /// "Recovery vitals". For catalog strings whose keys are still upper-case.
    var sentenceCased: String {
        let lower = lowercased(with: .current)
        guard let first = lower.first else { return lower }
        return String(first).uppercased(with: .current) + lower.dropFirst()
    }
}

public extension Text {
    /// A quiet sentence-case label: 13 Medium in secondary ink. (The name predates the switch away
    /// from ALL-CAPS overlines.)
    func strandOverline() -> some View {
        self.font(StrandFont.overline)
            .foregroundStyle(StrandPalette.textSecondary)
    }

    /// The Label role (docs/DESIGN_SYSTEM.md, Type): `subhead` in `textSecondary`, for the name above or
    /// beside a value (a tile label, a stat label). Replaces `strandOverline()` on content screens.
    func strandLabel() -> some View {
        self.font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
    }
}

public extension View {
    /// Convenience: a label-styled string.
    static func strandOverline(_ string: String) -> some View {
        Text(string).strandOverline()
    }
}

#if DEBUG
#Preview("Typography") {
    ScrollView {
        VStack(alignment: .leading, spacing: 18) {
            Text("Welcome to Nara").font(StrandFont.brandDisplay(34)).foregroundStyle(StrandPalette.textPrimary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("62").font(StrandFont.display(40)).foregroundStyle(StrandPalette.textPrimary)
                Text("ms · 4 above your baseline").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            }
            Text("Page title").font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
            Text("Section title").font(StrandFont.title2).foregroundStyle(StrandPalette.textPrimary)
            Text("Card title").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Body copy reads quietly and credibly, in sentence case.")
                .font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            Text("Secondary text").font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
            Text("Recovery vitals").strandOverline()
            Text("Metadata · chart label").font(StrandFont.footnote).foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(width: 420, height: 620)
    .background(StrandPalette.surfaceBase)
}
#endif

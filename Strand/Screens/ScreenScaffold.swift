import SwiftUI
import StrandDesign

/// How a page shows its title (docs/DESIGN_SYSTEM.md, Detail pages).
enum ScreenTitleDisplay {
    /// Tab roots: the `title1` header at the top of the content column.
    case header
    /// Pushed pages: the title goes in the navigation bar, inline, and the column starts with content, so
    /// the title appears once. iOS only; the Mac keeps the in-content header, because its sidebar panes
    /// have no inline bar to carry it.
    case navigationBar
}

/// Standard scrollable screen container: title + flat canvas + content column.
///
/// ```swift
/// // A tab root:
/// ScreenScaffold(title: "Sleep", onRefresh: { await repo.refresh() }) { … }
/// // A pushed page: title in the nav bar, the real layout redacted until the data lands.
/// ScreenScaffold(title: "Heart rate variability", titleDisplay: .navigationBar, isLoading: !loaded) { … }
/// // A page whose subtitle is data (a date or span), never a tagline:
/// ScreenScaffold(title: "Run", dateLine: startDate.formatted(date: .abbreviated, time: .shortened)) { … }
/// ```
struct ScreenScaffold<Content: View, Trailing: View>: View {
    /// Optional — when nil (and no subtitle) the header is omitted entirely, so a screen can supply its
    /// own custom header in `content` (iOS Today's compact top bar).
    let title: LocalizedStringKey?
    /// The older subtitle slot. Kept so every call site compiles; it should only ever carry data (a date or
    /// a span), never a tagline. New pages pass `dateLine`. When both are given, `dateLine` wins.
    var subtitle: LocalizedStringKey? = nil
    /// The data-only line under the title: a date, a span ("Since 12 Mar"), a count. Drawn verbatim.
    var dateLine: String? = nil
    /// `.header` (tab roots, the default) or `.navigationBar` (pushed pages).
    var titleDisplay: ScreenTitleDisplay = .header
    /// Renders the content column's real layout redacted, with taps off and one "Loading" element for
    /// VoiceOver, so the page does not move when the data arrives. The header stays readable and live.
    var isLoading: Bool = false
    /// Optional pull-to-refresh hook. When set, the scroll view becomes `.refreshable`
    /// (the standard iPhone gesture for a data dashboard). Defaults to nil so callers that
    /// don't opt in are unaffected — and on macOS `.refreshable` surfaces no affordance.
    var onRefresh: (() async -> Void)? = nil
    /// Lazily materialise the content column. When `true` the inner stack is a `LazyVStack`,
    /// so a screen whose content ends in a long `ForEach` only builds the cards on screen
    /// rather than all of them up-front — the fix for Intelligence "ALL" freezing on an
    /// 800+ day imported history (#345). Defaults to `false` so every existing caller keeps
    /// the eager `VStack` and its identical layout/scroll behaviour.
    var lazy: Bool = false
    /// Pins the content to exactly the width of the screen. `.basedOnSize` (#697) allows a horizontal bounce
    /// as soon as the content overflows at all, and SwiftUI has no way to switch that bounce off, so a page
    /// whose content can run a fraction of a point wider than the screen slides sideways under a drag. With
    /// the width pinned there is no overflow to bounce on. Defaults to `false`: every other screen is
    /// unchanged.
    var lockHorizontalScroll: Bool = false
    /// Optional full-bleed view drawn behind the scroll content at the TOP of the screen. Pages sit on the
    /// flat canvas (docs/DESIGN_SYSTEM.md, Canvas and surfaces), so new pages leave this nil; it is kept for
    /// the remaining callers until they drop it. nil renders nothing.
    var topBackground: AnyView? = nil
    /// Optional element pinned to the header's trailing edge (e.g. the strap-battery badge on Today).
    /// Defaults to `EmptyView` via the convenience init below, so other screens are unaffected.
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    // iPad runs the shared screens full-screen, where an uncapped column gives 120+ character lines
    // in landscape. On iOS regular width (iPad) the readable column is capped + centred; compact
    // (iPhone) and macOS are unchanged. macOS also reports a horizontalSizeClass, so the cap is gated
    // by `#if os(iOS)` — a runtime size-class check alone would also narrow the Mac detail pane.
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var hSizeClass
    #endif

    /// Bumped (via the environment) when the iOS tab shell wants THIS screen scrolled to the top — an
    /// at-root re-tap of the active tab (#198 follow-up). Default 0 never changes, so macOS and every
    /// non-tab screen keep their exact prior scroll behaviour.
    @Environment(\.scrollToTopSignal) private var scrollToTopSignal

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            // Scroll-to-top anchor (#198 follow-up): a zero-height marker pinned above the content so an
            // at-root tab re-tap can bring the screen back to the very top. Layout-neutral.
            Color.clear.frame(height: 0).id(screenScaffoldTopAnchorID)
            column
            #if os(iOS)
            // Unified side margins matching the floating navigation bar so every page's cards + header line up
            // to the same edges (2026-07-02); macOS keeps its wider desktop margin in the #else branch.
            .padding(.horizontal, NoopMetrics.screenHPadding)
            .padding(.top, NoopMetrics.space6)
            // The tab bar floats over the scroll content, so the last card sat hidden behind it.
            // Reserve extra bottom scroll room so every screen's final card clears the floating bar.
            .padding(.bottom, NoopMetrics.tabBarClearance)
            // iPad: cap the readable column, then centre it in the full-width scroll viewport.
            // iPhone (.compact): the inner frame is .infinity/.leading, identical to before.
            .frame(maxWidth: hSizeClass == .regular ? NoopMetrics.readableColumnWidth : .infinity,
                   alignment: hSizeClass == .regular ? .center : .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .modifier(ViewportWidthLock(active: lockHorizontalScroll))
            #else
            .padding(NoopMetrics.desktopScreenPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            #endif
        }
        #if os(iOS)
        // #697: stop a vertical scroll from drifting/bouncing the screen left-right. `.basedOnSize` only
        // permits horizontal bounce when content genuinely overflows the width (it does not here, the column
        // is width-capped), so the spurious horizontal rubber-band that caused the sideways drift is gone.
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        #endif
        // The flat canvas, edge-to-edge under the status bar, plus the optional `topBackground` while it
        // still has callers.
        .background(alignment: .top) {
            ZStack(alignment: .top) {
                StrandPalette.surfaceBase
                topBackground
            }
            .ignoresSafeArea()
        }
        .modifier(RefreshableIfNeeded(onRefresh: onRefresh))
        .modifier(InlineNavigationTitle(title: usesNavigationBarTitle ? title : nil))
        #if os(macOS)
        // The mac window toolbar's default vibrant material washed the top of the liquid day-of-sky WHITE
        // (the scroll-under-titlebar blend). Hide it so the sky reads edge-to-edge and dark, like iOS.
        .toolbarBackground(.hidden, for: .windowToolbar)
        #endif
        #if os(iOS)
        // Scroll-to-top on an at-root tab re-tap (#198 follow-up). iOS-only: the tab shell is the only
        // driver, and gating here keeps the two-param onChange off macOS 13. Inert until the signal moves.
        .onChange(of: scrollToTopSignal) { _, _ in
            withAnimation(.easeOut(duration: 0.35)) { proxy.scrollTo(screenScaffoldTopAnchorID, anchor: .top) }
        }
        #endif
        }
    }

    /// True when the title belongs in the navigation bar instead of the column (pushed pages on iOS).
    private var usesNavigationBarTitle: Bool {
        #if os(iOS)
        return titleDisplay == .navigationBar
        #else
        return false
        #endif
    }

    /// What the in-content header shows: the title unless it moved to the navigation bar, and the data
    /// line (or legacy subtitle). A page whose title moved to the bar keeps the header row for its
    /// trailing controls, so they are not lost with the title.
    private var headerTitle: LocalizedStringKey? { usesNavigationBarTitle ? nil : title }
    private var showsHeader: Bool {
        headerTitle != nil || dateLine != nil || subtitle != nil
            || (usesNavigationBarTitle && Trailing.self != EmptyView.self)
    }

    /// The header + content column. `lazy` swaps the eager `VStack` for a `LazyVStack` so a long
    /// trailing `ForEach` (Intelligence "ALL") builds cards on demand instead of all at once. The
    /// alignment/spacing/header are identical in both branches, so the non-lazy path is byte-for-byte
    /// the previous layout. `@ViewBuilder` lets the two stack types resolve to one opaque return.
    @ViewBuilder private var column: some View {
        if lazy {
            LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if showsHeader { header }
                loadingContent
            }
            .background { loadingAnnouncement }
        } else {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                if showsHeader { header }
                loadingContent
            }
            .background { loadingAnnouncement }
        }
    }

    /// The content with the loading treatment applied per child (redacted, no taps, hidden from
    /// VoiceOver where the OS allows). Value modifiers only, so the children keep their identity, state
    /// and `.task`s when loading ends, and a lazy column stays lazy.
    private var loadingContent: some View {
        content().loadingRedaction(isLoading)
    }

    /// The single "Loading" element for the whole column, present only while loading.
    @ViewBuilder private var loadingAnnouncement: some View {
        if isLoading { LoadingAccessibilityElement() }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                if let headerTitle {
                    // The page-title role (28 semibold), the same face on every tab root.
                    Text(headerTitle).font(StrandFont.title1).foregroundStyle(StrandPalette.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                }
                if let dateLine {
                    Text(verbatim: dateLine).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                } else if let subtitle {
                    Text(subtitle).font(StrandFont.subhead).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

extension ScreenScaffold where Trailing == EmptyView {
    /// Convenience init for the common case with no header trailing element — keeps every existing
    /// call site (which never passed `trailing`) source-compatible.
    init(title: LocalizedStringKey?, subtitle: LocalizedStringKey? = nil, dateLine: String? = nil,
         titleDisplay: ScreenTitleDisplay = .header, isLoading: Bool = false,
         onRefresh: (() async -> Void)? = nil, lazy: Bool = false, lockHorizontalScroll: Bool = false,
         topBackground: AnyView? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, dateLine: dateLine, titleDisplay: titleDisplay,
                  isLoading: isLoading, onRefresh: onRefresh, lazy: lazy,
                  lockHorizontalScroll: lockHorizontalScroll,
                  topBackground: topBackground, trailing: { EmptyView() }, content: content)
    }
}

/// Puts a pushed page's title in the navigation bar, inline (iOS). A nil title leaves the bar alone, so
/// tab roots (and the Mac) are untouched. A modifier keeps both branches one opaque type.
private struct InlineNavigationTitle: ViewModifier {
    let title: LocalizedStringKey?
    func body(content: Content) -> some View {
        #if os(iOS)
        if let title {
            content
                .navigationTitle(Text(title))
                .navigationBarTitleDisplayMode(.inline)
        } else {
            content
        }
        #else
        content
        #endif
    }
}

#if os(iOS)
/// Sizes the content to the scroll view's own width, whatever the content asks for. Without it, one child
/// that cannot compress below the screen width makes the whole column wider than the viewport.
private struct ViewportWidthLock: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.containerRelativeFrame(.horizontal, alignment: .leading)
        } else {
            content
        }
    }
}
#endif

/// Applies `.refreshable` only when a refresh hook is provided. A ViewModifier (rather than an
/// inline `if`) keeps the two branches the same opaque type, and means nil callers — every macOS
/// screen — never attach the modifier at all.
private struct RefreshableIfNeeded: ViewModifier {
    let onRefresh: (() async -> Void)?
    func body(content: Content) -> some View {
        if let onRefresh {
            content.refreshable { await onRefresh() }
        } else {
            content
        }
    }
}

/// The quiet empty or pending state for a screen still gathering history: one short message on the card
/// surface, no icon tile and no headline.
///
/// `symbol` is accepted so the existing call sites keep compiling and ignored; the message carries the
/// meaning (docs/DESIGN_SYSTEM.md, Loading, empty and sparse states).
struct ComingSoon: View {
    let what: LocalizedStringKey
    var symbol: String = "sparkles"
    var body: some View {
        Text(what)
            .font(StrandFont.subhead)
            .foregroundStyle(StrandPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(NoopMetrics.cardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frostedCardSurface()
    }
}

/// "History sync in progress" (#77): one quiet line shown above a screen's empty state while the strap's
/// historical offload runs, so a half-loaded screen ("No nights here yet") reads as in progress rather
/// than final. Never a percent: the total pending is unknowable from the protocol, so a bar would lie.
/// Static, because nothing on screen should loop for a background task.
struct SyncingHistoryNote: View {
    let chunks: Int

    var body: some View {
        Label {
            Text("Syncing strap history…")
        } icon: {
            Image(systemName: "arrow.triangle.2.circlepath")
        }
        .font(StrandFont.footnote)
        .foregroundStyle(StrandPalette.textSecondary)
        .accessibilityElement(children: .combine)
    }
}

/// Coarse relative-time label for the "History synced N ago" sync-status line. Pure — `now` is
/// injectable so the bucket edges are unit-testable (RelativeAgoTests) — and deliberately the same
/// buckets as the Android `relativeAgo` (LiveScreen.kt, ed6a31d) so the two apps read identically.
/// Clamps future timestamps (strap-clock skew) to "just now", never negative.
func relativeAgo(_ epochSeconds: TimeInterval,
                 now: TimeInterval = Date().timeIntervalSince1970) -> String {
    let d = max(0, Int(now - epochSeconds))
    switch d {
    case ..<60:     return String(localized: "just now")
    case ..<3600:   return String(localized: "\(d / 60) min ago")
    case ..<86_400: return String(localized: "\(d / 3600) h ago")
    default:        return String(localized: "\(d / 86_400) d ago")
    }
}

/// A "what shows now vs what it is waiting for" note for an empty or pending section: a short title and
/// one line of detail on the card surface, no icon tile.
///
/// `symbol` is accepted so the existing call sites keep compiling and ignored.
struct DataPendingNote: View {
    let title: LocalizedStringKey
    let message: LocalizedStringKey
    var symbol: String = "sparkles"

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space1) {
            Text(title)
                .font(StrandFont.subhead.weight(.semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text(message)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(NoopMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frostedCardSurface()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Scroll-to-top signal (#198 follow-up)

/// An incrementing token the iOS tab shell bumps when the user re-taps the ALREADY-at-root active tab,
/// to scroll that tab's root screen to the top (the other half of the iOS tab convention #197/#198 left
/// unserved — an at-root re-tap is otherwise a no-op). `ScreenScaffold` and `LiquidTodayView` observe it
/// and scroll to their top anchor when it changes. Default 0 is never bumped outside the tab shell, so
/// macOS (sidebar, no tab re-tap) and every non-tab screen are completely unaffected.
/// Zero-height scroll-to-top target id. File scope, not a `static` on `ScreenScaffold` — the latter is
/// generic (`<Content, Trailing>`) and Swift forbids stored static properties on generic types.
private let screenScaffoldTopAnchorID = "screenScaffold.top"

private struct ScrollToTopSignalKey: EnvironmentKey {
    static let defaultValue: Int = 0
}

extension EnvironmentValues {
    var scrollToTopSignal: Int {
        get { self[ScrollToTopSignalKey.self] }
        set { self[ScrollToTopSignalKey.self] = newValue }
    }
}

/// Placeholder body for screens whose UI is still to come.
struct ComingSoonScreen: View {
    let title: LocalizedStringKey
    var body: some View {
        ScreenScaffold(title: title) {
            Text("Coming soon")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
        }
    }
}

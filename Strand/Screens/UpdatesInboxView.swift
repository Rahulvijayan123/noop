import SwiftUI
import StrandDesign

// MARK: - Updates inbox
//
// A calm, newest-first log of what's new — release notes, "new data arrived" readings, strap heads-ups,
// and the Today info-cards the user swiped away (which can be restored from here). Tapping an actionable
// row routes via NavRouter; a dismissed-card row offers "Restore to Today". Everything is on-device and
// non-clinical — informational, never a verdict.
//
// Content only: the title and Done are the host navigation bar's. As a sheet the caller wraps it in a
// NavigationStack and passes `onClose`; pushed (Browse) it passes nothing and the back button is the way out.
struct UpdatesInboxView: View {
    @EnvironmentObject var updateStore: UpdateStore
    @EnvironmentObject var router: NavRouter
    /// Dismisses the presenting sheet; nil when the inbox is pushed.
    var onClose: (() -> Void)? = nil

    private var unread: [UpdateItem] { updateStore.sortedItems.filter { !$0.read } }
    private var read: [UpdateItem] { updateStore.sortedItems.filter { $0.read } }

    var body: some View {
        VStack(spacing: 0) {
            content
            if !updateStore.items.isEmpty {
                Rectangle().fill(StrandPalette.hairline).frame(height: NoopMetrics.hairlineWidth)
                footer
            }
        }
        #if os(macOS)
        // A macOS sheet hosting a ScrollView collapses to nothing without a size (same as WhatsNewView).
        .frame(minWidth: 460, minHeight: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .noopSheetPresentation(largeFirst: true)
        #endif
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .navigationTitle(Text("Updates"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            if let onClose {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose).foregroundStyle(StrandPalette.accent)
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if updateStore.items.isEmpty {
            Text("You're all caught up.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, NoopMetrics.screenHPadding)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if !unread.isEmpty {
                        section("New", items: unread)
                    }
                    if !read.isEmpty {
                        section("Earlier", items: read)
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space6)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
        }
    }

    private func section(_ label: LocalizedStringKey, items: [UpdateItem]) -> some View {
        VStack(alignment: .leading, spacing: NoopMetrics.gap) {
            Text(label)
                .font(StrandFont.subhead.weight(.medium))
                .foregroundStyle(StrandPalette.textSecondary)
                .accessibilityAddTraits(.isHeader)
            ForEach(items) { item in
                UpdateRow(item: item, onTap: { handleTap(item) }, onRestore: { restore(item) })
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: NoopMetrics.space3) {
            Button {
                StrandHaptic.selection.play()
                withAnimation(StrandMotion.interactive) { updateStore.clearAll() }
            } label: {
                Label("Clear all", systemImage: "trash")
            }
            .buttonStyle(NoopButtonStyle(.tertiary))
            .disabled(updateStore.items.isEmpty)

            Spacer()

            Button {
                StrandHaptic.selection.play()
                withAnimation(StrandMotion.interactive) { updateStore.markAllRead() }
            } label: {
                Text("Mark all read")
            }
            .buttonStyle(NoopButtonStyle(.secondary))
            .disabled(updateStore.unreadCount == 0)
        }
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.vertical, NoopMetrics.space3)
    }

    // MARK: Actions

    /// Tapping a row marks it read, then routes if it carries a known deep link (else just stays open).
    private func handleTap(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        withAnimation(StrandMotion.interactive) { updateStore.markRead(item.id) }
        guard let key = item.deepLink, let dest = NavRouter.Destination(deepLinkKey: key) else { return }
        // Route via the shell, then close this sheet so the destination is visible.
        router.requestedDestination = dest
        onClose?()
    }

    /// Restore a dismissed Today card: flip its `@AppStorage` flag back (so it reappears), drop the
    /// inbox item, and close so the card is on screen.
    private func restore(_ item: UpdateItem) {
        StrandHaptic.selection.play()
        if let payload = item.restorePayload {
            // Clear the dismissed flag directly using the SAME key TodayView writes, so a Today that's
            // already mounted under the sheet picks the card back up immediately.
            UserDefaults.standard.set(false, forKey: TodayCardDismissal.flagKey(payload))
        }
        updateStore.requestRestore(item)
        onClose?()
    }
}

// MARK: - Row

private struct UpdateRow: View {
    let item: UpdateItem
    let onTap: () -> Void
    let onRestore: () -> Void

    var body: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: symbol)
                        .font(StrandFont.headline)
                        .foregroundStyle(tint)
                        .frame(width: 24)
                        .padding(.top, 1)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(item.title)
                            .font(StrandFont.headline)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(item.message)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(relativeDate)
                            .font(StrandFont.footnote)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .padding(.top, 1)
                    }
                    Spacer(minLength: 0)
                    if !item.read {
                        Circle().fill(StrandPalette.accent)
                            .frame(width: 8, height: 8)
                            .padding(.top, 5)
                            .accessibilityHidden(true)
                    }
                }
                if item.kind == .dismissedCard {
                    Button(action: onRestore) {
                        Label("Restore to Today", systemImage: "arrow.uturn.up")
                            .font(StrandFont.subhead)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(StrandPalette.accent)
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .strandPressable()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(item.read ? "\(item.title). \(item.message)"
                                       : "Unread. \(item.title). \(item.message)")
    }

    private var symbol: String {
        switch item.kind {
        case .dismissedCard: return "rectangle.on.rectangle"
        case .whatsNew:      return "sparkles"
        case .reading:       return "waveform.path.ecg"
        case .strapAlert:    return "exclamationmark.triangle"
        // Distinct from `.whatsNew`'s sparkles on purpose: this is something you have NOT got yet.
        case .newVersion:    return "arrow.down.circle"
        }
    }

    /// A per-kind tint drawn from the domain palette so each row reads in its own colour world.
    private var tint: Color {
        switch item.kind {
        case .dismissedCard: return StrandPalette.textSecondary
        case .whatsNew:      return StrandPalette.accent
        case .reading:       return StrandPalette.restColor
        case .strapAlert:    return StrandPalette.statusWarning
        case .newVersion:    return StrandPalette.accent
        }
    }

    private var relativeDate: String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: item.date, relativeTo: Date())
    }
}

// MARK: - Today card dismissal keys (shared)
//
// The Today info-cards persist their dismissed state in `@AppStorage` under a stable per-card key. The
// inbox restores a card by clearing that same key, so the key shape lives in ONE place both sides use.
enum TodayCardDismissal {
    /// The `@AppStorage` bool key for a Today info-card's dismissed flag, by stable card id.
    static func flagKey(_ cardID: String) -> String { "noop.todayCard.\(cardID).dismissed" }
}

import SwiftUI
import StrandDesign

/// "What's New" — a proper in-app changelog, shown automatically after an update and reachable any
/// time from Settings. It also restates, up top, what Nara is and what to expect, so people who never
/// open GitHub still understand the experimental footing and the WHOOP 5/MG status.
///
/// Always presented as a sheet, so it brings its own NavigationStack: the inline title and a trailing
/// Done are the system bar's (no custom header, no scenic backdrop, no footer bar).
struct WhatsNewView: View {
    let onClose: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                // PERF: the changelog grows with every release, so this is an ever-lengthening column.
                // LazyVStack builds the off-screen release cards on demand instead of constructing the
                // entire history up-front each time the sheet opens.
                LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    Text(verbatim: "Nara \(AppChangelog.currentVersion)")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textSecondary)
                    expectationsCard
                    ForEach(AppChangelog.releases, id: \.id) { release in
                        releaseCard(release)
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.vertical, NoopMetrics.space6)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity: stop a vertical scroll from drifting the sheet sideways.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(Text("What's new"))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", action: onClose)
                        .foregroundStyle(StrandPalette.accent)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        // A fixed 560×640 is right for the macOS sheet window, but on iPhone it's wider than the
        // screen (#185). iOS fills the presented sheet instead.
        #if os(macOS)
        .frame(width: 560, height: 640)
        #else
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A long changelog scroll → open full-height, with a grabber for swipe-to-dismiss.
        .noopSheetPresentation(largeFirst: true)
        #endif
    }

    private var expectationsCard: some View {
        NoopCard {
            VStack(alignment: .leading, spacing: NoopMetrics.cardInnerSpacing) {
                Text("What to expect").font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                ForEach(AppChangelog.expectations) { e in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: e.icon)
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 22)
                            .padding(.top, 2)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.title).font(StrandFont.headline)
                                .foregroundStyle(StrandPalette.textPrimary)
                            Text(e.body).font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func releaseCard(_ release: AppChangelog.Release) -> some View {
        NoopCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    SourceBadge("v\(release.version)")
                    Text(release.title).font(StrandFont.headline)
                        .foregroundStyle(StrandPalette.textPrimary)
                    Spacer()
                    Text(release.date).font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                ForEach(Array(release.items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 8) {
                        Circle().fill(StrandPalette.textTertiary).frame(width: 5, height: 5)
                            .padding(.top, 7)
                        Text(item).font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

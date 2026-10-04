import SwiftUI
import StrandDesign

// MARK: - Unified Today customization

/// Every Today editing entry point presents the same sheet and optionally deep-links to one child editor.
enum TodayCustomizationDestination: String, Identifiable, Hashable {
    case today
    case addedCards

    var id: String { rawValue }
}

struct TodayCustomizationSheet: View {
    @Environment(\.dismiss) private var dismiss

    private enum Route: Hashable {
        case addedCards
    }

    private let initialSectionDraft: EditableLayoutDraft<TodaySection>
    private let initialHostedDraft: EditableLayoutDraft<HostedCard>

    @Binding private var sectionOrderRaw: String
    @Binding private var hiddenSectionsRaw: String
    @Binding private var hostedCardsRaw: String

    @State private var path: [Route]
    @State private var sectionDraft: EditableLayoutDraft<TodaySection>
    @State private var hostedDraft: EditableLayoutDraft<HostedCard>

    private var currentDestination: TodayCustomizationDestination {
        switch path.last {
        case .addedCards: return .addedCards
        case nil: return .today
        }
    }

    private var isDirty: Bool {
        sectionDraft != initialSectionDraft || hostedDraft != initialHostedDraft
    }

    init(
        initialDestination: TodayCustomizationDestination = .today,
        sectionOrderRaw: Binding<String>,
        hiddenSectionsRaw: Binding<String>,
        hostedCardsRaw: Binding<String>
    ) {
        _sectionOrderRaw = sectionOrderRaw
        _hiddenSectionsRaw = hiddenSectionsRaw
        _hostedCardsRaw = hostedCardsRaw

        let fullSectionOrder = TodayLayoutPrefs.decodeOrder(sectionOrderRaw.wrappedValue)
        let hiddenSectionSet = Set(TodayLayoutPrefs.decodeHidden(hiddenSectionsRaw.wrappedValue))
        let sections = EditableLayoutDraft(
            visible: fullSectionOrder.filter { !hiddenSectionSet.contains($0) },
            hidden: fullSectionOrder.filter { hiddenSectionSet.contains($0) }
        )
        let hosted = EditableLayoutDraft(
            visible: HostedCardPrefs.decodeEnabled(hostedCardsRaw.wrappedValue),
            allItems: HostedCard.canonicalOrder
        )

        initialSectionDraft = sections
        initialHostedDraft = hosted

        _sectionDraft = State(initialValue: sections)
        _hostedDraft = State(initialValue: hosted)

        switch initialDestination {
        case .today:
            _path = State(initialValue: [])
        case .addedCards:
            _path = State(initialValue: [.addedCards])
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            TodaySectionsCustomizationPage(
                draft: $sectionDraft,
                hostedCardCount: hostedDraft.visible.count,
                onConfigure: openConfiguration,
                onReset: resetCurrentLayout
            )
            .toolbar {
                customizationToolbar(showCancel: true)
            }
            .navigationDestination(for: Route.self) { route in
                switch route {
                case .addedCards:
                    HostedCardsCustomizationPage(
                        draft: $hostedDraft,
                        onReset: resetCurrentLayout
                    )
                        .toolbar {
                            customizationToolbar(showCancel: false)
                        }
                }
            }
        }
        .interactiveDismissDisabled(isDirty)
        .tint(StrandPalette.accent)
        #if os(macOS)
        .frame(
            minWidth: NoopMetrics.editorSheetMinWidth,
            minHeight: NoopMetrics.editorSheetMinHeight
        )
        #endif
    }

    private func openConfiguration(_ section: TodaySection) {
        switch section {
        case .addedCards:
            path.append(.addedCards)
        default:
            break
        }
    }

    private func resetCurrentLayout() {
        switch currentDestination {
        case .today:
            sectionDraft = EditableLayoutDraft(
                visible: TodaySection.defaultOrder,
                allItems: TodaySection.defaultOrder
            )
        case .addedCards:
            hostedDraft = EditableLayoutDraft(
                visible: HostedCard.defaultSelection,
                allItems: HostedCard.canonicalOrder
            )
        }
    }

    private func cancel() {
        dismiss()
    }

    private func save() {
        sectionOrderRaw = TodayLayoutPrefs.encode(sectionDraft.visible + sectionDraft.hidden)
        hiddenSectionsRaw = TodayLayoutPrefs.encodeHidden(sectionDraft.hidden)
        hostedCardsRaw = HostedCardPrefs.encode(hostedDraft.visible)
        dismiss()
    }

    @ToolbarContentBuilder
    private func customizationToolbar(showCancel: Bool) -> some ToolbarContent {
        if showCancel {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", action: cancel)
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", action: save)
        }
    }
}

// MARK: - Editor pages

private struct TodaySectionsCustomizationPage: View {
    @Binding var draft: EditableLayoutDraft<TodaySection>
    let hostedCardCount: Int
    let onConfigure: (TodaySection) -> Void
    let onReset: () -> Void

    var body: some View {
        EditableLayoutList(
            draft: $draft,
            shownTitle: String(localized: "Shown on Today"),
            hiddenTitle: String(localized: "Hidden"),
            title: \.title,
            subtitle: subtitle,
            icon: \.customizationIcon,
            tint: \.customizationTint,
            configurationLabel: configurationLabel,
            onConfigure: onConfigure,
            onReset: onReset
        ) {
            EmptyView()
        }
        .navigationTitle("Customize Today")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func subtitle(for section: TodaySection) -> String? {
        switch section {
        case .addedCards:
            return hostedCardCount == 0
                ? String(localized: "None added yet")
                : String(localized: "\(hostedCardCount) added")
        default:
            return nil
        }
    }

    private func configurationLabel(for section: TodaySection) -> String? {
        switch section {
        case .addedCards:
            return String(localized: "Edit")
        default:
            return nil
        }
    }
}

/// The Customise page for the Trends/Sleep cards hosted in Today (#today-hosted-cards). Reuses the shared
/// Shown/Hidden editor used for the Today sections; the Shown list is the `HostedCardPrefs` selection in
/// order, the Hidden list is every not-yet-hosted card. Subtitle names the originating tab.
private struct HostedCardsCustomizationPage: View {
    @Binding var draft: EditableLayoutDraft<HostedCard>
    let onReset: () -> Void

    var body: some View {
        EditableLayoutList(
            draft: $draft,
            shownTitle: String(localized: "Added to Today"),
            hiddenTitle: String(localized: "Available"),
            title: \.title,
            subtitle: { String(localized: "from \($0.origin)") },
            icon: \.customizationIcon,
            tint: \.customizationTint,
            configurationLabel: { _ in nil },
            onConfigure: { _ in },
            onReset: onReset,
            allowEmpty: true,   // hosting is opt-in: the last card can be un-hosted (Shown may be empty)
            group: { $0.origin }   // group the Available list by origin tab ("Sleep", "Trends")
        ) {
            EmptyView()
        }
        .navigationTitle(String(localized: "Added Cards"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

#if DEBUG
#Preview("Customize Today") {
    TodayCustomizationSheet(
        sectionOrderRaw: .constant(""),
        hiddenSectionsRaw: .constant(""),
        hostedCardsRaw: .constant("")
    )
    .preferredColorScheme(.dark)
}
#endif

import SwiftUI
import StrandDesign

// MARK: - Workout selection
//
// The activity picker for a live start (and the merge-name reuse): a search field, the recent sports, then the
// whole catalogue, as list rows in the house style. Catalogue, recents, GPS flags, and `onStart` /
// `RecentSportsPrefs` are unchanged.

/// Public entry used by Live / Workouts. Keeps the prior `onStart` + optional title overrides so the
/// merge-name prompt can reuse the same browser.
struct StartWorkoutSheet: View {
    let onStart: (_ sport: String) -> Void
    private let heading: String
    private let explainer: String?
    private let actionVerb: String

    init(title: String? = nil, subtitle: String? = nil, actionVerb: String? = nil,
         onStart: @escaping (_ sport: String) -> Void) {
        self.onStart = onStart
        self.heading = title ?? String(localized: "Start workout")
        // The live start needs no explanation; the merge prompt passes the one line it needs.
        self.explainer = subtitle
        self.actionVerb = actionVerb ?? String(localized: "Start")
    }

    var body: some View {
        WorkoutSelectionScreen(heading: heading, explainer: explainer, actionVerb: actionVerb,
                               onStart: onStart)
    }
}

// MARK: - Screen

struct WorkoutSelectionScreen: View {
    let heading: String
    let explainer: String?
    let actionVerb: String
    let onStart: (_ sport: String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    private var trimmedQuery: String { query.trimmingCharacters(in: .whitespaces) }
    private var filtered: [WorkoutCatalog.Sport] { WorkoutCatalog.matching(query) }
    private var recentSports: [WorkoutCatalog.Sport] {
        RecentSportsPrefs.recent().compactMap { WorkoutCatalog.sport(named: $0) }
    }
    private var showRecent: Bool { trimmedQuery.isEmpty && !recentSports.isEmpty }

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.sectionGap) {
                    if let explainer {
                        Text(explainer)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    WorkoutSearchField(query: $query, isFocused: $searchFocused)

                    if showRecent {
                        NoopListSection("Recent") { rows(recentSports) }
                    }

                    if filtered.isEmpty {
                        Text("No workouts found")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, NoopMetrics.space8)
                    } else {
                        NoopListSection(showRecent ? "All activities" : nil) { rows(filtered) }
                    }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, NoopMetrics.space4)
                .padding(.bottom, NoopMetrics.space10)
            }
            #if os(iOS)
            // #697/#horizontal-swipe parity, see ScreenScaffold.
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
            #endif
            .scrollDismissesKeyboard(.interactively)
            .background {
                StrandPalette.surfaceBase.ignoresSafeArea()
            }
            .navigationTitle(heading)
            .navigationBarTitleDisplayModeCompat()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 640)
        #endif
    }

    @ViewBuilder
    private func rows(_ sports: [WorkoutCatalog.Sport]) -> some View {
        ForEach(Array(sports.enumerated()), id: \.element.id) { index, sport in
            if index > 0 { NoopListDivider(leadingInset: NoopListDivider.iconRowInset) }
            WorkoutSelectionRow(sport: sport, actionVerb: actionVerb) { select(sport.name) }
        }
    }

    private func select(_ name: String) {
        searchFocused = false
        RecentSportsPrefs.recordSelection(name)
        onStart(name)
        dismiss()
    }
}

// MARK: - Search

struct WorkoutSearchField: View {
    @Binding var query: String
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        NoopLiquidGlassSearchField(text: $query,
                                   prompt: String(localized: "Search workouts"),
                                   isFocused: isFocused)
    }
}

// MARK: - Row

/// One activity: its symbol, its name, what the catalogue knows about it ("GPS · Outdoor"), and a tap that
/// starts it.
struct WorkoutSelectionRow: View {
    let sport: WorkoutCatalog.Sport
    let actionVerb: String
    let onSelect: () -> Void

    /// The catalogue flags, less any that only repeat the name ("Strength · Strength").
    private var meta: [WorkoutActivityMeta.Item] {
        WorkoutActivityMeta.items(for: sport).filter { $0.text.localizedCaseInsensitiveCompare(sport.name) != .orderedSame }
    }

    var body: some View {
        Button(action: onSelect) {
            NoopListRow(icon: sportSymbol(sport.name), iconColor: StrandPalette.effortColor,
                        title: "\(sport.name)",
                        subtitle: meta.isEmpty ? nil : meta.map(\.text).joined(separator: " · "),
                        showsChevron: false)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilityLabelText))
        .accessibilityHint(Text("Double tap to \(actionVerb.lowercased())"))
        .accessibilityAddTraits(.isButton)
    }

    private var accessibilityLabelText: String {
        let labels = meta.map(\.text)
        if labels.isEmpty { return "\(sport.name) workout" }
        return "\(sport.name) workout, \(labels.joined(separator: ", "))"
    }
}

// MARK: - Metadata

enum WorkoutActivityMeta {
    struct Item: Equatable {
        var symbol: String?
        var text: String
    }

    /// Labels derived only from catalogue flags / known types — no invented capabilities.
    static func items(for sport: WorkoutCatalog.Sport) -> [Item] {
        var items: [Item] = []
        if sport.isDistanceSport {
            items.append(Item(symbol: "location.fill", text: String(localized: "GPS")))
        }
        if let type = KnownWorkoutType.exact(matching: sport.name) {
            switch type {
            case .treadmillRun, .treadmillWalk, .indoorCycle, .poolSwim, .rowMachine, .elliptical:
                items.append(Item(symbol: nil, text: String(localized: "Indoor")))
            case .running, .walking, .hiking, .cycling, .openWaterSwim, .rowing, .skiing, .snowboarding:
                items.append(Item(symbol: nil, text: String(localized: "Outdoor")))
            case .strength, .bodybuilding, .weightlifting:
                items.append(Item(symbol: nil, text: String(localized: "Strength")))
            case .yoga, .pilates, .stretching:
                items.append(Item(symbol: nil, text: String(localized: "Mindfulness")))
            case .hiit:
                items.append(Item(symbol: nil, text: String(localized: "Cardio")))
            default:
                break
            }
        }
        return items
    }
}

// MARK: - Presentation helper

extension View {
    /// Full-screen workout browser on iOS; plain sheet on macOS (no fullScreenCover there).
    @ViewBuilder
    func workoutSelectionCover(isPresented: Binding<Bool>,
                               @ViewBuilder content: @escaping () -> StartWorkoutSheet) -> some View {
        #if os(iOS)
        self.fullScreenCover(isPresented: isPresented, content: content)
        #else
        self.sheet(isPresented: isPresented, content: content)
        #endif
    }

    @ViewBuilder
    func workoutSelectionCover<Item: Identifiable>(item: Binding<Item?>,
                                                   @ViewBuilder content: @escaping (Item) -> StartWorkoutSheet) -> some View {
        #if os(iOS)
        self.fullScreenCover(item: item, content: content)
        #else
        self.sheet(item: item, content: content)
        #endif
    }
}

private extension View {
    @ViewBuilder
    func navigationBarTitleDisplayModeCompat() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
}

#if DEBUG
#Preview("Start workout") {
    StartWorkoutSheet { _ in }
}
#endif

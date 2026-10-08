import StrandDesign
import SwiftUI

/// The Sana chat list (`docs/COACH_MEMORY.md` §7.6): search, New chat, folders, the date-grouped chats and the
/// way into "What Sana remembers". It observes only the thread store and the chrome state, never the view model,
/// so a streaming reply does not redraw it. `CoachChatView`'s drawer layer wraps it in `.equatable()` for the same
/// reason, and so a drawer-drag frame only moves it: the memory-sheet callback is a closure, which SwiftUI can't
/// compare on its own.
///
/// On iPhone it is the drawer (`compact`), and picking a chat or New chat closes it. On iPad it is the inline
/// column and stays where it is.
struct CoachSidebar: View, Equatable {
    @ObservedObject var store: CoachThreadStore
    @ObservedObject var chrome: CoachChromeState
    /// The iPhone drawer rather than the iPad column.
    let compact: Bool
    /// Whether the drawer or column is showing. It stays in the tree while hidden (only moved off screen), so a
    /// search field focused when it closes would keep the keyboard and take typing out of sight; closing clears it.
    let isOpen: Bool
    /// Opens the memory sheet; the chat view presents it, because the sheet reads the view model.
    var onShowMemories: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    /// Folder ids whose chats are hidden. Session only: every folder opens expanded on the next launch.
    @State private var collapsed: Set<String> = []
    @State private var prompt: TextPrompt?
    @State private var promptText = ""
    @State private var confirmation: Confirmation?

    static func == (a: CoachSidebar, b: CoachSidebar) -> Bool {
        a.store === b.store && a.chrome === b.chrome && a.compact == b.compact && a.isOpen == b.isOpen
    }

    /// The text-entry alerts. Only one is ever up, so a single `.alert` serves them all.
    private enum TextPrompt: Identifiable {
        case renameThread(CoachThread)
        /// From a chat's "Move to folder" menu (the chat moves into the new folder) or from the footer.
        case newFolder(moving: CoachThread?)
        case renameFolder(CoachFolder)

        var id: String {
            switch self {
            case .renameThread(let t): return "rename." + t.id
            case .newFolder(let t): return "folder." + (t?.id ?? "")
            case .renameFolder(let f): return "renameFolder." + f.id
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .renameThread: return "Rename chat"
            case .newFolder: return "New folder"
            case .renameFolder: return "Rename folder"
            }
        }

        var placeholder: LocalizedStringKey {
            switch self {
            case .renameThread: return "Title"
            case .newFolder, .renameFolder: return "Folder name"
            }
        }

        var confirm: LocalizedStringKey {
            switch self {
            case .renameThread, .renameFolder: return "Save"
            case .newFolder: return "Create"
            }
        }
    }

    private enum Confirmation: Identifiable {
        case deleteThread(CoachThread)
        case deleteFolder(CoachFolder)

        var id: String {
            switch self {
            case .deleteThread(let t): return "thread." + t.id
            case .deleteFolder(let f): return "folder." + f.id
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .deleteThread: return "Delete this chat?"
            case .deleteFolder: return "Delete this folder?"
            }
        }

        var message: LocalizedStringKey {
            switch self {
            case .deleteThread:
                return "The chat is removed from your history. Anything Sana remembers stays until you forget it in What Sana remembers."
            case .deleteFolder:
                return "Its chats stay in your history, outside any folder."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            NoopLiquidGlassSearchField(text: $store.query, prompt: String(localized: "Search chats"),
                                       isFocused: $searchFocused)
                .onSubmit(of: .text) { store.recordSearch() }
                .accessibilityIdentifier("coachSidebarSearch")
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 8)
            newChatRow
            list
            footer
        }
        // Every way of closing (scrim, drag, escape, a pending prompt, the iPad toggle, leaving the tab) lands here.
        .onChange(of: isOpen) { _, open in if !open { searchFocused = false } }
        .alert(Text(prompt?.title ?? ""),
               isPresented: Binding(get: { prompt != nil }, set: { if !$0 { prompt = nil } }),
               presenting: prompt) { p in
            TextField(p.placeholder, text: $promptText)
            Button(p.confirm) { commit(p) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog(Text(confirmation?.title ?? ""),
                            isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
                            titleVisibility: .visible, presenting: confirmation) { c in
            switch c {
            case .deleteThread(let thread):
                Button("Delete chat", role: .destructive) { store.requestDelete(id: thread.id) }
            case .deleteFolder(let folder):
                Button("Delete folder", role: .destructive) { Task { await store.deleteFolder(id: folder.id) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { c in
            Text(c.message)
        }
    }

    // MARK: Header

    /// Mirrors the chat header, so the drawer's close control lands where the button that opened it was.
    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            if compact {
                CoachHeaderButton(symbol: "sidebar.left", label: "Close chats", identifier: "coachSidebarCloseButton") {
                    close()
                }
            }
            Text("Chats")
                .font(StrandFont.rounded(24))
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 48)
        .padding(.leading, compact ? NoopMetrics.screenPadding - 4 : 16)
        .padding(.trailing, 16)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var newChatRow: some View {
        Button(action: newChat) {
            HStack(spacing: 12) {
                Image(systemName: "square.and.pencil")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(StrandPalette.accent)
                    .frame(width: 22)
                Text("New chat")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .disabled(!store.canSwitchThreads)
        .opacity(store.canSwitchThreads ? 1 : StrandPalette.disabledOpacity)
        .padding(.horizontal, 8)
        .accessibilityIdentifier("coachSidebarNewChat")
    }

    // MARK: List

    /// What every row reads from the store, read once per body rather than once per row.
    private struct RowContext {
        let currentThreadId: String?
        let canSwitchThreads: Bool
        let showsSnippets: Bool
        /// The "Move to folder" choices, sorted once rather than in every row's context menu.
        let folders: [CoachFolder]
    }

    private var list: some View {
        let context = RowContext(currentThreadId: store.currentThreadId, canSwitchThreads: store.canSwitchThreads,
                                 showsSnippets: store.searchResults != nil,
                                 folders: store.folders.sorted { $0.sortOrder < $1.sortOrder })
        return ScrollView(showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2) {
                if let error = store.errorMessage { errorRow(error) }
                if let results = store.searchResults {
                    searchResults(results, context)
                } else {
                    browse(context)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 12)
            .animation(NoopMotion.gated(NoopMotion.card, reduced: reduceMotion), value: store.sections)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    /// Each group is a `Section`, not a stack, so the lazy stack builds only the rows on screen: a long Older group
    /// paged in by scrolling stays cheap when the store publishes (every turn start and end, saves, titles).
    @ViewBuilder
    private func browse(_ context: RowContext) -> some View {
        let firstFolder = store.sections.first { if case .folder = $0.kind { return true } else { return false } }?.id
        ForEach(store.sections) { section in
            switch section.kind {
            case .folder(let folder):
                if section.id == firstFolder { sectionTitle(Text("Folders")) }
                folderSection(folder, threads: section.threads, context)
            default:
                Section {
                    ForEach(section.threads) { row($0, context) }
                } header: {
                    sectionTitle(title(of: section))
                }
            }
        }
        if store.threads.isEmpty { emptyState }
        if store.hasMore { moreRow }
    }

    private func title(of section: CoachThreadSection) -> Text {
        switch section.kind {
        case .pinned: return Text("Pinned")
        case .folder(let folder): return Text(verbatim: folder.name)
        case .today: return Text("Today")
        case .yesterday: return Text("Yesterday")
        case .previous7Days: return Text("Previous 7 Days")
        case .previous30Days: return Text("Previous 30 Days")
        case .older: return Text("Older")
        }
    }

    private func sectionTitle(_ text: Text) -> some View {
        text.strandOverline()
            .padding(.horizontal, 12)
            .padding(.top, 14)
            .padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    private func folderSection(_ folder: CoachFolder, threads: [CoachThread], _ context: RowContext) -> some View {
        let isCollapsed = collapsed.contains(folder.id)
        return Section {
            if !isCollapsed {
                ForEach(threads) { row($0, context, indented: true) }
                if threads.isEmpty {
                    Text("No chats in this folder yet")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .padding(.leading, 46)
                        .padding(.vertical, 6)
                }
            }
        } header: {
            Button { toggle(folder) } label: {
                HStack(spacing: 10) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(StrandPalette.textTertiary)
                        .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                        .frame(width: 12)
                    Image(systemName: "folder")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(StrandPalette.accent)
                    Text(verbatim: folder.name)
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text("\(threads.count)")
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            .contextMenu {
                Button {
                    promptText = folder.name
                    prompt = .renameFolder(folder)
                } label: { Label("Rename folder", systemImage: "pencil") }
                Button(role: .destructive) { confirmation = .deleteFolder(folder) } label: {
                    Label("Delete folder", systemImage: "trash")
                }
            }
            .accessibilityLabel(Text("\(folder.name), \(threads.count) chats"))
            .accessibilityValue(isCollapsed ? Text("Collapsed") : Text("Expanded"))
            .accessibilityHint(isCollapsed ? Text("Shows the chats in this folder") : Text("Hides the chats in this folder"))
            .accessibilityIdentifier("coachFolderRow.\(folder.id)")
        }
    }

    @ViewBuilder
    private func searchResults(_ results: [CoachThread], _ context: RowContext) -> some View {
        HStack(spacing: 8) {
            sectionTitle(Text("Results"))
            Spacer(minLength: 0)
            if store.isSearching {
                ProgressView().controlSize(.small).padding(.trailing, 12).padding(.top, 10)
            }
        }
        ForEach(results) { row($0, context) }
        if results.isEmpty, !store.isSearching {
            Text("No chats match your search.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textTertiary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
        }
    }

    private func row(_ thread: CoachThread, _ context: RowContext, indented: Bool = false) -> some View {
        let selected = context.currentThreadId == thread.id
        let locked = !context.canSwitchThreads && !selected
        return Button { open(thread) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: thread.displayTitle)
                    .font(StrandFont.subhead)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .lineLimit(1)
                if let snippet = thread.snippet, !snippet.isEmpty, context.showsSnippets {
                    Text(CoachSnippet.attributed(snippet))
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, indented ? 46 : 12)
            .padding(.trailing, 12)
            .padding(.vertical, 10)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(StrandPalette.accent.opacity(0.12))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .opacity(locked ? StrandPalette.disabledOpacity : 1)
        .contextMenu { menu(for: thread, folders: context.folders) }
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityHint(locked ? Text("Available when Sana finishes answering") : Text(""))
        .accessibilityIdentifier("coachThreadRow.\(thread.id)")
    }

    @ViewBuilder
    private func menu(for thread: CoachThread, folders: [CoachFolder]) -> some View {
        Button {
            promptText = thread.title ?? thread.displayTitle
            prompt = .renameThread(thread)
        } label: { Label("Rename", systemImage: "pencil") }
        Menu {
            ForEach(folders) { folder in
                Button { Task { await store.move(id: thread.id, folderId: folder.id) } } label: {
                    if thread.folderId == folder.id {
                        Label { Text(verbatim: folder.name) } icon: { Image(systemName: "checkmark") }
                    } else {
                        Text(verbatim: folder.name)
                    }
                }
            }
            if thread.folderId != nil {
                Button { Task { await store.move(id: thread.id, folderId: nil) } } label: {
                    Label("Remove from folder", systemImage: "folder.badge.minus")
                }
            }
            Divider()
            Button {
                promptText = ""
                prompt = .newFolder(moving: thread)
            } label: { Label("New folder…", systemImage: "folder.badge.plus") }
        } label: { Label("Move to folder", systemImage: "folder") }
        Button { Task { await store.setPinned(id: thread.id, !thread.pinned) } } label: {
            if thread.pinned { Label("Unpin", systemImage: "pin.slash") } else { Label("Pin", systemImage: "pin") }
        }
        Divider()
        Button(role: .destructive) { confirmation = .deleteThread(thread) } label: { Label("Delete", systemImage: "trash") }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: 8) {
            switch store.phase {
            case .loading:
                ProgressView().tint(StrandPalette.accent)
            case .failed:
                Text("Couldn't load your chats")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Button { Task { await store.refresh() } } label: {
                    Label("Try again", systemImage: "arrow.clockwise")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.accent)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(StrandPalette.accent.opacity(0.12), in: Capsule())
                }
                .buttonStyle(.plain)
            case .idle, .ready:
                Image(systemName: "bubble.left.and.bubble.right")
                    .font(.system(size: 22))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
                Text("No chats yet")
                    .font(StrandFont.headline)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text("Your conversations with Sana show up here.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    private var moreRow: some View {
        HStack {
            Spacer()
            if store.isLoadingMore {
                ProgressView().controlSize(.small)
            } else {
                Button("Show more") { Task { await store.loadMore() } }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
            }
            Spacer()
        }
        .padding(.vertical, 12)
        // Scrolling to the end pages in the next batch by itself; the button is there for VoiceOver.
        .onAppear { Task { await store.loadMore() } }
    }

    private func errorRow(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(StrandPalette.statusCritical)
                .accessibilityHidden(true)
            Text(message)
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.statusCritical)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { store.errorMessage = nil } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(StrandPalette.statusCritical.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.vertical, 4)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 4) {
            Button(action: onShowMemories) {
                HStack(spacing: 10) {
                    Image(systemName: "brain")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(width: 22)
                    Text("What Sana remembers")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityIdentifier("coachMemoryButton")

            Button {
                promptText = ""
                prompt = .newFolder(moving: nil)
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(StrandPalette.textSecondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(LiquidPressStyle())
            .accessibilityLabel("New folder")
            .accessibilityIdentifier("coachNewFolderButton")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .overlay(alignment: .top) {
            Rectangle().fill(StrandPalette.hairline).frame(height: 0.5)
        }
    }

    // MARK: Actions

    private func open(_ thread: CoachThread) {
        guard store.canSwitchThreads else { return }
        searchFocused = false
        store.select(thread)
        if compact { close() }
    }

    private func newChat() {
        guard store.canSwitchThreads else { return }
        searchFocused = false
        store.requestNewChat()
        if compact { close() }
    }

    private func close() {
        searchFocused = false
        chrome.drawerOpen = false
    }

    private func toggle(_ folder: CoachFolder) {
        withAnimation(NoopMotion.gated(NoopMotion.card, reduced: reduceMotion)) {
            if collapsed.contains(folder.id) { collapsed.remove(folder.id) } else { collapsed.insert(folder.id) }
        }
    }

    private func commit(_ prompt: TextPrompt) {
        let text = promptText
        switch prompt {
        case .renameThread(let thread):
            // Through the view model, so the header follows the rename and is put back if the server refuses it.
            store.requestRename(id: thread.id, title: text)
        case .newFolder(let moving):
            Task {
                guard let folder = await store.createFolder(name: text), let moving else { return }
                await store.move(id: moving.id, folderId: folder.id)
            }
        case .renameFolder(let folder):
            Task { await store.renameFolder(id: folder.id, name: text) }
        }
    }
}

// MARK: - Search snippets

enum CoachSnippet {
    /// A search snippet with the server's `«match»` markers as bold runs; the markers themselves are dropped.
    static func attributed(_ snippet: String) -> AttributedString {
        var out = AttributedString()
        var run = ""
        var bold = false
        func flush() {
            guard !run.isEmpty else { return }
            var part = AttributedString(run)
            if bold {
                part.inlinePresentationIntent = .stronglyEmphasized
                part.foregroundColor = StrandPalette.textPrimary
            }
            out += part
            run = ""
        }
        for ch in CoachModelText.collapsed(snippet) {
            switch ch {
            case "«": flush(); bold = true
            case "»": flush(); bold = false
            default: run.append(ch)
            }
        }
        flush()
        return out
    }
}

#if DEBUG
// MARK: - Screenshot seed

/// `--coach-demo-threads`: a few made-up chats, one pinned and two in a folder, so the drawer can be captured on
/// a build with no coach backend. Only when no account is configured, so nothing reaches a real owner's caches.
enum CoachSidebarDemo {
    static var requested: Bool { CommandLine.arguments.contains("--coach-demo-threads") }

    @MainActor
    static func seed(_ store: CoachThreadStore, now: Date = Date()) async {
        guard requested, !CoachAPI.shared.isAvailable, store.threads.isEmpty else { return }
        let folder = await store.createFolder(name: "Half marathon")
        let rows: [(title: String, hoursAgo: Double, pinned: Bool, inFolder: Bool)] = [
            ("Sleep before race day", 1, false, false),
            ("Why my HRV dipped after travel", 5, true, false),
            ("Taper plan for the last two weeks", 26, false, true),
            ("Knee niggle on long runs", 70, false, true),
            ("Protein on rest days", 120, false, false),
            ("Caffeine cut-off and deep sleep", 400, false, false),
            ("Building a morning routine", 1_500, false, false),
        ]
        for (i, row) in rows.enumerated() {
            let stamp = CoachDates.string(now.addingTimeInterval(-row.hoursAgo * 3_600))
            store.apply(CoachThread(id: UUID().uuidString, title: row.title, titleSource: "auto",
                                    folderId: row.inFolder ? folder?.id : nil, pinned: row.pinned, origin: "app",
                                    createdAt: stamp, updatedAt: stamp, lastMessageAt: stamp, messageCount: 4 + 2 * i))
        }
    }
}
#endif

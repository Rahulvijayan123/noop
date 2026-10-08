import PhotosUI
import StrandDesign
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Holds the streaming-scroll timestamp as a class so updating it never invalidates the view body.
private final class CoachScrollThrottle { var last: TimeInterval = 0 }

/// The Sana tab (`docs/COACH_MEMORY.md` §7.6): the chat column (header, welcome or messages, composer) and the
/// chats sidebar. On iPhone the sidebar is a drawer over a scrim; on iPad it is an inline column, open by default.
/// Both are the same view in the same place in one tree, so a size-class change never rebuilds the chat.
struct CoachChatView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coachEngine: AICoachEngine
    @EnvironmentObject private var profile: ProfileStore
    /// Whether the iPhone drawer is open; `RootTabView` reads it to pause the tab swipe.
    @EnvironmentObject private var chrome: CoachChromeState
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.noopBottomChromeInset) private var bottomChromeInset
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var vm = CoachChatViewModel()
    @FocusState private var inputFocused: Bool
    /// True while the list should chase new content. Only the wearer dragging the list upward turns it off:
    /// content that grows past the viewport also hides the bottom marker, so visibility alone can't tell
    /// "I scrolled away" from "the reply just got taller".
    @State private var following = true
    @State private var throttle = CoachScrollThrottle()
    /// The iPad column. Local rather than in `chrome`, so an open column never pauses the tab swipe.
    @State private var inlineOpen = true
    @State private var showMemories = false

    private static let inlineWidth: CGFloat = 300

    private var compact: Bool { sizeClass != .regular }

    /// The sidebar and New chat need a server with threads; an old one keeps the single-chat screen.
    private var sidebarAvailable: Bool {
        #if DEBUG
        if Self.debugSidebar { return true }
        #endif
        return vm.features.threads
    }

    #if DEBUG
    /// `--coach-sidebar` / `--coach-demo-threads` show the sidebar without a thread-aware server (screenshots).
    private static let debugSidebar = CommandLine.arguments.contains("--coach-sidebar") || CoachSidebarDemo.requested
    #endif

    private var sidebarOpen: Bool { sidebarAvailable && (compact ? chrome.drawerOpen : inlineOpen) }

    private var motion: Animation? { NoopMotion.gated(NoopMotion.screen, reduced: reduceMotion) }

    var body: some View {
        GeometryReader { geo in
            let drawerWidth = compact ? min(320, geo.size.width * 0.84) : Self.inlineWidth
            let open = sidebarOpen
            let drawer = compact && open
            let inline = !compact && open
            ZStack(alignment: .topLeading) {
                // One transaction for the spacer and the column, so on iPad the chat slides with the sidebar
                // instead of snapping to its new width (also when the threads feature arrives and opens it). Keyed
                // on the inline column only: the iPhone drawer floats over the chat and must not animate it.
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: inline ? Self.inlineWidth : 0)
                    chatColumn
                        // The composer rests above the glass tab bar, which would otherwise cover it.
                        .padding(.bottom, bottomChromeInset)
                        .accessibilityHidden(drawer)
                }
                .animation(motion, value: inline)

                CoachDrawerLayer(store: vm.threadStore, chrome: chrome, compact: compact, open: open,
                                 width: drawerWidth, motion: motion, onShowMemories: { showMemories = true })
                    .equatable()
            }
        }
        .background(alignment: .top) { liquidScaffoldSky().ignoresSafeArea(edges: .top) }
        .task {
            vm.attach(repo: repo, engine: coachEngine, profile: profile)
            #if DEBUG
            await CoachSidebarDemo.seed(vm.threadStore)
            #endif
            // Unstructured, so leaving the tab mid-start (which cancels this `.task`) can't cancel the launch
            // refresh of the chat list and memories after `start()` has marked itself done. A later appear finds it
            // started (or still running) and returns at once.
            await Task { await vm.start() }.value
        }
        // Back in the foreground (often on a new day, with the app kept in memory overnight): a repeated start()
        // refreshes a starter set that is not from today, and retries a start that found the server unreachable.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task { await vm.start() }
        }
        // A question handed over by the Today launcher, Siri or `--coach-prompt`. It goes into a new chat (after
        // any reply in progress) and is cleared only once the chat has taken it.
        .task(id: coachEngine.pendingPrompt) {
            guard let prompt = coachEngine.pendingPrompt else { return }
            guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                coachEngine.pendingPrompt = nil
                return
            }
            vm.attach(repo: repo, engine: coachEngine, profile: profile)
            chrome.drawerOpen = false
            if vm.queuePrompt(prompt) { coachEngine.pendingPrompt = nil }
        }
        .onChange(of: sizeClass) { _, new in
            // The drawer belongs to the compact layout; leaving it must not leave the tab swipe paused.
            if new == .regular { chrome.drawerOpen = false }
        }
        .onChange(of: vm.threadId) { _, _ in following = true }
        .onChange(of: inputFocused) { _, focused in if focused { vm.noteUserInteraction() } }
        .onDisappear { chrome.drawerOpen = false }
        .sheet(isPresented: $showMemories) {
            // Values in, so a streaming flush (which redraws this view, and with it the sheet's content) leaves the
            // sheet alone unless the memories themselves changed.
            CoachMemorySheet(memories: vm.memories, isLoading: vm.isLoadingMemories,
                             refresh: { await vm.refreshMemories() },
                             forget: { await vm.forget($0) },
                             forgetAll: { await vm.forgetAllMemories() })
                .equatable()
        }
        #if DEBUG
        .onAppear {
            if CommandLine.arguments.contains("--coach-focus") { inputFocused = true }
            if CommandLine.arguments.contains("--coach-memories") { showMemories = true }
        }
        #endif
    }

    private var chatColumn: some View {
        VStack(spacing: 0) {
            header
            if vm.messages.isEmpty {
                if vm.threadPhase == .loading { loadingPlaceholder } else { welcome }
            } else {
                messageList
            }
            if let error = vm.errorMessage { errorBanner(error) }
            CoachComposer(vm: vm, isGenerating: vm.isGenerating, pendingImage: vm.pendingImage,
                          wasScrubbed: vm.wasScrubbed, focused: $inputFocused)
                // A new thread starts with an empty draft.
                .id(vm.threadId)
        }
    }

    private func toggleSidebar() {
        vm.noteUserInteraction()
        if compact {
            inputFocused = false
            chrome.drawerOpen.toggle()
        } else {
            withAnimation(motion) { inlineOpen.toggle() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            if sidebarAvailable {
                CoachHeaderButton(symbol: "sidebar.left",
                                  label: sidebarOpen ? "Hide chats" : "Show chats",
                                  identifier: "coachSidebarButton",
                                  action: toggleSidebar)
                    .padding(.trailing, -4)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("Sana")
                    .font(StrandFont.rounded(28))
                    .foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                subtitle
            }
            Spacer(minLength: 0)
            if sidebarAvailable {
                CoachHeaderButton(symbol: "square.and.pencil", label: "New chat", identifier: "coachNewChatButton") {
                    inputFocused = false
                    vm.newChat()
                }
                .disabled(!vm.canSwitchThreads)
            }
            BrandMark(size: 40, style: .tile)
        }
        // The round button's 44 pt hit area overhangs its 36 pt face; the face lines up with the screen margin.
        .padding(.leading, sidebarAvailable ? NoopMetrics.screenPadding - 4 : NoopMetrics.screenPadding)
        .padding(.trailing, NoopMetrics.screenPadding)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// The open chat's title, or "Your health assistant" until it has one.
    private var subtitle: some View {
        Group {
            if let title = vm.threadTitle, !title.isEmpty {
                Text(verbatim: title)
            } else {
                Text("Your health assistant")
            }
        }
        .font(StrandFont.caption)
        .foregroundStyle(StrandPalette.textTertiary)
        .lineLimit(1)
        .truncationMode(.tail)
        .contentTransition(.opacity)
        .animation(NoopMotion.gated(NoopMotion.value, reduced: reduceMotion), value: vm.threadTitle)
        .accessibilityIdentifier("coachThreadTitle")
    }

    // MARK: Empty state

    private var welcome: some View {
        GeometryReader { geo in
            ScrollView(showsIndicators: false) {
                VStack(spacing: 46) {
                    VStack(spacing: 8) {
                        Text("Hi, I'm Sana")
                            .font(StrandFont.rounded(24))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Text("Ask me anything about your health.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .multilineTextAlignment(.center)

                    if case .offline(let reason) = vm.connection { offlineCard(reason) }

                    let starters = suggestions
                    CoachSuggestionStack(prompts: starters.map(\.text), icons: starters.map(\.symbol)) { text in
                        guard let pick = starters.first(where: { $0.text == text }) else { return }
                        inputFocused = false
                        vm.selectSuggestion(pick)
                    }
                    .animation(NoopMotion.gated(NoopMotion.card, reduced: reduceMotion), value: starters)
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.top, 12)
                .padding(.bottom, 84)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)
            // Scrolling counts as touching the screen: a late server set no longer swaps in under the reader.
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { _ in vm.noteUserInteraction() })
        }
    }

    /// The view model's starters; the generic prompts only for the frame before it has attached.
    private var suggestions: [CoachStarterSuggestion] {
        if !vm.starterSuggestions.isEmpty { return vm.starterSuggestions }
        return CoachPrompts.suggestions.prefix(4).map { CoachStarterSuggestion(text: $0, kind: .explore) }
    }

    private var loadingPlaceholder: some View {
        VStack(spacing: 12) {
            ProgressView().tint(StrandPalette.accent)
            Text("Loading chat…")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coachThreadLoading")
    }

    private func offlineCard(_ reason: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: "wifi.slash").font(.system(size: 24)).foregroundStyle(StrandPalette.textTertiary)
            Text("Sana unavailable").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text(reason)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await vm.start() }
            } label: {
                Label("Try again", systemImage: "arrow.clockwise")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.accent)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(StrandPalette.accent.opacity(0.12), in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .frostedCardSurface(cornerRadius: 16)
    }

    // MARK: Messages

    private var messageList: some View {
        // The pills under the newest answer; their arrival (or the keyword fallback's) scrolls them into view.
        let lastFollowUps = vm.messages.last.map { vm.followUps(for: $0) } ?? []
        return ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    if vm.hasEarlier { loadEarlierRow(proxy) }
                    ForEach(vm.messages) { message in
                        let isLast = message.id == vm.messages.last?.id
                        CoachBubble(message: message,
                                    phase: message.isStreaming ? vm.phase : .idle,
                                    phaseLabel: message.isStreaming ? vm.phase.label : "",
                                    onRetry: message.didStall ? { vm.retryStalled() } : nil,
                                    followUps: isLast && !vm.isGenerating ? lastFollowUps : [],
                                    onFollowUp: { vm.send($0) },
                                    onCardSend: { text, state, submitted in
                                        vm.sendFromCard(text, messageId: message.id, state: state, submitted: submitted)
                                    },
                                    onCardState: { vm.cardStateChanged($0, messageId: message.id) })
                            .id(message.id)
                    }
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { following = true }
                }
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 6)
            }
            .scrollDismissesKeyboard(.interactively)
            .defaultScrollAnchor(.bottom)
            .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { drag in
                if drag.translation.height > 8 { following = false }
            })
            .onChange(of: vm.messages.last?.content) { _, _ in
                // Streaming flushes at ~25Hz; an animated scroll per flush is wasteful, so follow at ~10Hz.
                guard following, Date.timeIntervalSinceReferenceDate - throttle.last >= 0.1 else { return }
                throttle.last = Date.timeIntervalSinceReferenceDate
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.messages.last?.vizPhase) { _, _ in
                // A placeholder or finished visual grows the list under the reader; keep the end of the answer in view.
                guard following else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            // Keyed on the newest message, not the count: "Load earlier" adds rows above and must not jump.
            .onChange(of: vm.messages.last?.id) { _, _ in
                following = true
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: lastFollowUps) { _, pills in
                guard following, !pills.isEmpty else { return }
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.isGenerating) { _, generating in
                guard !generating else { return }
                // A chart or image is laid out just after the last token, so settle again once it has its height.
                for delay in [0.0, 0.35] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard following else { return }
                        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .onChange(of: inputFocused) { _, focused in
                guard focused else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
        // Each thread gets its own scroll position and lazy layout.
        .id(vm.threadId)
    }

    /// Pages in the previous messages and puts the one that was on top back on top, so the reader stays put.
    private func loadEarlierRow(_ proxy: ScrollViewProxy) -> some View {
        Button {
            guard !vm.isLoadingEarlier else { return }
            let anchor = vm.messages.first?.id
            following = false
            Task {
                await vm.loadEarlier()
                guard let anchor else { return }
                proxy.scrollTo(anchor, anchor: .top)
                DispatchQueue.main.async { proxy.scrollTo(anchor, anchor: .top) }
            }
        } label: {
            HStack(spacing: 8) {
                if vm.isLoadingEarlier {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up").font(.system(size: 11, weight: .semibold))
                }
                Text("Load earlier")
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(StrandPalette.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
        .disabled(vm.isLoadingEarlier)
        .frame(maxWidth: .infinity)
        .id("earlier")
        .accessibilityIdentifier("coachLoadEarlier")
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(StrandPalette.statusCritical).accessibilityHidden(true)
            Text(message)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.statusCritical)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button { vm.errorMessage = nil } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .frostedCardSurface(cornerRadius: 14)
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

// MARK: - Drawer

/// The scrim, the sidebar and the leftward close drag. A separate view that owns the drag state, so a drag frame
/// (60-120 a second) invalidates only this layer and never the chat column with its Markdown bubbles. Equatable,
/// because the memory callback is a closure SwiftUI can't compare, so a streaming flush in the chat skips it too.
private struct CoachDrawerLayer: View, Equatable {
    let store: CoachThreadStore
    let chrome: CoachChromeState
    /// The iPhone drawer rather than the iPad column.
    let compact: Bool
    let open: Bool
    let width: CGFloat
    let motion: Animation?
    let onShowMemories: () -> Void

    /// How far a leftward drag has pulled the open drawer.
    @GestureState private var drag: CGFloat = 0

    private var drawer: Bool { compact && open }

    static func == (a: CoachDrawerLayer, b: CoachDrawerLayer) -> Bool {
        a.store === b.store && a.chrome === b.chrome && a.compact == b.compact && a.open == b.open
            && a.width == b.width && a.motion == b.motion
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Button(action: close) {
                Color.black.opacity(0.32).ignoresSafeArea()
            }
            .buttonStyle(.plain)
            .opacity(drawer ? 1 : 0)
            .allowsHitTesting(drawer)
            .accessibilityLabel("Close chats")
            .accessibilityHidden(!drawer)
            .accessibilityIdentifier("coachSidebarScrim")
            .animation(motion, value: drawer)

            CoachSidebar(store: store, chrome: chrome, compact: compact, isOpen: open, onShowMemories: onShowMemories)
                .equatable()
                .frame(width: width)
                .frame(maxHeight: .infinity)
                .background {
                    NoopChromeSurface()
                        .overlay(alignment: .trailing) {
                            Rectangle().fill(StrandPalette.hairline).frame(width: 0.5)
                        }
                        .shadow(color: .black.opacity(drawer ? 0.22 : 0), radius: 22, x: 8, y: 0)
                        .ignoresSafeArea()
                }
                .offset(x: open ? min(0, drag) : -(width + 32))
                .allowsHitTesting(open)
                .accessibilityHidden(!open)
                .accessibilityAddTraits(drawer ? .isModal : [])
                .accessibilityAction(.escape) { close() }
                .animation(motion, value: open)
        }
        // The leftward close drag. While the drawer is open the scrim covers the chat and the sidebar the rest, so
        // this layer sees every drag. A mask instead of a conditional attachment keeps one view type in both states
        // (the same reason `RootTabView` masks its tab swipe).
        .simultaneousGesture(closeDrag, including: drawer ? .all : .subviews)
    }

    private var closeDrag: some Gesture {
        DragGesture(minimumDistance: 16)
            .updating($drag) { value, state, _ in
                let dx = value.translation.width
                guard abs(dx) > abs(value.translation.height) else { return }
                state = max(-width, min(0, dx))
            }
            .onEnded { value in
                let dx = value.translation.width, dy = value.translation.height
                guard abs(dx) > abs(dy) * 1.2 else { return }
                if dx < -60 || value.predictedEndTranslation.width < -width / 2 { close() }
            }
    }

    private func close() { chrome.drawerOpen = false }
}

// MARK: - Composer

/// The composer is its own view so keystrokes invalidate only this subtree, not the message list. The draft is
/// local state, committed to the view model only when sent; everything else arrives as explicit values so streamed
/// tokens don't re-render it.
private struct CoachComposer: View {
    let vm: CoachChatViewModel
    let isGenerating: Bool
    let pendingImage: Data?
    let wasScrubbed: Bool
    var focused: FocusState<Bool>.Binding

    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showFiles = false

    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil }

    var body: some View {
        VStack(spacing: 6) {
            if wasScrubbed {
                Label("Personal details were anonymized before sending", systemImage: "lock.shield")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 6)
            }
            VStack(spacing: 8) {
                if let data = pendingImage, let image = CoachImage.thumbnail(for: data, maxDimension: 56) {
                    attachment(image)
                }
                HStack(alignment: .bottom, spacing: 4) {
                    photoMenu
                    field
                    sendOrStop
                }
            }
            .padding(6)
            .background(NoopPanelSurface(cornerRadius: 26))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(focused.wrappedValue ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))
            Text("General wellness info, not medical advice.")
                .font(.system(size: 10, design: .rounded))
                .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 4)
        // Typing counts as touching the screen: a late server set of starters no longer swaps in.
        .onChange(of: text) { _, new in if !new.isEmpty { vm.noteUserInteraction() } }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) { vm.pendingImage = CoachImage.prepare(data) }
                photoItem = nil
            }
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
        .fileImporter(isPresented: $showFiles, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result, url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            if let data = try? Data(contentsOf: url) { vm.pendingImage = CoachImage.prepare(data) }
        }
        .fullScreenCover(isPresented: $showCamera) {
            CoachCameraPicker { image in vm.pendingImage = image.jpegData(compressionQuality: 1).flatMap(CoachImage.prepare) }
                .ignoresSafeArea()
        }
    }

    private func attachment(_ image: UIImage) -> some View {
        HStack(spacing: 10) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(StrandPalette.accent.opacity(0.5), lineWidth: 1))
            Text("Photo ready to send").font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            Spacer()
            Button { vm.pendingImage = nil } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 20)).foregroundStyle(StrandPalette.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove photo")
        }
        .padding(.horizontal, 6)
    }

    private var photoMenu: some View {
        Menu {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button { showCamera = true } label: { Label("Take Photo", systemImage: "camera") }
            }
            Button { showLibrary = true } label: { Label("Choose from Library", systemImage: "photo.on.rectangle") }
            Button { showFiles = true } label: { Label("Choose from Files", systemImage: "folder") }
        } label: {
            Image(systemName: pendingImage != nil ? "photo.fill" : "photo")
                .font(.system(size: 18))
                .foregroundStyle(pendingImage != nil ? StrandPalette.accent : StrandPalette.textSecondary)
                .frame(width: 38, height: 38)
        }
        .disabled(isGenerating)
        .accessibilityLabel("Attach image")
    }

    private var field: some View {
        TextField("Ask Sana anything…", text: $text, axis: .vertical)
            .textFieldStyle(.plain)
            .font(StrandFont.body)
            .foregroundStyle(StrandPalette.textPrimary)
            .lineLimit(1...5)
            .focused(focused)
            .submitLabel(.send)
            .onSubmit(commit)
            .padding(.vertical, 9)
            .accessibilityIdentifier("coachMessageField")
            .accessibilityLabel("Question")
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button { focused.wrappedValue = false } label: { Image(systemName: "keyboard.chevron.compact.down") }
                        .accessibilityLabel("Hide keyboard")
                }
            }
    }

    @ViewBuilder
    private var sendOrStop: some View {
        if isGenerating {
            Button { vm.stop() } label: {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(StrandPalette.statusCritical, in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop generating")
        } else {
            Button(action: commit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(NoopVisualStyle.mintDeep.opacity(canSend ? 1 : 0.55), in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("coachSendButton")
        }
    }

    /// Clears the draft only when the view model accepted it, so text survives a send that was refused.
    private func commit() {
        if vm.send(text) { text = "" }
    }
}

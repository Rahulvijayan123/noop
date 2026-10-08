import PhotosUI
import StrandDesign
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Holds the streaming-scroll timestamp as a class so updating it never invalidates the view body.
private final class CoachScrollThrottle { var last: TimeInterval = 0 }

struct CoachChatView: View {
    @EnvironmentObject private var repo: Repository
    @EnvironmentObject private var coachEngine: AICoachEngine
    @EnvironmentObject private var profile: ProfileStore
    @EnvironmentObject private var router: NavRouter
    /// Following the stream scrolls with a short ease; with Reduce Motion on it jumps instead.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @StateObject private var vm = CoachChatViewModel()
    @FocusState private var inputFocused: Bool
    /// True while the list should chase new content. Only the wearer dragging the list upward turns it off:
    /// content that grows past the viewport also hides the bottom marker, so visibility alone can't tell
    /// "I scrolled away" from "the reply just got taller".
    @State private var following = true
    @State private var throttle = CoachScrollThrottle()
    @State private var confirmingClear = false

    /// The reachability check said Sana cannot answer. Sending is off while it does (a send would only fail
    /// into the error banner); the draft field stays editable so nothing typed is lost.
    private var offlineReason: String? {
        if case .offline(let reason) = vm.connection { return reason }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if vm.messages.isEmpty { welcome } else { messageList }
            if let error = vm.errorMessage {
                errorBanner(error)
            } else if let reason = offlineReason {
                offlineNotice(reason)
            }
            CoachComposer(vm: vm, isGenerating: vm.isGenerating, pendingImage: vm.pendingImage,
                          wasScrubbed: vm.wasScrubbed, isOffline: offlineReason != nil, focused: $inputFocused)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
        .task {
            vm.attach(repo: repo, engine: coachEngine, profile: profile)
            await vm.start()
            #if DEBUG
            if CoachChatViewModel.demoTranscriptRequested { vm.loadDemoTranscript() }
            #endif
        }
        // A question handed over by the Today launcher; cleared before sending so a rebuild can't send it twice.
        .task(id: coachEngine.pendingPrompt) {
            guard let prompt = coachEngine.pendingPrompt, !prompt.isEmpty else { return }
            coachEngine.pendingPrompt = nil
            vm.attach(repo: repo, engine: coachEngine, profile: profile)
            vm.send(prompt)
        }
        .confirmationDialog("Clear this conversation?", isPresented: $confirmingClear, titleVisibility: .visible) {
            Button("Clear conversation", role: .destructive) { Task { await vm.clearConversation() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Sana keeps what it has remembered about you.")
        }
        #if DEBUG
        .onAppear { if CommandLine.arguments.contains("--coach-focus") { inputFocused = true } }
        #endif
    }

    // MARK: Header

    /// The tab-root header, drawn the same way `ScreenScaffold` draws it (title1 at the page margin, the
    /// settings button trailing). Sana cannot use the scaffold itself: its composer is pinned below a
    /// scrolling list.
    private var header: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space2) {
            Text("Sana")
                .font(StrandFont.title1)
                .foregroundStyle(StrandPalette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if !vm.messages.isEmpty {
                CoachHeaderButton(systemImage: "square.and.pencil", label: "New chat") { confirmingClear = true }
            }
            HeaderSettingsButton()
        }
        .frame(minHeight: NoopMetrics.minimumHitTarget)
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.top, NoopMetrics.space4)
        .padding(.bottom, NoopMetrics.space2)
        // A conversation scrolls under the pinned header; a hairline gives it a clean edge (an overlay, so
        // the header is the same height with or without it).
        .overlay(alignment: .bottom) {
            if !vm.messages.isEmpty {
                Rectangle().fill(StrandPalette.hairline).frame(height: NoopMetrics.hairlineWidth)
            }
        }
    }

    // MARK: Empty state

    private var welcome: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: NoopMetrics.space3) {
                CoachPromptList(prompts: suggestions, isEnabled: offlineReason == nil) { vm.send($0) }
                disclaimer
            }
            .padding(.horizontal, NoopMetrics.screenHPadding)
            .padding(.top, NoopMetrics.space3)
            .padding(.bottom, NoopMetrics.space4)
            .frame(maxWidth: 700, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
    }

    private var suggestions: [String] {
        Array(CoachPrompts.suggestions.prefix(4))
    }

    private var disclaimer: some View {
        Text("General wellness info, not medical advice.")
            .font(StrandFont.footnote)
            .foregroundStyle(StrandPalette.textTertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NoopMetrics.space1)
    }

    /// Why Sana cannot answer, with the one action that can fix it: Settings when cloud mode is off (trying
    /// again cannot help), otherwise a fresh reachability check.
    private func offlineNotice(_ reason: String) -> some View {
        let notConfigured = reason == CoachAPIError.notConfigured.errorDescription
        let action: InlineNotice.Action
        if notConfigured {
            action = InlineNotice.Action("Open Settings", perform: { router.openSettings() })
        } else {
            action = InlineNotice.Action("Try again", perform: { Task { await vm.start() } })
        }
        return InlineNotice(reason, title: String(localized: "Sana unavailable"), tone: .neutral, action: action)
            .padding(.horizontal, NoopMetrics.screenHPadding)
            .padding(.bottom, NoopMetrics.space2)
    }

    // MARK: Messages

    private var messageList: some View {
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: NoopMetrics.space5) {
                    ForEach(vm.messages) { message in
                        CoachBubble(message: message,
                                    phase: message.isStreaming ? vm.phase : .idle,
                                    onRetry: message.didStall ? { vm.retryStalled() } : nil,
                                    followUps: message.id == vm.messages.last?.id && !vm.isGenerating
                                        ? CoachFollowUps.forAnswer(message.content) : [],
                                    followUpsEnabled: offlineReason == nil,
                                    onFollowUp: { vm.send($0) })
                            .id(message.id)
                    }
                    disclaimer
                    Color.clear.frame(height: 1).id("bottom")
                        .onAppear { following = true }
                }
                .padding(.horizontal, NoopMetrics.screenHPadding)
                .padding(.top, NoopMetrics.space3)
                .padding(.bottom, NoopMetrics.space2)
                .frame(maxWidth: 700, alignment: .leading)
                .frame(maxWidth: .infinity)
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
            .onChange(of: vm.messages.count) { _, _ in
                following = true
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
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
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: NoopMetrics.space3) {
            Image(systemName: "exclamationmark.triangle")
                .font(StrandFont.icon(.row))
                .foregroundStyle(StrandPalette.statusCritical)
                .accessibilityHidden(true)
            Text(message)
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { vm.errorMessage = nil } label: {
                Image(systemName: "xmark")
                    .font(StrandFont.icon(.inline))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: NoopMetrics.minimumHitTarget, height: 20)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.leading, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space3)
        .background(NoopPanelSurface())
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.bottom, NoopMetrics.space2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error: \(message)")
    }
}

/// A round header control, the same size and fill as the settings button beside it.
private struct CoachHeaderButton: View {
    let systemImage: String
    let label: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(StrandFont.icon(.inline).weight(.medium))
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 36, height: 36)
                .background(Circle().fill(StrandPalette.surfaceInset))
                .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(label))
    }
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
    let isOffline: Bool
    var focused: FocusState<Bool>.Binding

    @State private var text = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var showFiles = false

    private static let radius: CGFloat = 22

    private var canSend: Bool {
        !isOffline && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || pendingImage != nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            if wasScrubbed {
                Label("Personal details were anonymized before sending", systemImage: "lock.shield")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, NoopMetrics.space1)
            }
            VStack(spacing: NoopMetrics.space2) {
                if let data = pendingImage, let image = CoachImage.thumbnail(for: data, maxDimension: 56) {
                    attachment(image)
                }
                HStack(alignment: .bottom, spacing: NoopMetrics.space1) {
                    photoMenu
                    field
                    sendOrStop
                }
            }
            .padding(NoopMetrics.space1)
            .background(NoopPanelSurface(cornerRadius: Self.radius))
            .overlay(RoundedRectangle(cornerRadius: Self.radius, style: .continuous)
                .strokeBorder(focused.wrappedValue ? StrandPalette.focusRing : StrandPalette.hairline, lineWidth: 1))
        }
        .padding(.horizontal, NoopMetrics.screenHPadding)
        .padding(.bottom, NoopMetrics.space2)
        .frame(maxWidth: 700)
        .frame(maxWidth: .infinity)
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
        HStack(spacing: NoopMetrics.space3) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: NoopMetrics.insetRadius, style: .continuous))
                .accessibilityLabel("Photo to send")
            Spacer(minLength: 0)
            Button { vm.pendingImage = nil } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(StrandFont.icon(.row))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .frame(width: NoopMetrics.minimumHitTarget, height: NoopMetrics.minimumHitTarget)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove photo")
        }
        .padding(.leading, NoopMetrics.space1)
        .padding(.top, NoopMetrics.space1)
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
                .font(StrandFont.icon(.row))
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
                roundGlyph("stop.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Stop generating")
        } else {
            Button(action: commit) {
                roundGlyph("arrow.up")
                    .opacity(canSend ? 1 : NoopButtonMetrics.disabledOpacity)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send message")
            .accessibilityIdentifier("coachSendButton")
        }
    }

    /// The send and stop controls: the one accent action in the composer, its glyph in the on-accent ink.
    private func roundGlyph(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(StrandFont.icon(.inline).weight(.semibold))
            .foregroundStyle(StrandPalette.goldDeepText)
            .frame(width: 38, height: 38)
            .background(StrandPalette.accent, in: Circle())
    }

    /// Clears the draft only when the view model accepted it, so text survives a send that was refused.
    private func commit() {
        guard canSend else { return }
        if vm.send(text) { text = "" }
    }
}

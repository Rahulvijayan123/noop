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
    @StateObject private var vm = CoachChatViewModel()
    @FocusState private var inputFocused: Bool
    /// True while the list should chase new content. Only the wearer dragging the list upward turns it off:
    /// content that grows past the viewport also hides the bottom marker, so visibility alone can't tell
    /// "I scrolled away" from "the reply just got taller".
    @State private var following = true
    @State private var throttle = CoachScrollThrottle()

    var body: some View {
        VStack(spacing: 0) {
            header
            if vm.messages.isEmpty { welcome } else { messageList }
            if let error = vm.errorMessage { errorBanner(error) }
            CoachComposer(vm: vm, isGenerating: vm.isGenerating, pendingImage: vm.pendingImage,
                          wasScrubbed: vm.wasScrubbed, focused: $inputFocused)
        }
        .background(alignment: .top) { liquidScaffoldSky().ignoresSafeArea(edges: .top) }
        .task {
            vm.attach(repo: repo, engine: coachEngine, profile: profile)
            await vm.start()
        }
        // A question handed over by the Today launcher; cleared before sending so a rebuild can't send it twice.
        .task(id: coachEngine.pendingPrompt) {
            guard let prompt = coachEngine.pendingPrompt, !prompt.isEmpty else { return }
            coachEngine.pendingPrompt = nil
            vm.attach(repo: repo, engine: coachEngine, profile: profile)
            vm.send(prompt)
        }
        #if DEBUG
        .onAppear { if CommandLine.arguments.contains("--coach-focus") { inputFocused = true } }
        #endif
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sana").font(StrandFont.rounded(28)).foregroundStyle(StrandPalette.textPrimary)
                Text("Your health assistant").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            BrandMark(size: 40, style: .tile)
        }
        .padding(.horizontal, NoopMetrics.screenPadding)
        .padding(.top, 14)
        .padding(.bottom, 8)
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

                    CoachSuggestionStack(prompts: suggestions) { vm.send($0) }
                }
                .padding(.horizontal, NoopMetrics.screenPadding)
                .padding(.top, 12)
                .padding(.bottom, 84)
                .frame(maxWidth: .infinity, minHeight: geo.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
            .scrollDismissesKeyboard(.immediately)
        }
    }

    private var suggestions: [String] {
        Array(CoachPrompts.suggestions.prefix(4))
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
        ScrollViewReader { proxy in
            ScrollView(showsIndicators: false) {
                LazyVStack(spacing: 14) {
                    ForEach(vm.messages) { message in
                        CoachBubble(message: message,
                                    phase: message.isStreaming ? vm.phase : .idle,
                                    phaseLabel: message.isStreaming ? vm.phase.label : "",
                                    onRetry: message.didStall ? { vm.retryStalled() } : nil,
                                    followUps: message.id == vm.messages.last?.id && !vm.isGenerating
                                        ? CoachFollowUps.forAnswer(message.content) : [],
                                    onFollowUp: { vm.send($0) })
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
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.messages.last?.vizPhase) { _, _ in
                // A placeholder or finished visual grows the list under the reader; keep the end of the answer in view.
                guard following else { return }
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.messages.count) { _, _ in
                following = true
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
            }
            .onChange(of: vm.isGenerating) { _, generating in
                guard !generating else { return }
                // A chart or image is laid out just after the last token, so settle again once it has its height.
                for delay in [0.0, 0.35] {
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                        guard following else { return }
                        withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
            .onChange(of: inputFocused) { _, focused in
                guard focused else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                    withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
            }
            .onAppear { proxy.scrollTo("bottom", anchor: .bottom) }
        }
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

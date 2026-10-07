import ImageIO
import MarkdownUI
import StrandDesign
import SwiftUI
import UIKit

// MARK: - Photos

enum CoachImage {
    /// Longest edge sent to the vision model. Plenty for reading a label or judging form, and keeps the upload small.
    private static let maxEdge: CGFloat = 1_600

    /// Downsamples and re-encodes as JPEG. Returns nil when the data isn't a decodable image.
    static func prepare(_ data: Data) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg).jpegData(compressionQuality: 0.8)
    }

    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.countLimit = 40
        return c
    }()

    /// Decoded-once thumbnail: decoding the full JPEG in `body` would repeat on every streamed token.
    static func thumbnail(for data: Data, maxDimension: CGFloat) -> UIImage? {
        let key = "\(data.count)-\(data.hashValue)-\(Int(maxDimension))" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxDimension * UIScreen.main.scale,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let image = UIImage(cgImage: cg)
        cache.setObject(image, forKey: key)
        return image
    }
}

struct CoachCameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ controller: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CoachCameraPicker
        init(_ parent: CoachCameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onCapture(image) }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}

// MARK: - Bubbles

struct CoachBubble: View {
    let message: CoachChatMessage
    let phase: CoachThinkingPhase
    let phaseLabel: String
    var onRetry: (() -> Void)?
    var followUps: [String] = []
    var onFollowUp: (String) -> Void = { _ in }
    @State private var containerWidth: CGFloat = 560
    /// Set once this bubble has shown the loading mosaic, so the visual that follows dissolves out of it.
    /// Visuals restored from history never saw it and appear plainly.
    @State private var vizWasGenerating = false

    private var maxBubbleWidth: CGFloat { min(containerWidth * 0.82, 560) }
    private var isUser: Bool { message.role == .user }
    private var hasText: Bool { !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isUser {
                Spacer(minLength: 0)
            } else {
                avatar
            }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 6) {
                if isUser { photo }
                if !isUser {
                    CoachThinkingTrace(message: message, phase: phase, phaseLabel: phaseLabel)
                        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                }
                if hasText { textBubble }
                if !isUser, !message.isStreaming {
                    if message.vizPhase == .generating {
                        CoachVizGeneratingView()
                            .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                            .transition(.opacity)
                    } else if let viz = message.viz {
                        Group {
                            CoachVizView(viz: viz)
                                .equatable()
                        }
                        .imageFXReveal(active: vizWasGenerating, cornerRadius: CoachVizMetric.radiusMD) {
                            vizWasGenerating = false
                        }
                        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                        .transition(.opacity)
                    }
                }
                if !isUser, message.didStall, let onRetry { retryButton(onRetry) }
                if !isUser, !message.isStreaming, !message.didStall, hasText, !followUps.isEmpty { followUpList }
            }

            if !isUser { Spacer(minLength: 0) }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: CoachBubbleWidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(CoachBubbleWidthKey.self) { containerWidth = $0 }
        .onAppear { if message.vizPhase == .generating { vizWasGenerating = true } }
        .onChange(of: message.vizPhase) { _, phase in if phase == .generating { vizWasGenerating = true } }
    }

    private var avatar: some View {
        BrandMark(size: 26, style: .tile)
            .padding(.top, 2)
            .accessibilityHidden(true)
    }

    private var followUpList: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Follow-ups").strandOverline()
            ForEach(Array(followUps.enumerated()), id: \.element) { index, prompt in
                Button { onFollowUp(prompt) } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.turn.down.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                        Text(prompt)
                            .font(StrandFont.caption)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Follow-up question: \(prompt)")
                .accessibilityIdentifier("coachFollowUp.\(index)")
            }
        }
        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
        .padding(.top, 2)
    }

    @ViewBuilder
    private var photo: some View {
        if let data = message.imageData, let image = CoachImage.thumbnail(for: data, maxDimension: 240) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: min(maxBubbleWidth, 240), maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(StrandPalette.accent.opacity(0.35), lineWidth: 0.5))
                .accessibilityLabel("Photo you sent")
        } else if message.hadImage {
            Label("Photo", systemImage: "photo")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }

    private var textBubble: some View {
        Group {
            if isUser {
                Text(message.content)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Markdown(message.content)
                    .markdownTheme(.strand)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: maxBubbleWidth, alignment: isUser ? .trailing : .leading)
        .contextMenu {
            Button { UIPasteboard.general.string = message.content } label: { Label("Copy", systemImage: "doc.on.doc") }
            ShareLink(item: message.content) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUser ? "You said: \(message.content)" : "Sana said: \(message.content)")
    }

    private func retryButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label("Retry", systemImage: "arrow.clockwise")
                .font(StrandFont.caption)
                .foregroundStyle(StrandPalette.accent)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(StrandPalette.accent.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

private struct CoachBubbleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 560
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// Long answers can take a minute or two; a single static label reads as a hang, so the wording keeps moving.
struct CoachElapsedLabel: View {
    let base: String
    @State private var seconds = 0
    @State private var timer: Timer?

    private var text: String {
        switch seconds {
        case ..<15: return base
        case ..<40: return "\(base) Reviewing your data."
        case ..<75: return "\(base) Working through a detailed answer."
        default: return "\(base) Still working (\(seconds)s)."
        }
    }

    var body: some View {
        Text(text)
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
            .onAppear {
                seconds = 0
                timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in seconds += 1 }
            }
            .onDisappear { timer?.invalidate(); timer = nil }
    }
}

// MARK: - Suggestions

struct CoachSuggestionStack: View {
    let prompts: [String]
    /// One SF Symbol per prompt (a starter's kind); without it, or past its end, the fixed rotation is used.
    var icons: [String]? = nil
    /// Each row is identified `<identifierPrefix>.<index>` for UI tests.
    var identifierPrefix = "coachSuggestion"
    let onSend: (String) -> Void

    private static let icons = ["moon", "waveform.path.ecg", "heart", "chart.bar"]

    private func icon(at index: Int) -> String {
        if let icons, index < icons.count { return icons[index] }
        return Self.icons[index % Self.icons.count]
    }

    var body: some View {
        VStack(spacing: 10) {
            ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                Button { onSend(prompt) } label: {
                    HStack(spacing: 12) {
                        Image(systemName: icon(at: index))
                            .font(.system(size: 16))
                            .foregroundStyle(StrandPalette.accent)
                            .frame(width: 24)
                        Text(prompt)
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 4)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 16)
                    .contentShape(Rectangle())
                    .frostedCardSurface(cornerRadius: 16)
                }
                .buttonStyle(LiquidPressStyle())
                .accessibilityLabel("Suggested prompt: \(prompt)")
                .accessibilityIdentifier("\(identifierPrefix).\(index)")
            }
        }
    }
}

// MARK: - Header controls

/// A round header control in the chrome the Today header buttons use: system Liquid Glass on iOS 26, a thin
/// material circle before it. The face is 36 pt and the hit area 44 pt.
struct CoachHeaderButton: View {
    let symbol: String
    let label: LocalizedStringKey
    let identifier: String
    let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(width: 36, height: 36)
                .coachHeaderGlass()
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(LiquidPressStyle())
        .opacity(isEnabled ? 1 : StrandPalette.disabledOpacity)
        .accessibilityLabel(label)
        .accessibilityIdentifier(identifier)
    }
}

private extension View {
    @ViewBuilder
    func coachHeaderGlass() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: Circle())
        } else {
            self
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(.white.opacity(0.16), lineWidth: 0.8))
        }
    }
}

// MARK: - Memory

/// "What Sana remembers": the saved facts (up to 200, newest ranking first), each with Forget, and Forget all.
/// Forgetting touches memory only; the chats themselves stay in the history.
struct CoachMemorySheet: View {
    @ObservedObject var vm: CoachChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForgetAll = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.memories.isEmpty {
                    if vm.isLoadingMemories {
                        ProgressView()
                            .tint(StrandPalette.accent)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        empty
                    }
                } else {
                    list
                }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("What Sana remembers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(StrandPalette.accent)
                }
            }
            .confirmationDialog("Forget everything Sana remembers about you?", isPresented: $confirmForgetAll,
                                titleVisibility: .visible) {
                Button("Forget all", role: .destructive) { Task { await vm.forgetAllMemories() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sana stops using these facts in its answers. Your chats stay in your history.")
            }
            .task { await vm.refreshMemories() }
        }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Image(systemName: "brain").font(.system(size: 30)).foregroundStyle(StrandPalette.textTertiary)
            Text("Nothing remembered yet").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
            Text("Tell Sana about your goals, injuries or routines and it will remember them in your next chats.")
                .font(StrandFont.subhead)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        List {
            Section {
                ForEach(vm.memories) { memory in
                    row(memory)
                        .listRowBackground(StrandPalette.surfaceRaised)
                        .swipeActions {
                            Button(role: .destructive) { Task { await vm.forget(memory) } } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                        .contextMenu {
                            Button(role: .destructive) { Task { await vm.forget(memory) } } label: {
                                Label("Forget", systemImage: "trash")
                            }
                        }
                        .accessibilityAction(named: "Forget") { Task { await vm.forget(memory) } }
                }
            } header: {
                Text("Sana keeps these facts between chats and uses the ones that matter for each question. Forgetting one takes it out of Sana's memory; your chats stay in your history.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .textCase(nil)
                    .padding(.bottom, 4)
            } footer: {
                if vm.memories.count >= CoachChatViewModel.memoryListLimit {
                    Text("Showing the first \(vm.memories.count) memories.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            Section {
                Button(role: .destructive) { confirmForgetAll = true } label: {
                    Label("Forget all", systemImage: "trash")
                        .font(StrandFont.body)
                }
                .listRowBackground(StrandPalette.surfaceRaised)
                .accessibilityIdentifier("coachForgetAllMemories")
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await vm.refreshMemories() }
    }

    private func row(_ memory: CoachMemory) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(memory.content).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
            HStack(spacing: 6) {
                Text(memory.topic.capitalized)
                if memory.pinned == true {
                    Label("Always considered", systemImage: "pin.fill")
                        .labelStyle(.titleAndIcon)
                }
            }
            .font(StrandFont.caption)
            .foregroundStyle(StrandPalette.textTertiary)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

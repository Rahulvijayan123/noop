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
    @State private var containerWidth: CGFloat = 560

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
                        CoachVizView(viz: viz)
                            .equatable()
                            .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
                if !isUser, message.didStall, let onRetry { retryButton(onRetry) }
            }

            if !isUser { Spacer(minLength: 0) }
        }
        .background(GeometryReader { geo in
            Color.clear.preference(key: CoachBubbleWidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(CoachBubbleWidthKey.self) { containerWidth = $0 }
    }

    private var avatar: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(StrandPalette.accent)
            .frame(width: 26, height: 26)
            .background(Circle().fill(StrandPalette.accent.opacity(0.16)))
            .padding(.top, 2)
            .accessibilityHidden(true)
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
        .accessibilityLabel(isUser ? "You said: \(message.content)" : "Coach said: \(message.content)")
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

struct CoachTypingDots: View {
    @State private var active = 0
    @State private var timer: Timer?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(StrandPalette.accent)
                    .frame(width: 7, height: 7)
                    .scaleEffect(active == i ? (reduceMotion ? 1.15 : 1.35) : 0.85)
                    .opacity(active == i ? 1 : 0.3)
                    .animation(.easeInOut(duration: 0.22), value: active)
            }
        }
        .frame(height: 11)
        .accessibilityHidden(true)
        .onAppear {
            timer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { _ in active = (active + 1) % 3 }
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }
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
    let onSend: (String) -> Void

    private static let icons = ["heart.text.square", "figure.run", "moon.zzz", "chart.xyaxis.line", "bolt.heart"]

    var body: some View {
        VStack(spacing: 8) {
            Text("Suggested").strandOverline()
            VStack(spacing: 0) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                    Button { onSend(prompt) } label: {
                        HStack(spacing: 10) {
                            Image(systemName: Self.icons[index % Self.icons.count])
                                .font(.system(size: 12))
                                .foregroundStyle(StrandPalette.accent)
                                .frame(width: 24)
                            Text(prompt)
                                .font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textSecondary)
                                .lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Spacer(minLength: 4)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 13)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(LiquidPressStyle())
                    .accessibilityLabel("Suggested prompt: \(prompt)")

                    if index < prompts.count - 1 {
                        Divider().overlay(StrandPalette.hairline).padding(.leading, 48)
                    }
                }
            }
            .frostedCardSurface(cornerRadius: 16)
        }
    }
}

// MARK: - Memory

struct CoachMemorySheet: View {
    @ObservedObject var vm: CoachChatViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForgetAll = false

    var body: some View {
        NavigationStack {
            Group {
                if vm.memories.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "brain").font(.system(size: 30)).foregroundStyle(StrandPalette.textTertiary)
                        Text("Nothing remembered yet").font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                        Text("Tell Coach about your goals, injuries, or routines and it will remember them for next time.")
                            .font(StrandFont.subhead)
                            .foregroundStyle(StrandPalette.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(32)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(vm.memories) { memory in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(memory.content).font(StrandFont.body).foregroundStyle(StrandPalette.textPrimary)
                                Text(memory.topic.capitalized).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                            }
                            .listRowBackground(StrandPalette.surfaceRaised)
                            .swipeActions {
                                Button(role: .destructive) { Task { await vm.forget(memory) } } label: { Label("Forget", systemImage: "trash") }
                            }
                        }
                    }
                    .scrollContentBackground(.hidden)
                }
            }
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle("What Coach remembers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if !vm.memories.isEmpty { Button("Forget all", role: .destructive) { confirmForgetAll = true } }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Forget everything Coach remembers about you?", isPresented: $confirmForgetAll, titleVisibility: .visible) {
                Button("Forget all", role: .destructive) { Task { await vm.forgetAllMemories() } }
                Button("Cancel", role: .cancel) {}
            }
            .task { await vm.refreshMemories() }
        }
    }
}

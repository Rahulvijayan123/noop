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

/// One turn of the conversation. The user's words sit in an accent bubble at the trailing edge; Sana's reply is
/// plain text on the page at full width, so a chart under it is the only card in the turn. Who is speaking is
/// carried by alignment, not by an avatar.
struct CoachBubble: View {
    let message: CoachChatMessage
    let phase: CoachThinkingPhase
    var onRetry: (() -> Void)?
    var followUps: [String] = []
    var followUpsEnabled = true
    var onFollowUp: (String) -> Void = { _ in }
    @State private var containerWidth: CGFloat = 560
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The user bubble's widest; replies use the whole column.
    private var maxBubbleWidth: CGFloat { min(containerWidth * 0.82, 560) }
    private var isUser: Bool { message.role == .user }
    private var hasText: Bool { !message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Group {
            if isUser { userTurn } else { assistantTurn }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .background(GeometryReader { geo in
            Color.clear.preference(key: CoachBubbleWidthKey.self, value: geo.size.width)
        })
        .onPreferenceChange(CoachBubbleWidthKey.self) { containerWidth = $0 }
    }

    private var userTurn: some View {
        VStack(alignment: .trailing, spacing: NoopMetrics.space2) {
            photo
            if hasText {
                Text(message.content)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.goldDeepText)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.accent,
                                in: RoundedRectangle(cornerRadius: CoachChatMetrics.bubbleRadius, style: .continuous))
                    .frame(maxWidth: maxBubbleWidth, alignment: .trailing)
                    .modifier(CoachMessageActions(text: message.content, spoken: "You said: \(message.content)"))
            }
        }
    }

    private var assistantTurn: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space3) {
            CoachThinkingTrace(message: message, phase: phase, part: .working)
            if hasText {
                Markdown(message.content)
                    .markdownTheme(.strand)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .modifier(CoachMessageActions(text: message.content, spoken: "Sana said: \(message.content)"))
            }
            if !message.isStreaming {
                if message.vizPhase == .generating {
                    CoachVizGeneratingView()
                        .transition(.opacity)
                } else if let viz = message.viz {
                    CoachVizView(viz: viz)
                        .equatable()
                        .transition(.opacity)
                }
            }
            if message.didStall, let onRetry {
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(StrandFont.subhead.weight(.medium))
                        .foregroundStyle(StrandPalette.accent)
                        .frame(minHeight: NoopMetrics.minimumHitTarget)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            CoachThinkingTrace(message: message, phase: phase, part: .summary)
            if !message.isStreaming, !message.didStall, hasText, !followUps.isEmpty {
                CoachPromptList(prompts: followUps, isEnabled: followUpsEnabled, accessibilityPrefix: "Follow-up question", onSend: onFollowUp)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.25), value: message.vizPhase)
    }

    @ViewBuilder
    private var photo: some View {
        if let data = message.imageData, let image = CoachImage.thumbnail(for: data, maxDimension: 240) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: min(maxBubbleWidth, 240), maxHeight: 180)
                .clipShape(RoundedRectangle(cornerRadius: CoachChatMetrics.bubbleRadius, style: .continuous))
                .accessibilityLabel("Photo you sent")
        } else if message.hadImage {
            Label("Photo", systemImage: "photo")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textTertiary)
        }
    }
}

enum CoachChatMetrics {
    /// One radius for the user's bubble and photos (kit candidate `NoopMetrics.bubbleRadius`).
    static let bubbleRadius: CGFloat = 18
}

/// Copy / share on a long press, text selection, and one VoiceOver element saying who spoke.
private struct CoachMessageActions: ViewModifier {
    let text: String
    let spoken: String

    func body(content: Content) -> some View {
        content
            .textSelection(.enabled)
            .contextMenu {
                Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
                ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(spoken)
    }
}

private struct CoachBubbleWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 560
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

// MARK: - Suggested prompts

/// Questions to ask, as rows of one list card: the four suggestions on an empty chat and the follow-ups under
/// an answer. A tap sends the question as written.
struct CoachPromptList: View {
    let prompts: [String]
    var isEnabled = true
    var accessibilityPrefix = "Suggested prompt"
    let onSend: (String) -> Void

    var body: some View {
        NoopCard(padding: 0) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(prompts.enumerated()), id: \.offset) { index, prompt in
                    if index > 0 { NoopListDivider() }
                    Button { onSend(prompt) } label: {
                        HStack(spacing: NoopMetrics.space3) {
                            Text(prompt)
                                .font(StrandFont.body)
                                .foregroundStyle(isEnabled ? StrandPalette.textPrimary : StrandPalette.textTertiary)
                                .multilineTextAlignment(.leading)
                                .lineLimit(3)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right")
                                .font(StrandFont.icon(.inline))
                                .foregroundStyle(StrandPalette.textTertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.horizontal, NoopMetrics.cardPadding)
                        .padding(.vertical, NoopMetrics.space3)
                        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled)
                    .accessibilityLabel("\(accessibilityPrefix): \(prompt)")
                }
            }
        }
    }
}

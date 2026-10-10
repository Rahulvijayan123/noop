import ImageIO
import MarkdownUI
import OpenUILang
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
    /// A card's button or form: (message, card state, what was submitted) → whether it was sent.
    var onCardSend: (String, [String: Value], String?) -> Bool = { _, _, _ in false }
    var onCardState: ([String: Value]) -> Void = { _ in }
    @State private var containerWidth: CGFloat = 560
    /// Set once this bubble has shown the loading mosaic, so the visual that follows dissolves out of it.
    /// Visuals restored from history never saw it and appear plainly.
    @State private var vizWasGenerating = false

    private var maxBubbleWidth: CGFloat { min(containerWidth * 0.82, 560) }
    private var isUser: Bool { message.role == .user }

    /// The answer's prose and its interactive card: split out of the streaming text, or from `meta.ui` once saved.
    private var parts: (prose: String, card: String?, after: String) {
        guard !isUser else { return (message.content, nil, "") }
        if message.isStreaming {
            let split = CoachGenUI.split(message.content, streaming: true)
            return (split.before, split.source, split.after)
        }
        if let ui = message.ui { return (ui.contentIsSummary == true ? "" : message.content, ui.source, "") }
        return (message.content, nil, "")
    }

    private static func trimmed(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        let parts = self.parts
        let prose = Self.trimmed(parts.prose)
        let after = Self.trimmed(parts.after)
        let card = parts.card.flatMap { Self.trimmed($0).isEmpty ? nil : $0 }
        let cardPlacesVisual = card.map { $0.contains("Visual(") } ?? false
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
                if !prose.isEmpty { textBubble(prose) }
                if let card {
                    CoachGenUICard(source: card, streaming: message.isStreaming, persisted: message.ui?.state,
                                   submitted: message.ui?.submitted,
                                   interactive: !message.isStreaming && !message.didStall && !message.blocked,
                                   visual: cardPlacesVisual ? AnyView(visual) : nil,
                                   onSend: onCardSend, onStateChange: onCardState)
                        .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                }
                if !after.isEmpty { textBubble(after) }
                if !isUser, !message.isStreaming, !cardPlacesVisual { visual }
                if !isUser, message.didStall, let onRetry { retryButton(onRetry) }
                if !isUser, !message.isStreaming, !message.didStall, !prose.isEmpty || card != nil, !followUps.isEmpty {
                    followUpList
                }
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

    /// The fact-checked visual: the img-fx mosaic while it is designed, then the chart dissolving out of it.
    @ViewBuilder
    private var visual: some View {
        if message.vizPhase == .generating {
            CoachVizGeneratingView()
                .frame(maxWidth: maxBubbleWidth, alignment: .leading)
                .transition(.opacity)
        } else if let viz = message.viz {
            Group {
                CoachVizView(viz: viz)
                    .equatable()
            }
            .environment(\.coachSandboxSend, message.isStreaming ? nil : onFollowUp)
            .imageFXReveal(active: vizWasGenerating, cornerRadius: CoachVizMetric.radiusMD) {
                vizWasGenerating = false
            }
            .frame(maxWidth: maxBubbleWidth, alignment: .leading)
            .transition(.opacity)
        }
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

    private func textBubble(_ text: String) -> some View {
        Group {
            if isUser {
                Text(text)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.surfaceBase)
                    .multilineTextAlignment(.leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(StrandPalette.accent, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            } else {
                Markdown(text)
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
            Button { UIPasteboard.general.string = text } label: { Label("Copy", systemImage: "doc.on.doc") }
            ShareLink(item: text) { Label("Share", systemImage: "square.and.arrow.up") }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(isUser ? "You said: \(text)" : "Sana said: \(text)")
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
    func coachHeaderGlass() -> some View {
        LiquidGlassSwitch {
            self.noopGlassControl(in: Circle())
        } original: {
            self.originalCoachHeaderGlass()
        }
    }

    @ViewBuilder
    func originalCoachHeaderGlass() -> some View {
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

/// "What Sana remembers": the saved facts (up to 200) grouped by topic, each with Edit and Forget, plus Add a
/// memory and Forget all. An edit is stored on the server (the list, every cached context and the next chat follow);
/// forgetting touches memory only, and the chats themselves stay in the history.
///
/// It takes the memory state as values, not the view model: observing the view model would rebuild the sheet and
/// its 200-row list on every streaming flush of a reply. The presenter re-creates it on each of its own redraws, so
/// it is `Equatable` on those values (the actions are closures SwiftUI can't compare) and shown with `.equatable()`.
struct CoachMemorySheet: View, Equatable {
    let memories: [CoachMemory]
    let isLoading: Bool
    let refresh: () async -> Void
    let forget: (CoachMemory) async -> Void
    let forgetAll: () async -> Void
    let edit: (CoachMemory, String, String) async -> CoachMemoryEditOutcome
    let add: (String, String) async -> CoachMemoryEditOutcome
    @Environment(\.dismiss) private var dismiss
    @State private var confirmForgetAll = false
    @State private var editing: CoachMemoryEditTarget?

    static func == (a: CoachMemorySheet, b: CoachMemorySheet) -> Bool {
        a.isLoading == b.isLoading && a.memories == b.memories
    }

    var body: some View {
        NavigationStack {
            Group {
                if memories.isEmpty {
                    if isLoading {
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
                Button("Forget all", role: .destructive) { Task { await forgetAll() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Sana stops using these facts in its answers. Your chats stay in your history.")
            }
            .sheet(item: $editing) { target in
                editor(for: target)
            }
            .task { await refresh() }
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
            Button { editing = .add } label: {
                Label("Add a memory", systemImage: "plus")
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.accent)
            }
            .padding(.top, 8)
            .accessibilityIdentifier("coachAddMemory")
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        let sections = CoachMemory.sections(memories)
        return List {
            Section {
                EmptyView()
            } header: {
                Text("Sana keeps these facts between chats and uses the ones that matter for each question. Tap one to correct it. Forgetting one takes it out of Sana's memory; your chats stay in your history.")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .textCase(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(sections) { section in
                Section {
                    ForEach(section.memories) { memory in
                        row(memory)
                            .listRowBackground(StrandPalette.surfaceRaised)
                            .swipeActions(edge: .trailing) {
                                Button(role: .destructive) { Task { await forget(memory) } } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                                if memory.version != nil {
                                    Button { editing = .edit(memory.id) } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                    .tint(StrandPalette.accent)
                                }
                            }
                            .contextMenu {
                                if memory.version != nil {
                                    Button { editing = .edit(memory.id) } label: {
                                        Label("Edit", systemImage: "pencil")
                                    }
                                }
                                Button(role: .destructive) { Task { await forget(memory) } } label: {
                                    Label("Forget", systemImage: "trash")
                                }
                            }
                            .accessibilityActions {
                                if memory.version != nil {
                                    Button("Edit") { editing = .edit(memory.id) }
                                }
                                Button("Forget") { Task { await forget(memory) } }
                            }
                    }
                } header: {
                    Text(section.title)
                        .font(StrandFont.caption.weight(.semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .textCase(nil)
                }
            }

            if memories.count >= CoachChatViewModel.memoryListLimit {
                Section {
                    EmptyView()
                } footer: {
                    Text("Showing the first \(memories.count) memories.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }

            Section {
                Button { editing = .add } label: {
                    Label("Add a memory", systemImage: "plus")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.accent)
                }
                .listRowBackground(StrandPalette.surfaceRaised)
                .accessibilityIdentifier("coachAddMemory")
                Button(role: .destructive) { confirmForgetAll = true } label: {
                    // One colour for the title and the icon: the role alone reddens only the title in a List and
                    // leaves the icon in the tint.
                    Label("Forget all", systemImage: "trash")
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
                .listRowBackground(StrandPalette.surfaceRaised)
                .accessibilityIdentifier("coachForgetAllMemories")
            }
        }
        .scrollContentBackground(.hidden)
        .refreshable { await refresh() }
    }

    private func row(_ memory: CoachMemory) -> some View {
        Button { if memory.version != nil { editing = .edit(memory.id) } } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(memory.content)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                if memory.pinned == true || memory.changedAt != nil {
                    HStack(spacing: 8) {
                        if memory.pinned == true {
                            Label("Always considered", systemImage: "pin.fill")
                                .labelStyle(.titleAndIcon)
                        }
                        if let changed = memory.changedAt {
                            Text(changed, format: .dateTime.day().month(.abbreviated).year())
                        }
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
                if memory.isUsersOwn {
                    Label("Your words", systemImage: "pencil")
                        .labelStyle(.titleAndIcon)
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("coachMemoryRow.\(memory.id)")
    }

    /// The editor for one row (looked up again on every redraw, so after a conflict it edits the version the list
    /// now holds) or for a new fact.
    @ViewBuilder
    private func editor(for target: CoachMemoryEditTarget) -> some View {
        switch target {
        case .add:
            CoachMemoryEditor(isNew: true, memory: nil) { text, topic in await add(text, topic) }
        case .edit(let id):
            let latest = memories.first { $0.id == id }
            CoachMemoryEditor(isNew: false, memory: latest) { text, topic in
                guard let latest else { return .gone }
                return await edit(latest, text, topic)
            }
            .id(id)
        }
    }
}

/// What the memory editor is open for.
enum CoachMemoryEditTarget: Identifiable, Hashable {
    case add
    case edit(String)

    var id: String {
        switch self {
        case .add: return "add"
        case .edit(let id): return id
        }
    }
}

/// The memory editor: the fact in the user's own words and its topic. The text is checked as the phone checks any
/// stored line before it reaches a prompt; Sana keeps an edited memory as the user wrote it.
struct CoachMemoryEditor: View {
    /// Adding a new fact rather than editing one.
    let isNew: Bool
    /// The row as the list holds it now: after a conflict, the version stored on the server; nil once it is gone.
    let memory: CoachMemory?
    let save: (String, String) async -> CoachMemoryEditOutcome
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var topic: String
    @State private var saving = false
    @State private var notice: String?
    @State private var conflict = false
    @State private var gone = false
    @FocusState private var focused: Bool

    init(isNew: Bool, memory: CoachMemory?, save: @escaping (String, String) async -> CoachMemoryEditOutcome) {
        self.isNew = isNew
        self.memory = memory
        self.save = save
        _text = State(initialValue: memory?.content ?? "")
        _topic = State(initialValue: memory?.topic ?? "general")
    }

    private var trimmed: String { CoachModelText.collapsed(text) }
    private var problem: String? { trimmed.isEmpty ? nil : CoachChatViewModel.memoryProblem(trimmed) }
    private var unchanged: Bool { memory.map { trimmed == $0.content && topic == $0.topic } ?? false }
    private var canSave: Bool { !saving && !gone && (isNew || memory != nil) && !trimmed.isEmpty && problem == nil && !unchanged }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("A fact about you, like \"I swim on Thursdays\"", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                        .font(StrandFont.body)
                        .foregroundStyle(StrandPalette.textPrimary)
                        .focused($focused)
                        .accessibilityIdentifier("coachMemoryEditorText")
                        .listRowBackground(StrandPalette.surfaceRaised)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        if let problem {
                            Text(problem).foregroundStyle(StrandPalette.statusCritical)
                        } else if trimmed.utf16.count > CoachMemory.maxLength - 100 {
                            Text("\(trimmed.utf16.count) of \(CoachMemory.maxLength) characters")
                        }
                        if conflict, let stored = memory?.content {
                            Text("This memory changed on another device. Sana now has: \"\(stored)\". Save again to replace it with yours.")
                                .foregroundStyle(StrandPalette.textSecondary)
                        }
                        if let notice {
                            Text(notice).foregroundStyle(gone ? StrandPalette.statusCritical : StrandPalette.textSecondary)
                        }
                    }
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
                }
                Section {
                    Picker("Topic", selection: $topic) {
                        ForEach(CoachMemory.topics, id: \.self) { Text($0.capitalized).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .tint(StrandPalette.accent)
                    .listRowBackground(StrandPalette.surfaceRaised)
                } footer: {
                    Text("Sana keeps this in your words and uses it in your next chats.")
                        .font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.textTertiary)
                }
            }
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
            .navigationTitle(isNew ? "Add a memory" : "Edit memory")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .foregroundStyle(StrandPalette.accent)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if saving {
                        ProgressView().tint(StrandPalette.accent)
                    } else {
                        Button("Save") { Task { await submit() } }
                            .disabled(!canSave)
                            .foregroundStyle(canSave ? StrandPalette.accent : StrandPalette.textTertiary)
                            .accessibilityIdentifier("coachMemoryEditorSave")
                    }
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }

    private func submit() async {
        saving = true
        defer { saving = false }
        notice = nil
        conflict = false
        switch await save(trimmed, topic) {
        case .saved:
            dismiss()
        case .changedElsewhere:
            // The list now holds the stored version; the footer quotes it from `memory`, which follows the list.
            conflict = true
        case .gone:
            gone = true
            notice = "This memory was forgotten on another device, so there is nothing to edit."
        case .failed(let message):
            notice = message
        }
    }
}

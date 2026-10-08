import OpenUILang
import StrandDesign
import SwiftUI
import UIKit

// Sana's interactive cards: the SwiftUI renderer for `CoachGenUI.library`. A card streams in with its answer
// (parsed incrementally), shows the img-fx mosaic until it has enough to show, then dissolves in with the same
// reveal the visuals use. Inputs keep their values in the card's state store, which is saved with the message;
// buttons and forms send the user's next message.

// MARK: - Model

@MainActor
final class CoachGenUIModel: ObservableObject {
    @Published private(set) var tree: Element?
    @Published private(set) var store = StateStore()
    /// Forms whose submit was tried: their fields show validation errors from then on.
    @Published private(set) var attempted: Set<String> = []
    @Published private(set) var submitted: Set<String> = []

    var onStateChange: (([String: Value]) -> Void)?

    private var root: Element?
    private var source: String?
    private let stream = StreamParser(library: CoachGenUI.library)
    private var restored = false

    func load(source: String, streaming: Bool, persisted: [String: Value]?, submitted saved: [String]?) {
        if !restored {
            restored = true
            submitted = Set(saved ?? [])
        } else if let saved {
            submitted.formUnion(saved)
        }
        guard source != self.source else { return }
        let first = self.source == nil
        self.source = source
        let result = streaming ? stream.set(source) : CoachGenUI.parse(source)
        if result.root != nil || !streaming { root = result.root }
        store.initialize(defaults: result.stateDeclarations, persisted: first ? persisted ?? [:] : [:])
        evaluate()
    }

    /// Enough to show: the finished card, or a streaming one with at least two pieces in it.
    func isPresentable(streaming: Bool) -> Bool {
        guard let tree else { return false }
        return !streaming || (tree["children"].arrayValue?.count ?? 0) >= 2
    }

    var containsVisual: Bool { tree.map { Self.contains("Visual", in: .element($0)) } ?? false }

    static func contains(_ type: String, in value: Value) -> Bool {
        switch value {
        case .element(let el): return el.typeName == type || el.props.values.contains { contains(type, in: $0) }
        case .array(let items): return items.contains { contains(type, in: $0) }
        default: return false
        }
    }

    private func evaluate() {
        tree = root.map { Evaluator(library: CoachGenUI.library, store: store).evaluate($0) }
    }

    // MARK: State

    func value(_ key: String) -> Value { store.get(key) }

    func set(_ key: String, _ value: Value) {
        guard store.set(key, value) else { return }
        evaluate()
        onStateChange?(store.values)
    }

    /// Where an input keeps its value: its `$variable` when bound, else a key scoped to its form.
    static func key(for input: Element, form: String?) -> String {
        if case .binding(let name) = input["value"] { return name }
        let name = input["name"].stringValue ?? "field"
        return form.map { "form:\($0)/\(name)" } ?? "field:\(name)"
    }

    /// An input's value, with its declared default until the user changes it.
    func current(_ input: Element, form: String?) -> Value {
        let stored = value(Self.key(for: input, form: form))
        if !stored.isNull { return stored }
        switch input.typeName {
        case "Slider", "Stepper":
            return input["defaultValue"].isNull ? input["min"] : input["defaultValue"]
        case "RadioGroup", "Chips":
            return input["defaultValue"]
        case "CheckBoxGroup":
            var checked: [String: Value] = [:]
            for item in input["items"].arrayValue ?? [] {
                guard let el = item.elementValue, let name = el["name"].stringValue else { continue }
                checked[name] = .bool(el["defaultChecked"].boolValue ?? false)
            }
            return .object(checked)
        default:
            return .null
        }
    }

    // MARK: Forms

    /// The (label, input) pairs of a form, in order.
    static func fields(of form: Element) -> [(label: String, input: Element)] {
        (form["fields"].arrayValue ?? []).compactMap { v in
            guard let control = v.elementValue, let input = control["input"].elementValue else { return nil }
            return (control["label"].stringValue ?? "", input)
        }
    }

    /// The first rule an input's value breaks, as the message shown under it.
    func error(for input: Element, form: String?) -> String? {
        let rules = input["rules"]
        let v = current(input, form: form)
        let text: String = {
            switch v {
            case .string(let s): return s.trimmingCharacters(in: .whitespacesAndNewlines)
            case .number(let n): return JS.format(n)
            case .array(let a): return a.isEmpty ? "" : "x"
            case .object(let o): return o.values.contains(.bool(true)) ? "x" : ""
            default: return ""
            }
        }()
        if rules["required"].boolValue == true, text.isEmpty { return "Required" }
        guard !text.isEmpty else { return nil }
        if let n = rules["minLength"].numberValue, text.count < Int(n) { return "At least \(Int(n)) characters" }
        if let n = rules["maxLength"].numberValue, text.count > Int(n) { return "At most \(Int(n)) characters" }
        if rules["email"].boolValue == true, text.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) == nil {
            return "Enter an email address"
        }
        let wantsNumber = rules["numeric"].boolValue == true || input["type"].stringValue == "number"
        if wantsNumber, case .string = v, Double(text) == nil { return "Enter a number" }
        if let n = JS.number(fromString: text), wantsNumber || v.numberValue != nil {
            if let lo = rules["min"].numberValue, n < lo { return "At least \(JS.format(lo))" }
            if let hi = rules["max"].numberValue, n > hi { return "At most \(JS.format(hi))" }
        }
        return nil
    }

    func showsErrors(_ form: String?) -> Bool { form.map { attempted.contains($0) } ?? false }

    /// What an input's value reads as in the message a form sends.
    func display(_ input: Element, form: String?) -> String {
        let v = current(input, form: form)
        func label(of value: String, in items: Value) -> String {
            (items.arrayValue ?? []).compactMap(\.elementValue)
                .first { $0["value"].stringValue == value }?["label"].stringValue ?? value
        }
        switch input.typeName {
        case "Select", "RadioGroup":
            return v.isNull ? "" : label(of: JS.string(v), in: input["items"])
        case "Chips":
            if case .array(let picked) = v {
                return picked.map { label(of: JS.string($0), in: input["items"]) }.joined(separator: ", ")
            }
            return v.isNull ? "" : label(of: JS.string(v), in: input["items"])
        case "Slider", "Stepper":
            guard !v.isNull else { return "" }
            let unit = input["unit"].stringValue.map { " " + $0 } ?? ""
            return JS.format(JS.toNumber(v)) + unit
        case "CheckBoxGroup":
            let checked = v.objectValue ?? [:]
            return (input["items"].arrayValue ?? []).compactMap(\.elementValue)
                .filter { checked[$0["name"].stringValue ?? ""] == .bool(true) }
                .compactMap { $0["label"].stringValue }.joined(separator: ", ")
        default:
            return v.isNull ? "" : JS.string(v)
        }
    }

    // MARK: Actions

    struct Host {
        var send: (String, [String: Value], String?) -> Bool
        var openURL: (URL) -> Void
    }

    /// A button or tappable row. With no action it sends its label; inside a form the message carries the
    /// answers, and nothing is sent while a field breaks its rules.
    func perform(_ action: Value, label: String, form: Element?, host: Host) {
        let plan: ActionPlan
        if case .action(let p) = action { plan = p } else { plan = ActionPlan(steps: [.continueConversation(message: label, context: nil)]) }
        let formName = form?["name"].stringValue
        let converses = plan.steps.contains { if case .continueConversation = $0 { return true } else { return false } }
        if let form, let formName, converses {
            let invalid = Self.fields(of: form).contains { error(for: $0.input, form: formName) != nil }
            if invalid {
                attempted.insert(formName)
                UINotificationFeedbackGenerator().notificationOccurred(.warning)
                return
            }
        }
        var next = store
        let external = next.apply(plan) { Evaluator(library: CoachGenUI.library, store: $0) }
        let changed = next != store
        store = next
        if changed { evaluate() }
        for step in external {
            switch step {
            case .continueConversation(let message, _):
                var text = message.isEmpty ? label : message
                if let form, let formName {
                    text = CoachGenUI.formMessage(text, fields: Self.fields(of: form).map { ($0.label, display($0.input, form: formName)) })
                }
                let key = formName ?? "button:\(label)"
                if host.send(text, store.values, key) {
                    submitted.insert(key)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
                return
            case .openURL(let raw):
                if let url = CoachGenUI.safeURL(raw) { host.openURL(url) }
            default:
                break
            }
        }
        if changed { onStateChange?(store.values) }
    }
}

// MARK: - Card

/// The card under an answer, from its first streamed statement to its saved, interactive form.
struct CoachGenUICard: View {
    let source: String
    let streaming: Bool
    var persisted: [String: Value]?
    var submitted: [String]?
    var interactive: Bool
    var visual: AnyView?
    var onSend: (String, [String: Value], String?) -> Bool
    var onStateChange: ([String: Value]) -> Void

    @StateObject private var model = CoachGenUIModel()
    @State private var wasBuilding = false
    @Environment(\.openURL) private var openURL

    var body: some View {
        // A concrete container, not a Group: a saved card has no child until it loads, and a Group with no
        // child never appears.
        VStack(spacing: 0) {
            if model.isPresentable(streaming: streaming), let tree = model.tree {
                CoachGenUINode(value: .element(tree), model: model, ctx: context)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frostedCardSurface(tint: StrandPalette.chargeColor, cornerRadius: 16)
                    .imageFXReveal(active: wasBuilding, cornerRadius: 16) { wasBuilding = false }
                    .transition(.opacity)
            } else if streaming {
                CoachVizGeneratingView(label: "Building", height: 160)
                    .onAppear { wasBuilding = true }
                    .transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("coachCard")
        .onAppear(perform: load)
        .onChange(of: source) { _, _ in load() }
        .onChange(of: streaming) { _, _ in load() }
        .onChange(of: submitted) { _, _ in load() }
    }

    private var context: CoachGenUIContext {
        CoachGenUIContext(form: nil, formElement: nil, interactive: interactive && !streaming, visual: visual,
                          host: CoachGenUIModel.Host(send: onSend, openURL: { openURL($0) }))
    }

    private func load() {
        model.onStateChange = onStateChange
        model.load(source: source, streaming: streaming, persisted: persisted, submitted: submitted)
    }
}

struct CoachGenUIContext {
    var form: String?
    var formElement: Element?
    var interactive: Bool
    var visual: AnyView?
    var host: CoachGenUIModel.Host
    /// A submitted form's fields stay readable but no longer change.
    var locked = false
}

// MARK: - Nodes

struct CoachGenUINode: View {
    let value: Value
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext

    var body: some View {
        if case .element(let el) = value {
            CoachGenUIElementView(el: el, model: model, ctx: ctx)
        } else if case .array(let items) = value {
            CoachGenUIStack(items: items, model: model, ctx: ctx)
        }
    }
}

struct CoachGenUIStack: View {
    let items: [Value]
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext
    var spacing: CGFloat = 12

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                CoachGenUINode(value: item, model: model, ctx: ctx)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct CoachGenUIElementView: View {
    let el: Element
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext

    var body: some View {
        switch el.typeName {
        case "Card": CoachGenUIStack(items: el["children"].arrayValue ?? [], model: model, ctx: ctx)
        case "CardHeader": GenUIHeader(el: el)
        case "TextContent": GenUIText(el: el)
        case "Callout": GenUICallout(el: el)
        case "Separator": Rectangle().fill(StrandPalette.hairline).frame(height: 0.5)
        case "TagBlock": GenUITags(tags: (el["tags"].arrayValue ?? []).compactMap(\.stringValue))
        case "Visual": if let visual = ctx.visual { visual }
        case "StatGrid": GenUIStatGrid(items: (el["items"].arrayValue ?? []).compactMap(\.elementValue))
        case "Stat": GenUIStatGrid(items: [el])
        case "ProgressBar": GenUIProgress(el: el)
        case "Table": GenUITable(columns: (el["columns"].arrayValue ?? []).compactMap(\.elementValue))
        case "ListBlock", "ListItem": GenUIList(items: el.typeName == "ListItem" ? [el] : (el["items"].arrayValue ?? []).compactMap(\.elementValue),
                                                model: model, ctx: ctx)
        case "Steps": GenUISteps(items: (el["items"].arrayValue ?? []).compactMap(\.elementValue))
        case "Tabs": GenUITabs(el: el, model: model, ctx: ctx)
        case "Accordion": GenUIAccordion(el: el, model: model, ctx: ctx)
        case "Button": GenUIButton(el: el, model: model, ctx: ctx)
        case "Buttons": GenUIButtons(el: el, model: model, ctx: ctx)
        case "Form": GenUIForm(el: el, model: model, ctx: ctx)
        case "FormControl": GenUIFormControl(el: el, model: model, ctx: ctx)
        case "Timer": GenUITimer(el: el)
        case "Input", "TextArea", "Select", "Slider", "Stepper", "CheckBoxGroup", "RadioGroup", "Chips":
            GenUIInput(input: el, model: model, ctx: ctx)
        default: EmptyView()
        }
    }
}

// MARK: - Content

private enum GenUIStyle {
    static let inset = RoundedRectangle(cornerRadius: 12, style: .continuous)

    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    static func tone(_ name: String?) -> Color {
        switch name {
        case "good": return StrandPalette.statusPositive
        case "caution": return StrandPalette.statusWarning
        case "bad": return StrandPalette.statusCritical
        default: return StrandPalette.textPrimary
        }
    }
}

private struct GenUIHeader: View {
    let el: Element
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if let title = el["title"].stringValue, !title.isEmpty {
                Text(title).font(StrandFont.headline).foregroundStyle(StrandPalette.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            if let subtitle = el["subtitle"].stringValue, !subtitle.isEmpty {
                Text(subtitle).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct GenUIText: View {
    let el: Element
    var body: some View {
        let font: Font = switch el["size"].stringValue {
        case "small": StrandFont.caption
        case "large": StrandFont.headline
        default: StrandFont.body
        }
        Text(GenUIStyle.inline(el["text"].stringValue ?? ""))
            .font(font)
            .foregroundStyle(el["size"].stringValue == "small" ? StrandPalette.textSecondary : StrandPalette.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct GenUICallout: View {
    let el: Element
    var body: some View {
        let (color, icon): (Color, String) = switch el["variant"].stringValue {
        case "tip": (StrandPalette.metricCyan, "lightbulb")
        case "success": (StrandPalette.statusPositive, "checkmark.circle")
        case "warning": (StrandPalette.statusWarning, "exclamationmark.triangle")
        default: (StrandPalette.accent, "info.circle")
        }
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(color).padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(el["title"].stringValue ?? "").font(StrandFont.subhead.weight(.semibold)).foregroundStyle(StrandPalette.textPrimary)
                if let d = el["description"].stringValue, !d.isEmpty {
                    Text(GenUIStyle.inline(d)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(color.opacity(0.12), in: GenUIStyle.inset)
        .overlay(GenUIStyle.inset.strokeBorder(color.opacity(0.28), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

private struct GenUITags: View {
    let tags: [String]
    var body: some View {
        GenUIFlow(spacing: 6) {
            ForEach(Array(tags.enumerated()), id: \.offset) { _, tag in
                Text(tag).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(StrandPalette.surfaceInset, in: Capsule())
            }
        }
    }
}

private struct GenUIStatGrid: View {
    let items: [Element]
    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)], alignment: .leading, spacing: 8) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, stat in
                VStack(alignment: .leading, spacing: 3) {
                    Text(stat["label"].stringValue ?? "").font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
                    Text(stat["value"].stringValue ?? "")
                        .font(.system(.title3, weight: .semibold).monospacedDigit())
                        .foregroundStyle(GenUIStyle.tone(stat["tone"].stringValue))
                        .minimumScaleFactor(0.7).lineLimit(1)
                    if let detail = stat["detail"].stringValue, !detail.isEmpty {
                        Text(detail).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(StrandPalette.surfaceInset, in: GenUIStyle.inset)
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct GenUIProgress: View {
    let el: Element
    var body: some View {
        let value = JS.toNumber(el["value"]), target = max(JS.toNumber(el["target"]), 0.0001)
        let unit = el["unit"].stringValue.map { " " + $0 } ?? ""
        let fraction = min(1, max(0, value / target))
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(el["label"].stringValue ?? "").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                Text("\(JS.format(value)) / \(JS.format(JS.toNumber(el["target"])))\(unit)")
                    .font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textSecondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(StrandPalette.surfaceInset)
                    Capsule().fill(fraction >= 1 ? StrandPalette.statusPositive : StrandPalette.accent)
                        .frame(width: max(6, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(el["label"].stringValue ?? ""): \(JS.format(value)) of \(JS.format(JS.toNumber(el["target"])))\(unit)")
    }
}

private struct GenUITable: View {
    let columns: [Element]
    var body: some View {
        let data = columns.map { ($0["data"].arrayValue ?? []).map { $0.isNull ? "" : JS.string($0) } }
        let rows = data.map(\.count).max() ?? 0
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                GridRow {
                    ForEach(Array(columns.enumerated()), id: \.offset) { _, col in
                        Text(col["label"].stringValue ?? "").font(StrandFont.caption.weight(.semibold))
                            .foregroundStyle(StrandPalette.textTertiary)
                    }
                }
                Divider().gridCellUnsizedAxes(.horizontal)
                ForEach(0..<rows, id: \.self) { r in
                    GridRow {
                        ForEach(Array(data.enumerated()), id: \.offset) { c, column in
                            Text(r < column.count ? column[r] : "")
                                .font(c == 0 ? StrandFont.subhead.weight(.medium) : StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 180, alignment: .leading)
                        }
                    }
                }
            }
            .padding(.vertical, 2)
        }
    }
}

private struct GenUISteps: View {
    let items: [Element]
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 10) {
                    Text("\(i + 1)").font(StrandFont.captionNumber.weight(.semibold)).foregroundStyle(StrandPalette.surfaceBase)
                        .frame(width: 22, height: 22).background(StrandPalette.accent, in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step["title"].stringValue ?? "").font(StrandFont.subhead.weight(.semibold))
                            .foregroundStyle(StrandPalette.textPrimary)
                        if let d = step["details"].stringValue, !d.isEmpty {
                            Text(GenUIStyle.inline(d)).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct GenUIList: View {
    let items: [Element]
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let action = item["action"]
                let tappable = !action.isNull
                Button {
                    model.perform(action, label: item["title"].stringValue ?? "", form: nil, host: ctx.host)
                } label: {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item["title"].stringValue ?? "").font(StrandFont.subhead.weight(.medium))
                                .foregroundStyle(StrandPalette.textPrimary)
                            if let s = item["subtitle"].stringValue, !s.isEmpty {
                                Text(s).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                        if tappable {
                            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary)
                        }
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!tappable || !ctx.interactive)
                if i < items.count - 1 { Rectangle().fill(StrandPalette.hairline).frame(height: 0.5) }
            }
        }
    }
}

private struct GenUITabs: View {
    let el: Element
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext

    var body: some View {
        let items = (el["items"].arrayValue ?? []).compactMap(\.elementValue)
        let key = "ui:tabs:" + (el.statementId ?? items.compactMap { $0["value"].stringValue }.joined(separator: "|"))
        let selected = model.value(key).stringValue ?? items.first?["value"].stringValue
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, tab in
                        let value = tab["value"].stringValue ?? ""
                        GenUIChip(label: tab["trigger"].stringValue ?? value, selected: value == selected) {
                            model.set(key, .string(value))
                        }
                    }
                }
            }
            if let tab = items.first(where: { $0["value"].stringValue == selected }) {
                CoachGenUIStack(items: tab["content"].arrayValue ?? [], model: model, ctx: ctx, spacing: 10)
            }
        }
    }
}

private struct GenUIAccordion: View {
    let el: Element
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext

    var body: some View {
        let items = (el["items"].arrayValue ?? []).compactMap(\.elementValue)
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                let key = "ui:open:" + (item["value"].stringValue ?? "\(i)")
                let open = model.value(key).boolValue ?? false
                VStack(alignment: .leading, spacing: 8) {
                    Button {
                        withAnimation(StrandMotion.interactive) { model.set(key, .bool(!open)) }
                    } label: {
                        HStack {
                            Text(item["trigger"].stringValue ?? "").font(StrandFont.subhead.weight(.medium))
                                .foregroundStyle(StrandPalette.textPrimary).multilineTextAlignment(.leading)
                            Spacer()
                            Image(systemName: "chevron.down").font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(StrandPalette.textTertiary).rotationEffect(.degrees(open ? 180 : 0))
                        }
                        .padding(.vertical, 9)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(open ? "Expanded" : "Collapsed")
                    if open {
                        CoachGenUIStack(items: item["content"].arrayValue ?? [], model: model, ctx: ctx, spacing: 10)
                            .padding(.bottom, 8)
                    }
                }
                if i < items.count - 1 { Rectangle().fill(StrandPalette.hairline).frame(height: 0.5) }
            }
        }
    }
}

// MARK: - Buttons

private struct GenUIButton: View {
    let el: Element
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext
    @Environment(\.liquidGlass) private var glass

    var body: some View {
        let label = el["label"].stringValue ?? ""
        let key = ctx.form ?? "button:\(label)"
        let sent = model.submitted.contains(key)
        let variant = el["variant"].stringValue ?? (ctx.form != nil ? "primary" : "secondary")
        Button {
            model.perform(el["action"], label: label, form: ctx.formElement, host: ctx.host)
        } label: {
            HStack(spacing: 6) {
                if sent { Image(systemName: "checkmark").font(.system(size: 11, weight: .bold)) }
                Text(sent && ctx.form != nil ? "Sent" : label).font(StrandFont.subhead.weight(.semibold)).lineLimit(2)
            }
            .foregroundStyle(variant == "primary" ? StrandPalette.surfaceBase : StrandPalette.accent)
            .padding(.horizontal, variant == "tertiary" ? 4 : 14)
            .padding(.vertical, 9)
            .frame(maxWidth: ctx.form != nil ? .infinity : nil)
            .background { background(variant) }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!ctx.interactive || sent)
        .opacity(!ctx.interactive || sent ? 0.6 : 1)
        .accessibilityIdentifier("coachCard.button.\(label)")
    }

    @ViewBuilder
    private func background(_ variant: String) -> some View {
        switch variant {
        case "tertiary": Color.clear
        case "primary":
            if glass.isEnabled { Color.clear.noopGlassControl(in: Capsule(), tint: StrandPalette.accent, refraction: false) }
            else { Capsule().fill(StrandPalette.accent) }
        default:
            if glass.isEnabled { Color.clear.noopGlassControl(in: Capsule(), refraction: false) }
            else { Capsule().fill(StrandPalette.accent.opacity(0.12)) }
        }
    }
}

private struct GenUIButtons: View {
    let el: Element
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext

    var body: some View {
        let buttons = (el["buttons"].arrayValue ?? []).compactMap(\.elementValue)
        let row = HStack(spacing: 8) { content(buttons) }
        let column = VStack(alignment: .leading, spacing: 8) { content(buttons) }
        if el["direction"].stringValue == "column" {
            column
        } else {
            ViewThatFits(in: .horizontal) { row; column }
        }
    }

    private func content(_ buttons: [Element]) -> some View {
        ForEach(Array(buttons.enumerated()), id: \.offset) { _, b in GenUIButton(el: b, model: model, ctx: ctx) }
    }
}

// MARK: - Forms

private struct GenUIForm: View {
    let el: Element
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext

    var body: some View {
        let name = el["name"].stringValue ?? "form"
        var inner = ctx
        inner.form = name
        inner.formElement = el
        inner.locked = model.submitted.contains(name)
        return VStack(alignment: .leading, spacing: 12) {
            CoachGenUIStack(items: el["fields"].arrayValue ?? [], model: model, ctx: inner, spacing: 12)
                .disabled(inner.locked || !ctx.interactive)
            CoachGenUINode(value: el["buttons"], model: model, ctx: inner)
        }
    }
}

private struct GenUIFormControl: View {
    let el: Element
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(el["label"].stringValue ?? "").font(StrandFont.caption.weight(.semibold)).foregroundStyle(StrandPalette.textSecondary)
            if let input = el["input"].elementValue {
                GenUIInput(input: input, model: model, ctx: ctx, label: el["label"].stringValue)
                if model.showsErrors(ctx.form), let error = model.error(for: input, form: ctx.form) {
                    Label(error, systemImage: "exclamationmark.circle").font(StrandFont.caption)
                        .foregroundStyle(StrandPalette.statusCritical)
                }
            }
            if let hint = el["hint"].stringValue, !hint.isEmpty {
                Text(hint).font(StrandFont.caption).foregroundStyle(StrandPalette.textTertiary)
            }
        }
    }
}

private struct GenUIInput: View {
    let input: Element
    @ObservedObject var model: CoachGenUIModel
    let ctx: CoachGenUIContext
    var label: String?

    private var key: String { CoachGenUIModel.key(for: input, form: ctx.form) }
    private var current: Value { model.current(input, form: ctx.form) }
    private var a11yLabel: String { label ?? input["name"].stringValue ?? "" }

    var body: some View {
        switch input.typeName {
        case "Input", "TextArea": textField
        case "Select": select
        case "Slider": slider
        case "Stepper": stepper
        case "CheckBoxGroup": checkboxes
        case "RadioGroup": radios
        case "Chips": chips
        default: EmptyView()
        }
    }

    private var text: Binding<String> {
        Binding(get: { current.isNull ? "" : JS.string(current) }, set: { model.set(key, .string($0)) })
    }

    private var number: Binding<Double> {
        Binding(get: { JS.toNumber(current) }, set: { model.set(key, .number(($0 * 1000).rounded() / 1000)) })
    }

    private var bounds: ClosedRange<Double> {
        let lo = JS.toNumber(input["min"]), hi = JS.toNumber(input["max"])
        return lo < hi ? lo...hi : lo...(lo + 1)
    }

    private var unit: String { input["unit"].stringValue.map { " " + $0 } ?? "" }

    private func items(_ prop: String = "items") -> [Element] { (input[prop].arrayValue ?? []).compactMap(\.elementValue) }

    @ViewBuilder
    private var textField: some View {
        let placeholder = input["placeholder"].stringValue ?? ""
        Group {
            if input.typeName == "TextArea" {
                TextField(placeholder, text: text, axis: .vertical).lineLimit(3...6)
            } else {
                TextField(placeholder, text: text)
                    .keyboardType(input["type"].stringValue == "email" ? .emailAddress : input["type"].stringValue == "number" ? .decimalPad : .default)
                    .textInputAutocapitalization(input["type"].stringValue == "email" ? .never : .sentences)
            }
        }
        .font(StrandFont.body)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(StrandPalette.surfaceInset, in: GenUIStyle.inset)
        .accessibilityLabel(a11yLabel)
    }

    private var select: some View {
        let options = items()
        let selected = current.isNull ? nil : JS.string(current)
        let shown = options.first { $0["value"].stringValue == selected }?["label"].stringValue
        return Menu {
            ForEach(Array(options.enumerated()), id: \.offset) { _, option in
                Button(option["label"].stringValue ?? "") { model.set(key, .string(option["value"].stringValue ?? "")) }
            }
        } label: {
            HStack {
                Text(shown ?? input["placeholder"].stringValue ?? "Choose")
                    .foregroundStyle(shown == nil ? StrandPalette.textTertiary : StrandPalette.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 11)).foregroundStyle(StrandPalette.textTertiary)
            }
            .font(StrandFont.body)
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(StrandPalette.surfaceInset, in: GenUIStyle.inset)
        }
        .accessibilityLabel(a11yLabel)
        .accessibilityValue(shown ?? "None")
    }

    private var slider: some View {
        let step = input["step"].numberValue.flatMap { $0 > 0 ? $0 : nil }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Spacer()
                Text(JS.format(JS.toNumber(current)) + unit).font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textPrimary)
            }
            if let step {
                Slider(value: number, in: bounds, step: step)
            } else {
                Slider(value: number, in: bounds)
            }
        }
        .tint(StrandPalette.accent)
        .accessibilityLabel(a11yLabel)
        .accessibilityValue(JS.format(JS.toNumber(current)) + unit)
    }

    private var stepper: some View {
        let step = input["step"].numberValue.flatMap { $0 > 0 ? $0 : nil } ?? 1
        let shown = JS.format(JS.toNumber(current)) + unit
        return HStack {
            Text(shown).font(StrandFont.bodyNumber).foregroundStyle(StrandPalette.textPrimary)
                .accessibilityHidden(true)
            Spacer(minLength: 8)
            Stepper(a11yLabel, value: number, in: bounds, step: step)
                .labelsHidden()
                .accessibilityValue(shown)
        }
    }

    private var checkboxes: some View {
        let checked = current.objectValue ?? [:]
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items().enumerated()), id: \.offset) { _, item in
                let name = item["name"].stringValue ?? ""
                let on = checked[name] == .bool(true)
                Button {
                    var next = checked
                    next[name] = .bool(!on)
                    model.set(key, .object(next))
                    UISelectionFeedbackGenerator().selectionChanged()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .font(.system(size: 18)).foregroundStyle(on ? StrandPalette.accent : StrandPalette.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item["label"].stringValue ?? "").font(StrandFont.subhead)
                                .foregroundStyle(StrandPalette.textPrimary).strikethrough(on && ctx.form == nil, color: StrandPalette.textTertiary)
                            if let d = item["description"].stringValue, !d.isEmpty {
                                Text(d).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!ctx.interactive)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var radios: some View {
        let selected = current.isNull ? nil : JS.string(current)
        return VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(items().enumerated()), id: \.offset) { _, item in
                let value = item["value"].stringValue ?? ""
                let on = value == selected
                Button { model.set(key, .string(value)) } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: on ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 18)).foregroundStyle(on ? StrandPalette.accent : StrandPalette.textTertiary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item["label"].stringValue ?? "").font(StrandFont.subhead).foregroundStyle(StrandPalette.textPrimary)
                            if let d = item["description"].stringValue, !d.isEmpty {
                                Text(d).font(StrandFont.caption).foregroundStyle(StrandPalette.textSecondary)
                            }
                        }
                        .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
    }

    private var chips: some View {
        let multiple = input["type"].stringValue == "multiple"
        let picked: [String] = {
            if case .array(let a) = current { return a.map { JS.string($0) } }
            return current.isNull ? [] : [JS.string(current)]
        }()
        return GenUIFlow(spacing: 6) {
            ForEach(Array(items().enumerated()), id: \.offset) { _, item in
                let value = item["value"].stringValue ?? ""
                GenUIChip(label: item["label"].stringValue ?? value, selected: picked.contains(value)) {
                    if multiple {
                        let next = picked.contains(value) ? picked.filter { $0 != value } : picked + [value]
                        model.set(key, .array(next.map(Value.string)))
                    } else {
                        model.set(key, .string(value))
                    }
                }
            }
        }
    }
}

private struct GenUIChip: View {
    let label: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            action()
        } label: {
            Text(label).font(StrandFont.subhead.weight(selected ? .semibold : .regular))
                .foregroundStyle(selected ? StrandPalette.surfaceBase : StrandPalette.textPrimary)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(selected ? StrandPalette.accent : StrandPalette.surfaceInset, in: Capsule())
                .overlay(Capsule().strokeBorder(selected ? Color.clear : StrandPalette.hairline, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Timer

private struct GenUITimer: View {
    let el: Element
    @State private var endsAt: Date?
    @State private var remaining: Double?
    @State private var round = 1
    @State private var finished = false
    private let tick = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    private var seconds: Double { max(1, JS.toNumber(el["seconds"])) }
    private var rounds: Int { max(1, Int(JS.toNumber(el["rounds"]).rounded())) }
    private var left: Double { remaining ?? seconds }

    var body: some View {
        let running = endsAt != nil
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(el["label"].stringValue ?? "").font(StrandFont.subhead.weight(.medium)).foregroundStyle(StrandPalette.textPrimary)
                Spacer()
                if rounds > 1 {
                    Text("Round \(round) of \(rounds)").font(StrandFont.captionNumber).foregroundStyle(StrandPalette.textTertiary)
                }
            }
            HStack(spacing: 12) {
                Text(finished ? "Done" : Self.clock(left))
                    .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(finished ? StrandPalette.statusPositive : StrandPalette.textPrimary)
                    .contentTransition(.numericText())
                Spacer()
                Button(running ? "Pause" : (finished ? "Again" : "Start")) { running ? pause() : start() }
                    .font(StrandFont.subhead.weight(.semibold))
                    .buttonStyle(.borderedProminent).tint(StrandPalette.accent)
                Button("Reset", action: reset).font(StrandFont.subhead).buttonStyle(.bordered).tint(StrandPalette.accent)
                    .disabled(!running && remaining == nil && !finished)
            }
            GeometryReader { geo in
                Capsule().fill(StrandPalette.surfaceInset).overlay(alignment: .leading) {
                    Capsule().fill(StrandPalette.accent).frame(width: geo.size.width * (finished ? 1 : 1 - left / seconds))
                }
            }
            .frame(height: 4)
        }
        .padding(12)
        .background(StrandPalette.surfaceInset.opacity(0.6), in: GenUIStyle.inset)
        .onReceive(tick) { now in advance(now) }
        .onChange(of: seconds) { _, _ in reset() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(el["label"].stringValue ?? "Timer")
    }

    static func clock(_ s: Double) -> String {
        let total = Int(s.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func start() {
        if finished { reset() }
        endsAt = Date().addingTimeInterval(left)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    private func pause() {
        remaining = max(0, endsAt?.timeIntervalSinceNow ?? left)
        endsAt = nil
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func reset() {
        endsAt = nil
        remaining = nil
        round = 1
        finished = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func advance(_ now: Date) {
        guard let endsAt else { return }
        let r = endsAt.timeIntervalSince(now)
        if r > 0 { remaining = r; return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        if round < rounds {
            round += 1
            remaining = seconds
            self.endsAt = now.addingTimeInterval(seconds)
        } else {
            finished = true
            remaining = 0
            self.endsAt = nil
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }
}

// MARK: - Flow layout

/// Wraps its children onto as many rows as they need (tags, chips).
struct GenUIFlow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var indices: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for (i, view) in subviews.enumerated() {
            let size = view.sizeThatFits(.unspecified)
            if !rows[rows.count - 1].indices.isEmpty, rows[rows.count - 1].width + spacing + size.width > width {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(i)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

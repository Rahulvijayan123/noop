import SwiftUI
import StrandDesign

// MARK: - Grouped-list building blocks
//
// Every Settings page is built from these: a rounded card per group, rows with a label on the left and a
// value, chevron or control on the right, and hairlines between rows.

/// A rounded card of rows under a small all-caps title. `footer` is a muted note beneath the card.
/// With no title it is just the card, which the edit pages reuse.
struct SettingsGroup<Content: View>: View {
    let title: LocalizedStringKey?
    let footer: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey? = nil, footer: LocalizedStringKey? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            StrandCard(padding: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    if let title {
                        Text(title)
                            .strandOverline()
                            .textCase(.uppercase)
                            .padding(.horizontal, NoopMetrics.space4)
                            .padding(.top, NoopMetrics.space4)
                            .padding(.bottom, NoopMetrics.space1)
                    }
                    content()
                }
            }
            if let footer {
                Text(footer)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NoopMetrics.space1)
            }
        }
    }
}

/// Label left; optional value and chevron right.
struct SettingsRow: View {
    let label: LocalizedStringKey
    let value: String?
    let chevron: Bool

    init(_ label: LocalizedStringKey, value: String? = nil, chevron: Bool = true) {
        self.label = label
        self.value = value
        self.chevron = chevron
    }

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .layoutPriority(1)
            Spacer(minLength: NoopMetrics.space3)
            if let value {
                Text(value)
                    .font(StrandFont.body)
                    .foregroundStyle(chevron ? StrandPalette.accent : StrandPalette.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(StrandPalette.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NoopMetrics.space4)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// A switch with its label and an optional one-line detail underneath.
struct SettingsToggleRow: View {
    let label: LocalizedStringKey
    let detail: LocalizedStringKey?
    @Binding var isOn: Bool

    init(_ label: LocalizedStringKey, detail: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let detail {
                    Text(detail)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(StrandPalette.accent)
        .padding(.horizontal, NoopMetrics.space4)
        .padding(.vertical, NoopMetrics.space2)
        .frame(minHeight: 52)
    }
}

/// A whole-number setting: label, current value and a native stepper.
struct SettingsStepperRow: View {
    let label: LocalizedStringKey
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    let format: (Int) -> String

    var body: some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
            Spacer(minLength: NoopMetrics.space2)
            Text(format(value))
                .font(StrandFont.bodyNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .fixedSize()
            Stepper(label, value: $value, in: range, step: step)
                .labelsHidden()
                .accessibilityValue(format(value))
        }
        .padding(.horizontal, NoopMetrics.space4)
        .frame(minHeight: 52)
    }
}

/// A short muted line inside a group, for a state the user should know about (not a description).
struct SettingsNote: View {
    private let text: Text
    private let tone: Color

    init(_ text: LocalizedStringKey, tone: Color = StrandPalette.textTertiary) {
        self.text = Text(text)
        self.tone = tone
    }

    /// A message that is already user-facing text (an error from the system), shown as is.
    init(verbatim text: String, tone: Color = StrandPalette.textTertiary) {
        self.text = Text(verbatim: text)
        self.tone = tone
    }

    var body: some View {
        text
            .font(StrandFont.footnote)
            .foregroundStyle(tone)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, NoopMetrics.space4)
            .padding(.vertical, NoopMetrics.space2)
    }
}

/// Hairline between rows, inset from the leading edge so it starts under the label text.
struct SettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(StrandPalette.hairline)
            .frame(height: 1)
            .padding(.leading, NoopMetrics.space4)
    }
}

struct SettingsRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

/// A pushed page: big title, one card, optional footnote.
struct SettingsEditPage<Content: View>: View {
    let title: LocalizedStringKey
    let footnote: LocalizedStringKey?
    @ViewBuilder var content: () -> Content

    init(_ title: LocalizedStringKey, footnote: LocalizedStringKey? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footnote = footnote
        self.content = content
    }

    var body: some View {
        ScreenScaffold(title: title) {
            SettingsGroup(footer: footnote, content: content)
        }
    }
}

/// Single-choice list with a checkmark on the selected row.
struct SettingsOptions: View {
    @Binding var selection: String
    private let options: [(tag: String, label: Text)]

    init(selection: Binding<String>, options: [(tag: String, label: LocalizedStringKey)]) {
        _selection = selection
        self.options = options.map { ($0.tag, Text($0.label)) }
    }

    /// Labels that are already user-facing text, localized where they are defined, shown as they are.
    init(selection: Binding<String>, verbatim options: [(tag: String, label: String)]) {
        _selection = selection
        self.options = options.map { ($0.tag, Text(verbatim: $0.label)) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.offset) { index, option in
                if index > 0 { SettingsDivider() }
                Button {
                    selection = option.tag
                } label: {
                    HStack {
                        option.label
                            .font(StrandFont.body)
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        if selection == option.tag {
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(StrandPalette.accent)
                                .accessibilityHidden(true)
                        }
                    }
                    .padding(.horizontal, NoopMetrics.space4)
                    .frame(minHeight: 52)
                    .contentShape(Rectangle())
                }
                .buttonStyle(SettingsRowStyle())
                .accessibilityAddTraits(selection == option.tag ? .isSelected : [])
            }
        }
    }
}

/// Label on the left, control on the right — the two-column form feel.
struct FormRow<Control: View>: View {
    let label: LocalizedStringKey
    @ViewBuilder var control: () -> Control

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space4) {
            Text(label)
                .font(StrandFont.body)
                .foregroundStyle(StrandPalette.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
            control()
                .layoutPriority(1)
        }
        .frame(minHeight: 32)
    }
}

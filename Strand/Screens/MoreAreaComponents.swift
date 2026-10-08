import SwiftUI
import StrandDesign

// MARK: - Shared pieces for the device, data-source and settings-like screens
//
// Small building blocks the kit does not have yet (docs/DESIGN_SYSTEM.md, Lists), kept app-side and
// prefixed so they can be promoted to `Packages/StrandDesign` later without a name clash: a toggle row for
// a `NoopListSection`, a picker row, the sheet chrome (inline title + Done) and the macOS pane stack.

/// One switch inside a `NoopListSection`: a title, an optional one-line footnote, the switch at the trailing
/// edge in the accent colour. At least `NoopMetrics.listRowMinHeight` tall, like `NoopListRow`.
struct MoreToggleRow: View {
    private let title: Text
    private let footnote: String?
    @Binding private var isOn: Bool

    init(_ title: LocalizedStringKey, footnote: String? = nil, isOn: Binding<Bool>) {
        self.title = Text(title)
        self.footnote = footnote
        self._isOn = isOn
    }

    init(verbatim title: String, footnote: String? = nil, isOn: Binding<Bool>) {
        self.title = Text(verbatim: title)
        self.footnote = footnote
        self._isOn = isOn
    }

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                title
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let footnote {
                    Text(footnote)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(isOn: $isOn) { title }
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space3)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

/// A list row with a trailing control (a menu picker, a stepper, a date picker): title on the leading edge,
/// the control on the trailing edge, an optional footnote under the title.
struct MoreControlRow<Control: View>: View {
    private let title: Text
    private let footnote: String?
    private let control: () -> Control

    init(_ title: LocalizedStringKey, footnote: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = Text(title)
        self.footnote = footnote
        self.control = control
    }

    var body: some View {
        HStack(alignment: .center, spacing: NoopMetrics.space3) {
            VStack(alignment: .leading, spacing: NoopMetrics.spaceHalf) {
                title
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                if let footnote {
                    Text(footnote)
                        .font(StrandFont.footnote)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, NoopMetrics.cardPadding)
        .padding(.vertical, NoopMetrics.space2)
        .frame(maxWidth: .infinity, minHeight: NoopMetrics.listRowMinHeight, alignment: .leading)
    }
}

/// A row of buttons or a single full-width action inside a list card, padded like a row.
struct MoreRowActions<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) { content() }
            .padding(.horizontal, NoopMetrics.cardPadding)
            .padding(.vertical, NoopMetrics.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// One footnote-sized line inside a list card (a status or a result under the row above it).
struct MoreRowNote: View {
    private let text: String
    private let tone: StrandTone

    init(_ text: String, tone: StrandTone = .neutral) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(StrandFont.footnote)
            .foregroundStyle(tone == .neutral ? StrandPalette.textTertiary : tone.color)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, NoopMetrics.cardPadding)
            .padding(.bottom, NoopMetrics.space3)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Sheet chrome

extension View {
    /// The one way a sheet looks: its own `NavigationStack`, the title inline in the bar, and one Done
    /// button at the trailing edge (docs/DESIGN_SYSTEM.md, sheet rule). Replaces hand-made close buttons
    /// and in-content titles.
    func moreSheetChrome(_ title: LocalizedStringKey, onDone: @escaping () -> Void) -> some View {
        NavigationStack {
            self
                .background(StrandPalette.surfaceBase.ignoresSafeArea())
                .navigationTitle(Text(title))
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                            .foregroundStyle(StrandPalette.accent)
                    }
                }
        }
    }
}

// MARK: - macOS pane stack

/// Gives a page its own `NavigationStack` when it is a macOS sidebar pane, so its drill-down rows push.
///
/// On iPhone every page already sits in a tab's or a sheet's stack. On the Mac the sidebar's detail column has
/// none (#753), so a `NavigationLink` there does nothing; but the same page can also be pushed inside the
/// Today pane's stack (the Browse list), where a second stack would be nested. `isPresented` tells the two
/// apart: it is true for a pushed or presented page and false for a sidebar pane.
struct MorePaneNavigation<Content: View>: View {
    @Environment(\.isPresented) private var isPresented
    @ViewBuilder let content: () -> Content

    var body: some View {
        #if os(macOS)
        if isPresented {
            content()
        } else {
            NavigationStack { content().tabRouteDestinations() }
        }
        #else
        content()
        #endif
    }
}

// MARK: - Formatting

enum MoreFormat {
    /// "7 h 32 m" / "48 m" for a duration in minutes (units next to values, with a space).
    static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let h = total / 60, m = total % 60
        if h > 0 { return m > 0 ? "\(h) h \(m) m" : "\(h) h" }
        return "\(m) m"
    }

    /// Thousands-grouped whole number in the user's locale ("12,345").
    static func integer(_ value: Double) -> String {
        Int(value.rounded()).formatted(.number.grouping(.automatic))
    }

    /// A whole number without decimals ("98"), otherwise one decimal ("97.5"), in the user's locale.
    static func compact(_ value: Double) -> String {
        value == value.rounded() ? integer(value) : oneDecimal(value)
    }

    /// One decimal place in the user's locale ("72.4").
    static func oneDecimal(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)))
    }

    /// "Tue 7 Oct" for a stored yyyy-MM-dd key, in the user's locale; the key itself if it does not parse.
    static func day(_ key: String) -> String {
        guard let date = ChartDay.date(forKey: key) else { return key }
        return ReadoutContent.dateLine(date, period: .day)
    }
}

// MARK: - Row press feedback

/// Press feedback for a whole-row button inside a list card: a brief dim, nothing that moves the row.
struct MoreRowPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.55 : 1)
    }
}

#if !os(watchOS)
// The watch app never shows the day navigator (no DatePicker(.graphical) / .popover on watchOS),
// so this whole control is excluded there; iOS/macOS are unchanged.
import SwiftUI

// MARK: - DayNavBar — chevron + date-jump day selector
//
// The classic Today screen's day navigator, drawn as the shared `PeriodStepper`: chevrons step one day
// at a time (back older, forward newer, disabled at today so a future day can't be selected), and the
// centre shows the selected day's label + date and opens a graphical DatePicker capped at today.
// Replaces the fixed three-day strip so navigation reaches arbitrarily far back. The same control
// renders on macOS and iOS — the DatePicker is shown in a popover on both. Mirrors the Android
// DayNavBar (StrandComponents.kt). Offset is days-back-from-today (0 = today).

public struct DayNavBar: View {
    private let selectedOffset: Int
    private let today: Date
    private let onSelect: (Int) -> Void

    @State private var showingPicker = false
    @Environment(\.locale) private var locale

    /// `today` is the caller's LOGICAL day (the same anchor the rest of Today uses, rolling at 04:00),
    /// so every label here counts back from it. Passing it in instead of reading `Date()` keeps the
    /// macOS full-date label in step with the data shown in the 00:00-04:00 window, where a raw
    /// `Date()` already reads the next calendar day while the screen still shows the logical day (#14).
    public init(selectedOffset: Int, today: Date, onSelect: @escaping (Int) -> Void) {
        self.selectedOffset = selectedOffset
        self.today = today
        self.onSelect = onSelect
    }

    /// The calendar day the current offset resolves to, counting back from the caller's logical day.
    private var selectedDay: Date {
        Calendar.current.date(byAdding: .day, value: -selectedOffset, to: today) ?? today
    }

    private var canGoNewer: Bool { selectedOffset > 0 }

    private var label: String {
        switch selectedOffset {
        case 0:  return String(localized: "Today", bundle: .module)
        case 1:  return String(localized: "Yesterday", bundle: .module)
        default:
            return selectedDay.formatted(
                .dateTime.weekday(.abbreviated).day().month(.abbreviated).locale(locale)
            )
        }
    }

    /// The full date beside the label, once you have navigated away from today (on today the label
    /// already reads "Today").
    private var subtitle: String? {
        guard selectedOffset > 0 else { return nil }
        return selectedDay.formatted(.dateTime.day().month(.abbreviated).year().locale(locale))
    }

    /// The shared `PeriodStepper` look (one stepper for days, nights and weeks), with the date jump on the
    /// centre.
    public var body: some View {
        PeriodStepper(title: label, subtitle: subtitle,
                      canGoBack: true, canGoForward: canGoNewer,
                      onBack: { onSelect(selectedOffset + 1) },
                      onForward: { if canGoNewer { onSelect(selectedOffset - 1) } },
                      onTitleTap: { showingPicker = true })
            .popover(isPresented: $showingPicker) {
                datePickerPopover
            }
    }

    /// Graphical date jump, capped at today so a future day can't be picked. Converting the chosen
    /// date back to a whole-day offset keeps the rest of the screen driven by the single offset value.
    private var datePickerPopover: some View {
        // A local binding so the picker writes straight through to an offset via onSelect.
        let pickedBinding = Binding<Date>(
            get: { selectedDay },
            set: { newValue in
                let cal = Calendar.current
                let start = cal.startOfDay(for: newValue)
                // Offset is measured from the caller's LOGICAL day (not raw Date()), so a date picked in
                // the 00:00-04:00 window maps to the same offset the labels count back from (#14).
                let anchor = cal.startOfDay(for: today)
                let days = cal.dateComponents([.day], from: start, to: anchor).day ?? 0
                onSelect(max(0, days))
                showingPicker = false
            }
        )
        return DatePicker("", selection: pickedBinding, in: ...today, displayedComponents: [.date])
            .datePickerStyle(.graphical)
            .labelsHidden()
            .padding(12)
            // #840 — iPad popover needs an explicit size or the graphical picker clips. Safe on macOS 13
            // and iPhone (the popover/sheet sizes to this); avoids the macOS 13.3-only compact-adaptation API.
            .frame(minWidth: 320, minHeight: 360)
    }

}
#endif

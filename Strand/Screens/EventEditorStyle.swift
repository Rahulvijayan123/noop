import SwiftUI
import StrandDesign

// MARK: - The editor idiom
//
// Every "log a thing" editor (an exposure event, a treatment start, dose, end or edit, a lab reading) is the
// same shape: a sheet with its own NavigationStack, an inline title, Cancel and Save in the toolbar, a grouped
// Form on the flat canvas with its rows on the card surface, and any destructive action as a row at the
// bottom that asks before it acts. These two modifiers are the look; each editor keeps its own fields.

extension View {
    /// A grouped form on the flat canvas.
    func eventEditorForm() -> some View {
        formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    /// Form rows on the card surface (apply to a `Section`).
    func eventEditorRow() -> some View {
        listRowBackground(StrandPalette.surfaceRaised)
    }
}

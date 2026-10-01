import Foundation

/// The suggested questions offered when a Coach thread is empty (#1862).
///
/// Extracted from `CoachView` so the Today launcher sheet and the full screen offer the SAME four
/// prompts. Two hardcoded lists would have drifted the moment either was edited, and the launcher's
/// whole purpose is to be a shortcut into the screen rather than a second, subtly different Coach.
///
/// The strings are unchanged and keep their existing String Catalog keys, so nothing needs retranslating.
enum CoachPrompts {
    static let suggestions: [String] = [
        String(localized: "How did I sleep last night?"),
        String(localized: "Is my HRV normal for me?"),
        String(localized: "What's affecting my recovery?"),
        String(localized: "How is my resting heart rate trending?"),
    ]
}

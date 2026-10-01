import Foundation

/// Suggested next questions shown under a finished answer. Chosen from what the answer talks about, so no extra
/// model call is needed; the first matching topic wins and the last entry is the general fallback.
enum CoachFollowUps {
    private static let topics: [(keywords: [String], prompts: [String])] = [
        (["sleep", "slept", "bedtime", "rest ", "nap"],
         ["What would help me sleep better tonight?", "How does my sleep compare with last week?"]),
        (["hrv", "heart rate variability", "resting heart", "recovery", "charge"],
         ["What's behind that change?", "What should I do today because of it?"]),
        (["stress", "breath", "respiratory"],
         ["What can I do to lower my stress?", "Is this normal for me?"]),
        (["protein", "nutrition", "calorie", "hydrat", "water", "caffeine", "alcohol"],
         ["Turn that into a simple daily habit", "How does this affect my recovery?"]),
        (["effort", "strain", "workout", "training", "steps"],
         ["How should I balance effort and rest this week?", "How does that compare with my recent days?"]),
    ]

    private static let general = ["What should I focus on this week?", "How does that compare with my recent data?"]

    static func forAnswer(_ text: String) -> [String] {
        let lowered = text.lowercased()
        return topics.first { topic in topic.keywords.contains { lowered.contains($0) } }?.prompts ?? general
    }
}

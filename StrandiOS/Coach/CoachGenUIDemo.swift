#if DEBUG
import OpenUILang
import StrandDesign
import SwiftUI

/// DEBUG-only `--demo-screen genui` / `genui2`: sample Sana cards rendered as they are in the chat, with the message
/// a card would send shown at the top, so the generative UI can be screenshotted and driven by UI tests without a
/// model.
struct CoachGenUIDemoScreen: View {
    var page = 1

    @State private var sent = ""

    static let insight = """
    root = Card([header, stats, Visual(), tip])
    header = CardHeader("Your HRV this week", "Up 8% on last week")
    stats = StatGrid([Stat("Average", "58 ms", "7 nights", "good"), Stat("Lowest", "46 ms", "Tue, after legs", "caution")])
    tip = Callout("tip", "Keep the 22:45 bedtime", "Your three best nights all started before 23:00.")
    """

    static let week = """
    root = Card([header, form])
    header = CardHeader("Build your week", "Three quick questions")
    form = Form("week", Button("Build my plan", null, "primary"), [days, goal, minutes])
    days = FormControl("Training days", Stepper("days", 2, 6, 1, 4, "days"))
    goal = FormControl("Main goal", Chips("goal", [ChipItem("endurance", "Endurance"), ChipItem("strength", "Strength"), ChipItem("both", "Both")], "single", "both"))
    minutes = FormControl("Time per session", Slider("minutes", 20, 90, 5, 45, "min"))
    """

    static let water = """
    root = Card([header, weight, result, plan])
    header = CardHeader("Daily water")
    $kg = 70
    weight = FormControl("Body weight", Slider("kg", 40, 140, 1, 70, "kg", $kg))
    result = TextContent("About **" + @Round($kg * 0.033, 1) + " L** a day, plus 0.5 L per hour of training.", "large")
    plan = ProgressBar("Today so far", 1.4, @Round($kg * 0.033, 1), "L")
    """

    static let breathing = """
    root = Card([header, breath, timer, done])
    header = CardHeader("Box breathing")
    $pace = 4
    breath = FormControl("Seconds per side", Slider("pace", 3, 6, 1, 4, "s", $pace))
    timer = Timer("Inhale · hold · exhale · hold", $pace * 4, 6)
    done = Buttons([Button("That helped", Action([@ToAssistant("The box breathing helped. What next?")]), "secondary")])
    """

    private var cards: [String] { page == 1 ? [Self.insight, Self.water] : [Self.week, Self.breathing] }

    private var hrv: CoachViz? {
        let json = #"{"type":"line","title":"HRV","yLabel":"ms","points":[{"x":"Thu","y":52},{"x":"Fri","y":55},{"x":"Sat","y":61},{"x":"Sun","y":63},{"x":"Mon","y":57},{"x":"Tue","y":46},{"x":"Wed","y":60}]}"#
        return try? JSONDecoder().decode(CoachViz.self, from: Data(json.utf8))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(sent.isEmpty ? "Nothing sent yet" : sent)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityIdentifier("genuiDemo.sent")
                ForEach(cards, id: \.self) { source in
                    CoachGenUICard(source: source, streaming: false, interactive: true,
                                   visual: hrv.map { AnyView(CoachVizView(viz: $0)) },
                                   onSend: { text, _, _ in sent = text; return true },
                                   onStateChange: { _ in })
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }
}
#endif

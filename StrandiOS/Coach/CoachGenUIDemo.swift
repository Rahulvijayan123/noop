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

    /// `genui3`: an Open Generative UI tool as the visual pipeline returns it.
    static let bedtime = CoachViz(
        type: "custom", title: "Bedtime from your wake time", subtitle: "Drag to your alarm; cycles are about 90 minutes",
        source: "Example defaults",
        custom: .init(height: 300, css: """
        .times{display:grid;grid-template-columns:repeat(3,1fr);gap:8px}
        .opt{padding:10px;border-radius:var(--radius);background:var(--surface-inset);text-align:center}
        .opt.best{background:var(--accent-soft);color:var(--accent)}
        canvas{width:100%;height:56px;display:block}
        """, html: """
        <div class="stack">
          <div class="row"><label for="w">Wake at</label><span class="value" id="wv">6:30</span></div>
          <input type="range" id="w" min="300" max="600" step="15" value="390">
          <canvas id="c"></canvas>
          <div class="times" id="t"></div>
          <button id="ask">Plan my evening around this</button>
        </div>
        """, js: """
        (() => {
          const w = document.getElementById('w'), wv = document.getElementById('wv'), t = document.getElementById('t');
          const c = document.getElementById('c'), ctx = c.getContext('2d');
          const fmt = (m) => { m = ((m % 1440) + 1440) % 1440; const h = Math.floor(m / 60), mm = m % 60; return h + ':' + String(mm).padStart(2, '0'); };
          const css = (v) => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
          let best = '';
          const draw = () => {
            const wake = +w.value; wv.textContent = fmt(wake);
            const opts = [6, 5, 4].map((n) => ({ n, at: wake - n * 90 - 15 }));
            best = fmt(opts[0].at);
            t.innerHTML = opts.map((o, i) => '<div class="opt' + (i === 0 ? ' best' : '') + '"><div class="value" style="font-size:20px">' + fmt(o.at) + '</div><small>' + o.n + ' cycles</small></div>').join('');
            const r = window.devicePixelRatio || 1; c.width = c.clientWidth * r; c.height = c.clientHeight * r; ctx.scale(r, r);
            const W = c.clientWidth, H = c.clientHeight; ctx.clearRect(0, 0, W, H);
            for (let i = 0; i < 6; i++) { const x = (i / 6) * W; ctx.fillStyle = i % 2 ? css('--series-2') : css('--accent'); ctx.globalAlpha = 0.85; ctx.beginPath(); ctx.roundRect(x + 2, 14, W / 6 - 4, H - 28, 8); ctx.fill(); }
            ctx.globalAlpha = 1;
          };
          w.addEventListener('input', draw);
          document.getElementById('ask').addEventListener('click', () => window.nara.send('Plan my evening for a ' + best + ' bedtime'));
          draw();
        })();
        """))

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(sent.isEmpty ? "Nothing sent yet" : sent)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .accessibilityIdentifier("genuiDemo.sent")
                if page == 3 {
                    CoachVizView(viz: Self.bedtime)
                        .environment(\.coachSandboxSend) { sent = $0 }
                }
                ForEach(page == 3 ? [] : cards, id: \.self) { source in
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

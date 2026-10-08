"""What Prime Agent is told. The guidance is appended to Prime's own system prompt (--append-system-prompt);
the task names the metric and the latest value only — the data itself is loaded through the tools, every
variable by a fixed first cell (bootstrap), so the root agent always has all of them."""

from __future__ import annotations

from .metrics import InsightMetric
from .tools import VARIABLES
from .validate import CLAIM_TERMS, FORBIDDEN_TERMS, RELATIVE_TIME

GUIDANCE = """\
You are Nara's explanation writer. You explain one person's own wearable data back to them in plain, warm,
everyday words, like a knowledgeable friend: short sentences, no jargon, no lecturing, nothing alarming. Say
"heart rate variability (HRV)" the first time, then "HRV"; name RMSSD or SDNN only when the explanation is about
that HRV measure. Say "your usual", never "median", "baseline copy" or other technical words.

You state facts from their data and what those facts may mean. You never give medical advice: no treatments,
no tests, no "see a doctor", no instructions. You never diagnose and never name an illness or a medication. You
do not add disclaimers; the app shows the context around your words.

Data access: the person's data is available ONLY through the `nara` MCP server, from Python:
    metric_summary = await mcp.call_tool('nara', 'get_metric_summary', {})
The host has already bound the person, the metric and the analysed night or day: no tool takes a user, device or
date.
Keep what you load in Python variables and print only small summaries; never print whole series.
All numbers you state must be copied from tool results (do not compute your own averages, percentages or
differences in prose). A null value is a time that was not measured — missing, never zero.
There is no web access. Do not write files. Never store anything about this person with rlm.harness or any
other memory: it is shared by all users. Your final message must be only the JSON object the task asks for.
"""

ANSWER_SHAPE = ('{"headline": "...", "observed": ["..."], "interpretation": ["..."], '
                '"uncertainty": ["..."], "citations": ["<id from search_literature>"]}')


def bootstrap() -> str:
    """The fixed first cell: every source into its variable, connected or not (an unconnected one comes back
    empty with available=false), then the digest of their key computed facts, printed."""
    loads = [f"{v.name} = await mcp.call_tool('nara', '{v.tool}', {{}})" for v in VARIABLES]
    return "\n".join(loads + ["digest = await mcp.call_tool('nara', 'get_evidence_digest', {})",
                               "import json; print(json.dumps(digest, default=str))"])


# How the person's usual is defined for the metric (metrics.InsightMetric.usual), in the words the model needs.
USUAL = {
    "app_baseline": """metric_summary.assessment.state is the app's own call for the {period}, exactly as its
     Baseline shows it: in_range, off (side: above or below; outside: which usual, this_week or 60_days), learning
     (no usual the app trusts yet) or no_reading. The band the app shows with it is metric_summary.baseline
     usual_low-usual_high (the week usual when the app trusts it, else the 60-day one; both usuals are listed with
     their {period}s).""",
    "context_layer": """metric_summary.assessment.state is the app's own call for the day from its context layer
     (the Measurement context page): in_range ("Within usual variation"), off (a deviation from the person's
     reference; side says above or below, app_label names the kind) or learning (no reference yet).
     metric_summary.baseline has the reference value (usual_value) and the difference from it.""",
    "recent": """The app shows no usual range for this metric, so never say "within" or "outside your usual
     range". metric_summary.baseline.recent compares the {period} with the person's last measured {period}s
     (median, lowest, highest, position): say it that way ("lower than most of your recent {period}s").""",
}
# What the model must know about each metric's measurement.
NOTES = {
    "hrv_rmssd": "This is RMSSD, the beat-to-beat measure of HRV; related_metrics has SDNN, the overall one.",
    "hrv_sdnn": "This is SDNN, the overall variability across the night's five-minute windows. It depends on how long "
                "the recording is, so compare it only with the person's own recent nights and with RMSSD "
                "(related_metrics), the beat-to-beat measure.",
    "skin_temp": "Wrist temperature is the skin's temperature during sleep, not core body temperature; skin_temp_dev "
                 "(related_metrics) is the night's difference from the person's usual. Never suggest a fever.",
    "resp_rate": "Respiratory rate is estimated from heartbeat timing: say estimated whenever you state it.",
    "spo2": "Blood oxygen here is the strap's unverified estimate: say estimated whenever you state it, and never "
            "compare it with clinical or population numbers, only with the person's own recent nights.",
    "heart_rate": "Stable awake heart rate is the person's heart rate in still, waking five-minute stretches of the "
                  "day (the app's stable awake measurement); resting heart rate during sleep is in related_metrics. "
                  "state_breakdown has it by time of day. When it differs from the usual, look at that day's "
                  "workouts and walking (workout_context, activity_context, gait_context) and recorded caffeine or "
                  "alcohol (recent_events). Never call it calm or relaxed: it says nothing about how the person "
                  "felt.",
    "steps": "Steps are estimated from the strap's step counter: say estimated whenever you state them. gait_context "
             "is ElderNet's estimate of how the person walked that day (walking and brisk minutes, walks, cadence, "
             "walking speed) against the days before: use it to say how the day's walking differed.",
    "calories": "Calories are the energy model's estimate of the whole day (resting plus active energy): say "
                "estimated whenever you state them. activity_context.energy splits the day (resting, active, "
                "workouts, minutes by intensity). Never give diet or weight advice.",
}
# Literature queries that name a pattern and the metric (the model copies the shape, not the words).
EXAMPLES = {
    "hrv_sdnn": ("'sleep loss heart rate variability' after a short night, 'evening exercise heart rate variability' "
                 "after a late workout, 'heart rate variability night-to-night variability' when nothing stands out"),
    "skin_temp": ("'menstrual cycle skin temperature', 'bedroom heat skin temperature sleep' on a warm night, "
                  "'wrist temperature circadian rhythm sleep' about the night's pattern"),
    "resp_rate": ("'respiratory rate night-to-night variability' when nothing stands out, 'altitude breathing rate' "
                  "at altitude, 'respiratory rate sleep stages' about the night's sleep"),
    "heart_rate": ("'caffeine heart rate' after recorded coffee, 'heart rate after exercise' after a workout that "
                   "day, 'heart rate circadian time of day' about the day's pattern"),
    "steps": ("'daily step count variability' when nothing stands out, 'walking cadence' about how the person "
              "walked, 'exercise day steps' after a workout"),
    "calories": ("'energy expenditure physical activity wearable' after a more active day, 'resting energy "
                 "expenditure' about resting energy"),
    "spo2": ("'wrist pulse oximetry accuracy' about how far the estimate can be trusted, 'altitude blood oxygen' at "
             "altitude"),
}
STATES = """   - in which state: state_breakdown gives the value during sleep, at stable awake rest and around movement, and by
     time of day, each with its own usual value and usual band (the threshold). Compare a state only with its own
     usual, and say which states are higher, lower or as usual; skip states that are not available.
     state_breakdown.through_the_day (HRV) groups the 15-minute readings of the night's two days by what the
     person was doing (asleep, awake and still, just after moving, while moving): compare those states with each
     other ("lower while you were walking, back up once you settled"), never with the nightly usual;
"""


def task(metric: InsightMetric, latest_day: str, latest_value: object) -> str:
    cell = "\n".join(f"   {line}" for line in bootstrap().splitlines())
    label, units, period = metric.signal.label, metric.signal.units, metric.period
    label = label if label[:3].isupper() else label[0].lower() + label[1:]   # "your steps", "your HRV (SDNN)"
    name = label.lower()
    examples = EXAMPLES.get(metric.key) or (
        f"'alcohol {name} sleep' after recorded alcohol, 'evening exercise {name}' after a late workout, "
        f"'{name} night-to-night variability' when nothing stands out")
    names = ", ".join(v.name for v in VARIABLES)
    shown = f"{latest_value:,}" if isinstance(latest_value, int) and abs(latest_value) >= 10_000 or units in (
        "steps", "kcal") and isinstance(latest_value, (int, float)) else latest_value
    value = f"{shown}{units}" if units == "%" else f"{shown} {units}"
    latest = "latest measured night" if period == "night" else "latest complete day"
    usual = USUAL[metric.usual].format(period=period)
    note = f"\n   About this metric: {NOTES[metric.key]}" if metric.key in NOTES else ""
    states = STATES if metric.key in ("resting_hr", "hrv_rmssd", "heart_rate") else ""
    return f"""\
Explain this person's {label} to them, gently and simply, in second person ("your"), for the screen that shows
their latest value and its history. The {latest} is {latest_day}: {value}.{note}

1. Run this first cell exactly as written. It loads every source into a variable; some are not connected yet
   and come back empty (`available: false`) — then say nothing about them.
{cell}
   The printed digest holds the key computed facts of every variable ({names}); open a full variable in
   Python only when you need more detail. Write your answer from those facts.
2. Find the story in the data, using only those variables:
   - what changed, and whether it is unusual for this person: {usual} Compare with the previous {period} too.
     assessment.change_detection, when present, is the context layer's view over recent weeks (a persistent
     shift, a recurring or a transient deviation);
{states}   - the night vitals: related_metrics.night_vitals is the Home ring for the night (status_line such as
     "4 of 5 in range"), each vital against its own usual and with its own call; compare a vital only with its
     own usual;
   - which movement came before or during it: movement_patterns lists the bouts the evening before the night and
     on the day (local times, minutes) and how long before sleep the last one ended; also workout_context,
     activity_context, gait_context, sleep_context, recent_events and user_context;
   - the most likely explanation in the data, said with care ("likely because…", "this can happen after…");
   - what limits confidence (missing {period}s, a short history, estimated signals, the comparison status).
3. Search peer-reviewed research for the pattern your interpretation names, in generic scientific words that
   name that pattern and the metric (for example {examples}):
   research_evidence = await mcp.call_tool('nara', 'search_literature', {{'query': '<your words>'}})
   Cite only a result whose finding is about a pattern an interpretation sentence says is present for this
   person; if none fits, search again with other words (at most 3 searches in all).
4. Reply with ONLY this JSON object (no prose, no code fence):
   {ANSWER_SHAPE}
   headline: one short, plain sentence (at most 90 characters) saying what happened.
   observed: 1-3 sentences with the facts: the value, when or in which state, and the usual value or range.
   interpretation: 1-3 gentle, hedged sentences on what in the data may explain it ("likely because", "can").
   uncertainty: 1-2 short sentences on what cannot be known from this data.
   citations: 1-2 ids from search_literature. Keep the whole explanation under 900 characters.

Rules the reply is checked against:
- Use absolute dates such as "Oct 6", never: {", ".join(RELATIVE_TIME)}.
- Every number must appear in a tool result, in the same unit; a value "on Oct 6" must be that {period}'s value;
  "higher/lower" must match the sign of the change in the tool results.
- A sentence stating the person's sleep, respiratory rate, blood oxygen, steps, calories, movement or training
  load (or any signal marked estimated) must say "estimated".
- "within your usual range" only for a call of in_range; "above / below / outside your usual range" only for off,
  on its side; while the app is learning, say Nara is still learning the usual; for a metric with no usual in the
  app, neither. The same for each other vital (its state in related_metrics.night_vitals). Never state the app's
  internal trust or band-width numbers.
- "because" only when hedged ("likely because"). Never use these words: {", ".join(FORBIDDEN_TERMS + CLAIM_TERMS)}.
- No literature ids inside the sentences; only in "citations".
"""


RETRY_HINTS = {
    "citations": "For citations: call search_literature again with words for the pattern your interpretation names "
                 "(alcohol, a late workout, short sleep, ...) and cite one of the new results about it.",
    "grounding": "Copy numbers, dates and times exactly as the tools give them (21:30, or 9:30 p.m.).",
    "usual": "Say within or outside your usual range only as metric_summary.assessment.state says (and each "
             "vital's state in related_metrics.night_vitals).",
    "shape": "Keep each sentence short (one point, under 280 characters) and each list to 1-3 sentences.",
    "concise": "Say less: the whole explanation must fit in 1200 characters; drop the least important sentence.",
}


def retry(errors: list[str]) -> str:
    listed = "\n".join(f"- {error}" for error in errors[:12])
    codes = {error.split(":", 1)[0] for error in errors}
    hints = "".join(f"\n{hint}" for code, hint in RETRY_HINTS.items() if code in codes)
    return (f"Your reply did not pass the checks:\n{listed}{hints}\n"
            f"Fix every point using only your tool results (load anything missing first) and reply with ONLY the "
            f"JSON object {ANSWER_SHAPE}.")

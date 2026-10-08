"""The gate between the model and the screen. An answer is published only if it passes every check here:

1. shape: {headline, observed[], interpretation[], uncertainty[], citations[]}, short sentences, concise overall;
2. text: NFKC-normalised; invisible characters, mixed-script words and non-ASCII digits are refused outright;
3. wording: none of the app's forbidden terms (PhysiologyContextWording.forbiddenTerms, kept identical — see
   tests/test_validate.py — and caught with their inflections), no diagnosis / causal / certainty words, no
   relative days ("yesterday" is wrong the day after it is cached);
4. grounding: a number with a unit must be a value of that unit in the tool results (a change counts by its size);
   a direction word must agree with the sign of the change it states; zero is never a measurement; spelled-out
   numbers, clock times and dates are checked too; the person's own notes and labels ground nothing;
5. estimates: a sentence that states the person's value of a signal the evidence marks as estimated says so;
6. citations: only literature retrieved in this job, each backing a non-negated interpretation sentence.

Changing any rule here changes what is published: bump internal.metric_insight_version() (a new migration) so
cached analyses are redone.
"""

from __future__ import annotations

import json
import math
import re
import unicodedata
from dataclasses import dataclass, field
from datetime import date
from typing import Any

# PhysiologyContextWording.forbiddenTerms (Strand/Screens/MeasurementContextWording.swift), verbatim.
FORBIDDEN_TERMS: tuple[str, ...] = (
    "calm", "calmer", "calmness", "stress", "stressed", "stressful", "recovered", "relaxed", "relaxation",
    "anxious", "anxiety", "tired", "fatigue", "fatigued", "exhausted", "exhaustion", "burnout", "mood",
    "depressed", "illness", "ill", "sick", "sickness", "infection", "infected", "fever", "disease",
    "diagnosis", "diagnosed", "symptomatic", "medication effect", "drug effect", "side effect",
    "overtrained", "overtraining",
)
# Inflections and close forms of the app's terms (the app's list is exact words; this gate is stricter).
FORBIDDEN_FORMS: tuple[str, ...] = (
    "stresses", "stressing", "stressor", "stressors", "illnesses", "sicker", "sickest", "sicknesses",
    "infections", "infectious", "fevers", "feverish", "diseases", "diagnose", "diagnoses", "diagnosing",
    "diagnostic", "symptom", "symptoms", "anxieties", "depression", "exhausting", "fatiguing", "relaxing",
    "calming", "medication effects", "drug effects", "side effects", "burned out", "burnt out", "burn out",
    "overtrain",
)
# Diagnosis, unsupported causation and false certainty.
CLAIM_TERMS: tuple[str, ...] = (
    "cause", "causes", "caused", "causing", "due to", "led to", "leads to", "lead to", "leading to",
    "resulted in", "results in", "result of", "results from", "resulting from", "triggered", "triggers",
    "responsible for", "drove", "driven by", "proves", "proven", "disorder", "syndrome", "abnormal", "dangerous",
    "emergency", "treatment", "treat", "prescribe", "prescription", "cure", "definitely", "certainly",
    "guaranteed", "virus", "viral", "flu", "covid", "inflammation", "immune", "deficiency", "dehydrated",
    "hangover", "doctor", "physician", "medical advice",
)
RELATIVE_TIME: tuple[str, ...] = (
    "today", "yesterday", "tonight", "tomorrow", "last night", "this morning", "this afternoon", "this evening",
    "right now", "this week", "last week", "this weekend", "last weekend", "the other day", "ago",
    "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
)
# How a sentence names a signal. For estimated ones, a sentence stating the person's value must say "estimated".
ALIASES: dict[str, tuple[str, ...]] = {
    "resting_hr": ("resting heart rate", "resting hr", "rhr"),
    "hrv_rmssd": ("heart rate variability", "hrv", "rmssd"),
    "resp_rate": ("respiratory rate", "breathing rate", "breaths per minute", "breaths/min", "breathing"),
    "spo2": ("blood oxygen", "oxygen saturation", "oxygen level", "spo2", "oxygen"),
    "skin_temp": ("wrist temperature", "wrist temp", "skin temperature", "skin temp"),
    "skin_temp_dev": ("temperature deviation",),
    "hrv_sdnn": ("sdnn",),
    "heart_rate": ("stable awake heart rate", "stable heart rate", "awake heart rate"),
    "steps": ("steps", "step count"),
    "calories": ("calories", "calorie", "kcal", "energy expenditure", "energy burned"),
    # An estimated sleep MEASURE (not "during sleep", which names the state an HRV or heart-rate reading was in).
    "sleep": ("sleep duration", "sleep efficiency", "sleep timing", "sleep length", "sleep was", "sleep is",
              "shorter sleep", "longer sleep", "less sleep", "more sleep", "hours of sleep", "slept", "bedtime",
              "wake time", "woke", "fell asleep", "deep sleep", "rem sleep", "light sleep", "sleep stage"),
    "activity": ("training load", "locomotion", "movement", "workout", "exercise", "activity", "active minutes",
                 "steps", "training"),
}
SIGNAL_GROUP = {"sleep_total": "sleep", "sleep_efficiency": "sleep"}
# The signals an explanation may place inside or outside a usual (the app's call), or, for a metric with no usual in
# the app, must not (call "no_usual"), by their names here.
SIGNAL_CALLS = frozenset({"resting_hr", "hrv_rmssd", "hrv_sdnn", "resp_rate", "spo2", "skin_temp", "heart_rate",
                          "steps", "calories"})
# The Home ring's night vitals (evidence.NIGHT_VITALS) by the signal whose wording they share.
VITAL_GROUP = {"sleep_rhr": "resting_hr", "sleep_hrv_ln": "hrv_rmssd", "sleep_temp": "skin_temp",
               "sleep_resp": "resp_rate", "sleep_spo2_mean": "spo2"}
# Phrases that only state the person's own value after "your" ("your sleep was short"); a number near them is
# usually some other reading taken during sleep ("the 51 ms during sleep was below ...").
YOUR_ONLY = frozenset({"sleep was", "sleep is", "shorter sleep", "longer sleep", "less sleep", "more sleep",
                       "movement", "activity", "training", "exercise", "breathing", "oxygen"})
# A cited finding must be about something the explanation says (by the curated entry's topic).
TOPIC_WORDS: dict[str, tuple[str, ...]] = {
    "alcohol": ("alcohol", "drink", "wine", "beer"), "caffeine": ("caffeine", "coffee"),
    "sleep_restriction": ("sleep",),
    "training_load": ("training", "exercise", "workout", "exertion", "load", "cycling", "cycled", "ride", "running",
                      "ran", "walk", "bout", "session"),
    "detraining": ("training", "exercise", "fitness"), "aerobic_fitness": ("fitness", "training", "exercise"),
    "heat": ("heat", "hot", "warm", "humid", "bedroom", "weather"), "altitude": ("altitude", "elevation"),
    "hydration": ("hydration", "fluid", "water"), "menstrual_cycle": ("menstrual", "menstruation", "luteal", "ovulat"),
    "seasonality": ("season", "winter", "summer"), "age": ("age",),
    "normal_range": ("usual", "range", "normal", "typical", "vary", "variation", "differ"),
    "day_to_day_variability": ("night-to-night", "day-to-day", "vary", "variation", "common", "usual"),
    "wearable_accuracy": ("measure", "measurement", "sensor", "device", "wear", "accuracy", "estimat", "strap"),
    "posture": ("posture", "standing", "lying", "supine", "upright", "sitting"),
    "physical_activity": ("activity", "movement", "moving", "walk", "walking", "steps", "exercise"),
    "sleep_architecture": ("deep sleep", "rem", "sleep stage", "slow-wave", "sleep"),
    "circadian": ("circadian", "rhythm", "body clock", "time of day", "night", "daytime", "evening", "morning"),
}
UNITS: dict[str, str] = {
    "bpm": "bpm", "beats per minute": "bpm", "ms": "ms", "millisecond": "ms", "milliseconds": "ms",
    "h": "h", "hr": "h", "hrs": "h", "hour": "h", "hours": "h", "min": "min", "mins": "min", "minute": "min",
    "minutes": "min", "%": "%", "percent": "%", "breaths/min": "breaths/min", "breaths per minute": "breaths/min",
    "°c": "°C", "degrees": "°C", "mg": "mg", "ml": "ml", "g": "g", "drink": "drinks", "drinks": "drinks",
    "steps": "steps", "step": "steps", "kcal": "kcal", "calories": "kcal", "calorie": "kcal",
    "steps/min": "spm", "steps per minute": "spm", "spm": "spm", "m/s": "m/s", "km/h": "km/h",
    "meters per second": "m/s", "metres per second": "m/s", "kilometers per hour": "km/h",
    "kilometres per hour": "km/h",
}
MEASURED_UNITS = frozenset({"bpm", "ms", "breaths/min", "kcal"})  # a value of these is never zero (steps can be)
CHANGE_UNITS = frozenset({"bpm", "ms", "h", "min", "%", "breaths/min", "°C", "steps", "kcal", "spm"})
NUMBER_WORDS = {w: i for i, w in enumerate(
    "zero one two three four five six seven eight nine ten eleven twelve thirteen fourteen fifteen sixteen "
    "seventeen eighteen nineteen twenty".split())} | {"thirty": 30, "forty": 40, "fifty": 50, "sixty": 60,
                                                      "seventy": 70, "eighty": 80, "ninety": 90}
# Not "over"/"under": "51 bpm over the last 7 nights" is about time, not a change.
UP_WORDS = ("higher", "above", "more", "up", "rose", "risen", "increased", "climbed", "jumped")
DOWN_WORDS = ("lower", "below", "less", "down", "fell", "fallen", "dropped", "decreased", "declined")

MONTHS = {m: i for i, m in enumerate(
    ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"), start=1)}
# Capitalised only: "a change of 3 may..." is not May 3.
_MONTH = (r"(Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|June?|July?|Aug(?:ust)?|Sept?(?:ember)?|"
          r"Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)\.?")
_MONTH_DAY = re.compile(rf"\b{_MONTH}\s+(\d{{1,2}})(?:st|nd|rd|th)?(?:,?\s+(\d{{4}}))?\b")
_DAY_MONTH = re.compile(rf"\b(\d{{1,2}})(?:st|nd|rd|th)?\s+(?:of\s+)?{_MONTH}(?:,?\s+(\d{{4}}))?\b")
_ISO_DAY = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
_SLASH_DAY = re.compile(r"\b\d{1,2}/\d{1,2}(?:/\d{2,4})?\b")
_CLOCK = re.compile(r"\b(\d{1,2}):(\d{2})\b(?:\s*([ap])\.?\s*m\b\.?)?", re.I)  # 21:30, or 9:30 p.m.
_HOUR = re.compile(r"(?<![\d:.])\b(1[0-2]|0?[1-9])\s*([ap])\.?\s*m\b\.?", re.I)  # 6 am, 6 p.m.: on the hour
_UNIT_RE = "|".join(sorted((re.escape(u) for u in UNITS), key=len, reverse=True))
_DIRECTIONS = "|".join(UP_WORDS + DOWN_WORDS)
# A number as people write it: 52, 52.4, 8,123 (thousands separators), 12,345.6.
_NUM = r"\d{1,3}(?:,\d{3})+(?:\.\d+)?|\d+(?:\.\d+)?"
_NUMBER = re.compile(rf"(?<![\w.,])([-+−]?(?:{_NUM}))(?![\d,]\d)(?!st\b|nd\b|rd\b|th\b)\s*(?:({_UNIT_RE})(?![a-z]))?",
                     re.I)
_NUMBER_WORD = re.compile(r"\b(" + "|".join(sorted(NUMBER_WORDS, key=len, reverse=True)) + r")(?:-(one|two|three|"
                          r"four|five|six|seven|eight|nine))?\b", re.I)
_DIRECTION_AFTER = re.compile(rf"(?<![\w.,])({_NUM})\s*({_UNIT_RE})(?![a-z])\s+(?:\w+\s+)?({_DIRECTIONS})\b", re.I)
_DIRECTION_BEFORE = re.compile(rf"\b({_DIRECTIONS})\s+(?:by\s+)?({_NUM})\s*({_UNIT_RE})?(?![a-z])", re.I)
_PMID_OR_DOI = re.compile(r"\bpmid\s*[:#]?\s*\d+|\b10\.\d{4,9}/\S+", re.I)
_NEGATION = re.compile(r"\b(no|not|none|nothing|without|never|neither|nor)\b|n['’]t\b", re.I)
# "because" explains with the person's own data ("likely because you walked 40 minutes that evening"); it must be
# hedged, since a pattern in the data is an association, not proof. An uncertainty sentence may say plainly why a
# reading is less certain ("less certain because SpO2 is estimated from the wrist"): that is about the data.
_BECAUSE = re.compile(r"\bbecause\b", re.I)
_DATA_LIMIT = re.compile(r"\b(estimat\w*|measur\w*|readings?|data|sensors?|signals?|coverage|missing|gaps?|fewer|"
                         r"worn|wear|recorded|samples?|nights? of|days? of)\b", re.I)
_HEDGE = re.compile(r"\b(likely|probably|possibly|may|might|can|could|often|typically|usually|tends?|"
                    r"perhaps|partly)\b", re.I)
_YOU_VERB = {"sleep": re.compile(r"\byou\s+(?:\w+\s+){0,2}(slept|woke|fell asleep)\b", re.I),
             "activity": re.compile(r"\byou\s+(?:\w+\s+){0,2}(trained|exercised|walked|ran|worked out)\b", re.I)}

MAX_HEADLINE = 120
MAX_SENTENCE = 280
MAX_TOTAL = 1200
MAX_ITEMS = 3
MIN_CITATIONS = 1  # every explanation carries at least one peer-reviewed source to check it against
LIMIT_TOPICS = frozenset({"wearable_accuracy"})  # findings about the measurement itself, not the person
# Window lengths the tools state in words ("the last 7 nights", "up to 30 nights", "90 days").
WINDOW_NUMBERS = (7, 14, 30, 90)


@dataclass
class Result:
    ok: bool
    answer: dict[str, Any] | None = None
    errors: list[str] = field(default_factory=list)

    @property
    def codes(self) -> list[str]:
        return sorted({e.split(":", 1)[0] for e in self.errors})


def _pattern(term: str) -> re.Pattern[str]:
    return re.compile(r"\b" + r"\s+".join(map(re.escape, term.split())) + r"\b", re.I)


def _inflected(term: str) -> re.Pattern[str]:
    if " " in term:
        return re.compile(r"\b" + r"\s+".join(map(re.escape, term.split())) + r"s?\b", re.I)
    return re.compile(r"\b" + re.escape(term) + r"(?:s|es|ed|ing|ness|nesses)?\b", re.I)


_FORBIDDEN = [(t, _inflected(t)) for t in FORBIDDEN_TERMS] + [(t, _pattern(t)) for t in FORBIDDEN_FORMS]
_CLAIMS = [(t, _pattern(t)) for t in CLAIM_TERMS]
_RELATIVE = [(t, _pattern(t)) for t in RELATIVE_TIME]


def forbidden_term(text: str) -> str | None:
    """The first app-forbidden term (or inflection) in text, after normalisation; whole words only."""
    normal = unicodedata.normalize("NFKC", text)
    return next((t for t, p in _FORBIDDEN if p.search(normal)), None)


def text_problems(text: str) -> list[str]:
    """Characters that can hide words from the checks are refused rather than cleaned up."""
    problems = []
    if any(unicodedata.category(ch) == "Cf" for ch in text):
        problems.append("text:invisible characters are not allowed")
    if any(ch.isdigit() and not ("0" <= ch <= "9") for ch in text):
        problems.append("text:use ASCII digits only")
    for word in re.findall(r"[^\W\d_]+", text):
        scripts = {unicodedata.name(ch, "UNKNOWN").split(" ", 1)[0] for ch in word if ch.isalpha()}
        if scripts and scripts != {"LATIN"}:
            problems.append(f"text:'{word}' uses non-Latin letters")
            break
    return problems


def parse(text: str) -> tuple[dict[str, Any] | None, str | None]:
    raw = (text or "").strip()
    fenced = re.match(r"^```(?:json)?\s*(.*?)\s*```$", raw, re.S)
    if fenced:
        raw = fenced.group(1)
    start, end = raw.find("{"), raw.rfind("}")
    if start < 0 or end <= start:
        return None, "shape:no JSON object in the reply"
    try:
        value = json.loads(raw[start:end + 1])
    except json.JSONDecodeError as exc:
        return None, f"shape:invalid JSON ({exc.msg})"
    if not isinstance(value, dict):
        return None, "shape:the reply is not a JSON object"
    return value, None


# --------------------------------------------------------------------------- facts from the evidence


@dataclass
class Facts:
    by_unit: dict[str, set[float]] = field(default_factory=dict)
    signed: dict[str, set[float]] = field(default_factory=dict)
    counts: set[float] = field(default_factory=lambda: {float(n) for n in WINDOW_NUMBERS})
    days: set[date] = field(default_factory=set)
    clocks: set[str] = field(default_factory=set)
    literature: set[float] = field(default_factory=set)
    estimated: set[str] = field(default_factory=lambda: {"sleep", "activity", "calories"})
    # The value of a unit on a night, where the tools state it (the metric's nights, each signal's latest night,
    # the sleep nights): "59 bpm on Oct 6" must be Oct 6's value, not any bpm value.
    on_day: dict[tuple[str, date], set[float]] = field(default_factory=dict)
    # The app's call for each signal on the analysed night (in_range, off, learning, no_reading) and, when off, the
    # side; `metric` is the screen's own signal, the subject of a sentence that names none.
    calls: dict[str, str] = field(default_factory=dict)
    sides: dict[str, str] = field(default_factory=dict)
    metric: str | None = None
    # Each signal's own values (and change sizes) by unit: a number said about one signal must not be another's.
    by_signal: dict[tuple[str, str], set[float]] = field(default_factory=dict)

    def own(self, signal: Any, unit: str, value: Any) -> None:
        number = _num(value)
        if number is not None and signal:
            self.by_signal.setdefault((str(signal), unit), set()).add(abs(number))

    def dated(self, unit: str, day: Any, value: Any) -> None:
        number = _num(value)
        if number is None or not isinstance(day, str):
            return
        try:
            key = (unit, date.fromisoformat(day))
        except ValueError:
            return
        self.on_day.setdefault(key, set()).add(number)

    def add(self, unit: str, value: Any) -> None:
        number = _num(value)
        if number is not None:
            self.by_unit.setdefault(unit, set()).add(number)

    def change(self, unit: str, value: Any) -> None:
        number = _num(value)
        if number is not None:
            self.signed.setdefault(unit, set()).add(number)

    def count(self, value: Any) -> None:
        number = _num(value)
        if number is not None:
            self.counts.add(number)

    def unit_values(self, unit: str) -> set[float]:
        return self.by_unit.get(unit, set()) | {abs(v) for v in self.signed.get(unit, set())}

    def any_values(self) -> set[float]:
        out = set(self.counts)
        for unit in set(self.by_unit) | set(self.signed):
            out |= self.unit_values(unit)
        return out


def _num(value: Any) -> float | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)) and math.isfinite(value):
        return float(value)
    return None


def _listed(value: Any) -> list[dict[str, Any]]:
    """A tool's results: its default call, or several calls (the ones the model actually made)."""
    if isinstance(value, list):
        return [v for v in value if isinstance(v, dict)]
    return [value] if isinstance(value, dict) else []


def _get(node: Any, *path: str) -> Any:
    for key in path:
        node = node.get(key) if isinstance(node, dict) else None
    return node


def _all_days(value: Any, out: set[date]) -> None:
    if isinstance(value, dict):
        for item in value.values():
            _all_days(item, out)
    elif isinstance(value, (list, tuple)):
        for item in value:
            _all_days(item, out)
    elif isinstance(value, str):
        for match in _ISO_DAY.finditer(value):
            try:
                out.add(date(int(match.group(1)), int(match.group(2)), int(match.group(3))))
            except ValueError:
                pass


def _clock_key(value: str) -> str:
    hours, minutes = value.split(":")[:2]
    return f"{int(hours)}:{minutes}"


def _hour_key(match: re.Match) -> str:
    """6 am -> 6:00, 6 pm -> 18:00, 12 am -> 0:00 (a _HOUR match)."""
    hour = int(match.group(1)) % 12 + (12 if match.group(2).lower() == "p" else 0)
    return f"{hour}:00"


def _spoken_clocks(text: str) -> set[str]:
    """The clock times a tool's own wording names ("between 6 am and noon")."""
    found = {_hour_key(m) for m in _HOUR.finditer(text)}
    found |= {"12:00"} if re.search(r"\bnoon\b", text, re.I) else set()
    return found | ({"0:00"} if re.search(r"\bmidnight\b", text, re.I) else set())


def facts(evidence: dict[str, Any], retrieved: dict[str, dict[str, Any]]) -> Facts:
    """What the tools said, by unit. Free text (the person's notes, exposure labels, earlier headlines) is not read."""
    f = Facts()
    summaries = _listed(evidence.get("get_metric_summary"))
    for related in _listed(evidence.get("get_related_metrics"))[:1]:  # the default call: every signal, the night
        elsewhere = {s.get("metric") for s in related.get("signals") or [] if s.get("same_night_as_metric") is False}
        for vital in _get(related, "night_vitals", "vitals") or []:
            key = VITAL_GROUP.get(str(vital.get("vital")))
            if key and key not in elsewhere and vital.get("state"):
                f.calls[key] = vital["state"]
                if vital.get("side"):
                    f.sides[key] = vital["side"]
    for summary in summaries[:1]:
        f.metric = summary.get("metric")
        call = _get(summary, "baseline", "call") or {}
        if f.metric and call.get("state"):
            f.calls[f.metric] = call["state"]
            f.sides.pop(f.metric, None)
            if call.get("side"):
                f.sides[f.metric] = call["side"]
    for summary in summaries:
        unit = summary.get("units") or ""
        for path in (("latest",), ("previous",)):
            node = _get(summary, *path) or {}
            f.dated(unit, node.get("day"), node.get("value"))
        for path in (("latest", "value"), ("previous", "value"), ("baseline", "usual_value"),
                     ("baseline", "usual_low"), ("baseline", "usual_high"), ("baseline", "value"),
                     ("baseline", "call", "low"), ("baseline", "call", "high"), ("baseline", "week", "center"),
                     ("baseline", "week", "low"), ("baseline", "week", "high"),
                     ("baseline", "long", "center"), ("baseline", "long", "low"), ("baseline", "long", "high"),
                     ("last_7_nights", "median"), ("last_7_nights", "low"), ("last_7_nights", "high"),
                     ("context_layer", "reference", "center"), ("baseline", "recent", "median"),
                     ("baseline", "recent", "lowest"), ("baseline", "recent", "highest")):
            f.add(unit, _get(summary, *path))
            f.own(summary.get("metric"), unit, _get(summary, *path))
        for path in (("previous", "change"), ("baseline", "change_vs_usual"), ("context_layer", "reference", "difference")):
            f.change(unit, _get(summary, *path))
            f.own(summary.get("metric"), unit, _get(summary, *path))
        for path in (("measured_nights",), ("baseline", "week", "nights"), ("baseline", "long", "nights"),
                     ("last_7_nights", "measured"), ("assessment", "nights_needed"),
                     ("context_layer", "reference", "support_nights"), ("baseline", "recent", "periods"),
                     ("baseline", "recent", "lower_than_latest")):
            f.count(_get(summary, *path))
        if summary.get("estimated"):
            f.estimated.add(str(summary.get("metric")))
    for series in _listed(evidence.get("get_metric_series")):
        for night in series.get("nights") or []:
            f.add(series.get("units") or "", night.get("value"))
            f.own(series.get("metric"), series.get("units") or "", night.get("value"))
            f.dated(series.get("units") or "", night.get("day"), night.get("value"))
        f.count(series.get("measured_nights"))
        f.count(series.get("missing_nights"))
    for related in _listed(evidence.get("get_related_metrics")):
        for signal in related.get("signals") or []:
            unit = signal.get("units") or ""
            f.add(unit, _get(signal, "latest", "value"))
            f.dated(unit, _get(signal, "latest", "day"), _get(signal, "latest", "value"))
            for key in ("usual", "usual_low", "usual_high"):
                f.add(unit, signal.get(key))
                f.own(signal.get("metric"), unit, signal.get(key))
            f.change(unit, signal.get("change_vs_usual"))
            f.own(signal.get("metric"), unit, _get(signal, "latest", "value"))
            f.own(signal.get("metric"), unit, signal.get("change_vs_usual"))
            f.count(signal.get("measured_nights"))
            f.count(signal.get("usual_nights"))
            if signal.get("estimated"):
                f.estimated.add(SIGNAL_GROUP.get(str(signal.get("metric")), str(signal.get("metric"))))
        night = _get(related, "night_vitals", "night")
        for vital in _get(related, "night_vitals", "vitals") or []:
            unit = vital.get("units") or ""
            for key in ("value", "usual_low", "usual_high"):
                f.add(unit, vital.get(key))
                f.own(VITAL_GROUP.get(str(vital.get("vital"))), unit, vital.get(key))
            f.dated(unit, night, vital.get("value"))
            if vital.get("estimated"):
                f.estimated.add(VITAL_GROUP.get(str(vital.get("vital")), str(vital.get("vital"))))
    for breakdown in _listed(evidence.get("get_state_breakdown")):
        for state in breakdown.get("states") or []:
            unit = state.get("units") or ""
            f.add(unit, state.get("value"))
            for value in [state.get("value")] + [(b or {}).get(k) for b in (state.get("usual"), state.get("week"),
                                                                            state.get("long"))
                                                 for k in ("center", "low", "high")] + [
                    slot.get("value") for slot in state.get("time_of_day") or []]:
                f.own(breakdown.get("metric"), unit, value)
            f.dated(unit, breakdown.get("night"), state.get("value")) if state.get("state") == "sleep" else None
            for band in (state.get("usual") or {}, state.get("week") or {}, state.get("long") or {}):
                for key in ("center", "low", "high"):
                    f.add(unit, band.get(key))
                f.count(band.get("nights"))
            for slot in state.get("time_of_day") or []:
                f.add(unit, slot.get("value"))
                f.clocks |= _spoken_clocks(str(slot.get("when") or ""))
            support = re.match(r"\s*(\d+)\b", str(state.get("measured_in") or ""))  # "40 windows"
            f.count(int(support.group(1)) if support else None)
            if state.get("value") is not None and _num(_get(state, "usual", "center")) is not None:
                f.change(unit, round(state["value"] - state["usual"]["center"], 1))
    for breakdown in _listed(evidence.get("get_state_breakdown")):
        for state in (breakdown.get("through_the_day") or {}).get("states") or []:
            for key in ("median_ms", "low_ms", "high_ms"):
                f.add("ms", state.get(key))
            f.count(state.get("readings"))
            f.add("min", state.get("minutes"))
            f.add("h", round(state["minutes"] / 60.0, 1) if state.get("minutes") is not None else None)
            for key in ("from_local", "to_local"):
                if state.get(key):
                    f.clocks.add(_clock_key(state[key]))
        f.count((breakdown.get("through_the_day") or {}).get("slot_minutes"))
    for movement in _listed(evidence.get("get_movement_patterns")):
        for minutes in (movement.get("minutes_by_kind_before_the_night") or {}).values():
            f.add("min", minutes)
        for bout in (movement.get("before_the_night") or []) + (movement.get("on_the_day") or []):
            f.add("min", bout.get("minutes"))
            for key in ("start_local", "end_local"):
                if bout.get(key):
                    f.clocks.add(_clock_key(bout[key]))
        f.add("min", movement.get("last_movement_before_sleep_min"))
        f.add("h", round((movement.get("last_movement_before_sleep_min") or 0) / 60.0, 1)
              if movement.get("last_movement_before_sleep_min") is not None else None)
        for window in movement.get("load") or []:
            f.count(window.get("hours"))
            f.add("h", window.get("hours"))
            f.count(window.get("bouts"))
            f.add("min", window.get("locomotion_min"))
    for sleep in _listed(evidence.get("get_sleep_context")):
        for night in sleep.get("nights") or []:
            f.add("h", night.get("duration_h"))
            f.add("%", night.get("efficiency_pct"))
            f.dated("h", night.get("day"), night.get("duration_h"))
            f.dated("%", night.get("day"), night.get("efficiency_pct"))
            for key in ("onset_local", "wake_local"):
                if night.get(key):
                    f.clocks.add(_clock_key(night[key]))
        f.add("h", _get(sleep, "usual_duration_h", "median"))
        f.count(_get(sleep, "usual_duration_h", "nights"))
        f.change("min", _get(sleep, "timing_change", "wake_shift_min"))
        f.change("min", _get(sleep, "timing_change", "midpoint_shift_min"))
        f.count(_get(sleep, "timing_change", "compared_with_nights"))
    for workout in _listed(evidence.get("get_workout_context")):
        for window in workout.get("exertion_windows") or []:
            f.count(window.get("hours"))
            f.add("h", window.get("hours"))
            f.count(window.get("bouts"))
            f.add("min", window.get("locomotion_min"))
            f.add("h", window.get("observed_h"))
        for bout in workout.get("movement_bouts") or []:
            f.count(bout.get("count"))
            f.add("min", bout.get("minutes"))
    for activity in _listed(evidence.get("get_activity_context")):
        f.add("h", activity.get("motion_observed_h"))
        f.add("min", activity.get("locomotion_min_per_worn_hour"))
        f.add("min", activity.get("median_bout_min"))
        f.count(activity.get("bouts_per_worn_hour"))
        energy = activity.get("energy") or {}
        for key in ("total_kcal", "resting_kcal", "active_kcal", "workout_kcal"):
            f.add("kcal", energy.get(key))
        f.add("kcal", _get(energy, "usual_total_kcal", "median"))
        f.own("calories", "kcal", energy.get("total_kcal"))
        f.own("calories", "kcal", _get(energy, "usual_total_kcal", "median"))
        if _num(energy.get("total_kcal")) is not None and _num(_get(energy, "usual_total_kcal", "median")) is not None:
            f.change("kcal", energy["total_kcal"] - energy["usual_total_kcal"]["median"])
        for minutes in list((energy.get("minutes_by_intensity") or {}).values()) + [energy.get("coverage_min"),
                                                                                  energy.get("gap_min")]:
            f.add("min", minutes)
            f.add("h", round(minutes / 60.0, 1) if _num(minutes) is not None else None)
        f.count(energy.get("workouts"))
        f.count(_get(energy, "usual_total_kcal", "days"))
    for walking in _listed(evidence.get("get_gait_context")):
        for key in ("walking_min", "brisk_min"):
            f.add("min", walking.get(key))
            f.add("h", round(walking[key] / 60.0, 1) if _num(walking.get(key)) is not None else None)
        for minutes in (walking.get("minutes_by_cadence") or {}).values():
            f.add("min", minutes)
        f.count(walking.get("walks"))
        f.add("steps", walking.get("walk_steps"))
        f.add("spm", walking.get("cadence_spm"))
        f.add("m/s", walking.get("typical_speed_mps"))
        f.add("km/h", walking.get("typical_speed_kmh"))
        f.add("%", walking.get("regularity_pct"))
        for walk in walking.get("longest_walks") or []:
            f.add("min", walk.get("minutes"))
            f.add("spm", walk.get("cadence_spm"))
            f.add("m/s", walk.get("speed_mps"))
            for key in ("start_local", "end_local"):
                if walk.get(key):
                    f.clocks.add(_clock_key(walk[key]))
        previous = walking.get("previous_days") or {}
        f.count(previous.get("days"))
        f.add("min", previous.get("walking_min_median"))
        f.add("spm", previous.get("cadence_spm_median"))
        if _num(walking.get("walking_min")) is not None and _num(previous.get("walking_min_median")) is not None:
            f.change("min", walking["walking_min"] - previous["walking_min_median"])
    for events in _listed(evidence.get("get_recent_events")):
        for event in events.get("events") or []:
            unit = str(event.get("dose_unit") or "")
            f.add(UNITS.get(unit.lower(), unit), event.get("dose"))
            if event.get("local_time"):
                f.clocks.add(_clock_key(event["local_time"]))
            _all_days(event.get("local_day"), f.days)
    for quality in _listed(evidence.get("get_data_quality")):
        for key in ("tracked_nights", "measured_nights", "missing_nights", "longest_gap_nights", "measured_in_last_7"):
            f.count(quality.get(key))
        if _get(quality, "signal_validity", "state") == "unverified":
            for summary in summaries:
                f.estimated.add(str(summary.get("metric")))
    _all_days({k: v for k, v in evidence.items()
               if k not in ("get_user_context", "get_previous_insight", "get_recent_events")}, f.days)
    for record in retrieved.values():
        for match in re.finditer(rf"(?<![\w.,])(?:{_NUM})", _strip_dates(str(record.get("finding") or ""))):
            f.literature.add(float(match.group(0).replace(",", "")))
    return f


def _strip_dates(text: str) -> str:
    for pattern in (_ISO_DAY, _MONTH_DAY, _DAY_MONTH, _CLOCK, _HOUR, _SLASH_DAY):
        text = pattern.sub(" ", text)
    return text


def _matches(token: str, values: set[float]) -> bool:
    token = token.replace(",", "")
    number = float(token.replace("−", "-"))
    decimals = len(token.split(".", 1)[1]) if "." in token else 0
    return any(round(v, decimals) == round(number, decimals) for v in values)


def _mentioned_days(text: str) -> list[tuple[int, int, int | None]]:
    found = []
    for match in _MONTH_DAY.finditer(text):
        found.append((MONTHS[match.group(1)[:3]], int(match.group(2)), int(match.group(3)) if match.group(3) else None))
    for match in _DAY_MONTH.finditer(text):
        found.append((MONTHS[match.group(2)[:3]], int(match.group(1)), int(match.group(3)) if match.group(3) else None))
    for match in _ISO_DAY.finditer(text):
        found.append((int(match.group(2)), int(match.group(3)), int(match.group(1))))
    return found


def _direction_errors(token: str, unit_word: str | None, word: str, f: Facts) -> list[str]:
    unit = UNITS.get((unit_word or "").lower())
    if unit_word and unit not in CHANGE_UNITS:
        return []  # "3 nights more" is a count, not a change
    if unit and _matches(token, f.by_unit.get(unit, set())):
        return []  # "51 ms sat below your usual band": a value compared with a band, not the size of a change
    sign = 1 if word.lower() in UP_WORDS else -1
    changes = f.signed.get(unit, set()) if unit else {v for values in f.signed.values() for v in values}
    if any(v * sign > 0 and _matches(token, {abs(v)}) for v in changes):
        return []
    return [f"direction:'{token} {unit_word or ''} {word}' does not match the size and sign of a change in the "
            "tool results"]


def _numbers_errors(sentence: str, f: Facts, *, interpretation: bool) -> list[str]:
    errors = []
    stripped = _strip_dates(sentence)
    literature = f.literature if interpretation else set()  # a general finding may be quoted where it is discussed
    for match in _NUMBER.finditer(stripped):
        token, unit_word = match.group(1).replace("+", ""), match.group(2)
        unit = UNITS.get(unit_word.lower()) if unit_word else None
        if unit in MEASURED_UNITS and float(token.replace(",", "").replace("−", "-")) == 0:
            errors.append(f"grounding:0 {unit} is not a measurement (a missing night is missing, never zero)")
        elif unit and unit != "drinks":
            if not _matches(token, f.unit_values(unit) | literature):
                errors.append(f"grounding:{token} {unit} is not a {unit} value in any tool result")
        elif not _matches(token, f.any_values() | literature):
            errors.append(f"grounding:the number {token} is not in any tool result")
    for match in _NUMBER_WORD.finditer(stripped):
        word, unit_part = match.group(1).lower(), match.group(2)
        value = NUMBER_WORDS[word] + (NUMBER_WORDS[unit_part.lower()] if unit_part else 0)
        if value == 1 and not unit_part:
            continue  # "one night above", "no one": too common to be a stated count
        if not _matches(str(value), f.any_values() | literature):
            errors.append(f"grounding:'{match.group(0)}' ({value}) is not in any tool result")
    for match in _CLOCK.finditer(sentence):
        hour, half = int(match.group(1)), (match.group(3) or "").lower()
        if half and 1 <= hour <= 12:  # the same clock time in 12-hour form
            hour = hour % 12 + (12 if half == "p" else 0)
        if f"{hour}:{match.group(2)}" not in f.clocks:
            errors.append(f"grounding:the time {match.group(0).strip()} is not in any tool result")
    for match in _HOUR.finditer(_CLOCK.sub(" ", sentence)):
        if _hour_key(match) not in f.clocks:
            errors.append(f"grounding:the time {match.group(0).strip()} is not in any tool result")
    for m in _DIRECTION_AFTER.finditer(stripped):
        errors += _direction_errors(m.group(1), m.group(2), m.group(3), f)
    for m in _DIRECTION_BEFORE.finditer(stripped):
        errors += _direction_errors(m.group(2), m.group(3), m.group(1), f)
    return errors


_DATED = re.compile(rf"(?<![\w.,])({_NUM})\s*({_UNIT_RE})(?![a-z])", re.I)
_CHANGE_AFTER = re.compile(rf"\s+(?:\w+\s+)?(?:{_DIRECTIONS})\b", re.I)


def _dated_errors(sentence: str, f: Facts) -> list[str]:
    """In each clause that names one night, a value of a unit the tools state for that night must be that value."""
    errors = []
    for clause in re.split(r"[;]|,(?=\s)|\band\b|\bwhile\b|\bwhereas\b|\bthan\b", sentence):
        days = _mentioned_days(clause)
        if len(days) != 1:
            continue
        month, day, year = days[0]
        nights = [d for d in f.days if d.month == month and d.day == day and (year is None or d.year == year)]
        stripped = _strip_dates(clause)
        for match in _DATED.finditer(stripped):
            after, before = stripped[match.end():match.end() + 30], stripped[:match.start()]
            if _CHANGE_AFTER.match(after) or re.search(r"\bby\s*$", before, re.I):
                continue  # "1 bpm above Oct 5" is a change, checked by the direction rule
            unit = UNITS.get(match.group(2).lower())
            known = set().union(*(f.on_day.get((unit, night), set()) for night in nights)) if nights else set()
            if known and not _matches(match.group(1), known):
                errors.append(f"grounding:{match.group(1)} {unit} is not the value on {month}/{day} in the tool results")
    return errors


# Placing a night inside or outside the usual range (not "2 bpm higher than your usual", which is a change).
_OUT_OF_USUAL = re.compile(r"\b(?:outside|beyond|out of|above|below|higher than|lower than)\s+(?:your|the|its|their)\s+"
                           r"(?:[\w-]+\s+)?usual\s+(?:range|band)\b|\boff\s+(?:your|the|its)\s+usual\b|"
                           r"\bunusual(?:ly\s+\w+)?\s+for\s+you\b", re.I)
_IN_USUAL = re.compile(r"\b(?:within|inside|in)\s+(?:your|the|its|their)\s+(?:[\w-]+\s+)?usual\s+(?:range|band)\b|"
                       r"\b(?:normal|typical)\s+for\s+you\b|\bin\s+line\s+with\s+(?:your|the|its)\s+usual\b", re.I)
_CLAUSE = re.compile(r"[;—–]|[,:](?=\s)|\b(?:while|whereas|but|and)\b", re.I)
_OPEN_QUESTION = re.compile(r"\b(?:whether|if)\b", re.I)
_SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=[A-Z])")  # not "6.7 h" or "9:30 p.m. on"
CALL_WORDS = {"in_range": "In range", "off": "Off usual", "learning": "Learning (no usual yet)",
              "no_reading": "No reading"}


def _named(clause: str) -> list[str]:
    """The signals a clause names, by their longest alias ("resting heart rate" is not also "heart rate"); "HRV
    (SDNN)" names SDNN, not RMSSD."""
    lowered = clause.lower()
    spans = [(m.start(), m.end(), key) for key, words in ALIASES.items() if key in SIGNAL_CALLS for w in words
             for m in re.finditer(rf"\b{re.escape(w)}\b", lowered)]
    kept = [a for a in spans if not any(b[0] <= a[0] and a[1] <= b[1] and b[1] - b[0] > a[1] - a[0] for b in spans)]
    named = list(dict.fromkeys(key for _, _, key in sorted(kept)))
    if "hrv_sdnn" in named and "hrv_rmssd" in named and not re.search(r"\brmssd\b", lowered):
        named.remove("hrv_rmssd")
    return named


def _call_errors(sentence: str, f: Facts) -> list[str]:
    """A sentence that places a night inside or outside its usual range must say what the app shows for it."""
    errors: list[str] = []
    subject = f.metric
    for clause in _CLAUSE.split(sentence):
        named = _named(clause)
        if len(named) > 1:
            subject = None  # two signals in one clause: not attributable
            continue
        subject = named[0] if named else subject
        call = f.calls.get(subject) if subject else None
        if call is None:
            continue
        if call == "no_usual":
            if any(not _OPEN_QUESTION.search(clause[max(0, m.start() - 40):m.start()])
                   for pattern in (_OUT_OF_USUAL, _IN_USUAL) for m in pattern.finditer(clause)):
                errors.append(f"usual:the app shows no usual range for {subject}; compare it with the person's recent "
                              "nights or days instead (metric_summary.baseline.recent)")
            continue
        for pattern, says in ((_OUT_OF_USUAL, "off"), (_IN_USUAL, "in_range")):
            for match in pattern.finditer(clause):
                if _OPEN_QUESTION.search(clause[max(0, match.start() - 40):match.start()]):
                    continue  # "can't yet say whether it is within your usual range" claims nothing
                negated = _NEGATION.search(clause[max(0, match.start() - 40):match.start()])
                claim = {"off": "in_range", "in_range": "off"}[says] if negated else says
                if call in ("learning", "no_reading"):
                    if not negated:  # "has not called it in or outside your usual range" is right
                        errors.append(f"usual:the app shows {subject} as {CALL_WORDS[call]} for this night; do not "
                                      "place it inside or outside a usual range")
                elif claim != call:
                    errors.append(f"usual:the app shows {subject} {CALL_WORDS[call]} for this night; the text says it "
                                  f"was {'outside' if claim == 'off' else 'within'} the usual range")
                elif claim == "off" and not negated:
                    side = "above" if re.search(r"above|higher", match.group(0), re.I) else \
                        "below" if re.search(r"below|lower", match.group(0), re.I) else None
                    if side and f.sides.get(subject) and side != f.sides[subject]:
                        errors.append(f"usual:{subject} was {f.sides[subject]} its usual range, not {side} it")
    return errors


def _signal_errors(sentence: str, f: Facts) -> list[str]:
    """A number said about a named signal is that signal's own: an RMSSD value is not SDNN's, a resting heart rate
    during sleep is not the stable awake one. Flagged only when the number is another signal's and not this one's."""
    errors = []
    for clause in _CLAUSE.split(sentence):
        named = _named(clause)
        if len(named) != 1:
            continue
        subject = named[0]
        for match in _NUMBER.finditer(_strip_dates(clause)):
            unit = UNITS.get(match.group(2).lower()) if match.group(2) else None
            own = f.by_signal.get((subject, unit)) if unit else None
            if own is None or _matches(match.group(1), own):
                continue
            others = sorted(k for (k, u), values in f.by_signal.items()
                            if u == unit and k != subject and _matches(match.group(1), values))
            if others:
                errors.append(f"grounding:{match.group(1)} {unit} is {others[0]}'s value, not {subject}'s")
    return errors


def _estimated_errors(sentence: str, f: Facts) -> list[str]:
    lowered = sentence.lower()
    if "estimat" in lowered:
        return []
    quoted = f"'{sentence[:60]}…'" if len(sentence) > 60 else f"'{sentence}'"  # which sentence, for the retry
    for group in sorted(f.estimated):
        verb = _YOU_VERB.get(group)
        if verb and (m := verb.search(lowered)):
            return [f"estimated:{quoted} says you {m.group(1)}; it must say the {group} data is estimated"]
        for alias in ALIASES.get(group, ()):
            a = re.escape(alias)
            if (re.search(rf"\byour\s+(?:\w+\s+){{0,2}}{a}\b", lowered)
                    or (alias not in YOUR_ONLY and re.search(rf"\b{a}\b\W+(?:\w+\W+){{0,6}}?\d", lowered))):
                return [f"estimated:{quoted} states your {alias}; it must say it is estimated"]
    return []


def check(text: str, evidence: dict[str, Any], retrieved: dict[str, dict[str, Any]], *,
          called: set[str] | None = None, required: frozenset[str] = frozenset()) -> Result:
    answer, error = parse(text)
    if error:
        return Result(False, None, [error])
    assert answer is not None
    errors: list[str] = []
    headline = answer.get("headline")
    if not isinstance(headline, str) or not headline.strip():
        errors.append("shape:headline must be a non-empty string")
    elif len(headline) > MAX_HEADLINE:
        errors.append(f"shape:headline is longer than {MAX_HEADLINE} characters")
    sections: dict[str, list[str]] = {}
    for key, minimum in (("observed", 1), ("interpretation", 1), ("uncertainty", 1)):
        value = answer.get(key)
        if not isinstance(value, list) or not all(isinstance(s, str) and s.strip() for s in value):
            errors.append(f"shape:{key} must be a list of non-empty strings")
            continue
        if not minimum <= len(value) <= MAX_ITEMS:
            errors.append(f"shape:{key} needs {minimum} to {MAX_ITEMS} sentences")
        for sentence in value:
            if len(sentence) > MAX_SENTENCE:
                errors.append(f"shape:a {key} sentence is longer than {MAX_SENTENCE} characters")
        sections[key] = [unicodedata.normalize("NFKC", s).strip() for s in value]
    citations = answer.get("citations", [])
    if not isinstance(citations, list) or not all(isinstance(c, str) for c in citations) or len(citations) > MAX_ITEMS:
        errors.append(f"shape:citations must be a list of at most {MAX_ITEMS} ids")
        citations = []
    if errors:
        return Result(False, None, errors)
    errors += text_problems(" ".join([headline, *answer["observed"], *answer["interpretation"], *answer["uncertainty"]]))
    headline = unicodedata.normalize("NFKC", headline).strip()
    labelled = [("headline", headline)] + [(key, s) for key in ("observed", "interpretation", "uncertainty")
                                           for s in sections[key]]
    if sum(len(s) for _, s in labelled) > MAX_TOTAL:
        errors.append(f"concise:the whole explanation is longer than {MAX_TOTAL} characters")
    f = facts(evidence, retrieved)
    for key, item in labelled:
        for sentence in _SENTENCE_END.split(item):  # each check reads one sentence of an item
            for term, pattern in _FORBIDDEN:
                if pattern.search(sentence):
                    errors.append(f"wording:forbidden term '{term}'")
            for term, pattern in _CLAIMS:
                if pattern.search(sentence):
                    errors.append(f"claim:'{term}' states a diagnosis, a cause or certainty; describe an association "
                                  "with uncertainty instead")
            for term, pattern in _RELATIVE:
                if pattern.search(sentence):
                    errors.append(f"dates:'{term}' is relative; use the absolute date (e.g. Oct 6)")
            if (_BECAUSE.search(sentence) and not _HEDGE.search(sentence)
                    and not (key == "uncertainty" and _DATA_LIMIT.search(sentence))):
                errors.append("claim:'because' must be hedged ('likely because', 'may be because'): a pattern in "
                              "the data is an association, not proof")
            if _SLASH_DAY.search(sentence):
                errors.append("dates:write dates like Oct 6, not with slashes")
            errors += _numbers_errors(sentence, f, interpretation=key == "interpretation")
            errors += _dated_errors(sentence, f)
            for month, day, year in _mentioned_days(sentence):
                if not any(d.month == month and d.day == day and (year is None or d.year == year) for d in f.days):
                    errors.append(f"dates:{month}/{day} is not a night in the tool results")
            errors += _estimated_errors(sentence, f)
            errors += _call_errors(sentence, f)
            errors += _signal_errors(sentence, f)
            if _PMID_OR_DOI.search(sentence):
                errors.append("citations:put literature ids only in the citations list, not in the text")

    missing = sorted(required - (called or set()))
    if missing:
        errors.append(f"context:load these first: {', '.join(missing)}")
    if len(citations) < MIN_CITATIONS:
        errors.append("citations:cite at least one peer-reviewed finding returned by search_literature")
    for cited in (c for c in citations if c in retrieved):
        if not retrieved[cited].get("peer_reviewed"):
            errors.append(f"citations:{cited} is not a peer-reviewed journal article")
    unknown = [c for c in citations if c not in retrieved]
    if unknown:
        errors.append(f"citations:{', '.join(unknown[:3])} were not returned by search_literature in this session")
    # A citation supports an interpretation of something present: an interpretation sentence that names its
    # topic without negating it ("no alcohol was recorded" is not a reason to cite alcohol research). A topic word
    # counts at the start of a word ("walked" for walk, not "average" for age), and the explained metric's own name
    # is not a topic (every steps explanation says "steps", every wrist temperature one "temperature").
    # How far a wearable's reading can be trusted is what the uncertainty section is for: a finding on it may back
    # a sentence there too.
    def supported(items: list[str]) -> str:  # one sentence, then one clause, at a time
        clauses = (c for s in items for sentence in _SENTENCE_END.split(s) for c in _CLAUSE.split(sentence))
        text = " ".join(c for c in clauses if not _NEGATION.search(c)).lower()
        for name in sorted(ALIASES.get(str(f.metric), ()), key=len, reverse=True):
            text = re.sub(rf"\b{re.escape(name)}\b", " ", text)
        return text
    interpreted = supported(sections["interpretation"])
    limits = supported(sections["interpretation"] + sections["uncertainty"])
    for cited in (c for c in citations if c in retrieved):
        topic = str(retrieved[cited].get("topic"))
        words = TOPIC_WORDS.get(topic)
        text, where = (limits, "interpretation or uncertainty") if topic in LIMIT_TOPICS else (
            interpreted, "interpretation")
        if not words:
            errors.append(f"citations:{cited} has no verified topic and cannot be cited")
        elif not any(re.search(rf"\b{re.escape(word)}", text) for word in words):
            errors.append(f"citations:{cited} is about {topic}, which no {where} sentence says is present for this "
                          "person")
    answer = {"headline": headline, **sections, "citations": list(dict.fromkeys(citations))}
    return Result(not errors, answer, list(dict.fromkeys(errors)))

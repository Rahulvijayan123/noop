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
    "skin_temp_dev": ("skin temperature", "skin temp"),
    "sleep": ("sleep duration", "sleep efficiency", "sleep timing", "sleep", "slept", "asleep", "bedtime",
              "wake time", "woke"),
    "activity": ("training load", "locomotion", "movement", "workout", "exercise", "activity", "active minutes",
                 "steps", "training"),
}
SIGNAL_GROUP = {"sleep_total": "sleep", "sleep_efficiency": "sleep"}
# A cited finding must be about something the explanation says (by the curated entry's topic).
TOPIC_WORDS: dict[str, tuple[str, ...]] = {
    "alcohol": ("alcohol", "drink", "wine", "beer"), "caffeine": ("caffeine", "coffee"),
    "sleep_restriction": ("sleep",), "training_load": ("training", "exercise", "workout", "exertion", "load"),
    "detraining": ("training", "exercise", "fitness"), "aerobic_fitness": ("fitness", "training", "exercise"),
    "heat": ("heat", "hot", "warm", "temperature"), "altitude": ("altitude", "elevation"),
    "hydration": ("hydration", "fluid", "water"), "menstrual_cycle": ("cycle", "menstrual", "period"),
    "seasonality": ("season", "winter", "summer"), "age": ("age",),
    "normal_range": ("usual", "range", "normal", "typical", "vary", "variation", "differ"),
    "day_to_day_variability": ("night-to-night", "day-to-day", "vary", "variation", "common", "usual"),
    "wearable_accuracy": ("measure", "measurement", "sensor", "device", "wear", "accuracy"),
    "posture": ("posture", "standing", "lying", "supine", "upright", "sitting"),
    "physical_activity": ("activity", "movement", "moving", "walk", "walking", "steps", "exercise"),
    "sleep_architecture": ("deep sleep", "rem", "sleep stage", "slow-wave", "sleep"),
    "circadian": ("circadian", "time of day", "night", "daytime", "evening", "morning"),
}
UNITS: dict[str, str] = {
    "bpm": "bpm", "beats per minute": "bpm", "ms": "ms", "millisecond": "ms", "milliseconds": "ms",
    "h": "h", "hr": "h", "hrs": "h", "hour": "h", "hours": "h", "min": "min", "mins": "min", "minute": "min",
    "minutes": "min", "%": "%", "percent": "%", "breaths/min": "breaths/min", "breaths per minute": "breaths/min",
    "°c": "°C", "degrees": "°C", "mg": "mg", "ml": "ml", "g": "g", "drink": "drinks", "drinks": "drinks",
}
MEASURED_UNITS = frozenset({"bpm", "ms", "breaths/min"})  # a value of these is never zero
CHANGE_UNITS = frozenset({"bpm", "ms", "h", "min", "%", "breaths/min", "°C"})
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
_CLOCK = re.compile(r"\b(\d{1,2}):(\d{2})\b")
_UNIT_RE = "|".join(sorted((re.escape(u) for u in UNITS), key=len, reverse=True))
_DIRECTIONS = "|".join(UP_WORDS + DOWN_WORDS)
_NUMBER = re.compile(rf"(?<![\w.])([-+−]?\d+(?:\.\d+)?)(?!\d)(?!st\b|nd\b|rd\b|th\b)\s*(?:({_UNIT_RE})(?![a-z]))?", re.I)
_NUMBER_WORD = re.compile(r"\b(" + "|".join(sorted(NUMBER_WORDS, key=len, reverse=True)) + r")(?:-(one|two|three|"
                          r"four|five|six|seven|eight|nine))?\b", re.I)
_DIRECTION_AFTER = re.compile(rf"(?<![\w.])(\d+(?:\.\d+)?)\s*({_UNIT_RE})(?![a-z])\s+(?:\w+\s+)?({_DIRECTIONS})\b", re.I)
_DIRECTION_BEFORE = re.compile(rf"\b({_DIRECTIONS})\s+(?:by\s+)?(\d+(?:\.\d+)?)\s*({_UNIT_RE})?(?![a-z])", re.I)
_PMID_OR_DOI = re.compile(r"\bpmid\s*[:#]?\s*\d+|\b10\.\d{4,9}/\S+", re.I)
_NEGATION = re.compile(r"\b(no|not|none|nothing|without|never|neither|nor)\b|n't\b", re.I)
# "because" explains with the person's own data ("likely because you walked 40 minutes that evening"); it must be
# hedged, since a pattern in the data is an association, not proof.
_BECAUSE = re.compile(r"\bbecause\b", re.I)
_HEDGE = re.compile(r"\b(likely|probably|possibly|may|might|can|could|often|typically|usually|tends?|"
                    r"perhaps|partly)\b", re.I)
_YOU_VERB = {"sleep": re.compile(r"\byou\s+(?:\w+\s+){0,2}(slept|woke|fell asleep)\b", re.I),
             "activity": re.compile(r"\byou\s+(?:\w+\s+){0,2}(trained|exercised|walked|ran|worked out)\b", re.I)}

MAX_HEADLINE = 120
MAX_SENTENCE = 280
MAX_TOTAL = 1200
MAX_ITEMS = 3
MIN_CITATIONS = 1  # every explanation carries at least one peer-reviewed source to check it against
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
    estimated: set[str] = field(default_factory=lambda: {"sleep", "activity"})
    # The value of a unit on a night, where the tools state it (the metric's nights, each signal's latest night,
    # the sleep nights): "59 bpm on Oct 6" must be Oct 6's value, not any bpm value.
    on_day: dict[tuple[str, date], set[float]] = field(default_factory=dict)

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


def facts(evidence: dict[str, Any], retrieved: dict[str, dict[str, Any]]) -> Facts:
    """What the tools said, by unit. Free text (the person's notes, exposure labels, earlier headlines) is not read."""
    f = Facts()
    summaries = _listed(evidence.get("get_metric_summary"))
    for summary in summaries:
        unit = summary.get("units") or ""
        for path in (("latest",), ("previous",)):
            node = _get(summary, *path) or {}
            f.dated(unit, node.get("day"), node.get("value"))
        for path in (("latest", "value"), ("previous", "value"), ("baseline", "median"),
                     ("baseline", "usual_range", "low"), ("baseline", "usual_range", "high"),
                     ("last_7_nights", "median"), ("last_7_nights", "low"), ("last_7_nights", "high"),
                     ("context_layer", "reference", "center")):
            f.add(unit, _get(summary, *path))
        for path in (("previous", "change"), ("baseline", "change_vs_median"), ("context_layer", "reference", "difference")):
            f.change(unit, _get(summary, *path))
        for path in (("measured_nights",), ("baseline", "nights"), ("last_7_nights", "measured"),
                     ("assessment", "nights_available"), ("assessment", "nights_needed"),
                     ("context_layer", "reference", "support_nights")):
            f.count(_get(summary, *path))
        if summary.get("estimated"):
            f.estimated.add(str(summary.get("metric")))
    for series in _listed(evidence.get("get_metric_series")):
        for night in series.get("nights") or []:
            f.add(series.get("units") or "", night.get("value"))
            f.dated(series.get("units") or "", night.get("day"), night.get("value"))
        f.count(series.get("measured_nights"))
        f.count(series.get("missing_nights"))
    for related in _listed(evidence.get("get_related_metrics")):
        for signal in related.get("signals") or []:
            unit = signal.get("units") or ""
            f.add(unit, _get(signal, "latest", "value"))
            f.dated(unit, _get(signal, "latest", "day"), _get(signal, "latest", "value"))
            f.add(unit, signal.get("median"))
            f.change(unit, signal.get("change_vs_median"))
            f.count(signal.get("measured_nights"))
            f.count(signal.get("baseline_nights"))
            if signal.get("estimated"):
                f.estimated.add(SIGNAL_GROUP.get(str(signal.get("metric")), str(signal.get("metric"))))
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
        f.add("h", activity.get("worn_h"))
        f.add("min", activity.get("locomotion_min_per_worn_hour"))
        f.add("min", activity.get("median_bout_min"))
        f.count(activity.get("bouts_per_worn_hour"))
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
        for match in re.finditer(r"(?<![\w.])\d+(?:\.\d+)?", _strip_dates(str(record.get("finding") or ""))):
            f.literature.add(float(match.group(0)))
    return f


def _strip_dates(text: str) -> str:
    for pattern in (_ISO_DAY, _MONTH_DAY, _DAY_MONTH, _CLOCK, _SLASH_DAY):
        text = pattern.sub(" ", text)
    return text


def _matches(token: str, values: set[float]) -> bool:
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
        if unit in MEASURED_UNITS and float(token.replace("−", "-")) == 0:
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
        if f"{int(match.group(1))}:{match.group(2)}" not in f.clocks:
            errors.append(f"grounding:the time {match.group(0)} is not in any tool result")
    for m in _DIRECTION_AFTER.finditer(stripped):
        errors += _direction_errors(m.group(1), m.group(2), m.group(3), f)
    for m in _DIRECTION_BEFORE.finditer(stripped):
        errors += _direction_errors(m.group(2), m.group(3), m.group(1), f)
    return errors


_DATED = re.compile(rf"(?<![\w.])(\d+(?:\.\d+)?)\s*({_UNIT_RE})(?![a-z])", re.I)
_CHANGE_AFTER = re.compile(rf"\s+(?:\w+\s+)?(?:{_DIRECTIONS})\b", re.I)


def _dated_errors(sentence: str, f: Facts) -> list[str]:
    """In each clause that names one night, a value of a unit the tools state for that night must be that value."""
    errors = []
    for clause in re.split(r"[;,]|\band\b|\bwhile\b|\bwhereas\b|\bthan\b", sentence):
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


def _estimated_errors(sentence: str, f: Facts) -> list[str]:
    lowered = sentence.lower()
    if "estimat" in lowered:
        return []
    for group in sorted(f.estimated):
        verb = _YOU_VERB.get(group)
        if verb and (m := verb.search(lowered)):
            return [f"estimated:a sentence saying you {m.group(1)} must say the {group} data is estimated"]
        for alias in ALIASES.get(group, ()):
            a = re.escape(alias)
            if (re.search(rf"\byour\s+(?:\w+\s+){{0,2}}{a}\b", lowered)
                    or re.search(rf"\b{a}\b\W+(?:\w+\W+){{0,6}}?\d", lowered)):
                return [f"estimated:a sentence stating your {alias} must say it is estimated"]
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
    for key, minimum in (("observed", 1), ("interpretation", 0), ("uncertainty", 1)):
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
    for key, sentence in labelled:
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
        if _BECAUSE.search(sentence) and not _HEDGE.search(sentence):
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
    # topic without negating it ("no alcohol was recorded" is not a reason to cite alcohol research).
    supported = " ".join(s for s in sections["interpretation"] if not _NEGATION.search(s)).lower()
    for cited in (c for c in citations if c in retrieved):
        words = TOPIC_WORDS.get(str(retrieved[cited].get("topic")))
        if not words:
            errors.append(f"citations:{cited} has no verified topic and cannot be cited")
        elif not any(word in supported for word in words):
            errors.append(f"citations:{cited} is about {retrieved[cited].get('topic')}, which no interpretation "
                          "sentence says is present for this person")
    answer = {"headline": headline, **sections, "citations": list(dict.fromkeys(citations))}
    return Result(not errors, answer, list(dict.fromkeys(errors)))

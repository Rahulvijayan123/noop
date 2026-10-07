"""The gate between the model and the screen. An answer is published only if it passes every check here:

1. shape: {headline, observed[], interpretation[], uncertainty[], citations[]}, short sentences, concise overall;
2. wording: none of the app's forbidden terms (PhysiologyContextWording.forbiddenTerms, kept identical — see
   tests/test_validate.py), no diagnosis / causal / certainty words, no relative days ("yesterday" is wrong the
   day after it is cached);
3. grounding: every number is one the tools returned (or a retrieved finding states); every date is a night in
   the evidence;
4. estimates: a sentence about a signal the evidence marks as estimated says so;
5. citations: only literature the tools actually retrieved in this job.
"""

from __future__ import annotations

import json
import math
import re
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
# Diagnosis, unsupported causation and false certainty, on top of the app's list.
CLAIM_TERMS: tuple[str, ...] = (
    "caused", "causes", "causing", "because of", "due to", "proves", "proven", "disorder", "syndrome",
    "abnormal", "dangerous", "emergency", "treatment", "treat", "prescribe", "prescription", "cure",
    "definitely", "certainly", "guaranteed", "virus", "viral", "flu", "covid", "inflammation", "immune",
    "deficiency", "dehydrated", "hangover", "doctor", "physician", "medical advice",
)
RELATIVE_TIME: tuple[str, ...] = (
    "today", "yesterday", "tonight", "tomorrow", "last night", "this morning", "this afternoon",
    "this evening", "right now", "this week", "last week",
)
# Mentions of signals that are estimates. A sentence matching one must also say "estimate(d)".
ESTIMATED_MENTIONS: dict[str, tuple[str, ...]] = {
    "resp_rate": ("respiratory rate", "breathing rate", "breaths per minute", "breaths/min"),
    "spo2": ("blood oxygen", "spo2", "oxygen saturation"),
    "sleep": ("sleep duration", "slept", "hours of sleep", "sleep time", "sleep efficiency", "sleep timing",
              "fell asleep", "woke", "wake time", "bedtime", "sleep onset", "deep sleep", "rem sleep", "light sleep"),
    "activity": ("locomotion", "movement bout", "training load", "activity level", "active minutes"),
}

MONTHS = {m: i for i, m in enumerate(
    ("jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"), start=1)}
_MONTH = r"(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?"
_MONTH_DAY = re.compile(rf"\b{_MONTH}\s+(\d{{1,2}})(?:st|nd|rd|th)?(?:,?\s+(\d{{4}}))?\b", re.I)
_DAY_MONTH = re.compile(rf"\b(\d{{1,2}})(?:st|nd|rd|th)?\s+{_MONTH}(?:,?\s+(\d{{4}}))?\b", re.I)
_ISO_DAY = re.compile(r"\b(\d{4})-(\d{2})-(\d{2})\b")
_CLOCK = re.compile(r"\b\d{1,2}:\d{2}\b")
_NUMBER = re.compile(r"(?<![\w.])[-+−]?\d+(?:[.,]\d+)?(?![\w])")
_PMID_OR_DOI = re.compile(r"\bpmid\s*[:#]?\s*\d+|\b10\.\d{4,9}/\S+", re.I)
_PERSONAL = re.compile(r"\b(you|your|you're|you've)\b", re.I)

MAX_HEADLINE = 120
MAX_SENTENCE = 280
MAX_TOTAL = 1200
MAX_ITEMS = 3
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


def _term_pattern(term: str) -> re.Pattern[str]:
    return re.compile(r"\b" + re.escape(term) + r"\b", re.I)


_FORBIDDEN = [(t, _term_pattern(t)) for t in FORBIDDEN_TERMS]
_CLAIMS = [(t, _term_pattern(t)) for t in CLAIM_TERMS]
_RELATIVE = [(t, _term_pattern(t)) for t in RELATIVE_TIME]


def forbidden_term(text: str) -> str | None:
    """The first app-forbidden term in text (whole words: "still" never matches "ill")."""
    return next((t for t, p in _FORBIDDEN if p.search(text)), None)


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


def _numbers(value: Any, out: set[float]) -> None:
    if isinstance(value, bool) or value is None:
        return
    if isinstance(value, (int, float)):
        if math.isfinite(value):
            out.add(float(value))
            out.add(abs(float(value)))
    elif isinstance(value, dict):
        for item in value.values():
            _numbers(item, out)
    elif isinstance(value, (list, tuple)):
        for item in value:
            _numbers(item, out)
    elif isinstance(value, str):
        for match in _NUMBER.finditer(_strip_dates(value)):
            number = _to_float(match.group(0))
            if number is not None:
                out.add(number)
                out.add(abs(number))


def _days(value: Any, out: set[date]) -> None:
    if isinstance(value, dict):
        for item in value.values():
            _days(item, out)
    elif isinstance(value, (list, tuple)):
        for item in value:
            _days(item, out)
    elif isinstance(value, str):
        for match in _ISO_DAY.finditer(value):
            try:
                out.add(date(int(match.group(1)), int(match.group(2)), int(match.group(3))))
            except ValueError:
                pass


def _strip_dates(text: str) -> str:
    for pattern in (_ISO_DAY, _MONTH_DAY, _DAY_MONTH, _CLOCK):
        text = pattern.sub(" ", text)
    return text


def _to_float(token: str) -> float | None:
    try:
        return float(token.replace("−", "-").replace(",", "."))
    except ValueError:
        return None


def _mentioned_days(text: str) -> list[tuple[int, int, int | None]]:
    found = []
    for match in _MONTH_DAY.finditer(text):
        found.append((MONTHS[match.group(1)[:3].lower()], int(match.group(2)),
                      int(match.group(3)) if match.group(3) else None))
    for match in _DAY_MONTH.finditer(text):
        found.append((MONTHS[match.group(2)[:3].lower()], int(match.group(1)),
                      int(match.group(3)) if match.group(3) else None))
    for match in _ISO_DAY.finditer(text):
        found.append((int(match.group(2)), int(match.group(3)), int(match.group(1))))
    return found


def _grounded(token: str, allowed: set[float]) -> bool:
    number = _to_float(token)
    if number is None:
        return False
    decimals = len(token.replace(",", ".").split(".", 1)[1]) if ("." in token or "," in token) else 0
    return any(round(value, decimals) == round(number, decimals) for value in allowed)


def _estimated_groups(evidence: dict[str, Any]) -> set[str]:
    groups = {"sleep", "activity"}  # sleep detection and movement classification are always estimates
    related = (evidence.get("get_related_metrics") or {}).get("signals") or []
    for signal in related:
        if signal.get("estimated") and signal.get("metric") in ("resp_rate", "spo2"):
            groups.add(signal["metric"])
        if signal.get("metric") in ("sleep_total", "sleep_efficiency"):
            groups.add("sleep")
    return groups


def check(text: str, evidence: dict[str, Any], retrieved: dict[str, dict[str, Any]]) -> Result:
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
        sections[key] = [s.strip() for s in value]
    citations = answer.get("citations", [])
    if not isinstance(citations, list) or not all(isinstance(c, str) for c in citations) or len(citations) > MAX_ITEMS:
        errors.append(f"shape:citations must be a list of at most {MAX_ITEMS} ids")
        citations = []
    if errors:
        return Result(False, None, errors)

    sentences = [headline.strip(), *[s for key in ("observed", "interpretation", "uncertainty") for s in sections[key]]]
    if sum(len(s) for s in sentences) > MAX_TOTAL:
        errors.append(f"concise:the whole explanation is longer than {MAX_TOTAL} characters")

    allowed: set[float] = {float(n) for n in WINDOW_NUMBERS}
    _numbers(evidence, allowed)
    _numbers([r.get("finding") for r in retrieved.values()], allowed)
    known_days: set[date] = set()
    _days(evidence, known_days)
    estimated = _estimated_groups(evidence)

    for sentence in sentences:
        lowered = sentence.lower()
        for term, pattern in _FORBIDDEN:
            if pattern.search(sentence):
                errors.append(f"wording:forbidden term '{term}'")
        for term, pattern in _CLAIMS:
            if pattern.search(sentence):
                errors.append(f"claim:'{term}' states a diagnosis, a cause or certainty; describe association with uncertainty instead")
        for term, pattern in _RELATIVE:
            if pattern.search(sentence):
                errors.append(f"dates:'{term}' is relative; use the absolute date (e.g. Oct 6)")
        for token in (m.group(0) for m in _NUMBER.finditer(_strip_dates(sentence))):
            if not _grounded(token, allowed):
                errors.append(f"grounding:the number {token} is not in any tool result")
        for month, day, year in _mentioned_days(sentence):
            if not any(d.month == month and d.day == day and (year is None or d.year == year) for d in known_days):
                errors.append(f"dates:{month}/{day} is not a night in the tool results")
        # A sentence that states this person's own estimated value (a number, a date, "you/your") must say it
        # is an estimate; a general remark ("may reflect sleep timing") need not.
        personal = bool(re.search(r"\d", sentence) or _PERSONAL.search(sentence))
        for group in estimated:
            if (personal and any(alias in lowered for alias in ESTIMATED_MENTIONS[group])
                    and "estimat" not in lowered):
                errors.append(f"estimated:a sentence about your {group.replace('_', ' ')} must say it is estimated")
        if _PMID_OR_DOI.search(sentence):
            errors.append("citations:put literature ids only in the citations list, not in the text")

    unknown = [c for c in citations if c not in retrieved]
    if unknown:
        errors.append(f"citations:{', '.join(unknown[:3])} were not returned by search_literature in this session")
    answer = {"headline": headline.strip(), **sections, "citations": list(dict.fromkeys(citations))}
    return Result(not errors, answer, list(dict.fromkeys(errors)))

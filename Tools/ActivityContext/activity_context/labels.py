"""Ground-truth label model, window/label joining, and evaluation metrics.

Spec 10 / 13 (Nara activity ground-truth harness): pure, numpy-only, no torch.
This module owns:

  * ``LabelRecord`` -- one wire ground-truth label (``ground-truth-labels``
    route / ``activity_ground_truth_labels`` table), with the two evaluation
    flags the harness keys on:

      - ``strength``: ``strong`` only when ``source == "guided"`` AND the
        user was not unsure; everything else (stretch feedback, imported,
        guided-but-unsure) is ``weak``. Strong and weak are never mixed in
        the default evaluation (spec 13 "separate strong guided labels from
        weak feedback labels").

      - ``evaluation_ready``: a label is usable for evaluation only when its
        sensor coverage is complete. The store fills ``sensor_quality`` at
        save time, but we do NOT trust the wire's convenience flag: a label
        whose interval contains ANY gap in ``sensor_quality.gaps`` or whose
        ``covered_seconds < expected_seconds`` is NEVER evaluation-ready,
        even if the wire says otherwise. A label with no ``sensor_quality``
        at all is ``evaluation_ready == False`` (documented decision: absent
        coverage evidence is not evidence of coverage).

  * ``load_labels`` -- defensive JSONL / JSON-array loader that skips and
    counts malformed records instead of aborting the harness.

  * ``WindowPrediction`` + ``parse_day_doc`` -- the ``hart-windows-1`` day
    document (``ActivityEncoderWindows.swift``) reader: parallel arrays
    ``s,e,l,p,b,f`` relative to the UTC day start ``t0``. Unparseable
    windows are dropped and counted, mirroring the Swift decoder.

  * ``HART_LABEL_TO_HEADS`` -- explicit window-label -> per-head predicted
    value mapping. ``unknown`` maps to ``None`` (abstention).

  * window/label assignment and session-held-out splitting (leakage-free:
    a window can never sit on both sides, and sessions are never split).

  * the metric functions spec 10.3 / methodology require: per-class
    P/R/F1, macro-F1, balanced accuracy, confusion matrix, abstention rate,
    accepted coverage, duration-weighted accuracy, segment IoU, transition
    matching with tolerance, Brier / ECE-15 per head, and per-session
    macro-F1 (pooled vs session-macro both reported).

Metric conventions (consistent, documented choices):

  * Abstention (``predicted is None``) is a DECISION, not a class. Per-class
    P/R/F1, Brier and ECE are scored on ACCEPTED units only; abstention rate
    and accepted coverage are reported alongside, never silently dropped
    (methodology 2.2 choice A).
  * ``unknown`` as a window label abstains every head (``HART_LABEL_TO_HEADS``
    maps it to None); a window whose label is outside the mapping also
    abstains.
  * Duration-weighted accuracy weights each unit by its label's true duration
    (methodology 1.2: user-perceived correctness scales with wall-clock time).
"""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import Any, Dict, List, Mapping, Optional, Sequence, Tuple

import numpy as np

# ---------------------------------------------------------------------------
# Canonical vocabulary (ActivityContextOntology.swift / spec 6)
# ---------------------------------------------------------------------------

#: Locomotion classes the window encoder can name. ``brisk_walking`` etc. are
#: future-proofed aliases HART does not currently emit; they are still mapped
#: so the head projection stays total over the ontology.
HART_LABEL_TO_HEADS: Mapping[str, Optional[Dict[str, str]]] = {
    "stationary": {"locomotion": "stationary"},
    "walking": {"locomotion": "walking"},
    "brisk_walking": {"locomotion": "brisk_walking"},
    "running": {"locomotion": "running"},
    "stairs": {"locomotion": "stairs"},
    "cycling": {"locomotion": "cycling"},
    "vehicle_motion": {"locomotion": "vehicle_motion"},
    "other_movement": {"locomotion": "other"},
    "other": {"locomotion": "other"},
    "unknown": None,  # abstention: no head commits
}

#: Head names the harness evaluates. Posture and arm-behavior are supported
#: by the label model (a guided label can set them); HART windows only
#: project locomotion, so the other heads stay abstained for HART/baseline.
ALL_HEADS: Tuple[str, ...] = ("posture", "locomotion", "arm_behavior")

#: Minimum overlap (fraction of the WINDOW) before a window is claimed by a
#: label interval. Mirrors the spec 10 "window level" join: a window [s,e)
#: joins a label when >= 50% of the window lies inside the label interval.
MIN_WINDOW_OVERLAP = 0.5

#: Window entries older than this many seconds are rejected at parse time
#: (mirrors ActivityEncoderWindows.decode max window span).
MAX_WINDOW_SPAN_S = 3600

#: Default transition-matching tolerance (seconds), methodology 3.2.
DEFAULT_TAU_S = 5
#: Tolerances always reported in the transitions block.
TAUS_S: Tuple[int, ...] = (2, 5, 10)

#: Minimum GT events per type before an F1 is claimed (methodology 3.4).
MIN_GT_EVENTS_FOR_REPORT = 20


# ---------------------------------------------------------------------------
# Sensor quality + labels
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class SensorQuality:
    """``ActivityGroundTruthSensorQuality`` mirror (snake_case wire fields)."""

    expected_seconds: int = 0
    covered_seconds: int = 0
    sample_rate_hz: int = 0
    first_ts: Optional[int] = None
    last_ts: Optional[int] = None
    gaps: Tuple[Tuple[int, int], ...] = ()
    coverage_ratio: float = 0.0
    evaluation_ready: bool = False

    @property
    def has_any_gap(self) -> bool:
        return any(g0 < g1 for g0, g1 in self.gaps)

    @property
    def complete(self) -> bool:
        """Complete = every expected second covered AND no gap ever recorded.
        The wire's convenience ``evaluation_ready`` flag is deliberately NOT
        trusted here (see module docstring): gaps always poison a label."""
        if self.expected_seconds <= 0:
            return False
        if self.covered_seconds < self.expected_seconds:
            return False
        return not self.has_any_gap


@dataclass(frozen=True)
class LabelRecord:
    """One wire ground-truth label (spec 8.1 fields, snake_case)."""

    id: Optional[str] = None
    label_key: Optional[str] = None
    source: str = "guided"
    session_id: Optional[str] = None
    protocol_version: Optional[str] = None
    repetition: Optional[int] = None
    device_id: Optional[str] = None
    external_device_id: Optional[str] = None
    start_ts: int = 0
    end_ts: int = 0
    posture: Optional[str] = None
    locomotion: Optional[str] = None
    arm_behavior: Optional[str] = None
    transition_kind: Optional[str] = None
    transition_ts: Optional[int] = None
    semantic_tag: Optional[str] = None
    label_confidence: Optional[float] = None
    user_unsure: bool = False
    note: Optional[str] = None
    cue_context: Optional[Dict[str, Any]] = None
    sensor_quality: Optional[SensorQuality] = None
    raw_refs: Tuple[Dict[str, Any], ...] = ()
    model_context_at_label_time: Optional[Dict[str, str]] = None
    app_version: Optional[str] = None
    app_build: Optional[str] = None
    client_created_at: Optional[str] = None
    client_updated_at: Optional[str] = None
    synced_at: Optional[str] = None
    #: Optional owner id. This layer does not resolve auth; personalization
    #: groups by this field when any label carries it (else one subject).
    user_id: Optional[str] = None

    @property
    def strength(self) -> str:
        """``strong`` for guided, user-confident labels; ``weak`` otherwise."""
        return "strong" if (self.source == "guided" and not self.user_unsure) else "weak"

    @property
    def is_strong(self) -> bool:
        return self.strength == "strong"

    @property
    def session(self) -> str:
        """Session identity: the guided ``session_id`` when present, else the
        stretch/label_key prefix (spec: a weak label's session is its stretch
        key, which is the part of ``label_key`` before the first ``:``)."""
        if self.session_id:
            return self.session_id
        if self.label_key:
            prefix = self.label_key.split(":")[0]
            if prefix:
                return prefix
        return f"{self.source}:{self.start_ts}"

    @property
    def duration_s(self) -> int:
        return max(0, self.end_ts - self.start_ts)

    @property
    def evaluation_ready(self) -> bool:
        """True only when sensor coverage is complete (see module docstring).
        A missing ``sensor_quality`` is NOT evaluation-ready."""
        sq = self.sensor_quality
        if sq is None:
            return False
        return sq.complete

    def heads(self) -> Dict[str, str]:
        """The canonical head -> value pairs this label actually sets.
        Nil head fields mean "unknown / not given" and are not evaluated."""
        out: Dict[str, str] = {}
        if self.posture:
            out["posture"] = self.posture
        if self.locomotion:
            out["locomotion"] = self.locomotion
        if self.arm_behavior:
            out["arm_behavior"] = self.arm_behavior
        return out

    def transition(self) -> Optional[Tuple[str, int]]:
        """(kind, ts) when this label is a definitive transition event."""
        if self.transition_kind and self.transition_ts is not None:
            return (self.transition_kind, self.transition_ts)
        return None


def _maybe_int(value: Any) -> Optional[int]:
    if value is None:
        return None
    try:
        return int(value)
    except (TypeError, ValueError):
        return None


def _parse_sensor_quality(raw: Any) -> Optional[SensorQuality]:
    if not isinstance(raw, dict):
        return None
    gaps_raw = raw.get("gaps") or []
    gaps: List[Tuple[int, int]] = []
    for g in gaps_raw:
        if isinstance(g, dict):
            s, e = _maybe_int(g.get("start_ts")), _maybe_int(g.get("end_ts"))
            if s is not None and e is not None:
                gaps.append((s, e))
    return SensorQuality(
        expected_seconds=int(raw.get("expected_seconds", 0) or 0),
        covered_seconds=int(raw.get("covered_seconds", 0) or 0),
        sample_rate_hz=int(raw.get("sample_rate_hz", 0) or 0),
        first_ts=_maybe_int(raw.get("first_ts")),
        last_ts=_maybe_int(raw.get("last_ts")),
        gaps=tuple(sorted(gaps)),
        coverage_ratio=float(raw.get("coverage_ratio", 0.0) or 0.0),
        evaluation_ready=bool(raw.get("evaluation_ready", False)),
    )


def _label_from_wire(raw: Any) -> Optional[LabelRecord]:
    """Build a LabelRecord from one wire object; None when structurally bad.

    Only structural validity is checked here (required timestamps, sane
    interval). Vocabulary and coverage validity are the evaluator's business:
    ``evaluation_ready`` already folds coverage in, and unknown vocabulary is
    simply never matched by a head.
    """
    if not isinstance(raw, dict):
        return None
    start_ts = _maybe_int(raw.get("start_ts"))
    end_ts = _maybe_int(raw.get("end_ts"))
    if start_ts is None or end_ts is None or end_ts <= start_ts:
        return None
    source = str(raw.get("source") or "guided")
    if source not in ("guided", "stretch_feedback", "imported"):
        source = "guided"
    try:
        return LabelRecord(
            id=str(raw["id"]) if raw.get("id") is not None else None,
            label_key=str(raw["label_key"]) if raw.get("label_key") is not None else None,
            source=source,
            session_id=str(raw["session_id"]) if raw.get("session_id") is not None else None,
            protocol_version=str(raw["protocol_version"]) if raw.get("protocol_version") is not None else None,
            repetition=_maybe_int(raw.get("repetition")),
            device_id=str(raw["device_id"]) if raw.get("device_id") is not None else None,
            external_device_id=str(raw["external_device_id"]) if raw.get("external_device_id") is not None else None,
            start_ts=start_ts,
            end_ts=end_ts,
            posture=str(raw["posture"]) if raw.get("posture") is not None else None,
            locomotion=str(raw["locomotion"]) if raw.get("locomotion") is not None else None,
            arm_behavior=str(raw["arm_behavior"]) if raw.get("arm_behavior") is not None else None,
            transition_kind=str(raw["transition_kind"]) if raw.get("transition_kind") is not None else None,
            transition_ts=_maybe_int(raw.get("transition_ts")),
            semantic_tag=str(raw["semantic_tag"]) if raw.get("semantic_tag") is not None else None,
            label_confidence=float(raw["label_confidence"]) if raw.get("label_confidence") is not None else None,
            user_unsure=bool(raw.get("user_unsure", False)),
            note=str(raw["note"]) if raw.get("note") is not None else None,
            cue_context=raw.get("cue_context") if isinstance(raw.get("cue_context"), dict) else None,
            sensor_quality=_parse_sensor_quality(raw.get("sensor_quality")),
            raw_refs=tuple(r for r in (raw.get("raw_refs") or []) if isinstance(r, dict)),
            model_context_at_label_time=(
                raw.get("model_context_at_label_time")
                if isinstance(raw.get("model_context_at_label_time"), dict) else None),
            app_version=str(raw["app_version"]) if raw.get("app_version") is not None else None,
            app_build=str(raw["app_build"]) if raw.get("app_build") is not None else None,
            client_created_at=str(raw["client_created_at"]) if raw.get("client_created_at") is not None else None,
            client_updated_at=str(raw["client_updated_at"]) if raw.get("client_updated_at") is not None else None,
            synced_at=str(raw["synced_at"]) if raw.get("synced_at") is not None else None,
            user_id=str(raw["user_id"]) if raw.get("user_id") is not None else None,
        )
    except (TypeError, ValueError):
        return None


@dataclass
class LoadReport:
    """Counts from a defensive label load."""

    path: str
    total_lines: int = 0
    parsed: int = 0
    skipped_malformed: int = 0
    skipped_invalid_interval: int = 0
    skipped_no_heads: int = 0

    def as_dict(self) -> Dict[str, Any]:
        return {
            "path": self.path,
            "total_lines": self.total_lines,
            "parsed": self.parsed,
            "skipped_malformed": self.skipped_malformed,
            "skipped_invalid_interval": self.skipped_invalid_interval,
            "skipped_no_heads": self.skipped_no_heads,
        }


def load_labels(path: str) -> Tuple[List[LabelRecord], LoadReport]:
    """Load ground-truth labels from a JSONL file (one wire object per line)
    or a JSON file containing an array of wire objects.

    Defensive: malformed lines / non-object elements are skipped and counted
    in the returned ``LoadReport`` instead of aborting the harness. Labels
    whose interval is degenerate (``end_ts <= start_ts``) are counted as
    ``skipped_invalid_interval``; labels that set no head at all are kept in
    ``parsed`` but counted in ``skipped_no_heads`` (they can never join a
    window, but they still describe a session's existence).
    """
    report = LoadReport(path=path)
    raw_items: List[Any] = []
    with open(path, "r", encoding="utf-8") as f:
        first = f.read(1)
        f.seek(0)
        if first == "[":
            data = json.load(f)
            if isinstance(data, dict) and isinstance(data.get("labels"), list):
                data = data["labels"]
            if not isinstance(data, list):
                raise ValueError(f"{path}: expected a JSON array of labels, got {type(data).__name__}")
            raw_items = data
            report.total_lines = len(raw_items)
        else:
            for line in f:
                line = line.strip()
                report.total_lines += 1
                if not line:
                    continue
                try:
                    raw_items.append(json.loads(line))
                except json.JSONDecodeError:
                    report.skipped_malformed += 1

    labels: List[LabelRecord] = []
    for raw in raw_items:
        rec = _label_from_wire(raw)
        if rec is None:
            # Distinguish "malformed line" (non-dict / unparseable) from a
            # structurally-valid but degenerate interval.
            if isinstance(raw, dict) and "start_ts" in raw and "end_ts" in raw:
                report.skipped_invalid_interval += 1
            else:
                report.skipped_malformed += 1
            continue
        labels.append(rec)
        if not rec.heads():
            report.skipped_no_heads += 1
    report = LoadReport(
        path=path,
        total_lines=report.total_lines,
        parsed=len(labels),
        skipped_malformed=report.skipped_malformed,
        skipped_invalid_interval=report.skipped_invalid_interval,
        skipped_no_heads=report.skipped_no_heads,
    )
    return labels, report


# ---------------------------------------------------------------------------
# Window predictions + hart-windows-1 day documents
# ---------------------------------------------------------------------------

#: ``imu-feat-2`` keys, in the order ``f`` rows use (ActivityEncoderWindows).
FEATURE_KEYS: Tuple[str, ...] = (
    "accel_rms_g", "gyro_rms_dps", "jerk_rms_gps", "cadence_hz",
    "cadence_strength", "orientation_change_deg",
)
#: Multiplier applied before rounding each feature to an integer.
FEATURE_SCALE: Tuple[float, ...] = (100_000, 1_000, 10_000, 1_000, 10_000, 100)

#: ``imu-feat-1`` stored jerk per sample at 30 Hz under ``jerk_rms``; read as
#: per-second (``jerk_rms_gps``) by multiplying by this rate (Swift parity).
LEGACY_JERK_KEY = "jerk_rms"
LEGACY_JERK_SAMPLE_RATE_HZ = 30.0

#: Required feature columns for a usable feature row (Swift parity).
_REQUIRED_FEATURES = ("accel_rms_g", "gyro_rms_dps", "jerk_rms_gps", "cadence_strength")


@dataclass(frozen=True)
class WindowPrediction:
    """One ``hart-windows-1`` window (ActivityWindowPrediction mirror)."""

    start_ts: int
    end_ts: int
    label: str
    probs: Tuple[Tuple[str, float], ...] = ()
    baseline: bool = False
    features: Optional[Dict[str, float]] = None

    @property
    def probs_dict(self) -> Dict[str, float]:
        return dict(self.probs)

    @property
    def head_value(self) -> Optional[str]:
        """Locomotion value this window's label projects onto, or None for
        abstention (unknown / unmapped labels abstain every head)."""
        mapped = HART_LABEL_TO_HEADS.get(self.label)
        if mapped is None:
            return None
        return mapped.get("locomotion")


def _to_num(value: Any) -> Optional[float]:
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        v = float(value)
        return v if math.isfinite(v) else None
    if isinstance(value, str):
        try:
            v = float(value)
        except ValueError:
            return None
        return v if math.isfinite(v) else None
    return None


def _to_int(value: Any) -> Optional[int]:
    v = _to_num(value)
    if v is None or v != math.floor(v):
        return None
    return int(v)


@dataclass
class DayDocReport:
    """Counts from one parsed ``hart-windows-1`` day document."""

    path: str
    format_ok: bool = False
    total_windows: int = 0
    parsed_windows: int = 0
    dropped: int = 0
    encoder_id: str = "hart"

    def as_dict(self) -> Dict[str, Any]:
        return {
            "path": self.path,
            "format_ok": self.format_ok,
            "total_windows": self.total_windows,
            "parsed_windows": self.parsed_windows,
            "dropped": self.dropped,
            "encoder_id": self.encoder_id,
        }


def parse_day_doc(doc: Any, path: str = "<memory>") -> Tuple[List[WindowPrediction], DayDocReport]:
    """Parse one ``hart-windows-1`` day document into window predictions.

    Layout (parallel arrays, times relative to the UTC day start ``t0``):
    ``labels`` (vocabulary order), ``s``/``e`` (window start/end seconds
    after t0), ``l`` (label index), ``p`` (per-mille probabilities),
    ``b`` (1 when the heuristic baseline produced the window), ``f``
    (scaled feature rows or null).

    Defensive parsing mirrors ``ActivityEncoderWindowSet.decode``: a window
    that cannot be parsed (bad span, bad label index, malformed probability
    row, out-of-range per-mille) is dropped and counted, never fatal.
    """
    report = DayDocReport(path=path)
    if not isinstance(doc, dict) or doc.get("format") != "hart-windows-1":
        return [], report

    t0 = _to_int(doc.get("t0"))
    labels_raw = doc.get("labels")
    if t0 is None or not isinstance(labels_raw, list) or not labels_raw:
        return [], report
    labels: List[str] = [str(x) for x in labels_raw]

    keys = ("s", "e", "l", "p", "b", "f")
    cols: Dict[str, List[Any]] = {}
    for k in keys:
        v = doc.get(k)
        if not isinstance(v, list):
            return [], report
        cols[k] = v
    n = len(cols["s"])
    if not all(len(cols[k]) == n for k in keys[1:]):
        return [], report

    feature_keys_raw = doc.get("features")
    feature_keys: List[str] = FEATURE_KEYS
    if isinstance(feature_keys_raw, list) and feature_keys_raw:
        feature_keys = [str(x) for x in feature_keys_raw]
    scales_raw = doc.get("feature_scale")
    scales: List[float] = list(FEATURE_SCALE)
    if isinstance(scales_raw, list):
        parsed_scales = [_to_num(x) for x in scales_raw]
        if len(parsed_scales) == len(feature_keys) and all(
                s is not None and s > 0 for s in parsed_scales):
            scales = [float(s) for s in parsed_scales]

    def feature_index(key: str) -> Optional[int]:
        if key in feature_keys:
            i = feature_keys.index(key)
            if i < len(scales) and scales[i] > 0:
                return i
        return None

    idx = {k: feature_index(k) for k in FEATURE_KEYS}
    legacy_jerk = idx["jerk_rms_gps"] is None and feature_index(LEGACY_JERK_KEY) is not None
    if legacy_jerk:
        idx["jerk_rms_gps"] = feature_index(LEGACY_JERK_KEY)

    report.format_ok = True
    report.total_windows = n
    windows: List[WindowPrediction] = []
    for i in range(n):
        start = _to_int(cols["s"][i])
        end = _to_int(cols["e"][i])
        li = _to_int(cols["l"][i])
        b = _to_int(cols["b"][i])
        if start is None or end is None or li is None or b is None:
            report.dropped += 1
            continue
        if end <= start or end - start > MAX_WINDOW_SPAN_S:
            report.dropped += 1
            continue
        if li < 0 or li >= len(labels):
            report.dropped += 1
            continue
        p_row = cols["p"][i]
        if not isinstance(p_row, list) or len(p_row) != len(labels):
            report.dropped += 1
            continue
        probs: List[Tuple[str, float]] = []
        valid = True
        for lab, raw in zip(labels, p_row):
            permille = _to_num(raw)
            if permille is None or permille < 0 or permille > 1000:
                valid = False
                break
            if permille > 0:
                probs.append((lab, permille / 1000.0))
        if not valid:
            report.dropped += 1
            continue
        window_label = labels[li]
        baseline_flag = b == 1

        features: Optional[Dict[str, float]] = None
        f_row = cols["f"][i]
        if isinstance(f_row, list):
            values: Dict[str, float] = {}
            ok = True
            for key in FEATURE_KEYS:
                fi = idx[key]
                if fi is None or fi >= len(f_row):
                    ok = False
                    break
                raw = f_row[fi]
                if raw is None:
                    continue
                v = _to_num(raw)
                if v is None:
                    ok = False
                    break
                values[key] = v / scales[fi]
                if legacy_jerk and key == "jerk_rms_gps":
                    values[key] *= LEGACY_JERK_SAMPLE_RATE_HZ
            if ok and all(k in values for k in _REQUIRED_FEATURES):
                features = values

        windows.append(WindowPrediction(
            start_ts=start + t0,
            end_ts=end + t0,
            label=window_label,
            probs=tuple(probs),
            baseline=baseline_flag,
            features=features,
        ))
    report = DayDocReport(
        path=path,
        format_ok=True,
        total_windows=n,
        parsed_windows=len(windows),
        dropped=n - len(windows),
        encoder_id="baseline" if all(w.baseline for w in windows) else "hart",
    )
    return windows, report


# ---------------------------------------------------------------------------
# Window <-> label assignment and session-held-out splits
# ---------------------------------------------------------------------------

@dataclass(frozen=True)
class EvalUnit:
    """One evaluated (window, head, truth) triple.

    ``predicted`` is the model's head value for the window (None =
    abstention). ``session`` is the label session that claimed the window.
    ``model`` is "hart" / "baseline" / "activity_context".
    """

    window: WindowPrediction
    head: str
    truth: str
    predicted: Optional[str]
    session: str
    model: str
    label_duration_s: int
    label: LabelRecord


def assign_units(
    labels: Sequence[LabelRecord],
    windows: Sequence[WindowPrediction],
    *,
    include_degraded: bool = False,
    include_weak: bool = False,
    model: str = "hart",
) -> Tuple[List[EvalUnit], Dict[str, int]]:
    """Join windows to labels -> evaluation units (spec 10 window level).

    A window [s,e) joins a label when >= ``MIN_WINDOW_OVERLAP`` (50%) of the
    window lies inside the label interval AND the label sets the head. The
    unit's ``truth`` is the label's value for the head; ``predicted`` comes
    from ``HART_LABEL_TO_HEADS`` via ``WindowPrediction.head_value``.

    Split-integrity guarantee: each window is claimed by AT MOST ONE label
    (the one with the largest overlap; ties break on earliest start then
    label_key). A window straddling two labels of DIFFERENT sessions can
    therefore never place units on both sides of a session split.

    Exclusions (never mixed into the default evaluation):

      * labels that are not ``evaluation_ready`` are excluded unless
        ``include_degraded`` (gaps / short coverage poison a label);
      * weak labels (stretch feedback, imported, guided-but-unsure) are
        excluded unless ``include_weak``.

    Returns (units, counts) where counts explains what was excluded.
    """
    counts: Dict[str, int] = {
        "labels_total": 0,
        "labels_evaluation_ready": 0,
        "labels_degraded_included": 0,
        "labels_excluded_degraded": 0,
        "labels_excluded_weak": 0,
        "windows_total": len(windows),
        "windows_unclaimed": 0,
        "units": 0,
    }

    # Eligible labels first (coverage + strength), so the exclusion counts are
    # per label and the window claim loop stays O(windows * eligible_labels).
    eligible: List[LabelRecord] = []
    for label in labels:
        counts["labels_total"] += 1
        if not label.evaluation_ready:
            if include_degraded:
                counts["labels_degraded_included"] += 1
            else:
                counts["labels_excluded_degraded"] += 1
                continue
        else:
            counts["labels_evaluation_ready"] += 1
        if not include_weak and not label.is_strong:
            counts["labels_excluded_weak"] += 1
            continue
        if label.heads():
            eligible.append(label)

    units: List[EvalUnit] = []
    for w in windows:
        # Best eligible label for this window by overlap.
        best: Optional[Tuple[float, int, str, int, LabelRecord]] = None
        for i, label in enumerate(eligible):
            if w.end_ts <= label.start_ts or w.start_ts >= label.end_ts:
                continue
            overlap = min(w.end_ts, label.end_ts) - max(w.start_ts, label.start_ts)
            key = (overlap, -label.start_ts, label.label_key or "", i, label)
            if best is None or key > best:
                best = key
        if best is None:
            counts["windows_unclaimed"] += 1
            continue
        overlap, _neg_start, _key, _i, label = best
        window_len = w.end_ts - w.start_ts
        if window_len <= 0 or overlap < MIN_WINDOW_OVERLAP * window_len:
            counts["windows_unclaimed"] += 1
            continue
        predicted = w.head_value
        for head, truth in label.heads().items():
            units.append(EvalUnit(
                window=w,
                head=head,
                truth=truth,
                predicted=predicted,
                session=label.session,
                model=model,
                label_duration_s=label.duration_s,
                label=label,
            ))
    counts["units"] = len(units)
    return units, counts


def session_of_window(
    window: WindowPrediction, labels: Sequence[LabelRecord]
) -> Optional[str]:
    """Session of the label with the largest overlap over this window
    (deterministic tie-break: earliest start_ts, then label_key). Used to
    place every window on one side of a session split even when a window
    straddles two labels of one session or two sessions."""
    best: Optional[Tuple[float, int, str, str]] = None
    for label in labels:
        if not label.evaluation_ready:
            continue
        if window.end_ts <= label.start_ts or window.start_ts >= label.end_ts:
            continue
        overlap = min(window.end_ts, label.end_ts) - max(window.start_ts, label.start_ts)
        key = (overlap, -label.start_ts, label.label_key or "", label.session)
        if best is None or key > best:
            best = key
    if best is None:
        return None
    return best[3]


@dataclass(frozen=True)
class SplitResult:
    """Deterministic session-held-out split. Every window of a session stays
    on ONE side; windows not claimed by any label are excluded."""

    train_units: Tuple[EvalUnit, ...]
    test_units: Tuple[EvalUnit, ...]
    train_sessions: Tuple[str, ...]
    test_sessions: Tuple[str, ...]
    mode: str
    report: Dict[str, Any]

    @property
    def train_windows(self) -> List[WindowPrediction]:
        return [u.window for u in self.train_units]

    @property
    def test_windows(self) -> List[WindowPrediction]:
        return [u.window for u in self.test_units]


def split_by_session(
    labels: Sequence[LabelRecord],
    units: Sequence[EvalUnit],
    *,
    holdout_sessions: int = 1,
    mode: str = "holdout",
    chronological_ts: Optional[int] = None,
) -> SplitResult:
    """Leakage-free split (spec 10.4): sessions, never windows, are the split
    unit. Deterministic:

      * sessions are ordered by their EARLIEST label ``start_ts`` (ties by
        session string);
      * ``mode="holdout"``: the last ``holdout_sessions`` sessions (latest)
        are the test side;
      * ``mode="alternate"``: sessions alternate train/test in that order;
      * ``mode="chronological"``: sessions whose earliest start >=
        ``chronological_ts`` are test (a session is never cut in two).

    The split is applied to the UNITS of every model at once, so "hart",
    "baseline" and "activity_context" always score the same labeled windows
    on each side.
    """
    if holdout_sessions < 0:
        raise ValueError("holdout_sessions must be >= 0")
    if mode not in ("holdout", "alternate", "chronological"):
        raise ValueError(f"unknown split mode: {mode!r}")

    # Session ordering by the earliest label start_ts among the UNITS being
    # split. Sessions whose labels were excluded from evaluation (weak or
    # degraded) never appear in the ordering, so a held-out side is always
    # backed by real units and the split is consistent across models.
    earliest: Dict[str, int] = {}
    for u in units:
        s = u.session
        start = u.label.start_ts
        if s not in earliest or start < earliest[s]:
            earliest[s] = start
    ordered = sorted(earliest.items(), key=lambda kv: (kv[1], kv[0]))

    if mode == "chronological":
        if chronological_ts is None:
            raise ValueError("chronological mode requires chronological_ts")
        test_set = {s for s, ts in ordered if ts >= chronological_ts}
        train_set = {s for s, ts in ordered if s not in test_set}
    elif mode == "alternate":
        train_set = {s for i, (s, _ts) in enumerate(ordered) if i % 2 == 0}
        test_set = {s for i, (s, _ts) in enumerate(ordered) if i % 2 == 1}
    else:  # holdout
        k = min(holdout_sessions, len(ordered))
        train_set = {s for s, _ts in ordered[:len(ordered) - k]}
        test_set = {s for s, _ts in ordered[len(ordered) - k:]}

    train: List[EvalUnit] = []
    test: List[EvalUnit] = []
    for u in units:
        if u.session in test_set:
            test.append(u)
        elif u.session in train_set:
            train.append(u)
        # else: session not backed by any label -> window dropped (can't
        # happen for units, which always carry a label session).

    report = {
        "mode": mode,
        "holdout_sessions": holdout_sessions,
        "chronological_ts": chronological_ts,
        "n_sessions_total": len(ordered),
        "n_train_sessions": len(train_set),
        "n_test_sessions": len(test_set),
        "train_sessions": sorted(train_set),
        "test_sessions": sorted(test_set),
        "n_train_units": len(train),
        "n_test_units": len(test),
        "session_order": [s for s, _ in ordered],
    }
    return SplitResult(
        train_units=tuple(train),
        test_units=tuple(test),
        train_sessions=tuple(sorted(train_set)),
        test_sessions=tuple(sorted(test_set)),
        mode=mode,
        report=report,
    )


# ---------------------------------------------------------------------------
# Metrics (spec 10.3, methodology 1-3)
# ---------------------------------------------------------------------------

def _f1(p: float, r: float) -> float:
    return 0.0 if (p + r) == 0 else 2.0 * p * r / (p + r)


def confusion_matrix(
    truths: Sequence[str], preds: Sequence[Optional[str]], classes: Sequence[str]
) -> Tuple[np.ndarray, int]:
    """Confusion matrix (rows = truth, cols = prediction) over ACCEPTED units
    (prediction not None). Unknown/abstained units are excluded here and
    reported via abstention_rate / accepted_coverage instead."""
    idx = {c: i for i, c in enumerate(classes)}
    conf = np.zeros((len(classes), len(classes)), dtype=np.int64)
    accepted = 0
    for t, p in zip(truths, preds):
        if p is None:
            continue
        if t not in idx or p not in idx:
            continue
        accepted += 1
        conf[idx[t], idx[p]] += 1
    return conf, accepted


def prf_per_class(conf: np.ndarray, classes: Sequence[str]) -> Dict[str, Dict[str, float]]:
    """Per-class precision / recall / F1 / counts from a confusion matrix."""
    out: Dict[str, Dict[str, float]] = {}
    n = len(classes)
    for i, c in enumerate(classes):
        tp = int(conf[i, i])
        fp = int(conf[:, i].sum()) - tp
        fn = int(conf[i, :].sum()) - tp
        p = tp / (tp + fp) if (tp + fp) else 0.0
        r = tp / (tp + fn) if (tp + fn) else 0.0
        out[c] = {
            "tp": tp, "fp": fp, "fn": fn,
            "precision": round(p, 6), "recall": round(r, 6), "f1": round(_f1(p, r), 6),
            "support": tp + fn,
        }
    return out


def macro_f1(per_class: Mapping[str, Mapping[str, float]]) -> float:
    """Macro-F1 = unweighted mean of per-class F1 (methodology 1.1)."""
    f1s = [pc["f1"] for pc in per_class.values()]
    return float(np.mean(f1s)) if f1s else 0.0


def balanced_accuracy(per_class: Mapping[str, Mapping[str, float]]) -> float:
    """Balanced accuracy = unweighted mean of per-class recall."""
    rs = [pc["recall"] for pc in per_class.values()]
    return float(np.mean(rs)) if rs else 0.0


def abstention_rate(n_abstained: int, n_total: int) -> float:
    return n_abstained / n_total if n_total else 0.0


def accepted_coverage(n_accepted: int, n_total: int) -> float:
    return n_accepted / n_total if n_total else 0.0


def duration_weighted_accuracy(units: Sequence[EvalUnit]) -> float:
    """Weight each accepted unit by its label's true duration
    (methodology 1.2): what fraction of real labeled wall-clock time is
    classified correctly on the accepted stream."""
    num = 0.0
    den = 0.0
    for u in units:
        if u.predicted is None:
            continue
        w = max(1, u.label_duration_s)
        den += w
        if u.predicted == u.truth:
            num += w
    return num / den if den else 0.0


def _units_runs(units: Sequence[EvalUnit], value_of) -> List[Tuple[int, int, Any]]:
    """Coalesce time-ordered units into runs of identical ``value_of``.
    A None (abstained) unit breaks a run; a time gap larger than one hop
    (2 s) breaks it too."""
    ordered = sorted(units, key=lambda u: (u.window.start_ts, u.window.end_ts))
    runs: List[Tuple[int, int, Any]] = []
    for u in ordered:
        v = value_of(u)
        s, e = u.window.start_ts, u.window.end_ts
        if runs and runs[-1][2] == v and s <= runs[-1][1] + 2:
            runs[-1] = (runs[-1][0], max(runs[-1][1], e), v)
        else:
            runs.append((s, e, v))
    return runs


def segment_iou(units: Sequence[EvalUnit]) -> Dict[str, Any]:
    """Segment-level overlap (Ward et al. 2006; methodology 1.3): predicted
    runs vs truth runs, greedy one-to-one by IoU; segment-F1 =
    2 * sum(matched IoU) / (sum |pred| + sum |truth|). Punishes
    over-segmentation: a fragmented prediction pays in the denominator."""
    truth_runs = _units_runs(units, lambda u: u.truth)
    pred_runs = _units_runs(units, lambda u: u.predicted)
    matched: List[float] = []
    pred_used = [False] * len(pred_runs)
    for ts, te, _tv in truth_runs:
        best_iou = 0.0
        best = None
        for i, (ps, pe, _pv) in enumerate(pred_runs):
            if pred_used[i]:
                continue
            inter = min(te, pe) - max(ts, ps)
            if inter <= 0:
                continue
            union = (pe - ps) + (te - ts) - inter
            iou = inter / union
            if iou > best_iou:
                best_iou = iou
                best = i
        if best is not None:
            pred_used[best] = True
            matched.append(best_iou)
    denom = sum(pe - ps for ps, pe, _ in pred_runs) + sum(te - ts for ts, te, _ in truth_runs)
    seg_f1 = 2.0 * sum(matched) / denom if denom else 0.0
    return {
        "segment_f1": round(seg_f1, 6),
        "mean_matched_iou": round(float(np.mean(matched)), 6) if matched else 0.0,
        "n_pred_runs": len(pred_runs),
        "n_truth_runs": len(truth_runs),
        "n_matched_runs": len(matched),
    }


def predicted_transitions(units: Sequence[EvalUnit]) -> List[Tuple[str, int]]:
    """Predicted transition events from the predicted label stream: a change
    between two consecutive NON-ABSTAINED windows (same session, time-adjacent)
    is an event at the window boundary. Kind is ``"prev->next"``; the harness
    matches events by time, so the kind is informational."""
    events: List[Tuple[str, int]] = []
    by_session: Dict[str, List[EvalUnit]] = {}
    for u in units:
        by_session.setdefault(u.session, []).append(u)
    for sess, sess_units in by_session.items():
        ordered = sorted(sess_units, key=lambda u: (u.window.start_ts, u.window.end_ts))
        prev: Optional[str] = None
        prev_end: Optional[int] = None
        for u in ordered:
            if u.predicted is None:
                prev = None
                prev_end = None
                continue
            if prev is not None and prev != u.predicted:
                if prev_end is not None and u.window.start_ts <= prev_end + 2:
                    events.append((f"{prev}->{u.predicted}", prev_end))
            prev = u.predicted
            prev_end = u.window.end_ts
    return events


def transition_matching(
    gt_events: Sequence[Tuple[str, int]],
    pred_events: Sequence[Tuple[str, int]],
    tau: int = DEFAULT_TAU_S,
    monitored_seconds: int = 0,
) -> Dict[str, Any]:
    """One-to-one greedy nearest transition matching within tolerance tau
    (methodology 3.2/3.3). Events are (kind, ts) pairs; matching is by time
    only. Reports matched / unmatched, timing error (median/p90 abs), signed
    bias (median pred - gt; a systematic sign reveals lag/lead), and false
    events per hour over ``monitored_seconds``."""
    gt = sorted(gt_events, key=lambda kv: kv[1])
    pred = sorted(pred_events, key=lambda kv: kv[1])
    used = [False] * len(pred)
    matched: List[Tuple[int, int]] = []
    for gk, gts in gt:
        best: Optional[int] = None
        best_d: Optional[int] = None
        for i, (_pk, pts) in enumerate(pred):
            if used[i]:
                continue
            d = abs(pts - gts)
            if d <= tau and (best_d is None or d < best_d):
                best_d = d
                best = i
        if best is not None:
            used[best] = True
            matched.append((gts, pred[best][1]))
    n_matched = len(matched)
    n_gt = len(gt)
    n_pred = len(pred)
    errs = [abs(p - g) for g, p in matched]
    signed = [p - g for g, p in matched]
    precision = n_matched / n_pred if n_pred else 0.0
    recall = n_matched / n_gt if n_gt else 0.0
    hours = monitored_seconds / 3600.0 if monitored_seconds > 0 else 0.0
    result: Dict[str, Any] = {
        "tau_s": tau,
        "n_gt_events": n_gt,
        "n_pred_events": n_pred,
        "matched": n_matched,
        "unmatched_gt": n_gt - n_matched,
        "unmatched_pred": n_pred - n_matched,
        "precision": round(precision, 6),
        "recall": round(recall, 6),
        "f1": round(_f1(precision, recall), 6),
        "median_abs_err_s": round(float(np.median(errs)), 3) if errs else None,
        "p90_abs_err_s": round(float(np.percentile(errs, 90)), 3) if errs else None,
        "signed_bias_s": round(float(np.median(signed)), 3) if signed else None,
        "fp_per_hour": round((n_pred - n_matched) / hours, 4) if hours else None,
        "monitored_seconds": monitored_seconds,
    }
    return result


def _head_probabilities(window: WindowPrediction, truth_classes: Sequence[str]) -> Optional[np.ndarray]:
    """Per-head posterior over ``truth_classes`` from the window's HART
    probabilities: probabilities of source labels mapping to each head value
    are summed, then renormalized over the head's own simplex. None when the
    window carries no probabilities at all."""
    if not window.probs:
        return None
    q = np.zeros(len(truth_classes), dtype=np.float64)
    for src_label, p in window.probs:
        mapped = HART_LABEL_TO_HEADS.get(src_label)
        if mapped is None:
            continue
        head_value = mapped.get("locomotion")
        if head_value in truth_classes:
            q[truth_classes.index(head_value)] += p
    z = q.sum()
    if z <= 0:
        return None
    return q / z


def brier_per_head(units: Sequence[EvalUnit]) -> Optional[float]:
    """Multi-class Brier over the head's own simplex, ACCEPTED units only
    (methodology 2.1/2.2 choice A). Perfect probabilities -> 0."""
    accepted = [u for u in units if u.predicted is not None]
    if not accepted:
        return None
    classes = sorted({u.truth for u in units})
    if not classes:
        return None
    scores = 0.0
    n = 0
    for u in accepted:
        p = _head_probabilities(u.window, classes)
        if p is None:
            # No usable probabilities: a one-hot of the (accepted) prediction.
            p = np.zeros(len(classes), dtype=np.float64)
            p[classes.index(u.predicted)] = 1.0
        y = np.zeros(len(classes), dtype=np.float64)
        y[classes.index(u.truth)] = 1.0
        scores += float(np.sum((p - y) ** 2))
        n += 1
    return scores / n if n else None


def ece_15_per_head(units: Sequence[EvalUnit], bins: int = 15) -> Optional[float]:
    """ECE with ``bins`` equal-width confidence bins over the head's own
    simplex, ACCEPTED units only (methodology 2.3). Perfect probabilities -> 0."""
    accepted = [u for u in units if u.predicted is not None]
    if not accepted:
        return None
    classes = sorted({u.truth for u in units})
    if not classes:
        return None
    confs: List[float] = []
    accs: List[float] = []
    for u in accepted:
        p = _head_probabilities(u.window, classes)
        if p is None:
            p = np.zeros(len(classes), dtype=np.float64)
            p[classes.index(u.predicted)] = 1.0
        confs.append(float(p.max()))
        pred_class = classes[int(p.argmax())]
        accs.append(1.0 if pred_class == u.truth else 0.0)
    confs = np.asarray(confs)
    accs = np.asarray(accs)
    n = len(confs)
    edges = np.linspace(0.0, 1.0, bins + 1)
    ece = 0.0
    for lo, hi in zip(edges[:-1], edges[1:]):
        if hi < 1.0:
            m = (confs >= lo) & (confs < hi)
        else:
            m = (confs >= lo) & (confs <= hi)
        if m.sum() == 0:
            continue
        ece += (m.sum() / n) * abs(float(accs[m].mean()) - float(confs[m].mean()))
    return round(ece, 6)


def per_session_macro_f1(units: Sequence[EvalUnit]) -> Dict[str, Any]:
    """Per-session macro-F1 distribution + pooled macro-F1 (methodology 5.3):
    both the session-macro (mean of per-session macro-F1, each session counts
    once) and the pooled metric (computed on the pooled confusion matrix)
    are reported; a divergence > 0.05 signals cross-session label shift."""
    by_session: Dict[str, List[EvalUnit]] = {}
    for u in units:
        by_session.setdefault(u.session, []).append(u)
    per_session: Dict[str, Dict[str, Any]] = {}
    session_f1s: List[float] = []
    for sess in sorted(by_session):
        sess_units = by_session[sess]
        classes = sorted({u.truth for u in sess_units} |
                         {u.predicted for u in sess_units
                          if u.predicted is not None})
        truths = [u.truth for u in sess_units]
        preds = [u.predicted for u in sess_units]
        conf, _ = confusion_matrix(truths, preds, classes)
        pc = prf_per_class(conf, classes)
        mf1 = macro_f1(pc)
        session_f1s.append(mf1)
        per_session[sess] = {
            "n_units": len(sess_units),
            "n_accepted": sum(1 for u in sess_units if u.predicted is not None),
            "macro_f1": round(mf1, 6),
            "classes": list(classes),
        }
    pooled_classes = sorted({u.truth for u in units} |
                            {u.predicted for u in units
                             if u.predicted is not None})
    pooled_truths = [u.truth for u in units]
    pooled_preds = [u.predicted for u in units]
    pooled_conf, _ = confusion_matrix(pooled_truths, pooled_preds, pooled_classes)
    pooled_mf1 = macro_f1(prf_per_class(pooled_conf, pooled_classes))
    arr = np.asarray(session_f1s, dtype=np.float64)
    q25, q75 = np.percentile(arr, [25, 75]) if arr.size else (0.0, 0.0)
    return {
        "per_session": per_session,
        "n_sessions": len(per_session),
        "session_macro_f1_mean": round(float(arr.mean()), 6) if arr.size else 0.0,
        "session_macro_f1_median": round(float(np.median(arr)), 6) if arr.size else 0.0,
        "session_macro_f1_iqr": round(float(q75 - q25), 6) if arr.size else 0.0,
        "session_macro_f1_min": round(float(arr.min()), 6) if arr.size else 0.0,
        "session_macro_f1_max": round(float(arr.max()), 6) if arr.size else 0.0,
        "pooled_macro_f1": round(pooled_mf1, 6),
        "divergence": round(abs(pooled_mf1 - (float(arr.mean()) if arr.size else 0.0)), 6),
    }


def evaluate_head(units: Sequence[EvalUnit], monitored_seconds: int = 0) -> Dict[str, Any]:
    """Full pooled metric report for ONE head over ``units`` (spec 10.3)."""
    classes = sorted({u.truth for u in units} |
                     {u.predicted for u in units if u.predicted is not None})
    truths = [u.truth for u in units]
    preds = [u.predicted for u in units]
    n = len(units)
    n_abstained = sum(1 for p in preds if p is None)
    n_accepted = n - n_abstained
    conf, _ = confusion_matrix(truths, preds, classes)
    pc = prf_per_class(conf, classes)
    gt_events = [t for u in units if u.label.transition() is not None]
    report: Dict[str, Any] = {
        "n_units": n,
        "n_accepted": n_accepted,
        "n_abstained": n_abstained,
        "abstention_rate": round(abstention_rate(n_abstained, n), 6),
        "accepted_coverage": round(accepted_coverage(n_accepted, n), 6),
        "classes": classes,
        "per_class": pc,
        "macro_f1": round(macro_f1(pc), 6),
        "balanced_accuracy": round(balanced_accuracy(pc), 6),
        "duration_weighted_accuracy": round(duration_weighted_accuracy(units), 6),
        "segment": segment_iou(units),
        "brier": brier_per_head(units),
        "ece_15": ece_15_per_head(units),
        "per_session": per_session_macro_f1(units),
        "n_gt_transitions": len(gt_events),
    }
    return report

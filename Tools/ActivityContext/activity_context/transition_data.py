"""transition-data — raw-IMU transition-expert dataset loaders (typed evidence for the HSMM).

The ActivityContext HSMM stays canonical and authoritative (spec-14 s6-s8, C10); this module
produces the *training supervision* for a small learned raw-IMU transition expert whose outputs
feed the HSMM as typed evidence and can always be overridden by it. The canonical transition
ontology has five classes:

    none, sit_to_stand, stand_to_sit, lie_down, get_up

Every loader returns the SAME in-memory shape (TransitionSession) in canonical units
(accel g, gyro deg/s, float64), so training mixes datasets with placement recorded. Loaders are
deterministic (no RNG, sorted iteration only) and pure — they only read their dataset trees.

Sources and rationale:

* HAPT (50 Hz waist phone, CC BY 4.0): a 12-segment label stream per (experiment, user); labels
  7-12 are explicit transition segments, 1-6 are steady states (none time). One session per
  (experiment, user); event ts is the segment midpoint, onset/offset the segment bounds.
* PAMAP2 (100 Hz wrist IMU, CC BY 4.0): continuous Protocol/subject10X.dat streams with state
  labels lying/sitting/standing; transitions are DERIVED at boundaries between consecutive
  DIFFERENT states, skipping transient (activityID 0) and other-activity rows. The recording is
  split into sessions on timestamp gaps > 1 s. Event ts is the native timestamp of the first
  sample of the new state, minus the session t0.
* WISDM v2 watch (20 Hz, CC BY 4.0): per-subject contiguous activity-letter runs (``Block``s,
  already split on > 1 s gaps by activity_context.wisdm_raw.blocks_for_subject — REUSED here, no
  logic duplication). Only D (sitting) <-> E (standing) boundaries become events. The watch
  version has NO lying letter (the vocabulary is A-S: walking, jogging, stairs, sitting,
  standing, typing, teeth, soup, chips, pasta, drinking, sandwich, kicking, catch, dribbling,
  writing, clapping, folding), so lie_down/get_up cannot be supervised from WISDM. A boundary
  event is attached to the NEW letter's block session at ts = 0: the physical transition
  happened in the unrecorded gap between two ~3-minute blocks, and the first recorded sample of
  the new posture is the best available proxy. Consequently WISDM contributes steady-state
  (none) windows and ambiguous boundary windows, never positive transition windows — the
  positives come from HAPT/PAMAP2 (and FORTH when explicitly opted in).
* FORTH-TRACE (51.2 Hz wrist Shimmer): per-file part{N}dev{1,2}.csv (dev1 = left wrist, dev2 =
  right wrist). Labels 8/10 -> stand_to_sit, 9/11 -> sit_to_stand, 12/13 are stand<->walk
  transitions that are NOT in the ontology and are recorded as EXCLUDED time (never none),
  1-7 -> none. Transition regions are ~7.5 s: event ts = region midpoint, onset/offset = region
  bounds. FORTH-TRACE is citation-only (no open license) and exists for research benchmarking:
  it must NEVER be selected by default in a training CLI — callers opt in explicitly (see
  train_transition --forth / NARA_TRANSITION_DATA).

Window contract (shared with transition_features / train_transition): 4 s windows at a 2 s hop
over native-rate slices. A window is POSITIVE when exactly one transition-event class falls in
the central 50 % of the window, 'none' when no event of any class is within +-3 s AND no
excluded region overlaps, and otherwise ambiguous (None -> training skips it). Windows are
resampled to the canonical 120 @ 30 Hz with preprocess.resample_poly_nd at the exact rational
ratios (50->30: 3/5, 100->30: 3/10, 20->30: 3/2, 51.2->30: 75/128).
"""

from __future__ import annotations

import math
import os
import re
from dataclasses import dataclass, field
from typing import Iterator, List, Optional, Tuple

import numpy as np

from .preprocess import resample_poly_nd
from .wisdm_raw import (SESSION_GAP_NS, WISDM_HZ, Block,
                        blocks_for_subject, parse_raw_file)

# ---------------------------------------------------------------------------
# Canonical ontology and units
# ---------------------------------------------------------------------------

CLASSES: Tuple[str, ...] = ("none", "sit_to_stand", "stand_to_sit", "lie_down", "get_up")
EVENT_KINDS: Tuple[str, ...] = CLASSES[1:]      # the four supervised transition kinds

G = 9.80665                      # standard gravity, m/s^2 per g
M_S2_TO_G = 1.0 / G              # accel m/s^2 -> g
RAD_S_TO_DEG_S = 57.29577951308232   # gyro rad/s -> deg/s (180/pi)

TARGET_HZ = 30.0
WINDOW_SECONDS = 4.0
HOP_SECONDS = 2.0
WINDOW_SAMPLES = 120             # 4 s @ 30 Hz

# Resample ratios (native -> 30 Hz) as exact rationals for preprocess.resample_poly_nd.
_RESAMPLE_RATIOS: Tuple[Tuple[float, int, int], ...] = (
    (50.0, 3, 5),
    (100.0, 3, 10),
    (20.0, 3, 2),
    (51.2, 75, 128),
)


@dataclass
class TransitionEvent:
    """One transition event; ts/onset_ts/offset_ts are seconds relative to the session start."""
    kind: str                       # one of EVENT_KINDS
    ts: float                       # event time (midpoint for region labels, boundary time otherwise)
    onset_ts: float                 # start of the transition region (== ts for instantaneous boundaries)
    offset_ts: float                # end of the transition region (== ts for instantaneous boundaries)
    subject: str
    dataset: str
    placement: str                  # 'wrist' | 'waist' | 'pocket'
    session_id: str


@dataclass
class TransitionSession:
    """One continuous IMU session in canonical units: data is (n, 6) float64, columns
    ax, ay, az [g], gx, gy, gz [deg/s]."""
    subject: str
    dataset: str
    placement: str                  # 'wrist' | 'waist' | 'pocket'
    session_id: str
    hz: float                       # native sampling rate of ``data``
    t0_ts: float                    # native timestamp of the first sample, in seconds
    data: np.ndarray                # (n, 6) float64
    events: List[TransitionEvent] = field(default_factory=list)
    excluded: Tuple[Tuple[float, float], ...] = ()   # excluded-time regions (start, end), seconds


# ---------------------------------------------------------------------------
# HAPT (50 Hz waist phone; labels are explicit transition segments)
# ---------------------------------------------------------------------------

HAPT_HZ = 50.0
# activity_labels.txt: 7 STAND_TO_SIT, 8 SIT_TO_STAND, 9 SIT_TO_LIE, 10 LIE_TO_SIT,
# 11 STAND_TO_LIE, 12 LIE_TO_STAND; labels 1-6 are steady states (none time).
HAPT_TRANSITION_LABELS = {
    7: "stand_to_sit",
    8: "sit_to_stand",
    9: "lie_down",
    10: "get_up",
    11: "lie_down",
    12: "get_up",
}


def load_hapt(root: str) -> List[TransitionSession]:
    """Load HAPT (root .../hapt with RawData/). 50 Hz waist phone, one session per (experiment, user)."""
    raw = os.path.join(root, "RawData")
    label_rows: List[Tuple[int, int, int, int, int]] = []
    with open(os.path.join(raw, "labels.txt"), "r", encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) == 5:
                label_rows.append(tuple(int(p) for p in parts))  # type: ignore[arg-type]
    sessions: List[TransitionSession] = []
    for exp, user in sorted({(r[0], r[1]) for r in label_rows}):
        acc = np.loadtxt(os.path.join(raw, f"acc_exp{exp:02d}_user{user:02d}.txt"))
        gyr = np.loadtxt(os.path.join(raw, f"gyro_exp{exp:02d}_user{user:02d}.txt"))
        if acc.ndim != 2 or gyr.ndim != 2 or acc.shape != gyr.shape:
            raise ValueError(f"HAPT exp{exp:02d} user{user:02d}: acc {acc.shape} != gyro {gyr.shape}")
        data = np.concatenate([acc, gyr * RAD_S_TO_DEG_S], axis=1).astype(np.float64)  # acc g; HAPT gyro is rad/s
        events = []
        for e, u, label, start, end in label_rows:
            if (e, u) != (exp, user):
                continue
            kind = HAPT_TRANSITION_LABELS.get(label)
            if kind is None:
                continue                                            # labels 1-6: none time
            events.append(TransitionEvent(
                kind=kind,
                ts=(start + end) / 2.0 / HAPT_HZ,                   # segment midpoint
                onset_ts=start / HAPT_HZ,
                offset_ts=end / HAPT_HZ,
                subject=f"user{user}", dataset="hapt", placement="waist",
                session_id=f"exp{exp:02d}"))
        events.sort(key=lambda ev: (ev.ts, ev.kind))
        sessions.append(TransitionSession(
            subject=f"user{user}", dataset="hapt", placement="waist",
            session_id=f"exp{exp:02d}", hz=HAPT_HZ, t0_ts=0.0, data=data, events=events))
    return sessions


# ---------------------------------------------------------------------------
# PAMAP2 (100 Hz wrist IMU; transitions derived at state-label boundaries)
# ---------------------------------------------------------------------------

PAMAP_HZ = 100.0
PAMAP_GAP_S = 1.0
_PAMAP_STATES = frozenset({1, 2, 3})          # 1 lying, 2 sitting, 3 standing
_PAMAP_TRANSITIONS = {
    (1, 2): "get_up",       # lying -> sitting
    (1, 3): "get_up",       # lying -> standing
    (2, 1): "lie_down",     # sitting -> lying
    (3, 1): "lie_down",     # standing -> lying
    (2, 3): "sit_to_stand",
    (3, 2): "stand_to_sit",
}


def _read_pamap_rows(path: str) -> List[Tuple[float, int, Optional[List[float]]]]:
    """Parse one Protocol/subject10X.dat into (ts_s, activity_id, hand6|None) rows.

    Hand-IMU block: columns 4-6 hand accel 16g (m/s^2) -> g, columns 10-12 hand gyro (rad/s) ->
    deg/s (0-based indexes). Rows with a NaN in the hand block yield None sensors (dropped from
    the data array); a NaN activity id is treated as 0 (transient), and rows with a NaN
    timestamp are skipped. At least 13 columns are required.
    """
    out: List[Tuple[float, int, Optional[List[float]]]] = []
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            parts = line.split()
            if len(parts) < 13:
                continue
            try:
                vals = [float(p) for p in parts[:13]]
            except ValueError:
                continue
            ts = vals[0]
            if math.isnan(ts):
                continue
            act = vals[1]
            act = 0 if math.isnan(act) else int(act)
            hand = vals[4:7] + vals[10:13]
            if any(math.isnan(v) for v in hand):
                hand6 = None
            else:
                hand6 = [hand[0] * M_S2_TO_G, hand[1] * M_S2_TO_G, hand[2] * M_S2_TO_G,
                         hand[3] * RAD_S_TO_DEG_S, hand[4] * RAD_S_TO_DEG_S,
                         hand[5] * RAD_S_TO_DEG_S]
            out.append((ts, act, hand6))
    return out


def _pamap_events(rows: List[Tuple[float, int, Optional[List[float]]]],
                  t0: float, subject: str, session_id: str) -> List[TransitionEvent]:
    """Derive events at boundaries between consecutive DIFFERENT state labels, skipping
    intervening transient (0) and other-activity rows."""
    events: List[TransitionEvent] = []
    prev: Optional[int] = None
    for ts, act, _hand in rows:
        if act not in _PAMAP_STATES:
            continue
        if prev is not None and act != prev:
            t = ts - t0
            events.append(TransitionEvent(
                kind=_PAMAP_TRANSITIONS[(prev, act)], ts=t, onset_ts=t, offset_ts=t,
                subject=subject, dataset="pamap2", placement="wrist", session_id=session_id))
        prev = act
    return events


def load_pamap2(root: str) -> List[TransitionSession]:
    """Load PAMAP2 (root .../PAMAP2_Dataset with Protocol/). 100 Hz wrist IMU; one or more
    sessions per subject, split on timestamp gaps > 1 s."""
    proto = os.path.join(root, "Protocol")
    sessions: List[TransitionSession] = []
    for fn in sorted(f for f in os.listdir(proto) if re.fullmatch(r"subject\d+\.dat", f)):
        subject = fn[:-4]
        rows = _read_pamap_rows(os.path.join(proto, fn))
        i, gap_idx = 0, 0
        while i < len(rows):
            j = i + 1
            while j < len(rows) and rows[j][0] - rows[j - 1][0] <= PAMAP_GAP_S:
                j += 1
            sub = rows[i:j]
            i = j
            data = np.array([r[2] for r in sub if r[2] is not None], dtype=np.float64)
            if data.shape[0] == 0:
                continue
            t0 = sub[0][0]
            session_id = f"{subject}-{gap_idx}"
            events = _pamap_events(sub, t0, subject, session_id)
            sessions.append(TransitionSession(
                subject=subject, dataset="pamap2", placement="wrist",
                session_id=session_id, hz=PAMAP_HZ, t0_ts=t0, data=data, events=events))
            gap_idx += 1
    return sessions


# ---------------------------------------------------------------------------
# WISDM v2 watch (20 Hz; D sitting <-> E standing boundary events at block starts)
# ---------------------------------------------------------------------------

_WISDM_BOUNDARY_EVENTS = {("D", "E"): "sit_to_stand", ("E", "D"): "stand_to_sit"}


def _wisdm_block_starts(ts_sec: np.ndarray, acts: List[str]) -> List[int]:
    """First sample index of each activity block, using the SAME boundary rule as
    wisdm_raw.blocks_for_subject (activity change OR timestamp gap > 1 s). This is index
    bookkeeping only — the block samples themselves come from blocks_for_subject (reused, not
    duplicated); a length mismatch with blocks_for_subject raises loudly instead of misaligning.
    """
    starts: List[int] = []
    prev_act: Optional[str] = None
    prev_ts: Optional[float] = None
    for i, (t, a) in enumerate(zip(ts_sec, acts)):
        if prev_act is None or a != prev_act or (
                prev_ts is not None and t - prev_ts > SESSION_GAP_NS / 1e9):
            starts.append(i)
        prev_act, prev_ts = a, t
    return starts


def load_wisdm(root: str) -> List[TransitionSession]:
    """Load WISDM v2 watch (root .../wisdm-dataset/raw/watch). 20 Hz; one session per
    activity block; D->E / E->D boundary events are attached to the NEW letter's block at
    ts = 0 (the watch set has no lying letter)."""
    watch = os.path.join(root, "raw", "watch")
    accel_dir = os.path.join(watch, "accel")
    gyro_dir = os.path.join(watch, "gyro")
    sessions: List[TransitionSession] = []
    for accel_fn in sorted(f for f in os.listdir(accel_dir) if f.endswith(".txt")):
        m = re.fullmatch(r"data_(\d+)_accel_watch\.txt", accel_fn)
        if not m:
            continue
        subject = m.group(1)
        accel_path = os.path.join(accel_dir, accel_fn)
        gyro_path = os.path.join(gyro_dir, f"data_{subject}_gyro_watch.txt")
        if not os.path.exists(gyro_path):
            raise ValueError(f"WISDM subject {subject}: missing {os.path.basename(gyro_path)}")
        acc = parse_raw_file(accel_path)                      # reused helper (wisdm_raw.py)
        ts_sec = np.array([int(r[2]) for r in acc], dtype=np.float64) / 1e9
        acts = [str(r[1]) for r in acc]
        starts = _wisdm_block_starts(ts_sec, acts)
        blocks: List[Block] = blocks_for_subject(accel_path, gyro_path)  # reused helper (wisdm_raw.py)
        if len(starts) != len(blocks):
            raise ValueError(
                f"WISDM subject {subject}: block bookkeeping mismatch "
                f"({len(starts)} starts vs {len(blocks)} blocks)")
        for i, block in enumerate(blocks):
            events: List[TransitionEvent] = []
            if i > 0:
                kind = _WISDM_BOUNDARY_EVENTS.get((blocks[i - 1].activity, block.activity))
                if kind is not None:
                    events.append(TransitionEvent(
                        kind=kind, ts=0.0, onset_ts=0.0, offset_ts=0.0,
                        subject=subject, dataset="wisdm", placement="wrist",
                        session_id=f"{subject}-{i}"))
            sessions.append(TransitionSession(
                subject=subject, dataset="wisdm", placement="wrist",
                session_id=f"{subject}-{i}", hz=WISDM_HZ,
                t0_ts=float(ts_sec[starts[i]]), data=block.samples, events=events))
    return sessions


# ---------------------------------------------------------------------------
# FORTH-TRACE (51.2 Hz wrist Shimmer; region labels, research benchmarking only)
# ---------------------------------------------------------------------------

FORTH_HZ = 51.2
_FORTH_LABEL_KIND = {8: "stand_to_sit", 9: "sit_to_stand",
                     10: "stand_to_sit", 11: "sit_to_stand"}
_FORTH_EXCLUDED_LABELS = frozenset({12, 13})     # stand<->walk transitions: excluded time


def _read_forth_csv(path: str) -> List[List[float]]:
    """Parse one part{N}dev{M}.csv (device_id, ax, ay, az, gx, gy, gz, mx, my, mz, timestamp,
    label). Rows that do not parse as 12 floats (header/stray lines) are skipped; rows are
    sorted deterministically by (timestamp, device_id). Timestamps are interpreted as seconds."""
    rows: List[List[float]] = []
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            parts = line.strip().split(",")
            if len(parts) < 12:
                continue
            try:
                vals = [float(p) for p in parts[:12]]
            except ValueError:
                continue
            rows.append(vals)
    rows.sort(key=lambda r: (r[10], r[0]))
    return rows


def _forth_sample_delta(rows: List[List[float]]) -> float:
    """Median consecutive-row timestamp delta (seconds); used to close the final region.

    Timestamps are milliseconds (see load_forth_trace), so the median delta is scaled to
    seconds here once, keeping every consumer in the session's seconds domain.
    """
    d = [rows[k + 1][10] - rows[k][10] for k in range(len(rows) - 1)
         if rows[k + 1][10] > rows[k][10]]
    if not d:
        return 1.0 / FORTH_HZ
    return float(np.median(np.asarray(d, dtype=np.float64))) / 1000.0


def load_forth_trace(root: str) -> List[TransitionSession]:
    """Load FORTH-TRACE (root .../forth with part0/..part14/). 51.2 Hz wrist Shimmer; dev1
    (left wrist) and dev2 (right wrist) only, one session per file. FORTH-TRACE license:
    CC BY-SA 4.0 (Zenodo DOI 10.5281/zenodo.841301, verified from the record); it is loaded
    only when a caller passes it explicitly (like every dataset: never default-loaded)."""
    sessions: List[TransitionSession] = []
    for part_dir in sorted(d for d in os.listdir(root) if re.fullmatch(r"part\d+", d)):
        part_num = int(part_dir[4:])
        for dev in (1, 2):
            path = os.path.join(root, part_dir, f"part{part_num}dev{dev}.csv")
            if not os.path.exists(path):
                continue
            rows = _read_forth_csv(path)
            if not rows:
                continue
            # Subject is the PARTICIPANT (partX), not the device: left/right wrist are two
            # sessions of the same person and MUST share a split or participant-held-out
            # evaluation leaks (spec s12: never split one participant across train/test).
            subject = f"part{part_num}"
            # FORTH timestamps are MILLISECONDS (verified empirically on the real corpus:
            # successive rows step by ~20 = 1000/51.2, and ~53k-row sessions end at ~1.04e6 —
            # ms, i.e. a ~17 min session; the README does not state the unit).
            t0 = rows[0][10] / 1000.0
            data = np.array([[r[1] * M_S2_TO_G, r[2] * M_S2_TO_G, r[3] * M_S2_TO_G,
                              r[4], r[5], r[6]] for r in rows], dtype=np.float64)
            delta = _forth_sample_delta(rows)
            events: List[TransitionEvent] = []
            excluded: List[Tuple[float, float]] = []
            i, n = 0, len(rows)
            while i < n:
                label = int(rows[i][11])
                j = i + 1
                while j < n and int(rows[j][11]) == label:
                    j += 1
                onset = rows[i][10] / 1000.0 - t0
                offset = (rows[j][10] / 1000.0 - t0) if j < n else (rows[-1][10] / 1000.0 - t0 + delta)
                kind = _FORTH_LABEL_KIND.get(label)
                if kind is not None:
                    events.append(TransitionEvent(
                        kind=kind, ts=(onset + offset) / 2.0, onset_ts=onset, offset_ts=offset,
                        subject=subject, dataset="forth", placement="wrist",
                        session_id=f"part{part_num}dev{dev}"))
                elif label in _FORTH_EXCLUDED_LABELS:
                    excluded.append((onset, offset))
                i = j
            events.sort(key=lambda ev: (ev.ts, ev.kind))
            sessions.append(TransitionSession(
                subject=subject, dataset="forth", placement="wrist", session_id=f"part{part_num}dev{dev}",
                hz=FORTH_HZ, t0_ts=t0, data=data, events=events, excluded=tuple(excluded)))
    return sessions


# ---------------------------------------------------------------------------
# Windowing
# ---------------------------------------------------------------------------

def _window_label(session: TransitionSession, start: float, end: float,
                  window_s: float) -> Optional[str]:
    """Label one window: class c when exactly one class-c event lies in the central 50 % of the
    window; 'none' when no event of any class is within +-3 s and no excluded region overlaps;
    else None (ambiguous)."""
    inner_lo = start + 0.25 * window_s
    inner_hi = end - 0.25 * window_s
    outer_lo = start - 3.0
    outer_hi = end + 3.0
    inner_kind: Optional[str] = None
    inner_multi = False
    outer_seen = False
    for ev in session.events:
        if inner_lo <= ev.ts <= inner_hi:
            if inner_kind is None:
                inner_kind = ev.kind
            elif inner_kind != ev.kind:
                inner_multi = True
        if outer_lo <= ev.ts <= outer_hi:
            outer_seen = True
    if inner_kind is not None and not inner_multi:
        return inner_kind
    if outer_seen:
        return None
    for r0, r1 in session.excluded:
        if r0 < end and r1 > start:
            return None
    return "none"


def iter_windows(session: TransitionSession, window_s: float = WINDOW_SECONDS,
                 hop_s: float = HOP_SECONDS
                 ) -> Iterator[Tuple[float, float, np.ndarray, Optional[str]]]:
    """Yield (start_ts, end_ts, native-rate data slice, label) windows for one session.

    Window boundaries are relative to the session start and clipped to the session bounds
    (duration = len(data) / hz). Label semantics are documented on _window_label; ambiguous
    (None) windows are still yielded and the caller decides whether to skip them for training.
    Windows with fewer than 4 native samples (degenerate trailing fragments) are not yielded.
    The data slice is a view into session.data — callers must not mutate it.
    """
    n = session.data.shape[0]
    hz = float(session.hz)
    if n == 0 or hz <= 0 or window_s <= 0 or hop_s <= 0:
        return
    duration = n / hz
    t = 0.0
    while t < duration - 1e-9:
        end = min(t + window_s, duration)
        i0 = max(0, int(math.floor(t * hz)))
        i1 = min(n, int(math.ceil(end * hz)))
        # Windows with fewer than 4 native samples are degenerate trailing fragments with no
        # usable content; they are not yielded (the shared feature contract needs >= 4 samples).
        if i1 - i0 >= 4:
            yield (t, end, session.data[i0:i1], _window_label(session, t, end, window_s))
        t += hop_s


def resample_window_to_30hz(data: np.ndarray, hz: float) -> np.ndarray:
    """Resample one native-rate window to the canonical 120 @ 30 Hz float64 (n, 6).

    Uses preprocess.resample_poly_nd at the exact rational ratios (50->30: 3/5, 100->30: 3/10,
    20->30: 3/2, 51.2->30: 75/128). When the resampled length is not exactly 120, the center
    crop/pad rule is applied deterministically: longer signals are center-cropped, shorter ones
    zero-padded evenly (extra zero on the right when the pad is odd).
    """
    data = np.asarray(data, dtype=np.float64)
    if data.ndim != 2 or data.shape[1] != 6:
        raise ValueError(f"window must be (n, 6), got {data.shape}")
    if data.shape[0] == 0:
        raise ValueError("cannot resample an empty window")
    ratio = None
    for rate, up, down in _RESAMPLE_RATIOS:
        if abs(hz - rate) < 1e-9:
            ratio = (up, down)
            break
    if ratio is None:
        raise ValueError(f"unsupported native rate {hz!r}; supported: "
                         f"{sorted(rate for rate, _, _ in _RESAMPLE_RATIOS)}")
    up, down = ratio
    resampled = resample_poly_nd(data, up, down, axis=0)
    m = resampled.shape[0]
    if m == WINDOW_SAMPLES:
        return resampled
    if m > WINDOW_SAMPLES:
        start = (m - WINDOW_SAMPLES) // 2
        return resampled[start:start + WINDOW_SAMPLES]
    pad_total = WINDOW_SAMPLES - m
    left = pad_total // 2
    right = pad_total - left
    return np.pad(resampled, ((left, right), (0, 0)), mode="constant")

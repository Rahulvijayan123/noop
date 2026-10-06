"""WISDM-2019 watch loader for HART training and evaluation (``wisdm-watch-loader-2``).

Replaces the v0 accel/gyro merge in ``train.py``, which had two bugs:

* it ``np.searchsorted``-ed every accel timestamp into the subject's WHOLE gyro timestamp array, which
  is not sorted (WISDM timestamps jump at every activity change), and wrote 0 into every unmatched
  sample. 82 % of v0's train windows and 83 % of its eval windows carry all-zero gyro.
* it assumed every block is 20 Hz and always resampled 3/2. Subjects 1637-1640 record ~49.7 Hz accel
  and ~24.8 Hz gyro (their blocks were time-stretched 2.5x), and about 20 blocks of other subjects
  switch between 20 Hz and ~100 Hz in the middle of the block.

Pipeline, per subject file pair (``raw/watch/{accel,gyro}/data_<subject>_<sensor>_watch.txt``):

1. Parse the rows. Rows whose subject field is not the file's subject are dropped and counted.
2. Group the rows by activity letter and sort each sensor stream by timestamp. Exact duplicate rows
   (same timestamp, same xyz; subject 1629's files hold the whole session twice) are collapsed.
   Conflicting duplicates (same timestamp, different xyz) are dropped and counted.
3. Recordings: a gap of more than 1 s starts a new recording (train.py's session rule).
4. Constant-rate segments. Each interval gets a nominal rate (20/25/50/100 Hz) from the rolling median
   of 11 intervals. A segment ends where the nominal rate changes, or at an interval shorter than 0.5
   or longer than 2.5 nominal periods. A long-then-short pair that sums to about 2 periods is delivery
   jitter and is left alone. An interval of 1.5-2.5 periods followed by a normal one is exactly ONE
   missing sample. What happens to it is the named, versioned loader option ``repair``
   (:data:`REPAIR_POLICIES`): the default ``wisdm-single-dropout-linear-1`` inserts the linear interpolation
   of its two neighbours (counted; never a zero); ``none`` ends the segment there instead. Every repaired
   sample is tracked to the 30 Hz output (``Piece.repaired_pos``) so each window records how many repaired
   samples it contains (:func:`window_repair_counts`; ``train.py`` writes ``n_repaired`` per window into the
   npz files, audit G2 E-1). Segments shorter than ``MIN_SEGMENT_S`` cannot hold a window and are dropped
   (counted).
5. Clock per segment: least-squares fit ``t_i = a + i / r`` over the (repaired, uniform) sample index.
   This gives the measured rate ``r`` and the fitted time of every sample, robust to the 2-20 ms
   delivery jitter of the 1637-1640 watches.
6. Each stream segment is resampled from its own measured rate to 30 Hz with the repo's polyphase
   design (``preprocess._design_resample_filter``: Kaiser beta=5 windowed sinc, 20*max(up,down)+1 taps,
   the same design as scipy.signal.resample_poly). ``up/down`` is the simplest fraction approximating
   ``30 / r`` whose accumulated time error over the segment is at most ``MAX_RATE_DRIFT_S``
   (``Fraction.limit_denominator`` with a doubling bound; e.g. 20.015 Hz -> 670/447). The gyro ratio
   is derived from the accel ratio (step 7).
   ``resample_poly_direct`` computes only the output samples that are kept, which makes large ratios
   cheap. It equals ``preprocess.resample_poly_nd`` to ~1e-15 (tests/test_wisdm.py).
7. Alignment on a common 30 Hz time base. WISDM's gyro shares the accel clock: its timestamps equal the
   accel's at 20/100 Hz, and at 50/25 Hz every gyro instant is every other accel instant. For each
   overlapping (accel segment, gyro segment) pair, every gyro sample is located on the accel sample
   index through the accel timestamps; gyro j sits at accel index c + j*k (k = nominal ratio, checked
   against the measured rates). Where the rolling-median level c jumps (one stream lost or gained a
   sample the other did not: the 1638-1640 watches do this a few times per block), the pair is split.
   Each consistent stretch starts at the first gyro sample within ``ALIGN_TOL_S`` of an accel sample.
   The accel ratio approximates 30 / (measured accel rate); the gyro ratio is that ratio times k. Output
   sample m of both streams then lies at the same instant t0 + m/30 s (to within the rational-
   approximation error, <= 2 ms over the piece, and the constant sub-sample offset, <= ``ALIGN_TOL_S``;
   both are recorded per piece).
8. Nothing is zero-filled. Accel time without gyro (or gyro without accel) produces no samples, so no
   windows. Recordings with no gyro at all are excluded and reported.

Units: accel m/s^2 -> g (/9.80665), gyro rad/s -> deg/s (x180/pi), applied before resampling. Windows
follow serve.py exactly (``window_starts``): 4 s / 2 s grid anchored at the piece start, the first
window starting at the first hop multiple that clears the 1 s FIR-transient margin, and the last one
ending at least 1 s before the piece end.

Pure numpy. Deterministic. No I/O apart from reading the raw files.
"""

from __future__ import annotations

import math
import os
from dataclasses import dataclass, field
from fractions import Fraction
from typing import Any, Dict, List, Optional, Sequence, Tuple

import numpy as np

from .preprocess import (HOP_SAMPLES, N_CHANNELS, TARGET_HZ, TRANSIENT_MARGIN_SECONDS,
                         WINDOW_SAMPLES, _design_resample_filter)

LOADER_VERSION = "wisdm-watch-loader-2"

# Single-dropout repair (a named, versioned loader option; recorded in the HART manifest and data_report.json).
REPAIR_POLICIES: Dict[str, str] = {
    "wisdm-single-dropout-linear-1": "an interval of 1.5-2.5 nominal periods followed by a normal one is ONE missing "
                                     "sample: it is inserted as the linear interpolation of its two neighbours "
                                     "(timestamp = their midpoint); every window records how many it contains",
    "none": "no repair: such an interval ends the constant-rate segment like any other irregular interval",
}
DEFAULT_REPAIR = "wisdm-single-dropout-linear-1"


def check_repair(repair: str) -> str:
    if repair not in REPAIR_POLICIES:
        raise ValueError(f"repair must be one of {sorted(REPAIR_POLICIES)}, got {repair!r}")
    return repair

M_S2_TO_G = 1.0 / 9.80665
RAD_S_TO_DEG_S = 180.0 / math.pi

NOMINAL_RATES_HZ: Tuple[int, ...] = (20, 25, 50, 100)
RATE_SNAP_TOL = 0.10            # rolling-median rate must be within 10 % of a nominal rate
ROLLING_INTERVALS = 11          # rolling-median width (intervals) for the per-interval nominal rate
RECORDING_GAP_S = 1.0           # > 1 s gap starts a new recording (train.py's session rule)
SPLIT_SHORT = 0.5               # interval < 0.5 nominal periods -> segment break
SPLIT_LONG = 2.5                # interval > 2.5 nominal periods -> segment break (>= 2 samples missing)
REPAIR_LONG = 1.5               # 1.5 < interval <= 2.5 periods, next interval normal -> one sample missing
MIN_SEGMENT_S = 6.0             # one 4 s window + 1 s transient margin at each side
MAX_RATE_DRIFT_S = 0.002        # rational up/down: accumulated time error over a segment <= 2 ms
MAX_RATIO_DENOMINATOR = 1 << 15
ALIGN_TOL_S = 0.010             # accel/gyro offset on the common 30 Hz time base (start and end)
MARGIN_SAMPLES = int(round(TRANSIENT_MARGIN_SECONDS * TARGET_HZ))   # 30


# ---------------------------------------------------------------------------
# Parsing
# ---------------------------------------------------------------------------

@dataclass
class RawStream:
    """All rows of one WISDM raw file, in file order."""
    subject: int
    activity: np.ndarray        # (N,) str
    ts_ns: np.ndarray           # (N,) int64
    xyz: np.ndarray             # (N, 3) float64, native units
    n_unparsed: int = 0
    n_wrong_subject: int = 0


def parse_raw(path: str, subject: int) -> RawStream:
    """Parse ``subject,activity,timestamp_ns,x,y,z;`` rows. Rows of another subject are dropped (counted)."""
    acts: List[str] = []
    ts: List[int] = []
    xyz: List[Tuple[float, float, float]] = []
    bad = wrong = 0
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip().rstrip(";").strip()
            if not line:
                continue
            p = line.split(",")
            if len(p) != 6:
                bad += 1
                continue
            try:
                s = int(p[0])
                t = int(p[2])
                v = (float(p[3]), float(p[4]), float(p[5]))
            except ValueError:
                bad += 1
                continue
            if not all(math.isfinite(c) for c in v):
                bad += 1
                continue
            if s != subject:
                wrong += 1
                continue
            acts.append(p[1].strip())
            ts.append(t)
            xyz.append(v)
    return RawStream(subject=subject, activity=np.asarray(acts, dtype=str),
                     ts_ns=np.asarray(ts, dtype=np.int64),
                     xyz=np.asarray(xyz, dtype=np.float64).reshape(-1, 3),
                     n_unparsed=bad, n_wrong_subject=wrong)


def sorted_unique(ts_ns: np.ndarray, xyz: np.ndarray) -> Tuple[np.ndarray, np.ndarray, int, int]:
    """Sort by timestamp; collapse exact duplicates; drop conflicting duplicates.

    Returns (ts, xyz, n_exact_duplicates_removed, n_conflicting_rows_dropped).
    """
    if ts_ns.size == 0:
        return ts_ns.copy(), xyz.copy(), 0, 0
    order = np.lexsort((xyz[:, 2], xyz[:, 1], xyz[:, 0], ts_ns))
    t = ts_ns[order]
    v = xyz[order]
    same_ts = np.r_[False, t[1:] == t[:-1]]
    same_row = same_ts & np.r_[False, np.all(v[1:] == v[:-1], axis=1)]
    keep = ~same_row                             # drop exact repeats of the previous row
    t, v = t[keep], v[keep]
    n_exact = int(same_row.sum())
    # any timestamp still repeated now carries different values -> drop every row at that timestamp
    dup = np.r_[t[1:] == t[:-1], False] | np.r_[False, t[1:] == t[:-1]]
    n_conflict = int(dup.sum())
    return t[~dup], v[~dup], n_exact, n_conflict


# ---------------------------------------------------------------------------
# Constant-rate segments
# ---------------------------------------------------------------------------

@dataclass
class Segment:
    """A uniform-rate stretch of one sensor stream (after the single-dropout repair)."""
    ts_ns: np.ndarray           # (n,) int64; repaired samples carry the midpoint timestamp
    x: np.ndarray               # (n, 3) float64, canonical units
    nominal_hz: int
    rate_hz: float              # least-squares measured rate
    a_s: float                  # fitted time of sample 0, seconds relative to ``ref_ns``
    ref_ns: int                 # time reference (first raw timestamp of the segment)
    max_resid_s: float
    n_repaired: int = 0
    repaired_index: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.int64))  # inserted samples

    @property
    def n(self) -> int:
        return int(self.ts_ns.shape[0])

    def t_fit(self, i) -> np.ndarray:
        """Fitted time (seconds relative to ``ref_ns``) of sample index i."""
        return self.a_s + np.asarray(i, dtype=np.float64) / self.rate_hz

    @property
    def start_abs_s(self) -> float:
        return self.ref_ns / 1e9 + self.a_s

    @property
    def end_abs_s(self) -> float:
        return self.ref_ns / 1e9 + float(self.t_fit(self.n - 1))

    @property
    def duration_s(self) -> float:
        return (self.n - 1) / self.rate_hz


def _rolling_median(x: np.ndarray, width: int) -> np.ndarray:
    from numpy.lib.stride_tricks import sliding_window_view
    if x.size == 0:
        return x.copy()
    h = width // 2
    if x.size <= h:
        return np.full_like(x, np.median(x))
    pad = np.pad(x, (h, h), mode="reflect")         # edge values do not get h+1 votes
    return np.median(sliding_window_view(pad, width), axis=1)


def _snap_nominal(rate: np.ndarray) -> np.ndarray:
    """Nearest nominal rate per element (0 = no nominal rate within RATE_SNAP_TOL)."""
    noms = np.asarray(NOMINAL_RATES_HZ, dtype=np.float64)
    with np.errstate(divide="ignore", invalid="ignore"):
        idx = np.argmin(np.abs(rate[:, None] - noms[None, :]), axis=1)
        best = noms[idx]
        ok = np.abs(rate - best) <= RATE_SNAP_TOL * best
    return np.where(ok, best, 0.0).astype(np.int64)


def fit_clock(ts_ns: np.ndarray) -> Tuple[float, float, int, float]:
    """Least-squares ``t_i = a + i / r``. Returns (a_s rel. ref, rate_hz, ref_ns, max |residual| s)."""
    ref = int(ts_ns[0])
    t = (ts_ns.astype(np.int64) - ref).astype(np.float64) / 1e9
    i = np.arange(t.size, dtype=np.float64)
    im, tm = i.mean(), t.mean()
    slope = float(np.sum((i - im) * (t - tm)) / np.sum((i - im) ** 2))
    a = tm - slope * im
    resid = float(np.max(np.abs(t - (a + slope * i))))
    return float(a), 1.0 / slope, ref, resid


@dataclass
class StreamStats:
    n_rows: int = 0
    n_exact_duplicates: int = 0
    n_conflicting_dropped: int = 0
    n_repaired: int = 0
    n_breaks: int = 0
    n_short_segment_samples: int = 0
    n_unknown_rate_samples: int = 0

    def add(self, other: "StreamStats") -> None:
        for k in self.__dataclass_fields__:
            setattr(self, k, getattr(self, k) + getattr(other, k))


def constant_rate_segments(ts_ns: np.ndarray, x: np.ndarray,
                           stats: Optional[StreamStats] = None, repair: str = DEFAULT_REPAIR) -> List[Segment]:
    """Split ONE sorted, de-duplicated recording into uniform-rate segments (see module doc, step 4).

    ``repair`` (:data:`REPAIR_POLICIES`): what a single missing sample does — interpolated (default) or a
    segment break (``none``)."""
    policy_none = check_repair(repair) == "none"
    st = stats if stats is not None else StreamStats()
    n = ts_ns.size
    if n < 3:
        st.n_short_segment_samples += n
        return []
    dt = np.diff(ts_ns).astype(np.float64) / 1e9                       # > 0 (sorted, unique)
    nom = _snap_nominal(1.0 / _rolling_median(dt, ROLLING_INTERVALS))  # per interval
    with np.errstate(divide="ignore", invalid="ignore"):
        r = np.where(nom > 0, dt * nom, np.inf)                        # interval in nominal periods
    m = r.size
    jitter = np.zeros(m, dtype=bool)                                   # long+short pair summing to ~2
    near2 = np.abs(r[:-1] + r[1:] - 2.0) < 0.5
    pair = near2 & (((r[:-1] > REPAIR_LONG) & (r[1:] < SPLIT_SHORT))
                    | ((r[:-1] < SPLIT_SHORT) & (r[1:] > REPAIR_LONG)))
    jitter[:-1] |= pair
    jitter[1:] |= pair
    brk = np.zeros(m, dtype=bool)                                      # break AFTER sample i
    brk |= (nom == 0)
    brk[1:] |= nom[1:] != nom[:-1]
    nxt_ok = np.r_[r[1:] >= SPLIT_SHORT, True]
    rep_mask = (~jitter) & (r > REPAIR_LONG) & (r <= SPLIT_LONG) & nxt_ok & (nom > 0)
    brk |= (~jitter) & ((r < SPLIT_SHORT) | (r > SPLIT_LONG))
    brk |= (~jitter) & (r > REPAIR_LONG) & (r <= SPLIT_LONG) & ~nxt_ok
    rep_mask &= ~brk
    if policy_none:
        brk |= rep_mask                                                # "none": the dropout ends the segment
        rep_mask = np.zeros_like(rep_mask)
    st.n_breaks += int(brk.sum())
    st.n_unknown_rate_samples += int(np.sum(nom == 0))

    out: List[Segment] = []
    cuts = np.flatnonzero(brk) + 1
    starts = np.r_[0, cuts]
    ends = np.r_[cuts, n]
    for s, e in zip(starts, ends):
        if e - s < 3:
            st.n_short_segment_samples += int(e - s)
            continue
        seg_nom = int(np.bincount(nom[s:e - 1]).argmax()) if e - s > 1 else 0
        if seg_nom == 0:
            st.n_short_segment_samples += int(e - s)
            continue
        t_seg = ts_ns[s:e]
        x_seg = x[s:e]
        rep = np.flatnonzero(rep_mask[s:e - 1])                          # interval k: between k and k+1
        if rep.size:
            ins_t = (t_seg[rep] + t_seg[rep + 1]) // 2
            ins_x = 0.5 * (x_seg[rep] + x_seg[rep + 1])
            t_seg = np.insert(t_seg, rep + 1, ins_t)
            x_seg = np.insert(x_seg, rep + 1, ins_x, axis=0)
        rep_idx = (rep + 1 + np.arange(rep.size)).astype(np.int64)   # positions of the inserted samples
        dur = (t_seg[-1] - t_seg[0]) / 1e9
        if dur < MIN_SEGMENT_S:
            st.n_short_segment_samples += int(e - s)
            continue
        st.n_repaired += int(rep.size)
        a, rate, ref, resid = fit_clock(t_seg)
        out.append(Segment(ts_ns=t_seg, x=x_seg, nominal_hz=seg_nom, rate_hz=rate, a_s=a, ref_ns=ref,
                           max_resid_s=resid, n_repaired=int(rep.size), repaired_index=rep_idx))
    return out


def recordings(ts_ns: np.ndarray, gap_s: float = RECORDING_GAP_S) -> List[Tuple[int, int]]:
    """[start, end) index ranges of a sorted stream split at gaps > ``gap_s``."""
    if ts_ns.size == 0:
        return []
    cut = np.flatnonzero(np.diff(ts_ns) > int(gap_s * 1e9)) + 1
    return list(zip(np.r_[0, cut].tolist(), np.r_[cut, ts_ns.size].tolist()))


# ---------------------------------------------------------------------------
# Resampling: exact rational approximation of the measured rate
# ---------------------------------------------------------------------------

def rational_ratio(rate_hz: float, duration_s: float, target_hz: int = TARGET_HZ,
                   max_drift_s: float = MAX_RATE_DRIFT_S,
                   max_den: int = MAX_RATIO_DENOMINATOR) -> Tuple[int, int, float]:
    """Simplest up/down ~= target/rate whose accumulated time error over ``duration_s`` is <= max_drift_s.

    Returns (up, down, relative error). The relative error eps scales time: after resampling, output
    sample k sits at k/target * (1 + eps) seconds. The doubling ``limit_denominator`` search returns
    3/2 for an exact 20 Hz stream, 6/5 for 25 Hz, 3/5 for 50 Hz and 3/10 for 100 Hz.
    """
    if not (rate_hz > 0 and math.isfinite(rate_hz)):
        raise ValueError(f"invalid rate {rate_hz!r}")
    exact = Fraction(target_hz) / Fraction(rate_hz)
    want = float(exact)
    den = 1
    best = None
    while den <= max_den:
        f = exact.limit_denominator(den)
        eps = (float(f) - want) / want
        best = (f.numerator, f.denominator, eps)
        if abs(eps) * max(duration_s, 1e-9) <= max_drift_s:
            return best
        den *= 2
    assert best is not None
    return best


def resample_poly_direct(x: np.ndarray, up: int, down: int) -> np.ndarray:
    """Polyphase FIR resample along axis 0, identical to ``preprocess.resample_poly_nd``.

    Same filter and the same zero-stuff / pre-pad / centre-crop indexing, but each output sample is
    computed directly as a short dot product over the input samples that reach it (about
    20*max(up,down)/up taps), instead of convolving the whole zero-stuffed signal. Large ratios such
    as 767/512 then cost no more than 3/2. Results agree with resample_poly_nd to ~1e-15.
    """
    x = np.asarray(x, dtype=np.float64)
    if x.ndim == 1:
        return resample_poly_direct(x[:, None], up, down)[:, 0]
    up, down = int(up), int(down)
    if up < 1 or down < 1:
        raise ValueError("up/down must be positive integers")
    g = math.gcd(up, down)
    up, down = up // g, down // g
    n_in = x.shape[0]
    if n_in == 0:
        raise ValueError("cannot resample an empty signal")
    h = _design_resample_filter(up, down)
    half_len = (len(h) - 1) // 2
    n_pre_pad = down - (half_len % down)
    n_pre_remove = (half_len + n_pre_pad) // down
    hp = np.concatenate([np.zeros(n_pre_pad, dtype=np.float64), h])
    lp = hp.size
    n_out = (n_in * up) // down + bool((n_in * up) % down)
    m = (np.arange(n_out, dtype=np.int64) + n_pre_remove) * down       # index into the full convolution
    n_hi = m // up                                                      # last input reaching output k
    taps = (lp - 1) // up + 1
    out = np.zeros((n_out, x.shape[1]), dtype=np.float64)
    chunk = max(1, 2_000_000 // max(1, taps * x.shape[1]))
    for c0 in range(0, n_out, chunk):
        c1 = min(n_out, c0 + chunk)
        n_idx = n_hi[c0:c1, None] - np.arange(taps, dtype=np.int64)[None, :]
        tap = m[c0:c1, None] - n_idx * up
        valid = (n_idx >= 0) & (n_idx < n_in) & (tap < lp)
        w = np.where(valid, hp[np.minimum(tap, lp - 1)], 0.0)
        xi = np.clip(n_idx, 0, n_in - 1)
        out[c0:c1] = np.einsum("kt,ktc->kc", w, x[xi])
    return out


# ---------------------------------------------------------------------------
# Accel/gyro alignment and pieces
# ---------------------------------------------------------------------------

@dataclass
class Piece:
    """One contiguous 6-channel 30 Hz run with accel and gyro aligned (no fill anywhere)."""
    subject: int
    activity: str
    recording: int                  # index of the accel recording within (subject, activity)
    t0_ns: int                      # absolute time of output sample 0 (fitted accel clock)
    samples: np.ndarray             # (n, 6) float64: ax, ay, az (g), gx, gy, gz (deg/s) at 30 Hz
    acc_rate_hz: float
    acc_nominal_hz: int
    acc_ratio: Tuple[int, int]
    gyr_rate_hz: float
    gyr_nominal_hz: int
    gyr_ratio: Tuple[int, int]
    offset_s: float                 # gyro - accel instant offset (constant over the piece)
    time_error_s: float             # max |output time - (t0 + k/30)| over the piece (rational approx.)
    wander_s: float = 0.0           # max transient gyro-timestamp excursion tolerated inside the piece
    n_repaired: int = 0             # repaired samples of the two source segments (whole segments)
    # 30 Hz output position (fractional sample index) of every repaired raw sample inside this piece
    repaired_pos: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.float64))

    @property
    def n(self) -> int:
        return int(self.samples.shape[0])

    @property
    def duration_s(self) -> float:
        return self.n / TARGET_HZ


@dataclass
class AlignStats:
    n_pairs: int = 0
    n_pieces: int = 0
    n_slips: int = 0                # one-stream sample slips (accel-index level jumps) split a pair
    n_clock_mismatch: int = 0       # rate ratio not the nominal ratio (not a shared clock) -> rejected
    n_unaligned: int = 0            # no common instant within ALIGN_TOL_S -> rejected
    n_short: int = 0                # consistent stretch shorter than MIN_SEGMENT_S

    def add(self, other: "AlignStats") -> None:
        for k in self.__dataclass_fields__:
            setattr(self, k, getattr(self, k) + getattr(other, k))


SLIP_JUMP = 0.5                     # accel samples: a sustained level jump this large is a slip
SLIP_MIN_S = 2.0                    # level excursions shorter than this are timestamp wander, not slips
CLOCK_RATIO_TOL = 1e-3              # measured accel/gyro rate ratio vs the nominal ratio


def consistent_runs(acc: Segment, gyr: Segment,
                    stats: Optional[AlignStats] = None) -> List[Tuple[int, int, float]]:
    """Stretches where the gyro sits at a constant position on the accel sample index.

    WISDM's gyro shares the accel clock, so gyro sample j lies at accel index c + j*k with
    k = accel nominal / gyro nominal (1 at 20/20 and 100/100 Hz, 2 at 50/25 Hz) and a constant c. The
    position of every gyro sample is read off the accel timestamps (linear interpolation of the accel
    index over its own timestamps; exact for shared instants). The level c is the rolling median over
    2 * SLIP_MIN_S of gyro samples. A level jump of >= SLIP_JUMP accel samples means one stream lost
    or gained a sample the other did not, for longer than SLIP_MIN_S: the pair is split there. Shorter
    excursions are timestamp wander (the 1638-1640 watches shift their gyro timestamps by one accel
    sample, 20 ms, for ~1-2 s at a time and return); they are tolerated and their size is recorded.
    Returns [(gyro index start, gyro index end inclusive, c, max |c - level| in accel samples)].
    """
    st = stats if stats is not None else AlignStats()
    k = Fraction(acc.nominal_hz, gyr.nominal_hz)
    meas = acc.rate_hz / gyr.rate_hz
    if abs(meas / float(k) - 1.0) > CLOCK_RATIO_TOL:
        st.n_clock_mismatch += 1
        return []
    lo = max(acc.ts_ns[0], gyr.ts_ns[0])
    hi = min(acc.ts_ns[-1], gyr.ts_ns[-1])
    if (hi - lo) / 1e9 < MIN_SEGMENT_S:
        st.n_short += 1
        return []
    j = np.flatnonzero((gyr.ts_ns >= lo) & (gyr.ts_ns <= hi))
    pos = np.interp(gyr.ts_ns[j].astype(np.float64), acc.ts_ns.astype(np.float64),
                    np.arange(acc.n, dtype=np.float64))
    c = pos - j * float(k)
    width = 2 * int(round(SLIP_MIN_S * gyr.rate_hz)) + 1
    cm = _rolling_median(c, width)
    cut = np.flatnonzero(np.abs(np.diff(cm)) >= SLIP_JUMP) + 1
    st.n_slips += int(cut.size)
    out = []
    for s, e in zip(np.r_[0, cut], np.r_[cut, j.size]):
        if e - s < 2:
            continue
        j0, j1 = int(j[s]), int(j[e - 1])
        if (j1 - j0) / gyr.rate_hz < MIN_SEGMENT_S:
            st.n_short += 1
            continue
        level = float(np.median(cm[s:e]))
        out.append((j0, j1, level, float(np.max(np.abs(c[s:e] - level)))))
    return out


def align_run(acc: Segment, gyr: Segment, j0: int, j1: int, c: float, subject: int, activity: str,
              recording: int, tol_s: float = ALIGN_TOL_S,
              stats: Optional[AlignStats] = None, wander: float = 0.0) -> Optional[Piece]:
    """Resample one consistent stretch of an accel/gyro pair onto a common 30 Hz time base.

    The start is the first gyro sample whose accel position c + j*k is within tol of an accel sample.
    The accel ratio up/down approximates 30 / (measured accel rate over the stretch); the gyro ratio is
    derived from it (up*k/down) because the gyro runs at exactly 1/k of the accel rate on the same
    clock. Output sample m of both streams then lies at the same accel-index position
    start + m*down/up: the two grids coincide, up to the constant sub-sample offset ``offset_s``.
    """
    st = stats if stats is not None else AlignStats()
    k = Fraction(acc.nominal_hz, gyr.nominal_hz)
    kf = float(k)
    tol_idx = tol_s * acc.rate_hz
    start = None
    for jg in range(j0, min(j1, j0 + int(math.ceil(gyr.rate_hz)) + 1)):
        p = c + jg * kf
        ia = int(round(p))
        if 0 <= ia < acc.n and abs(p - ia) <= tol_idx:
            start = (jg, ia, p - ia)
            break
    if start is None:
        st.n_unaligned += 1
        return None
    jg, ia, frac = start
    ia1 = min(acc.n - 1, int(math.floor(c + j1 * kf + 1e-9)))
    if ia1 - ia < 3 or j1 - jg < 3:
        st.n_short += 1
        return None
    _, rate_a, _, _ = fit_clock(acc.ts_ns[ia:ia1 + 1])
    dur_a = (ia1 - ia) / rate_a
    if dur_a < MIN_SEGMENT_S:
        st.n_short += 1
        return None
    ua, da, eps = rational_ratio(rate_a, dur_a)
    g_ratio = Fraction(ua, da) * k
    ug, dg = g_ratio.numerator, g_ratio.denominator
    ya = resample_poly_direct(acc.x[ia:ia1 + 1], ua, da)
    yg = resample_poly_direct(gyr.x[jg:j1 + 1], ug, dg)
    step_idx = da / ua                                   # accel samples per output sample
    n = min(ya.shape[0], yg.shape[0],
            int(math.floor((ia1 - ia) / step_idx + 1e-9)) + 1,
            int(math.floor((j1 - jg) * kf / step_idx + 1e-9)) + 1)
    if n < 1:
        st.n_short += 1
        return None
    t0_abs_s = acc.ref_ns / 1e9 + float(acc.t_fit(ia))
    # repaired raw samples on the 30 Hz output grid: accel index i -> (i - ia) * ua/da; gyro index j -> (j - jg) *
    # k * ua/da (both grids start at the same instant up to the sub-sample offset)
    ra = acc.repaired_index[(acc.repaired_index >= ia) & (acc.repaired_index <= ia1)]
    rg = gyr.repaired_index[(gyr.repaired_index >= jg) & (gyr.repaired_index <= j1)]
    pos = np.concatenate([(ra - ia) * (ua / da), (rg - jg) * kf * (ua / da)]).astype(np.float64)
    pos = np.sort(pos[(pos >= 0) & (pos <= n - 1)])
    st.n_pieces += 1
    return Piece(subject=subject, activity=activity, recording=recording,
                 t0_ns=int(round(t0_abs_s * 1e9)),
                 samples=np.concatenate([ya[:n], yg[:n]], axis=1),
                 acc_rate_hz=rate_a, acc_nominal_hz=acc.nominal_hz, acc_ratio=(ua, da),
                 gyr_rate_hz=rate_a / kf, gyr_nominal_hz=gyr.nominal_hz, gyr_ratio=(ug, dg),
                 offset_s=frac / rate_a, time_error_s=abs(eps) * (n - 1) / TARGET_HZ,
                 wander_s=wander / rate_a, n_repaired=acc.n_repaired + gyr.n_repaired, repaired_pos=pos)


def align_segments(acc: Segment, gyr: Segment, subject: int, activity: str, recording: int,
                   tol_s: float = ALIGN_TOL_S, stats: Optional[AlignStats] = None) -> List[Piece]:
    """All aligned 30 Hz pieces of one overlapping accel/gyro segment pair."""
    st = stats if stats is not None else AlignStats()
    st.n_pairs += 1
    out = []
    for j0, j1, c, wander in consistent_runs(acc, gyr, st):
        p = align_run(acc, gyr, j0, j1, c, subject, activity, recording, tol_s, st, wander)
        if p is not None:
            out.append(p)
    return out


# ---------------------------------------------------------------------------
# Windows (serve.py semantics)
# ---------------------------------------------------------------------------

def window_starts(n: int, window: int = WINDOW_SAMPLES, hop: int = HOP_SAMPLES,
                  margin: int = MARGIN_SAMPLES) -> List[int]:
    """Window start indices exactly as preprocess.windows_from_run emits them for a whole-run request:
    a 2 s grid anchored at sample 0, keeping windows that start >= margin and end >= margin before n."""
    out = []
    k = 0
    while k + window <= n:
        if k >= margin and n - (k + window) >= margin:
            out.append(k)
        k += hop
    return out


def window_repair_counts(piece: Piece, starts: Sequence[int], window: int = WINDOW_SAMPLES,
                         margin: int = 0) -> np.ndarray:
    """Repaired raw samples inside each window [k - margin, k + window - 1 + margin] (output samples) of a piece.

    ``margin = 0`` counts the samples inside the window; ``margin = 15`` (0.5 s) also counts dropouts close
    enough to reach the window through the resampling filter's main lobe."""
    pos = np.asarray(piece.repaired_pos, dtype=np.float64)
    k = np.asarray(starts, dtype=np.float64)
    if not pos.size or not k.size:
        return np.zeros(len(k), dtype=np.int64)
    lo = np.searchsorted(pos, k - margin, side="left")
    hi = np.searchsorted(pos, k + window - 1 + margin, side="right")
    return (hi - lo).astype(np.int64)


# ---------------------------------------------------------------------------
# Subject loader
# ---------------------------------------------------------------------------

@dataclass
class RecordingReport:
    subject: int
    activity: str
    recording: int
    acc_seconds: float
    gyr_seconds_activity: float     # all gyro recordings of this activity
    aligned_seconds: float
    n_pieces: int
    n_windows: int
    acc_nominal_hz: List[int] = field(default_factory=list)
    gyr_nominal_hz: List[int] = field(default_factory=list)
    reason: str = ""                # "" | "no_gyro" | "no_overlap"


@dataclass
class SubjectData:
    subject: int
    pieces: List[Piece]
    recordings: List[RecordingReport]
    acc_stats: StreamStats
    gyr_stats: StreamStats
    align_stats: AlignStats = field(default_factory=AlignStats)
    n_unparsed: int = 0
    n_wrong_subject: int = 0
    gyro_only_activities: List[str] = field(default_factory=list)
    repair: str = DEFAULT_REPAIR
    repaired_ts_ns: np.ndarray = field(default_factory=lambda: np.zeros(0, dtype=np.int64))  # accel + gyro, sorted

    def report(self) -> Dict[str, Any]:
        starts = [window_starts(p.n) for p in self.pieces]
        per_win = [window_repair_counts(p, k) for p, k in zip(self.pieces, starts)]
        return {
            "subject": self.subject,
            "repair": self.repair,
            "n_repaired_samples_in_pieces": int(sum(len(p.repaired_pos) for p in self.pieces)),
            "n_windows_with_repaired_samples": int(sum(int((c > 0).sum()) for c in per_win)),
            "n_pieces": len(self.pieces),
            "n_windows": int(sum(len(window_starts(p.n)) for p in self.pieces)),
            "accel": self.acc_stats.__dict__.copy(),
            "gyro": self.gyr_stats.__dict__.copy(),
            "alignment": self.align_stats.__dict__.copy(),
            "max_abs_offset_ms": round(max([abs(p.offset_s) for p in self.pieces], default=0.0) * 1e3, 3),
            "max_time_error_ms": round(max([p.time_error_s for p in self.pieces], default=0.0) * 1e3, 3),
            "max_wander_ms": round(max([p.wander_s for p in self.pieces], default=0.0) * 1e3, 3),
            "n_unparsed_rows": self.n_unparsed,
            "n_wrong_subject_rows": self.n_wrong_subject,
            "gyro_only_activities": list(self.gyro_only_activities),
            "recordings": [r.__dict__.copy() for r in self.recordings],
        }


def _stream_segments(raw: RawStream, activity: str, scale: float,
                     stats: StreamStats, repair: str = DEFAULT_REPAIR) -> List[Tuple[int, List[Segment], float]]:
    """[(recording index, segments, recording seconds)] of one activity of one sensor stream."""
    m = raw.activity == activity
    t, v, n_exact, n_conf = sorted_unique(raw.ts_ns[m], raw.xyz[m] * scale)
    stats.n_rows += int(m.sum())
    stats.n_exact_duplicates += n_exact
    stats.n_conflicting_dropped += n_conf
    out = []
    for ri, (s, e) in enumerate(recordings(t)):
        segs = constant_rate_segments(t[s:e], v[s:e], stats, repair)
        out.append((ri, segs, float((t[e - 1] - t[s]) / 1e9) if e - s > 1 else 0.0))
    return out


def subject_paths(wisdm_dir: str, subject: int) -> Tuple[str, str]:
    return (os.path.join(wisdm_dir, "raw", "watch", "accel", f"data_{subject}_accel_watch.txt"),
            os.path.join(wisdm_dir, "raw", "watch", "gyro", f"data_{subject}_gyro_watch.txt"))


def load_subject(wisdm_dir: str, subject: int, repair: str = DEFAULT_REPAIR) -> SubjectData:
    """All aligned 30 Hz pieces of one subject plus an exclusion/quality report (``repair``: see
    :data:`REPAIR_POLICIES`)."""
    check_repair(repair)
    ap, gp = subject_paths(wisdm_dir, subject)
    acc = parse_raw(ap, subject)
    gyr = parse_raw(gp, subject)
    acc_stats, gyr_stats = StreamStats(), StreamStats()
    align_stats = AlignStats()
    pieces: List[Piece] = []
    reports: List[RecordingReport] = []
    acc_acts = sorted(set(acc.activity.tolist()))
    gyr_acts = sorted(set(gyr.activity.tolist()))
    rep_ts: List[np.ndarray] = []
    for act in acc_acts:
        a_recs = _stream_segments(acc, act, M_S2_TO_G, acc_stats, repair)
        g_recs = _stream_segments(gyr, act, RAD_S_TO_DEG_S, gyr_stats, repair) if act in gyr_acts else []
        g_segs = [s for _, segs, _ in g_recs for s in segs]
        rep_ts += [sg.ts_ns[sg.repaired_index] for _, segs, _ in a_recs for sg in segs]
        rep_ts += [sg.ts_ns[sg.repaired_index] for sg in g_segs]
        g_secs = sum(sec for _, _, sec in g_recs)
        for ri, a_segs, a_sec in a_recs:
            rec_pieces: List[Piece] = []
            for sa in a_segs:
                for sg in g_segs:
                    if sg.end_abs_s < sa.start_abs_s or sg.start_abs_s > sa.end_abs_s:
                        continue
                    rec_pieces.extend(align_segments(sa, sg, subject, act, ri, stats=align_stats))
            rec_pieces.sort(key=lambda p: p.t0_ns)
            pieces.extend(rec_pieces)
            if not g_recs:
                reason = "no_gyro"
            elif not rec_pieces:
                reason = "no_overlap"
            else:
                reason = ""
            reports.append(RecordingReport(
                subject=subject, activity=act, recording=ri, acc_seconds=round(a_sec, 3),
                gyr_seconds_activity=round(g_secs, 3),
                aligned_seconds=round(sum(p.duration_s for p in rec_pieces), 3),
                n_pieces=len(rec_pieces),
                n_windows=int(sum(len(window_starts(p.n)) for p in rec_pieces)),
                acc_nominal_hz=sorted({s.nominal_hz for s in a_segs}),
                gyr_nominal_hz=sorted({s.nominal_hz for s in g_segs}),
                reason=reason))
    return SubjectData(subject=subject, pieces=pieces, recordings=reports, acc_stats=acc_stats,
                       gyr_stats=gyr_stats, align_stats=align_stats, n_unparsed=acc.n_unparsed + gyr.n_unparsed,
                       n_wrong_subject=acc.n_wrong_subject + gyr.n_wrong_subject,
                       gyro_only_activities=sorted(set(gyr_acts) - set(acc_acts)), repair=repair,
                       repaired_ts_ns=np.sort(np.concatenate(rep_ts)).astype(np.int64) if rep_ts
                       else np.zeros(0, dtype=np.int64))


def available_subjects(wisdm_dir: str, subjects: Sequence[int]) -> List[int]:
    """Subjects with both watch files present (the split universe; 51 for the full archive)."""
    out = []
    for s in subjects:
        ap, gp = subject_paths(wisdm_dir, s)
        if os.path.isfile(ap) and os.path.isfile(gp):
            out.append(int(s))
    return out

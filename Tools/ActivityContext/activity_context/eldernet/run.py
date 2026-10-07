"""Offline ElderNet run over one accelerometer array — the owner's CLI (ELDERNET.md §2/§3).

    python -m activity_context.eldernet.run --input whoop_accel.npy --fs 100 --outdir results/
    python -m activity_context.eldernet.run --input whoop_accel.npy --fs 100 --outdir results/ --upstream

Input: ``.npy`` [N, 3] (or [3, N]) in g at ``--fs`` (gravity kept). Nara mode runs ``eldernet-prep-1`` +
the window-local detector (activity_context.eldernet.gait) and writes, like upstream ``pipelines.general``:

  <stem>_windows.csv   one row per 10 s window re-cut inside each walking bout (upstream columns; the
                       signal-processing ``regularity_signal_processing`` cross-check is not computed)
  <stem>_bouts.csv     one row per bout: median of each metric
  summary.csv          one row: walking minutes, bout count, per-metric median / p10 / p90
  <stem>_gait_windows.csv  every window on the ``--hop-s`` grid: s, e, gait_prob, is_gait, prefiltered and the
                       metrics on gait windows (the served per-window view)

Bouts are upstream's own functions (``gait_quality.detection`` / ``quality``, imported verified from the
operator's checkout, ``--upstream-dir`` / $ELDERNET_UPSTREAM_DIR; :mod:`.bouts`): centre-second voting at hop 1,
3 s gap bridging, 10 s minimum. Differences from upstream by design: no gravity calibration / non-wear /
imputation / edge-day trimming; window-local static pre-filter; nonfinite samples split the recording. Needs
pandas (upstream ``quality.py``). ``--upstream`` instead runs upstream ``pipelines.general`` literally in its own
environment (a full clone at ``--upstream-dir`` / $ELDERNET_UPSTREAM_DIR, ``--upstream-python`` /
$ELDERNET_UPSTREAM_PYTHON) with ``--device cpu`` — the parity reference.
"""

from __future__ import annotations

import argparse
import csv
import datetime as dt
import os
import subprocess
import sys
from typing import Dict, List, Optional, Sequence

import numpy as np

from . import QUALITY_HEADS, RATE_HZ, UPSTREAM_HOP_S, WINDOW_S
from .bouts import bout_window_starts, detect_bouts, second_labels, summarise
from .gait import GaitCalibration, score_windows
from .preprocess import stack_windows, windows_from_array

UPSTREAM_DIR_ENV = "ELDERNET_UPSTREAM_DIR"
UPSTREAM_PYTHON_ENV = "ELDERNET_UPSTREAM_PYTHON"
DEFAULT_START_TIME = "2000-01-01 00:00:00"            # upstream readers.DEFAULT_START_TIME for .npy
# Upstream output column per head (gait_quality/quality.py QUALITY_MODELS + step_count).
UPSTREAM_COLUMNS = {"gait_speed": "gait_speed_m_s", "cadence": "cadence_steps_min", "gait_length": "stride_length_m",
                    "regularity": "regularity_eldernet", "step_count": "step_count"}
METRIC_COLUMNS = list(UPSTREAM_COLUMNS.values()) + ["stride_length_indirect_m"]


def load_array(path: str) -> np.ndarray:
    acc = np.load(path)
    if acc.ndim == 2 and acc.shape[0] == 3 and acc.shape[1] != 3:
        acc = acc.T
    if acc.ndim != 2 or acc.shape[1] != 3 or not len(acc):
        raise SystemExit(f"{path}: expected an [N, 3] array in g, got shape {acc.shape}")
    return np.asarray(acc, dtype=np.float64)


def _stamp(start: dt.datetime, seconds: float) -> str:
    return str(start + dt.timedelta(seconds=float(seconds)))


def _write_csv(path: str, rows: List[Dict], columns: Sequence[str]) -> None:
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=list(columns), extrasaction="ignore")
        w.writeheader()
        for r in rows:
            w.writerow({k: ("" if isinstance(r.get(k), float) and not np.isfinite(r[k]) else r.get(k)) for k in columns})


def analyse(acc: np.ndarray, fs: float, heads, *, hop_s: int = UPSTREAM_HOP_S, start_time: str = DEFAULT_START_TIME,
            calibration: Optional[GaitCalibration] = None, min_bout_s: int = 10, merge_gap_s: int = 3,
            upstream_dir: Optional[str] = None) -> Dict:
    """Nara path end to end on one array; returns rows for the four CSVs (no I/O)."""
    start = dt.datetime.fromisoformat(start_time)
    # detection grid: always the upstream 1 s stride (bouts need it); <stem>_gait_windows.csv keeps every hop_s
    windows = windows_from_array(acc, fs, hop_s=UPSTREAM_HOP_S)
    by_start = {int(round(w.s)): i for i, w in enumerate(windows)}
    sc = score_windows(heads, stack_windows(windows), calibration)         # quality on is_gait windows
    n30 = int(np.around((len(acc) - 1) / fs * RATE_HZ)) + 1                # actipy's 30 Hz tick count
    n_sec_total = n30 / RATE_HZ
    pred = np.zeros(int(max(0, np.floor(n_sec_total - WINDOW_S + 1e-9) + 1)), dtype=int)
    for i, w in enumerate(windows):
        if 0 <= int(w.s) < len(pred):
            pred[int(w.s)] = int(sc.is_gait[i])
    labels = second_labels(pred, min_bout_s, merge_gap_s, upstream_dir)
    bouts = detect_bouts(labels, upstream_dir)
    cut = [(b, by_start[s]) for b, s in bout_window_starts(bouts, n30, upstream_dir) if s in by_start]
    extra = sorted({i for _, i in cut if not sc.is_gait[i]})      # bridged-gap windows: quality as upstream
    q_extra = heads.quality(stack_windows([windows[i] for i in extra])) if extra else {}
    pos = {i: j for j, i in enumerate(extra)}
    rows: List[Dict] = []
    for bid, i in cut:
        s = int(round(windows[i].s))
        r = {"timestamp": _stamp(start, s), "bout_id": bid, "start_sample": s * RATE_HZ}
        for name, col in UPSTREAM_COLUMNS.items():
            v = sc.metrics[name][i] if sc.is_gait[i] else q_extra[name][pos[i]]
            r[col] = float(np.clip(v, 0.0, QUALITY_HEADS[name][1]))
        cad = r["cadence_steps_min"]
        r["stride_length_indirect_m"] = 120.0 * r["gait_speed_m_s"] / cad if cad > 0 else float("nan")
        rows.append(r)
    gait_rows = []
    for i, w in enumerate(windows):
        if int(round(w.s)) % hop_s:
            continue
        r = {"s": w.s, "e": w.e, "timestamp": _stamp(start, w.s), "gait_prob": float(sc.gait_prob[i]),
             "is_gait": bool(sc.is_gait[i]), "prefiltered": bool(sc.prefiltered[i]), "finite": bool(sc.finite[i])}
        for name, (key, _, _, _) in QUALITY_HEADS.items():
            r[key] = float(sc.metrics[name][i])
        gait_rows.append(r)
    summary = {"recording": "", "device": "array", "fs_hz": float(fs), "start_time": start_time,
               "duration_hours": round(len(acc) / fs / 3600, 3), "calibration_ok": ""}
    bout_rows, recording = summarise(rows, labels, METRIC_COLUMNS, upstream_dir)
    summary.update(recording)
    return {"windows": rows, "bouts": bout_rows, "summary": summary,
            "gait_windows": gait_rows, "second_labels": labels, "n_detection_windows": len(windows)}


def write_outputs(result: Dict, outdir: str, stem: str, recording: str) -> None:
    os.makedirs(outdir, exist_ok=True)
    if result["windows"]:
        _write_csv(os.path.join(outdir, f"{stem}_windows.csv"), result["windows"],
                   ["timestamp", "bout_id", "start_sample"] + METRIC_COLUMNS)
        _write_csv(os.path.join(outdir, f"{stem}_bouts.csv"), result["bouts"],
                   ["bout_id", "n_windows", "duration_sec", "start_time"] + METRIC_COLUMNS)
    _write_csv(os.path.join(outdir, f"{stem}_gait_windows.csv"), result["gait_windows"],
               ["s", "e", "timestamp", "gait_prob", "is_gait", "prefiltered", "finite"]
               + [v[0] for v in QUALITY_HEADS.values()])
    summary = dict(result["summary"], recording=recording)
    _write_csv(os.path.join(outdir, "summary.csv"), [summary], list(summary))


def run_upstream(input_path: str, fs: float, outdir: str, upstream_dir: Optional[str], upstream_python: Optional[str],
                 nonwear: str = "auto") -> int:
    """Literally ``python -m pipelines.general`` in the upstream checkout (parity reference)."""
    from ..inertia.subproc import PYTHON_ENV_ALLOWLIST, safe_env
    up = upstream_dir or os.environ.get(UPSTREAM_DIR_ENV, "")
    py = upstream_python or os.environ.get(UPSTREAM_PYTHON_ENV, "")
    if not up or not os.path.isdir(up) or not py:
        raise SystemExit(f"--upstream needs --upstream-dir/${UPSTREAM_DIR_ENV} and "
                         f"--upstream-python/${UPSTREAM_PYTHON_ENV}")
    cmd = [py, "-m", "pipelines.general", "--input", os.path.abspath(input_path), "--fs", str(fs),
           "--device", "cpu", "--nonwear", nonwear, "--outdir", os.path.abspath(outdir)]
    env = safe_env({"PYTHONPATH": up, "PYTHONDONTWRITEBYTECODE": "1"}, allow=PYTHON_ENV_ALLOWLIST)
    return subprocess.run(cmd, cwd=up, env=env).returncode


def main(argv: Optional[Sequence[str]] = None) -> int:
    ap = argparse.ArgumentParser(description="ElderNet gait quality over an [N, 3] g array (Nara path or upstream)")
    ap.add_argument("--input", required=True, help=".npy [N, 3] accelerometer in g")
    ap.add_argument("--fs", type=float, required=True, help="sampling rate (Hz)")
    ap.add_argument("--outdir", default="output")
    ap.add_argument("--hop-s", type=int, default=UPSTREAM_HOP_S, help="grid of <stem>_gait_windows.csv (default 1)")
    ap.add_argument("--start-time", default=DEFAULT_START_TIME, help="timestamp of sample 0 (upstream default)")
    ap.add_argument("--weights-dir", default=None, help="the six pinned heads (default $ELDERNET_WEIGHTS_DIR)")
    ap.add_argument("--calibration", default=None, help="VAL-fitted gait calibration JSON (default none)")
    ap.add_argument("--threads", type=int, default=1)
    ap.add_argument("--upstream", action="store_true", help="run upstream pipelines.general instead (parity)")
    ap.add_argument("--upstream-dir", default=None,
                    help="the pinned upstream source (default $ELDERNET_UPSTREAM_DIR; a full clone for --upstream)")
    ap.add_argument("--upstream-python", default=None)
    ap.add_argument("--nonwear", choices=["auto", "on", "off"], default="auto", help="(--upstream only)")
    args = ap.parse_args(argv)
    if args.upstream:
        return run_upstream(args.input, args.fs, args.outdir, args.upstream_dir, args.upstream_python, args.nonwear)
    from .model import load_heads
    from .runtime import load_calibration
    from .weights import WeightsError, resolve
    try:
        heads = load_heads(resolve(args.weights_dir), threads=args.threads, upstream_dir=args.upstream_dir)
        acc = load_array(args.input)
        result = analyse(acc, args.fs, heads, hop_s=args.hop_s, start_time=args.start_time,
                         calibration=load_calibration(args.calibration), upstream_dir=args.upstream_dir)
    except WeightsError as exc:
        print(f"[eldernet.run] {exc.kind}: {exc.message}", file=sys.stderr)
        return 2
    name = os.path.basename(args.input)
    stem = name[:-4] if name.lower().endswith(".npy") else os.path.splitext(name)[0]
    write_outputs(result, args.outdir, stem, name)
    print(f"[eldernet.run] {len(result['bouts'])} bouts, {result['summary']['walking_time_min']:.1f} min walking, "
          f"{int(sum(r['is_gait'] for r in result['gait_windows']))}/{len(result['gait_windows'])} gait windows "
          f"-> {args.outdir}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

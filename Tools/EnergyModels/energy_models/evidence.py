"""Raw wrist IMU -> per-minute motion evidence for the Swift energy estimator.

``energy-evidence`` reads a raw accelerometer (+ gyroscope) recording, cuts it into wall-clock minutes,
runs WristMET and, optionally, the pretrained wrist CNN over each minute, and writes
``energy-motion-evidence-v1`` JSON: the document ``MotionEvidenceDocument`` decodes in
``Packages/StrandAnalytics/Sources/StrandAnalytics/Energy/MotionEvidence.swift``. Swift fuses these
records with heart rate, activity context and priors; nothing here weighs one model against another.

Behaviour worth knowing before trusting a number:

* One record per wall-clock minute (``t`` is unix seconds, a multiple of 60), so records line up with the
  estimator's minute grid. Each window is cut from that minute's own samples, never from a grid that
  started at some earlier sample, so a dropout cannot shift every later minute.
* A minute is modelled only if its 60 s are covered without a gap above 500 ms (the models were trained on
  gap-free windows, and an interpolated hole is not data). Anything else is skipped, not guessed, and
  counted in ``provenance.counts``.
* The two models run independently on the same samples; neither sees the other's output. The CNN is
  scheduled only on minutes WristMET calls non-sedentary. That is a cost and bias choice, not a coupling:
  the CNN's regression head reads ~1.40 MET on motionless input (its labels come from a waist-ActiGraph
  proxy, not calorimetry), so running it on rest minutes would add a small upward offset to the day's
  largest block of minutes for no information. With no gyroscope WristMET cannot run, and the CNN is then
  scheduled on every minute that is not motionless (``--cnn-policy all`` does the same with WristMET).
* WristMET here is the model retrained from the authors' public code and data, and its published accuracy
  did not reproduce. ``provenance.wristmet.validated_rmse_met`` records the leave-one-participant-out
  errors from the artifact manifest, and the Swift side keeps its sigmas in step with them (a test fails
  if they drift apart).
* Axis conventions are assumptions. ``AxisMap`` defaults to the identity: nothing here proves a WHOOP
  strap's axes match the training watch's. Pass a map you have verified with ``--axis-map``.
* The wearer's age, weight and height are inputs to WristMET's regressor but are not written to the output;
  only how far they sit from the training cohort (``demog_ood``) is.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Sequence

import numpy as np

from . import __version__
from .wrist_cnn.inputs import prepare_windows, quiet_mask
from .wrist_cnn.ood import ood_signal as cnn_ood_signal
from .wrist_cnn.pins import PINNED_COMMIT
from .wristmet import AxisMap, WristMetModel
from .wristmet.preprocess import STANDARD_GRAVITY_MS2, windows_from_raw

SCHEMA = "energy-motion-evidence-v1"
CNN_MODEL_ID = f"wrist-cnn-{PINNED_COMMIT[:7]}"

MINUTE_MS = 60_000
#: Fewest seconds of a minute that must contain a sample for the minute to be modelled; matches the
#: threshold the Swift side applies before it will use a record.
MIN_IMU_SECONDS = 30
#: A window may start at most this long after the minute boundary (otherwise it would straddle two minutes).
MAX_LATE_START_MS = 1_000
_WRISTMET_BLOCK = 120
_CNN_BLOCK = 64

_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_WRISTMET_PATH = _ROOT / "artifacts" / "wristmet" / "wristmet-v1.json.gz"

CNN_POLICIES = ("active", "all")


@dataclass(frozen=True)
class Wearer:
    """Who wore the strap. WristMET's regressor takes these; they are not written to the output."""

    age: float
    sex: str
    weight_kg: float
    height_cm: float
    wrist: str = "right"

    @classmethod
    def from_dict(cls, d: dict) -> "Wearer":
        missing = [k for k in ("age", "sex", "weight_kg", "height_cm") if k not in d]
        if missing:
            raise ValueError(f"profile is missing {missing}")
        return cls(float(d["age"]), str(d["sex"]), float(d["weight_kg"]), float(d["height_cm"]),
                   str(d.get("wrist", "right")))


@dataclass(frozen=True)
class Recording:
    """A continuous raw capture. ``acc`` includes gravity."""

    t_ms: np.ndarray                 # [M] unix epoch milliseconds
    acc: np.ndarray                  # [M, 3]
    gyr: np.ndarray | None = None    # [M, 3]; WristMET needs it, the CNN does not
    acc_unit: str = "g"              # "g" or "m/s2"
    gyr_unit: str = "deg/s"          # "deg/s" or "rad/s"


@dataclass(frozen=True)
class WristMetBundle:
    model: WristMetModel
    model_id: str                    # model id + artifact digest prefix: identifies the exact weights
    sha256: str
    validated_rmse: dict | None      # leave-one-participant-out errors from the artifact manifest


# ----------------------------------------------------------------------------- loading

def load_wristmet(path: str | Path | None = None) -> WristMetBundle:
    """Load the WristMET artifact; if a ``manifest.json`` sits next to it, refuse a digest mismatch."""
    path = Path(path) if path is not None else DEFAULT_WRISTMET_PATH
    manifest_path = path.parent / "manifest.json"
    manifest = json.loads(manifest_path.read_text()) if manifest_path.exists() else None
    expected = manifest["artifact"]["sha256"] if manifest and "artifact" in manifest else None
    model = WristMetModel.load(path, expected_sha256=expected)
    sha = expected or hashlib.sha256(path.read_bytes()).hexdigest()
    validated = None
    if manifest and "loso" in manifest:
        primary = manifest["loso"].get("w60_primary", {})
        ablation = manifest["loso"].get("w60_ablation_demographics_free", {})
        non_sedentary = ablation.get("regressor_only_rmse_on_nonsedentary_windows", {})
        validated = {
            "overall": primary.get("rmse_overall"),
            "sedentary": primary.get("rmse_sedentary"),
            "non_sedentary_regressor": non_sedentary.get("nine_features"),
            "source": "artifact manifest, leave-one-participant-out, 60 s windows",
        }
    return WristMetBundle(model, f"{model.model_id}-{sha[:8]}", sha, validated)


def load_cnn(artifacts_dir: str | Path | None = None):
    """The digest-verified regression CNN, or ``None`` if its weights have not been fetched."""
    from .wrist_cnn.model import load_model

    try:
        return load_model("regression", artifacts_dir)
    except FileNotFoundError:
        return None


def load_recording(path: str | Path, *, acc_unit: str = "g", gyr_unit: str = "deg/s") -> Recording:
    """``.npz`` with ``t_ms``, ``acc`` [M,3] and optional ``gyr`` [M,3]; or ``.csv`` with a header row of
    ``t_ms,ax,ay,az[,gx,gy,gz]``. Use npz for real captures: a day at 100 Hz is ~8.6 million rows."""
    p = Path(path)
    if p.suffix == ".npz":
        with np.load(p, allow_pickle=False) as z:
            if "t_ms" not in z.files or "acc" not in z.files:
                raise ValueError(f"{p}: an .npz recording needs 't_ms' and 'acc' (optional 'gyr')")
            gyr = np.asarray(z["gyr"], dtype=np.float64) if "gyr" in z.files else None
            return Recording(np.asarray(z["t_ms"], dtype=np.float64), np.asarray(z["acc"], dtype=np.float64),
                             gyr, acc_unit, gyr_unit)
    if p.suffix == ".csv":
        table = np.genfromtxt(p, delimiter=",", names=True, dtype=np.float64)
        names = table.dtype.names or ()
        need = ("t_ms", "ax", "ay", "az")
        if any(n not in names for n in need):
            raise ValueError(f"{p}: CSV header must include {need}")
        acc = np.column_stack([table["ax"], table["ay"], table["az"]])
        gyr = (np.column_stack([table["gx"], table["gy"], table["gz"]])
               if all(n in names for n in ("gx", "gy", "gz")) else None)
        return Recording(np.asarray(table["t_ms"]), acc, gyr, acc_unit, gyr_unit)
    raise ValueError(f"unsupported recording format {p.suffix!r}; use .npz or .csv")


def _clean(rec: Recording) -> tuple[np.ndarray, np.ndarray, np.ndarray | None]:
    """Sorted, de-duplicated, finite samples; refuses a unit that is plainly wrong."""
    t = np.asarray(rec.t_ms, dtype=np.float64)
    acc = np.asarray(rec.acc, dtype=np.float64)
    gyr = None if rec.gyr is None else np.asarray(rec.gyr, dtype=np.float64)
    if acc.ndim != 2 or acc.shape != (t.shape[0], 3):
        raise ValueError(f"acc must be [M, 3] matching t_ms; got {acc.shape} for {t.shape[0]} timestamps")
    if gyr is not None and gyr.shape != (t.shape[0], 3):
        raise ValueError(f"gyr must be [M, 3] matching t_ms; got {gyr.shape}")
    if rec.acc_unit not in ("g", "m/s2"):
        raise ValueError("acc_unit must be 'g' or 'm/s2'")
    if rec.gyr_unit not in ("deg/s", "rad/s"):
        raise ValueError("gyr_unit must be 'deg/s' or 'rad/s'")

    ok = np.isfinite(t) & np.isfinite(acc).all(axis=1)
    if gyr is not None:
        ok &= np.isfinite(gyr).all(axis=1)
    t, acc = t[ok], acc[ok]
    gyr = None if gyr is None else gyr[ok]
    order = np.argsort(t, kind="stable")
    t, acc = t[order], acc[order]
    gyr = None if gyr is None else gyr[order]
    if t.size:
        keep = np.concatenate([[True], np.diff(t) > 0])
        t, acc = t[keep], acc[keep]
        gyr = None if gyr is None else gyr[keep]

    if t.size >= 10:
        stride = max(1, t.size // 2000)
        median_norm = float(np.median(np.linalg.norm(acc[::stride], axis=1)))
        if rec.acc_unit == "g" and median_norm > 5.0:
            raise ValueError(f"median |acc| is {median_norm:.2f}: this looks like m/s^2, but acc_unit is 'g'")
        if rec.acc_unit == "m/s2" and median_norm < 2.0:
            raise ValueError(f"median |acc| is {median_norm:.2f}: this looks like g, but acc_unit is 'm/s2'")
    return t, acc, gyr


# ----------------------------------------------------------------------------- the pipeline

def build_evidence(
    rec: Recording,
    wearer: Wearer,
    *,
    wristmet: WristMetBundle | None,
    cnn=None,
    cnn_policy: str = "active",
    axis_map: AxisMap | None = None,
    cnn_axis_transform: np.ndarray | None = None,
    progress: Callable[[str], None] | None = None,
) -> dict:
    """Return the ``energy-motion-evidence-v1`` document (a plain dict, ready for ``json.dump``).

    ``cnn`` is anything with ``predict(windows[n, 6000, 3]) -> met[n]`` (a ``WristCNN`` regression head);
    ``None`` runs WristMET only.
    """
    if cnn_policy not in CNN_POLICIES:
        raise ValueError(f"cnn_policy must be one of {CNN_POLICIES}")
    say = progress or (lambda _msg: None)
    t, acc, gyr = _clean(rec)
    counts = {"minutes_with_imu": 0, "wristmet": 0, "cnn": 0, "skipped_short_imu": 0,
              "skipped_gap_or_late_start": 0, "skipped_cnn_invalid_window": 0}
    records: dict[int, dict] = {}

    if t.size >= 2:
        first = int(t[0] // MINUTE_MS)
        last = int(t[-1] // MINUTE_MS)
        minute_ids = np.arange(first, last + 1, dtype=np.int64)
        starts_ms = minute_ids * MINUTE_MS
        lo = np.searchsorted(t, starts_ms, side="left")
        hi_in = np.searchsorted(t, starts_ms + MINUTE_MS, side="left")
        hi_ext = np.searchsorted(t, starts_ms + MINUTE_MS + 1_000, side="left")
    else:
        minute_ids = np.empty(0, dtype=np.int64)
        starts_ms = lo = hi_in = hi_ext = np.empty(0, dtype=np.int64)

    modelled: list[int] = []        # indices into minute_ids with enough IMU
    for k in range(minute_ids.size):
        if hi_in[k] <= lo[k]:
            continue
        counts["minutes_with_imu"] += 1
        seconds = int(np.unique(((t[lo[k]:hi_in[k]] - starts_ms[k]) // 1000).astype(np.int64)).size)
        if seconds < MIN_IMU_SECONDS:
            counts["skipped_short_imu"] += 1
            continue
        records[k] = {"t": int(starts_ms[k] // 1000), "imu_s": seconds}
        modelled.append(k)

    demographic_ood: float | None = None
    active_minutes: set[int] = set()
    wristmet_ran = wristmet is not None and gyr is not None

    # ---- WristMET: needs the gyroscope; one 60 s window per minute --------------------------------
    if wristmet_ran:
        demographic_ood = float(wristmet.model.ood_demographic(
            age=wearer.age, sex=wearer.sex, weight_kg=wearer.weight_kg, height_cm=wearer.height_cm))
        pending: list[tuple[int, np.ndarray]] = []

        def flush() -> None:
            if not pending:
                return
            result = wristmet.model.predict_windows(
                np.stack([w for _, w in pending]), age=wearer.age, sex=wearer.sex,
                weight_kg=wearer.weight_kg, height_cm=wearer.height_cm)
            for j, (k_, _) in enumerate(pending):
                if not (result.valid[j] and np.isfinite(result.met[j])):
                    counts["skipped_gap_or_late_start"] += 1
                    continue
                records[k_]["wristmet"] = {
                    "met": round(float(result.met[j]), 3),
                    "p_active": round(float(result.p_active[j]), 4),
                    "ood": round(float(result.ood_signal[j]), 3),
                    "model": wristmet.model_id,
                }
                records[k_]["demog_ood"] = round(demographic_ood, 3)
                counts["wristmet"] += 1
                if bool(result.is_active[j]):
                    active_minutes.add(k_)
            pending.clear()

        for n_done, k in enumerate(modelled):
            sl = slice(lo[k], hi_ext[k])
            # Timestamps relative to the minute: the interpolation arithmetic loses ~1e-6 on epoch-sized values.
            raw = windows_from_raw(
                t[sl] - starts_ms[k], acc[sl], gyr[sl], None, acc_unit=rec.acc_unit, gyr_unit=rec.gyr_unit,
                axis_map=axis_map, wrist=wearer.wrist, window_samples=wristmet.model.window_samples,
                rate_hz=wristmet.model.sample_rate_hz)
            if raw.windows.shape[0] == 0 or not raw.valid[0] or raw.start_ms[0] > MAX_LATE_START_MS:
                counts["skipped_gap_or_late_start"] += 1
                continue
            pending.append((k, raw.windows[0]))
            if len(pending) >= _WRISTMET_BLOCK:
                flush()
            if (n_done + 1) % 500 == 0:
                say(f"WristMET: {n_done + 1}/{len(modelled)} minutes")
        flush()

    # ---- wrist CNN: independent of WristMET's output, scheduled by it ------------------------------
    if cnn is not None:
        acc_g = acc / STANDARD_GRAVITY_MS2 if rec.acc_unit == "m/s2" else acc
        candidates = sorted(active_minutes) if (wristmet_ran and cnn_policy == "active") else modelled
        batch: list[tuple[int, np.ndarray]] = []

        def run_batch() -> None:
            if not batch:
                return
            windows = np.stack([w for _, w in batch])
            quiet = quiet_mask(windows) if not (wristmet_ran and cnn_policy == "active") else np.zeros(len(batch), bool)
            met = np.full(len(batch), np.nan)
            if (~quiet).any():
                met[~quiet] = np.asarray(cnn.predict(windows[~quiet]), dtype=np.float64)
            ood = cnn_ood_signal(windows)
            for j, (k_, _) in enumerate(batch):
                if quiet[j] or not np.isfinite(met[j]):
                    continue
                records[k_]["cnn"] = {"met": round(max(1.0, float(met[j])), 3), "ood": round(float(ood[j]), 3),
                                      "model": CNN_MODEL_ID}
                counts["cnn"] += 1
            batch.clear()

        for n_done, k in enumerate(candidates):
            sl = slice(lo[k], hi_ext[k])
            prepared = prepare_windows(acc_g[sl], timestamps=(t[sl] - starts_ms[k]) / 1000.0, fs=100.0,
                                       window_s=60.0, step_s=60.0, axis_transform=cnn_axis_transform)
            if prepared.n == 0 or not prepared.valid[0] or prepared.start_time_s()[0] * 1000.0 > MAX_LATE_START_MS:
                counts["skipped_cnn_invalid_window"] += 1
                continue
            batch.append((k, prepared.windows[0]))
            if len(batch) >= _CNN_BLOCK:
                run_batch()
            if (n_done + 1) % 200 == 0:
                say(f"wrist CNN: {n_done + 1}/{len(candidates)} minutes")
        run_batch()

    minutes = [records[k] for k in sorted(records) if "wristmet" in records[k] or "cnn" in records[k]]
    return {
        "schema": SCHEMA,
        "minutes": [_ordered(m) for m in minutes],
        "provenance": {
            "generator": f"energy-models {__version__}",
            "wristmet": None if wristmet is None else {
                "model": wristmet.model_id,
                "artifact_sha256": wristmet.sha256,
                "ran": wristmet_ran,
                "validated_rmse_met": wristmet.validated_rmse,
            },
            "cnn": None if cnn is None else {
                "model": CNN_MODEL_ID, "upstream_commit": PINNED_COMMIT, "policy": cnn_policy,
                "label_source": "waist-ActiGraph-derived energy expenditure, not calorimetry",
            },
            "axis_map": _axis_map_dict(axis_map),
            "cnn_axis_transform": None if cnn_axis_transform is None else np.asarray(cnn_axis_transform).tolist(),
            "wrist": wearer.wrist,
            "counts": counts,
        },
    }


def _ordered(minute: dict) -> dict:
    return {k: minute[k] for k in ("t", "imu_s", "wristmet", "cnn", "demog_ood") if k in minute}


def _axis_map_dict(axis_map: AxisMap | None) -> dict:
    m = axis_map or AxisMap()
    d = dataclasses.asdict(m)
    d["is_identity"] = m.is_identity
    return d


# ----------------------------------------------------------------------------- command line

def _read_axis_maps(path: str | None) -> tuple[AxisMap | None, np.ndarray | None]:
    if path is None:
        return None, None
    spec = json.loads(Path(path).read_text())
    wm = spec.get("wristmet")
    axis_map = None
    if wm is not None:
        axis_map = AxisMap(
            acc_source=tuple(wm.get("acc_source", (0, 1, 2))), acc_sign=tuple(float(s) for s in wm.get("acc_sign", (1, 1, 1))),
            gyr_source=tuple(wm.get("gyr_source", (0, 1, 2))), gyr_sign=tuple(float(s) for s in wm.get("gyr_sign", (1, 1, 1))))
    cnn = None if spec.get("cnn") is None else np.asarray(spec["cnn"], dtype=np.float64)
    return axis_map, cnn


def main(argv: Sequence[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="energy-evidence",
        description="Raw wrist IMU -> per-minute WristMET / wrist-CNN evidence (energy-motion-evidence-v1 JSON).")
    ap.add_argument("--imu", required=True, help="recording: .npz (t_ms, acc[, gyr]) or .csv (t_ms,ax,ay,az[,gx,gy,gz])")
    ap.add_argument("--profile", required=True,
                    help='JSON {"age":..,"sex":"male|female","weight_kg":..,"height_cm":..,"wrist":"right|left"}')
    ap.add_argument("--out", required=True, help="output JSON path")
    ap.add_argument("--acc-unit", default="g", choices=("g", "m/s2"))
    ap.add_argument("--gyr-unit", default="deg/s", choices=("deg/s", "rad/s"))
    ap.add_argument("--wristmet", default=None, help=f"WristMET artifact (default {DEFAULT_WRISTMET_PATH})")
    ap.add_argument("--cnn", default="auto", choices=("auto", "on", "off"),
                    help="auto: use the CNN if its weights have been fetched; on: require them; off: skip")
    ap.add_argument("--cnn-dir", default=None, help="directory holding the converted CNN weights")
    ap.add_argument("--cnn-policy", default="active", choices=CNN_POLICIES)
    ap.add_argument("--axis-map", default=None,
                    help='JSON {"wristmet": {acc_source, acc_sign, gyr_source, gyr_sign}, "cnn": [[3x3]]} (identity if omitted)')
    args = ap.parse_args(argv)

    try:
        wearer = Wearer.from_dict(json.loads(Path(args.profile).read_text()))
        rec = load_recording(args.imu, acc_unit=args.acc_unit, gyr_unit=args.gyr_unit)
        axis_map, cnn_transform = _read_axis_maps(args.axis_map)
        wristmet = load_wristmet(args.wristmet)
        cnn = None
        if args.cnn != "off":
            cnn = load_cnn(args.cnn_dir)
            if cnn is None and args.cnn == "on":
                print("error: wrist CNN weights not found; run scripts/fetch_wrist_cnn.sh", file=sys.stderr)
                return 2
            if cnn is None:
                print("note: wrist CNN weights not fetched; continuing with WristMET only", file=sys.stderr)
        if rec.gyr is None:
            print("note: no gyroscope in the recording; WristMET cannot run", file=sys.stderr)
        doc = build_evidence(rec, wearer, wristmet=wristmet, cnn=cnn, cnn_policy=args.cnn_policy,
                             axis_map=axis_map, cnn_axis_transform=cnn_transform,
                             progress=lambda m: print(m, file=sys.stderr))
    except (ValueError, FileNotFoundError, KeyError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    Path(args.out).write_text(json.dumps(doc, separators=(",", ":")))
    c = doc["provenance"]["counts"]
    print(f"wrote {len(doc['minutes'])} minutes to {args.out} "
          f"(WristMET {c['wristmet']}, CNN {c['cnn']}, skipped: short IMU {c['skipped_short_imu']}, "
          f"gap/late start {c['skipped_gap_or_late_start']})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

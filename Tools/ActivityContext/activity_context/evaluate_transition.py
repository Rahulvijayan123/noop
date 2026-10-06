"""activity-evaluate-transition — event-level benchmark of the learned transition expert.

The evaluation unit is a TRANSITION EVENT, not a window (spec s12): ground truth comes from the
transition-labelled datasets (HAPT explicit segments; PAMAP2/WISDM boundary-derived; FORTH-TRACE
explicit regions), and predictions are evaluated at three layers:

  1. expert proposals   — the learned window classifier alone, turned into events by the same
                          excursion rule the HSMM uses (one event per same-class run of committed
                          windows, nearest-first merge of duplicates);
  2. Model A            — the CURRENT heuristic + HSMM (hsmm port, w_transition=0), fed the same
                          production-shaped inputs the phone feeds it: per-second gravity and
                          dynAccel streams derived from the IMU (exactly the strap channels the
                          decoder consumes in production) plus per-4 s imu-feat-1 windows;
  3. Model A+expert     — the same HSMM with the expert evidence attached (channel 4b, the Swift
                          wTransition 0.6), the actual integration being shipped.

Splits are PARTICIPANT-HELD-OUT (spec s12): train/test subjects never mix, and every metric is
reported per dataset and per sensor placement (wrist vs waist), because cross-placement transfer
is a first-class risk here (spec s11): a model that performs on HAPT (waist) but not on
FORTH-TRACE/WISDM (wrist) is not acceptable.

Timestamp honesty (spec s12): HSMM events live on a 1 s grid; expert windows on the training hop;
the 0.5 s tolerance cell is only meaningful with the 100 Hz refinement, which the expert proposals
carry when the refiner qualifies a peak.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from typing import Dict, List, Optional, Sequence, Tuple

import numpy as np

from . import transition_data as td
from .events import EVENT_KINDS, match_events, metrics, paired_participant_diffs
from .hsmm import HsmmDecoder
from .transition_features import window_transition_features
from .transition_refine import refine_event_ts

TAUS = (0.5, 1.0, 2.0, 5.0)
# The Swift evidence-channel weight (ActivityContextModel.wTransition); the shipped integration.
W_TRANSITION = 0.6
# HSMM event kinds carry the -Like suffix; the supervised ontology does not (kind map, not a new one).
_HSMM_KIND = {
    "sit_to_stand_like": "sit_to_stand",
    "stand_to_sit_like": "stand_to_sit",
    "lying_down_like": "lie_down",
    "getting_up_like": "get_up",
}


def _session_inputs(session, hop_s: float = 2.0):
    """Production-shaped inputs for one session: imu windows + per-second strap streams.

    The strap channels the decoder consumes in production (per-second gravity direction and
    dynAccel) are synthesized from the session IMU exactly the way the phone derives them: the
    gravity direction is the mean accelerometer direction over the second, dynAccel the RMS of the
    gravity-removed acceleration. Nothing is imputed from other sessions.
    """
    hz = float(session.hz)
    data = session.data
    n = data.shape[0]
    per_s = int(round(hz))
    seconds = n // per_s
    gravity = []
    dyn = []
    for s in range(seconds):
        seg = data[s * per_s:(s + 1) * per_s, 0:3]
        if seg.shape[0] < 4:
            continue
        mean = seg.mean(axis=0)
        gravity.append((s, float(mean[0]), float(mean[1]), float(mean[2])))
        ac = np.linalg.norm(seg - mean, axis=1)
        dyn.append((s, float(np.sqrt(np.square(ac).mean()))))
    return gravity, dyn


def _imu_feat_windows(session, window_s=4.0, hop_s=2.0):
    """imu-feat-1 windows for the HSMM (the same 4 s/2 s-hop grid production uses)."""
    from .features import window_features
    from .preprocess import Window
    from .transition_data import resample_window_to_30hz
    hz = float(session.hz)
    out = []
    for (start, end, data, label) in td.iter_windows(session, window_s=window_s, hop_s=hop_s):
        if end - start < window_s - 1e-6:
            continue  # trailing fragment; production windows are always full 4 s
        res = resample_window_to_30hz(data, hz)
        w = Window(s=start, e=end, data=res)
        out.append((int(round(start)), int(round(end)), window_features(w)))
    return out


def _expert_events(windows: Sequence[Tuple[float, float, object, object]], model, hz: float):
    """Turn per-window expert predictions into events: one per same-class excursion.

    Mirrors the HSMM excursion rule: a committed (non-abstaining, non-none) window starts or
    continues an excursion of its class; the event time is the refined 100 Hz timestamp when the
    refiner qualifies one, else the window center of the excursion's most confident window.
    Duplicate excursions of the same class within 3 s merge (nearest kept).
    """
    events: List[Dict] = []
    active: Dict[str, Optional[Dict]] = {k: None for k in EVENT_KINDS}
    for (start, end, data, _label) in windows:
        pred = model.predict_window(np.asarray(data), hz)
        if pred.abstained or pred.label in ("none", "unknown"):
            # any uncommitted window closes every open excursion (same as the HSMM's
            # mass-below-clear rule: an excursion is a contiguous run)
            for k in EVENT_KINDS:
                if active[k] is not None:
                    events.append(active[k])
                    active[k] = None
            continue
        kind = pred.label
        cur = active[kind]
        refined = None
        r = refine_event_ts(np.asarray(data), hz, float(start), kind)
        if r is not None:
            refined = r.ts
        if cur is None:
            active[kind] = {"kind": kind, "ts": refined if refined is not None
                            else float(start) + (end - start) / 2.0,
                            "prob": pred.confidence}
        else:
            if refined is not None:
                cur["ts"] = refined  # nearest-to-onset refined timestamp wins
            cur["prob"] = max(cur["prob"], pred.confidence)
    for k in EVENT_KINDS:
        if active[k] is not None:
            events.append(active[k])
    # duplicate merge: same kind within 3 s keeps the first
    merged: List[Dict] = []
    for ev in sorted(events, key=lambda e: (e["ts"], e["kind"])):
        dup = [m for m in merged if m["kind"] == ev["kind"] and abs(m["ts"] - ev["ts"]) <= 3.0]
        if dup:
            continue
        merged.append(ev)
    return merged


def _hsmm_events(session, imu_windows, transition_windows=None, w_transition: float = 0.0):
    """Run the HSMM port over one session and return canonical postural events."""
    gravity, dyn = _session_inputs(session)
    n_seconds = int(session.data.shape[0] / float(session.hz))
    decoder = HsmmDecoder()
    result = decoder.run(imu_windows, 0, n_seconds,
                        transition_windows=transition_windows,
                        w_transition=w_transition,
                        streams={"gravity": gravity, "dyn_accel": dyn})
    out = []
    for ev in result.events:
        kind = _HSMM_KIND.get(ev["kind"])
        if kind is None:
            continue  # locomotion edges stay the HSMM's own events, not this benchmark's unit
        out.append({"kind": kind, "ts": float(ev["ts"]), "prob": float(ev["prob"])})
    return out


def _load_sessions(args):
    pairs = []
    if args.hapt:
        pairs.append(("hapt", args.hapt))
    if args.pamap2:
        pairs.append(("pamap2", args.pamap2))
    if args.wisdm:
        pairs.append(("wisdm", args.wisdm))
    if args.forth:
        pairs.append(("forth", args.forth))
    sessions = []
    for name, root in pairs:
        loader = {"hapt": td.load_hapt, "pamap2": td.load_pamap2,
                  "wisdm": td.load_wisdm, "forth": td.load_forth_trace}[name]
        sessions.extend(loader(root))
    return sessions


def _predictor_from_artifact(path: str):
    from .transition_model import TransitionModel
    return TransitionModel.load(path)


def evaluate(sessions, model, hop_s: float = 2.0):
    """Run all three layers over every session; returns per-session event lists + hours."""
    per_session = []
    for s in sessions:
        hz = float(s.hz)
        # the SAME window grid feeds the expert and the HSMM's imu channel
        windows = list(td.iter_windows(s, window_s=4.0, hop_s=hop_s))
        expert = _expert_events(windows, model, hz)
        imu_feat = _imu_feat_windows(s, window_s=4.0, hop_s=hop_s)
        transition_windows = None
        if expert is not None:
            tw = []
            for (start, end, data, _label) in windows:
                pred = model.predict_window(np.asarray(data), hz)
                tw.append((int(round(start)), int(round(end)),
                           {"none": pred.probs.get("none", 0.0),
                            "sit_to_stand": pred.probs.get("sit_to_stand", 0.0),
                            "stand_to_sit": pred.probs.get("stand_to_sit", 0.0),
                            "lie_down": pred.probs.get("lie_down", 0.0),
                            "get_up": pred.probs.get("get_up", 0.0),
                            "confidence": pred.confidence,
                            "abstained": pred.abstained}))
            transition_windows = tw
        model_a = _hsmm_events(s, imu_feat, transition_windows=None, w_transition=0.0)
        model_ab = _hsmm_events(s, imu_feat, transition_windows=transition_windows,
                                w_transition=W_TRANSITION)
        gt = [{"kind": e.kind, "ts": e.ts} for e in s.events]
        hours = float(s.data.shape[0]) / hz / 3600.0
        per_session.append({"session": s.session_id, "subject": s.subject, "dataset": s.dataset,
                            "placement": s.placement, "hours": hours, "gt": gt,
                            "expert": expert, "model_a": model_a, "model_ab": model_ab})
    return per_session


def _report(per_session, taus=TAUS):
    """Aggregate event metrics per layer, per dataset, per placement; paired participant stats."""
    def _events(rows, layer):
        gt, pred = [], []
        for row in rows:
            gt.extend(row["gt"])
            pred.extend(row[layer])
        hours = sum(r["hours"] for r in rows)
        return metrics(gt, pred, taus=taus, hours=hours if hours > 0 else None)

    out: Dict[str, object] = {}
    for layer in ("expert", "model_a", "model_ab"):
        out[layer] = {
            "overall": _events(per_session, layer),
            "per_dataset": {ds: _events([r for r in per_session if r["dataset"] == ds], layer)
                            for ds in sorted({r["dataset"] for r in per_session})},
            "per_placement": {pl: _events([r for r in per_session if r["placement"] == pl], layer)
                              for pl in sorted({r["placement"] for r in per_session})},
        }
    # paired participant F1@1s / FP-per-hour between Model A and A+expert (the shipped comparison)
    for tau in (1.0, 2.0):
        fa, fab, fp_a, fp_ab = [], [], [], []
        for row in per_session:
            m_a = metrics(row["gt"], row["model_a"], taus=(tau,), hours=row["hours"])[tau]
            m_b = metrics(row["gt"], row["model_ab"], taus=(tau,), hours=row["hours"])[tau]
            fa.append(m_a["f1"])
            fab.append(m_b["f1"])
            fp_a.append(m_a["fp_per_hour"])
            fp_ab.append(m_b["fp_per_hour"])
        # Both diffs are (A+expert) - (Model A): positive F1 and negative FP/h mean the expert helps.
        f1_diff, f1_p = paired_participant_diffs(np.asarray(fab), np.asarray(fa))
        fp_diff, fp_p = paired_participant_diffs(np.asarray(fp_ab), np.asarray(fp_a))
        out[f"paired_tau_{tau}"] = {
            "model_a_f1_mean": float(np.mean(fa)),
            "model_ab_f1_mean": float(np.mean(fab)),
            "f1_diff_mean": f1_diff,
            "f1_p_value": f1_p,
            "fp_per_hour_diff_mean": fp_diff,
            "fp_p_value": fp_p,
        }
    return out


def main(argv=None) -> int:
    p = argparse.ArgumentParser(prog="activity-evaluate-transition",
                                 description=__doc__.splitlines()[0])
    p.add_argument("--hapt", help="HAPT dataset root (RawData/)")
    p.add_argument("--pamap2", help="PAMAP2 dataset root (Protocol/)")
    p.add_argument("--wisdm", help="WISDM dataset root (raw/watch under it)")
    p.add_argument("--forth", help="FORTH-TRACE root (research-licensed wrist sit/stand)")
    p.add_argument("--model", required=True, help="transition artifact (transition.json.gz)")
    p.add_argument("--hop-s", type=float, default=2.0, choices=(1.0, 2.0))
    p.add_argument("--out", help="write the JSON report here")
    args = p.parse_args(argv)

    sessions = _load_sessions(args)
    if not sessions:
        p.error("no sessions loaded (check dataset roots)")
    model = _predictor_from_artifact(args.model)
    per_session = evaluate(sessions, model, hop_s=args.hop_s)
    report = {
        "model": os.path.basename(args.model),
        "taus": list(TAUS),
        "w_transition": W_TRANSITION,
        "sessions": len(per_session),
        "subjects": len({r["subject"] for r in per_session}),
        "hours": sum(r["hours"] for r in per_session),
        "results": _report(per_session),
    }
    text = json.dumps(report, indent=2, sort_keys=True, default=float)
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
        print(f"wrote {args.out}", file=sys.stderr)
    print(text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

"""Pre-registered experiments (declared here BEFORE any test split is opened; spec §26).

``evaluate_heads`` refuses an experiment that is not in :data:`EXPERIMENTS` and any second evaluation of
one (TestVault ledger). Every bundle is a **stand-in shadow bundle** (``evidence_tier_max = "shadow"``):
none of these encoders is Inertia-1. The real ``inertia-1/...`` experiment is declared too and is blocked
until an official checkpoint exists.

Roles
-----
``ood_bench``   heads + OOD reference trained WITHOUT the ``ood_holdout`` activities; scored on held-out
                activities (selection = val subjects, report = test subjects) and Daphnet (non-wrist).
                Its VAL selection fixes the OOD method/k of the same encoder's primary bundle.
``primary``     the full procedure (arch selected by the CV rule) on all six CC BY wrist datasets.
``arch``        forced linear / MLP heads (the linear-vs-MLP ablation on test).
``window``      10 s windows (stand-in window benchmark; class heads only).
``lodo``        leave-one-dataset-out transfer.
``seed``        seeds 1, 2 of the primary hc procedure with the primary's selected architectures.

NC-SA experiments (``ncsa-*``, declared 2026-10-06 after the owner approved non-commercial use of GOTOV and WEAR,
CC BY-NC-SA 4.0, and BEFORE any of their test splits was opened): the same procedures on the eight wrist sets
:data:`WRIST_NC` (the six CC BY sets + GOTOV + WEAR), every one evaluated on the test subjects of all eight.
``ncsa-lodo-nonc-hc`` trains on the six CC BY sets only (the "without NC-SA data" reference on the same test
split, archs and OOD method fixed from ``ncsa-primary-hc`` / ``ncsa-ood-hc``); ``ncsa-lodo-nogotov-hc`` /
``ncsa-lodo-nowear-hc`` leave one NC-SA set out (its contribution on its own test subjects; the left-out set is
also scored as a held-out-dataset OOD probe). Their bundles record ``training_data_licences``.
"""

from __future__ import annotations

import os
from dataclasses import dataclass, field
from typing import Dict, Optional, Tuple

from .paths import bundles_root as _bundles_root

# $INERTIA_BUNDLES_DIR or $INERTIA_DATA_ROOT/inertia-bundles; "" when unconfigured (entry points refuse "").
BUNDLES_ROOT = _bundles_root()
EVAL_ROOT = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "eval", "inertia")

HC = "standin:handcrafted-stats-v1"
NF = "standin:nara-imu-feat-1-accel"
ART = "standin:inertia-arch-random-init/ar_transformer-small/seed0"
REAL = "inertia-1/ar_transformer-small/30s@20hz"
WRIST = ("capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity")     # CC BY 4.0
NC_SA = ("gotov", "wear")                                                                      # CC BY-NC-SA 4.0
WRIST_NC = WRIST + NC_SA
SHORT = {HC: "hc", NF: "nf", ART: "art", REAL: "inertia1"}
# leave-one-dataset-out experiments whose left-out dataset is also scored as a held-out-dataset OOD probe
HELDOUT_DATASET_OOD = {"lodo-nohhar-hc": "hhar_watch", "ncsa-lodo-nogotov-hc": "gotov", "ncsa-lodo-nowear-hc": "wear"}


@dataclass(frozen=True)
class Experiment:
    name: str
    encoder: str
    role: str
    window: str = "w30"
    train_datasets: Tuple[str, ...] = WRIST
    eval_datasets: Tuple[str, ...] = WRIST
    ood_holdout: bool = False
    arch: str = "select"                 # select | linear | mlp | from:<experiment>
    seed: int = 0
    transition: bool = True
    ood_from: Optional[str] = None       # ood_bench experiment whose VAL selection fixes the OOD method
    save_predictions: bool = False
    description: str = ""
    extra: Dict[str, str] = field(default_factory=dict)

    @property
    def bundle_id(self) -> str:
        return f"shadow-{self.name}"

    @property
    def datasets(self) -> Tuple[str, ...]:
        """Every dataset the experiment assembles (training first, then evaluation-only), in a stable order."""
        return tuple(dict.fromkeys(self.train_datasets + self.eval_datasets))

    @property
    def trn_window(self) -> Optional[str]:
        return "w30t" if self.transition and self.window == "w30" else None


def _primary(enc: str, **kw) -> Experiment:
    s = SHORT[enc]
    return Experiment(name=f"primary-{s}", encoder=enc, role="primary", ood_from=f"ood-{s}",
                      save_predictions=True, description=f"primary stand-in bundle ({s}); CV-selected head archs", **kw)


EXPERIMENTS: Dict[str, Experiment] = {e.name: e for e in [
    *[Experiment(name=f"ood-{SHORT[e]}", encoder=e, role="ood_bench", ood_holdout=True, arch="linear",
                 description="OOD benchmark bundle: ood_holdout activities withheld from every head and the reference")
      for e in (HC, NF, ART)],
    _primary(HC), _primary(NF), _primary(ART),
    *[Experiment(name=f"{a}-{SHORT[e]}", encoder=e, role="arch", arch=a, ood_from=f"ood-{SHORT[e]}",
                 description=f"forced {a} heads (linear-vs-MLP ablation)") for e in (HC, ART) for a in ("linear", "mlp")],
    Experiment(name="linear-nf", encoder=NF, role="arch", arch="linear", ood_from="ood-nf",
               description="nara-imu-feat-1-accel + linear probe (what the decoder already sees, LR baseline)"),
    Experiment(name="w10-hc", encoder=HC, role="window", window="w10", transition=False, ood_from="ood-hc",
               description="10 s windows, CV-selected archs (stand-in window benchmark; class heads + intensity)"),
    Experiment(name="lodo-noc24-hc", encoder=HC, role="lodo", arch="from:primary-hc", ood_from="ood-hc",
               train_datasets=tuple(d for d in WRIST if d != "capture24"),
               description="train without Capture-24 -> Capture-24 test (and the rest)"),
    Experiment(name="lodo-c24only-hc", encoder=HC, role="lodo", arch="from:primary-hc", ood_from="ood-hc",
               train_datasets=("capture24",), description="train on Capture-24 only -> other wrist test sets"),
    Experiment(name="lodo-nohhar-hc", encoder=HC, role="lodo", arch="from:primary-hc", ood_from="ood-hc",
               train_datasets=tuple(d for d in WRIST if d != "hhar_watch"),
               description="train without HHAR -> HHAR (device/population shift; also the OOD held-out dataset)"),
    *[Experiment(name=f"seed{k}-hc", encoder=HC, role="seed", seed=k, arch="from:primary-hc", ood_from="ood-hc",
                 description=f"primary hc procedure, seed {k}") for k in (1, 2)],
    Experiment(name="primary-inertia1", encoder=REAL, role="primary", ood_from=None, save_predictions=True,
               description="REAL Inertia-1 (blocked: no public checkpoint)"),
    # --- NC-SA (GOTOV + WEAR), declared 2026-10-06 before any of these test evaluations -------------------------
    *[Experiment(name=f"ncsa-ood-{SHORT[e]}", encoder=e, role="ood_bench", ood_holdout=True, arch="linear",
                 train_datasets=WRIST_NC, eval_datasets=WRIST_NC,
                 description="OOD benchmark bundle on the eight wrist sets incl. GOTOV/WEAR (CC BY-NC-SA 4.0)")
      for e in (HC, NF, ART)],
    *[Experiment(name=f"ncsa-primary-{SHORT[e]}", encoder=e, role="primary", ood_from=f"ncsa-ood-{SHORT[e]}",
                 train_datasets=WRIST_NC, eval_datasets=WRIST_NC,
                 description=f"primary stand-in bundle ({SHORT[e]}) on the eight wrist sets incl. GOTOV/WEAR "
                             "(CC BY-NC-SA 4.0); CV-selected head archs") for e in (HC, NF, ART)],
    Experiment(name="ncsa-lodo-nonc-hc", encoder=HC, role="lodo", arch="from:ncsa-primary-hc", ood_from="ncsa-ood-hc",
               train_datasets=WRIST, eval_datasets=WRIST_NC,
               description="without NC-SA data: train on the six CC BY sets -> the eight-set test (GOTOV/WEAR unseen)"),
    Experiment(name="ncsa-lodo-nogotov-hc", encoder=HC, role="lodo", arch="from:ncsa-primary-hc",
               ood_from="ncsa-ood-hc", train_datasets=WRIST + ("wear",), eval_datasets=WRIST_NC,
               description="train without GOTOV -> GOTOV test (GOTOV's contribution; older adults, measured MET)"),
    Experiment(name="ncsa-lodo-nowear-hc", encoder=HC, role="lodo", arch="from:ncsa-primary-hc",
               ood_from="ncsa-ood-hc", train_datasets=WRIST + ("gotov",), eval_datasets=WRIST_NC,
               description="train without WEAR -> WEAR test (WEAR's contribution; exercise_motion)"),
]}


def get_experiment(name: str) -> Experiment:
    if name not in EXPERIMENTS:
        raise KeyError(f"unknown experiment {name!r}; declared: {sorted(EXPERIMENTS)}")
    return EXPERIMENTS[name]


DECLARED = tuple(sorted(EXPERIMENTS))

# Decoder-replay TEST decodes (replay_eval final / baseline), pre-registered like the head experiments; each
# is opened through a TestVault with its own ledger (eval/inertia/replay_test_ledger.jsonl).
REPLAY_DATASETS = ("wisdm", "capture24")
REPLAY_DECLARED = tuple(sorted([f"replay-baseline/{d}" for d in REPLAY_DATASETS] +
                               [f"replay-final/{d}/{e.bundle_id}" for d in REPLAY_DATASETS
                                for e in EXPERIMENTS.values() if e.role == "primary"]))

__all__ = ["Experiment", "EXPERIMENTS", "DECLARED", "REPLAY_DECLARED", "get_experiment", "BUNDLES_ROOT", "EVAL_ROOT",
           "HC", "NF", "ART", "REAL", "WRIST", "NC_SA", "WRIST_NC", "SHORT", "HELDOUT_DATASET_OOD"]

"""wav2sleep with the REAL pinned checkpoint: identity, strict load, and parity with the official code.

Skipped unless ``FRWHOOP_WAV2SLEEP_MODEL_ROOT`` points at a model root holding the pinned
``wav2sleep/278e3046/{state_dict.pth,config.yaml}`` (the bytes are never committed). The parity
tests additionally need ``FRWHOOP_WAV2SLEEP_OFFICIAL_REFERENCE``: a directory of
``<fixture>_reference.npz`` written by the official-code reference run (the pinned upstream code
in its own locked environment; see docs/pretrained-models/WAV2SLEEP.md, "Parity").

Fixtures are SYNTHETIC. Parity says the adapter computes what the official code computes; it says
nothing about sleep-staging accuracy on WHOOP data.

Run with ``-s`` to see the printed parity and diagnostic numbers.
"""

import json
import os

import numpy as np
import pytest
import torch
import yaml

import wav2sleep_fixtures as F
import wav2sleep_helpers as H
from frwhoop_inference.frwhoop_sleep.wav2sleep import constants as C
from frwhoop_inference.frwhoop_sleep.wav2sleep import preprocessing as P
from frwhoop_inference.frwhoop_sleep.wav2sleep import runtime
from frwhoop_inference.frwhoop_sleep.wav2sleep.artifacts import load_model, verify_artifacts
from frwhoop_inference.frwhoop_sleep.wav2sleep.contract import parse_night
from frwhoop_inference.frwhoop_sleep.wav2sleep.provider import Wav2SleepPpgProvider

pytestmark = H.requires_real_weights()

#: name -> (builder, declared native rate): 25 Hz anchored v26 and the earlier 24 Hz convention.
FIXTURES = {name: (build, rate) for name, build, rate in F.PARITY_FIXTURES}


def _reference_dir():
    path = os.environ.get(H.REFERENCE_ENV)
    if not path or not os.path.isdir(path):
        pytest.skip(f"set {H.REFERENCE_ENV} to the official-code reference directory")
    return path


@pytest.fixture(scope="module")
def root():
    return H.real_model_root()


@pytest.fixture(scope="module")
def provider(root):
    runtime.clear_cache()
    return Wav2SleepPpgProvider(model_root=root, enabled=True, threads=1)


def _softmax(logits):
    shifted = logits - logits.max(axis=1, keepdims=True)
    exp = np.exp(shifted)
    return exp / exp.sum(axis=1, keepdims=True)


def test_real_artifacts_verify_and_load_strictly(root):
    verified = verify_artifacts(root)
    assert {n: a.sha256 for n, a in verified.items()} == {
        n: s["sha256"] for n, s in C.ARTIFACTS.items()}
    loaded = load_model(root)
    assert loaded.inventory["tensors"] == C.STATE_DICT_KEYS == 177
    assert loaded.inventory["parameters"] == C.STATE_DICT_PARAMETERS == 2_391_172
    assert loaded.inventory["valid_signals"] == ["ABD", "ECG", "PPG", "THX"]
    assert loaded.inventory["num_classes"] == 4 and loaded.inventory["signal_encoders_causal"] is False
    with open(verified["config.yaml"].path) as handle:
        assert yaml.safe_load(handle) == H.RELEASED_CONFIG, "the stand-in config must be the release"
    print(f"\n[wav2sleep] strict load: {loaded.inventory['tensors']} tensors, "
          f"{loaded.inventory['parameters']} params, load {loaded.load_seconds:.3f} s")


def test_enabled_readiness_and_runtime_identity_report_measured_digests(provider):
    report = provider.readiness()
    assert report["ready"] is True, report
    assert report["provenance"]["state_dict.pth"] == C.ARTIFACTS["state_dict.pth"]["sha256"]
    identity = provider.runtime_identity()
    assert identity["loaded"] is True
    assert identity["artifacts"]["state_dict.pth"]["sha256"] == C.ARTIFACTS["state_dict.pth"]["sha256"]
    assert identity["artifacts"]["config.yaml"]["size_bytes"] == 749
    assert len(identity["artifact_digest"]) == 64


@pytest.mark.parametrize("name", sorted(FIXTURES))
def test_forward_parity_with_the_official_code(provider, name):
    reference = np.load(os.path.join(_reference_dir(), f"{name}_reference.npz"))
    meta = json.loads(str(reference["meta"]))
    build, rate = FIXTURES[name]
    fixture = build(rate)
    assert meta["fixture"]["digest"] == F.run_digest(fixture), "the reference was built from other samples"
    assert meta["fixture"]["rate"] == rate
    assert meta["digests"] == {n: s["sha256"] for n, s in C.ARTIFACTS.items()}
    payload, ctx = F.payload(fixture), F.context(fixture)
    outcome = provider.stage(payload, ctx)
    night = parse_night(payload, ctx)
    rows = []
    for k, run in enumerate(night.runs):
        plan = P.plan_run(run)
        assert int(reference[f"run{k}_t0"]) == plan.t0
        resampled = P.resample_run(run, plan)
        assert np.array_equal(resampled, reference[f"run{k}_resampled"]), "resampling differs"
        previous = torch.get_num_threads()
        torch.set_num_threads(1)              # the reference z-score ran single-threaded
        try:
            zscored = P.normalize(resampled).numpy()
        finally:
            torch.set_num_threads(previous)
        z_diff = float(np.max(np.abs(zscored.astype(np.float64) - reference[f"run{k}_zscored"])))
        ref_logits = reference[f"run{k}_logits"].astype(np.float64)
        first = (plan.t0 - int(outcome["epoch_start"][0])) // 30
        mine_logits = outcome["logits"][first:first + plan.n_epochs]
        mine_probs = outcome["probabilities"][first:first + plan.n_epochs]
        prob_diff = float(np.max(np.abs(mine_probs - _softmax(ref_logits))))
        logit_diff = float(np.max(np.abs(mine_logits - ref_logits)))
        agree = int(np.sum(mine_logits.argmax(1) == ref_logits.argmax(1)))
        rows.append((k, plan.n_epochs, z_diff, logit_diff, prob_diff, agree))
        assert z_diff <= 2e-5 and logit_diff <= 1e-3 and prob_diff <= 1e-4
        assert agree == plan.n_epochs
        inf_diff = meta["runs"][k]["inf_route_max_abs_logit_diff"]
        assert inf_diff < 1e-4, "ABD/ECG/THX as -inf must match the absent route"
    for k, n, z, lg, pr, ag in rows:
        print(f"\n[wav2sleep parity] {name} ({rate} Hz) run{k}: epochs={n} max|dz|={z:.3g} "
              f"max|dlogit|={lg:.3g} max|dprob|={pr:.3g} argmax {ag}/{n} "
              f"(official -inf route max|dlogit| {meta['runs'][k]['inf_route_max_abs_logit_diff']:.3g})")
    if name.startswith("parity_8h"):
        pof = reference["pof_preds"]
        agree = int(np.sum(outcome["logits"].argmax(1) == pof))
        assert agree == pof.size == 960
        padded = reference["pof_preds_default10"]
        same = int(np.sum(padded[:960] == pof))
        print(f"[wav2sleep parity] predict_on_folder(signals=['PPG'], max_length_hours=8) argmax "
              f"{agree}/{pof.size}; pinned default max_length_hours=10 (2 h raw-zero padding) agrees "
              f"with the unpadded run on {same}/960 epochs (deviation D1)")


def test_real_weight_staging_is_deterministic_and_thread_count_is_rounding_only(root):
    fixture = F.parity_night_gap()
    one = Wav2SleepPpgProvider(model_root=root, enabled=True, threads=1)
    two = Wav2SleepPpgProvider(model_root=root, enabled=True, threads=2)
    a = one.stage(F.payload(fixture), F.context(fixture))
    b = one.stage(F.payload(fixture), F.context(fixture))
    assert np.array_equal(a["logits"], b["logits"], equal_nan=True)
    assert a["digests"] == b["digests"]
    c = two.stage(F.payload(fixture), F.context(fixture))
    m = a["mask"]
    diff = float(np.max(np.abs(a["probabilities"][m] - c["probabilities"][m])))
    agree = int(np.sum(a["logits"][m].argmax(1) == c["logits"][m].argmax(1)))
    print(f"\n[wav2sleep] threads 1 vs 2: max|dprob|={diff:.3g}, argmax {agree}/{int(m.sum())}")
    assert diff < 1e-3


def test_real_weight_response_on_a_gapped_night(provider):
    fixture = F.parity_night_gap()
    response = provider.infer(input=F.payload(fixture), context=F.context(fixture))
    assert response["status"] == "ok", response["diagnostics"]
    assert response["coverage"]["scored_epochs"] == 898
    labels = [v for v in response["raw_scores"]["labels"]["values"] if v is not None]
    counts = {label: labels.count(label) for label in C.CLASS_ORDER}
    print(f"\n[wav2sleep] synthetic gapped night label counts (meaningless as staging): {counts}")
    assert set(labels) <= set(C.CLASS_ORDER)


def test_diagnostics_polarity_and_affine_scaling(root):
    """Diagnostics, not gates: how much the output moves if the WHOOP polarity were flipped, and
    that the EDF branch's [-1, 1] physical-range scaling (not applied here) is irrelevant after the
    pinned z-score up to float32 rounding."""
    loaded = runtime.get_model(root)
    fixture = F.parity_night_8h()
    night = parse_night(F.payload(fixture), F.context(fixture))
    run = night.runs[0]
    plan = P.plan_run(run)
    signal = P.resample_run(run, plan)
    base, _ = runtime.run_ppg(loaded, signal, threads=1)
    flipped, _ = runtime.run_ppg(loaded, (-signal.astype(np.float64)).astype(np.float32), threads=1)
    scaled = ((signal.astype(np.float64) + 0.5) / 524_287.5).astype(np.float32)
    affine, _ = runtime.run_ppg(loaded, scaled, threads=1)
    pb, pf, pa = _softmax(base), _softmax(flipped), _softmax(affine)
    flip_agree = int(np.sum(base.argmax(1) == flipped.argmax(1)))
    affine_diff = float(np.max(np.abs(pb - pa)))
    affine_agree = int(np.sum(base.argmax(1) == affine.argmax(1)))
    print(f"\n[wav2sleep] polarity flip: argmax agreement {flip_agree}/{plan.n_epochs}, "
          f"max|dprob|={float(np.max(np.abs(pb - pf))):.3g}; EDF [-1,1] scaling: "
          f"max|dprob|={affine_diff:.3g}, argmax {affine_agree}/{plan.n_epochs}")
    assert affine_agree >= plan.n_epochs - 5

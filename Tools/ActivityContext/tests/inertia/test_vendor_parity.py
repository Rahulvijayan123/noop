"""Vendored encoders == upstream Inertia-1 encode(), bit for bit, on the same random state_dict.

Runs only when the upstream clone is present (``$INERTIA1_UPSTREAM_DIR``, or ``$INERTIA_DATA_ROOT/inertia1-upstream``)
and pytorch_lightning is importable (upstream modules subclass LightningModule). The vendored code itself
never imports Lightning. The required max |diff| is exactly 0: both sides run the same torch ops on the
same weights in the same process, so any nonzero difference means the vendored code diverged.
"""

import os
import sys
import warnings

import numpy as np
import pytest

torch = pytest.importorskip("torch")

from activity_context.inertia.paths import upstream_dir  # noqa: E402

UPSTREAM = upstream_dir()
if not UPSTREAM or not os.path.isfile(os.path.join(UPSTREAM, "inertia1", "methods", "ar_transformer_module.py")):
    pytest.skip(f"Inertia-1 upstream clone not found at {UPSTREAM}", allow_module_level=True)
pytest.importorskip("pytorch_lightning")

from activity_context.inertia import UPSTREAM_COMMIT  # noqa: E402
from activity_context.inertia.adapter import random_init_module  # noqa: E402
from activity_context.inertia.encoder_config import expected_arch  # noqa: E402


def _upstream():
    if UPSTREAM not in sys.path:
        sys.path.insert(0, UPSTREAM)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        from inertia1.methods.ar_transformer_module import ARTransformerModule
        from inertia1.methods.patchtst_module import PatchTSTModule
    return ARTransformerModule, PatchTSTModule


def _upstream_module(method, preset, window_s):
    ART, PTST = _upstream()
    arch = expected_arch(method, preset)
    data = {"axes": 3, "window_sec": window_s, "hz": 20}
    with warnings.catch_warnings():
        warnings.simplefilter("ignore")
        if method == "ar_transformer":
            params = {k: arch[k] for k in ("patch_len", "d_model", "n_layers", "n_heads", "d_ff", "dropout")}
            return ART({"method": {"params": params}, "data": data})
        model = {k: arch[k] for k in ("n_layers", "d_model", "n_heads", "d_ff", "norm", "attn_dropout", "dropout",
                                      "act", "res_attention", "pre_norm", "pe", "learn_pe", "head_dropout")}
        return PTST({"method": {"params": {"patch_len": 10, "stride": 10, "mask_ratio": 0.4}},
                     "model": {"params": model}, "data": data})


def test_upstream_clone_is_the_pinned_commit():
    head = os.path.join(UPSTREAM, ".git", "HEAD")
    if not os.path.isfile(head):
        pytest.skip("upstream clone has no .git metadata")
    import subprocess
    from activity_context.inertia.subproc import safe_env
    sha = subprocess.run(["git", "-C", UPSTREAM, "rev-parse", "HEAD"], capture_output=True, text=True,
                         env=safe_env()).stdout.strip()
    assert sha == UPSTREAM_COMMIT


@pytest.mark.parametrize("method,preset,window_s", [
    ("ar_transformer", "small", 30), ("ar_transformer", "small", 10),
    ("patchtst", "small", 30), ("patchtst", "small", 10),
    ("patchtst", "medium", 10),            # res_attention False path
])
def test_encode_is_identical_to_upstream(method, preset, window_s):
    vendored = random_init_module(method, expected_arch(method, preset), window_s, seed=11)
    upstream = _upstream_module(method, preset, window_s)
    upstream.load_state_dict(vendored.state_dict(), strict=True)                  # vendored -> upstream keys
    random_init_module(method, expected_arch(method, preset), window_s, seed=12).load_state_dict(
        upstream.state_dict(), strict=True)                                       # upstream -> vendored keys
    vendored.eval()
    upstream.eval()
    x = torch.from_numpy(np.random.default_rng(5).normal(0, 0.5, size=(6, 3, window_s * 20)).astype(np.float32))
    x[:, 2] += 1.0                                                                # gravity on z, like real data
    with torch.inference_mode():
        a = vendored.encode(x)
        b = upstream.encode(x)
    assert a.shape == (6, expected_arch(method, preset)["d_model"])
    diff = float((a - b).abs().max())
    assert diff == 0.0, f"expected bit-identical encode(), got max |vendored - upstream| = {diff}"

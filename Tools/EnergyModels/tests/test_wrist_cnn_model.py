"""Forward-pass tests for the numpy wrist CNN.

Everything above the "real weights" section needs no artifacts: it checks the layer semantics
(valid convolutions, ReLU, floor max-pooling, global max, softmax) against an independent
loop-based reference on a tiny network, plus batching / skip / NaN / shape handling. The real-weight
tests skip cleanly when the pinned artifacts have not been fetched.
"""

from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import numpy as np  # noqa: E402
import pytest  # noqa: E402

from energy_models.wrist_cnn import synthetic  # noqa: E402
from energy_models.wrist_cnn.fetch import DigestMismatchError, default_artifacts_dir, write_npz  # noqa: E402
from energy_models.wrist_cnn.inputs import to_upstream_layout  # noqa: E402
from energy_models.wrist_cnn.model import WristCNN  # noqa: E402
from energy_models.wrist_cnn.pins import PINS, NpzPin, PinSet  # noqa: E402
from energy_models.wrist_cnn.spec import HEADS, REAL_ARCH, head_units, parameter_count  # noqa: E402
from energy_models.wrist_cnn.testing import TINY_ARCH, naive_forward, random_weights, random_windows  # noqa: E402

GOLDEN = Path(__file__).parent / "fixtures" / "wrist_cnn_golden.npz"


def tiny(head: str, seed: int = 0, dtype=np.float32) -> WristCNN:
    return WristCNN(random_weights(TINY_ARCH, head_units(head), seed), head, arch=TINY_ARCH, dtype=dtype)


# --------------------------------------------------------------------- semantics on a tiny network


@pytest.mark.parametrize("head", HEADS)
def test_tiny_matches_independent_loop_reference(head):
    weights = random_weights(TINY_ARCH, head_units(head), seed=3)
    net = WristCNN(weights, head, arch=TINY_ARCH)
    x = random_windows(TINY_ARCH, 5, seed=4)
    got = net.predict_raw(x)
    want = np.stack([naive_forward(weights, TINY_ARCH, head, w) for w in x])
    np.testing.assert_allclose(got, want, rtol=2e-5, atol=2e-5)


@pytest.mark.parametrize("head", HEADS)
def test_tiny_float64_matches_reference_tightly(head):
    weights = random_weights(TINY_ARCH, head_units(head), seed=5)
    net = WristCNN(weights, head, arch=TINY_ARCH, dtype=np.float64)
    x = random_windows(TINY_ARCH, 3, seed=6, scale=3.0)
    want = np.stack([naive_forward(weights, TINY_ARCH, head, w) for w in x])
    np.testing.assert_allclose(net.predict_raw(x), want, rtol=1e-10, atol=1e-10)


def test_stage_shapes_follow_valid_conv_and_floor_pool():
    net = tiny("regression")
    stages = net.forward_stages(random_windows(TINY_ARCH, 1)[0])
    expected = TINY_ARCH.stage_lengths()
    got = [(n, a.shape[0]) for n, a in stages if n.startswith(("conv", "pool"))]
    assert got == expected
    # 67 -> floor(67 / 3) = 22: the trailing step is dropped, not padded
    assert dict(expected)["pool_after_conv2"] == 22 and dict(expected)["conv2"] == 67
    assert stages[-3][0] == "global_max" and stages[-3][1].shape == (TINY_ARCH.filters[-1],)


def test_relu_makes_every_conv_stage_nonnegative_and_global_max_is_maximum():
    net = tiny("regression", seed=2)
    stages = dict(net.forward_stages(random_windows(TINY_ARCH, 1, seed=9)[0]))
    for name, act in stages.items():
        if name.startswith(("conv", "pool", "global")):
            assert (act >= 0).all(), name
    np.testing.assert_array_equal(stages["global_max"], stages["conv6"].max(axis=0))


def test_convolution_is_cross_correlation_not_flipped():
    weights = random_weights(TINY_ARCH, 1, seed=7)
    for i in range(1, 7):
        weights[f"conv{i}_bias"][:] = 0.0
    net = WristCNN(weights, "regression", arch=TINY_ARCH)
    x = random_windows(TINY_ARCH, 1, seed=8)[0]
    conv1 = dict(net.forward_stages(x))["conv1"]
    ker = weights["conv1_kernel"]                          # [k, cin, cout]
    t = 11
    manual = np.maximum(sum(x[t + dk] @ ker[dk] for dk in range(ker.shape[0])), 0.0)
    np.testing.assert_allclose(conv1[t], manual, rtol=1e-5, atol=1e-6)
    flipped = np.maximum(sum(x[t + dk] @ ker[::-1][dk] for dk in range(ker.shape[0])), 0.0)
    assert not np.allclose(conv1[t], flipped, atol=1e-4)


def test_classification_head_returns_probabilities():
    net = tiny("classification", seed=11)
    p = net.predict(random_windows(TINY_ARCH, 6, seed=12, scale=5.0))
    assert p.shape == (6, 3)
    np.testing.assert_allclose(p.sum(axis=1), 1.0, atol=1e-6)
    assert (p >= 0).all()
    np.testing.assert_array_equal(net.predict_class(random_windows(TINY_ARCH, 6, seed=12, scale=5.0)), p.argmax(axis=1))


def test_softmax_is_stable_for_large_logits():
    weights = random_weights(TINY_ARCH, 3, seed=1)
    weights["dense_kernel"] *= 1e4
    net = WristCNN(weights, "classification", arch=TINY_ARCH)
    p = net.predict(random_windows(TINY_ARCH, 4, seed=2, scale=2.0))
    assert np.isfinite(p).all()
    np.testing.assert_allclose(p.sum(axis=1), 1.0, atol=1e-6)


def test_regression_head_output_is_raw_and_can_fall_below_one_met():
    weights = random_weights(TINY_ARCH, 1, seed=1)
    weights["dense_bias"][:] = -5.0
    net = WristCNN(weights, "regression", arch=TINY_ARCH)
    assert (net.predict(random_windows(TINY_ARCH, 3)) < 1.0).all()


# --------------------------------------------------------------------- batching, skip, validation


@pytest.mark.parametrize("head", HEADS)
def test_batching_is_equivalent_to_single_window_calls(head):
    net = tiny(head, seed=21)
    x = random_windows(TINY_ARCH, 7, seed=22)
    single = np.concatenate([net.predict_raw(x[i : i + 1], batch_size=1) for i in range(len(x))])
    for bs in (1, 2, 3, 7, 64):
        np.testing.assert_allclose(net.predict_raw(x, batch_size=bs), single, rtol=1e-6, atol=1e-6)


def test_window_order_does_not_matter():
    net = tiny("regression", seed=23)
    x = random_windows(TINY_ARCH, 6, seed=24)
    perm = np.random.default_rng(0).permutation(6)
    np.testing.assert_allclose(net.predict(x)[perm], net.predict(x[perm]), rtol=1e-6, atol=1e-6)


def test_skip_mask_leaves_nan_rows_and_does_not_change_the_others():
    net = tiny("regression", seed=25)
    x = random_windows(TINY_ARCH, 6, seed=26)
    skip = np.array([False, True, False, False, True, False])
    full = net.predict(x)
    part = net.predict(x, skip=skip)
    assert np.isnan(part[skip]).all()
    np.testing.assert_allclose(part[~skip], full[~skip], rtol=1e-6, atol=1e-6)
    assert np.isnan(net.predict(x, skip=np.ones(6, bool))).all()


def test_skip_mask_shape_is_validated():
    net = tiny("regression")
    with pytest.raises(ValueError, match="skip"):
        net.predict(random_windows(TINY_ARCH, 3), skip=np.zeros(2, bool))


def test_skipped_windows_may_contain_nan_without_raising():
    net = tiny("regression")
    x = random_windows(TINY_ARCH, 3)
    x[1] = np.nan
    out = net.predict(x, skip=np.array([False, True, False]))
    assert np.isnan(out[1]) and np.isfinite(out[[0, 2]]).all()


def test_nan_and_inf_windows_raise_by_default_and_give_nan_when_asked():
    net = tiny("regression", seed=27)
    x = random_windows(TINY_ARCH, 4, seed=28)
    clean = net.predict(x)
    bad = x.copy()
    bad[1, 5, 0] = np.nan
    bad[3, 0, 2] = np.inf
    with pytest.raises(ValueError, match="2 window"):
        net.predict(bad)
    out = net.predict(bad, on_invalid="nan")
    assert np.isnan(out[[1, 3]]).all()
    np.testing.assert_allclose(out[[0, 2]], clean[[0, 2]], rtol=1e-6, atol=1e-6)
    with pytest.raises(ValueError, match="on_invalid"):
        net.predict(x, on_invalid="ignore")


@pytest.mark.parametrize(
    "shape",
    [(3, TINY_ARCH.window_samples), (2, TINY_ARCH.window_samples, 2), (2, TINY_ARCH.window_samples + 1, 3), (TINY_ARCH.window_samples, 3)],
)
def test_wrong_shapes_are_rejected(shape):
    net = tiny("regression")
    with pytest.raises(ValueError, match="shape"):
        net.predict(np.zeros(shape, np.float32))


def test_non_numeric_input_is_rejected():
    net = tiny("regression")
    with pytest.raises(ValueError, match="numeric"):
        net.predict(np.full((1, TINY_ARCH.window_samples, 3), "x", dtype=object))


def test_empty_batch_returns_empty_output():
    assert tiny("regression").predict(np.zeros((0, TINY_ARCH.window_samples, 3), np.float32)).shape == (0,)
    assert tiny("classification").predict(np.zeros((0, TINY_ARCH.window_samples, 3), np.float32)).shape == (0, 3)


def test_integer_and_float64_inputs_are_accepted():
    net = tiny("regression", seed=29)
    x = random_windows(TINY_ARCH, 2, seed=30)
    np.testing.assert_allclose(net.predict(x.astype(np.float64)), net.predict(x), rtol=1e-6, atol=1e-6)
    net.predict(np.round(x * 10).astype(np.int16))


def test_batch_size_must_be_positive():
    with pytest.raises(ValueError, match="batch_size"):
        tiny("regression").predict(random_windows(TINY_ARCH, 1), batch_size=0)


def test_predict_class_is_classification_only():
    with pytest.raises(ValueError, match="classification"):
        tiny("regression").predict_class(random_windows(TINY_ARCH, 1))
    cls = tiny("classification").predict_class(random_windows(TINY_ARCH, 3), skip=np.array([False, True, False]))
    assert cls.dtype == np.int8 and cls[1] == -1 and (cls[[0, 2]] >= 0).all()


def test_overflowing_inputs_raise_instead_of_returning_garbage():
    net = tiny("regression", seed=31)
    with pytest.raises(FloatingPointError):
        net.predict(random_windows(TINY_ARCH, 1, scale=1e38))


def test_threads_do_not_share_scratch_buffers():
    from concurrent.futures import ThreadPoolExecutor

    net = tiny("regression", seed=32)
    x = random_windows(TINY_ARCH, 24, seed=33)
    want = net.predict(x)
    with ThreadPoolExecutor(4) as pool:
        parts = list(pool.map(lambda s: net.predict(x[s : s + 6]), range(0, 24, 6)))
    np.testing.assert_allclose(np.concatenate(parts), want, rtol=1e-6, atol=1e-6)


# --------------------------------------------------------------------- weight validation and loading


def test_weight_set_and_shapes_are_validated():
    w = random_weights(TINY_ARCH, 1)
    missing = {k: v for k, v in w.items() if k != "conv3_bias"}
    with pytest.raises(ValueError, match="missing"):
        WristCNN(missing, "regression", arch=TINY_ARCH)
    with pytest.raises(ValueError, match="unexpected"):
        WristCNN({**w, "extra": np.zeros(1, np.float32)}, "regression", arch=TINY_ARCH)
    wrong = dict(w, dense_kernel=np.zeros((9, 3), np.float32))
    with pytest.raises(ValueError, match="dense_kernel"):
        WristCNN(wrong, "regression", arch=TINY_ARCH)
    nan = dict(w)
    nan["conv1_kernel"] = w["conv1_kernel"].copy()
    nan["conv1_kernel"][0, 0, 0] = np.nan
    with pytest.raises(ValueError, match="non-finite"):
        WristCNN(nan, "regression", arch=TINY_ARCH)
    with pytest.raises(ValueError, match="head"):
        WristCNN.load("bogus", None)


def _tiny_artifacts(tmp_path, head="regression"):
    weights = random_weights(TINY_ARCH, head_units(head), seed=40)
    name = f"tiny_{head}.npz"
    write_npz(tmp_path / name, weights)
    import hashlib

    blob = (tmp_path / name).read_bytes()
    pins = PinSet(upstream=PINS.upstream, npz={**PINS.npz, head: NpzPin(name, len(blob), hashlib.sha256(blob).hexdigest())})
    return pins, weights


def test_load_accepts_the_pinned_bytes_and_reproduces_the_weights(tmp_path):
    pins, weights = _tiny_artifacts(tmp_path)
    net = WristCNN.load("regression", tmp_path, pins=pins, arch=TINY_ARCH)
    x = random_windows(TINY_ARCH, 2)
    np.testing.assert_allclose(net.predict(x), WristCNN(weights, "regression", arch=TINY_ARCH).predict(x), rtol=0, atol=0)


def test_load_refuses_a_modified_file(tmp_path):
    pins, _ = _tiny_artifacts(tmp_path)
    path = tmp_path / pins.npz["regression"].filename
    data = bytearray(path.read_bytes())
    data[len(data) // 2] ^= 0x01
    path.write_bytes(bytes(data))
    with pytest.raises(DigestMismatchError):
        WristCNN.load("regression", tmp_path, pins=pins, arch=TINY_ARCH)


def test_load_refuses_a_truncated_file_and_an_unpinned_one(tmp_path):
    pins, _ = _tiny_artifacts(tmp_path)
    path = tmp_path / pins.npz["regression"].filename
    path.write_bytes(path.read_bytes()[:-100])
    with pytest.raises(DigestMismatchError, match="size"):
        WristCNN.load("regression", tmp_path, pins=pins, arch=TINY_ARCH)
    unpinned = PinSet(upstream=pins.upstream, npz={**pins.npz, "regression": NpzPin(pins.npz["regression"].filename, 0, "")})
    with pytest.raises(Exception, match="no sha256 pin"):
        WristCNN.load("regression", tmp_path, pins=unpinned, arch=TINY_ARCH)


def test_load_reports_how_to_fetch_when_the_artifact_is_missing(tmp_path):
    with pytest.raises(FileNotFoundError, match="fetch"):
        WristCNN.load("regression", tmp_path)


# --------------------------------------------------------------------- real pinned weights (skip if absent)


def _artifacts_present() -> bool:
    d = default_artifacts_dir()
    return all((d / PINS.npz[h].filename).exists() for h in HEADS)


needs_artifacts = pytest.mark.skipif(not _artifacts_present(), reason="pinned artifacts not fetched (scripts/fetch_wrist_cnn.sh)")


@pytest.fixture(scope="module")
def real():
    return {h: WristCNN.load(h) for h in HEADS}


def golden_windows():
    z = np.load(GOLDEN, allow_pickle=False)
    natural = z["counts"].astype(np.float32) * np.float32(z["quantum_g"])
    return to_upstream_layout(natural), z["met_expected"], z["proba_expected"]


def test_golden_fixture_is_small_synthetic_and_not_weights():
    assert GOLDEN.exists(), (
        f"{GOLDEN} is missing. If it exists on disk but is untracked, the repository .gitignore rule `Fixtures/` "
        "matches it on case-insensitive filesystems; add an exception for Tools/EnergyModels/tests/fixtures/."
    )
    assert GOLDEN.stat().st_size < 300_000
    z = np.load(GOLDEN, allow_pickle=False)
    assert z["counts"].shape[0] <= 3
    assert not any(k.startswith(("conv", "dense")) for k in z.files)


@needs_artifacts
def test_numpy_matches_keras_reference_on_golden_windows(real):
    windows, met_expected, proba_expected = golden_windows()
    np.testing.assert_allclose(real["regression"].predict(windows), met_expected, rtol=0, atol=1e-4)
    np.testing.assert_allclose(real["classification"].predict(windows), proba_expected, rtol=0, atol=1e-4)


@needs_artifacts
def test_golden_windows_have_the_expected_ordering(real):
    windows, _, _ = golden_windows()
    met = real["regression"].predict(windows)
    assert met[0] < met[2] and met[1] < met[2]
    assert 1.2 < met[0] < 1.6


@needs_artifacts
def test_real_parameter_counts_and_stage_shapes(real):
    for head, net in real.items():
        n_params = sum(a.size for a in net._conv_w) + sum(a.size for a in net._conv_b) + net._dense_w.size + net._dense_b.size
        assert n_params == parameter_count(head)
    assert parameter_count("regression") == 1_455_621 and parameter_count("classification") == 1_456_103
    window = synthetic.oscillating_window(1)
    stages = real["regression"].forward_stages(to_upstream_layout(window[None])[0])
    shapes = [(n, a.shape[0]) for n, a in stages if n.startswith(("conv", "pool"))]
    assert shapes == REAL_ARCH.stage_lengths()
    assert dict(shapes)["pool_after_conv4"] == 658 and dict(shapes)["conv6"] == 640


@needs_artifacts
def test_real_batching_and_skip_equivalence(real):
    windows = to_upstream_layout(np.stack([synthetic.still_window(1), synthetic.oscillating_window(2), synthetic.running_window(3), synthetic.still_window(4), synthetic.oscillating_window(5)]))
    net = real["regression"]
    single = np.concatenate([net.predict(windows[i : i + 1], batch_size=1) for i in range(5)])
    np.testing.assert_allclose(net.predict(windows, batch_size=5), single, rtol=1e-6, atol=1e-6)
    skip = np.array([True, False, False, True, False])
    out = net.predict(windows, skip=skip)
    assert np.isnan(out[skip]).all()
    np.testing.assert_allclose(out[~skip], single[~skip], rtol=1e-6, atol=1e-6)


@needs_artifacts
def test_convenience_functions_use_the_verified_cache():
    from energy_models.wrist_cnn.model import load_model, predict_met, predict_proba

    windows, met_expected, proba_expected = golden_windows()
    np.testing.assert_allclose(predict_met(windows), met_expected, atol=1e-4)
    np.testing.assert_allclose(predict_proba(windows), proba_expected, atol=1e-4)
    assert load_model("regression") is load_model("regression")


@needs_artifacts
def test_optional_live_keras_parity(real):
    """Full numpy-vs-Keras comparison; runs only where tf_keras and the verified upstream .h5 files exist."""
    pytest.importorskip("tensorflow")
    tf_keras = pytest.importorskip("tf_keras")
    from energy_models.wrist_cnn.fetch import verify_file

    art = default_artifacts_dir()
    rng = np.random.default_rng(0)
    gaussian = to_upstream_layout((rng.normal(0, 0.3, size=(3, 6000, 3)) + np.array([0.0, 0.0, 1.0])).astype(np.float32))
    windows = np.concatenate([golden_windows()[0], gaussian])
    for head in HEADS:
        entry = PINS.upstream[head]
        h5 = art / "upstream" / entry.basename
        if not h5.exists():
            pytest.skip("upstream .h5 not cached")
        verify_file(h5, entry.sha256, entry.size)
        model = tf_keras.models.load_model(str(h5), compile=False)
        ref = np.asarray(model.predict(windows.reshape(len(windows), -1), verbose=0))
        np.testing.assert_allclose(real[head].predict_raw(windows), ref, rtol=0, atol=1e-4)

"""Input adapter (``prepare_windows``, layouts, quiet mask) and OOD-signal tests; synthetic data only."""

from __future__ import annotations

import sys
import warnings
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import numpy as np  # noqa: E402
import pytest  # noqa: E402

from energy_models.wrist_cnn import ood, synthetic  # noqa: E402
from energy_models.wrist_cnn.fetch import default_artifacts_dir  # noqa: E402
from energy_models.wrist_cnn.inputs import (  # noqa: E402
    QUIET_MET_BASELINE,
    apply_axis_transform,
    axes_major,
    from_upstream_layout,
    prepare_windows,
    quiet_mask,
    regularize_timestamps,
    to_upstream_layout,
)
from energy_models.wrist_cnn.pins import PINS  # noqa: E402
from energy_models.wrist_cnn.spec import HEADS  # noqa: E402

FS, W = 100, 6000


def ramp_recording(n_windows: int, extra: int = 0) -> np.ndarray:
    """x ramps 0..2 g inside every 60 s block, y and z constant: easy to check exactly."""
    n = n_windows * W + extra
    t = np.arange(n)
    return np.stack([(t % W) / W * 2.0, np.full(n, 0.5), np.full(n, 0.25)], axis=1).astype(np.float32)


# --------------------------------------------------------------------- layout


def test_upstream_layout_is_the_three_axes_concatenated_in_time():
    rng = np.random.default_rng(0)
    nat = rng.normal(size=(2, W, 3)).astype(np.float32)
    up = to_upstream_layout(nat)
    flat = up.reshape(2, -1)
    np.testing.assert_array_equal(flat[:, :W], nat[:, :, 0])
    np.testing.assert_array_equal(flat[:, W : 2 * W], nat[:, :, 1])
    np.testing.assert_array_equal(flat[:, 2 * W :], nat[:, :, 2])
    np.testing.assert_array_equal(up[0, 0], flat[0, :3])           # row r = flat[3r:3r+3]
    np.testing.assert_array_equal(from_upstream_layout(up), nat)
    np.testing.assert_array_equal(axes_major(up, "upstream"), np.swapaxes(nat, 1, 2))
    np.testing.assert_array_equal(axes_major(nat, "natural"), np.swapaxes(nat, 1, 2))


def test_layout_helpers_validate_shapes():
    with pytest.raises(ValueError):
        to_upstream_layout(np.zeros((2, W, 2), np.float32))
    with pytest.raises(ValueError):
        from_upstream_layout(np.zeros((W, 3), np.float32))
    with pytest.raises(ValueError):
        axes_major(np.zeros((1, W, 3)), "bogus")


def test_apply_axis_transform_is_a_matrix_product_without_fp_warnings():
    rng = np.random.default_rng(1)
    acc = rng.normal(size=(50, 3)).astype(np.float32)
    acc[3] = np.nan
    r = np.array([[0, 1, 0], [-1, 0, 0], [0, 0, 1]], float)
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        out = apply_axis_transform(acc, r)
    np.testing.assert_allclose(out[0], r @ acc[0], atol=1e-6)
    assert np.isnan(out[3]).all()
    with pytest.raises(ValueError):
        apply_axis_transform(acc, np.eye(2))


# --------------------------------------------------------------------- prepare_windows


def test_windows_are_contiguous_non_overlapping_minutes_in_upstream_layout():
    acc = ramp_recording(3, extra=150)
    pw = prepare_windows(acc)
    assert pw.n == 3 and pw.windows.shape == (3, W, 3) and pw.windows.dtype == np.float32
    np.testing.assert_array_equal(pw.start_index, [0, W, 2 * W])
    assert pw.valid.all() and (pw.missing_fraction == 0).all() and (pw.longest_gap == 0).all()
    assert pw.layout == "upstream" and pw.step_samples == W
    np.testing.assert_array_equal(pw.windows[1], to_upstream_layout(acc[W : 2 * W][None])[0])
    np.testing.assert_allclose(pw.start_time_s(), [0.0, 60.0, 120.0])


def test_half_overlap_step_reproduces_the_training_stride():
    acc = np.random.default_rng(2).normal(size=(3 * W, 3)).astype(np.float32)
    pw = prepare_windows(acc, step_s=30)
    assert pw.n == 5
    nat = from_upstream_layout(pw.windows)
    np.testing.assert_array_equal(nat[1][:3000], nat[0][3000:])
    np.testing.assert_array_equal(nat[2][:3000], nat[1][3000:])


def test_start_offset_and_short_inputs():
    acc = ramp_recording(2)
    np.testing.assert_array_equal(prepare_windows(acc, start=1000).start_index, [1000])
    empty = prepare_windows(acc[: W - 1])
    assert empty.n == 0 and empty.windows.shape == (0, W, 3) and empty.valid.shape == (0,)
    with pytest.raises(ValueError, match="start"):
        prepare_windows(acc, start=-1)


def test_short_gaps_are_interpolated_and_long_or_numerous_gaps_invalidate_the_window():
    acc = ramp_recording(5)
    acc[100:130, :] = np.nan                                       # window 0: one 0.30 s gap -> valid
    acc[W + 200 : W + 260, :] = np.nan                             # window 1: one 0.60 s gap -> invalid (> 0.5 s)
    for k in range(4):                                             # window 2: 4 x 0.4 s = 2.7% missing -> valid
        s = 2 * W + 500 + 1000 * k
        acc[s : s + 40, :] = np.nan
    for k in range(10):                                            # window 3: 10 x 0.4 s = 6.7% missing -> invalid
        s = 3 * W + 100 + 500 * k
        acc[s : s + 40, :] = np.nan
    acc[4 * W : 5 * W, :] = np.nan                                 # window 4: nothing at all
    pw = prepare_windows(acc)
    assert pw.valid.tolist() == [True, False, True, False, False]
    assert pw.longest_gap.tolist() == [30, 60, 40, 40, W]
    np.testing.assert_allclose(pw.missing_fraction, [30 / W, 60 / W, 160 / W, 400 / W, 1.0], rtol=1e-6)
    clean = ramp_recording(5)
    np.testing.assert_allclose(from_upstream_layout(pw.windows)[0], clean[:W], atol=1e-5)   # linear ramp is interpolated exactly
    np.testing.assert_allclose(from_upstream_layout(pw.windows)[2], clean[2 * W : 3 * W], atol=1e-5)
    assert np.isfinite(pw.windows[[0, 2]]).all()
    assert np.isnan(pw.windows[[1, 3, 4]]).any(axis=(1, 2)).all()                      # invalid windows keep their NaNs


def test_nans_at_the_window_edges_are_filled_with_the_nearest_value():
    acc = ramp_recording(1)
    acc[:10, :] = np.nan
    acc[-10:, :] = np.nan
    pw = prepare_windows(acc)
    assert pw.valid[0]
    nat = from_upstream_layout(pw.windows)[0]
    np.testing.assert_allclose(nat[:10, 0], acc[10, 0])
    np.testing.assert_allclose(nat[-10:, 0], acc[-11, 0])


def test_partially_missing_axes_count_as_missing_samples():
    acc = ramp_recording(1)
    acc[300:310, 1] = np.nan
    pw = prepare_windows(acc)
    assert pw.longest_gap[0] == 10 and pw.valid[0] and np.isfinite(pw.windows).all()


def test_values_beyond_the_sensor_range_are_clipped_and_counted():
    acc = ramp_recording(1)
    acc[:60, 2] = 20.0
    acc[100:110, 0] = -15.0
    pw = prepare_windows(acc)
    nat = from_upstream_layout(pw.windows)[0]
    assert nat.max() == 8.0 and nat.min() == -8.0
    assert pw.clipped_fraction[0] == pytest.approx(70 / W, rel=1e-6)
    unclipped = prepare_windows(acc, clip_g=None)
    assert from_upstream_layout(unclipped.windows)[0].max() == 20.0 and unclipped.clipped_fraction[0] == 0


def test_axis_transform_is_applied_before_windowing_and_tolerates_nan():
    acc = ramp_recording(1)
    acc[5:8, :] = np.nan
    r = np.array([[0, 1, 0], [1, 0, 0], [0, 0, -1]], float)
    with warnings.catch_warnings():
        warnings.simplefilter("error")
        pw = prepare_windows(acc, axis_transform=r)
    nat = from_upstream_layout(pw.windows)[0]
    np.testing.assert_allclose(nat[100], [acc[100, 1], acc[100, 0], -acc[100, 2]], atol=1e-6)
    assert pw.valid[0]


def test_irregular_timestamps_are_resampled_onto_the_uniform_grid():
    rng = np.random.default_rng(3)
    n = 2 * W + 300
    t = np.arange(n) / FS + rng.uniform(-0.002, 0.002, size=n)
    t.sort()
    sig = lambda tt: 0.5 * np.sin(2 * np.pi * 1.0 * tt)  # noqa: E731
    acc = np.stack([sig(t), np.full(n, 0.2), np.full(n, 0.9)], axis=1).astype(np.float32)
    pw = prepare_windows(acc, timestamps=t)
    assert pw.n == 2 and pw.valid.all()
    assert pw.grid_t0 == pytest.approx(float(t[0]))
    np.testing.assert_allclose(pw.start_time_s(), t[0] + np.array([0.0, 60.0]))
    grid = t[0] + np.arange(W) / FS
    np.testing.assert_allclose(from_upstream_layout(pw.windows)[0][:, 0], sig(grid), atol=1.5e-3)


def test_a_dropped_packet_run_invalidates_only_the_affected_window():
    t = np.arange(3 * W) / FS
    acc = np.tile(np.array([0.1, 0.2, 0.97], np.float32), (len(t), 1))
    keep = ~((t >= 70.0) & (t < 71.0))                              # 1 s hole inside window 1
    pw = prepare_windows(acc[keep], timestamps=t[keep])
    assert pw.valid.tolist() == [True, False, True]
    assert pw.longest_gap[1] >= 90


def test_timestamp_input_is_validated():
    acc = ramp_recording(1)
    t = np.arange(len(acc)) / FS
    with pytest.raises(ValueError, match="sorted"):
        regularize_timestamps(t[::-1], acc)
    with pytest.raises(ValueError):
        regularize_timestamps(t[:-1], acc)
    with pytest.raises(ValueError, match="two"):
        regularize_timestamps(t[:1], acc[:1])
    dup = np.concatenate([t[:50], t[49:]])
    _, grid = regularize_timestamps(dup, np.concatenate([acc[:50], acc[49:]]))
    assert np.isfinite(grid).all()


def test_window_length_and_layout_rules():
    acc = ramp_recording(2)
    nat = prepare_windows(acc, window_s=10, step_s=10, layout="natural")
    assert nat.windows.shape == (12, 1000, 3) and nat.layout == "natural"
    np.testing.assert_array_equal(nat.windows[0], acc[:1000])
    with pytest.raises(ValueError, match="6000"):
        prepare_windows(acc, window_s=10, step_s=10)
    with pytest.raises(ValueError, match="whole"):
        prepare_windows(acc, window_s=60.003)
    with pytest.raises(ValueError, match="layout"):
        prepare_windows(acc, layout="bogus")
    with pytest.raises(ValueError, match="x, y, z"):
        prepare_windows(acc[:, :2])


# --------------------------------------------------------------------- quiet mask


def test_quiet_mask_selects_motionless_gravity_consistent_windows_only():
    still = synthetic.still_window(1)
    walk = synthetic.oscillating_window(1)
    flat = synthetic.flat_window(1)
    nan = synthetic.nan_window(1)
    scaled = still * 9.80665
    no_gravity = still - still.mean(axis=0)
    nat = np.stack([still, walk, flat, nan, scaled, no_gravity])
    for layout, w in (("natural", nat), ("upstream", to_upstream_layout(nat))):
        assert quiet_mask(w, layout).tolist() == [True, False, True, False, False, False]
    assert quiet_mask(np.zeros((0, W, 3), np.float32)).shape == (0,)
    with pytest.raises(ValueError):
        quiet_mask(np.zeros((1, W, 2)))


# --------------------------------------------------------------------- real weights + adapter (skip if absent)


def test_end_to_end_ordering_on_a_synthetic_recording():
    art = default_artifacts_dir()
    if not all((art / PINS.npz[h].filename).exists() for h in HEADS):
        pytest.skip("pinned artifacts not fetched")
    from energy_models.wrist_cnn.model import WristCNN

    minutes = [synthetic.still_window(10 + i) for i in range(2)] + [synthetic.oscillating_window(20 + i, amplitude_g=0.9) for i in range(2)] + [synthetic.running_window(30)]
    recording = np.concatenate(minutes, axis=0)
    pw = prepare_windows(recording)
    assert pw.n == 5 and pw.valid.all()
    reg = WristCNN.load("regression")
    met = reg.predict(pw.windows)
    assert met[:2].max() < met[2:4].min() < met[4]
    quiet = quiet_mask(pw.windows)
    assert quiet.tolist() == [True, True, False, False, False]
    assert np.abs(met[quiet] - QUIET_MET_BASELINE).max() < 0.05
    part = reg.predict(pw.windows, skip=quiet)
    assert np.isnan(part[quiet]).all()
    np.testing.assert_allclose(part[~quiet], met[~quiet], rtol=1e-6, atol=1e-6)


# =================================================================== OOD


def up(*nat_windows: np.ndarray) -> np.ndarray:
    return to_upstream_layout(np.stack(nat_windows))


def score(*nat_windows):
    return ood.ood_signal(up(*nat_windows))


def test_typical_still_and_walking_windows_are_in_distribution():
    s = score(*[synthetic.still_window(i) for i in range(6)], *[synthetic.oscillating_window(i) for i in range(6)])
    assert s.dtype == np.float32 and s.shape == (12,)
    assert s.max() < 0.2, s


def test_saturated_flat_and_nan_windows_are_flagged():
    sat = score(synthetic.saturated_window(1))[0]
    flat = score(synthetic.flat_window(1))[0]
    nan = score(synthetic.nan_window(1))[0]
    assert sat > 0.9 and flat > 0.9 and nan == 1.0


def test_component_reasons_name_the_cause():
    batch = up(synthetic.still_window(1), synthetic.saturated_window(1), synthetic.flat_window(1), synthetic.nan_window(1))
    comps = ood.ood_components(batch)
    assert ood.dominant_reason(comps) == ["ok", "saturation", "flat", "nonfinite"]
    assert comps["nonfinite"].tolist() == [0, 0, 0, 1] and comps["flat"][2] == 1.0 and comps["saturation"][1] > 0.9


@pytest.mark.parametrize(
    ("name", "transform", "minimum"),
    [
        ("m/s^2", lambda w: w * 9.80665, 0.9),
        ("milli-g", lambda w: w * 1000.0, 0.99),
        ("raw LSB", lambda w: w * 4096.0, 0.99),
        ("half scale", lambda w: w * 0.5, 0.6),
        ("gravity removed", lambda w: w - w.mean(axis=0), 0.9),
    ],
)
def test_unit_and_gravity_mistakes_on_quiet_windows_are_flagged(name, transform, minimum):
    base = [synthetic.still_window(i) for i in range(4)]
    assert score(*[transform(w) for w in base]).min() >= minimum, name


def test_scale_errors_on_walking_windows_are_flagged_when_far_enough_out():
    walk = [synthetic.oscillating_window(i) for i in range(4)]
    assert score(*[w * 9.80665 for w in walk]).min() > 0.8
    assert score(*[w * 0.25 for w in walk]).min() > 0.5


def test_heavy_white_noise_is_flagged_but_sensor_level_noise_is_not():
    rng = np.random.default_rng(0)
    base = synthetic.still_window(1)
    loud = np.clip(base + rng.normal(0, 1.0, base.shape), -8, 8).astype(np.float32)
    quiet_noise = (base + rng.normal(0, 0.01, base.shape)).astype(np.float32)
    s = score(loud, quiet_noise)
    assert s[0] > 0.7 and s[1] < 0.2


def test_score_does_not_depend_on_layout_axis_order_or_sign():
    wins = np.stack([synthetic.oscillating_window(1), synthetic.running_window(2), synthetic.still_window(3)])
    ref = ood.ood_signal(to_upstream_layout(wins))
    np.testing.assert_allclose(ood.ood_signal(wins, layout="natural"), ref, atol=1e-6)
    np.testing.assert_allclose(ood.ood_signal(to_upstream_layout(wins[:, :, [1, 2, 0]])), ref, atol=1e-5)
    np.testing.assert_allclose(ood.ood_signal(to_upstream_layout(-wins)), ref, atol=1e-5)


def test_nan_windows_do_not_disturb_their_neighbours():
    a, b = synthetic.still_window(1), synthetic.oscillating_window(2)
    both = score(a, synthetic.nan_window(3), b)
    np.testing.assert_allclose(both[[0, 2]], score(a, b), atol=1e-7)
    assert both[1] == 1.0


def test_inf_counts_as_non_finite():
    w = synthetic.still_window(1).copy()
    w[10, 1] = np.inf
    assert score(w)[0] == 1.0


def test_random_input_stays_in_the_unit_interval():
    rng = np.random.default_rng(5)
    wins = np.concatenate([rng.normal(0, s, size=(3, W, 3)) for s in (0.001, 0.1, 1, 10, 1000)]).astype(np.float32)
    s = ood.ood_signal(to_upstream_layout(wins))
    assert ((s >= 0) & (s <= 1)).all() and np.isfinite(s).all()


def test_empty_and_malformed_inputs():
    assert ood.ood_signal(np.zeros((0, W, 3), np.float32)).shape == (0,)
    with pytest.raises(ValueError):
        ood.ood_signal(np.zeros((W, 3), np.float32))
    with pytest.raises(ValueError):
        ood.ood_signal(np.zeros((1, W, 2), np.float32))


def test_features_on_known_signals():
    t = np.arange(W) / FS
    w = np.stack([0.1 * np.sin(2 * np.pi * t), 0.3 * np.sin(2 * np.pi * 2 * t), 1.0 + 0.2 * np.sin(2 * np.pi * 0.5 * t)], axis=1).astype(np.float32)
    f = ood.window_features(up(w))
    assert [f[k][0] for k in ("std_max", "std_mid", "std_min")] == pytest.approx([0.3 / np.sqrt(2), 0.2 / np.sqrt(2), 0.1 / np.sqrt(2)], rel=0.02)
    assert [f[k][0] for k in ("range_max", "range_mid", "range_min")] == pytest.approx([0.6, 0.4, 0.2], rel=0.02)
    assert f["mean_norm"][0] == pytest.approx(1.0, rel=0.01)                       # sinusoids average out, gravity on z remains
    assert f["diff_rms"][0] < 0.05
    still = ood.window_features(up(np.tile(np.array([0.0, 0.0, 1.0], np.float32), (W, 1))))
    for k in ("std_max", "std_mid", "std_min", "range_max", "diff_rms", "sat_frac"):
        assert still[k][0] == 0.0
    assert still["vm_p50"][0] == pytest.approx(1.0) and still["mean_norm"][0] == pytest.approx(1.0) and still["flat_cov"][0] == 1.0


def test_saturation_fraction_counts_samples_with_any_railed_axis():
    w = synthetic.still_window(1).copy()
    w[:60, 0] = 8.0
    w[100:130, 2] = -8.0                                              # 90 samples railed in total = 1.5%
    f = ood.window_features(up(w))
    assert f["sat_frac"][0] == pytest.approx(90 / W)
    assert ood.ood_components(up(w))["saturation"][0] == pytest.approx(0.015 / 0.02, rel=1e-5)


def test_frozen_coverage_counts_only_runs_of_at_least_one_second():
    def same(runs: list[tuple[int, int]], length: int = W) -> np.ndarray:
        s = np.zeros((1, length - 1), dtype=bool)
        for start, n in runs:                                          # n identical samples starting at `start`
            s[0, start : start + n - 1] = True
        return s

    assert ood._frozen_coverage(same([(0, 100)]), 100)[0] == pytest.approx(100 / W)
    assert ood._frozen_coverage(same([(0, 99)]), 100)[0] == 0.0
    assert ood._frozen_coverage(same([(10, 250), (3000, 99), (5000, 1000)]), 100)[0] == pytest.approx(1250 / W)
    assert ood._frozen_coverage(same([(0, W)]), 100)[0] == 1.0
    assert ood._frozen_coverage(np.zeros((2, W - 1), bool), 100).tolist() == [0.0, 0.0]


def test_partially_frozen_windows_score_between_the_thresholds():
    base = synthetic.oscillating_window(1).copy()
    quarter, most = base.copy(), base.copy()
    quarter[int(0.75 * W) :] = quarter[int(0.75 * W) - 1]
    most[int(0.05 * W) :] = most[int(0.05 * W) - 1]
    s = ood.ood_components(up(base, quarter, most))["flat"]
    assert s[0] == 0.0 and s[1] == 0.0 and s[2] == 1.0
    mid = base.copy()
    mid[int(0.3 * W) :] = mid[int(0.3 * W) - 1]                       # 70% frozen
    assert 0.3 < ood.ood_components(up(mid))["flat"][0] < 0.7


def test_envelope_literal_is_well_formed():
    assert set(ood.ENVELOPE) == set(ood.FEATURES)
    for name, (lo, med, hi) in ood.ENVELOPE.items():
        assert lo <= med <= hi, name
    assert set(ood.HALF_WIDTH_FLOOR) == set(ood.FEATURES) and set(ood.TWO_SIDED) <= set(ood.FEATURES)
    assert ood.ENVELOPE["vm_p50"][0] > 0.9 and 1.0 < ood.ENVELOPE["vm_p50"][1] < 1.1


def test_custom_envelope_changes_the_verdict_and_median_inputs_score_zero():
    wins = up(*[synthetic.oscillating_window(i) for i in range(5)])
    own = ood.compute_envelope(wins)
    assert set(own) == set(ood.FEATURES)
    assert ood.ood_signal(wins, envelope=own).max() < 0.3
    tight = {k: (v[1], v[1], v[1]) for k, v in own.items()}                 # collapse the envelope onto the medians
    assert ood.ood_signal(wins, envelope=tight).max() > ood.ood_signal(wins, envelope=own).max()
    med = ood.ENVELOPE
    feats = {k: np.array([med[k][1]]) for k in ood.FEATURES}
    worst, _ = ood._envelope_scores(feats, med)
    assert worst[0] == 0.0


def test_envelope_is_two_sided_for_level_features_and_upper_sided_for_the_rest():
    env = ood.ENVELOPE
    base = {k: np.array([env[k][1]]) for k in ood.FEATURES}

    def worst(**changes):
        feats = {k: v.copy() for k, v in base.items()}
        for k, v in changes.items():
            feats[k] = np.array([v])
        s, which = ood._envelope_scores(feats, env)
        return float(s[0]), ood.FEATURES[which[0]] if which[0] >= 0 else None

    s, name = worst(vm_p50=0.3)
    assert s > 0.8 and name == "vm_p50"                                   # below the lower edge
    s, name = worst(vm_p50=9.8)
    assert s > 0.9 and name == "vm_p50"                                   # above the upper edge
    s, name = worst(mean_norm=0.0)
    assert 0.2 < s < 0.5 and name == "mean_norm"
    assert worst(std_max=0.0, range_max=0.0, diff_rms=0.0, std_min=0.0) == (0.0, None)   # calmer than any training window is fine
    s, name = worst(std_max=20.0)
    assert s > 0.8 and name == "std_max"
    s_edge, _ = worst(vm_p95=env["vm_p95"][2])                             # exactly at the p99.5 edge
    assert s_edge == 0.0


def test_a_window_with_no_data_is_never_valid_even_if_the_missing_share_limit_is_lifted():
    acc = ramp_recording(2)
    acc[W:, :] = np.nan
    lax = prepare_windows(acc, max_missing_frac=1.0, max_gap_s=1000.0)
    assert lax.valid.tolist() == [True, False]


def test_gravity_rule_only_applies_to_quiet_windows():
    still = synthetic.still_window(1)
    moving = synthetic.oscillating_window(1) * 1.4                         # VM median far from 1 but moving
    comps = ood.ood_components(up(still * 1.5, moving))
    assert comps["gravity"][0] > 0.8 and comps["gravity"][1] == 0.0

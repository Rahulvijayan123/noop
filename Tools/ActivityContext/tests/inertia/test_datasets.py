"""Dataset loaders on tiny synthetic files (formats + unit conversion to g), plus real-data unit checks
(median |a| at rest ~ 1 g) that skip when the datasets are not on this machine."""

import os

import numpy as np
import pytest

from activity_context.inertia import datasets as D

G = 9.80665


def _rest(rec, labels):
    return D.rest_median_norm(rec, labels)


def test_capture24_parquet(tmp_path):
    pa = pytest.importorskip("pyarrow")
    import pyarrow.parquet as pq
    d = tmp_path / "pid=P001"
    d.mkdir()
    n = 400
    ann = ["7030 sleeping;MET 0.95"] * 200 + [None] * 200
    tb = pa.table({"timestamp_ms": np.arange(n, dtype=np.int64) * 10 + 1_479_003_480_000,
                   "x": np.zeros(n, np.float32), "y": np.zeros(n, np.float32), "z": np.ones(n, np.float32),
                   "annotation": pa.array(ann, pa.string())})
    pq.write_table(tb, d / "data.parquet")
    rec = next(D.iter_recordings("capture24", root=str(tmp_path)))
    assert rec.subject == "capture24:P001" and rec.source_hz == 100.0
    assert rec.label_names[-1] == "<NA>" and (rec.labels[200:] == len(rec.label_names) - 1).all()
    assert abs(rec.t[1] - rec.t[0] - 0.01) < 1e-6          # unix seconds in float64
    assert abs(_rest(rec, ["7030 sleeping;MET 0.95"]) - 1.0) < 1e-6


def test_wisdm_rate_detection_and_units(tmp_path):
    p = tmp_path / "raw" / "watch" / "accel"
    p.mkdir(parents=True)
    lines, t = [], 1_000_000_000
    for i in range(20 * 20):                         # 20 s at 20 Hz, sitting, 1 g
        lines.append(f"1600,D,{t + i * 50_000_000},0.0,0.0,{G};")
    t2 = t + 3600 * 10**9
    for i in range(50 * 20):                         # 20 s at 50 Hz, walking
        lines.append(f"1600,A,{t2 + i * 20_000_000},{G},0.0,0.0;")
    (p / "data_1600_accel_watch.txt").write_text("\n".join(lines) + "\n")
    recs = list(D.iter_recordings("wisdm2019_watch", root=str(tmp_path)))
    assert [r.source_hz for r in recs] == [20.0, 50.0]
    assert [r.label_names for r in recs] == [["D"], ["A"]]
    assert all(not r.uniform for r in recs)
    assert abs(_rest(recs[0], ["D"]) - 1.0) < 1e-9


def test_hhar_one_watch_per_user(tmp_path):
    rows = ["Index,Arrival_Time,Creation_Time,x,y,z,User,Model,Device,gt"]
    k = 0
    for dev, n, dt in (("lgwatch_1", 600, 5_000_000), ("gear_1", 100, 10_000_000)):
        for i in range(n):
            gt = "stand" if i < n // 2 else ""
            rows.append(f"{k},0,{10**12 + i * dt},0,{-G},0,a,{dev.split('_')[0]},{dev},{gt}")
            k += 1
    (tmp_path / "Watch_accelerometer.csv").write_text("\n".join(rows) + "\n")
    D.loader("hhar_watch")._CACHE.clear()
    recs = list(D.iter_recordings("hhar_watch", root=str(tmp_path)))
    assert len(recs) == 1 and recs[0].device == "lgwatch_1" and recs[0].source_hz == 200.0
    assert "null" in recs[0].label_names
    assert abs(_rest(recs[0], ["stand"]) - 1.0) < 1e-9
    D.loader("hhar_watch")._CACHE.clear()


def test_pamap2_fill_policy_and_units(tmp_path):
    (tmp_path / "Protocol").mkdir()
    n = 1000
    t = 8.38 + np.arange(n) * 0.01
    acc = np.tile([0.0, 0.0, G], (n, 1))
    acc[100:103] = np.nan                            # 3 samples -> filled (<= 50 ms)
    acc[500:520] = np.nan                            # 20 samples -> removed (splits the run)
    a = np.column_stack([t, np.full(n, 2), np.full(n, 100.0), np.full(n, 30.0), acc, np.zeros((n, 3))])
    np.savetxt(tmp_path / "Protocol" / "subject101.dat", a, fmt="%.6f")
    rec = next(D.iter_recordings("pamap2", root=str(tmp_path)))
    assert rec.placement == "wrist_right" and len(rec.t) == n - 20
    assert rec.filled.sum() == 3 and rec.meta["n_dropped_nan"] == 20
    assert np.allclose(np.linalg.norm(rec.xyz_g, axis=1), 1.0)
    assert np.diff(rec.t).max() > 0.1                # the long dropout is a gap, not bridged


def test_mhealth_columns(tmp_path):
    n = 200
    a = np.zeros((n, 24))
    a[:, 16] = G
    a[:, 23] = 2
    np.savetxt(tmp_path / "mHealth_subject1.log", a, fmt="%.5f", delimiter="\t")
    rec = next(D.iter_recordings("mhealth", root=str(tmp_path)))
    assert rec.source_hz == 50.0 and rec.label_names == ["2"] and abs(_rest(rec, ["2"]) - 1.0) < 1e-9


def test_opportunity_stream_choice_and_mg(tmp_path):
    n = 300
    a = np.zeros((n, 250))
    a[:, 0] = np.arange(n) * 33.333
    a[:, 22:25] = np.nan                              # RWR missing -> next stream
    a[:, 33] = 1000.0                                  # LWR z = 1000 mg
    a[:, 243] = 4
    np.savetxt(tmp_path / "S1-ADL1.dat", a, fmt="%.3f")
    rec = next(D.iter_recordings("opportunity", root=str(tmp_path)))
    assert rec.meta["stream"] == "LWR" and rec.placement == "wrist_left" and rec.subject == "opportunity:S1"
    assert abs(_rest(rec, ["loc:4"]) - 1.0) < 1e-9


def test_daphnet_is_ood_only(tmp_path):
    n = 200
    a = np.zeros((n, 11))
    a[:, 0] = np.arange(n) * 15.625
    a[:, 9] = 1000.0
    a[:, 10] = 1
    np.savetxt(tmp_path / "S01R01.txt", a, fmt="%.3f")
    rec = next(D.iter_recordings("daphnet_fog", root=str(tmp_path)))
    assert rec.placement == "back" and rec.meta["role"] == "ood_only" and abs(_rest(rec, ["1"]) - 1.0) < 1e-9


def _gotov_files(root, subj="GOTOV05", zipped=False, jump_ms=0):
    """Tiny GOTOV participant: 20 s NA, 100 s standing, 20 s NA, 120 s walkingFast at 600/7 Hz (ms timestamps
    rounded like the release), 1 g; COSMED breaths every 2 s (1.5 METS standing, 5 METS walking)."""
    import zipfile
    fs = 600.0 / 7.0
    segs = [("NA", 20), ("standing", 100), ("NA", 20), ("walkingFast", 120)]
    labels = np.concatenate([[lab] * int(round(d * fs)) for lab, d in segs])
    n = len(labels)
    t0 = 1_454_935_381_000
    t = np.round(t0 + np.arange(n) * 7000.0 / 600.0).astype(np.int64)
    if jump_ms:
        t[n // 2:] += jump_ms
    lines = ['"","time","x","y","z","labels"']
    for i in range(n):
        lab = "NA" if labels[i] == "NA" else f'"{labels[i]}"'
        lines.append(f'"{i + 1}",{t[i]},0.0,0.0,1.0,{lab}')
    act = f"Activity_Measurements/{subj}/{subj}-GENEActiv-wrist.csv"
    ee_rows = ["time,wrist_x,METS,original_activity_labels"]
    for k in range(0, int(sum(d for _, d in segs)), 2):
        mets = 5.0 if k >= 140 else 1.5
        ee_rows.append(f"{float(t0 + k * 1000)},0.0,{mets},")
    ee = f"Energy_Expenditure_Measurements/{subj}.csv"
    if zipped:
        with zipfile.ZipFile(root / "Activity_Measurements.zip", "w") as z:
            z.writestr(act, "\n".join(lines) + "\n")
        with zipfile.ZipFile(root / "Energy_Expenditure_Measurements.zip", "w") as z:
            z.writestr(ee, "\n".join(ee_rows) + "\n")
    else:
        (root / act).parent.mkdir(parents=True)
        (root / act).write_text("\n".join(lines) + "\n")
        (root / ee).parent.mkdir(parents=True)
        (root / ee).write_text("\n".join(ee_rows) + "\n")


@pytest.mark.parametrize("zipped", [False, True])
def test_gotov_clock_guard_units_and_measured_met(tmp_path, zipped):
    mod = D.loader("gotov")
    _gotov_files(tmp_path, zipped=zipped)
    assert D.list_units("gotov", root=str(tmp_path)) == ["GOTOV05"]
    rec = next(D.iter_recordings("gotov", root=str(tmp_path)))
    assert rec.subject == "gotov:GOTOV05" and rec.placement == "wrist_right" and rec.uniform
    assert rec.source_hz == pytest.approx(600 / 7) and np.allclose(np.diff(rec.t), 7 / 600, atol=1e-6)
    assert abs(_rest(rec, mod.REST_LABELS) - 1.0) < 1e-9                    # g, unconverted
    names = np.array(rec.label_names)[rec.labels]
    rel = rec.t - rec.t[0]
    stand = names == "standing"
    assert rel[stand].min() >= 30.0 - 0.02 and rel[stand].max() <= 110.0 + 0.02      # 10 s guard at both edges
    walk = names == "walkingFast"
    assert rel[walk].min() >= 150.0 - 0.02 and rec.meta["n_guard_relabelled_null"] > 0
    met = rec.met
    assert np.isnan(met[(rel >= 140) & (rel < 199.9)]).all()                  # first 60 s of the activity: MASK
    assert np.allclose(met[(rel >= 201) & (rel < 255)], 5.0)
    assert np.isnan(met[(rel < 19.9) | ((rel > 120.1) & (rel < 139.9))]).all()   # unlabelled in the source: no MET
    assert np.isfinite(met[(rel > 252) & (rel < 257)]).all() and rec.meta["met"]["cosmed"]        # guard tail keeps its measurement


def test_gotov_refuses_a_drifting_clock(tmp_path):
    _gotov_files(tmp_path, jump_ms=200)
    with pytest.raises(D.DatasetError):
        next(D.iter_recordings("gotov", root=str(tmp_path)))


def test_gotov_without_cosmed_has_no_met(tmp_path):
    _gotov_files(tmp_path)
    import shutil
    shutil.rmtree(tmp_path / "Energy_Expenditure_Measurements")
    rec = next(D.iter_recordings("gotov", root=str(tmp_path)))
    assert np.isnan(rec.met).all() and rec.meta["met"] == {"cosmed": False}


def _wear_file(path, k, left_nan=0.0, label="push-ups"):
    n = 50 * 60
    cols = ["sbj_id"] + [f"{s}_acc_{a}" for s in ("right_arm", "right_leg", "left_leg", "left_arm") for a in "xyz"] + ["label"]
    rows = [",".join(cols)]
    n_nan = int(left_nan * n)
    for i in range(n):
        lab = "null" if i < 50 * 10 else label
        left = ",".join(["nan"] * 3) if i < n_nan else "0.0,-1.0,0.0"
        rows.append(f"{k},1.0,0.0,0.0,0.0,0.0,1.0,0.0,0.0,1.0,{left},{lab}")
    path.write_text("\n".join(rows) + "\n")


def test_wear_one_wrist_per_subject_left_first(tmp_path):
    mod = D.loader("wear")
    _wear_file(tmp_path / "sbj_0.csv", 0, label="stretching (triceps)")
    _wear_file(tmp_path / "sbj_1.csv", 1, left_nan=0.1)                     # left < 95 % finite -> right wrist
    assert D.list_units("wear", root=str(tmp_path)) == ["sbj_0", "sbj_1"]
    r0, r1 = list(D.iter_recordings("wear", root=str(tmp_path)))
    assert r0.placement == "wrist_left" and r0.meta["stream"] == "left_arm" and r0.subject == "wear:sbj_0"
    assert r1.placement == "wrist_right" and r1.meta["stream"] == "right_arm" and len(r1.t) == 50 * 60
    assert r0.source_hz == 50.0 and r0.uniform and abs(np.diff(r0.t).max() - 0.02) < 1e-12
    assert abs(_rest(r0, mod.REST_LABELS) - 1.0) < 1e-9                     # g, unconverted
    assert "null" in r0.label_names and r0.met is None
    _wear_file(tmp_path / "sbj_2.csv", 2, label="yoga")
    with pytest.raises(D.DatasetError):
        list(D.iter_recordings("wear", root=str(tmp_path), subjects=["sbj_2"]))


@pytest.mark.parametrize("ds", ["capture24", "wisdm2019_watch", "hhar_watch", "pamap2", "mhealth", "opportunity", "daphnet_fog",
                                "gotov", "wear"])
def test_real_data_rest_is_one_g(ds):
    mod = D.loader(ds)
    root = getattr(mod, "DEFAULT_ROOT")
    if not os.path.isdir(root):
        pytest.skip(f"{ds} not present on this machine")
    unit = D.list_units(ds)[0]
    med = [D.rest_median_norm(r, mod.REST_LABELS) for r in D.iter_recordings(ds, subjects=[unit])]
    med = [m for m in med if np.isfinite(m)]
    assert med and all(0.9 < m < 1.1 for m in med), (ds, med)

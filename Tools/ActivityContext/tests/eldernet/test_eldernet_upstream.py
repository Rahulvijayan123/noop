"""The upstream ElderNet source is fetched by the operator and imported verified; none of it is in Nara's repository
(ELDERNET.md §1, NOTICE.md). Manifest, refusal of missing / tampered files, private import, fetch paths, ping."""

import hashlib
import json
import os
import shutil
import subprocess
import sys

import numpy as np
import pytest

from activity_context.eldernet import QUALITY_HEADS, UPSTREAM_COMMIT
from activity_context.eldernet import upstream as U
from activity_context.eldernet.weights import (DEPLOYMENT_WEIGHTS_DIGEST, MANIFEST, WeightsError, weights_digest,
                                               wire_hashes)

from ._helpers import PKG, FakeHeads, env, upstream_source_or_skip, weights_dir_or_skip

ELDERNET_PKG = os.path.join(PKG, "activity_context", "eldernet")


def _fake_tree(tmp_path, files):
    man = {}
    for rel, data in files.items():
        p = tmp_path.joinpath(*rel.split("/"))
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data)
        man[rel] = U.SourceFile(rel, hashlib.sha256(data).hexdigest(), len(data), "import")
    return man


# --- no Oxford code in the repository --------------------------------------------------------------------------

def test_no_vendored_oxford_code_in_the_package():
    assert not os.path.exists(os.path.join(ELDERNET_PKG, "vendor"))
    # Class / function definitions only the upstream source has (built here so this file does not contain them).
    markers = [f"{kw} {name}(" for kw, name in (("class", "Downsample"), ("class", "ResBlock"), ("class", "Resnet"),
                                                ("class", "LinearLayers"), ("class", "Regressor"),
                                                ("def", "weight_init"), ("def", "otsu_threshold_log"),
                                                ("def", "merge_bouts"), ("def", "window_predictions_to_seconds"),
                                                ("def", "windows_within_bouts"), ("def", "summarise_bouts"))]
    oxford = "Copyright © 2022, University of Oxford"
    for root in (os.path.join(PKG, "activity_context"), os.path.join(PKG, "tests")):
        for dirpath, _, names in os.walk(root):
            for n in names:
                if not n.endswith(".py"):
                    continue
                with open(os.path.join(dirpath, n), encoding="utf-8") as f:
                    text = f.read()
                hits = [m for m in markers if m in text]
                assert not hits, (n, hits)
                if n not in ("__init__.py",):          # the package constant UPSTREAM_COPYRIGHT names the notice
                    assert not any(line.lstrip().startswith("#") and oxford in line for line in text.splitlines()), n


# --- manifest ----------------------------------------------------------------------------------------------------

def test_manifest_pins_every_executed_file():
    executed = {rel for rel, _ in U.MODULES.values()}
    assert executed <= set(U.SOURCE_MANIFEST)
    assert {"LICENSE.md", "pipelines/config.yaml"} <= set(U.SOURCE_MANIFEST)
    for sf in list(U.SOURCE_MANIFEST.values()) + list(U.EXAMPLE_MANIFEST.values()):
        assert len(sf.sha256) == 64 and int(sf.sha256, 16) >= 0 and sf.size > 0
        assert sf.url == f"https://raw.githubusercontent.com/yonbrand/gait-quality/{UPSTREAM_COMMIT}/{sf.path}"
    assert set(U.SERVE_FILES) == {"LICENSE.md", "models.py"}
    assert U.source_hashes() == {p: U.SOURCE_MANIFEST[p].sha256 for p in U.SERVE_FILES}


def test_missing_directory_and_files_are_model_missing(tmp_path, monkeypatch):
    monkeypatch.delenv("ELDERNET_UPSTREAM_DIR", raising=False)
    with pytest.raises(WeightsError) as e:
        U.models(None)
    assert e.value.kind == "model_missing" and "ELDERNET_UPSTREAM_DIR" in e.value.message
    with pytest.raises(WeightsError) as e:
        U.models(str(tmp_path / "nope"))
    assert e.value.kind == "model_missing"
    with pytest.raises(WeightsError) as e:                     # empty directory: LICENSE.md is checked first
        U.models(str(tmp_path))
    assert e.value.kind == "model_missing" and "LICENSE.md" in e.value.message


def test_tampered_or_resized_files_are_refused(tmp_path):
    man = _fake_tree(tmp_path, {"a.py": b"x = 1\n", "pkg/b.py": b"y = 2\n"})
    assert U.verify(str(tmp_path), man) == {p: sf.sha256 for p, sf in man.items()}
    (tmp_path / "a.py").write_bytes(b"x = 9\n")                 # same size, other bytes
    with pytest.raises(WeightsError) as e:
        U.verify(str(tmp_path), man)
    assert e.value.kind == "weights_mismatch" and "sha256" in e.value.message and "a.py" in e.value.message
    (tmp_path / "a.py").write_bytes(b"x = 1\n# appended\n")
    with pytest.raises(WeightsError) as e:
        U.verify(str(tmp_path), man)
    assert e.value.kind == "weights_mismatch" and "bytes" in e.value.message


def test_weights_digest_is_the_deployment_pin():
    w = wire_hashes(MANIFEST)
    text = "eldernet-weights-1\n" + "".join(f"{k}={v}\n" for k, v in sorted(w.items()))
    assert weights_digest(w) == hashlib.sha256(text.encode()).hexdigest() == DEPLOYMENT_WEIGHTS_DIGEST
    assert DEPLOYMENT_WEIGHTS_DIGEST == "01b2f982a0a2664f455a529a8c483a10106a7ddcd89c326e3d15e24fa4cf4ca6"


def test_ping_reports_the_digest_and_the_upstream_source():
    from activity_context.eldernet.runtime import build_runtime, handle_request
    ping = handle_request(build_runtime(heads=FakeHeads()), {"id": "p", "op": "ping"})
    assert ping["weights_digest"] == DEPLOYMENT_WEIGHTS_DIGEST
    assert ping["upstream_source"] == U.source_hashes()
    assert all(isinstance(v, str) for v in ping["upstream_source"].values())   # worker: all-string object


# --- verified private import (needs the operator's upstream source) ---------------------------------------------

_PRIVATE = r"""
import json, random, sys
import numpy as np
from activity_context.eldernet import upstream as U
from activity_context.eldernet.model import build_head
random.seed(7); np.random.seed(7)
r0, n0 = random.getstate(), np.random.get_state()[1].copy()
m = build_head("gait_detection"); build_head("cadence")
det = U.detection()
leaked = sorted(k for k in sys.modules if k.split(".")[0] in U.UPSTREAM_TOP_LEVEL)
try:
    det._as_config({})                       # imports gait_quality.config: not part of the verified set
    refused = False
except ImportError:
    refused = True
print(json.dumps({"module": type(m).__module__, "leaked": leaked, "refused": refused,
                  "rng_untouched": random.getstate() == r0 and bool((np.random.get_state()[1] == n0).all()),
                  "pandas": "pandas" in sys.modules}))
"""


def test_upstream_modules_load_privately_without_side_effects():
    pytest.importorskip("torch")
    up = upstream_source_or_skip()
    r = subprocess.run([sys.executable, "-c", _PRIVATE], env=env({"ELDERNET_UPSTREAM_DIR": up}),
                       capture_output=True, text=True, timeout=300)
    assert r.returncode == 0, r.stdout + r.stderr
    out = json.loads(r.stdout.strip().splitlines()[-1])
    assert out["module"] == U.PRIVATE_PACKAGE + ".models"
    assert out["leaked"] == []                              # no `models` / `gait_quality` / `utils` in sys.modules
    assert out["refused"] is True
    assert out["rng_untouched"] is True                     # upstream weight_init (set_seed) is never run
    assert out["pandas"] is False                           # the architecture path never loads quality.py


def test_tampered_upstream_model_source_is_refused(tmp_path):
    pytest.importorskip("torch")
    up = upstream_source_or_skip()
    for rel in ("LICENSE.md", "models.py"):
        dst = tmp_path.joinpath(*rel.split("/"))
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(os.path.join(up, rel), dst)
    assert U.models(str(tmp_path)).__name__ == U.PRIVATE_PACKAGE + ".models"
    data = bytearray((tmp_path / "models.py").read_bytes())
    data[-2] ^= 1                                           # one bit; same size
    (tmp_path / "models.py").write_bytes(bytes(data))
    U._CACHE.clear()
    with pytest.raises(WeightsError) as e:
        U.models(str(tmp_path))
    assert e.value.kind == "weights_mismatch" and "models.py" in e.value.message
    U._CACHE.clear()


def test_architecture_constants_equal_upstream_config():
    yaml = pytest.importorskip("yaml")
    up = upstream_source_or_skip()
    raw = U.read_verified(up, U.SOURCE_MANIFEST["pipelines/config.yaml"])
    cfg = yaml.safe_load(raw.decode("utf-8"))["models"]
    assert cfg["gait_detection"]["output_size"] == 2 and cfg["gait_detection"]["feature_vector_size"] == 128
    for name, (_, max_mu, n_layers, bn) in QUALITY_HEADS.items():
        blk = cfg[name]
        assert (float(blk["max_mu"]), blk["num_layers_regressor"], bool(blk["batch_norm"])) == (max_mu, n_layers, bn)
        assert blk["feature_vector_size"] == 128 and blk["head"] == "fc" and blk["net"] == "ElderNet"


def test_bout_rules_come_from_upstream():
    pytest.importorskip("pandas")
    upstream_source_or_skip()
    from activity_context.eldernet.bouts import bout_window_starts, detect_bouts, second_labels, summarise
    pred = np.zeros(60, int)
    pred[5:20] = 1                       # 15 windows -> seconds 10..24
    pred[23:26] = 1                      # 3-window blip after a 3 s gap: bridged (merge_gap 3)
    pred[40:43] = 1                      # isolated 3 s: shorter than the 10 s minimum, dropped
    labels = second_labels(pred)
    assert labels.tolist() == [0] * 10 + [1] * 21 + [0] * 38
    bouts = detect_bouts(labels)
    assert [(b["start_sec"], b["end_sec"], b["start_sample"]) for b in bouts] == [(10, 31, 300)]
    starts = bout_window_starts(bouts, 69 * 30)
    assert starts == [(1, s) for s in range(10, 22)]        # windows of 10 s fully inside [10, 31)
    rows = [{"timestamp": f"t{s:02d}", "bout_id": 1, "start_sample": s * 30, "m": float(s)} for _, s in starts]
    bout_rows, rec = summarise(rows, labels, ["m"])
    assert bout_rows == [{"bout_id": 1, "n_windows": 12, "duration_sec": 21, "start_time": "t10", "m": 15.5}]
    assert rec["walking_time_min"] == 21 / 60 and rec["n_bouts"] == 1 and rec["m_median"] == 15.5


# --- fetch (offline: git archive of the operator's clone, or GitHub raw with the network stubbed) -----------------

def _is_pinned_clone(d):
    r = subprocess.run(["git", "-C", d, "cat-file", "-e", UPSTREAM_COMMIT + "^{commit}"], capture_output=True)
    return r.returncode == 0


def test_fetch_from_git_archive(tmp_path):
    up = upstream_source_or_skip()
    if not _is_pinned_clone(up):
        pytest.skip("ELDERNET_UPSTREAM_DIR is not a git clone holding the pinned commit")
    got = U.fetch(str(tmp_path / "src"), with_examples=True, from_git=up)
    assert set(got) == set(U.SOURCE_MANIFEST) | set(U.EXAMPLE_MANIFEST)
    assert U.main(["verify", "--dir", str(tmp_path / "src"), "--with-examples"]) == 0
    assert U.fetch(str(tmp_path / "src"), from_git="/nonexistent") == {p: sf.sha256 for p, sf in
                                                                       U.SOURCE_MANIFEST.items()}  # all present


def test_fetch_downloads_each_pinned_file_by_sha(tmp_path, monkeypatch):
    up = upstream_source_or_skip()
    import activity_context.fetch_artifacts as FA
    calls = []

    def fake_download(url, dest, sha, size, retries=5):
        rel = url.split(f"/{UPSTREAM_COMMIT}/", 1)[1]
        calls.append((url, sha, size))
        data = open(os.path.join(up, *rel.split("/")), "rb").read()
        assert hashlib.sha256(data).hexdigest() == sha and len(data) == size
        with open(dest, "wb") as f:
            f.write(data)
    monkeypatch.setattr(FA, "download", fake_download)
    U.fetch(str(tmp_path), with_examples=False)
    assert sorted(c[0] for c in calls) == sorted(sf.url for sf in U.SOURCE_MANIFEST.values())
    assert U.verify(str(tmp_path)) == {p: sf.sha256 for p, sf in U.SOURCE_MANIFEST.items()}


# --- the serve needs both pins ------------------------------------------------------------------------------------

def test_serve_with_weights_but_no_upstream_source_is_unavailable(tmp_path):
    pytest.importorskip("torch")
    wd = weights_dir_or_skip()
    from activity_context.eldernet.runtime import build_runtime, handle_request
    rt = build_runtime(wd, upstream_dir=str(tmp_path / "missing"))
    assert not rt.available and rt.error.kind == "model_missing" and "upstream" in rt.error.message
    ping = handle_request(rt, {"id": "p", "op": "ping"})
    assert ping["model_available"] is False and ping["model_error"].startswith("model_missing")

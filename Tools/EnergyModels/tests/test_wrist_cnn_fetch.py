"""Fetch / verify / convert tests: digest-mismatch refusal, idempotency, deterministic .npz, architecture checks.

No test touches the network: downloads are served by fake openers or ``file://`` URLs, and the
fake "upstream" .h5 files are tiny legacy-Keras-style files built with h5py (skipped without it).
"""

from __future__ import annotations

import hashlib
import io
import subprocess
import sys
import urllib.error
import zipfile
from dataclasses import replace
from pathlib import Path

_ROOT = Path(__file__).resolve().parents[1]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

import numpy as np  # noqa: E402
import pytest  # noqa: E402

from energy_models.wrist_cnn import fetch  # noqa: E402
from energy_models.wrist_cnn.fetch import (  # noqa: E402
    DigestMismatchError,
    FetchError,
    _npy_bytes,
    build_artifacts,
    default_artifacts_dir,
    download_verified,
    ensure_upstream,
    npz_bytes,
    read_h5_weights,
    sha256_file,
    verify_artifacts,
    verify_file,
)
from energy_models.wrist_cnn.model import WristCNN  # noqa: E402
from energy_models.wrist_cnn.pins import PINNED_COMMIT, PINS, NpzPin, PinSet, UpstreamFile  # noqa: E402
from energy_models.wrist_cnn.spec import HEADS, head_units  # noqa: E402
from energy_models.wrist_cnn.testing import TINY_ARCH, fake_upstream, random_weights, random_windows, write_fake_keras_h5  # noqa: E402

GOOD_URL = "https://raw.githubusercontent.com/razmik/cnn-wrist-model-freeliving/" + PINNED_COMMIT + "/x.h5"


class FakeResponse:
    def __init__(self, data: bytes, url: str):
        self._buf = io.BytesIO(data)
        self._url = url

    def read(self, n: int = -1) -> bytes:
        return self._buf.read(n)

    def geturl(self) -> str:
        return self._url

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


def serving(data: bytes, *, final_url: str | None = None, calls: list | None = None):
    def opener(req, timeout=None):
        if calls is not None:
            calls.append(req.full_url)
        return FakeResponse(data, final_url or req.full_url)

    return opener


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


# --------------------------------------------------------------------------- verify_file


def test_verify_file_accepts_exact_bytes_and_is_case_insensitive(tmp_path):
    p = tmp_path / "f.bin"
    p.write_bytes(b"hello")
    verify_file(p, sha(b"hello"), 5)
    verify_file(p, sha(b"hello").upper(), 5)


def test_verify_file_rejects_digest_size_and_missing_pin(tmp_path):
    p = tmp_path / "f.bin"
    p.write_bytes(b"hello")
    with pytest.raises(DigestMismatchError) as exc:
        verify_file(p, sha(b"hellp"), 5)
    assert sha(b"hello") in str(exc.value) and exc.value.expected == sha(b"hellp")
    with pytest.raises(DigestMismatchError, match="size"):
        verify_file(p, sha(b"hello"), 6)
    with pytest.raises(FetchError, match="no sha256 pin"):
        verify_file(p, "")


def test_verify_file_hashes_every_chunk_of_a_large_file(tmp_path):
    # the weights are ~17 MB: a bit flipped in the final chunk must still be caught
    blob = bytearray(np.random.default_rng(7).integers(0, 256, size=2 * (1 << 20) + 12345, dtype=np.uint8).tobytes())
    good = sha(bytes(blob))
    p = tmp_path / "big.bin"
    p.write_bytes(bytes(blob))
    assert sha256_file(p) == good
    verify_file(p, good, len(blob))
    blob[-1] ^= 0x01
    p.write_bytes(bytes(blob))
    with pytest.raises(DigestMismatchError):
        verify_file(p, good, len(blob))


def test_default_artifacts_dir_is_the_tracked_artifacts_folder_unless_overridden(monkeypatch):
    monkeypatch.delenv("NARA_WRIST_CNN_DIR", raising=False)
    d = default_artifacts_dir()
    assert d == _ROOT / "artifacts" / "wrist_cnn"
    assert (d / "manifest.json").is_file() and (d / "NOTICE.md").is_file()
    monkeypatch.setenv("NARA_WRIST_CNN_DIR", "/some/where")
    assert default_artifacts_dir() == Path("/some/where")


# --------------------------------------------------------------------------- download_verified


def test_download_accepts_the_pinned_bytes(tmp_path):
    data = b"A" * 5000
    dest = tmp_path / "d" / "x.h5"
    calls: list[str] = []
    download_verified(GOOD_URL, dest, sha(data), len(data), opener=serving(data, calls=calls), log=lambda m: None)
    assert dest.read_bytes() == data and calls == [GOOD_URL]
    assert not list(dest.parent.glob("*.part"))


@pytest.mark.parametrize(("tamper", "message"), [("flip", "sha256 mismatch"), ("shorter", "size"), ("longer", "more than")])
def test_download_refuses_tampered_bytes_and_leaves_nothing_behind(tmp_path, tamper, message):
    good = bytes(range(256)) * 20
    bad = {"flip": bytes([good[0] ^ 1]) + good[1:], "shorter": good[:-1], "longer": good + b"\0"}[tamper]
    dest = tmp_path / "x.h5"
    with pytest.raises(DigestMismatchError, match=message):
        download_verified(GOOD_URL, dest, sha(good), len(good), opener=serving(bad), log=lambda m: None)
    assert not dest.exists() and not list(tmp_path.glob("*.part"))


def test_download_stops_reading_an_endless_stream_once_the_pinned_size_is_exceeded(tmp_path):
    served = {"bytes": 0}

    class Endless(FakeResponse):
        def __init__(self, url):
            super().__init__(b"", url)

        def read(self, n=-1):
            n = 1 << 20 if n < 0 else n
            served["bytes"] += n
            if served["bytes"] > 64 << 20:
                raise RuntimeError("download was not capped at the pinned size")
            return b"x" * n

    def opener(req, timeout=None):
        return Endless(req.full_url)

    with pytest.raises(DigestMismatchError, match="more than"):
        download_verified(GOOD_URL, tmp_path / "x.h5", sha(b"whatever"), 1 << 20, opener=opener, log=lambda m: None)
    assert served["bytes"] <= 3 << 20 and not list(tmp_path.iterdir())


@pytest.mark.parametrize(
    "url",
    [
        "https://evil.example/x.h5",
        "http://raw.githubusercontent.com/razmik/cnn-wrist-model-freeliving/" + PINNED_COMMIT + "/x.h5",
        "https://raw.githubusercontent.com.evil.example/x.h5",
        "ftp://raw.githubusercontent.com/x.h5",
        "file:///etc/passwd",
    ],
)
def test_download_refuses_unexpected_schemes_and_hosts_before_connecting(tmp_path, url):
    calls: list[str] = []
    with pytest.raises(FetchError, match="refusing to download"):
        download_verified(url, tmp_path / "x.h5", sha(b"x"), 1, opener=serving(b"x", calls=calls))
    assert calls == []


def test_download_refuses_redirects_to_other_hosts(tmp_path):
    data = b"payload"
    with pytest.raises(FetchError, match="redirected"):
        download_verified(GOOD_URL, tmp_path / "x.h5", sha(data), len(data), opener=serving(data, final_url="https://evil.example/x"), log=lambda m: None)
    assert not (tmp_path / "x.h5").exists()


def test_download_retries_transient_failures_then_succeeds(tmp_path, monkeypatch):
    monkeypatch.setattr(fetch.time, "sleep", lambda s: None)
    data = b"B" * 100
    attempts = {"n": 0}

    def flaky(req, timeout=None):
        attempts["n"] += 1
        if attempts["n"] < 3:
            raise urllib.error.URLError("temporary failure")
        return FakeResponse(data, req.full_url)

    download_verified(GOOD_URL, tmp_path / "x.h5", sha(data), len(data), opener=flaky, retries=2, log=lambda m: None)
    assert attempts["n"] == 3 and (tmp_path / "x.h5").read_bytes() == data


def test_download_gives_up_cleanly(tmp_path, monkeypatch):
    monkeypatch.setattr(fetch.time, "sleep", lambda s: None)

    def down(req, timeout=None):
        raise urllib.error.URLError("offline")

    with pytest.raises(FetchError, match="could not download"):
        download_verified(GOOD_URL, tmp_path / "x.h5", sha(b"x"), 1, opener=down, retries=1, log=lambda m: None)
    assert not list(tmp_path.iterdir())


def test_digest_mismatch_is_not_retried(tmp_path):
    calls: list[str] = []
    with pytest.raises(DigestMismatchError):
        download_verified(GOOD_URL, tmp_path / "x.h5", sha(b"good"), 4, opener=serving(b"evil", calls=calls), retries=3, log=lambda m: None)
    assert len(calls) == 1


# --------------------------------------------------------------------------- ensure_upstream


def one_file_pins(data: bytes) -> PinSet:
    entry = UpstreamFile("regression", "pre/reg.h5", len(data), sha(data), "0" * 40)
    return PinSet(upstream={**PINS.upstream, "regression": entry}, npz=PINS.npz)


def test_ensure_upstream_trusts_only_a_verified_cache(tmp_path):
    data = b"model-bytes" * 100
    pins = one_file_pins(data)
    (tmp_path / "reg.h5").write_bytes(data)

    def must_not_be_called(req, timeout=None):
        raise AssertionError("network used although the cache verifies")

    path = ensure_upstream("regression", tmp_path, pins, base_url="file:///nowhere", opener=must_not_be_called)
    assert path.read_bytes() == data


def test_ensure_upstream_replaces_a_corrupt_cache(tmp_path):
    data = b"model-bytes" * 100
    pins = one_file_pins(data)
    (tmp_path / "reg.h5").write_bytes(b"corrupted")
    path = ensure_upstream("regression", tmp_path, pins, base_url="file:///srv", opener=serving(data), log=lambda m: None)
    assert path.read_bytes() == data


def test_ensure_upstream_offline_never_uses_unverified_files(tmp_path):
    data = b"model-bytes" * 100
    pins = one_file_pins(data)
    with pytest.raises(FetchError, match="--offline"):
        ensure_upstream("regression", tmp_path, pins, offline=True)
    (tmp_path / "reg.h5").write_bytes(b"corrupted")
    with pytest.raises(DigestMismatchError):
        ensure_upstream("regression", tmp_path, pins, offline=True)


# --------------------------------------------------------------------------- pins


def test_real_pins_are_complete_and_tied_to_the_pinned_commit():
    assert len(PINNED_COMMIT) == 40 and all(c in "0123456789abcdef" for c in PINNED_COMMIT)
    names = set()
    for head in HEADS:
        up, npz = PINS.upstream[head], PINS.npz[head]
        assert up.raw_url().startswith(f"https://raw.githubusercontent.com/razmik/cnn-wrist-model-freeliving/{PINNED_COMMIT}/pre-trained-models/{head}/")
        assert up.raw_url().endswith(".h5") and up.size > 1_000_000
        assert len(up.sha256) == 64 and int(up.sha256, 16) >= 0
        assert len(up.git_blob_sha1) == 40 and int(up.git_blob_sha1, 16) >= 0
        assert len(npz.sha256) == 64 and int(npz.sha256, 16) >= 0 and npz.size > 1_000_000
        names.add(npz.filename)
    assert len(names) == 2 and len({PINS.upstream[h].sha256 for h in HEADS}) == 2


# --------------------------------------------------------------------------- deterministic npz


@pytest.mark.parametrize("shape", [(), (5,), (3, 4), (10, 80, 3), (1, 1, 1)])
def test_npy_bytes_equal_numpys_own_writer(shape):
    arr = np.random.default_rng(0).normal(size=shape).astype("<f4")
    buf = io.BytesIO()
    np.save(buf, arr)
    assert _npy_bytes(arr) == buf.getvalue()


def test_npz_bytes_roundtrip_and_determinism():
    rng = np.random.default_rng(1)
    arrays = {"b_kernel": rng.normal(size=(3, 4, 5)).astype(np.float32), "a_bias": rng.normal(size=(5,)).astype(np.float32)}
    blob = npz_bytes(arrays)
    assert blob == npz_bytes(dict(reversed(list(arrays.items()))))
    with np.load(io.BytesIO(blob), allow_pickle=False) as z:
        assert sorted(z.files) == ["a_bias", "b_kernel"]
        for k, v in arrays.items():
            np.testing.assert_array_equal(z[k], v)
            assert z[k].dtype == np.float32
    with zipfile.ZipFile(io.BytesIO(blob)) as zf:
        assert zf.testzip() is None
        assert [i.filename for i in zf.infolist()] == ["a_bias.npy", "b_kernel.npy"]
        assert all(i.compress_type == zipfile.ZIP_STORED and i.date_time == (1980, 1, 1, 0, 0, 0) for i in zf.infolist())


# --------------------------------------------------------------------------- end-to-end with fake upstream


@pytest.fixture(params=["nested", "flat"])
def world(request, tmp_path):
    pytest.importorskip("h5py")
    src = tmp_path / "src"
    pins, base_url, weights = fake_upstream(src, TINY_ARCH, naming=request.param)
    return {"pins": pins, "url": base_url, "weights": weights, "art": tmp_path / "artifacts", "src": src}


def build(world, **kw):
    return build_artifacts(world["art"], world["pins"], arch=TINY_ARCH, base_url=world["url"], log=lambda m: None, **kw)


def test_fetch_convert_verify_and_load_roundtrip(world):
    assert build(world) == {"regression": "converted", "classification": "converted"}
    assert verify_artifacts(world["art"], world["pins"]) == {"regression": "ok", "classification": "ok"}
    assert not list(world["art"].rglob("*.part")) and not list(world["art"].rglob("*.candidate"))
    for head in HEADS:
        net = WristCNN.load(head, world["art"], pins=world["pins"], arch=TINY_ARCH)
        ref = WristCNN(world["weights"][head], head, arch=TINY_ARCH)
        x = random_windows(TINY_ARCH, 3, seed=5)
        np.testing.assert_array_equal(net.predict(x), ref.predict(x))


def test_build_is_idempotent_and_does_not_touch_good_files(world):
    build(world)
    files = {p: p.stat().st_mtime_ns for p in world["art"].glob("*.npz")}
    assert build(world) == {"regression": "up-to-date", "classification": "up-to-date"}
    assert {p: p.stat().st_mtime_ns for p in world["art"].glob("*.npz")} == files


def test_up_to_date_artifacts_need_neither_network_nor_upstream_files(world):
    build(world)
    for p in (world["art"] / "upstream").glob("*"):
        p.unlink()

    def no_network(req, timeout=None):
        raise AssertionError("network used")

    assert build_artifacts(world["art"], world["pins"], arch=TINY_ARCH, base_url=world["url"], opener=no_network, offline=True) == {
        "regression": "up-to-date",
        "classification": "up-to-date",
    }


def test_tampered_npz_is_detected_and_rebuilt(world):
    build(world)
    path = world["art"] / world["pins"].npz["regression"].filename
    blob = bytearray(path.read_bytes())
    blob[-40] ^= 0xFF
    path.write_bytes(bytes(blob))
    assert verify_artifacts(world["art"], world["pins"])["regression"].startswith("mismatch")
    assert build(world) == {"regression": "converted", "classification": "up-to-date"}
    assert verify_artifacts(world["art"], world["pins"])["regression"] == "ok"


def test_wrong_upstream_digest_pin_is_refused_and_nothing_is_produced(world):
    bad = replace(world["pins"].upstream["regression"], sha256="0" * 64)
    pins = PinSet(upstream={**world["pins"].upstream, "regression": bad}, npz=world["pins"].npz)
    with pytest.raises(DigestMismatchError):
        build_artifacts(world["art"], pins, arch=TINY_ARCH, base_url=world["url"], log=lambda m: None)
    assert not list(world["art"].glob("*.npz"))
    assert not (world["art"] / "upstream" / Path(bad.path).name).exists()


def test_swapped_upstream_file_is_refused(world):
    """The server hands out the classification file where the regression one is pinned."""
    reg, cls = world["pins"].upstream["regression"], world["pins"].upstream["classification"]
    pins = PinSet(upstream={**world["pins"].upstream, "regression": replace(reg, path=cls.path)}, npz=world["pins"].npz)
    with pytest.raises(DigestMismatchError):
        build_artifacts(world["art"], pins, arch=TINY_ARCH, base_url=world["url"], log=lambda m: None)
    assert not list(world["art"].glob("*.npz"))


def test_wrong_npz_pin_refuses_to_install_the_converted_file(world):
    bad = NpzPin(world["pins"].npz["regression"].filename, world["pins"].npz["regression"].size, "f" * 64)
    pins = PinSet(upstream=world["pins"].upstream, npz={**world["pins"].npz, "regression": bad})
    with pytest.raises(DigestMismatchError, match="converted"):
        build_artifacts(world["art"], pins, arch=TINY_ARCH, base_url=world["url"], log=lambda m: None)
    assert not list(world["art"].glob("*.npz")) and not list(world["art"].glob("*.candidate"))


def test_empty_npz_pin_is_refused(world):
    pins = PinSet(upstream=world["pins"].upstream, npz={**world["pins"].npz, "regression": NpzPin("x.npz", 0, "")})
    with pytest.raises(FetchError, match="no npz sha256 pin"):
        build_artifacts(world["art"], pins, arch=TINY_ARCH, base_url=world["url"], log=lambda m: None)


def test_corrupt_cached_upstream_file_is_replaced_by_a_verified_download(world):
    build(world, purge_upstream=False)
    cached = world["art"] / "upstream" / Path(world["pins"].upstream["regression"].path).name
    cached.write_bytes(b"truncated")
    (world["art"] / world["pins"].npz["regression"].filename).unlink()
    assert build(world)["regression"] == "converted"
    verify_file(cached, world["pins"].upstream["regression"].sha256, world["pins"].upstream["regression"].size)


def test_purge_upstream_removes_the_h5_after_conversion(world):
    build(world, purge_upstream=True)
    assert not list((world["art"] / "upstream").glob("*.h5"))
    assert verify_artifacts(world["art"], world["pins"]) == {"regression": "ok", "classification": "ok"}


# --------------------------------------------------------------------------- architecture validation


def _write(tmp_path, head="regression", mutate=None, weights=None, **kw):
    pytest.importorskip("h5py")
    weights = weights or random_weights(TINY_ARCH, head_units(head), seed=2)
    path = tmp_path / "m.h5"
    write_fake_keras_h5(path, weights, head, TINY_ARCH, mutate_config=mutate, **kw)
    return path


def test_valid_fake_h5_converts_to_the_exact_weights(tmp_path):
    w = random_weights(TINY_ARCH, 3, seed=2)
    got = read_h5_weights(_write(tmp_path, "classification", weights=w), "classification", TINY_ARCH)
    assert set(got) == set(w)
    for k in w:
        np.testing.assert_array_equal(got[k], w[k])


def _set(layer_idx, **cfg):
    def mutate(model_config):
        model_config["config"][layer_idx]["config"].update(cfg)

    return mutate


def _drop_layer(idx):
    def mutate(model_config):
        del model_config["config"][idx]

    return mutate


def _rename_class(idx, name):
    def mutate(model_config):
        model_config["config"][idx]["class_name"] = name

    return mutate


@pytest.mark.parametrize(
    "mutate",
    [
        _set(1, padding="same"),                 # conv1
        _set(1, kernel_size=[5]),
        _set(2, strides=[2]),                    # conv2
        _set(2, filters=7),
        _set(4, activation="tanh"),              # conv3
        _set(7, dilation_rate=[2]),              # conv5
        _set(3, pool_size=[2]),                  # pool after conv2
        _set(3, padding="same"),
        _set(6, strides=[2]),                    # pool after conv4
        _set(10, rate=0.2),                      # dropout
        _set(-1, activation="softmax"),          # dense head
        _set(-1, units=2),
        _set(-1, use_bias=False),
        _set(0, target_shape=[3, 71]),           # reshape
        _drop_layer(4),
        _rename_class(3, "AveragePooling1D"),
        _rename_class(9, "GlobalAveragePooling1D"),
    ],
)
def test_architecture_changes_are_refused(tmp_path, mutate):
    with pytest.raises(FetchError):
        read_h5_weights(_write(tmp_path, mutate=mutate), "regression", TINY_ARCH)


def test_a_non_sequential_model_is_refused(tmp_path):
    def mutate(model_config):
        model_config["class_name"] = "Model"

    with pytest.raises(FetchError, match="Sequential"):
        read_h5_weights(_write(tmp_path, mutate=mutate), "regression", TINY_ARCH)


def test_wrong_head_for_the_file_is_refused(tmp_path):
    with pytest.raises(FetchError):
        read_h5_weights(_write(tmp_path, "classification"), "regression", TINY_ARCH)


def test_non_float32_or_non_finite_weights_are_refused(tmp_path):
    w = random_weights(TINY_ARCH, 1, seed=2)
    with pytest.raises(FetchError, match="float32"):
        read_h5_weights(_write(tmp_path, weights={**w, "conv2_kernel": w["conv2_kernel"].astype(np.float64)}), "regression", TINY_ARCH)
    bad = w["dense_kernel"].copy()
    bad[0, 0] = np.nan
    with pytest.raises(FetchError, match="non-finite"):
        read_h5_weights(_write(tmp_path, weights={**w, "dense_kernel": bad}), "regression", TINY_ARCH)


def test_wrong_weight_shapes_are_refused(tmp_path):
    w = random_weights(TINY_ARCH, 1, seed=2)
    with pytest.raises(FetchError, match="shape"):
        read_h5_weights(_write(tmp_path, weights={**w, "conv1_kernel": np.zeros((3, 3, 5), np.float32)}), "regression", TINY_ARCH)


# --------------------------------------------------------------------------- CLI and imports


def test_cli_check_reports_missing_artifacts(tmp_path, capsys):
    assert fetch.main(["--check", "--artifacts-dir", str(tmp_path)]) == 1
    out = capsys.readouterr().out
    assert "regression: missing" in out and "classification: missing" in out


def test_cli_offline_without_cache_fails_without_network(tmp_path, capsys):
    assert fetch.main(["--offline", "--artifacts-dir", str(tmp_path)]) == 3
    assert "not cached" in capsys.readouterr().err


def test_cli_refuses_a_corrupt_cached_file_with_status_2(tmp_path, capsys):
    cache = tmp_path / "upstream"
    cache.mkdir()
    (cache / PINS.upstream["regression"].basename).write_bytes(b"not the pinned weights")
    assert fetch.main(["--offline", "--artifacts-dir", str(tmp_path)]) == 2
    assert "REFUSING" in capsys.readouterr().err
    assert not list(tmp_path.glob("*.npz"))


def test_cli_check_passes_on_the_real_artifacts_when_present(capsys):
    art = default_artifacts_dir()
    if not all((art / PINS.npz[h].filename).exists() for h in HEADS):
        pytest.skip("pinned artifacts not fetched")
    assert fetch.main(["--check"]) == 0
    assert capsys.readouterr().out.count(": ok") == 2


def test_inference_path_imports_only_numpy_and_the_standard_library():
    code = (
        "import sys\n"
        "import energy_models.wrist_cnn.model, energy_models.wrist_cnn.inputs, energy_models.wrist_cnn.ood\n"
        "heavy = {'h5py', 'tensorflow', 'tf_keras', 'keras', 'torch', 'scipy', 'pandas', 'sklearn', 'matplotlib'}\n"
        "bad = sorted(heavy & {m.split('.')[0] for m in sys.modules})\n"
        "assert not bad, bad\n"
        "assert 'numpy' in sys.modules\n"
        "print('ok')\n"
    )
    res = subprocess.run([sys.executable, "-c", code], cwd=_ROOT, capture_output=True, text=True, timeout=120)
    assert res.returncode == 0 and res.stdout.strip() == "ok", res.stderr

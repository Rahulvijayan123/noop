"""Fetch -> verify -> convert the pretrained wrist-CNN weights.

The upstream repository has no licence, so the weights are never committed or
redistributed from this project. This module downloads the two ``.h5`` files
from upstream at a pinned commit, accepts them only if their sha256 equals the
pinned digest, converts kernels/biases to a compact float32 ``.npz`` in the
git-ignored ``artifacts/wrist_cnn/`` directory, and re-checks the sha256 of that
``.npz`` against its own pin. Any mismatch aborts without leaving a usable file.

Build/verify-time only: converting needs ``h5py`` (``requirements-cnn-convert.txt``),
which the numpy-only inference path never imports.

    python -m energy_models.wrist_cnn.fetch            # fetch + convert (idempotent)
    python -m energy_models.wrist_cnn.fetch --check    # verify existing .npz, offline
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import struct
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zlib
from collections.abc import Callable, Mapping
from pathlib import Path

import numpy as np

from .integrity import DigestMismatchError, FetchError, default_artifacts_dir, sha256_file, verify_file
from .pins import PINS, RAW_HOST, PinSet, UpstreamFile
from .spec import HEAD_ACTIVATION, HEADS, REAL_ARCH, ArchSpec, head_units

# DigestMismatchError, FetchError, default_artifacts_dir, sha256_file and verify_file live in
# integrity.py (so the loader does not import this tool); they stay importable from here.
__all__ = [
    "ALLOWED_DOWNLOAD_HOSTS",
    "DigestMismatchError",
    "FetchError",
    "build_artifacts",
    "compute_npz_digests",
    "default_artifacts_dir",
    "download_verified",
    "ensure_upstream",
    "main",
    "npz_bytes",
    "read_h5_weights",
    "sha256_file",
    "validate_model_config",
    "verify_artifacts",
    "verify_file",
    "write_npz",
]

ALLOWED_DOWNLOAD_HOSTS = frozenset({RAW_HOST, "media.githubusercontent.com"})
DEFAULT_TIMEOUT_S = 60.0
_CHUNK = 1 << 20

Log = Callable[[str], None]


def _stderr(msg: str) -> None:
    print(msg, file=sys.stderr)


# --------------------------------------------------------------------------- download


def upstream_url(entry: UpstreamFile, base_url: str | None = None) -> str:
    if base_url is None:
        return entry.raw_url()
    return base_url.rstrip("/") + "/" + entry.path


def download_verified(
    url: str,
    dest: Path,
    sha256: str,
    size: int,
    *,
    opener: Callable[..., object] | None = None,
    timeout: float = DEFAULT_TIMEOUT_S,
    retries: int = 2,
    enforce_host: bool = True,
    log: Log = _stderr,
) -> None:
    """Stream ``url`` to ``dest`` (via ``dest.part``), accepting only the pinned bytes."""
    parsed = urllib.parse.urlparse(url)
    if enforce_host and (parsed.scheme != "https" or parsed.hostname not in ALLOWED_DOWNLOAD_HOSTS):
        raise FetchError(f"refusing to download from {url!r}: only https://{RAW_HOST}/ is allowed")
    opener = opener or urllib.request.urlopen
    dest.parent.mkdir(parents=True, exist_ok=True)
    part = dest.with_name(dest.name + ".part")
    last_err: Exception | None = None
    for attempt in range(retries + 1):
        h = hashlib.sha256()
        got = 0
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "nara-energy-fetch/1"})
            with opener(req, timeout=timeout) as resp, open(part, "wb") as out:  # type: ignore[attr-defined]
                final = urllib.parse.urlparse(resp.geturl())
                if enforce_host and final.hostname not in ALLOWED_DOWNLOAD_HOSTS:
                    raise FetchError(f"download redirected to unexpected host {final.hostname!r}")
                while chunk := resp.read(_CHUNK):
                    got += len(chunk)
                    if size and got > size:
                        raise DigestMismatchError(f"{dest.name} (more than the pinned {size} bytes)", sha256, "oversize")
                    h.update(chunk)
                    out.write(chunk)
            if size and got != size:
                raise DigestMismatchError(f"{dest.name} (size {got} != pinned {size})", sha256, "size-mismatch")
            if h.hexdigest() != sha256.lower():
                raise DigestMismatchError(dest.name, sha256, h.hexdigest())
            os.replace(part, dest)
            return
        except DigestMismatchError:
            part.unlink(missing_ok=True)
            raise
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
            part.unlink(missing_ok=True)
            last_err = exc
            if attempt < retries:
                log(f"download of {dest.name} failed ({exc}); retrying")
                time.sleep(1.5 * (attempt + 1))
        except BaseException:
            part.unlink(missing_ok=True)
            raise
    raise FetchError(f"could not download {url}: {last_err}")


def ensure_upstream(
    head: str,
    upstream_dir: Path,
    pins: PinSet = PINS,
    *,
    base_url: str | None = None,
    opener: Callable[..., object] | None = None,
    offline: bool = False,
    log: Log = _stderr,
) -> Path:
    """Return the path of a digest-verified upstream ``.h5`` for ``head`` (downloading if needed)."""
    entry = pins.upstream[head]
    dest = upstream_dir / entry.basename
    if dest.exists():
        try:
            verify_file(dest, entry.sha256, entry.size, label=entry.basename)
            return dest
        except DigestMismatchError as exc:
            if offline:
                raise
            log(f"cached {entry.basename} failed verification ({exc}); fetching a fresh copy")
            dest.unlink()
    if offline:
        raise FetchError(f"{entry.basename} is not cached under {upstream_dir} and --offline was given")
    log(f"downloading {entry.basename} ({entry.size / 1e6:.1f} MB) from the pinned upstream commit")
    download_verified(
        upstream_url(entry, base_url),
        dest,
        entry.sha256,
        entry.size,
        opener=opener,
        enforce_host=base_url is None,
        log=log,
    )
    return dest


# --------------------------------------------------------------------------- h5 -> arrays


def _expected_layers(head: str, arch: ArchSpec) -> list[tuple[str, dict]]:
    layers: list[tuple[str, dict]] = [
        (
            "Reshape",
            {"target_shape": [arch.window_samples, arch.n_axes], "batch_input_shape": [None, arch.window_samples * arch.n_axes]},
        )
    ]
    for i, filters in enumerate(arch.filters, start=1):
        layers.append(
            (
                "Conv1D",
                {
                    "filters": filters,
                    "kernel_size": [arch.kernel_size],
                    "strides": [1],
                    "padding": "valid",
                    "data_format": "channels_last",
                    "dilation_rate": [1],
                    "activation": "relu",
                    "use_bias": True,
                },
            )
        )
        if i in arch.pool_after:
            layers.append(
                (
                    "MaxPooling1D",
                    {
                        "pool_size": [arch.pool_size],
                        "strides": [arch.pool_size],
                        "padding": "valid",
                        "data_format": "channels_last",
                    },
                )
            )
    layers.append(("GlobalMaxPooling1D", {"data_format": "channels_last"}))
    layers.append(("Dropout", {"rate": 0.5}))
    layers.append(("Dense", {"units": head_units(head), "activation": HEAD_ACTIVATION[head], "use_bias": True}))
    return layers


def _norm(value):
    if isinstance(value, (list, tuple)):
        return [_norm(v) for v in value]
    return value


def validate_model_config(config: Mapping, head: str, arch: ArchSpec = REAL_ARCH) -> list[dict]:
    """Check an upstream Keras model_config against the architecture this package implements.

    Returns the per-layer config dicts. Raises ``FetchError`` on any difference.
    """
    if config.get("class_name") != "Sequential":
        raise FetchError(f"unexpected model class {config.get('class_name')!r} (expected Sequential)")
    layers = config["config"]
    if isinstance(layers, Mapping):
        layers = layers["layers"]
    expected = _expected_layers(head, arch)
    if len(layers) != len(expected):
        raise FetchError(f"model has {len(layers)} layers, expected {len(expected)}")
    for idx, (layer, (cls, want)) in enumerate(zip(layers, expected)):
        if layer["class_name"] != cls:
            raise FetchError(f"layer {idx}: class {layer['class_name']!r}, expected {cls!r}")
        cfg = layer["config"]
        for key, value in want.items():
            if _norm(cfg.get(key)) != _norm(value):
                raise FetchError(f"layer {idx} ({cls}).{key} = {cfg.get(key)!r}, expected {value!r}")
    return [layer["config"] for layer in layers]


def read_h5_weights(h5_path: Path, head: str, arch: ArchSpec = REAL_ARCH) -> dict[str, np.ndarray]:
    """Validate the architecture of a legacy-Keras ``.h5`` and return canonical float32 weights."""
    try:
        import h5py  # build-time only
    except ImportError as exc:  # pragma: no cover - exercised only without h5py
        raise FetchError(
            "h5py is required to convert the upstream weights. Install requirements-cnn-convert.txt "
            "into a throwaway virtualenv (never into the inference environment)."
        ) from exc

    with h5py.File(h5_path, "r") as f:
        raw = f.attrs["model_config"]
        config = json.loads(raw.decode("utf8") if isinstance(raw, bytes) else raw)
        layer_cfgs = validate_model_config(config, head, arch)
        mw = f["model_weights"]
        listed = [n.decode("utf8") if isinstance(n, bytes) else str(n) for n in mw.attrs["layer_names"]]
        if listed != [c["name"] for c in layer_cfgs]:
            raise FetchError("h5 layer_names do not match the model config")

        arrays: dict[str, np.ndarray] = {}
        conv_i = 0
        for (cls, _), cfg in zip(_expected_layers(head, arch), layer_cfgs):
            if cls not in ("Conv1D", "Dense"):
                continue
            grp = mw[cfg["name"]]
            wnames = [n.decode("utf8") if isinstance(n, bytes) else str(n) for n in grp.attrs["weight_names"]]
            found: dict[str, np.ndarray] = {}
            for wname in wnames:
                part = wname.rsplit("/", 1)[-1].split(":")[0]
                ds = grp[wname]
                if ds.dtype != np.float32:
                    raise FetchError(f"{cfg['name']}/{part}: dtype {ds.dtype}, expected float32")
                found[part] = np.asarray(ds[()], dtype=np.float32)
            if set(found) != {"kernel", "bias"}:
                raise FetchError(f"{cfg['name']}: unexpected weight set {sorted(found)}")
            if cls == "Conv1D":
                conv_i += 1
                prefix = f"conv{conv_i}"
            else:
                prefix = "dense"
            arrays[f"{prefix}_kernel"] = found["kernel"]
            arrays[f"{prefix}_bias"] = found["bias"]

    shapes = arch.weight_shapes(head_units(head))
    if set(arrays) != set(shapes):
        raise FetchError(f"converted tensor set {sorted(arrays)} != expected {sorted(shapes)}")
    for key, want in shapes.items():
        if arrays[key].shape != want:
            raise FetchError(f"{key}: shape {arrays[key].shape}, expected {want}")
        if not np.isfinite(arrays[key]).all():
            raise FetchError(f"{key}: contains non-finite values")
    return arrays


# --------------------------------------------------------------------------- deterministic npz


def _npy_bytes(arr: np.ndarray) -> bytes:
    """Version-1.0 ``.npy`` bytes for a little-endian float32 C-order array (numpy-independent)."""
    a = np.asarray(arr, dtype="<f4", order="C")          # (ascontiguousarray would promote 0-d to 1-d)
    shape = tuple(int(d) for d in a.shape)
    header = "{'descr': '<f4', 'fortran_order': False, 'shape': %r, }" % (shape,)
    padlen = 64 - ((10 + len(header) + 1) % 64)
    header_b = (header + " " * padlen + "\n").encode("latin1")
    return b"\x93NUMPY\x01\x00" + struct.pack("<H", len(header_b)) + header_b + a.tobytes(order="C")


def npz_bytes(arrays: Mapping[str, np.ndarray]) -> bytes:
    """Byte-reproducible STORED zip of ``<key>.npy`` entries (sorted keys, 1980-01-01 timestamps)."""
    dos_time, dos_date = 0, (0 << 9) | (1 << 5) | 1
    body = bytearray()
    central = bytearray()
    count = 0
    for key in sorted(arrays):
        name = f"{key}.npy".encode("ascii")
        data = _npy_bytes(arrays[key])
        crc = zlib.crc32(data) & 0xFFFFFFFF
        offset = len(body)
        body += struct.pack("<IHHHHHIIIHH", 0x04034B50, 20, 0, 0, dos_time, dos_date, crc, len(data), len(data), len(name), 0)
        body += name + data
        central += struct.pack(
            "<IHHHHHHIIIHHHHHII",
            0x02014B50, (3 << 8) | 20, 20, 0, 0, dos_time, dos_date, crc, len(data), len(data),
            len(name), 0, 0, 0, 0, 0o100644 << 16, offset,
        )
        central += name
        count += 1
    out = bytes(body) + bytes(central)
    out += struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, count, count, len(central), len(body), 0)
    return out


def write_npz(path: Path, arrays: Mapping[str, np.ndarray]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    part = path.with_name(path.name + ".part")
    try:
        part.write_bytes(npz_bytes(arrays))
        os.replace(part, path)
    finally:
        part.unlink(missing_ok=True)


# --------------------------------------------------------------------------- orchestration


def build_artifacts(
    artifacts_dir: Path | None = None,
    pins: PinSet = PINS,
    *,
    heads: tuple[str, ...] = HEADS,
    arch: ArchSpec = REAL_ARCH,
    base_url: str | None = None,
    opener: Callable[..., object] | None = None,
    offline: bool = False,
    purge_upstream: bool = False,
    log: Log = _stderr,
) -> dict[str, str]:
    """Idempotently produce verified ``.npz`` weights; returns ``{head: status}``."""
    art = Path(artifacts_dir) if artifacts_dir is not None else default_artifacts_dir()
    art.mkdir(parents=True, exist_ok=True)
    status: dict[str, str] = {}
    for head in heads:
        pin = pins.npz[head]
        npz_path = art / pin.filename
        if not pin.sha256:
            raise FetchError(f"{head}: no npz sha256 pin configured; refusing to produce an unpinned artifact")
        if npz_path.exists():
            try:
                verify_file(npz_path, pin.sha256, pin.size, label=pin.filename)
                status[head] = "up-to-date"
                continue
            except DigestMismatchError as exc:
                log(f"existing {pin.filename} failed verification ({exc}); rebuilding from upstream")
                npz_path.unlink()
        h5 = ensure_upstream(head, art / "upstream", pins, base_url=base_url, opener=opener, offline=offline, log=log)
        arrays = read_h5_weights(h5, head, arch)
        part = npz_path.with_name(npz_path.name + ".candidate")
        try:
            write_npz(part, arrays)
            verify_file(part, pin.sha256, pin.size, label=f"converted {pin.filename}")
            os.replace(part, npz_path)
        finally:
            part.unlink(missing_ok=True)
        status[head] = "converted"
        log(f"wrote {npz_path.name} ({npz_path.stat().st_size / 1e6:.2f} MB, sha256 {pin.sha256[:12]}...)")
        if purge_upstream:
            h5.unlink()
    return status


def verify_artifacts(artifacts_dir: Path | None = None, pins: PinSet = PINS, heads: tuple[str, ...] = HEADS) -> dict[str, str]:
    """Offline check of the converted ``.npz`` files: ``{head: 'ok' | 'missing' | 'mismatch: ...'}``."""
    art = Path(artifacts_dir) if artifacts_dir is not None else default_artifacts_dir()
    result: dict[str, str] = {}
    for head in heads:
        pin = pins.npz[head]
        path = art / pin.filename
        if not path.exists():
            result[head] = "missing"
            continue
        try:
            verify_file(path, pin.sha256, pin.size, label=pin.filename)
            result[head] = "ok"
        except FetchError as exc:
            result[head] = f"mismatch: {exc}"
    return result


def compute_npz_digests(
    artifacts_dir: Path | None = None,
    pins: PinSet = PINS,
    *,
    heads: tuple[str, ...] = HEADS,
    arch: ArchSpec = REAL_ARCH,
    base_url: str | None = None,
    opener: Callable[..., object] | None = None,
    offline: bool = False,
    log: Log = _stderr,
) -> dict[str, dict[str, object]]:
    """Maintainer tool: convert verified upstream files and report the resulting npz digests.

    Nothing is written to the artifact directory; the output is what goes into ``pins.NPZ_PINS``.
    """
    art = Path(artifacts_dir) if artifacts_dir is not None else default_artifacts_dir()
    out: dict[str, dict[str, object]] = {}
    for head in heads:
        h5 = ensure_upstream(head, art / "upstream", pins, base_url=base_url, opener=opener, offline=offline, log=log)
        blob = npz_bytes(read_h5_weights(h5, head, arch))
        out[head] = {"filename": pins.npz[head].filename, "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest()}
    return out


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--artifacts-dir", type=Path, default=None, help="default: <EnergyModels>/artifacts/wrist_cnn")
    ap.add_argument("--check", action="store_true", help="only verify existing .npz files (offline, no h5py)")
    ap.add_argument("--offline", action="store_true", help="never use the network; use cached upstream .h5 files")
    ap.add_argument("--purge-upstream", action="store_true", help="delete the downloaded .h5 files after converting")
    ap.add_argument("--print-npz-digests", action="store_true", help="maintainer: print digests of freshly converted npz files")
    args = ap.parse_args(argv)

    try:
        if args.check:
            result = verify_artifacts(args.artifacts_dir)
            for head, state in result.items():
                print(f"{head}: {state}")
            return 0 if all(v == "ok" for v in result.values()) else 1
        if args.print_npz_digests:
            print(json.dumps(compute_npz_digests(args.artifacts_dir, offline=args.offline), indent=2))
            return 0
        status = build_artifacts(args.artifacts_dir, offline=args.offline, purge_upstream=args.purge_upstream)
    except DigestMismatchError as exc:
        print(f"REFUSING: {exc}", file=sys.stderr)
        return 2
    except FetchError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 3
    for head, state in status.items():
        print(f"{head}: {state}")
    return 0


if __name__ == "__main__":  # pragma: no cover
    raise SystemExit(main())

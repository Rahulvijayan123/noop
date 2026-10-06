"""``encoder.json`` (``nara.inertia.encoder/1``): presets, strict validation, module builder.

Presets reproduce upstream's resolved configs at the pinned commit (``config/methods/*.yaml`` merged with
``config/presets/{small,medium,large}.yaml`` by ``run.apply_preset``): the size knobs under
``preset.patchtst`` go to ``model.params`` for PatchTST and to ``method.params`` for ART.

  ART      patch_len 10 (stride = patch_len), dropout 0.0, no final norm, sinusoidal PE table [1, 5000, d]
  PatchTST patch_len 10, stride 10, pre_norm True (final LayerNorm), learned W_pos [num_patch, d],
           res_attention True for small (patchtst.yaml default) and False for medium/large
  small  d_model 512,  n_layers 4, n_heads 4,  d_ff 1024
  medium d_model 768,  n_layers 6, n_heads 8,  d_ff 2048
  large  d_model 1024, n_layers 8, n_heads 16, d_ff 4096

``tiny`` (d_model 16, 1 layer, 2 heads, d_ff 32) is a Nara test/fixture preset, allowed only for
``standin:`` ids. The validator refuses unknown keys, unknown method/preset combinations and any arch
number that differs from the preset, so a config can never silently describe a different network.
"""

from __future__ import annotations

import json
import os
import re
from typing import Any, Dict, Mapping, Tuple, Union

from . import (ALLOWED_WINDOW_S, ENCODER_CONFIG_SCHEMA, INERTIA_AXES, INERTIA_RATE_HZ,
               UPSTREAM_COMMIT)
from .contract import InputContract, is_sha256_hex

METHODS = ("ar_transformer", "patchtst")
_SIZES = {
    "small": {"d_model": 512, "n_layers": 4, "n_heads": 4, "d_ff": 1024},
    "medium": {"d_model": 768, "n_layers": 6, "n_heads": 8, "d_ff": 2048},
    "large": {"d_model": 1024, "n_layers": 8, "n_heads": 16, "d_ff": 4096},
}
UPSTREAM_PRESETS = tuple(_SIZES)
TEST_PRESETS = {"tiny": {"d_model": 16, "n_layers": 1, "n_heads": 2, "d_ff": 32}}

EXTRACTION_POINTS = {
    "ar_transformer": "inertia1/methods/ar_transformer_module.py:ARTransformerModule.encode"
                      " (all patches, no causal mask, mean over patch tokens)",
    "patchtst": "inertia1/methods/patchtst_module.py:PatchTSTModule.encode (mean over backbone patch tokens)",
}
AXIS_REDUCE = ("l2", "mean", "sum")      # upstream data option; inert when axes == 3
_REAL_ID = re.compile(r"^inertia-1/(ar_transformer|patchtst)-(small|medium|large)/(10|30)s@20hz$")
_ARCH_ID = re.compile(r"^standin:inertia-arch-random-init/(ar_transformer|patchtst)-([a-z]+)/seed(\d+)$")
_TOP_KEYS = {"schema", "encoder_id", "method", "preset", "arch", "data", "checkpoint", "inertia_repo_commit",
             "extraction_point", "embedding_dim", "input_contract"}
_OPTIONAL_TOP_KEYS = {"notes"}


class EncoderConfigError(ValueError):
    """encoder.json is malformed or describes a network other than the one it names."""


def expected_arch(method: str, preset: str) -> Dict[str, Any]:
    """The full ``arch`` object an encoder.json must carry for (method, preset)."""
    if method not in METHODS:
        raise EncoderConfigError(f"unknown method {method!r} (expected one of {METHODS})")
    sizes = _SIZES.get(preset) or TEST_PRESETS.get(preset)
    if sizes is None:
        raise EncoderConfigError(f"unknown preset {preset!r}")
    arch: Dict[str, Any] = {"patch_len": 10, "stride": 10, **sizes, "dropout": 0.0}
    if method == "patchtst":
        arch.update({"attn_dropout": 0.0, "head_dropout": 0.0, "act": "gelu", "norm": "LayerNorm",
                     "res_attention": preset in ("small", "tiny"), "pre_norm": True, "pe": "zeros",
                     "learn_pe": True})
    return arch


def encoder_id_for(method: str, preset: str, window_s: int) -> str:
    return f"inertia-1/{method}-{preset}/{int(window_s)}s@{INERTIA_RATE_HZ}hz"


def random_init_id(method: str, preset: str, seed: int) -> str:
    return f"standin:inertia-arch-random-init/{method}-{preset}/seed{int(seed)}"


def parse_arch_id(encoder_id: str) -> Tuple[str, str, Union[int, None], Union[int, None]]:
    """(method, preset, window_s|None, seed|None) from a real or random-init encoder id."""
    m = _REAL_ID.match(encoder_id or "")
    if m:
        return m.group(1), m.group(2), int(m.group(3)), None
    m = _ARCH_ID.match(encoder_id or "")
    if m:
        return m.group(1), m.group(2), None, int(m.group(3))
    raise EncoderConfigError(f"encoder_id {encoder_id!r} is neither 'inertia-1/<method>-<preset>/<w>s@20hz' "
                             f"nor 'standin:inertia-arch-random-init/<method>-<preset>/seed<k>'")


def _same(a: Any, b: Any) -> bool:
    """Equality that does not let True stand in for 1 (or 1 for 1.0 where a bool is expected)."""
    return type(a) is type(b) and a == b if isinstance(a, bool) or isinstance(b, bool) else a == b


def validate_encoder_config(cfg: Mapping[str, Any]) -> Dict[str, Any]:
    """Validate an encoder.json object; return a plain-dict copy. Raises EncoderConfigError."""
    if not isinstance(cfg, Mapping):
        raise EncoderConfigError("encoder config must be a JSON object")
    keys = set(cfg)
    if not _TOP_KEYS <= keys or keys - _TOP_KEYS - _OPTIONAL_TOP_KEYS:
        raise EncoderConfigError(f"encoder config keys must be {sorted(_TOP_KEYS)} (+ optional "
                                 f"{sorted(_OPTIONAL_TOP_KEYS)}); missing {sorted(_TOP_KEYS - keys)}, "
                                 f"unknown {sorted(keys - _TOP_KEYS - _OPTIONAL_TOP_KEYS)}")
    if cfg["schema"] != ENCODER_CONFIG_SCHEMA:
        raise EncoderConfigError(f"schema must be {ENCODER_CONFIG_SCHEMA!r}")
    method, preset, id_window, _seed = parse_arch_id(cfg["encoder_id"])
    if cfg["method"] != method or cfg["preset"] != preset:
        raise EncoderConfigError(f"method/preset {cfg['method']!r}/{cfg['preset']!r} disagree with the "
                                 f"encoder_id {cfg['encoder_id']!r}")
    if preset in TEST_PRESETS and not cfg["encoder_id"].startswith("standin:"):
        raise EncoderConfigError(f"preset {preset!r} is a test preset; only stand-in ids may use it")
    if preset not in UPSTREAM_PRESETS and preset not in TEST_PRESETS:
        raise EncoderConfigError(f"unknown preset {preset!r} for method {method!r}")
    want = expected_arch(method, preset)
    arch = cfg["arch"]
    if not isinstance(arch, Mapping) or set(arch) != set(want) or any(not _same(arch[k], want[k]) for k in want):
        diff = {k: (arch.get(k) if isinstance(arch, Mapping) else None, want[k]) for k in want
                if not isinstance(arch, Mapping) or not _same(arch.get(k), want[k])}
        raise EncoderConfigError(f"arch does not match preset {method}-{preset}: (got, expected) {diff}")
    data = cfg["data"]
    if not isinstance(data, Mapping) or set(data) != {"window_sec", "hz", "axes", "axis_reduce"}:
        raise EncoderConfigError("data must be exactly {window_sec, hz, axes, axis_reduce}")
    if data["window_sec"] not in ALLOWED_WINDOW_S or isinstance(data["window_sec"], bool):
        raise EncoderConfigError(f"data.window_sec must be one of {ALLOWED_WINDOW_S}")
    if data["hz"] != INERTIA_RATE_HZ or data["axes"] != len(INERTIA_AXES) or data["axis_reduce"] not in AXIS_REDUCE:
        raise EncoderConfigError(f"data must be hz={INERTIA_RATE_HZ}, axes=3, axis_reduce in {AXIS_REDUCE}")
    if id_window is not None and id_window != data["window_sec"]:
        raise EncoderConfigError(f"encoder_id window {id_window}s != data.window_sec {data['window_sec']}")
    ck = cfg["checkpoint"]
    if (not isinstance(ck, Mapping) or set(ck) != {"file", "sha256", "size", "source", "url"}
            or not isinstance(ck["file"], str) or not is_sha256_hex(ck["sha256"])
            or not isinstance(ck["size"], int) or ck["size"] <= 0 or not isinstance(ck["source"], str)
            or not (ck["url"] is None or isinstance(ck["url"], str))):
        raise EncoderConfigError("checkpoint must be {file:str, sha256:hex64, size:int>0, source:str, url:str|null}")
    if cfg["inertia_repo_commit"] != UPSTREAM_COMMIT:
        raise EncoderConfigError(f"inertia_repo_commit must be {UPSTREAM_COMMIT}")
    if cfg["extraction_point"] != EXTRACTION_POINTS[method]:
        raise EncoderConfigError(f"extraction_point must be {EXTRACTION_POINTS[method]!r}")
    if cfg["embedding_dim"] != want["d_model"] or isinstance(cfg["embedding_dim"], bool):
        raise EncoderConfigError(f"embedding_dim must equal d_model ({want['d_model']})")
    if cfg["input_contract"] != InputContract(window_s=data["window_sec"]).config_dict():
        raise EncoderConfigError(f"input_contract must be {InputContract(window_s=30).config_dict()}")
    return json.loads(json.dumps(cfg))


def load_encoder_config(source: Union[str, Mapping[str, Any]]) -> Tuple[Dict[str, Any], str]:
    """(validated config, base directory) from a path to encoder.json or an in-memory dict."""
    if isinstance(source, Mapping):
        return validate_encoder_config(source), os.getcwd()
    if not isinstance(source, str) or not os.path.isfile(source):
        raise FileNotFoundError(f"encoder config not found: {source}")
    with open(source, "r", encoding="utf-8") as f:
        try:
            cfg = json.load(f)
        except json.JSONDecodeError as exc:
            raise EncoderConfigError(f"encoder config is not valid JSON: {exc}") from exc
    return validate_encoder_config(cfg), os.path.dirname(os.path.abspath(source))


def check_against_preprocessing(cfg: Mapping[str, Any], preprocessing: Mapping[str, Any]) -> None:
    """Load step 3: encoder data.window_sec/hz/axes must equal the bundle's preprocessing."""
    d = cfg["data"]
    got = (d["window_sec"], d["hz"], d["axes"])
    want = (preprocessing.get("window_s"), preprocessing.get("rate_hz"), len(preprocessing.get("axes") or ()))
    if got != want:
        raise EncoderConfigError(f"encoder (window_sec, hz, axes) {got} != bundle preprocessing {want}")


def build_module(method: str, arch: Mapping[str, Any], window_s: int, hz: int = INERTIA_RATE_HZ):
    """Instantiate the vendored encoder module (torch imported lazily)."""
    if arch["d_model"] % arch["n_heads"]:
        raise EncoderConfigError("d_model must be divisible by n_heads")
    if method == "ar_transformer":
        from .vendor.ar_transformer import ARTransformerEncoder
        return ARTransformerEncoder(channels=len(INERTIA_AXES), patch_len=arch["patch_len"],
                                    d_model=arch["d_model"], n_heads=arch["n_heads"], n_layers=arch["n_layers"],
                                    d_ff=arch["d_ff"], dropout=arch["dropout"])
    if method == "patchtst":
        from .vendor.patchtst import PatchTSTEncoder
        return PatchTSTEncoder(window_samples=int(window_s) * int(hz), patch_len=arch["patch_len"],
                               stride=arch["stride"], n_layers=arch["n_layers"], d_model=arch["d_model"],
                               n_heads=arch["n_heads"], d_ff=arch["d_ff"], attn_dropout=arch["attn_dropout"],
                               dropout=arch["dropout"], act=arch["act"], res_attention=arch["res_attention"],
                               pre_norm=arch["pre_norm"], learn_pe=arch["learn_pe"],
                               head_dropout=arch["head_dropout"])
    raise EncoderConfigError(f"unknown method {method!r}")

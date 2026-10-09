"""Frozen encoder adapters. Missing checkpoints fail; random weights are never a substitute."""
from __future__ import annotations

from pathlib import Path
import hashlib
import importlib
import json
import subprocess
import sys

import numpy as np

from scipy.signal import resample_poly
from fractions import Fraction

def resample_dense(x, source, target):
    ratio = Fraction(target / source).limit_denominator(10000)
    return resample_poly(x, ratio.numerator, ratio.denominator, axis=0)


CATALOG = {
    "harnet5": dict(seconds=5, sample_rate=30, channels=3, dimensions=512, modality="acceleration_g"),
    "harnet10": dict(seconds=10, sample_rate=30, channels=3, dimensions=1024, modality="acceleration_g"),
    "harnet30": dict(seconds=30, sample_rate=30, channels=3, dimensions=1024, modality="acceleration_g"),
    "sensori": dict(seconds=86400, sample_rate=10, channels=3, dimensions=768, modality="acceleration_g"),
    "normwear": dict(seconds=None, sample_rate=None, channels=None, dimensions="768 * channels", modality="physiological_waveforms"),
    "normwear2": dict(seconds=None, sample_rate=None, channels=None, dimensions="768 * channels", modality="multivariate_series"),
}


def digest(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def git_revision(path):
    p = subprocess.run(["git", "-C", str(path), "rev-parse", "HEAD"], capture_output=True, text=True)
    return p.stdout.strip() if p.returncode == 0 else "not_a_git_checkout"


class FrozenEncoder:
    def __init__(self, name, source=None, checkpoint=None, config=None):
        import torch
        if name not in CATALOG:
            raise ValueError(f"Unknown encoder: {name}")
        self.name, self.torch = name, torch
        self.spec = CATALOG[name]
        torch.set_num_threads(1)
        self.provenance = dict(encoder=name, adapter_version="1", frozen=True, source_revision=git_revision(source) if source else None)
        if name.startswith("harnet"):
            if source is None:
                raise ValueError("HARNet requires a local ssl-wearables checkout")
            source = Path(source).resolve()
            filenames = {"harnet5": "mtl_5_best.mdl", "harnet10": "mtl_best.mdl", "harnet30": "mtl_30_best.mdl"}
            checkpoint = Path(checkpoint) if checkpoint else source / "model_check_point" / filenames[name]
            if not checkpoint.is_file():
                raise FileNotFoundError(checkpoint)
            # Instantiate architecture only, then verify every feature parameter against the checkpoint.
            self.model = torch.hub.load(str(source), name, source="local", pretrained=False)
            weights = torch.load(checkpoint, map_location="cpu", weights_only=True)
            weights = weights.get("state_dict", weights)
            weights = {k.removeprefix("module."): v for k, v in weights.items()}
            required = {k for k, _ in self.model.named_parameters() if k.startswith("feature_extractor.")}
            absent = required - weights.keys()
            if absent:
                raise ValueError(f"Checkpoint does not cover feature extractor parameters: {sorted(absent)[:5]}")
            target = self.model.state_dict()
            feature_weights = {k: v for k, v in weights.items() if k.startswith("feature_extractor.") and k in target}
            self.model.load_state_dict(feature_weights, strict=False)
        elif name == "normwear":
            if source is None or checkpoint is None:
                raise ValueError("NormWear requires its local repository and pretrained checkpoint")
            source = Path(source).resolve()
            sys.path.insert(0, str(source.parent))
            cls = importlib.import_module(f"{source.name}.main_model").NormWearModel
            self.model = cls(weight_path=str(checkpoint), optimized_cwt=True)
        elif name == "normwear2":
            if checkpoint is None or not Path(checkpoint).is_dir():
                raise ValueError("NormWear-2 requires a local Hugging Face snapshot directory")
            # Import the complete local package explicitly. Some transformers releases miss
            # transitive relative imports when copying a local custom model into their cache.
            from importlib import util
            root = Path(checkpoint).resolve()
            package_name = "forecast_normwear2_" + hashlib.sha256(str(root).encode()).hexdigest()[:12]
            package_spec = util.spec_from_file_location(package_name, root / "__init__.py", submodule_search_locations=[str(root)])
            package = util.module_from_spec(package_spec)
            sys.modules[package_name] = package
            package_spec.loader.exec_module(package)
            configuration = package.NormWear2Config.from_pretrained(str(root), local_files_only=True)
            self.model = package.NormWear2Model.from_pretrained(str(root), config=configuration, local_files_only=True)
        else:
            if source is not None:
                # Upstream maps its src directory to the sensori package. Import the inference
                # subset directly without installing training/notebook dependencies.
                import types
                package = types.ModuleType("sensori")
                package.__path__ = [str(Path(source).resolve() / "src")]
                sys.modules["sensori"] = package
            from sensori.sensori import load_sensori
            from omegaconf import OmegaConf
            if checkpoint is None or config is None:
                raise ValueError("Sensori requires installed upstream package plus local checkpoint/config")
            self.model = load_sensori(str(checkpoint), OmegaConf.load(config), "cpu")
        self.model.to("cpu").eval()
        for parameter in self.model.parameters():
            parameter.requires_grad_(False)
        cp = Path(checkpoint)
        if cp.is_dir():
            files = sorted(p for p in cp.rglob("*") if p.is_file() and p.suffix in {".safetensors", ".bin", ".json", ".py"})
            if not any(p.suffix in {".safetensors", ".bin"} for p in files):
                raise ValueError("Snapshot has no weight files")
            self.provenance["checkpoint_files"] = {str(p.relative_to(cp)): digest(p) for p in files}
        else:
            self.provenance["checkpoint_sha256"] = digest(cp)

    def encode(self, values, sample_rate, channels, units):
        """Encode one complete window [samples, channels], returning a flat float32 vector."""
        torch = self.torch
        x = np.asarray(values, dtype=np.float32)
        if x.ndim != 2 or len(channels) != x.shape[1] or len(units) != x.shape[1] or not np.isfinite(x).all():
            raise ValueError("Invalid waveform shape/metadata or missing samples")
        if self.spec["modality"] == "acceleration_g":
            if tuple(channels) != ("ax", "ay", "az") or tuple(units) != ("g", "g", "g"):
                raise ValueError("Oxford motion encoders require ax, ay, az in g; no gyro or sparse gravity substitution")
            seconds = self.spec["seconds"]
            if len(x) != round(seconds * sample_rate):
                raise ValueError(f"{self.name} requires exactly {seconds} seconds")
            x = resample_dense(x, sample_rate, self.spec["sample_rate"])
        with torch.inference_mode():
            if self.name.startswith("harnet"):
                out = self.model.feature_extractor(torch.from_numpy(x.T.copy())[None]).flatten(1)
            elif self.name == "sensori":
                # DayDataset.collate_fn reshapes disk (2880,300,3) into 1440 minute
                # windows. Five consecutive minute features become each transformer token.
                out = self.model(torch.from_numpy(x.reshape(1440, 600, 3))[None], output="embedding")
            elif self.name == "normwear":
                if sample_rate > 256:
                    # The released helper's high-rate branch passes ndarray to torchaudio.
                    # Resample explicitly, recording this adapter choice, before its CWT path.
                    x = resample_dense(x, sample_rate, 65)
                    sample_rate = 65
                out = self.model.get_embedding(torch.from_numpy(x.T.copy())[None], sampling_rate=sample_rate, device=torch.device("cpu"))
                out = out.mean(dim=2).flatten(1)
            else:
                patch = self.model.config.patch_size
                if len(x) % patch:
                    raise ValueError(f"NormWear-2 needs a length divisible by {patch}; explicit windowing is required")
                if len(x) // patch > self.model.config.max_in_length:
                    raise ValueError("Window exceeds this NormWear-2 checkpoint's configured token context")
                out = self.model.normwear.get_embedding(torch.from_numpy(x.T.copy())[None], criteria="mean")
        vector = out.detach().cpu().numpy().reshape(-1).astype(np.float32)
        expected = self.spec["dimensions"] if isinstance(self.spec["dimensions"], int) else 768 * x.shape[1]
        if vector.shape != (expected,) or not np.isfinite(vector).all():
            raise ValueError(f"Unexpected {self.name} output: {vector.shape}, expected {(expected,)}")
        return vector

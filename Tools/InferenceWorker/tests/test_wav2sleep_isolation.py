"""wav2sleep stays dormant: unregistered, unreferenced by production paths (WAV2SLEEP.md §12).

Registration is a deliberate edit to Spec 01's files (docs/pretrained-models/integration/wav2sleep.md) and must
only happen once every gate in ``constants.ACTIVATION_GATES`` is met. These tests make that edit visible.
"""

import os

import pytest

from frwhoop_inference.frwhoop_sleep.wav2sleep import constants as C

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
IW = os.path.join(REPO, "Tools", "InferenceWorker")
SLEEP = os.path.join(IW, "src", "frwhoop_inference", "frwhoop_sleep")
OWN = (os.path.join(SLEEP, "wav2sleep") + os.sep, os.path.join(SLEEP, "wav2sleep_vendored") + os.sep,
       os.path.join(IW, "tests", "test_wav2sleep_"), os.path.join(IW, "tests", "wav2sleep_"))
# Case-insensitive. A bare "wav2sleep" is not a token: the manifest's existing blocked_input entry carries that id.
TOKENS = tuple(t.lower() for t in ("frwhoop_sleep.wav2sleep", "from .wav2sleep", "from ..wav2sleep", "wav2sleep import",
                                   "Wav2SleepPpgProvider", "Wav2SleepRegistryShim", C.PROVIDER_ID,
                                   "FRWHOOP_WAV2SLEEP", "wav2sleep_providers"))
PRODUCTION_ROOTS = ("Tools/InferenceWorker", "Tools/CloudWorker", "Tools/ActivityContext", "supabase", "Packages",
                    "Strand", "StrandiOS", "StrandiOSShared", "deploy", "Config", "contracts")
SKIP_SUFFIXES = (".md", ".png", ".jpg", ".pdf", ".npz", ".pt", ".pth", ".bin", ".zip", ".gz", ".parquet", ".lock")


def _full_checkout_or_skip():
    if not (os.path.isdir(os.path.join(REPO, "Tools", "CloudWorker")) and os.path.exists(os.path.join(REPO, ".git"))):
        if os.environ.get("CI"):
            pytest.fail("isolation guard needs the full repository checkout in CI")
        pytest.skip("not running from a full repository checkout")


def _offenders(repo, files):
    hits = []
    for path in files:
        if os.path.abspath(path).startswith(OWN) or path.endswith(SKIP_SUFFIXES):
            continue
        try:
            if os.path.getsize(path) > 4 * 1024 * 1024:
                continue
            text = open(path, encoding="utf-8", errors="ignore").read().lower()
        except OSError:
            continue
        hits += [f"{os.path.relpath(path, repo)}: {t}" for t in TOKENS if t in text]
    return hits


def test_no_production_path_registers_or_names_the_adapter():
    import subprocess
    _full_checkout_or_skip()
    out = subprocess.run(["git", "-C", REPO, "ls-files", "-z", "--", *PRODUCTION_ROOTS], capture_output=True, check=True)
    files = [os.path.join(REPO, p) for p in out.stdout.decode("utf-8").split("\0") if p]
    assert len(files) > 1000
    assert _offenders(REPO, files) == []


def test_the_manifest_entry_stays_unwired_and_blocked():
    import json
    entry = [e for e in json.load(open(os.path.join(IW, "models", "manifest.json")))["entries"] if e["id"] == "wav2sleep"]
    assert len(entry) == 1 and entry[0]["wired"] is False and entry[0]["status"] == "blocked_input"


def test_the_guard_would_catch_wiring(tmp_path):
    unit = tmp_path / "frwhoop-inference.service"
    unit.write_text("Environment=FRWHOOP_WAV2SLEEP_SHADOW_ENABLED=1\n")
    shim = tmp_path / "__init__.py"
    shim.write_text("from .wav2sleep import make_providers\n")
    assert _offenders(str(tmp_path), [str(unit), str(shim)]) == [
        "frwhoop-inference.service: frwhoop_wav2sleep", "__init__.py: from .wav2sleep", "__init__.py: wav2sleep import"]


def test_default_registry_has_no_wav2sleep_provider():
    from frwhoop_inference.providers import default_providers
    ids = {getattr(p, "provider_id", None) for p in default_providers()}
    assert C.PROVIDER_ID not in ids
    assert not any("wav2sleep" in str(i) for i in ids)


def test_activation_gates_are_the_six_admission_gates():
    assert len(C.ACTIVATION_GATES) == 6 and len(set(C.ACTIVATION_GATES)) == 6


def test_disabled_provider_claims_no_loaded_artifacts():
    from frwhoop_inference.frwhoop_sleep.wav2sleep.provider import Wav2SleepPpgProvider
    loaded = Wav2SleepPpgProvider(model_root="/nonexistent", enabled=False).loaded_identity()
    assert loaded["enabled"] == "False" and loaded["loaded"] == "False"
    assert "artifact_digest" not in loaded and not any(k.endswith(".sha256") for k in loaded)

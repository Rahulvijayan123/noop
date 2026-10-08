"""wav2sleep stays dormant: unregistered, unreferenced by production paths (WAV2SLEEP.md §12).

Registration is a deliberate edit to Spec 01's files (docs/pretrained-models/integration/wav2sleep.md) and must
only happen once every gate in ``constants.ACTIVATION_GATES`` is met. These tests make that edit visible.
"""

import os

import pytest

from frwhoop_inference.frwhoop_sleep.wav2sleep import constants as C

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
OWN = (os.path.join(REPO, "Tools", "InferenceWorker", "src", "frwhoop_inference", "frwhoop_sleep", "wav2sleep"),
       os.path.join(REPO, "Tools", "InferenceWorker", "src", "frwhoop_inference", "frwhoop_sleep", "wav2sleep_vendored"))
TOKENS = ("frwhoop_sleep.wav2sleep", "Wav2SleepPpgProvider", C.PROVIDER_ID, "FRWHOOP_WAV2SLEEP_SHADOW_ENABLED")
PRODUCTION_ROOTS = ("Tools/InferenceWorker/src", "Tools/CloudWorker/Sources", "supabase", "Packages", "Strand",
                    "StrandiOS", "StrandiOSShared", "deploy")
SUFFIXES = (".py", ".swift", ".ts", ".sql", ".json", ".sh", ".service", ".env", ".yml", ".yaml", ".toml")


def test_no_production_path_registers_or_names_the_adapter():
    if not os.path.isdir(os.path.join(REPO, "Tools", "CloudWorker")):
        pytest.skip("not running from a full repository checkout")
    hits = []
    for rel in PRODUCTION_ROOTS:
        for d, dirs, files in os.walk(os.path.join(REPO, rel)):
            dirs[:] = [x for x in dirs if x not in ("__pycache__", "node_modules", ".build", ".venv")]
            if os.path.abspath(d).startswith(OWN):
                continue
            for name in files:
                if name.endswith(SUFFIXES):
                    text = open(os.path.join(d, name), encoding="utf-8", errors="ignore").read()
                    hits += [f"{os.path.relpath(os.path.join(d, name), REPO)}: {t}" for t in TOKENS if t in text]
    assert hits == []


def test_default_registry_has_no_wav2sleep_provider():
    from frwhoop_inference.providers import default_providers
    ids = {getattr(p, "provider_id", None) for p in default_providers()}
    assert C.PROVIDER_ID not in ids
    assert not any("wav2sleep" in str(i) for i in ids)


def test_activation_gates_are_the_six_admission_gates():
    assert len(C.ACTIVATION_GATES) == 6 and len(set(C.ACTIVATION_GATES)) == 6

"""Providers and sleep-feature entry points for the execution tests.

They live at module level, not inside test functions, because the sidecar runs every
computation in a worker process: the parent pickles its registry and the worker imports
these classes by name (the worker receives the parent's ``sys.path``, so this module is
importable there exactly as it is in the test process).
"""

from __future__ import annotations

import os
import signal
import time

from frwhoop_inference.contract import ProviderResult
from frwhoop_inference.providers.hrv import HrvProductionProvider

#: When set, probe providers append ``<event> <pid>`` lines here.
PROBE_FILE_ENV = "FRWHOOP_TEST_PROBE_FILE"


def _probe(event: str) -> None:
    path = os.environ.get(PROBE_FILE_ENV)
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(f"{event} {os.getpid()}\n")


class UnreadyProvider(HrvProductionProvider):
    provider_id = "unready.runs.v1"

    def readiness(self):
        return False, "blocked_license: not licensed for product use"


class SlowProvider(HrvProductionProvider):
    """Blocks (sleeps) for ``seconds``: an overrun that is waiting, not computing."""

    provider_id = "slow.runs.v1"

    def __init__(self, seconds: float = 5.0):
        super().__init__()
        self.seconds = float(seconds)

    def infer(self, request):
        time.sleep(self.seconds)
        return ProviderResult(status="ok", value=1.0, unit="ms")


class SpinningProvider(HrvProductionProvider):
    """Burns CPU in pure Python for ``seconds``: the overrun a daemon thread could never stop."""

    provider_id = "spin.runs.v1"

    def __init__(self, seconds: float = 30.0):
        super().__init__()
        self.seconds = float(seconds)

    def infer(self, request):
        _probe("spin")
        deadline = time.monotonic() + self.seconds
        x = 0
        while time.monotonic() < deadline:
            x = (x * 31 + 7) % 1_000_003
        return ProviderResult(status="ok", value=float(x % 100), unit="ms")


class ExplodingProvider(HrvProductionProvider):
    provider_id = "boom.runs.v1"

    def infer(self, request):
        raise RuntimeError("kaboom")


class CrashingProvider(HrvProductionProvider):
    """Kills its own process mid-request (a segfault or an OOM kill, as far as the parent can tell)."""

    provider_id = "crash.runs.v1"

    def infer(self, request):
        os.kill(os.getpid(), signal.SIGKILL)
        time.sleep(10)  # pragma: no cover - the signal ends the process first


class ProbeProvider(HrvProductionProvider):
    """Records where it is warmed and where it computes, and what thread caps it sees."""

    provider_id = "probe.runs.v1"

    def readiness(self):
        _probe("warm")
        return super().readiness()

    def infer(self, request):
        _probe("infer")
        result = super().infer(request)
        result.diagnostics = dict(result.diagnostics or {})
        result.diagnostics["probe"] = {
            "pid": os.getpid(),
            "env": {name: os.environ.get(name) for name in (
                "OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS",
                "NUMEXPR_NUM_THREADS", "VECLIB_MAXIMUM_THREADS")},
        }
        return result


def sleepy_compute(request, budget_ms: int = 3000):
    """A sleep-features entry point that overruns any budget."""
    time.sleep(30)
    return {}  # pragma: no cover


def spinning_compute(request, budget_ms: int = 3000):
    deadline = time.monotonic() + 30
    x = 0
    while time.monotonic() < deadline:
        x = (x * 31 + 7) % 1_000_003
    return {}  # pragma: no cover


def crashing_compute(request, budget_ms: int = 3000):
    os.kill(os.getpid(), signal.SIGKILL)
    time.sleep(10)  # pragma: no cover


def raising_compute(request, budget_ms: int = 3000):
    raise ValueError("feature module exploded")

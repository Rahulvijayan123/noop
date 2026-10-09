"""Registry presentation of the wav2sleep provider (reuses the sleep ``RegistryShim`` as-is)."""

from __future__ import annotations

from typing import Any

from ..registry_adapter import RegistryShim
from . import constants as C


class Wav2SleepRegistryShim(RegistryShim):
    """``RegistryShim`` + the release mode in the capability + :meth:`runtime_identity`.

    The shim's mapping is unchanged: ``withheld`` keeps the provider's enum reason, ``ok`` carries
    ``stages`` (label runs) and ``raw_scores`` (the per-epoch columns), ``publishable`` is False.
    The shim's scalar ``value`` for an ``ok`` result is the scored seconds (a coverage summary,
    exactly like the sibling ``sleepecg.wrn-gru-mesa.v1``), never a sleep metric.
    """

    def __init__(self, provider: Any):
        super().__init__(
            provider,
            eligibility_state="blocked_input",
            eligibility_reason=("shadow-only; no anchored, contiguous overnight PPG reaches the "
                                "server yet and there is no WHOOP sleep-stage evaluation set"),
            publishable=False,
        )

    def capability(self) -> dict:
        capability = super().capability()
        capability["release_mode"] = C.RELEASE_MODE
        capability["publishable"] = False
        return capability

    def runtime_identity(self) -> dict:
        return self._provider.runtime_identity()

    def loaded_identity(self) -> dict:
        return self._provider.loaded_identity()

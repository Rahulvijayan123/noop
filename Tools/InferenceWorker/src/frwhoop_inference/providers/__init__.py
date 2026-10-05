"""Provider registry.

A provider declares its metric, its versions, its readiness and its
capability block, and exposes one ``infer`` call. Providers never raise on bad
input: they return a :class:`~frwhoop_inference.contract.ProviderResult` whose
status is ``withheld`` or ``error``. The server owns HTTP mapping.
"""

from __future__ import annotations

from typing import Iterable, Protocol, Sequence

from ..contract import InferRequest, ProviderResult
from .hrv import (
    DEFAULT_TUNING,
    PRODUCTION_PROVIDER_ID,
    SHADOW_PROVIDER_ID,
    HrvNeurokitShadowProvider,
    HrvProductionProvider,
)

__all__ = [
    "Provider",
    "ProviderRegistry",
    "default_providers",
    "HrvProductionProvider",
    "HrvNeurokitShadowProvider",
    "PRODUCTION_PROVIDER_ID",
    "SHADOW_PROVIDER_ID",
    "DEFAULT_TUNING",
]


class Provider(Protocol):
    """The registry surface every provider must expose."""

    provider_id: str
    metric: str
    mode: str
    label_space: str | None
    required_signals: tuple[str, ...]
    eligibility_state: str
    eligibility_reason: str | None

    def versions(self, request: InferRequest | None = None) -> dict: ...

    def readiness(self) -> tuple[bool, str | None]: ...

    def capability(self) -> dict: ...

    def infer(self, request: InferRequest) -> ProviderResult: ...


class ProviderRegistry:
    """Ordered registry. Registration order is the listing order."""

    def __init__(self, providers: Sequence[Provider] | None = None):
        self._providers: dict[str, Provider] = {}
        for provider in providers or ():
            self.register(provider)

    def register(self, provider: Provider) -> None:
        if not provider.provider_id:
            raise ValueError("provider_id must not be empty")
        self._providers[provider.provider_id] = provider

    def get(self, provider_id: str) -> Provider | None:
        return self._providers.get(provider_id)

    def all(self) -> list[Provider]:
        return list(self._providers.values())

    def for_metric(self, metric: str) -> list[Provider]:
        return [p for p in self._providers.values() if p.metric == metric]

    def default_for_metric(self, metric: str) -> Provider | None:
        """The provider used when the request does not name one.

        Prefer a publishable (authoritative) provider; otherwise fall back to the
        first registered provider for the metric.
        """
        candidates = self.for_metric(metric)
        for provider in candidates:
            if provider.capability().get("publishable", False):
                return provider
        return candidates[0] if candidates else None


def default_providers() -> list[Provider]:
    """The providers wired in this build.

    HRV production + HRV shadow, plus the two retrospective sleep candidates
    (``hypnospy.hr-boundary.v1`` and ``sleepecg.wrn-gru-mesa.v1``). The sleep candidates are
    registered as non-publishable shadow providers: they never feed canonical values, and
    their accuracy is unverified (spec section 8).
    """
    from ..frwhoop_sleep.registry_adapter import sleep_providers

    return [HrvProductionProvider(), HrvNeurokitShadowProvider(), *sleep_providers()]

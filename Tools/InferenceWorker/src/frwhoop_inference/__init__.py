"""FRWHOOP physiology inference sidecar.

Loopback-only HTTP service exposing versioned physiology providers to the
FRWHOOP Swift worker. See ``README.md`` for the operational contract.
"""

from .contract import (
    ADAPTER_VERSION,
    CONTRACT_VERSION,
    METRICS,
    PACKAGE_VERSION,
    SERVER_NAME,
    STATUSES,
    ContractError,
    ProviderResult,
    WithheldReason,
)

__all__ = [
    "ADAPTER_VERSION",
    "CONTRACT_VERSION",
    "METRICS",
    "PACKAGE_VERSION",
    "SERVER_NAME",
    "STATUSES",
    "ContractError",
    "ProviderResult",
    "WithheldReason",
]

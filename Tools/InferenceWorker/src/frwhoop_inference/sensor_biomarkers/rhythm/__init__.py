"""Rhythm shadow adapters: DeepBeat (disabled research) + optional SiamAF comparator.

Owned by W4 (spec 6.6/6.7; CONTRACTS.md sections 1-4, 7). Real weights, real
execution, no clinical outputs, never user-facing.

* ``deepbeat.py``  - DeepBeat adapter (GPL-3.0 artifact; keras 3 + torch backend).
* ``siamaf.py``    - SiamAF adapter (MIT artifact; torch, strict load).
* ``provider.py``  - ``sensor.biomarkers.rhythm.v1`` provider +
                     :func:`compute_rhythm_shadow_document` (the one family implementation).
* ``_siamaf_vendored.py`` - minimal vendored SiamAF architecture (MIT, attributed).

``FAMILIES``, ``adapter_state`` and ``compute_family_documents`` are the
optional-family interface ``sensor.biomarkers.v1`` calls
(``sensor_biomarkers/optional.py``).

Fail-closed by design: importing this package pulls in only numpy/scipy; keras
and torch are imported lazily inside the adapters, and a missing artifact or a
broken dependency makes ``make_providers()`` still succeed while the family
answers ``family_disabled`` / ``artifact_unavailable``. The rhythm family is
disabled by default (``FRWHOOP_DEEPBEAT_SHADOW_ENABLED`` /
``FRWHOOP_SIAMAF_SHADOW_ENABLED`` must each be exactly ``"1"``).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from .provider import ADAPTER_NAME, FAMILIES, adapter_state, compute_family_documents

if TYPE_CHECKING:  # pragma: no cover
    from ...providers import Provider

#: Versions the rhythm stage reports (CONTRACTS.md section 1).
DEEPBEAT_REVISION = "deepbeat/1.0.0"
SIAMAF_REVISION = "siamaf/1.0.0"
FAMILY = "rhythm_shadow"


def make_providers() -> list["Provider"]:
    """One rhythm shadow provider (fail-closed; heavy runtimes load lazily)."""
    from .provider import make_providers as _make

    return _make()


__all__ = ["make_providers", "DEEPBEAT_REVISION", "SIAMAF_REVISION", "FAMILY",
           "ADAPTER_NAME", "FAMILIES", "adapter_state", "compute_family_documents"]

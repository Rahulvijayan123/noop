"""ParaDigMa tremor + arm_swing research families (actual upstream package + pinned assets).

Owned by W3. Uses the REAL ParaDigMa 1.1.2 package (pinned upstream tree
``4735d6d21b2a62b764a0bc7e0f677577e6ce1668``) and the REAL pretrained
classifier assets, executed in a narrow optional subprocess environment so
the main inference env's scikit-learn 1.9.1 pin is untouched (spec section
6.3; the tremor pickle records sklearn 1.6.0 and the package requires
``scikit-learn <1.6.1``).

``FAMILIES``, ``adapter_state`` and ``compute_family_documents`` are the
optional-family interface ``sensor.biomarkers.v1`` calls
(``sensor_biomarkers/optional.py``); ``make_providers`` registers the
standalone ``sensor.biomarkers.paradigma.v1`` over the same implementation.

Fail-closed rules (CONTRACTS.md sections 3/7, enforced in tests):

* the families run ONLY when the env flag (FRWHOOP_PARADIGMA_ENABLED == "1")
  is set AND every pinned artifact in the manifest entry ``paradigma``
  verifies against the artifact root AND the subprocess python exists;
  otherwise they are withheld ``family_disabled`` / ``artifact_unavailable``
  / ``runtime_unavailable`` and the standalone provider is not registered,
  so a missing optional artifact never breaks the descriptive families;
* only manifest-verified bytes are ever unpickled (verified by the runner
  before ``run_paradigma`` loads any pickle);
* a zero-eligible family publishes null burden/frequency, never a
  percentage of the whole day;
* unknown wrist placement / device orientation withholds arm_swing only;
  tremor (coordinate-invariant) keeps running;
* the WHOOP 5 axis convention is UNVERIFIED (WHOOP publishes none), so
  arm_swing is currently withheld with ``unknown_orientation`` until the
  mapping is evidenced from real captures (see ``axes.py``).
"""

from __future__ import annotations

from typing import TYPE_CHECKING

from .provider import (
    ADAPTER_NAME,
    FAMILIES,
    UPSTREAM_COMMIT,
    ParadigmaProvider,
    adapter_state,
    compute_family_documents,
)

if TYPE_CHECKING:  # pragma: no cover
    from ...providers import Provider

__all__ = ["make_providers", "ParadigmaProvider", "UPSTREAM_COMMIT", "ADAPTER_NAME",
           "FAMILIES", "adapter_state", "compute_family_documents"]


def make_providers() -> list["Provider"]:
    """Register the research provider only when it can actually run.

    Fail-closed: any gate failure yields no provider, so the optional lane
    can never break startup or the descriptive families.
    """
    from .provider import make_providers as _make

    return _make()

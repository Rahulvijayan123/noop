"""ParaDigMa tremor + arm_swing research families (actual upstream package + pinned assets).

Owned by W3. Uses the REAL ParaDigMa 1.1.2 package (pinned upstream tree
``4735d6d21b2a62b764a0bc7e0f677577e6ce1668``) and the REAL pretrained
classifier assets, executed in a narrow optional subprocess environment so
the main inference env's scikit-learn 1.9.1 pin is untouched (spec section
6.3; the tremor pickle records sklearn 1.6.0 and the package requires
``scikit-learn <1.6.1``).

Fail-closed rules (CONTRACTS.md sections 3/7, enforced in tests):

* ``make_providers()`` registers the provider ONLY when the env flag
  (FRWHOOP_PARADIGMA_ENABLED == "1") is set AND every pinned artifact in the
  manifest entry ``paradigma`` verifies against the artifact root AND the
  subprocess python exists. A missing optional artifact therefore never
  breaks readiness of the descriptive families;
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

if TYPE_CHECKING:  # pragma: no cover
    from ...providers import Provider

__all__ = ["make_providers", "ParadigmaProvider", "UPSTREAM_COMMIT"]


def make_providers() -> list["Provider"]:
    """Register the research provider only when it can actually run.

    Fail-closed: any gate failure yields no provider, so the optional lane
    can never break startup or the descriptive families.
    """
    from .provider import make_providers as _make

    return _make()

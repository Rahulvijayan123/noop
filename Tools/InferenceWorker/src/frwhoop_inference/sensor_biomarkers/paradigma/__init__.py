"""ParaDigMa tremor + arm_swing research families (actual upstream package + pinned assets).

Owned by W3. Stub until implemented; a missing artifact or dependency must fail closed
(``not_ready`` + ``artifact_unavailable``), never break the descriptive families.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:  # pragma: no cover
    from ...providers import Provider


def make_providers() -> list["Provider"]:
    return []

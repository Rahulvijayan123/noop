"""PPG quality + pulse shape families (NeuroKit2 0.2.13, pinned).

Owned by W2 (deterministic algorithms). Stub: returns no providers until implemented.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:  # pragma: no cover
    from ..providers import Provider


def make_providers() -> list["Provider"]:
    return []

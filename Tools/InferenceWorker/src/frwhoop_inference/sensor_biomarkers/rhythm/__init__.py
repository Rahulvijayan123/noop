"""Rhythm shadow adapters: DeepBeat (disabled research) + optional SiamAF comparator.

Owned by W4. Stub until implemented; outputs are model score vectors in shadow logs
only, withheld with ``preprocessing_unverified`` until original preprocessing is traced.
"""

from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:  # pragma: no cover
    from ...providers import Provider


def make_providers() -> list["Provider"]:
    return []

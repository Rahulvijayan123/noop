"""Candidate providers for the FRWHOOP physiology migration.

The two providers have deliberately independent import graphs (the boundary provider needs
pandas; the stager needs sleepecg + keras), so this package resolves them lazily. Import the
module you need directly, or use the lazy attribute access below.
"""

from __future__ import annotations

__all__ = ["SLEEP_BOUNDARY_PROVIDER", "SLEEP_STAGE_PROVIDER", "register_all"]


def __getattr__(name: str):
    if name == "SLEEP_BOUNDARY_PROVIDER":
        from .sleep_boundary import PROVIDER

        return PROVIDER
    if name == "SLEEP_STAGE_PROVIDER":
        from .sleep_stage import PROVIDER

        return PROVIDER
    raise AttributeError("module %r has no attribute %r" % (__name__, name))


def register_all(registry: dict) -> dict:
    """Register every available provider in a ``{metric: provider}`` registry."""
    from .sleep_boundary import PROVIDER as boundary
    from .sleep_stage import PROVIDER as stage

    boundary.register(registry)
    stage.register(registry)
    return registry

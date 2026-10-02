"""FRWHOOP sleep candidates: HypnosPy HR sleep boundaries and SleepECG wrn-gru-mesa staging.

Layout
------
``timebase.py``            shared IANA wake-date / analysis-block / gap / hashing helpers
``hypnospy_vendored/``     vendored HypnosPy HR boundary algorithm (pinned 3b6c825d + patch set)
``providers/``             the two candidate providers
``registry_adapter.py``    presents them through the ``frwhoop_inference`` registry protocol

Both providers are retrospective, non-publishable candidates: they never write the canonical
four-stage fields, and their accuracy is ``unverified_accuracy``.

``sleep_boundary`` result conventions
-------------------------------------
* ``sleep_onset`` and ``final_wake`` both span the whole sleep period: read
  ``sleep_onset.start_utc`` for the onset and ``final_wake.end_utc`` for the final wake.
* the sleep period is bounded by the first and last accepted sleep piece **inside the selected
  in-bed interval**, so scored-awake time between them is ``waso`` (a fragmented night reports
  real WASO). Unscored wear-gap epochs between them stay in ``unscored``.
* ``nap`` is a sleep episode inside the analysis block but **outside** the selected in-bed
  window (typically a daytime sleep found by a re-parameterised search window).
* ``input.window {start_utc, end_utc}`` overrides the context interval as the in-bed interval;
  ``diagnostics.in_bed_source`` records which was used. ``input.config`` is honoured by both
  providers, and an unknown key is a typed ``unknown_config`` error.
"""

from __future__ import annotations

__all__ = ["registry_adapter", "timebase"]

__version__ = "1.0.0"

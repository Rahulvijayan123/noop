"""Canonical data reason codes (contracts/reason-codes.json, `data-reason-1`) for what the service publishes.

`anomaly_window_scores.withheld_reason` keeps the service's own short values (readers and stored rows depend on
them); every published window row also carries `reason_code` ("code" or "code/subcode") and `reason_certainty`
from the contract's `legacy.anomaly_withheld` table below. The table is a copy because the service is installed on
the VPS without the repository's contracts directory; tests/test_reasons.py pins it to the contract file.
"""

from __future__ import annotations

CONTRACT_VERSION = "data-reason-1"

# withheld_reason → (code, subcode, certainty)
ANOMALY_WITHHELD: dict[str, tuple[str, str | None, str]] = {
  "off_wrist": ("off_wrist", None, "inferred"),
  "low_hr_coverage": ("insufficient_coverage", None, "measured"),
  "activity": ("context_not_comparable", "movement", "inferred"),
  "recovery": ("context_not_comparable", "recovery", "inferred"),
  "context_unknown": ("context_unknown", None, "unknown"),
  "calibrating": ("learning", None, "measured"),
}


def canonical(withheld_reason: str | None) -> tuple[str | None, str | None]:
  """(reason_code, certainty) for a withheld_reason; (None, None) for a scored window (no reason)."""
  if withheld_reason is None:
    return None, None
  code, sub, certainty = ANOMALY_WITHHELD[withheld_reason]
  return (f"{code}/{sub}" if sub else code), certainty

"""Nara anomaly service (VPS): TimesFM 3.0 forecast residuals + UniTS conditional reconstruction.

Model output is a CANDIDATE written to `anomaly_candidates`; the phone verifies every candidate (baseline,
activity, sensor quality, significance, independence) before anything can alert. See
docs/BASELINE_WATCHDOG_V2.md §5.
"""

__version__ = "1.0.0"

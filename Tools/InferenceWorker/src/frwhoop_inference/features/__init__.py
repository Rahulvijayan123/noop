"""Deterministic sleep-phenotype enrichment (spec `/Volumes/Untitled/Downloads/spec-25.md`).

One bounded request -> one descriptive feature document. No new composite score,
no staging replacement, no candidate promotion (see docs/SLEEP_FEATURES_CONTRACT.md).
"""

SCHEMA_VERSION = 1
ALGORITHM_VERSION = "nara-sleep-features-1"
CONFIG_VERSION = "sleep-features-defaults-1"
ROUTE = "/v1/sleep-features"
#: Initial enrichment budget (spec 7.4): three seconds per scoring pass.
BUDGET_MS = 3000

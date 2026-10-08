"""A stand-in optional-family adapter whose own dependency is missing.

Importing it fails the way an adapter with an absent optional runtime fails, so the aggregate
route's import path is exercised for real (test_family_dispatch.py).
"""

import frwhoop_missing_optional_dependency  # noqa: F401  (ModuleNotFoundError on import)

FAMILIES = ("tremor", "arm_swing")

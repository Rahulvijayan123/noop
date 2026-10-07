"""Stable names for HART's fine-grained (per-activity) output. Constants only: no numpy/torch."""

from __future__ import annotations

from typing import Dict

FINE_SCHEMA = "wisdm-act-1"

# WISDM-19 watch activity letters -> stable activity names for the fine-grained head. The coarse
# label_mapping folds these 18 classes into 4 (sitting, standing, typing, writing, clapping and folding all
# become "stationary"; stairs becomes "other_movement"); the decoder reads this distribution directly so
# none of that is lost. Never rename: persisted window documents key on these names.
WISDM_ACTIVITY_NAMES: Dict[str, str] = {
    "A": "walking", "B": "jogging", "C": "stairs", "D": "sitting", "E": "standing",
    "F": "typing", "G": "brushing_teeth", "H": "eating_soup", "I": "eating_chips",
    "J": "eating_pasta", "K": "drinking", "L": "eating_sandwich", "M": "kicking",
    "O": "playing_catch", "P": "dribbling", "Q": "writing", "R": "clapping", "S": "folding_clothes",
}

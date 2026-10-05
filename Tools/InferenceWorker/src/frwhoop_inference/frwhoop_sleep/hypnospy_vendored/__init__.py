"""Vendored HypnosPy HR sleep-boundary algorithm.

Only what the ``sleep_boundary`` candidate needs is vendored:

* ``misc.py``                          - upstream, verbatim (+ provenance header)
* ``analysis/sleep_boundary_detector.py`` - upstream, plus a documented local patch set
* ``wearable_minimal.py``              - minimal ``Wearable`` (upstream ``wearable.py`` needs
                                         h5py + the RawProcessing/CGM stack)

Pinned commit ``3b6c825d1568158cbf0058de50495e5308117d17``. See ``PROVENANCE.md`` for the
exact upstream/vendored hashes, the patch list, the license inconsistency (MIT file vs BSD
``setup.py``) and the upstream defects the adapter must neutralise.
"""

from . import misc
from .analysis.sleep_boundary_detector import SleepBoudaryDetector
from .wearable_minimal import Experiment, FrequencyNotSetError, Wearable

__all__ = [
    "Experiment",
    "FrequencyNotSetError",
    "SleepBoudaryDetector",
    "Wearable",
    "misc",
]

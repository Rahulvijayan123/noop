"""wav2sleep PPG-only shadow sleep-stage adapter (Spec 03, candidate 2).

Layout
------
``constants.py``     identity, sampling contracts, classes, gates, consumer, withheld reasons
``contract.py``      input validation of the anchored PPG transport (Spec 01 segment members)
``preprocessing.py`` run -> epochs -> the pinned resampling and z-score
``artifacts.py``     size + sha256 before load, allowlisted config build, strict state_dict load
``runtime.py``       warm model cache, one forward at a time, thread cap
``digests.py``       input / artifact / preprocessing digests and the cache key
``provider.py``      ``wav2sleep.ppg-only.v1`` (sleep-provider wire interface)
``registry.py``      registry presentation (``RegistryShim`` subclass)

The vendored model code lives in ``../wav2sleep_vendored`` (MIT, pinned 278e3046).

Importing this package imports neither torch nor the vendored model; both load lazily.
Nothing here is registered by default: see docs/pretrained-models/integration/wav2sleep.md.
"""

from __future__ import annotations

from .constants import (ADAPTER_VERSION, CLASS_ORDER, LABEL_SPACE, METRIC, PROVIDER_ID,
                        RELEASE_MODE)

__all__ = ["ADAPTER_VERSION", "CLASS_ORDER", "LABEL_SPACE", "METRIC", "PROVIDER_ID",
           "RELEASE_MODE", "make_providers", "provider"]


def make_providers() -> list:
    from .provider import make_providers as _make

    return _make()


def provider():
    from .provider import PROVIDER

    return PROVIDER

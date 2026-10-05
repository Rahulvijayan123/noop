"""Minimal stand-in for ``hypnospy.wearable.Wearable``.

Provenance
----------
Upstream:  https://github.com/HypnosPy/HypnosPy
Pinned:    3b6c825d1568158cbf0058de50495e5308117d17  (``hypnospy/wearable.py``)
Vendored:  2026-10-01 for the FRWHOOP server-side physiology migration.

Why a minimal stand-in and not the upstream file
------------------------------------------------
Upstream ``Wearable.__init__`` reads a HypnosPy HDF5 export (``pd.read_hdf``) or a
``RawProcessing`` object and imports ``h5py``, ``hypnospy.data.preprocessing`` and
``CGM``. The HR sleep-boundary algorithm reads only a small part of that state, so this
module implements exactly the members the algorithm touches and keeps the import graph
small (pandas only).

Deliberate deviations from upstream (each one is a defect class the adapter must not hit)
----------------------------------------------------------------------------------------
1. ``get_frequency_in_secs()`` NEVER infers the frequency. Upstream
   (``hypnospy/wearable.py:98-115``) falls back to ``pd.infer_freq`` and raises
   ``ValueError`` on an irregular index; more importantly, a wrong-but-set frequency
   silently rescales every window in the algorithm, because every window length is
   expressed in epochs (``rolling_win_in_minutes * get_epochs_in_min()``). Here a missing
   frequency raises instead, so the adapter is forced to call ``set_frequency_in_secs``.
2. The constructor takes the frame directly instead of a file path or a preprocessing
   object.
3. ``change_start_hour_for_experiment_day`` subtracts a ``pd.Timedelta`` instead of a
   ``pd.DateOffset``. Both are an absolute whole-hour shift, but on a timezone-aware index
   pandas 3 re-localises the result of a ``DateOffset`` subtraction and raises
   ``ValueError: Cannot infer dst time`` at the ambiguous hour of a DST fall-back.

Everything else (attribute names, ``experiment_day_col`` default, the day-offset
arithmetic in ``change_start_hour_for_experiment_day``) is copied from the pinned
upstream revision so the vendored algorithm behaves as written.
"""

from __future__ import annotations

from typing import Optional

import pandas as pd


class FrequencyNotSetError(ValueError):
    """Raised when the epoch length was not set explicitly."""


class Wearable:
    """Minimal carrier for the HR sleep-boundary algorithm.

    Parameters
    ----------
    data:
        Frame with a datetime column (``time_col``) and a heart-rate column
        (``hr_col``). The index is rebuilt as a ``RangeIndex``.
    time_col:
        Name of the datetime column. Must be timezone-aware local time for FRWHOOP use.
    hr_col:
        Name of the heart-rate column, in beats per minute. Missing samples are ``NaN``.
    pid:
        Participant / subject identifier, for diagnostics only.
    freq_in_secs:
        Epoch length in seconds. Must be set explicitly (see deviation 1).
    """

    def __init__(
        self,
        data: pd.DataFrame,
        time_col: str,
        hr_col: str,
        pid: str = "unknown",
        freq_in_secs: Optional[int] = None,
    ):
        if time_col not in data.columns:
            raise KeyError("time_col %r is not a column of the input frame" % (time_col,))
        if hr_col not in data.columns:
            raise KeyError("hr_col %r is not a column of the input frame" % (hr_col,))

        self.data = data.reset_index(drop=True).copy()
        self.time_col = time_col
        self.hr_col = hr_col
        self.pid = str(pid)
        self.freq_in_secs = None if freq_in_secs is None else int(freq_in_secs)

        self.experiment_day_col = "hyp_exp_day"
        self.hour_start_experiment = 0

        # Upstream __init__ ends with this call; the algorithm relies on the column
        # existing before it re-groups the frame.
        self.change_start_hour_for_experiment_day(0)

    # -- identity ---------------------------------------------------------------
    def get_pid(self):
        return self.pid

    # -- epoch grid -------------------------------------------------------------
    def set_frequency_in_secs(self, freq):
        self.freq_in_secs = int(freq)

    def get_frequency_in_secs(self):
        if not self.freq_in_secs:
            raise FrequencyNotSetError(
                "Epoch length was not set. Call set_frequency_in_secs(); frequency "
                "inference is deliberately disabled in this vendored copy."
            )
        return int(self.freq_in_secs)

    def get_epochs_in_min(self):
        return 60 / self.get_frequency_in_secs()

    def get_epochs_in_hour(self):
        return 60 * self.get_epochs_in_min()

    # -- analysis day -----------------------------------------------------------
    def change_start_hour_for_experiment_day(self, hour_start_experiment):
        """Copy of the pinned upstream implementation (``wearable.py:128-139``).

        The analysis day is ``floor((local_timestamp - hour_start_experiment) / 1 day)``
        in the wall-clock calendar of the timestamps given. FRWHOOP's IANA zone and
        wake-date semantics are applied by the adapter before the frame reaches this
        class.
        """
        self.hour_start_experiment = hour_start_experiment
        if self.data.empty:
            self.data[self.experiment_day_col] = pd.Series(dtype="int64")
            return
        day_zero = self.data.iloc[0][self.time_col].toordinal()
        # LOCAL EDIT (deviation 3): upstream uses pd.DateOffset(hours=...). On a timezone-aware
        # index pandas 3 re-localises the result of a DateOffset subtraction and raises
        # "Cannot infer dst time" at the ambiguous hour of a DST fall-back. pd.Timedelta is an
        # absolute shift, so for a whole-hour offset it is the same arithmetic without the
        # re-localisation.
        new_exp_day = (
            self.data[self.time_col] - pd.Timedelta(hours=hour_start_experiment)
        ).apply(lambda x: x.toordinal() - day_zero)
        self.data[self.experiment_day_col] = new_exp_day


class Experiment:
    """Stub for ``hypnospy.Experiment``.

    The HR boundary algorithm accepts either one ``Wearable`` or an ``Experiment``.
    Multi-wearable experiments are not vendored: FRWHOOP runs one user-device-day per
    inference call, so a batch object has no use here. Constructing this class fails
    loudly instead of silently processing the wrong scope.
    """

    def __init__(self, *args, **kwargs):
        raise NotImplementedError(
            "The vendored HypnosPy copy only supports single-Wearable detection. "
            "Pass a Wearable to the boundary detector."
        )

    def get_all_wearables(self):  # pragma: no cover - unreachable
        raise NotImplementedError

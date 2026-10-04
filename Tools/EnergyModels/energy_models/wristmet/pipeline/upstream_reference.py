"""Literal copies of the upstream feature code, used only to verify ``energy_models.wristmet.features``.

Source: https://github.com/HAbitsLab/WristBased-EE-Estimation (MIT License, Copyright (c) 2025
The HABits Lab), commit 3d3517cb95ef490d5e867ebf6a7207b8f7278788: ``in-lab.py`` lines 165-227
(``get_rmssd``, ``get_freq_intensity``) and ``helper_preprocess.py`` lines 158-175
(``extract_features``). The bodies are unchanged; only the imports are local. Requires pandas
and scikit-learn (build / test time only).
"""

from __future__ import annotations

import numpy as np
from sklearn import preprocessing
from sklearn.preprocessing import MinMaxScaler


def get_rmssd(df, norm="l2"):
    df_temp = df.dropna()
    acc_x = list(df_temp["accX"])
    acc_y = list(df_temp["accY"])
    acc_z = list(df_temp["accZ"])
    data = np.array([df_temp["accX"], df_temp["accY"], df_temp["accZ"]])

    if len(acc_x) != 0:
        if norm == "l2":
            processed = preprocessing.normalize(data, norm="l2")
            acc_x = processed[0]
            acc_y = processed[1]
            acc_z = processed[2]
        if norm == "l1":
            processed = preprocessing.normalize(data, norm="l1")
            acc_x = processed[0]
            acc_y = processed[1]
            acc_z = processed[2]
        if norm == "minmax":
            scaler = MinMaxScaler()
            scaler.fit(data)
            processed = scaler.transform(data)
            acc_x = processed[0]
            acc_y = processed[1]
            acc_z = processed[2]

        temp_sum = 0
        for i in range(1, len(acc_x)):
            temp_sum = temp_sum + (acc_x[i] - acc_x[i - 1]) ** 2 + (acc_y[i] - acc_y[i - 1]) ** 2 + (acc_z[i] - acc_z[i - 1]) ** 2
        rmssd = (temp_sum / len(acc_x)) ** (1 / 2)
        return rmssd
    else:
        return np.nan


def get_freq_intensity(df, fs, top, plot=False):
    df_temp = df.dropna()
    acc_x = list(df_temp["accX"])
    acc_y = list(df_temp["accY"])
    acc_z = list(df_temp["accZ"])
    y = []
    if len(acc_x) != 0:
        for i in range(1, len(acc_x)):
            y.append(np.sqrt(acc_x[i] ** 2 + acc_y[i] ** 2 + acc_z[i] ** 2))
            n = len(y)  # length of the signal
            k = np.arange(n)
            T = n / fs
            frq = k / T  # two sides frequency range
            frq = frq[: len(frq) // 2]  # one side frequency range
            Y = np.fft.fft(y) / n  # dft and normalization
            Y = Y[: n // 2]

        top = top + 1
        fr = list(abs(Y))
        result = frq[fr.index(sorted(fr, reverse=True)[:top][top - 1])]
        return result
    else:
        return np.nan


def extract_features(data):
    # Added new features: Median, mean, maximum, minimum, range, standard deviation, and root mean square power
    outcome = []
    for m in data:
        temp = []
        try:
            temp.append(np.median(m, axis=1))
            temp.append(np.mean(m, axis=1))
            temp.append(np.max(m, axis=1))
            temp.append(np.min(m, axis=1))
            temp.append(np.max(m, axis=1) - np.min(m, axis=1))
            temp.append(np.std(m, axis=1))
            temp.append(np.sqrt(np.mean(m**2, axis=1)))
            temp = np.concatenate(temp)
        except Exception:
            temp = np.array([0] * 42)
        outcome.append(temp)
    return np.array(outcome)


def get_freq_intensity_fast(df, fs, top):
    """Equivalent to :func:`get_freq_intensity` but with the loop-invariant FFT hoisted out of the loop.

    The upstream function recomputes the FFT after every appended sample and only the last
    iteration survives; this variant is checked against the literal one on a subset of windows
    and used for the full-dataset equivalence check because the literal version is O(N^2 log N).
    """
    df_temp = df.dropna()
    acc_x = list(df_temp["accX"])
    acc_y = list(df_temp["accY"])
    acc_z = list(df_temp["accZ"])
    y = []
    if len(acc_x) != 0:
        for i in range(1, len(acc_x)):
            y.append(np.sqrt(acc_x[i] ** 2 + acc_y[i] ** 2 + acc_z[i] ** 2))
        n = len(y)
        k = np.arange(n)
        T = n / fs
        frq = k / T
        frq = frq[: len(frq) // 2]
        Y = np.fft.fft(y) / n
        Y = Y[: n // 2]
        top = top + 1
        fr = list(abs(Y))
        return frq[fr.index(sorted(fr, reverse=True)[:top][top - 1])]
    return np.nan

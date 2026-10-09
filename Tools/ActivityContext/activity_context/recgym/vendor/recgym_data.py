# Vendored from HAR_IMU_CNN-Transformer (https://github.com/MKorp7/HAR_IMU_CNN-Transformer)
# Upstream path: src/data/recgym.py
# Upstream commit: e085ac0e116aa5997d5f593ac1d0dd0c801859b1
# Upstream file sha256: a8c47737994f6bda6437376c93e8cf4f4743525f1a4acf34a567d8fe76f52ed7
# Used ONLY by activity_context.recgym.reproduce (offline scaler reproduction; needs pandas, scikit-learn, torch);
# the serve process never imports it. Everything below the line of dashes is the upstream file, byte for byte.
#
# MIT License
#
# Copyright (c) 2025 MKorp7
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in all
# copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# ----------------------------------------------------------------------------------------------------------------
from typing import Dict, Tuple, Sequence

import numpy as np
import pandas as pd
from sklearn.preprocessing import StandardScaler
import torch
from torch.utils.data import Dataset, DataLoader

# Channel indices (based on feature_cols order)
IMU_IDX = [0, 1, 2, 3, 4, 5]          # A_x..G_z
HBC_IDX = [6]                         # C_1
ALL_IDX = [0, 1, 2, 3, 4, 5, 6]       # IMU + HBC


class IMUWindowDataset(Dataset):
    """
    Holds windowed time-series (N, T, C) with optional Gaussian noise augmentation.
    """

    def __init__(self, X: np.ndarray, y: np.ndarray,
                 augment: bool = False, noise_std: float = 0.01):
        """
        X: (N, T, C)
        y: (N,)
        """
        assert X.shape[0] == len(y)
        self.X = torch.from_numpy(X).float()
        self.y = torch.from_numpy(y).long()
        self.augment = augment
        self.noise_std = noise_std

    def __len__(self) -> int:
        return len(self.X)

    def __getitem__(self, idx: int):
        x = self.X[idx]  # (T, C)
        y = self.y[idx]

        if self.augment:
            noise = torch.randn_like(x) * self.noise_std
            x = x + noise

        # model expects (C, T)
        x = x.permute(1, 0)
        return x, y


def create_windows(
    df_pos: pd.DataFrame,
    fs: int = 20,
    window_sec: float = 4.0,
    step_sec: float = 2.0,
    majority_thresh: float = 0.6,
) -> Tuple[np.ndarray, np.ndarray, Dict[str, np.ndarray]]:
    """
    Create sliding windows for a single position.

    df_pos: DataFrame with columns:
        Subject, Session, A_x..C_1, label
    Returns:
        X: (N, T, 7)  with columns [A_x..G_z, C_1]
        y: (N,)
        meta: dict with 'Subject' and 'Session' arrays per window
    """
    feature_cols = ["A_x", "A_y", "A_z", "G_x", "G_y", "G_z", "C_1"]

    window_size = int(window_sec * fs)
    step_size = int(step_sec * fs)

    X_list, y_list = [], []
    subj_list, sess_list = [], []

    for (subj, sess), g in df_pos.groupby(["Subject", "Session"]):
        g = g.reset_index(drop=True)
        data = g[feature_cols].values
        labels = g["label"].values
        n = len(g)

        if n < window_size:
            continue

        for start in range(0, n - window_size + 1, step_size):
            end = start + window_size
            x_win = data[start:end]
            y_win = labels[start:end]

            binc = np.bincount(y_win)
            y_major = binc.argmax()
            frac_major = binc[y_major] / len(y_win)

            if frac_major < majority_thresh:
                continue

            X_list.append(x_win)
            y_list.append(y_major)
            subj_list.append(subj)
            sess_list.append(sess)

    X = np.stack(X_list) if X_list else np.empty((0, window_size, len(feature_cols)))
    y = np.array(y_list, dtype=int)
    meta = {
        "Subject": np.array(subj_list, dtype=int),
        "Session": np.array(sess_list, dtype=int),
    }
    return X, y, meta


def get_windows_for_position(
    df: pd.DataFrame,
    position: str,
    fs: int = 20,
    window_sec: float = 4.0,
    step_sec: float = 2.0,
    majority_thresh: float = 0.6,
):
    df_pos = df[df["Position"] == position].copy()
    df_pos = df_pos.sort_values(["Subject", "Session"]).reset_index(drop=True)
    print(
        f"Position {position}: {df_pos['Subject'].nunique()} subjects, "
        f"{df_pos['Session'].nunique()} sessions"
    )
    X, y, meta = create_windows(
        df_pos,
        fs=fs,
        window_sec=window_sec,
        step_sec=step_sec,
        majority_thresh=majority_thresh,
    )
    print(f"Windows for {position}: X shape = {X.shape}, y shape = {y.shape}")
    return X, y, meta


def make_loaders_for_channels(
    X: np.ndarray,
    y: np.ndarray,
    meta: Dict[str, np.ndarray],
    ch_idx: Sequence[int],
    train_subjs=(1, 2, 3, 4, 5, 6, 7),
    val_subjs=(8,),
    test_subjs=(9, 10),
    batch_size: int = 64,
    augment: bool = False,
    noise_std: float = 0.02,
):
    """
    Selects channels, splits by Subject, scales, and returns DataLoaders + scaler.
    """
    X_sel = X[:, :, ch_idx]  # (N, T, C_sel)

    subjects = meta["Subject"]
    train_mask = np.isin(subjects, train_subjs)
    val_mask = np.isin(subjects, val_subjs)
    test_mask = np.isin(subjects, test_subjs)

    X_train, y_train = X_sel[train_mask], y[train_mask]
    X_val, y_val = X_sel[val_mask], y[val_mask]
    X_test, y_test = X_sel[test_mask], y[test_mask]

    T = X_train.shape[1]
    C = X_train.shape[2]

    scaler = StandardScaler()
    X_train_flat = X_train.reshape(len(X_train), -1)
    X_val_flat = X_val.reshape(len(X_val), -1)
    X_test_flat = X_test.reshape(len(X_test), -1)

    X_train_sc = scaler.fit_transform(X_train_flat).reshape(-1, T, C)
    X_val_sc = scaler.transform(X_val_flat).reshape(-1, T, C)
    X_test_sc = scaler.transform(X_test_flat).reshape(-1, T, C)

    train_ds = IMUWindowDataset(X_train_sc, y_train, augment=augment, noise_std=noise_std)
    val_ds = IMUWindowDataset(X_val_sc, y_val, augment=False)
    test_ds = IMUWindowDataset(X_test_sc, y_test, augment=False)

    train_loader = DataLoader(train_ds, batch_size=batch_size, shuffle=True)
    val_loader = DataLoader(val_ds, batch_size=batch_size)
    test_loader = DataLoader(test_ds, batch_size=batch_size)

    return train_loader, val_loader, test_loader, scaler

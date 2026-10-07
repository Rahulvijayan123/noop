# Vendored from Inertia-1 (https://github.com/yang-ai-lab/Inertia-1)
# Upstream path: inertia1/methods/ar_transformer_module.py
# Upstream commit: afcd725314c95f4afefce118821349df7d61e7e8
#
# MIT License
#
# Copyright (c) 2026 The Inertia-1 Authors
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
#
# Nara modifications (inference only):
#   * nn.Module instead of pl.LightningModule; constructor takes explicit arch numbers instead of a cfg dict;
#     training (forward/_step/optimizers) and the causal-mask helper removed.
#   * nn.TransformerEncoder(enable_nested_tensor=False): a no-op with norm_first=True (upstream's
#     use_nested_tensor is already False then) that only silences torch's construction warning.
#   * The pretraining head ``head`` is kept so upstream checkpoints load with strict=True; encode() ignores it.
#   * encode() is unchanged: all N patches, NO causal mask, mean over patch tokens (as upstream).
"""Patch-level autoregressive transformer ("ART") — encoder side."""

from __future__ import annotations

import math

import torch
import torch.nn as nn


class PositionalEncoding(nn.Module):
    """Sinusoidal positional encoding for transformer."""

    def __init__(self, d_model: int, max_len: int = 5000):
        super().__init__()
        position = torch.arange(max_len).unsqueeze(1)
        div_term = torch.exp(torch.arange(0, d_model, 2) * (-math.log(10000.0) / d_model))
        pe = torch.zeros(1, max_len, d_model)
        pe[0, :, 0::2] = torch.sin(position * div_term)
        pe[0, :, 1::2] = torch.cos(position * div_term)
        self.register_buffer('pe', pe)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        return x + self.pe[:, :x.size(1), :]


class ARTransformerEncoder(nn.Module):
    """Encoder side of upstream ``ARTransformerModule``.

    Input: x [B, C, T]. Patches the input into non-overlapping patches of [C * patch_len] (channel-major
    within a patch; a tail remainder T % patch_len is dropped), projects, adds the sinusoidal table and
    runs the pre-norm TransformerEncoder; ``encode`` mean-pools all patch tokens -> [B, d_model].
    """

    def __init__(self, *, channels: int = 3, patch_len: int = 10, d_model: int = 512, n_heads: int = 4,
                 n_layers: int = 4, d_ff: int = 1024, dropout: float = 0.0):
        super().__init__()
        self.patch_len = int(patch_len)
        self.channels = int(channels)
        patch_dim = self.channels * self.patch_len

        self.patch_proj = nn.Linear(patch_dim, d_model)
        self.pos_encoder = PositionalEncoding(d_model)

        encoder_layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=n_heads,
            dim_feedforward=d_ff,
            dropout=dropout,
            batch_first=True,
            norm_first=True,
        )
        self.transformer = nn.TransformerEncoder(encoder_layer, num_layers=n_layers,
                                                 enable_nested_tensor=False)

        self.head = nn.Linear(d_model, patch_dim)
        self.d_model = d_model

    def _to_patches(self, x: torch.Tensor) -> torch.Tensor:
        """x: [B, C, T] -> patches: [B, N, C * patch_len]"""
        B, C, T = x.shape
        n_patches = T // self.patch_len
        T_trim = n_patches * self.patch_len
        x = x[:, :, :T_trim]
        x = x.reshape(B, C, n_patches, self.patch_len)
        x = x.permute(0, 2, 1, 3).reshape(B, n_patches, C * self.patch_len)
        return x

    def encode(self, x: torch.Tensor) -> torch.Tensor:
        """Return pooled transformer hidden representation [B, d_model]."""
        patches = self._to_patches(x)  # [B, N, C*patch_len]
        p_in = self.patch_proj(patches)  # [B, N, d_model]
        h = self.pos_encoder(p_in)
        h = self.transformer(h)  # [B, N, d_model]
        return h.mean(dim=1)  # [B, d_model]

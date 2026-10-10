# Vendored from HAR_IMU_CNN-Transformer (https://github.com/MKorp7/HAR_IMU_CNN-Transformer)
# Upstream path: src/models/imu_transformer.py
# Upstream commit: e085ac0e116aa5997d5f593ac1d0dd0c801859b1
# Upstream file sha256: edd1801e5b7ace210859e75e039d1b106ff59f7bbe5740205f7024829e00278c
# Everything below the line of dashes is the upstream file, byte for byte (module and attribute names are what the
# upstream state dicts load into strictly).
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
import torch
import torch.nn as nn


class PositionalEncoding(nn.Module):
    def __init__(self, d_model, max_len=500):
        super().__init__()
        pe = torch.zeros(max_len, d_model)
        position = torch.arange(0, max_len, dtype=torch.float).unsqueeze(1)
        div_term = torch.exp(
            torch.arange(0, d_model, 2).float()
            * (-torch.log(torch.tensor(10000.0)) / d_model)
        )
        pe[:, 0::2] = torch.sin(position * div_term)
        pe[:, 1::2] = torch.cos(position * div_term)
        pe = pe.unsqueeze(0)  # (1, max_len, d_model)
        self.register_buffer("pe", pe)

    def forward(self, x):  # x: (B, T, d_model)
        T = x.size(1)
        return x + self.pe[:, :T]


class IMUCNNTransformer(nn.Module):
    def __init__(
        self,
        in_channels=7,     # number of input channels
        num_classes=12,
        d_model=64,
        n_heads=4,
        num_layers=2,
        dropout=0.2,
    ):
        super().__init__()

        self.conv = nn.Sequential(
            nn.Conv1d(in_channels, 64, kernel_size=5, padding=2),
            nn.BatchNorm1d(64),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Conv1d(64, 128, kernel_size=5, padding=2),
            nn.BatchNorm1d(128),
            nn.ReLU(),
            nn.Dropout(dropout),
        )

        self.proj = nn.Linear(128, d_model)
        self.pos_enc = PositionalEncoding(d_model, max_len=500)

        encoder_layer = nn.TransformerEncoderLayer(
            d_model=d_model,
            nhead=n_heads,
            dim_feedforward=256,
            dropout=dropout,
            batch_first=True,  # (B, T, d_model)
        )
        self.transformer = nn.TransformerEncoder(
            encoder_layer,
            num_layers=num_layers,
        )

        self.norm = nn.LayerNorm(d_model)

        self.head = nn.Sequential(
            nn.Linear(d_model, d_model),
            nn.ReLU(),
            nn.Dropout(dropout),
            nn.Linear(d_model, num_classes),
        )

    def forward(self, x):
        # x: (B, C, T)
        x = self.conv(x)           # (B, 128, T)
        x = x.transpose(1, 2)      # (B, T, 128)

        x = self.proj(x)           # (B, T, d_model)
        x = self.pos_enc(x)
        x = self.transformer(x)    # (B, T, d_model)
        x = self.norm(x)

        x_mean = x.mean(dim=1)
        x_max, _ = x.max(dim=1)
        x = x_mean + x_max         # (B, d_model)

        logits = self.head(x)      # (B, num_classes)
        return logits

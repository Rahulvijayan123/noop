# Vendored from ssl-wearables (https://github.com/OxWearables/ssl-wearables), tag v1.0.0
# Upstream path: sslearning/models/accNet.py (Downsample, ResBlock, Resnet.make_layer, the epoch_len=30
#                resnet_version=1 layer table) — the network ActiNet (https://github.com/OxWearables/actinet)
#                fine-tunes. Feature extractor only: no classifier heads, no training code.
#
# Copyright (c) Oxford Wearables Group (ssl-wearables authors). Licensed under CC BY-NC 4.0 by upstream;
# used here for an internal, non-commercial project (NOTICE.md).
"""harnet30 feature extractor: ``float32 [B, 3, 900]`` (x, y, z in g, 30 Hz, gravity kept) -> ``[B, 1024, 1]``.

Module names match upstream's ``Resnet.feature_extractor`` so its state_dict (keys ``layer1.0.weight`` …)
loads with ``strict=True``.
"""

from __future__ import annotations

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

# (out_channels, conv_kernel, n_resblocks, resblock_kernel, downfactor, downorder); 3*3*5*5*4 = 900
HARNET30_LAYERS = (
    (64, 5, 2, 5, 3, 1),
    (128, 5, 2, 5, 3, 1),
    (256, 5, 2, 5, 5, 1),
    (512, 5, 2, 5, 5, 1),
    (1024, 5, 0, 5, 4, 0),
)
HARNET30_INPUT_SAMPLES = 900
HARNET30_DIM = 1024


class Downsample(nn.Module):
    def __init__(self, channels=None, factor=2, order=1):
        super().__init__()
        assert factor > 1, "Downsampling factor must be > 1"
        self.stride = factor
        self.channels = channels
        self.order = order
        total_padding = order * (factor - 1)
        assert total_padding % 2 == 0, "order*(factor-1) must be divisible by 2"
        self.padding = int(order * (factor - 1) / 2)
        box_kernel = np.ones(factor)
        kernel = np.ones(factor)
        for _ in range(order):
            kernel = np.convolve(kernel, box_kernel)
        kernel /= np.sum(kernel)
        kernel = torch.Tensor(kernel)
        self.register_buffer("kernel", kernel[None, None, :].repeat((channels, 1, 1)))

    def forward(self, x):
        return F.conv1d(x, self.kernel, stride=self.stride, padding=self.padding, groups=x.shape[1])


class ResBlock(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size=5, stride=1, padding=2):
        super().__init__()
        self.bn1 = nn.BatchNorm1d(in_channels)
        self.bn2 = nn.BatchNorm1d(out_channels)
        self.conv1 = nn.Conv1d(in_channels, out_channels, kernel_size, stride, padding, bias=False,
                               padding_mode="circular")
        self.conv2 = nn.Conv1d(out_channels, out_channels, kernel_size, stride, padding, bias=False,
                               padding_mode="circular")
        self.relu = nn.ReLU(inplace=True)

    def forward(self, x):
        identity = x
        x = self.relu(self.bn1(x))
        x = self.conv1(x)
        x = self.relu(self.bn2(x))
        x = self.conv2(x)
        return x + identity


def _make_layer(in_channels, out_channels, conv_kernel_size, n_resblocks, resblock_kernel_size, downfactor,
                downorder=1):
    conv_padding = int((conv_kernel_size - 1) / 2)
    resblock_padding = int((resblock_kernel_size - 1) / 2)
    modules = [nn.Conv1d(in_channels, out_channels, conv_kernel_size, 1, conv_padding, bias=False,
                         padding_mode="circular")]
    for _ in range(n_resblocks):
        modules.append(ResBlock(out_channels, out_channels, resblock_kernel_size, 1, resblock_padding))
    modules.append(nn.BatchNorm1d(out_channels))
    modules.append(nn.ReLU(True))
    modules.append(Downsample(out_channels, downfactor, downorder))
    return nn.Sequential(*modules)


def harnet30_feature_extractor() -> nn.Sequential:
    fe = nn.Sequential()
    in_channels = 3
    for i, p in enumerate(HARNET30_LAYERS):
        fe.add_module(f"layer{i + 1}", _make_layer(in_channels, *p))
        in_channels = p[0]
    return fe

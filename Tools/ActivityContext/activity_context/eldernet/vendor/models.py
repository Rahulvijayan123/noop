# Vendored from yonbrand/gait-quality (https://github.com/yonbrand/gait-quality)
# Upstream path: models.py
# Upstream commit: 437a38bcc69f42717fe73c1f7dbea7e1f7a50d23
# The ResNet-18 architecture is from OxWearables/ssl-wearables (https://github.com/OxWearables/ssl-wearables).
#
# Copyright © 2022, University of Oxford
#
# Licensed under the University of Oxford SSL-wearables Academic Use Licence (full text: upstream LICENSE.md,
# reproduced in Tools/ActivityContext/NOTICE.md). Use is limited to internal academic, non-commercial
# research; the licence conditions are imposed on any receiver of this code or of modified versions of it.
#
# Nara modifications (inference only; numerics unchanged):
#   * Only the classes the released ElderNet checkpoints need: Downsample, ResBlock, Resnet (feature extractor;
#     epoch_len 10 only), LinearLayers, Classifier, Regressor, ElderNet (head 'fc', is_classification /
#     is_regression only). Unet, EvaClassifier, ContrastiveLoss, the MTL / SimCLR heads removed.
#   * weight_init removed: it imported upstream utils.py (plotting/statistics stack, TkAgg) and re-seeded the
#     global RNGs. Every parameter is overwritten by the strict checkpoint load, so initialisation is moot.
#   * Resnet takes no mutable default feature_extractor (upstream shares one nn.Sequential between instances).
#   * Regressor stores max_mu as given (float); ElderNet.forward keeps upstream's flatten + head order.
"""ElderNet: ResNet-18 (ssl-wearables, 10 s @ 30 Hz) -> 3 FC layers -> classifier / bounded regressor."""

from __future__ import annotations

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as F

# epoch_len == 10 layer table (upstream models.py:315-322):
# (out_channels, conv_kernel, n_resblocks, resblock_kernel, downfactor, downorder); 2*2*5*5*3 = 300 samples.
RESNET_CFG_10S = (
    (64, 5, 2, 5, 2, 2),
    (128, 5, 2, 5, 2, 2),
    (256, 5, 2, 5, 5, 1),
    (512, 5, 2, 5, 5, 1),
    (1024, 5, 0, 5, 3, 1),
)
BACKBONE_OUTPUT_SIZE = 1024


class Classifier(nn.Module):
    def __init__(self, input_size=1024, output_size=2):
        super().__init__()
        self.linear1 = torch.nn.Linear(input_size, output_size)

    def forward(self, x):
        return self.linear1(x)


class Regressor(nn.Module):
    def __init__(self, input_size=1024, output_size=1, max_mu=2.0, num_layers=1, batch_norm=False):
        super().__init__()
        self.max_mu = max_mu
        self.bn = batch_norm
        self.linear_layers = nn.ModuleList()
        self.bn_layers = nn.ModuleList()
        hidden_size = input_size
        for _ in range(num_layers):
            next_hidden_size = max(hidden_size // 2, 32)
            self.linear_layers.append(nn.Linear(hidden_size, next_hidden_size))
            if self.bn:
                self.bn_layers.append(nn.BatchNorm1d(next_hidden_size))
            hidden_size = next_hidden_size
        self.mu = nn.Linear(hidden_size, output_size)

    def forward(self, x):
        if self.bn:
            for linear, bn in zip(self.linear_layers, self.bn_layers):
                x = F.relu(bn(linear(x)))
        else:
            for linear in self.linear_layers:
                x = F.relu(linear(x))
        mu = self.mu(x)
        return self.max_mu * torch.sigmoid(mu)


class LinearLayers(nn.Module):
    def __init__(self, input_size=1024, output_size=128, non_linearity=False):
        super().__init__()
        assert input_size / 4 > 0, "input size too small"
        assert output_size <= (input_size / 4), "output size needs to be smaller the input size/4"
        self.linear1 = torch.nn.Linear(input_size, int(input_size / 2))
        self.linear2 = torch.nn.Linear(int(input_size / 2), int(input_size / 4))
        self.linear3 = torch.nn.Linear(int(input_size / 4), output_size)
        self.relu = nn.ReLU()
        self.non_linearity = non_linearity

    def forward(self, x):
        if self.non_linearity:
            fc1 = self.linear1(x)
            fc2 = self.linear2(self.relu(fc1))
            return self.linear3(self.relu(fc2))
        return self.linear3(self.linear2(self.linear1(x)))


class Downsample(nn.Module):
    """Anti-aliased downsampling (order 0 = box, 1 = triangle, ...); kernel is a registered buffer."""

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
    """bn-relu-conv-bn-relu-conv with identity skip (circular padding)."""

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


def make_layer(in_channels, out_channels, conv_kernel_size, n_resblocks, resblock_kernel_size, downfactor,
               downorder=1):
    """x -> conv -> [ResBlock]^m -> bn -> relu -> down (upstream Resnet.make_layer)."""
    assert conv_kernel_size % 2, "Only odd number for conv_kernel_size supported"
    assert resblock_kernel_size % 2, "Only odd number for resblock_kernel_size supported"
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


def resnet_feature_extractor(n_channels: int = 3) -> nn.Sequential:
    """The ssl-wearables ResNet-18 feature extractor for 10 s epochs (modules ``layer1`` .. ``layer5``)."""
    fe = nn.Sequential()
    in_channels = n_channels
    for i, params in enumerate(RESNET_CFG_10S):
        fe.add_module(f"layer{i + 1}", make_layer(in_channels, *params))
        in_channels = params[0]
    return fe


class ElderNet(nn.Module):
    """``feature_extractor`` -> ``fc`` (LinearLayers, ReLU) -> ``classifier`` or ``regressor``."""

    def __init__(self, feature_extractor, linear_model_input_size=BACKBONE_OUTPUT_SIZE,
                 linear_model_output_size=128, output_size=1, is_classification=False, is_regression=False,
                 max_mu=None, num_layers_regressor=None, batch_norm=False):
        super().__init__()
        if is_classification == is_regression:
            raise ValueError("exactly one of is_classification / is_regression")
        self.feature_extractor = feature_extractor
        self.output_size = output_size
        self.is_classification = is_classification
        self.is_regression = is_regression
        self.head = "fc"
        self.fc = LinearLayers(linear_model_input_size, linear_model_output_size, True)
        if is_classification:
            self.classifier = Classifier(linear_model_output_size, output_size)
        else:
            self.max_mu = max_mu
            self.num_layers_regressor = num_layers_regressor
            self.batch_norm = batch_norm
            self.regressor = Regressor(input_size=linear_model_output_size, output_size=output_size,
                                       max_mu=max_mu, num_layers=num_layers_regressor, batch_norm=batch_norm)

    def forward(self, x):
        features = self.feature_extractor(x)
        representation = self.fc(features.view(x.shape[0], -1))
        if self.is_classification:
            return self.classifier(representation)
        return self.regressor(representation)


__all__ = ["RESNET_CFG_10S", "BACKBONE_OUTPUT_SIZE", "Classifier", "Regressor", "LinearLayers", "Downsample",
           "ResBlock", "make_layer", "resnet_feature_extractor", "ElderNet"]

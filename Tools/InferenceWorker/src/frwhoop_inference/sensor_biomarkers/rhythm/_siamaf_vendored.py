"""Vendored minimal SiamAF architecture (ResNet-34 + SimSiam head).

MIT License (c) 2024 Zhicheng Guo. Source:
    https://github.com/chengstark/SiamAF
    file: proposed/resnet1d.py
    pinned commit: c05be9e37d2013d0817aafc5b2e72b2f7649e95e (repository HEAD)
    upstream file sha256: c50cead1e84c84b572c2bb69c5db4a89c83e14211d413e6fed4a29d6807f9a99

Only the four classes needed to build ``Res34SimSiam(512, 128,
single_source_mode=True)`` are vendored (ResBlock, Resnet34, DirectFwd,
Res34SimSiam), byte-for-byte from the pinned file except for the module
docstring and imports. The full MIT license text is in the repository
NOTICE/ATTRIBUTION ledger; see the parent-owned ATTRIBUTION.md at the repo
root for the consolidated attribution record.

NOTES (verified 2026-10-06 against the pinned checkpoint):

* ``Res34SimSiam.forward(self, ECG, PPG)`` takes TWO positional arguments in
  every mode, including ``single_source_mode=True`` where ``PPG`` is unused.
  The model card example calls ``model(signal)`` with one argument; that call
  would fail on the real network. The adapter wrapper passes the second
  argument explicitly and never rewrites the learned network.
* The learned classification logits are the THIRD return value
  (``class_pred1``, shape ``(batch, 2)``), produced by
  ``classification_head`` over the 384-d pooled features.
* The saved checkpoint ``proposed/saved_models/final_model.pt`` is a
  DataParallel ``state_dict``: every key carries a verified leading
  ``module.`` prefix that the adapter strips before a strict ``load_state_dict``.
"""

import torch
import torch.nn as nn


class ResBlock(nn.Module):

    def __init__(self, filters, stage, i_block, kernel_size=3, stride=1):
        super(ResBlock,self).__init__()
        self.out_channels = filters
        self.kernel_size = kernel_size
        self.stride = stride
        self.in_channels = filters

        if i_block == 0 and stage != 0:
            self.in_channels = filters // 2

        self.conv1 = nn.Conv1d(
            in_channels=self.in_channels,
            out_channels=self.out_channels,
            kernel_size=self.kernel_size,
            stride=self.stride,
            padding='same')
        self.bn1 = nn.BatchNorm1d(self.out_channels)
        self.relu1 = nn.ReLU()

        self.conv2 = nn.Conv1d(
            in_channels=self.out_channels,
            out_channels=self.out_channels,
            kernel_size=self.kernel_size,
            stride=self.stride,
            padding='same')

        self.bn2 = nn.BatchNorm1d(self.out_channels)
        self.bn3 = nn.BatchNorm1d(self.out_channels)
        self.relu2 = nn.ReLU()

    def forward(self, x):

        out = x
        out = self.relu1(self.bn1(self.conv1(out)))
        out = self.bn2(self.conv2(out))
        if x.shape[1] != out.shape[1]:
            out = torch.add(out, torch.repeat_interleave(x, 2, dim=1))
        else:
            out = torch.add(out, x)

        out = self.relu2(self.bn3(out))

        return out


class Resnet34(nn.Module):
    def __init__(self, num_classes=2):
        super(Resnet34,self).__init__()
        self.num_classes = num_classes
        self.conv0 = nn.Conv1d(1, 48, 80, 4)
        self.bn0 = nn.BatchNorm1d(48)
        self.relu = nn.ReLU()
        self.pool0 = nn.MaxPool1d(4)
        self.stage0 = nn.Sequential(ResBlock(48, 0, 0),
                                   ResBlock(48, 0, 1))
        self.pool1 = nn.MaxPool1d(4)
        self.stage1 = nn.Sequential(ResBlock(96, 1, 0),
                                   ResBlock(96, 1, 1))
        self.pool2 = nn.MaxPool1d(4)
        self.stage2 = nn.Sequential(ResBlock(192, 2, 0),
                                    ResBlock(192, 2, 1))
        self.pool3 = nn.MaxPool1d(4)
        self.stage3 = nn.Sequential(ResBlock(384, 3, 0),
                                    ResBlock(384, 3, 1))

        self.avgpool = nn.AvgPool1d(1)
        self.fc = nn.Linear(384, self.num_classes)

    def forward(self, x):
        
        out = self.conv0(x)
        out = self.bn0(out)
        out = self.relu(out)
        out = self.pool0(out)


        out = self.stage0(out)
        out = self.pool1(out)

        out = self.stage1(out)
        out = self.pool2(out)


        out = self.stage2(out)
        out = self.pool3(out)


        out = self.stage3(out)


        out = self.avgpool(out)
        features = out.mean(dim=2)
        out = self.fc(features)

        return out, features


class DirectFwd(nn.Module):
    def __init__(self):
        super(DirectFwd, self).__init__()

    def forward(self, x):
        return x


class Res34SimSiam(nn.Module):
    """
    Build a SimSiam model.
    """
    def __init__(self, dim=2048, pred_dim=512, predictor=True, single_source_mode=False):
        """
        dim: feature dimension (default: 2048)
        pred_dim: hidden dimension of the predictor (default: 512)
        """
        super(Res34SimSiam, self).__init__()

        # create the encoder
        # num_classes is the output fc dimension, zero-initialize last BNs
        self.encoder = Resnet34(num_classes=dim)
        self.single_source_mode = single_source_mode
        # build a 3-layer projector
        prev_dim = self.encoder.fc.weight.shape[1]
        self.encoder.fc = nn.Sequential(nn.Linear(prev_dim, prev_dim, bias=False),
                                        nn.BatchNorm1d(prev_dim),
                                        nn.ReLU(inplace=True), # first layer
                                        nn.Linear(prev_dim, prev_dim, bias=False),
                                        nn.BatchNorm1d(prev_dim),
                                        nn.ReLU(inplace=True), # second layer
                                        self.encoder.fc,
                                        nn.BatchNorm1d(dim, affine=False)) # output layer
        self.encoder.fc[6].bias.requires_grad = False # hack: not use bias as it is followed by BN

        if predictor:
        # build a 2-layer predictor
            self.predictor = nn.Sequential(nn.Linear(dim, pred_dim, bias=False),
                                            nn.BatchNorm1d(pred_dim),
                                            nn.ReLU(inplace=True), # hidden layer
                                            nn.Linear(pred_dim, dim)) # output layer
        else:
            self.predictor = DirectFwd()

        self.classification_head = nn.Linear(384, 2)

    def forward(self, ECG, PPG):
        """
        Input:
            x1: first views of images
            x2: second views of images
        Output:
            p1, p2, z1, z2: predictors and targets of the network
            See Sec. 3 of https://arxiv.org/abs/2011.10566 for detailed notations
        """

        if not self.single_source_mode:
            # compute features for one view
            z1, features1 = self.encoder(ECG) # NxC
            z2, features2 = self.encoder(PPG) # NxC

            p1 = self.predictor(z1) # NxC
            p2 = self.predictor(z2) # NxC
            
            class_pred1 = self.classification_head(features1)
            class_pred2 = self.classification_head(features2)

            return p1, p2, z1.detach(), z2.detach(), class_pred1, class_pred2
        else:
            z1, features1 = self.encoder(ECG) # NxC

            p1 = self.predictor(z1) # NxC
            
            class_pred1 = self.classification_head(features1)

            return p1, z1.detach(), class_pred1


__all__ = ["ResBlock", "Resnet34", "DirectFwd", "Res34SimSiam"]

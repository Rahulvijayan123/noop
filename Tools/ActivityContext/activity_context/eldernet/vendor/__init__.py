# Narrowly vendored ElderNet model definitions from yonbrand/gait-quality
# (https://github.com/yonbrand/gait-quality), upstream commit 437a38bcc69f42717fe73c1f7dbea7e1f7a50d23.
#
# Copyright © 2022, University of Oxford
#
# Licensed under the University of Oxford SSL-wearables Academic Use Licence (upstream LICENSE.md, reproduced
# in Tools/ActivityContext/NOTICE.md): limited to internal academic, non-commercial research; the conditions of
# that licence apply to any receiver of this code; this notice must appear wherever the code is reproduced.
"""Vendored ElderNet architecture (inference only).

models.py  <- models.py (Downsample, ResBlock, Resnet [feature extractor only], LinearLayers, Classifier,
              Regressor, ElderNet [fc head, classification / regression only])

Why vendored rather than imported: upstream ``models.weight_init`` imports ``utils`` (pingouin, seaborn,
``matplotlib.use('TkAgg')``) and re-seeds Python/NumPy/PyTorch globally on every model construction, and
``Resnet``'s mutable default ``feature_extractor=nn.Sequential()`` is shared between instances (upstream
works around it with ``copy.deepcopy`` in ``gait_quality/weights.py:81``). Attribute names are identical to
upstream so the released checkpoints load with ``strict`` key checking (activity_context/eldernet/model.py).
"""

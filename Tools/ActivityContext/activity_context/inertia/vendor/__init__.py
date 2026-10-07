# Narrowly vendored encoder-side code from Inertia-1 (https://github.com/yang-ai-lab/Inertia-1)
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
"""Vendored Inertia-1 encoders (inference only; no pytorch-lightning, no training code).

ar_transformer.py  <- inertia1/methods/ar_transformer_module.py (PositionalEncoding, ARTransformerModule)
patchtst.py        <- inertia1/methods/patchtst_module.py (PatchTSTModule.encode),
                      inertia1/augmentations/patchtst.py (create_patch),
                      inertia1/models/backbones/patchtst/patchTST_accel.py (PatchTST_Accel, AccelPretrainHead,
                      AccelPatchTSTEncoder, TSTEncoder, TSTEncoderLayer),
                      inertia1/models/backbones/patchtst/layers/{attention,basics,pos_encoding}.py

Attribute names are identical to upstream so a Lightning ``state_dict`` loads with ``strict=True``.
``tests/inertia/test_vendor_parity.py`` proves ``encode()`` is bit-identical to upstream.
"""

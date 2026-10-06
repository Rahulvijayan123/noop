# Vendored from Inertia-1 (https://github.com/yang-ai-lab/Inertia-1)
# Upstream paths: inertia1/methods/patchtst_module.py (PatchTSTModule.encode)
#                 inertia1/augmentations/patchtst.py (create_patch)
#                 inertia1/models/backbones/patchtst/patchTST_accel.py
#                 inertia1/models/backbones/patchtst/layers/attention.py
#                 inertia1/models/backbones/patchtst/layers/basics.py (get_activation_fn)
#                 inertia1/models/backbones/patchtst/layers/pos_encoding.py (positional_encoding, 'zeros')
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
#   * nn.Module instead of pl.LightningModule; training, masking, prediction/classification heads, the
#     C != 3 channel adapter, BatchNorm, store_attn and non-'zeros' positional encodings removed (the
#     encoder config validator refuses those settings).
#   * Attention masks / key padding masks dropped (encode() never passes them).
#   * The pretraining head ``model.head.linear`` is kept so upstream checkpoints load with strict=True;
#     encode() ignores it. Module/attribute names are unchanged.
"""PatchTST_Accel masked-reconstruction model — encoder side (``PatchTSTModule.encode``)."""

from __future__ import annotations

from typing import Optional

import torch
import torch.nn.functional as F
from torch import Tensor, nn


def create_patch(xb, patch_len, stride):
    """
    xb: [bs x seq_len x n_vars]
    """
    seq_len = xb.shape[1]
    num_patch = (max(seq_len, patch_len)-patch_len) // stride + 1
    tgt_len = patch_len + stride*(num_patch-1)
    s_begin = seq_len - tgt_len

    xb = xb[:, s_begin:, :]                                                    # xb: [bs x tgt_len x nvars]
    xb = xb.unfold(dimension=1, size=patch_len, step=stride)                 # xb: [bs x num_patch x n_vars x patch_len]
    return xb, num_patch


def get_activation_fn(activation):
    if callable(activation): return activation()
    elif activation.lower() == "relu": return nn.ReLU()
    elif activation.lower() == "gelu": return nn.GELU()
    raise ValueError(f'{activation} is not available. You can use "relu", "gelu", or a callable')


class ScaledDotProductAttention(nn.Module):
    """Scaled dot-product attention with optional residual attention from the previous layer."""

    def __init__(self, d_model, n_heads, attn_dropout=0., res_attention=False, lsa=False):
        super().__init__()
        self.attn_dropout = nn.Dropout(attn_dropout)
        self.res_attention = res_attention
        head_dim = d_model // n_heads
        self.scale = nn.Parameter(torch.tensor(head_dim ** -0.5), requires_grad=lsa)
        self.lsa = lsa

    def forward(self, q: Tensor, k: Tensor, v: Tensor, prev: Optional[Tensor] = None):
        attn_scores = torch.matmul(q, k) * self.scale      # attn_scores : [bs x n_heads x max_q_len x q_len]
        if prev is not None: attn_scores = attn_scores + prev
        attn_weights = F.softmax(attn_scores, dim=-1)                 # attn_weights   : [bs x n_heads x max_q_len x q_len]
        attn_weights = self.attn_dropout(attn_weights)
        output = torch.matmul(attn_weights, v)                        # output: [bs x n_heads x max_q_len x d_v]
        if self.res_attention: return output, attn_weights, attn_scores
        else: return output, attn_weights


class MultiheadAttention(nn.Module):
    def __init__(self, d_model, n_heads, d_k=None, d_v=None, res_attention=False, attn_dropout=0., proj_dropout=0., qkv_bias=True, lsa=False):
        super().__init__()
        d_k = d_model // n_heads if d_k is None else d_k
        d_v = d_model // n_heads if d_v is None else d_v

        self.n_heads, self.d_k, self.d_v = n_heads, d_k, d_v

        self.W_Q = nn.Linear(d_model, d_k * n_heads, bias=qkv_bias)
        self.W_K = nn.Linear(d_model, d_k * n_heads, bias=qkv_bias)
        self.W_V = nn.Linear(d_model, d_v * n_heads, bias=qkv_bias)

        self.res_attention = res_attention
        self.sdp_attn = ScaledDotProductAttention(d_model, n_heads, attn_dropout=attn_dropout, res_attention=self.res_attention, lsa=lsa)

        self.to_out = nn.Sequential(nn.Linear(n_heads * d_v, d_model), nn.Dropout(proj_dropout))

    def forward(self, Q: Tensor, K: Optional[Tensor] = None, V: Optional[Tensor] = None, prev: Optional[Tensor] = None):
        bs = Q.size(0)
        if K is None: K = Q
        if V is None: V = Q

        q_s = self.W_Q(Q).view(bs, -1, self.n_heads, self.d_k).transpose(1,2)       # q_s    : [bs x n_heads x max_q_len x d_k]
        k_s = self.W_K(K).view(bs, -1, self.n_heads, self.d_k).permute(0,2,3,1)     # k_s    : [bs x n_heads x d_k x q_len]
        v_s = self.W_V(V).view(bs, -1, self.n_heads, self.d_v).transpose(1,2)       # v_s    : [bs x n_heads x q_len x d_v]

        if self.res_attention:
            output, attn_weights, attn_scores = self.sdp_attn(q_s, k_s, v_s, prev=prev)
        else:
            output, attn_weights = self.sdp_attn(q_s, k_s, v_s)

        output = output.transpose(1, 2).contiguous().view(bs, -1, self.n_heads * self.d_v) # output: [bs x q_len x n_heads * d_v]
        output = self.to_out(output)

        if self.res_attention: return output, attn_weights, attn_scores
        else: return output, attn_weights


class TSTEncoderLayer(nn.Module):
    def __init__(self, d_model, n_heads, d_ff=256, attn_dropout=0, dropout=0., bias=True,
                 activation="gelu", res_attention=False, pre_norm=False):
        super().__init__()
        assert not d_model%n_heads, f"d_model ({d_model}) must be divisible by n_heads ({n_heads})"
        d_k = d_model // n_heads
        d_v = d_model // n_heads

        self.res_attention = res_attention
        self.self_attn = MultiheadAttention(d_model, n_heads, d_k, d_v, attn_dropout=attn_dropout, proj_dropout=dropout, res_attention=res_attention)

        self.dropout_attn = nn.Dropout(dropout)
        self.norm_attn = nn.LayerNorm(d_model)

        self.ff = nn.Sequential(nn.Linear(d_model, d_ff, bias=bias),
                                get_activation_fn(activation),
                                nn.Dropout(dropout),
                                nn.Linear(d_ff, d_model, bias=bias))

        self.dropout_ffn = nn.Dropout(dropout)
        self.norm_ffn = nn.LayerNorm(d_model)

        self.pre_norm = pre_norm

    def forward(self, src: Tensor, prev: Optional[Tensor] = None):
        if self.pre_norm:
            src2 = self.norm_attn(src)
        else:
            src2 = src
        if self.res_attention:
            src2, attn, scores = self.self_attn(src2, src2, src2, prev)
        else:
            src2, attn = self.self_attn(src2, src2, src2)
        src = src + self.dropout_attn(src2)
        if not self.pre_norm:
            src = self.norm_attn(src)

        if self.pre_norm:
            src2 = self.norm_ffn(src)
        else:
            src2 = src
        src2 = self.ff(src2)
        src = src + self.dropout_ffn(src2)
        if not self.pre_norm:
            src = self.norm_ffn(src)

        if self.res_attention:
            return src, scores
        else:
            return src


class TSTEncoder(nn.Module):
    def __init__(self, d_model, n_heads, d_ff=None, attn_dropout=0., dropout=0., activation='gelu',
                 res_attention=False, n_layers=1, pre_norm=False):
        super().__init__()
        self.layers = nn.ModuleList([TSTEncoderLayer(d_model, n_heads=n_heads, d_ff=d_ff,
                                                     attn_dropout=attn_dropout, dropout=dropout,
                                                     activation=activation, res_attention=res_attention,
                                                     pre_norm=pre_norm) for i in range(n_layers)])
        self.res_attention = res_attention
        self.pre_norm = pre_norm
        self.norm = nn.LayerNorm(d_model) if self.pre_norm else None

    def forward(self, src: Tensor):
        output = src
        scores = None
        if self.res_attention:
            for mod in self.layers: output, scores = mod(output, prev=scores)
        else:
            for mod in self.layers: output = mod(output)
        if self.pre_norm and self.norm is not None:
            output = self.norm(output)
        return output


class AccelPatchTSTEncoder(nn.Module):
    """Processes patches of [patch_len x 3] as 3D vectors -> [bs x num_patch x d_model]."""

    def __init__(self, num_patch, patch_len, n_layers=3, d_model=128, n_heads=16, d_ff=256,
                 attn_dropout=0., dropout=0., act="gelu", res_attention=True, pre_norm=False, learn_pe=True):
        super().__init__()
        self.num_patch = num_patch
        self.patch_len = patch_len
        self.d_model = d_model
        self.W_P = nn.Linear(patch_len * 3, d_model)
        # positional_encoding('zeros', learn_pe, num_patch, d_model)
        W_pos = torch.empty((num_patch, d_model))
        nn.init.uniform_(W_pos, -0.02, 0.02)
        self.W_pos = nn.Parameter(W_pos, requires_grad=learn_pe)
        self.dropout = nn.Dropout(dropout)
        self.encoder = TSTEncoder(d_model, n_heads, d_ff=d_ff, attn_dropout=attn_dropout, dropout=dropout,
                                  pre_norm=pre_norm, activation=act, res_attention=res_attention,
                                  n_layers=n_layers)

    def forward(self, x) -> Tensor:
        bs, num_patch, n_channels, patch_len = x.shape
        assert n_channels == 3, "Expected 3 accelerometer channels (x, y, z)"
        x = x.reshape(bs, num_patch, -1)
        x = self.W_P(x)
        x = self.dropout(x + self.W_pos)
        z = self.encoder(x)
        return z


class AccelPretrainHead(nn.Module):
    """Reconstruct masked 3D accelerometer patches (kept for strict checkpoint loading only)."""

    def __init__(self, d_model, patch_len, dropout):
        super().__init__()
        self.dropout = nn.Dropout(dropout)
        self.linear = nn.Linear(d_model, patch_len * 3)
        self.patch_len = patch_len


class PatchTST_Accel(nn.Module):
    def __init__(self, patch_len: int, stride: int, num_patch: int, n_layers: int = 3, d_model=128,
                 n_heads=16, d_ff: int = 256, attn_dropout: float = 0., dropout: float = 0., act: str = "gelu",
                 res_attention: bool = True, pre_norm: bool = False, learn_pe: bool = True, head_dropout=0):
        super().__init__()
        self.backbone = AccelPatchTSTEncoder(num_patch=num_patch, patch_len=patch_len, n_layers=n_layers,
                                             d_model=d_model, n_heads=n_heads, d_ff=d_ff,
                                             attn_dropout=attn_dropout, dropout=dropout, act=act,
                                             res_attention=res_attention, pre_norm=pre_norm, learn_pe=learn_pe)
        self.head_type = "pretrain"
        self.head = AccelPretrainHead(d_model, patch_len, head_dropout)


class PatchTSTEncoder(nn.Module):
    """Encoder side of upstream ``PatchTSTModule`` (3-channel input; no channel adapter)."""

    def __init__(self, *, window_samples: int, patch_len: int = 10, stride: int = 10, n_layers: int = 4,
                 d_model: int = 512, n_heads: int = 4, d_ff: int = 1024, attn_dropout: float = 0.0,
                 dropout: float = 0.0, act: str = "gelu", res_attention: bool = True, pre_norm: bool = True,
                 learn_pe: bool = True, head_dropout: float = 0.0):
        super().__init__()
        T = int(window_samples)
        self.patch_len = int(patch_len)
        self.stride = int(stride)
        if T < self.patch_len:
            raise ValueError(f"window length T={T} must be >= patch_len={self.patch_len}")
        self.num_patch = 1 + (T - self.patch_len) // self.stride
        self.model = PatchTST_Accel(patch_len=self.patch_len, stride=self.stride, num_patch=self.num_patch,
                                    n_layers=n_layers, d_model=d_model, n_heads=n_heads, d_ff=d_ff,
                                    attn_dropout=attn_dropout, dropout=dropout, act=act,
                                    res_attention=res_attention, pre_norm=pre_norm, learn_pe=learn_pe,
                                    head_dropout=head_dropout)

    def encode(self, x: torch.Tensor) -> torch.Tensor:
        """Return mean pooled PatchTST backbone representation [B, D]."""
        xb = x.permute(0, 2, 1)          # [B, T, 3]
        xb_patch, _ = create_patch(xb, self.patch_len, self.stride)  # [B, num_patch, 3, patch_len]
        z = self.model.backbone(xb_patch)  # [B, num_patch, d_model]
        return z.mean(dim=1)             # [B, d_model]

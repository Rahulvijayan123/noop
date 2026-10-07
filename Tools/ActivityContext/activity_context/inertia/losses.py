"""Masked losses for the Inertia heads (torch; training only — inference is numpy in ``bundle_math``).

Every loss selects masked rows away with ``torch.where`` *before* reduction (never multiply-by-mask: a
masked row against a ``-inf`` unsupported logit is ``inf`` and ``inf * 0 = NaN``). An all-masked batch
returns an exact 0 that still carries a graph (zero gradients, never NaN).

* :func:`masked_set_ce` — set targets as ``int64`` bitmasks over the class order (0 = MASK):
  ``-log sum_{k in S} p_k = logsumexp(z) - logsumexp(z | S)`` (a singleton set is ordinary CE).
* :func:`masked_bce` — multi-label events, targets ``{-1 MASK, 0, 1}`` per event.
* :func:`masked_huber` — regression on a sigmoid output, NaN target = MASK.
"""

from __future__ import annotations

from typing import Optional

import torch
import torch.nn.functional as F

NEG_INF = float("-inf")


def bits_to_bool(target_bits: torch.Tensor, n_classes: int) -> torch.Tensor:
    """int64 bitmask [B] -> bool [B, K]."""
    k = torch.arange(n_classes, device=target_bits.device, dtype=torch.int64)
    return (target_bits[:, None] >> k[None, :]) & 1 == 1


def apply_support(logits: torch.Tensor, supported: torch.Tensor) -> torch.Tensor:
    """Unsupported classes -> -inf (they never receive probability mass)."""
    return logits.masked_fill(~supported[None, :], NEG_INF)


def _weighted_mean(per_row: torch.Tensor, valid: torch.Tensor, w: Optional[torch.Tensor]) -> torch.Tensor:
    per_row = torch.where(valid, per_row, torch.zeros_like(per_row))
    ww = valid.to(per_row.dtype) if w is None else torch.where(valid, w.to(per_row.dtype), torch.zeros_like(per_row))
    return (per_row * ww).sum() / torch.clamp(ww.sum(), min=1e-12)


def masked_set_ce(logits: torch.Tensor, target_bits: torch.Tensor, supported: Optional[torch.Tensor] = None,
                  class_weight: Optional[torch.Tensor] = None, row_weight: Optional[torch.Tensor] = None) -> torch.Tensor:
    """Weighted mean of ``-log sum_{k in S} p_k`` over rows with a non-empty target set.

    ``supported`` (bool [K]) masks unsupported logits to -inf; a valid row whose set has no supported member
    is a caller bug (resolve targets first) and raises. ``class_weight`` [K] weights a row by the mean weight
    of its set members; ``row_weight`` [B] is the dataset/subject balancing weight."""
    K = logits.shape[1]
    z = logits if supported is None else apply_support(logits, supported)
    member = bits_to_bool(target_bits, K)
    valid = target_bits != 0
    if supported is not None:
        member = member & supported[None, :]
        if bool((valid & ~member.any(dim=1)).any()):
            raise ValueError("a valid target set has no supported member; resolve targets before training")
    safe_member = torch.where(valid[:, None], member, torch.ones_like(member))
    if supported is not None:
        safe_member = safe_member & supported[None, :]
    z_set = torch.where(safe_member, z, torch.full_like(z, NEG_INF))
    per_row = torch.logsumexp(z, dim=1) - torch.logsumexp(z_set, dim=1)
    w = row_weight
    if class_weight is not None:
        m = safe_member.to(logits.dtype)
        cw = (m * class_weight[None, :]).sum(1) / torch.clamp(m.sum(1), min=1.0)
        w = cw if w is None else w * cw
    return _weighted_mean(per_row, valid, w)


def masked_bce(logits: torch.Tensor, targets: torch.Tensor, supported: Optional[torch.Tensor] = None,
               pos_weight: Optional[torch.Tensor] = None, row_weight: Optional[torch.Tensor] = None) -> torch.Tensor:
    """Mean BCE over (row, event) entries with target in {0, 1} (and event supported)."""
    valid = targets >= 0
    if supported is not None:
        valid = valid & supported[None, :]
    y = torch.where(valid, targets.to(logits.dtype), torch.zeros_like(logits))
    per = F.binary_cross_entropy_with_logits(logits, y, reduction="none",
                                             pos_weight=None if pos_weight is None else pos_weight.to(logits.dtype))
    per = torch.where(valid, per, torch.zeros_like(per))
    w = valid.to(logits.dtype)
    if row_weight is not None:
        w = w * row_weight[:, None].to(logits.dtype)
    return (per * w).sum() / torch.clamp(w.sum(), min=1e-12)


def masked_huber(pred: torch.Tensor, target: torch.Tensor, delta: float = 0.1,
                 row_weight: Optional[torch.Tensor] = None) -> torch.Tensor:
    """Huber over rows with finite targets; NaN targets are replaced before the residual (torch.where)."""
    valid = torch.isfinite(target)
    safe_t = torch.where(valid, target, pred.detach())
    per_row = F.huber_loss(pred, safe_t, reduction="none", delta=delta)
    return _weighted_mean(per_row, valid, row_weight)


__all__ = ["bits_to_bool", "apply_support", "masked_set_ce", "masked_bce", "masked_huber"]

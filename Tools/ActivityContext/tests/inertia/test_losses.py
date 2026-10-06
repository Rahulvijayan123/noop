"""Masked losses: masked rows -> zero loss and zero gradient, all-masked batch -> 0 (not NaN), set targets."""

import math

import numpy as np
import pytest

torch = pytest.importorskip("torch")

from activity_context.inertia.heads import ARCHS, export_head, make_head, numpy_logits  # noqa: E402
from activity_context.inertia.losses import masked_bce, masked_huber, masked_set_ce  # noqa: E402


def test_masked_rows_zero_loss_and_grad():
    z = torch.randn(4, 5, requires_grad=True)
    y = torch.tensor([1 << 2, 0, 0, (1 << 1) | (1 << 3)])
    loss = masked_set_ce(z, y)
    loss.backward()
    assert torch.all(z.grad[1] == 0) and torch.all(z.grad[2] == 0)
    p = torch.softmax(z.detach(), 1)
    ref = (-torch.log(p[0, 2]) - torch.log(p[3, 1] + p[3, 3])) / 2
    assert abs(float(loss.detach()) - float(ref)) < 1e-5


def test_all_masked_batch_is_zero_not_nan():
    z = torch.randn(3, 4, requires_grad=True)
    sup = torch.tensor([True, True, False, True])
    loss = masked_set_ce(z, torch.zeros(3, dtype=torch.int64), sup)
    loss.backward()
    assert float(loss.detach()) == 0.0 and not torch.isnan(z.grad).any() and torch.all(z.grad == 0)
    lb = masked_bce(z, torch.full((3, 4), -1), sup)
    assert float(lb) == 0.0
    lh = masked_huber(torch.sigmoid(z[:, 0]), torch.full((3,), float("nan")))
    lh.backward()
    assert float(lh) == 0.0


def test_unsupported_class_minus_inf_and_valid_row_on_it_raises():
    z = torch.randn(2, 3)
    sup = torch.tensor([True, False, True])
    loss = masked_set_ce(z, torch.tensor([1 << 0, (1 << 1) | (1 << 2)]), sup)    # {1,2} -> only 2 counts
    assert math.isfinite(float(loss))
    with pytest.raises(ValueError):
        masked_set_ce(z, torch.tensor([1 << 1, 0]), sup)


def test_bce_masks_entries():
    z = torch.zeros(2, 3, requires_grad=True)
    y = torch.tensor([[1, -1, 0], [-1, -1, -1]])
    loss = masked_bce(z, y)
    loss.backward()
    assert abs(float(loss) - math.log(2)) < 1e-6
    assert torch.all(z.grad[1] == 0) and z.grad[0, 1] == 0


@pytest.mark.parametrize("arch", ARCHS)
def test_head_dims_export_and_numpy_parity(arch):
    torch.manual_seed(0)
    m = make_head(arch, 16, 7).eval()
    x = np.random.default_rng(0).standard_normal((5, 16))
    with torch.no_grad():
        ref = m(torch.from_numpy(x.astype(np.float32))).numpy()
    arr = export_head(m, "locomotion", arch)
    out = numpy_logits(arr, "locomotion", arch, x)
    assert out.shape == (5, 7) and np.abs(out - ref).max() < 1e-4
    e = np.exp(out - out.max(1, keepdims=True))
    assert np.allclose((e / e.sum(1, keepdims=True)).sum(1), 1.0)

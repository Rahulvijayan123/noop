"""Static description of the pretrained wrist CNN.

Everything here was read from the upstream ``.h5`` model configs (and is
re-checked against them by ``fetch.py`` before any weight is converted).
No numpy, no I/O: safe to import from anywhere.
"""

from __future__ import annotations

from dataclasses import dataclass

SAMPLE_RATE_HZ = 100
WINDOW_SAMPLES = 6000          # 60 s at 100 Hz
WINDOW_SECONDS = 60
N_AXES = 3

HEADS = ("regression", "classification")
HEAD_UNITS = {"regression": 1, "classification": 3}
HEAD_ACTIVATION = {"regression": "linear", "classification": "softmax"}

DROPOUT_RATE = 0.5             # training only; identity at inference

# Names used by the upstream evaluation code (modeling/model_train_class.py).
# See README.md: the head follows the <1.5 / 1.5-<3 / >=3 MET bands, but the public sample's own
# class codes do not follow these names, so treat them as upstream's, not a verified clinical mapping.
CLASS_INDEX_NAMES = ("SED", "LPA", "MVPA")

# The training sensor (ActiGraph GT3X+ worn on the wrist) clips at +-8 g.
SENSOR_RANGE_G = 8.0


@dataclass(frozen=True)
class ArchSpec:
    """Geometry of the Conv1D stack. The defaults are the real pretrained model."""

    window_samples: int = WINDOW_SAMPLES
    n_axes: int = N_AXES
    kernel_size: int = 10
    filters: tuple[int, ...] = (80, 100, 160, 180, 220, 240)
    pool_after: tuple[int, ...] = (2, 4)   # 1-based conv indices followed by MaxPooling1D
    pool_size: int = 3                     # pool_size == strides, padding "valid" (floor)

    @property
    def n_conv(self) -> int:
        return len(self.filters)

    def weight_shapes(self, units: int) -> dict[str, tuple[int, ...]]:
        shapes: dict[str, tuple[int, ...]] = {}
        cin = self.n_axes
        for i, cout in enumerate(self.filters, start=1):
            shapes[f"conv{i}_kernel"] = (self.kernel_size, cin, cout)
            shapes[f"conv{i}_bias"] = (cout,)
            cin = cout
        shapes["dense_kernel"] = (cin, units)
        shapes["dense_bias"] = (units,)
        return shapes

    def stage_lengths(self, n_samples: int | None = None) -> list[tuple[str, int]]:
        """(stage name, time length) after every conv / pool stage."""
        length = self.window_samples if n_samples is None else n_samples
        stages = []
        for i in range(1, self.n_conv + 1):
            length = length - self.kernel_size + 1
            stages.append((f"conv{i}", length))
            if i in self.pool_after:
                length //= self.pool_size
                stages.append((f"pool_after_conv{i}", length))
        return stages

    def min_samples(self) -> int:
        """Shortest input that leaves at least one time step after the last conv."""
        need = 1
        for i in range(self.n_conv, 0, -1):
            if i in self.pool_after:
                need *= self.pool_size
            need += self.kernel_size - 1
        return need

    def macs(self, units: int, n_samples: int | None = None) -> int:
        shapes = self.weight_shapes(units)
        macs = 0
        stage_len = dict(self.stage_lengths(n_samples))
        for i in range(1, self.n_conv + 1):
            k, cin, cout = shapes[f"conv{i}_kernel"]
            macs += stage_len[f"conv{i}"] * k * cin * cout
        d_in, d_out = shapes["dense_kernel"]
        return macs + d_in * d_out

    def parameter_count(self, units: int) -> int:
        total = 0
        for shape in self.weight_shapes(units).values():
            n = 1
            for d in shape:
                n *= d
            total += n
        return total


REAL_ARCH = ArchSpec()

CONV_KEYS = tuple(
    f"conv{i}_{part}" for i in range(1, REAL_ARCH.n_conv + 1) for part in ("kernel", "bias")
)
DENSE_KEYS = ("dense_kernel", "dense_bias")
WEIGHT_KEYS = CONV_KEYS + DENSE_KEYS


def head_units(head: str) -> int:
    if head not in HEAD_UNITS:
        raise ValueError(f"unknown head {head!r}; expected one of {HEADS}")
    return HEAD_UNITS[head]


def weight_shapes(head: str) -> dict[str, tuple[int, ...]]:
    """Expected float32 array shape of every weight tensor of the real model."""
    return REAL_ARCH.weight_shapes(head_units(head))


def parameter_count(head: str) -> int:
    return REAL_ARCH.parameter_count(head_units(head))


def macs_per_window(head: str = "regression") -> int:
    return REAL_ARCH.macs(head_units(head))

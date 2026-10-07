"""Inertia test configuration.

macOS Accelerate (numpy's BLAS here) raises spurious floating-point status flags on some matmuls, which
numpy reports as "divide by zero / overflow / invalid value encountered in matmul" even though the results
are exact (checked against float64 references). They are noise, not signal, for these tests.
"""

import pytest


def pytest_collection_modifyitems(config, items):
    for item in items:
        if "tests/inertia/" in str(item.fspath).replace("\\", "/"):
            item.add_marker(pytest.mark.filterwarnings("ignore:.*encountered in matmul:RuntimeWarning"))

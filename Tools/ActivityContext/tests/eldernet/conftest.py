"""ElderNet test configuration: macOS Accelerate raises spurious FP flags on some matmuls (see tests/inertia)."""

import pytest


def pytest_collection_modifyitems(config, items):
    for item in items:
        if "tests/eldernet/" in str(item.fspath).replace("\\", "/"):
            item.add_marker(pytest.mark.filterwarnings("ignore:.*encountered in matmul:RuntimeWarning"))
